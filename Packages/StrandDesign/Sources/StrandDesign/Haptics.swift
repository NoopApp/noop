import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Strand Haptics (the tactile sibling of the Motion tokens)
//
// One tasteful tactile vocabulary shared across the app, mirroring StrandMotion.
// iOS fires the Taptic engine; macOS is a no-op. Keep it SPARSE — confirmations and
// state landings only, never per-keystroke or per-frame (no buzz spam). The system
// already honours the user's Settings ▸ Sounds & Haptics master switch.

public enum StrandHaptic {
    case selection   // segmented-pill / tab switch / toggle — light, frequent-safe
    case commit      // a primary action succeeded (save workout, finish interval)
    case success     // a meaningful milestone (bond success, breathe session done)
    case warning     // a soft "not allowed / invalid"

    #if canImport(UIKit)
    // Generators are cheap to make; UIKit pools the engine. We don't retain selection
    // generators (tab/pill taps are bursty).
    fileprivate func fire() {
        switch self {
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .commit:    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .success:   UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:   UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
    #endif

    /// Fire this haptic now. No-op on macOS.
    public func play() {
        #if canImport(UIKit)
        fire()
        #endif
    }
}

public extension View {
    /// Declarative tap when `trigger` changes (iOS 17+ `.sensoryFeedback`; no-op below /
    /// on macOS). Use for value-driven landings: score reveal, bond success, refresh-done.
    @ViewBuilder
    func strandHaptic<V: Equatable>(_ haptic: StrandHaptic, trigger: V) -> some View {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            self.sensoryFeedback(trigger: trigger) { _, _ in haptic.sensory }
        } else { self }
        #else
        self
        #endif
    }
}

#if os(iOS)
@available(iOS 17.0, *)
private extension StrandHaptic {
    var sensory: SensoryFeedback {
        switch self {
        case .selection: return .selection
        case .commit:    return .impact(weight: .heavy)
        case .success:   return .success
        case .warning:   return .warning
        }
    }
}
#endif
