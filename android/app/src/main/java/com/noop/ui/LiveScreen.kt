package com.noop.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.ble.WhoopModel

/**
 * Live — the real-time strap view + hardware-test surface. A big smoothed HR number,
 * a connection pill, a battery/last-event status grid, and connect/disconnect/buzz
 * controls. Ports LiveView.swift to Compose. Toggles the strap's real-time HR stream
 * on/off as the screen enters/leaves composition.
 */
@Composable
fun LiveScreen(viewModel: AppViewModel) {
    val live by viewModel.live.collectAsStateWithLifecycle()
    val bpm by viewModel.bpm.collectAsStateWithLifecycle()
    val selectedModel by viewModel.selectedModel.collectAsStateWithLifecycle()

    // The runtime Bluetooth permission gates scanning. If it isn't granted, the Connect button
    // REQUESTS it (rather than silently doing nothing), then connects once allowed. Shared with
    // Settings → Re-scan via rememberRequestScan so no entry point can forget the gate (issue #1).
    val requestConnect = rememberRequestScan { viewModel.connect() }

    // Keep the realtime HR stream on while this screen is visible (ref-counted in the ViewModel, so
    // navigating to Health Monitor — which also wants it — doesn't stop it). Refresh battery on bond.
    DisposableEffect(Unit) {
        viewModel.requestRealtimeHr()
        onDispose { viewModel.releaseRealtimeHr() }
    }
    LaunchedEffect(live.bonded) {
        if (live.bonded) viewModel.getBattery()
    }

    ScreenScaffold(title = "Live", subtitle = "All your data · none of the cloud") {

        // Connection pill row.
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            val (label, tone) = when {
                live.bonded -> "Bonded" to StrandTone.Positive
                live.connected -> "Connected" to StrandTone.Warning
                live.scanning -> "Searching…" to StrandTone.Warning
                else -> "Disconnected" to StrandTone.Critical
            }
            StatePill(label, tone = tone, pulsing = live.bonded || live.scanning)
        }
        // Why it's in this state and what to try (permission, strap busy, not found…).
        live.statusNote?.let { note ->
            Text(
                note,
                style = NoopType.footnote,
                color = Palette.textSecondary,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        // Big HR card.
        HeartRateCard(bpm = bpm, rr = live.rr)

        // Status grid.
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            StatTile(
                modifier = Modifier.weight(1f),
                label = "Battery",
                value = live.batteryPct?.let { "${it.toInt()}%" } ?: "—",
                accent = batteryColor(live.batteryPct),
            )
            StatTile(
                modifier = Modifier.weight(1f),
                label = "Worn",
                value = if (live.worn) "Yes" else "Off",
                accent = if (live.worn) Palette.accent else Palette.textTertiary,
            )
            StatTile(
                modifier = Modifier.weight(1f),
                label = "Last Event",
                value = live.lastEvent ?: "—",
                accent = Palette.textPrimary,
            )
        }

        // Strap picker — choose the model before scanning so we look for exactly one device family.
        // Shown whenever we're not actively streaming, so a user with both a WHOOP 4 and a 5/MG can
        // switch between them (it used to hide once `bonded`, which stuck after the first pairing).
        if (!(live.connected && live.bonded)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Metrics.gap),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Strap", style = NoopType.footnote, color = Palette.textSecondary)
                SegmentedPillControl(
                    items = WhoopModel.entries.toList(),
                    selection = selectedModel,
                    label = { it.displayName },
                    onSelect = { viewModel.setSelectedModel(it) },
                )
            }
        }

        // Controls.
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap), modifier = Modifier.fillMaxWidth()) {
            // Compact, single-line labels: with three weight(1f) buttons in a row, the default
            // body style + icon could wrap "Re-scan"/"Searching…" to two lines on narrow phones,
            // making one button taller than the others. captionNumber + maxLines=1 keeps the row
            // even. Connect disables while a scan is in flight so it can't be re-tapped mid-search.
            Button(
                onClick = { requestConnect() },
                modifier = Modifier.weight(1f),
                enabled = !live.scanning,
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Palette.accent,
                    contentColor = Palette.surfaceBase,
                ),
            ) {
                Icon(
                    Icons.Filled.Bluetooth,
                    contentDescription = null,
                    modifier = Modifier
                        .size(18.dp)
                        .padding(end = 4.dp),
                )
                Text(
                    when {
                        live.scanning -> "Searching…"
                        live.connected -> "Re-scan"
                        else -> "Connect"
                    },
                    style = NoopType.captionNumber,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Clip,
                )
            }

            OutlinedButton(
                onClick = { viewModel.buzz(2) },
                modifier = Modifier.weight(1f),
                enabled = live.bonded,
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
            ) {
                Icon(
                    Icons.Filled.GraphicEq,
                    contentDescription = null,
                    modifier = Modifier
                        .size(18.dp)
                        .padding(end = 4.dp),
                )
                Text(
                    "Buzz",
                    style = NoopType.captionNumber,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Clip,
                )
            }

            OutlinedButton(
                onClick = { viewModel.disconnect() },
                modifier = Modifier.weight(1f),
                enabled = live.connected,
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.statusCritical),
            ) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription = null,
                    modifier = Modifier
                        .size(18.dp)
                        .padding(end = 4.dp),
                )
                Text(
                    "End",
                    style = NoopType.captionNumber,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Clip,
                )
            }
        }

        // Foolproof connection walkthrough — detects each blocker (WHOOP app, Bluetooth,
        // permission) and offers a one-tap fix. Hidden once the strap is bonded.
        if (!live.bonded) {
            ConnectionHelp(viewModel, modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun HeartRateCard(bpm: Int?, rr: List<Int>) {
    val color by animateColorAsState(
        if (bpm == null) Palette.textSecondary else Palette.accentHover,
        tween(Motion.durationStandard), label = "hrColor",
    )
    val shape = RoundedCornerShape(Metrics.cardRadius)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(Palette.surfaceRaised, shape)
            .border(1.dp, Palette.hairline, shape)
            .padding(vertical = 28.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Overline("Heart Rate")
            Text(
                text = bpm?.toString() ?: "—",
                style = NoopType.number(96f),
                color = color,
            )
            Text("bpm", style = NoopType.subhead, color = Palette.textSecondary)
            if (rr.isNotEmpty()) {
                Spacer(Modifier.padding(top = 4.dp))
                Text(
                    text = "R-R " + rr.takeLast(4).joinToString(" · ") + " ms",
                    style = NoopType.captionNumber,
                    color = Palette.textTertiary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

private fun batteryColor(pct: Double?): Color = when {
    pct == null -> Palette.textPrimary
    pct < 15 -> Palette.statusCritical
    pct < 30 -> Palette.statusWarning
    else -> Palette.accent
}
