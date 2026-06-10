package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.noop.data.JournalEntry
import java.time.LocalDate

// MARK: - Native journal logging (pure helpers + the Insights logging card)

/** Native answers are written under this dedicated source id, NEVER under "my-whoop":
 *  journal's PK is (deviceId, day, question) and has no source column, so a CSV re-import
 *  would silently overwrite in-app answers (and clears could delete imported rows). */
const val JOURNAL_DEVICE_ID = "noop-journal"

/** Starter behaviour catalog (mirrors WHOOP's most popular journal questions; full-question
 *  phrasing matching the export style). Question strings are opaque exact-match labels to the
 *  effects engine, so imported question strings always take precedence (mergeJournalCatalog).
 *  They are DATA, not UI literals — stored verbatim in the journal table. */
val STARTER_JOURNAL_QUESTIONS: List<String> = listOf(
    "Did you drink any alcohol?",
    "Did you have caffeine late in the day?",
    "Did you view a screen in bed?",
    "Did you eat close to bedtime?",
    "Did you feel stressed?",
    "Did you use a sauna?",
    "Did you share your bed?",
    "Did you feel sick or ill?",
    "Did you take magnesium?",
    "Did you read before bed?",
)

/** Catalog = imported questions (exact strings → logged days join imported history), then
 *  starter defaults, then user customs. Case-insensitive dedupe, first casing wins. */
internal fun mergeJournalCatalog(
    imported: List<String>,
    custom: List<String>,
    starter: List<String> = STARTER_JOURNAL_QUESTIONS,
): List<String> {
    val out = ArrayList<String>()
    val seen = HashSet<String>()
    for (q in imported + starter + custom) {
        val t = q.trim()
        if (t.isNotEmpty() && seen.add(t.lowercase())) out.add(t)
    }
    return out
}

/** Union of imported + native entries; on a (day, question) collision the NATIVE row wins
 *  (the in-app answer is the user's most recent explicit action and stays editable). */
internal fun mergeJournalEntries(
    imported: List<JournalEntry>,
    native: List<JournalEntry>,
): List<JournalEntry> {
    val byKey = LinkedHashMap<Pair<String, String>, JournalEntry>()
    for (e in imported) byKey[e.day to e.question] = e
    for (e in native) byKey[e.day to e.question] = e
    return byKey.values.sortedWith(compareBy({ it.day }, { it.question }))
}

/** Importer convention (WhoopCsvImporter.parseJournal): journal day = the wake/cycle day whose
 *  morning recovery the previous ~24 h affected. "Log today" = answers about yesterday / last
 *  night, attributed to TODAY's local day key; daysBack=1 edits yesterday. */
internal fun journalDayKey(daysBack: Long = 0L, today: LocalDate = LocalDate.now()): String =
    today.minusDays(daysBack).toString()

// MARK: - The logging card (hosted at the top of Insights)

/**
 * Yes/no chips for the merged behaviour catalog + a free-text custom-question field.
 * Tri-state: no answer logged → neither chip filled; tapping the selected chip again
 * clears the answer (deletes the native row — imported rows are never touched).
 */
@Composable
fun JournalLogCard(
    catalog: List<String>,
    answers: Map<String, Boolean>,
    dayOffset: Long,
    onDayOffset: (Long) -> Unit,
    onAnswer: (String, Boolean) -> Unit,
    onClear: (String) -> Unit,
    onAddCustom: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            SectionHeader(
                title = "Journal",
                overline = "Log",
                trailing = null,
            )
            Spacer(Modifier.weight(1f))
            DayChip("Today", selected = dayOffset == 0L) { onDayOffset(0L) }
            Spacer(Modifier.width(6.dp))
            DayChip("Yesterday", selected = dayOffset == 1L) { onDayOffset(1L) }
        }
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "Answers are about the night and day leading into this morning — the same " +
                        "attribution a WHOOP export uses, so logged and imported days line up.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
                catalog.forEach { q ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            q,   // data, not a UI literal — rendered verbatim
                            style = NoopType.body,
                            color = Palette.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        AnswerChip("Yes", selected = answers[q] == true) {
                            if (answers[q] == true) onClear(q) else onAnswer(q, true)
                        }
                        Spacer(Modifier.width(6.dp))
                        AnswerChip("No", selected = answers[q] == false) {
                            if (answers[q] == false) onClear(q) else onAnswer(q, false)
                        }
                    }
                }
                JournalDivider()
                var draft by remember { mutableStateOf("") }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = draft,
                        onValueChange = { draft = it },
                        placeholder = {
                            Text("Add a custom question…", style = NoopType.body, color = Palette.textTertiary)
                        },
                        singleLine = true,
                        textStyle = NoopType.body,
                        colors = journalFieldColors(),
                        shape = RoundedCornerShape(14.dp),
                        modifier = Modifier.weight(1f),
                    )
                    Spacer(Modifier.width(8.dp))
                    AnswerChip("Add", selected = draft.isNotBlank()) {
                        val t = draft.trim()
                        if (t.isNotEmpty()) {
                            onAddCustom(t)
                            draft = ""
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DayChip(label: String, selected: Boolean, onClick: () -> Unit) {
    AnswerChip(label, selected = selected, onClick = onClick)
}

@Composable
private fun JournalDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .height(1.dp)
            .background(Palette.hairline),
    )
}

@Composable
private fun AnswerChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Text(
        label,
        style = NoopType.caption,
        color = if (selected) Palette.surfaceBase else Palette.textSecondary,
        modifier = Modifier
            .clip(shape)
            .background(if (selected) Palette.accent else Palette.surfaceInset)
            .border(1.dp, if (selected) Palette.accent else Palette.hairline, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    )
}

@Composable
private fun journalFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    disabledTextColor = Palette.textTertiary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    disabledBorderColor = Palette.hairline,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
    disabledContainerColor = Palette.surfaceInset,
)
