package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/**
 * Automations — turn the strap's physical inputs (double-tap, wrist on/off) and live
 * biometrics into on-device actions and haptic coaching. The toggles persist nothing
 * here yet (the data layer owns settings); they are functional, local UI placeholders
 * that mirror AutomationsView.swift so the wiring agent can bind them to a store.
 */
@Composable
fun AutomationsScreen(viewModel: AppViewModel) {
    val live by viewModel.live.collectAsStateWithLifecycle()

    var zoneCoaching by remember { mutableStateOf(false) }
    var stressNudge by remember { mutableStateOf(false) }
    var autoLockOnWristOff by remember { mutableStateOf(false) }
    // Smart alarm is real + persisted (issue #51): backed by the ViewModel, which arms the strap's
    // firmware alarm. (The toggles above are still preview-only — separate follow-up.)
    val smartAlarm by viewModel.smartAlarmEnabled.collectAsStateWithLifecycle()
    val alarmMinutes by viewModel.smartAlarmMinutes.collectAsStateWithLifecycle()

    ScreenScaffold(
        title = "Automations",
        subtitle = "Make the strap do things — tap to act, walk away to lock, train by feel.",
    ) {
        // Double-tap.
        SettingsSection(
            icon = Icons.Filled.TouchApp,
            title = "Double-tap",
            blurb = "Double-tap the strap to trigger an action on this device. (The strap exposes a single double-tap gesture.)",
        ) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("When I double-tap", style = NoopType.body, color = Palette.textPrimary)
                Spacer(Modifier.weight(1f))
                StatePill(
                    if (live.bonded) "Strap bonded" else "Not connected",
                    tone = if (live.bonded) StrandTone.Positive else StrandTone.Warning,
                )
            }
            RowDivider()
            Text(
                "Currently mapped to: silence alerts. Bind more actions once the strap is connected.",
                style = NoopType.footnote, color = Palette.textTertiary,
            )
        }

        // Haptic coaching.
        SettingsSection(
            icon = Icons.Filled.Bolt,
            title = "Haptic coaching",
            blurb = "Train by feel — the strap buzzes so you don't have to watch a screen.",
        ) {
            ToggleRow(
                label = "HR-zone coaching",
                help = "Buzz when you hit your top zone (ease off) and again when you recover. Uses your max HR from settings.",
                checked = zoneCoaching,
                onChange = { zoneCoaching = it },
            )
            RowDivider()
            ToggleRow(
                label = "Resting stress nudge (experimental)",
                help = "A gentle buzz when your HRV drops while your heart rate is calm — a cue to take a paced breath. Rate-limited to once every 15 minutes; off by default.",
                checked = stressNudge,
                onChange = { stressNudge = it },
            )
        }

        // Wear & presence.
        SettingsSection(
            icon = Icons.Filled.TouchApp,
            title = "Wear & presence",
            blurb = "React when the strap comes off or goes on.",
        ) {
            ToggleRow(
                label = "Lock the device when I take the strap off",
                help = "Fires the moment the strap leaves your wrist.",
                checked = autoLockOnWristOff,
                onChange = { autoLockOnWristOff = it },
            )
        }

        // Smart alarm.
        SettingsSection(
            icon = Icons.Filled.Alarm,
            title = "Smart alarm",
            blurb = "Wake to a wrist buzz. This arms the strap's own firmware alarm, so it still fires if the phone is asleep or NOOP is closed.",
        ) {
            ToggleRow(
                label = "Enable smart alarm",
                help = "Arms the strap to buzz at your wake time.",
                checked = smartAlarm,
                onChange = { viewModel.setSmartAlarmEnabled(it) },
            )
            if (smartAlarm) {
                RowDivider()
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Wake at", style = NoopType.body, color = Palette.textPrimary)
                    Spacer(Modifier.weight(1f))
                    TimeChip(
                        minutes = alarmMinutes,
                        accessibilityLabel = "Smart alarm wake time",
                        onPicked = { viewModel.setSmartAlarmMinutes(it) },
                    )
                }
                RowDivider()
                Text(
                    if (live.bonded)
                        "Armed on the strap itself, so it buzzes at your wake time even if your phone is asleep or NOOP is closed."
                    else
                        "Connect your strap to arm this — it's set on the strap's own firmware alarm, so it fires even when your phone or NOOP isn't running.",
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            }
        }
    }
}

// MARK: - Section + rows (mirror the settings idiom from AutomationsView.swift)

@Composable
private fun SettingsSection(
    icon: ImageVector,
    title: String,
    blurb: String,
    content: @Composable () -> Unit,
) {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(icon, contentDescription = null, tint = Palette.accent)
                Spacer(Modifier.width(10.dp))
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(blurb, style = NoopType.subhead, color = Palette.textSecondary)
            content()
        }
    }
}

@Composable
private fun ToggleRow(
    label: String,
    help: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = NoopType.body, color = Palette.textPrimary)
            Text(help, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Spacer(Modifier.width(16.dp))
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Palette.surfaceBase,
                checkedTrackColor = Palette.accent,
                uncheckedThumbColor = Palette.textSecondary,
                uncheckedTrackColor = Palette.surfaceInset,
                uncheckedBorderColor = Palette.hairline,
            ),
        )
    }
}

@Composable
private fun RowDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .padding(vertical = 4.dp)
            .background(Palette.hairline),
    )
}
