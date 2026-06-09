import SwiftUI
import AppKit
import UniformTypeIdentifiers
import StrandDesign
import WhoopStore

/// Settings — profile (powers zones / calories / recovery), strap connection, and about.
/// Grouped cards on surface.raised with a two-column form feel.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore

    /// Backup & restore UI state.
    @State private var backupBusy = false
    @State private var backupAlertTitle = ""
    @State private var backupAlertMessage = ""
    @State private var showBackupAlert = false

    /// Opt-in WHOOP 5/MG protocol experiments (off by default). See [PuffinExperiment].
    @AppStorage(PuffinExperiment.defaultsKey) private var puffinExperiments = false

    /// Opt-in WHOOP 5/MG raw-frame capture to a file (off by default). See [PuffinFrameRecorder].
    @AppStorage(PuffinFrameRecorder.enabledKey) private var puffinCapture = false

    /// "What's New" changelog sheet, reachable any time from About.
    @State private var showWhatsNew = false

    var body: some View {
        ScreenScaffold(title: "Settings",
                       subtitle: "Your numbers, your strap, and how NOOP works. All on this Mac.") {
            profileCard
            strapCard
            experimentalCard
            backupCard
            aboutCard
        }
        .alert(backupAlertTitle, isPresented: $showBackupAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(backupAlertMessage)
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(onClose: { showWhatsNew = false })
        }
    }

    // MARK: - Profile

    private var profileCard: some View {
        SettingsSection(
            icon: "person.fill",
            title: "Profile",
            blurb: "These power your heart-rate zones, calorie estimates and recovery baselines. Keep them accurate."
        ) {
            VStack(spacing: 0) {
                FormRow(label: "Age") {
                    HStack(spacing: 12) {
                        Text("\(profile.age)")
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(minWidth: 28, alignment: .trailing)
                        Stepper("Age", value: $profile.age, in: 13...100)
                            .labelsHidden()
                            .accessibilityLabel("Age, \(profile.age) years")
                    }
                }
                rowDivider
                FormRow(label: "Sex") {
                    Picker("Sex", selection: $profile.sex) {
                        Text("Male").tag("male")
                        Text("Female").tag("female")
                        Text("Non-binary").tag("nonbinary")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Sex")
                }
                rowDivider
                FormRow(label: "Weight") {
                    measureField(value: $profile.weightKg, unit: "kg",
                                 range: 30...250, step: 0.5, format: "%.1f",
                                 accessibility: "Weight in kilograms")
                }
                rowDivider
                FormRow(label: "Height") {
                    measureField(value: $profile.heightCm, unit: "cm",
                                 range: 120...230, step: 1, format: "%.0f",
                                 accessibility: "Height in centimetres")
                }
                rowDivider
                FormRow(label: "Max heart rate") {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 8) {
                            hrMaxField
                            Text("bpm")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Text(profile.hrMaxOverride > 0
                             ? "Manual override"
                             : "Auto · \(profile.hrMax) bpm (Tanaka)")
                            .font(StrandFont.footnote)
                            .foregroundStyle(profile.hrMaxOverride > 0
                                             ? StrandPalette.accent
                                             : StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    /// Numeric weight/height field: tabular value + small +/- stepper.
    private func measureField(value: Binding<Double>, unit: String,
                              range: ClosedRange<Double>, step: Double,
                              format: String, accessibility: String) -> some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: format, value.wrappedValue))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(minWidth: 48, alignment: .trailing)
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Stepper(accessibility, value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(accessibility)
        }
    }

    /// HR-max override: 0 = auto. Shown as a compact tabular value with a stepper.
    private var hrMaxField: some View {
        HStack(spacing: 10) {
            Text(profile.hrMaxOverride > 0 ? "\(profile.hrMaxOverride)" : "Auto")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(profile.hrMaxOverride > 0
                                 ? StrandPalette.textPrimary
                                 : StrandPalette.textTertiary)
                .frame(minWidth: 44, alignment: .trailing)
            Stepper("Max heart rate override",
                    value: $profile.hrMaxOverride, in: 0...230, step: 1)
                .labelsHidden()
                .accessibilityLabel("Max heart rate override, \(profile.hrMaxOverride == 0 ? "automatic" : "\(profile.hrMaxOverride) bpm")")
        }
    }

    // MARK: - Strap

    private var strapCard: some View {
        SettingsSection(
            icon: "antenna.radiowaves.left.and.right",
            title: "Strap",
            blurb: "NOOP pairs directly with your WHOOP over Bluetooth — no WHOOP app, no cloud."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    StatePill("\(strapStatusTitle)", tone: strapTone, pulsing: live.connected)
                    if let pct = live.batteryPct {
                        StatePill("Battery \(Int(pct.rounded()))%",
                                  tone: batteryTone(pct), showsDot: false)
                    }
                    Spacer(minLength: 0)
                }
                Text(strapStatusDetail)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                HStack(spacing: 12) {
                    Button {
                        model.scan()
                    } label: {
                        Label("Re-scan", systemImage: "arrow.clockwise")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)

                    Button {
                        model.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(StrandPalette.statusCritical)
                    .disabled(!live.connected && !live.bonded)
                }
            }
        }
    }

    private var strapStatusTitle: String {
        if live.bonded && live.connected { return "Bonded · streaming" }
        if live.connected { return "Connected" }
        if live.bonded { return "Bonded · idle" }
        return "Disconnected"
    }

    private var strapTone: StrandTone {
        if live.connected { return .positive }
        if live.bonded { return .warning }
        return .critical
    }

    private var strapStatusDetail: String {
        if live.bonded && live.connected {
            return "Your strap is paired and sending data. Open Live for a real-time heart rate."
        }
        if live.connected, let hint = live.pairingHint { return hint }
        if live.connected { return "Connected. Finishing the secure pairing handshake…" }
        if live.bonded { return "Previously paired but not currently connected. Re-scan to reconnect." }
        return "No strap connected. Put your WHOOP nearby and tap Re-scan to pair."
    }

    private func batteryTone(_ pct: Double) -> StrandTone {
        if pct <= 15 { return .critical }
        if pct <= 30 { return .warning }
        return .positive
    }

    // MARK: - Backup & restore

    // MARK: - Experimental (WHOOP 5 / MG)

    private var experimentalCard: some View {
        SettingsSection(
            icon: "flask.fill",
            title: "Experimental · WHOOP 5 / MG",
            blurb: "Live heart rate already works on a WHOOP 5/MG strap. These probes go further and try to coax more out of it. They are guesses, off by default, and only ever touch a 5/MG strap — WHOOP 4.0 is never affected."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $puffinExperiments) {
                    Text("Try WHOOP 5/MG protocol probes")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("On a 5/MG connection NOOP will send a puffin realtime-stream request after the handshake, and log what comes back. If you have a 5/MG strap, turning this on and sharing your strap log helps map the protocol. No effect on WHOOP 4.0.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(StrandPalette.hairline)

                Toggle(isOn: $puffinCapture) {
                    Text("Record puffin frames to a file")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("Saves every raw 5/MG frame (with a timestamp and the live heart rate) to a JSON file you can share to help map the biometric layout. This only records frames the strap already sent — it never writes to your strap — so it is safe to leave on. Export the file and attach it to a protocol-mapping issue.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if live.puffinCaptureCount > 0 {
                    Text("\(live.puffinCaptureCount) frame\(live.puffinCaptureCount == 1 ? "" : "s") captured this session.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    HStack(spacing: 12) {
                        Button {
                            exportPuffinCaptures()
                        } label: {
                            Label("Export frames…", systemImage: "square.and.arrow.up")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StrandPalette.accent)

                        Button {
                            revealPuffinCaptures()
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.bordered)
                        .tint(StrandPalette.accent)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// Flush the in-flight capture, then copy it to a user-chosen location via a save panel.
    private func exportPuffinCaptures() {
        model.ble.flushPuffinCaptures()
        guard let src = live.puffinCaptureURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = src.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
        } catch {
            backupAlertTitle = "Export failed"
            backupAlertMessage = error.localizedDescription
            showBackupAlert = true
        }
    }

    /// Flush, then reveal the capture file in Finder so the user can grab it directly.
    private func revealPuffinCaptures() {
        model.ble.flushPuffinCaptures()
        guard let url = live.puffinCaptureURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var backupCard: some View {
        SettingsSection(
            icon: "externaldrive.fill",
            title: "Backup & restore",
            blurb: "Move all your NOOP data to another machine. Export saves everything — history, sleeps, workouts, settings — to a single file you can copy across; import replaces this Mac's data with a backup."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Button {
                        runExport()
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.up")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)
                    .disabled(backupBusy)

                    Button {
                        runImport()
                    } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(StrandPalette.accent)
                    .disabled(backupBusy)

                    if backupBusy { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(StrandPalette.textTertiary)
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                    Text("Importing overwrites everything currently on this Mac. Your old data is kept in a side file just in case. NOOP needs a relaunch for an import to take effect.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func runExport() {
        backupBusy = true
        Task {
            let result = await DataBackup.runExport(checkpoint: { await model.repo.checkpointForBackup() })
            handleBackup(result)
        }
    }

    private func runImport() {
        backupBusy = true
        Task {
            let result = await DataBackup.runImport()
            handleBackup(result)
        }
    }

    @MainActor
    private func handleBackup(_ result: DataBackup.BackupResult) {
        backupBusy = false
        switch result {
        case .cancelled:
            return
        case .exported(let url):
            backupAlertTitle = "Backup exported"
            backupAlertMessage = "Saved to \(url.lastPathComponent). Copy this file to your other Mac and use Import there to restore everything."
            showBackupAlert = true
        case .imported:
            backupAlertTitle = "Backup imported"
            backupAlertMessage = "Your data has been restored. Quit and reopen NOOP for it to take effect."
            showBackupAlert = true
        case .failure(let message):
            backupAlertTitle = "Backup problem"
            backupAlertMessage = message
            showBackupAlert = true
        }
    }

    // MARK: - About

    private var aboutCard: some View {
        SettingsSection(
            icon: "info.circle.fill",
            title: "About",
            blurb: "NOOP — all your data, none of the cloud."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("NOOP")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    StatePill("v\(AppChangelog.currentVersion)", tone: .neutral, showsDot: false)
                    Spacer()
                    Button {
                        showWhatsNew = true
                    } label: {
                        Label("What's new", systemImage: "sparkles").padding(.horizontal, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(StrandPalette.accent)
                }

                Text("A standalone companion for your WHOOP. Everything stays on this device — your history, your live stream, your numbers. Nothing is uploaded. NOOP is an independent, experimental project, not the WHOOP app.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Medical disclaimer
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StrandPalette.statusWarning)
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                    Text("NOOP is not a medical device. It is for informational and personal-insight purposes only and is not intended to diagnose, treat, cure or prevent any condition. Talk to a clinician for medical advice.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(StrandPalette.statusWarning.opacity(0.25), lineWidth: 1)
                )

                rowDivider

                VStack(alignment: .leading, spacing: 6) {
                    Text("Built on").strandOverline()
                    attribution(repo: "johnmiddleton12/my-whoop", note: "WHOOP 4.0 protocol")
                    attribution(repo: "b-nnett/goose", note: "WHOOP 5.0 protocol")
                }

                Text("Open-source BLE reverse-engineering work. Thank you.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func attribution(repo: String, note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            Text(repo)
                .font(StrandFont.mono(12))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("· \(note)")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Shared bits

    private var rowDivider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .padding(.vertical, 4)
    }
}

// MARK: - Section card

/// A grouped settings card: icon + title header, an explanatory blurb, then content.
private struct SettingsSection<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let blurb: LocalizedStringKey
    @ViewBuilder var content: () -> Content

    var body: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text(blurb)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }
}

// MARK: - Two-column form row

/// Label on the left, control on the right — the two-column form feel.
private struct FormRow<Control: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .frame(minHeight: 32)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Settings") {
    let model = AppModel()
    model.live.bonded = true
    model.live.connected = true
    model.live.batteryPct = 64
    return SettingsView()
        .environmentObject(model)
        .environmentObject(model.live)
        .environmentObject(model.profile)
        .frame(width: 720, height: 900)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif
