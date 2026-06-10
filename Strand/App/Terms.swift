import Foundation

/// The Terms of Use the first-run gate presents. Bump `currentVersion` when the terms MATERIALLY
/// change (risk / liability / medical / affiliation wording) to re-prompt every user for a fresh
/// acknowledgment; leave it for typo fixes. Mirrored on Android by `NoopPrefs.TERMS_VERSION`. The
/// full text lives in `TERMS.md`, shipped with NOOP.
enum Terms {
    static let currentVersion = "1.0"

    /// The load-bearing points the user must accept on first launch — the plain-English summary of
    /// `TERMS.md` §1–§6. Kept identical to the Android `Terms.points`. Each is (headline, body).
    static let points: [(String, String)] = [
        ("Independent — not affiliated with WHOOP",
         "NOOP is an unofficial project — not affiliated with, endorsed by, or sponsored by WHOOP, Inc. \"WHOOP\" is their trademark, used only to name the hardware NOOP works with."),
        ("Using NOOP may breach WHOOP's Terms of Service",
         "Use it only with a device you own, to read your own data. Whether to use it — and any effect on your WHOOP account, subscription, device, or warranty — is your decision, and your risk alone."),
        ("Experimental — at your own risk",
         "NOOP talks to your strap's firmware over an unofficial, reverse-engineered protocol. There is a residual risk to the device, its data, and its connection to official services. You assume that risk."),
        ("Not a medical device, not medical advice",
         "Every metric is an unvalidated approximation. Don't use NOOP to diagnose, treat, or make any health decision. Always consult a qualified professional."),
        ("No warranty; liability limited",
         "NOOP is free and provided \"as is\", with no warranty. Liability is limited to the maximum extent the law that applies to you allows — and nothing here removes protections your local law won't let us remove."),
    ]
}
