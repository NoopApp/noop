import Foundation

// MARK: - Sport → SF Symbol
//
// Maps a free-text sport/activity name to an SF Symbol name. Shared so a sport
// reads identically everywhere it appears — the Workouts list, per-sport
// breakdown cards, and the Today HR overview's workout annotations.

/// The SF Symbol that best represents a free-text `sport` label (case-insensitive,
/// substring-matched). Falls back to `figure.mixed.cardio` for anything unrecognised.
public func sportSymbol(_ sport: String) -> String {
    let s = sport.lowercased()
    switch true {
    case s.contains("run"):                         return "figure.run"
    case s.contains("walk") || s.contains("hike"):  return "figure.walk"
    case s.contains("cycl") || s.contains("bike") || s.contains("ride"):
                                                     return "figure.outdoor.cycle"
    case s.contains("swim"):                        return "figure.pool.swim"
    case s.contains("row"):                         return "figure.rower"
    case s.contains("yoga"):                        return "figure.yoga"
    case s.contains("strength") || s.contains("weight") || s.contains("lift"):
                                                     return "dumbbell.fill"
    case s.contains("box"):                         return "figure.boxing"
    case s.contains("hiit") || s.contains("functional"):
                                                     return "figure.highintensity.intervaltraining"
    case s.contains("elliptical"):                  return "figure.elliptical"
    case s.contains("ski"):                         return "figure.skiing.downhill"
    case s.contains("tennis"):                      return "figure.tennis"
    case s.contains("golf"):                        return "figure.golf"
    case s.contains("soccer") || s.contains("football"):
                                                     return "figure.soccer"
    case s.contains("basketball"):                  return "figure.basketball"
    case s.contains("dance"):                       return "figure.dance"
    case s.contains("climb"):                       return "figure.climbing"
    case s.contains("pilates"):                     return "figure.pilates"
    case s.contains("meditat"):                     return "figure.mind.and.body"
    default:                                        return "figure.mixed.cardio"
    }
}
