#!/usr/bin/env python3
"""Merge translation fragments into the string catalogs.

Usage: scripts/l10n_merge.py build/l10n/*.json
Each fragment: {"<Target>": {"<Russian key>": "<English>", ...}, ...}. Keys are exactly what the code
uses: the Russian text with %lld (Int), %@ (String) and %lf (Double) for interpolations. The Russian text
is the key, so a missing translation shows Russian, never a blank.
"""
import json, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
merged: dict[str, dict[str, str]] = {}
for arg in sys.argv[1:]:
    for target, strings in json.loads(pathlib.Path(arg).read_text()).items():
        merged.setdefault(target, {}).update(strings)

for target, strings in merged.items():
    path = root / "Sources" / target / "Resources" / "Localizable.xcstrings"
    catalog = json.loads(path.read_text()) if path.exists() else {"sourceLanguage": "ru", "strings": {}, "version": "1.0"}
    for key, en in strings.items():
        if not key or not en or key == en:
            continue
        entry = catalog["strings"].setdefault(key, {})
        entry.setdefault("localizations", {})["en"] = {"stringUnit": {"state": "translated", "value": en}}
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(f"{target}: {len(catalog['strings'])} keys")
