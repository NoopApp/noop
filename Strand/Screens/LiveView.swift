import SwiftUI
import StrandDesign
import WhoopProtocol

/// Live — the connected strap in real time. Built on the shared design system
/// (ScreenScaffold chrome, StrandPalette, StrandFont) so it lines up pixel-for-pixel
/// with every other screen instead of the old standalone Milestone-1 layout.
struct LiveView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    /// Which strap the user is pairing — persists across launches. Drives which
    /// BLE service we scan for so a WHOOP 4.0 scan never hangs on a WHOOP 5 wrist.
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop4.rawValue
    private var selectedModel: WhoopModel { WhoopModel(rawValue: selectedModelRaw) ?? .whoop4 }

    /// Smoothed, spike-filtered live HR from AppModel (median over a short window).
    private var displayHR: Int? { model.bpm }
    private var activeConnection: Bool { live.connected && live.bonded }

    var body: some View {
        ScreenScaffold(title: "Live",
                       subtitle: "Your strap in real time — heart rate and frames as they arrive.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                connectionRow
                heartRateCard
                statusGrid
                if !live.bonded { modelPicker }
                controls
                logCard
            }
        }
        .onAppear { refreshLiveSession() }
        .onDisappear { model.stopRealtimeHR() }
        .onChange(of: live.bonded) { _ in refreshLiveSession() }
        .onChange(of: live.connected) { _ in refreshLiveSession() }
    }

    // MARK: - Connection

    private var connectionRow: some View {
        HStack {
            connectionPill
            Spacer()
        }
    }

    private var connectionPill: some View {
        let (label, color): (String, Color) =
            activeConnection ? ("Streaming", StrandPalette.accent)
            : live.connected ? ("Connected", StrandPalette.statusWarning)
            : live.bonded ? ("Paired · idle", StrandPalette.statusWarning)
            : ("Disconnected", StrandPalette.metricRose)
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(StrandPalette.surfaceRaised, in: Capsule())
    }

    // MARK: - Heart rate

    private var heartRateCard: some View {
        NoopCard {
            VStack(spacing: 6) {
                Text("HEART RATE").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(displayHR.map(String.init) ?? "—")
                    .font(.system(size: 96, weight: .semibold).monospacedDigit())
                    .foregroundStyle(displayHR == nil ? StrandPalette.textTertiary : StrandPalette.accent)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: displayHR)
                Text("bpm").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                if !live.rr.isEmpty {
                    Text("R-R: " + live.rr.suffix(4).map(String.init).joined(separator: " · ") + " ms")
                        .font(StrandFont.mono).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }

    // MARK: - Status tiles

    private var statusGrid: some View {
        HStack(spacing: NoopMetrics.gap) {
            stat("Battery", live.batteryPct.map { "\(Int($0))%" } ?? "—")
            stat("Last frame", live.lastFrameType ?? "—")
            stat("Last event", live.lastEvent ?? "—")
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(value).font(StrandFont.headline).monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Strap picker

    /// Pick the strap family before scanning. Hidden once bonded — by then we know
    /// what's on the wrist.
    private var modelPicker: some View {
        HStack(spacing: 10) {
            Text("Strap").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            SegmentedPillControl(
                WhoopModel.allCases,
                selection: Binding(
                    get: { selectedModel },
                    set: { selectedModelRaw = $0.rawValue }
                ),
                label: { $0.displayName }
            )
            Spacer()
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button { model.scan(model: selectedModel) } label: {
                Label(live.connected ? "Re-scan" : "Scan & Connect",
                      systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).tint(StrandPalette.accent)

            Button { model.buzz() } label: {
                Label("Buzz strap", systemImage: "waveform.path")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.bordered).tint(StrandPalette.accent)
            .disabled(!activeConnection)
            .help("Fire a test haptic buzz on the strap (requires an active strap connection)")

            Button(role: .destructive) { model.disconnect() } label: {
                Label("Disconnect", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .disabled(!live.connected)
        }
    }

    private func refreshLiveSession() {
        guard activeConnection else { return }
        model.startRealtimeHR()
        model.getBattery()
    }

    // MARK: - Strap log

    private var logCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("STRAP LOG").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(live.log.enumerated()), id: \.offset) { idx, line in
                                Text(line).font(StrandFont.mono)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                    }
                    .frame(height: 200)
                    .onChange(of: live.log.count) { _ in
                        if let last = live.log.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }
}
