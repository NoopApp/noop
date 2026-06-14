import SwiftUI
import StrandDesign

// MARK: - Key-Metrics layout editor (#251)
//
// A Today-local sheet (no new nav destination — another lane owns the nav graph) for choosing which
// Key-Metric tiles show on the Control Center and in what order. Display-only: it edits the persisted
// `today.keyMetrics` layout string, never any stored metric. Enabled tiles render in the list's order;
// a toggle hides/shows a tile and the up/down chevrons reorder it. Reorder uses explicit chevrons rather
// than drag so it behaves identically on macOS and iOS without depending on List EditMode.

struct KeyMetricsEditorSheet: View {
    /// The persisted layout string (comma-joined enabled `KeyMetric` rawValues, in order). Bound straight
    /// to the Today screen's @AppStorage so an edit takes effect live and survives relaunch.
    @Binding var layoutRaw: String

    @Environment(\.dismiss) private var dismiss

    /// Working copy: the full ordered list with an enabled flag per tile. Enabled tiles come first in
    /// their saved order, then the disabled remainder in the default order — so toggling one on drops it
    /// at the end of the visible set, and the editor always lists every known tile exactly once.
    @State private var items: [Item]

    private struct Item: Identifiable {
        let metric: KeyMetric
        var enabled: Bool
        var id: String { metric.rawValue }
    }

    init(layoutRaw: Binding<String>) {
        _layoutRaw = layoutRaw
        let enabled = KeyMetricPrefs.decodeEnabled(layoutRaw.wrappedValue)
        let enabledSet = Set(enabled)
        // Enabled tiles first (saved order), then the rest in the canonical default order.
        var working = enabled.map { Item(metric: $0, enabled: true) }
        for m in KeyMetric.defaultOrder where !enabledSet.contains(m) {
            working.append(Item(metric: m, enabled: false))
        }
        _items = State(initialValue: working)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            // Each tile is its own frosted row, tinted by that metric's own accent, so the editor
            // reads like a stack of the cards it controls rather than a flat settings list.
            VStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item, at: index)
                }
            }
            footer
        }
        .padding(24)
        // A fixed 420pt suits the free-floating macOS window, but it overflows a 393pt iPhone, so
        // on iOS fill the presented sheet (matching the sibling sheets' #185 fix) and adopt detents.
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity)
        // A short list → open at .medium with .large a drag away; the grabber gives the top dismiss
        // affordance the sheet otherwise lacks (only a bottom Done today).
        .noopSheetPresentation(largeFirst: false)
        #endif
        .background(StrandPalette.surfaceOverlay)
    }

    // MARK: Rows

    private func row(_ item: Item, at index: Int) -> some View {
        let accent = accent(for: item.metric)
        return NoopCard(padding: 12, tint: item.enabled ? accent : nil) {
            HStack(spacing: 12) {
                // A per-metric accent dot ties the row to its Today tile; dims when the tile is off.
                Circle()
                    .fill(item.enabled ? accent : StrandPalette.textTertiary)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                // Show/hide toggle — an off tile is dimmed but stays listed so it can be re-enabled.
                Toggle(isOn: enabledBinding(at: index)) {
                    Text(item.metric.title)
                        .font(StrandFont.body)
                        .foregroundStyle(item.enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .accessibilityLabel("Show \(item.metric.title)")

                Spacer(minLength: 0)

                // Explicit reorder — robust on macOS + iOS without List EditMode/drag.
                Button {
                    move(from: index, to: index - 1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(index == 0 ? StrandPalette.textTertiary : StrandPalette.textSecondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .accessibilityLabel("Move \(item.metric.title) up")

                Button {
                    move(from: index, to: index + 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(index == items.count - 1 ? StrandPalette.textTertiary : StrandPalette.textSecondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(index == items.count - 1)
                .accessibilityLabel("Move \(item.metric.title) down")
            }
        }
    }

    /// The accent each metric carries on the Today grid — kept in sync with TodayView's tiles so a
    /// row's dot/wash matches the tile it toggles. Local to the editor (presentation only).
    private func accent(for metric: KeyMetric) -> Color {
        switch metric {
        case .charge:      return StrandPalette.accent
        case .effort:      return StrandPalette.effortColor
        case .rest:        return StrandPalette.metricPurple
        case .hrv:         return StrandPalette.metricPurple
        case .restingHr:   return StrandPalette.metricRose
        case .bloodOxygen: return StrandPalette.metricCyan
        case .respiratory: return StrandPalette.accent
        case .steps:       return StrandPalette.metricCyan
        case .weight:      return StrandPalette.accent
        case .calories:    return StrandPalette.metricAmber
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CONTROL CENTER").font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            Text("Edit Key Metrics")
                .font(StrandFont.rounded(24, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Choose which tiles show on your Control Center and reorder them with the arrows.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Reset") { resetToDefault() }
                .buttonStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityLabel("Reset Key Metrics to default")
            Spacer()
            Button("Done") {
                commit()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
            // At least one tile must stay visible — an empty grid reads as a bug, not a choice.
            .disabled(!items.contains { $0.enabled })
            .accessibilityLabel("Done editing Key Metrics")
        }
    }

    // MARK: Mutations

    private func enabledBinding(at index: Int) -> Binding<Bool> {
        Binding(
            get: { items[index].enabled },
            set: { items[index].enabled = $0 }
        )
    }

    private func move(from: Int, to: Int) {
        guard items.indices.contains(from), items.indices.contains(to) else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
    }

    private func resetToDefault() {
        items = KeyMetric.defaultOrder.map { Item(metric: $0, enabled: true) }
    }

    /// Persist the enabled tiles in their current order. Disabled tiles are simply omitted from the
    /// stored string — `KeyMetricPrefs.decodeEnabled` rebuilds the editor's disabled remainder from the
    /// default order on next open, so nothing is lost.
    private func commit() {
        layoutRaw = KeyMetricPrefs.encode(items.filter { $0.enabled }.map(\.metric))
    }
}

#if DEBUG
#Preview("Key-Metrics editor") {
    KeyMetricsEditorSheet(layoutRaw: .constant(""))
        .preferredColorScheme(.dark)
}
#endif
