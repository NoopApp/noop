# Security Policy

## Scope

NOOP is a fully offline app — it has no servers, no accounts, no cloud sync, and no network communication (except the optional AI Coach feature, which uses a user-supplied API key). The attack surface is limited to:

- **Bluetooth Low Energy** — communication with the WHOOP strap
- **Local SQLite database** — all data stored on-device
- **File imports** — WHOOP CSV exports and Apple Health ZIP files

## Reporting a Vulnerability

If you find a security issue, please **do not open a public GitHub issue**.

Report privately by emailing the details to the address in [docs/DONATIONS.md](docs/DONATIONS.md), or by opening a [GitHub Security Advisory](https://github.com/NoopApp/noop/security/advisories/new).

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Any suggested fix (optional)

You will receive a response within 7 days. If the issue is confirmed, a fix will be prioritised and you will be credited in the release notes (unless you prefer to remain anonymous).

## Supported Versions

Only the latest release is supported with security fixes.

## Out of Scope

- Vulnerabilities requiring physical access to an unlocked device
- Issues in third-party dependencies (report upstream)
- The WHOOP strap firmware itself
