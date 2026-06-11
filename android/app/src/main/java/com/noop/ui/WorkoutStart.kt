package com.noop.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.Sport
import com.noop.analytics.WorkoutSport
import kotlinx.coroutines.delay

/**
 * The shared "Start a workout" picker — sport search + GPS toggle, then [AppViewModel.startWorkout].
 * Lives in one place so both the Live screen and the Workouts screen open the SAME sheet (#115).
 *
 * GPS needs ACCESS_FINE_LOCATION, which the BLE flow does NOT grant on Android 12+, so a GPS start
 * requests it first and falls back to a route-less workout if denied (#101). Calls [onDismiss] once
 * the workout has started (or the user cancels).
 */
@Composable
fun StartWorkoutSheet(vm: AppViewModel, onDismiss: () -> Unit) {
    var query by remember { mutableStateOf("") }
    var selected by remember { mutableStateOf<Sport>(WorkoutSport.default) }
    var gpsOn by remember(selected) { mutableStateOf(selected.isDistanceSport) }
    val filtered = WorkoutSport.all.filter { it.name.contains(query, ignoreCase = true) }
    val startWithGps = rememberRequestLocation { granted ->
        vm.startWorkout(selected, gpsEnabled = gpsOn && granted)
        onDismiss()
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Start a workout") },
        text = {
            Column {
                OutlinedTextField(
                    value = query, onValueChange = { query = it },
                    label = { Text("Search sport") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Column(modifier = Modifier.heightIn(max = 240.dp).verticalScroll(rememberScrollState())) {
                    filtered.forEach { sp ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth()
                                .clickable { selected = sp; gpsOn = sp.isDistanceSport }
                                .padding(vertical = 10.dp),
                        ) {
                            Text(
                                sp.name, style = NoopType.body,
                                color = if (sp == selected) Palette.accent else Palette.textPrimary,
                            )
                            if (sp.isDistanceSport) {
                                Spacer(Modifier.width(6.dp))
                                Text("· GPS", style = NoopType.footnote, color = Palette.textTertiary)
                            }
                        }
                    }
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                ) {
                    Text("Track GPS route", style = NoopType.body, color = Palette.textPrimary)
                    Spacer(Modifier.weight(1f))
                    Switch(checked = gpsOn, onCheckedChange = { gpsOn = it })
                }
            }
        },
        confirmButton = {
            Button(onClick = {
                if (gpsOn) {
                    startWithGps() // requests location, then starts in the callback (#101)
                } else {
                    vm.startWorkout(selected, gpsEnabled = false)
                    onDismiss()
                }
            }) {
                Text("Start ${selected.name}")
            }
        },
        dismissButton = {
            OutlinedButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

/**
 * Start-a-workout entry for the Workouts screen (#115) — mirrors the Live screen's control so a user
 * can begin a session from either place. Shows a compact "running" banner while a workout is active
 * (the rich live card stays on Live), the "Start workout" button when a strap is bonded, or nothing
 * when there's no strap to stream from (matching Live, which only offers the start when bonded).
 */
@Composable
fun WorkoutStartSection(vm: AppViewModel) {
    val live by vm.live.collectAsStateWithLifecycle()
    val activeWorkout by vm.activeWorkout.collectAsStateWithLifecycle()
    var showSportPicker by remember { mutableStateOf(false) }

    val w = activeWorkout
    if (w != null) {
        var nowMs by remember { mutableStateOf(w.startMs) }
        LaunchedEffect(w.startMs) {
            while (true) { nowMs = System.currentTimeMillis(); delay(1000) }
        }
        val elapsedS = ((nowMs - w.startMs) / 1000).coerceAtLeast(0)
        NoopCard {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text("● ${w.sport.name.uppercase()}", style = NoopType.overline, color = Palette.statusCritical)
                Spacer(Modifier.width(10.dp))
                Text(
                    String.format("%d:%02d", elapsedS / 60, elapsedS % 60),
                    style = NoopType.title2, color = Palette.textPrimary,
                )
                Spacer(Modifier.weight(1f))
                Button(
                    onClick = { vm.endWorkout() },
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Palette.statusCritical, contentColor = Palette.surfaceBase,
                    ),
                ) { Text("End", style = NoopType.captionNumber) }
            }
        }
    } else if (live.bonded) {
        Button(
            onClick = { showSportPicker = true },
            modifier = Modifier.fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 10.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = Palette.accent, contentColor = Palette.surfaceBase,
            ),
        ) { Text("Start workout", style = NoopType.captionNumber) }
    }

    if (showSportPicker) {
        StartWorkoutSheet(vm = vm, onDismiss = { showSportPicker = false })
    }
}
