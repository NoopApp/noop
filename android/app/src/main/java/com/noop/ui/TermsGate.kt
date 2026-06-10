package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Current Terms of Use version. Bump on a MATERIAL change (risk / liability / medical / affiliation
 * wording) to re-prompt every user for a fresh acknowledgment; leave it for typo fixes. Mirrors macOS
 * `Terms.currentVersion`. The full text ships in TERMS.md.
 */
object Terms {
    const val CURRENT_VERSION = "1.0"

    /** Plain-English summary of TERMS.md §1–§6 — kept identical to the macOS `Terms.points`. */
    val points: List<Pair<String, String>> = listOf(
        "Independent — not affiliated with WHOOP" to
            "NOOP is an unofficial project — not affiliated with, endorsed by, or sponsored by WHOOP, Inc. \"WHOOP\" is their trademark, used only to name the hardware NOOP works with.",
        "Using NOOP may breach WHOOP's Terms of Service" to
            "Use it only with a device you own, to read your own data. Whether to use it — and any effect on your WHOOP account, subscription, device, or warranty — is your decision, and your risk alone.",
        "Experimental — at your own risk" to
            "NOOP talks to your strap's firmware over an unofficial, reverse-engineered protocol. There is a residual risk to the device, its data, and its connection to official services. You assume that risk.",
        "Not a medical device, not medical advice" to
            "Every metric is an unvalidated approximation. Don't use NOOP to diagnose, treat, or make any health decision. Always consult a qualified professional.",
        "No warranty; liability limited" to
            "NOOP is free and provided \"as is\", with no warranty. Liability is limited to the maximum extent the law that applies to you allows — and nothing here removes protections your local law won't let us remove.",
    )
}

/**
 * First-run acknowledgment gate (clickwrap), shown over everything — before onboarding, pairing, or
 * any Bluetooth access — until [Terms.CURRENT_VERSION] is accepted, and again if the terms materially
 * change. The user must tick the (un-pre-checked) box and tap Accept; acceptance is persisted by the
 * caller. Mirrors macOS `TermsGateView`.
 */
@Composable
fun TermsGateScreen(onAccept: () -> Unit) {
    var checked by remember { mutableStateOf(false) }
    Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
        Column(modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp)) {
            Spacer(Modifier.height(40.dp))
            Text("Before you use NOOP", style = NoopType.title1, color = Palette.textPrimary)
            Spacer(Modifier.height(4.dp))
            Text(
                "Please read and accept the points below.",
                style = NoopType.subhead, color = Palette.textSecondary,
            )
            Spacer(Modifier.height(20.dp))

            Column(
                modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Terms.points.forEach { (head, body) ->
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(head, style = NoopType.headline, color = Palette.textPrimary)
                        Text(body, style = NoopType.footnote, color = Palette.textSecondary)
                    }
                }
                Text(
                    "The full terms are in TERMS.md, shipped with NOOP. This is not legal advice.",
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            }

            Spacer(Modifier.height(12.dp))
            Row(verticalAlignment = Alignment.Top) {
                Checkbox(
                    checked = checked,
                    onCheckedChange = { checked = it },
                    colors = CheckboxDefaults.colors(checkedColor = Palette.accent),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    "I have read and accept these terms, and I'm using NOOP with my own device and my own data, at my own risk.",
                    style = NoopType.footnote, color = Palette.textPrimary,
                    modifier = Modifier.padding(top = 14.dp),
                )
            }
            Spacer(Modifier.height(12.dp))
            Button(
                onClick = onAccept,
                enabled = checked,
                modifier = Modifier.fillMaxWidth().padding(bottom = 24.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Palette.accent),
            ) {
                Text("Accept & Continue", style = NoopType.headline)
            }
        }
    }
}
