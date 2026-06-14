import SwiftUI
import StrandDesign

/// Smart alarm (#207) — the iOS/macOS surface.
///
/// HONEST by design: a sideloaded, backgrounded app on iOS can't fire a dependable LOUD wake alarm
/// (that needs the critical-alert entitlement, which a non-App-Store build doesn't have), so this
/// platform deliberately does NOT offer a wake alarm. The dependable phone wake lives on Android,
/// which has the exact-alarm primitive. Here we offer the cross-platform WIND-DOWN nudge — a gentle
/// evening reminder — and we say plainly why there's no wake alarm, rather than promising one we
/// can't keep.
struct SmartAlarmView: View {
    @State private var windDownOn = WindDownNudge.isEnabled
    /// Earliest wake time the nudge is derived from (minutes since midnight). Seeded from the store.
    @State private var wakeMinutes = WindDownNudge.wakeMinutes

    var body: some View {
        ScreenScaffold(title: "Smart alarm",
                       subtitle: "A gentle evening wind-down nudge to help you reach your wake time rested.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                windowHero
                honestyCard
                windDownCard
            }
        }
    }

    // A small Rest-tinted hero — the wind-down readout as a clean time pairing (wind-down → wake)
    // over a scenic Rest backdrop, so a glance gives the night's shape. It's about winding down to
    // sleep, so it reads in the Rest world (indigo) rather than the brand-green chrome below.
    private var windowHero: some View {
        ZStack {
            ScenicHeroBackground(domain: .rest)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 12) {
                Text("Tonight").strandOverline()
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    heroTime(label: "Wind down",
                             time: windDownOn ? timeLabel(WindDownNudge.nudgeMinuteOfDay()) : "—",
                             tint: StrandPalette.restColor)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    heroTime(label: "Wake",
                             time: timeLabel(wakeMinutes),
                             tint: StrandPalette.restBright)
                    Spacer(minLength: 0)
                }
                Text(windDownOn
                     ? "A calm nudge \(WindDownNudge.sleepNeedMinutes / 60)h \(WindDownNudge.leadMinutes)m before your wake time."
                     : "Turn on the wind-down reminder below to land at your wake time rested.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .accessibilityElement(children: .combine)
    }

    private func heroTime(label: LocalizedStringKey, time: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).strandOverline()
            Text(time)
                .font(StrandFont.number(28))
                .foregroundStyle(tint)
        }
    }

    // The up-front, honest explanation of why iOS gets a nudge and not a wake alarm.
    private var honestyCard: some View {
        StrandCard(padding: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.slash")
                    .foregroundStyle(StrandPalette.statusWarning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("No wake alarm on this device")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("A sideloaded app can't sound a reliable wake alarm in the background on iOS — that needs a critical-alert permission this build doesn't have. Use your phone's built-in Clock alarm to wake. NOOP's smart wake (light-sleep detection) is available on the Android app.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var windDownCard: some View {
        // Rest-tinted when armed so the active state reads in the sleep world; neutral when off.
        StrandCard(padding: 20, tint: windDownOn ? StrandPalette.restColor : nil) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Evening").strandOverline()
                    HStack(spacing: 10) {
                        Image(systemName: "moon.zzz.fill")
                            .foregroundStyle(StrandPalette.restColor)
                            .accessibilityHidden(true)
                        Text("Wind-down nudge")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remind me to wind down")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("A calm evening reminder, timed from your wake time and usual sleep need. It's a suggestion, not an alarm.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $windDownOn)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .accessibilityLabel("Remind me to wind down")
                        .onChangeCompat(of: windDownOn) { _, on in WindDownNudge.setEnabled(on) }
                }
                .frame(minHeight: 42)

                if windDownOn {
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wake time")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("The nudge fires \(WindDownNudge.sleepNeedMinutes / 60)h \(WindDownNudge.leadMinutes)m before this.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer()
                        DatePicker("", selection: wakeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityLabel("Wake time")
                    }
                    Text("You'll be reminded around \(timeLabel(WindDownNudge.nudgeMinuteOfDay())).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    // Bridges the minutes-since-midnight store to a DatePicker's Date, persisting + rescheduling.
    private var wakeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = wakeMinutes / 60
                c.minute = wakeMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                wakeMinutes = m
                WindDownNudge.setWakeMinutes(m)
            }
        )
    }

    private func timeLabel(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
