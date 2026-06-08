import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for an active live-HR session — shown on the Lock Screen and in the Dynamic Island.
struct NOOPLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            HStack(spacing: 14) {
                Image(systemName: "waveform.path.ecg")
                    .font(.title2)
                    .foregroundStyle(StrandPalette.statusCritical)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title)
                        .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                    Text("\(context.state.bpm.map(String.init) ?? "–") bpm")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Spacer()
                if let r = context.state.recovery {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Recovery").font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                        Text("\(r)%").font(.headline).foregroundStyle(StrandPalette.textPrimary)
                    }
                }
            }
            .padding()
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.state.bpm.map(String.init) ?? "–")", systemImage: "heart.fill")
                        .foregroundStyle(StrandPalette.statusCritical)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let r = context.state.recovery {
                        Text("\(r)%").font(.headline)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.title).font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
            } compactTrailing: {
                Text("\(context.state.bpm.map(String.init) ?? "–")")
            } minimal: {
                Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
            }
        }
    }
}
