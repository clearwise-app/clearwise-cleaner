#!/usr/bin/env python3
"""Write a Russian .strings table from a string catalog.

Usage: scripts/l10n_ru_strings.py Sources/<Target>/Resources/Localizable.xcstrings <out>/ru.lproj/Localizable.strings
Russian is the catalog's source language, so the keys are the Russian text and the catalog carries no ru
values. The app bundle still needs a real ru.lproj table: with English as the development region (the
fallback for every other system language), SwiftUI resolves a Text whose preferred .lproj has no table
from the development table — English — instead of from the key. build_app.sh runs this for every catalog.
"""
import json, pathlib, sys

src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
catalog = json.loads(src.read_text())


def quote(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


lines = []
for key, entry in sorted(catalog["strings"].items()):
    unit = entry.get("localizations", {}).get("ru", {}).get("stringUnit", {})
    value = unit.get("value") or key
    lines.append(f"{quote(key)} = {quote(value)};")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"{out}: {len(lines)} strings")
