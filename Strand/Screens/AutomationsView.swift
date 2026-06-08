import SwiftUI
import StrandDesign

/// Automations — turn the strap's physical inputs (double-tap, wrist on/off) and live biometrics
/// into Mac actions and haptic coaching. All on-device.
struct AutomationsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var behavior: BehaviorStore
    @EnvironmentObject var live: LiveState

    var body: some View {
        ScreenScaffold(title: "Automations",
                       subtitle: "Make the strap do things — tap to act, walk away to lock, train by feel.") {
            doubleTapCard
            wearCard
            coachingCard
            alarmCard
        }
    }

    // MARK: - Double tap

    private var doubleTapCard: some View {
        Section2(icon: "hand.tap.fill", title: "Double-tap",
                 blurb: "Double-tap the strap to trigger an action on this Mac. (The strap exposes a single double-tap gesture.)") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("When I double-tap").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Picker("", selection: $behavior.doubleTapAction) {
                        ForEach(MacActionKind.available) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if behavior.doubleTapAction == .runShortcut {
                    shortcutField("Shortcut name", text: $behavior.doubleTapShortcut)
                }
                HStack {
                    Button {
                        model.runMacAction(behavior.doubleTapAction, shortcut: behavior.doubleTapShortcut)
                    } label: { Label("Test action", systemImage: "play.fill") }
                    .buttonStyle(.bordered).tint(StrandPalette.accent)
                    .disabled(behavior.doubleTapAction == .none)
                    Spacer()
                    StatePill(live.bonded ? "Strap bonded" : "Strap not connected",
                              tone: live.bonded ? .positive : .warning, showsDot: true)
                }
                if !model.moments.isEmpty {
                    rowDivider
                    momentsView
                }
            }
        }
    }

    private var momentsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent moments").strandOverline()
                Spacer()
                Button("Clear") {
                    model.moments.removeAll()
                    UserDefaults.standard.removeObject(forKey: "moments")
                }
                .buttonStyle(.plain).font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
            }
            ForEach(Array(model.moments.suffix(5).reversed().enumerated()), id: \.offset) { _, d in
                Text(Self.momentFormatter.string(from: d))
                    .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
    private static let momentFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM · HH:mm"; return f
    }()

    // MARK: - Wear & presence

    private var wearCard: some View {
        Section2(icon: "figure.walk.motion", title: "Wear & presence",
                 blurb: "React when the strap comes off or goes on. Note: macOS reserves true auto-UNLOCK for Apple Watch — this can lock, not unlock.") {
            VStack(spacing: 0) {
                ToggleRow(label: "Lock the Mac when I take the strap off",
                          help: "Fires the moment the strap leaves your wrist.",
                          isOn: $behavior.autoLockOnWristOff)
                rowDivider
                shortcutFieldRow("Run a Shortcut when taken off",
                                 help: "Presence automation — set a Focus, pause media, set away…",
                                 text: $behavior.wristOffShortcut)
                rowDivider
                shortcutFieldRow("Run a Shortcut when put back on",
                                 help: "Reverse the above when you return.",
                                 text: $behavior.wristOnShortcut)
            }
        }
    }

    // MARK: - Coaching

    private var coachingCard: some View {
        Section2(icon: "bolt.heart.fill", title: "Haptic coaching",
                 blurb: "Train by feel — the strap buzzes so you don't have to watch a screen.") {
            VStack(spacing: 0) {
                ToggleRow(label: "HR-zone coaching",
                          help: "Buzz when you hit your top zone (ease off) and again when you recover. Uses your max HR from Settings.",
                          isOn: $behavior.zoneCoaching)
                rowDivider
                ToggleRow(label: "Resting stress nudge (experimental)",
                          help: "A gentle buzz when your HRV drops while your heart rate is calm — a cue to take a paced breath. Rate-limited to once every 15 minutes; off by default.",
                          isOn: $behavior.stressNudge)
            }
        }
    }

    // MARK: - Smart alarm

    private var alarmCard: some View {
        Section2(icon: "alarm.fill", title: "Smart alarm",
                 blurb: "Wake to a wrist buzz. This arms the strap's own firmware alarm, so it still fires if the Mac is asleep or NOOP is closed.") {
            VStack(spacing: 0) {
                ToggleRow(label: "Enable smart alarm", help: "Arms the strap to buzz at your wake time.",
                          isOn: $behavior.smartAlarmEnabled)
                if behavior.smartAlarmEnabled {
                    rowDivider
                    HStack {
                        Text("Wake at").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        DatePicker("", selection: alarmTimeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden().datePickerStyle(.compact)
                    }
                    .frame(minHeight: 42).padding(.vertical, 4)
                    rowDivider
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Light-sleep window").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            Text("Wake up to this many minutes early if the Mac stays awake & connected and a light phase is detected.")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Stepper("\(behavior.smartAlarmWindow) min", value: $behavior.smartAlarmWindow, in: 0...60, step: 5)
                            .fixedSize()
                    }
                    .frame(minHeight: 42).padding(.vertical, 4)
                }
            }
            .onChange(of: behavior.smartAlarmEnabled) { _ in model.applySmartAlarm() }
            .onChange(of: behavior.smartAlarmMinutes) { _ in model.applySmartAlarm() }
        }
    }

    // MARK: - Helpers

    private var alarmTimeBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: behavior.smartAlarmMinutes) },
                set: { behavior.smartAlarmMinutes = Self.minutes(from: $0) })
    }
    private static func date(fromMinutes m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    private static func minutes(from d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func shortcutField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(StrandFont.body)
            .frame(maxWidth: 320)
    }

    private func shortcutFieldRow(_ label: String, help: String, text: Binding<String>) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(help).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            shortcutField("Shortcut name", text: text)
        }
        .frame(minHeight: 42).padding(.vertical, 4)
    }

    private var rowDivider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.vertical, 4)
    }
}

// MARK: - Local section + row (mirrors the settings idiom)

private struct Section2<Content: View>: View {
    let icon: String; let title: String; var blurb: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: icon).foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
                    Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                }
                if let blurb {
                    Text(blurb).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
        }
    }
}

private struct ToggleRow: View {
    let label: String; let help: String; @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(help).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                .accessibilityLabel(label)
        }
        .frame(minHeight: 42).padding(.vertical, 4)
    }
}
