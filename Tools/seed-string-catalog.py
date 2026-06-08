#!/usr/bin/env python3
"""Build Strand/Resources/Localizable.xcstrings (English US base) from the
.stringsdata files xcodebuild emits during a build. Each extracted key becomes
an `en` localization whose value is the key itself (the authored English text).

One-off tooling used to seed the String Catalog; safe to re-run.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

CATALOG = Path("Strand/Resources/Localizable.xcstrings")


def find_stringsdata() -> list[Path]:
    derived = Path.home() / "Library/Developer/Xcode/DerivedData"
    out: list[Path] = []
    for root, _dirs, files in os.walk(derived):
        if "Strand-" not in root:
            continue
        for f in files:
            if f.endswith(".stringsdata"):
                out.append(Path(root) / f)
    return out


def load_stringsdata(path: Path) -> dict:
    """stringsdata is an Apple binary property list variant; plutil reads it
    reliably where plistlib does not. Convert to JSON and parse that."""
    try:
        raw = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", str(path)],
            capture_output=True, check=True,
        ).stdout
        return json.loads(raw)
    except Exception:
        return {}


def main() -> int:
    keys: dict[str, str] = {}  # key -> comment
    for sd in find_stringsdata():
        data = load_stringsdata(sd)
        tables = data.get("tables", {})
        entries = tables.get("Localizable")
        if not entries:
            continue
        for e in entries:
            key = e.get("key")
            if not key:
                continue
            comment = e.get("comment") or ""
            # Keep the first non-empty comment we see for a key.
            if key not in keys or (not keys[key] and comment):
                keys[key] = comment

    if not keys:
        print("No Localizable strings found in stringsdata.", file=sys.stderr)
        return 1

    # Merge into any existing catalog so translations added for other languages
    # (and hand-written comments) are preserved — only the English base is seeded.
    existing: dict = {}
    if CATALOG.exists():
        try:
            existing = json.loads(CATALOG.read_text())
        except Exception:
            existing = {}
    strings: dict[str, dict] = dict(existing.get("strings", {}))

    added = 0
    for key in sorted(keys):
        entry = strings.get(key, {})
        localizations = entry.setdefault("localizations", {})
        if "en" not in localizations:
            localizations["en"] = {
                "stringUnit": {"state": "translated", "value": key}
            }
            added += 1
        comment = keys[key]
        if comment and "comment" not in entry:
            entry["comment"] = comment
        strings[key] = entry

    catalog = {
        "sourceLanguage": existing.get("sourceLanguage", "en"),
        "strings": strings,
        "version": existing.get("version", "1.0"),
    }

    CATALOG.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
    print(f"Catalog now has {len(strings)} strings ({added} newly seeded).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
