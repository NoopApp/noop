import SwiftUI
import StrandDesign

// MARK: - Scoring guide
//
// "How your scores work" — the one honest explainer for NOOP's three daily scores
// (Charge, Effort, Rest) and the confidence labels. Presented as a sheet, mirroring
// WhatsNewView's presentation + dismiss + layout idiom: a fixed header with a close
// button, a scrollable column of cards, and a "Got it" footer. Reachable from
// Settings → About, the ⓘ on each Today score, and the one-time first-run card.
//
// All copy here is the single approved source of truth, shared verbatim across
// macOS / iOS / Android. Each score section is tinted with the SAME accent the rest
// of the app uses for that metric (Charge = recovery green, Effort = strain rose,
// Rest = sleep purple), so a glance maps a section to its tile.

/// The three score sections the guide can deep-link to. The raw value is used as the
/// ScrollViewReader anchor id. The Android port mirrors these case names exactly.
enum ScoreSection: String, CaseIterable, Identifiable {
    case charge
    case effort
    case rest

    var id: String { rawValue }

    /// The accent each section uses — matched to the Today tile / ring for continuity.
    var accent: Color {
        switch self {
        case .charge: return StrandPalette.accent          // recovery ring spark
        case .effort: return StrandPalette.strain066        // strain spark
        case .rest:   return StrandPalette.metricPurple     // sleep spark
        }
    }

    /// The Bevel colour world this score belongs to — drives the card tint, the sample
    /// gauge stroke and the scenic bloom, so each section reads as its own domain.
    var domain: DomainTheme {
        switch self {
        case .charge: return .charge
        case .effort: return .effort
        case .rest:   return .rest
        }
    }

    /// A representative sample fraction (0–1) for the section's illustrative gauge — a
    /// "what a strong day looks like" reading, purely decorative in the guide.
    var sampleFraction: Double {
        switch self {
        case .charge: return 0.82
        case .effort: return 0.64
        case .rest:   return 0.88
        }
    }

    /// The number shown inside the sample gauge (the 0–100 score the fraction maps to).
    var sampleNumber: String {
        "\(Int((sampleFraction * 100).rounded()))"
    }

    /// The SF Symbol for the section header (heart/spark · flame · moon).
    var icon: String {
        switch self {
        case .charge: return "heart.circle.fill"
        case .effort: return "flame.fill"
        case .rest:   return "moon.stars.fill"
        }
    }
}

struct ScoringGuideView: View {
    /// When set, the guide scrolls to (and briefly highlights) this section on appear —
    /// used by the ⓘ affordances on the Today screen so each opens at its own score.
    var initialSection: ScoreSection? = nil
    let onClose: () -> Void

