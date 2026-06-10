package com.noop.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.noop.R
import com.noop.ui.MainActivity
import java.text.DateFormat
import java.util.Date

/**
 * Home-screen widget: today's recovery (band-coloured), live HR and strap battery at a glance.
 * Renders purely from the [WidgetSnapshotStore] SharedPreferences snapshot — no BLE, no DB — so it
 * costs nothing and survives process death. Tapping anywhere opens the app.
 *
 * Colours are hardcoded mirrors of [com.noop.ui.Palette] (surfaceRaised / textPrimary / textSecondary
 * / statusPositive / statusWarning / statusCritical): Glance composes outside our theme, and the
 * widget is deliberately always-dark like the app.
 */
class NoopGlanceWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        // A corrupt pref must degrade to the empty-state widget, not throw mid-provide.
        val snap = runCatching { WidgetSnapshotStore.load(context) }.getOrDefault(WidgetSnapshot())
        provideContent { WidgetContent(snap) }
    }

    /** Defence-in-depth, NOT a crash fix: Glance 1.1.0's default already contains composition errors
     *  (it renders its built-in error layout; verified in bytecode while investigating #82 — which we
     *  could not reproduce). This override only swaps that generic layout for our own friendlier one.
     *  The widget heals on the next successful push. */
    override fun onCompositionError(
        context: Context,
        glanceId: GlanceId,
        appWidgetId: Int,
        throwable: Throwable,
    ) {
        runCatching {
            val rv = android.widget.RemoteViews(context.packageName, R.layout.noop_widget_error)
            android.appwidget.AppWidgetManager.getInstance(context).updateAppWidget(appWidgetId, rv)
        }
    }
}

private val surface = ColorProvider(Color(0xFF0D1512))
private val textPrimary = ColorProvider(Color(0xFFF4F7F5))
private val textSecondary = ColorProvider(Color(0xFF8B9690))

/** Recovery-band colour, the app-wide 67 / 34 cuts (RecoveryScorer.band). */
private fun bandColor(recovery: Int): ColorProvider = ColorProvider(
    when {
        recovery >= 67 -> Color(0xFF18C98B)
        recovery >= 34 -> Color(0xFFF5A623)
        else -> Color(0xFFFF4F73)
    },
)

@Composable
private fun WidgetContent(snap: WidgetSnapshot) {
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(surface)
            .cornerRadius(16.dp)
            .clickable(actionStartActivity<MainActivity>())
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "RECOVERY",
            style = TextStyle(color = textSecondary, fontSize = 11.sp, fontWeight = FontWeight.Medium),
        )
        Text(
            text = snap.recoveryPct?.let { "$it%" } ?: "—",
            style = TextStyle(
                color = snap.recoveryPct?.let { bandColor(it) } ?: textSecondary,
                fontSize = 32.sp,
                fontWeight = FontWeight.Bold,
            ),
        )
        Spacer(modifier = GlanceModifier.height(4.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = snap.heartRate?.let { "♥ $it" } ?: "♥ —",
                style = TextStyle(color = textPrimary, fontSize = 13.sp),
            )
            Spacer(modifier = GlanceModifier.width(10.dp))
            Text(
                text = snap.batteryPct?.let { "⚡ $it%" } ?: "⚡ —",
                style = TextStyle(color = textPrimary, fontSize = 13.sp),
            )
        }
        Spacer(modifier = GlanceModifier.height(2.dp))
        Text(
            text = when {
                snap.connected -> "Connected"
                snap.updatedAtMs > 0L ->
                    DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(snap.updatedAtMs))
                else -> "Open NOOP to connect"
            },
            style = TextStyle(color = textSecondary, fontSize = 11.sp),
        )
    }
}
