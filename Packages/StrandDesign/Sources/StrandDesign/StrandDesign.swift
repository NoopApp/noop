import SwiftUI
import Charts

/// Strand design system: palette, typography, motion, and signature components
/// (Recovery Ring, Strain Gauge, Hypnogram, Trend/Sparkline charts, Year heat
/// strip, cards, status chips). Dark-only, instrument-grade. See spec §9.
///
/// Token entry points:
/// - `StrandPalette` — every semantic color token (§9.1), recovery/strain sampling.
/// - `StrandFont` — the full type scale with tabular digits (§9.2).
/// - `StrandMotion` — spring presets + durations (§9.6).
public enum StrandDesign {
    public static let version = "0.1.0"
}

// MARK: - Availability-safe onChange

// The two-parameter `onChange(of:initial:_:)` (and its zero-parameter sibling)
// arrived in iOS 17 / macOS 14, which deprecated the single-parameter
// `onChange(of:perform:)`. NOOP ships a split deployment target — the iOS app is
// iOS 17 but the macOS app is macOS 13 — and the Strand/ + StrandDesign sources
// compile into BOTH. So a blind swap to the new closure form silences the iOS
// deprecation warning yet fails to compile on macOS 13 (the overload doesn't
// exist there). `onChangeCompat` bridges the two: it calls the modern form where
// available and the legacy form (un-deprecated on macOS 13) otherwise, so the
// single residual deprecation is acknowledged exactly once — here — instead of at
// every call site. Behaviour is identical to a direct `.onChange(of:)`.
public extension View {
    /// macOS-13-safe `onChange` that hands the closure the old and new values
    /// (matching the iOS 17 / macOS 14 two-parameter form).
    @ViewBuilder
    func onChangeCompat<V: Equatable>(
        of value: V,
        perform action: @escaping (_ oldValue: V, _ newValue: V) -> Void
    ) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.onChange(of: value) { oldValue, newValue in
                action(oldValue, newValue)
            }
        } else {
            self.legacyOnChange(of: value, perform: action)
        }
    }

    /// macOS-13-safe `onChange` for observers that don't read the value
    /// (matching the iOS 17 / macOS 14 zero-parameter form).
    func onChangeCompat<V: Equatable>(
        of value: V,
        perform action: @escaping () -> Void
    ) -> some View {
        onChangeCompat(of: value) { _, _ in action() }
    }
}

private extension View {
    /// The legacy single-parameter `onChange`, isolated so its deprecation is
    /// acknowledged once. The `@available` annotation marks it deprecated exactly
    /// where the modern overload takes over (iOS 17 / macOS 14), so no warning
    /// fires on the macOS-13 build that genuinely needs this path. The macOS-13
    /// overload only surfaces the new value, so it is passed as both arguments —
    /// safe because every NOOP call site reads only the new value.
    @available(iOS, introduced: 16.0, deprecated: 17.0)
    @available(macOS, introduced: 13.0, deprecated: 14.0)
    func legacyOnChange<V: Equatable>(
        of value: V,
        perform action: @escaping (_ oldValue: V, _ newValue: V) -> Void
    ) -> some View {
        self.onChange(of: value) { newValue in
            action(newValue, newValue)
        }
    }
}

// MARK: - Availability-safe Chart plot frame

public extension ChartProxy {
    /// macOS-13-safe resolver for the chart's plotting rectangle.
    ///
    /// `plotAreaFrame` was deprecated in iOS 17 / macOS 14 and renamed to
    /// `plotFrame` (which also became Optional). The renamed API doesn't exist on
    /// macOS 13, and these chart overlays compile into the macOS-13 target, so we
    /// resolve through the modern anchor where available and fall back to the
    /// legacy one otherwise. Returns the same non-optional `CGRect` the call sites
    /// already use; the deprecation is acknowledged once, here.
    func plotRect(in geometry: GeometryProxy) -> CGRect {
        if #available(iOS 17.0, macOS 14.0, *) {
            if let anchor = self.plotFrame {
                return geometry[anchor]
            }
            return .zero
        } else {
            return geometry[legacyPlotAreaFrame]
        }
    }

    /// Isolated access to the deprecated `plotAreaFrame` anchor so its deprecation
    /// is acknowledged exactly here and not at the overlay call sites.
    @available(iOS, introduced: 16.0, deprecated: 17.0)
    @available(macOS, introduced: 13.0, deprecated: 14.0)
    private var legacyPlotAreaFrame: Anchor<CGRect> {
        self.plotAreaFrame
    }
}