    /// Drives the brief highlight pulse on the deep-linked section.
    @State private var highlighted: ScoreSection? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
                // A scenic Charge-tinted hero behind the title region sets the premium tone
                // the moment the guide opens — the same backdrop the Today rings float over.
                .background {
                    ScenicHeroBackground(domain: .charge, starCount: 28, fadesToBase: true)
                }
            Divider().overlay(StrandPalette.hairline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        introCard
                        scoreCard(.charge,
                                  headline: "Charge — how recovered are you?",
                                  body: "Led by your heart-rate variability (HRV) measured against your own personal baseline, plus resting heart rate, last night's Rest, breathing rate, and a skin-temperature signal (an early illness or overreach flag). Higher HRV versus your baseline means more Charge. NOOP needs a few nights to learn your baseline first — until then you'll see “Calibrating”.",
                                  vsWhoop: "Same core idea as WHOOP's Recovery % (HRV-led recovery), but our weighting and baseline maths are our own, and openly documented.")
                        scoreCard(.effort,
                                  headline: "Effort — how hard did your heart work?",
                                  body: "Your cardiovascular load. NOOP turns every second of heart rate into a training-impulse using heart-rate-reserve zones (Karvonen), weights time in harder zones more heavily (Edwards / Banister), and places it on a logarithmic 0–100 scale — so easy days sit low and an all-out day approaches 100, which stays genuinely rare. A long walk with little cardio still counts, through a steps / active-energy floor.",
                                  vsWhoop: "Same cardiovascular-load idea as WHOOP's Day Strain (0–21). We rescaled the top of the ladder from 21 to 100 so all three scores share one scale — the rungs didn't move, so a 100 is as rare as a 21.0 was.")
                        scoreCard(.rest,
                                  headline: "Rest — how restorative was your sleep?",
                                  body: "A blend of how long you slept versus your personal need (the biggest factor), how efficiently (asleep versus in bed), how much was restorative (deep + REM sleep), and how consistent your sleep and wake timing is.",
                                  vsWhoop: "Similar in spirit to WHOOP's Sleep Performance %; our composite is our own.")
                        confidenceCard
                        footerNote
                    }
                    .padding(20)
                }
                .onAppear { jump(to: initialSection, using: proxy) }
            }
            Divider().overlay(StrandPalette.hairline)
            footerBar
        }
        // Same sizing split as WhatsNewView: a fixed window on macOS, fill the presented
        // sheet on iOS so nothing runs off a narrow phone screen (#185).
        #if os(macOS)
        .frame(width: 560, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A long explainer scroll → open full-height, with a grabber for swipe-to-dismiss.
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR DAILY SCORES").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("How your scores work").font(StrandFont.rounded(26, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Charge · Effort · Rest").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Text("Got it").frame(minWidth: 120).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Cards

    private var introCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("THE THREE SCORES").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("NOOP gives you three daily scores — Charge, Effort and Rest — each on a 0–100 scale. They're built from your strap's raw signals using published, peer-reviewed sport science, and computed entirely on your device. They are NOT WHOOP's scores: we don't have WHOOP's private algorithms and don't pretend to. They aim at the same three questions using open science, so they'll usually track WHOOP's in direction, but won't match number-for-number — and that's the point.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The three accents as a quick legend, echoing the section colours below.
                HStack(spacing: 16) {
                    legendDot(.charge, "Charge")
                    legendDot(.effort, "Effort")
                    legendDot(.rest, "Rest")
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legendDot(_ section: ScoreSection, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(section.domain.color).frame(width: 8, height: 8)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// One colour-accented score section: a frosted, domain-tinted card carrying a sample
    /// BevelGauge of that world beside a tinted headline, the body, and an italic "vs WHOOP"
    /// line set off by a hairline rule. The gauge is illustrative — a "what a strong day reads
    /// like" preview in the section's own colour — so a glance maps a card to its Today ring.
    private func scoreCard(_ section: ScoreSection, headline: String, body: String, vsWhoop: String) -> some View {
        NoopCard(tint: section.domain.color) {
            VStack(alignment: .leading, spacing: 14) {
                // Header row — the sample gauge sits beside the tinted icon + headline.
                HStack(alignment: .center, spacing: 14) {
                    BevelGauge(
                        fraction: section.sampleFraction,
                        stops: section.domain.gradient.stops,
                        tipColor: section.domain.bright,
                        numberText: section.sampleNumber,
                        captionText: section.rawValue.capitalized,
                        diameter: 84,
                        lineWidth: 9,
                        showsLabel: true,
                        animatedFraction: section.sampleFraction,
                        bloomActive: true
                    )
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: section.icon)
                                .font(.system(size: 16))
                                .foregroundStyle(section.domain.color)
                                .accessibilityHidden(true)
                            Text(section.rawValue.capitalized)
                                .font(StrandFont.overline)
                                .tracking(StrandFont.overlineTracking)
                                .textCase(.uppercase)
                                .foregroundStyle(section.domain.color)
                        }
                        Text(headline).font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Text(body)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(StrandPalette.hairline)
                HStack(alignment: .top, spacing: 8) {
                    Text("vs WHOOP").font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(section.domain.color)
                        .padding(.top, 1)
                    Text(vsWhoop)
                        .font(StrandFont.footnote)
                        .italic()
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Deep-link highlight: a brief domain-tinted ring when arrived at via an ⓘ.
        .overlay(
            RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                .strokeBorder(section.domain.color, lineWidth: 2)
                .opacity(highlighted == section ? 1 : 0)
        )
        .animation(.easeOut(duration: 0.35), value: highlighted)
        .id(section.id)
    }

    private var confidenceCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("How sure is NOOP?  ·  Solid · Building · Calibrating")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                // The three labels as the same pills used elsewhere, in their honest order.
                HStack(spacing: 8) {
                    StatePill("Solid", tone: .positive, showsDot: true)
                    StatePill("Building", tone: .warning, showsDot: true)
                    StatePill("Calibrating", tone: .neutral, showsDot: true)
                }
                Text("Every score carries a small honesty label. Calibrating means NOOP is still learning your baseline, or doesn't have enough data yet. Building means there's enough to show, but it's thin. Solid means full inputs are present. When NOOP can't compute a score honestly, it shows nothing rather than a fake number.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footerNote: some View {
        Text("These are independent approximations from a consumer strap, built on open science — not medical advice, and not WHOOP's official scores.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - Deep-link

    /// Scroll to the requested section and pulse its highlight, then fade it.
    private func jump(to section: ScoreSection?, using proxy: ScrollViewProxy) {
        guard let section else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(section.id, anchor: .top)
            }
            highlighted = section
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if highlighted == section { highlighted = nil }
            }
        }
    }
}

#if DEBUG
#Preview("Scoring guide") {
    ScoringGuideView(initialSection: .effort, onClose: {})
        .preferredColorScheme(.dark)
}
#endif
