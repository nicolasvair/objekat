#!/usr/bin/env python3
"""A maintenance tool for the translation catalogue (`objekat/Resources/Localizable.xcstrings`).

The catalogue IS THE AUTHORITY: Xcode edits it, and this script only reads it back and pours one
language into it in one go, which no interface makes pleasant for three hundred keys.

    python3 tools/i18n/xcstrings.py check              # incomplete keys, by language
    python3 tools/i18n/xcstrings.py dump fr            # one language's values, as JSON
    python3 tools/i18n/xcstrings.py set es < es.json   # pours in / updates one language
    python3 tools/i18n/xcstrings.py orphans            # catalogue keys absent from the code

`set` reads a JSON object { "key": "value" } on standard input and overwrites only what it
brings: a key absent from the JSON keeps what the catalogue says about it.
"""
import json, os, re, subprocess, sys

CATALOG = "objekat/Resources/Localizable.xcstrings"
LANGUAGES = ["fr", "en", "es"]


def load():
    with open(CATALOG, encoding="utf-8") as f:
        return json.load(f)


def save(cat):
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(cat, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


def value(entry, lang):
    unit = entry.get("localizations", {}).get(lang, {}).get("stringUnit")
    return unit.get("value") if unit else None


SPECIFIER = re.compile(r"%(?:(\d+)\$)?[-+ #0]*[\d.*]*(?:hh|h|ll|l|q|L|z|t|j)?([@dioupxXeEfgGaAcsSn%])")


def specifiers(text):
    """A format's conversions, in the order `String(format:)` will consume them. A
    translation that has not got EXACTLY the same ones reads the argument stack askew — it is the
    only translation defect that brings the app down rather than showing nonsense."""
    out = []
    for index, kind in SPECIFIER.findall(text or ""):
        if kind == "%":
            continue
        out.append(f"{index}${kind}" if index else kind)
    return out


def cmd_check(cat):
    bad = 0
    source = cat.get("sourceLanguage", "fr")
    for lang in LANGUAGES:
        missing = sorted(k for k, e in cat["strings"].items() if value(e, lang) is None)
        if missing:
            bad = 1
            print(f"{lang} — {len(missing)} key(s) with no translation:")
            for k in missing:
                print(f"    {k}")
        if lang == source:
            continue
        for k, e in sorted(cat["strings"].items()):
            here, there = value(e, lang), value(e, source)
            if here is None or there is None:
                continue
            if specifiers(here) != specifiers(there):
                bad = 1
                print(f"{lang} — {k}: formats {specifiers(here)} instead of {specifiers(there)}")
    if not bad:
        print(f"{len(cat['strings'])} keys, {len(LANGUAGES)} languages, nothing missing.")
    return bad


def cmd_dump(cat, lang):
    out = {k: value(e, lang) for k, e in sorted(cat["strings"].items())}
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


def cmd_set(cat, lang):
    incoming = json.load(sys.stdin)
    unknown = sorted(set(incoming) - set(cat["strings"]))
    if unknown:
        print("keys unknown to the catalogue: " + ", ".join(unknown), file=sys.stderr)
        return 1
    for key, text in incoming.items():
        entry = cat["strings"][key]
        entry.setdefault("extractionState", "manual")
        entry.setdefault("localizations", {})[lang] = {
            "stringUnit": {"state": "translated", "value": text}
        }
    save(cat)
    print(f"{len(incoming)} keys laid down in {lang}.")
    return 0


def cmd_orphans(cat):
    """The keys no `L(...)` / `Ln(...)` claims any more. The `.one` / `.other` forms are
    attached to their base key, which the code cites with no suffix."""
    used = set()
    # `L("…")` / `Ln("…")`, the keys passed as a parameter (`titleKey: "…"`), and — as a last
    # net — every string in the code that has the SHAPE of a key (`a.b.c`, lowercase and dotted).
    # That last pattern catches what the first two do not see: a key chosen by a
    # ternary inside the `L(...)`, or filed in an array. It is deliberately
    # wide — `orphans` only suggests, and a live key reported dead costs more
    # than a dead key forgotten.
    for pattern in (r'\bLn?\("[^"]+"', r'[Kk]ey[ :=A-Za-z]*"[a-z][A-Za-z0-9_.]+"',
                    r'"[a-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+"'):
        grep = subprocess.run(["grep", "-rhoE", pattern, "objekat", "--include=*.swift"],
                              capture_output=True, text=True)
        for line in grep.stdout.splitlines():
            used.add(line.split('"')[1])
    orphans = sorted(k for k in cat["strings"]
                     if k not in used and re.sub(r"\.(one|other)$", "", k) not in used)
    for k in orphans:
        print(k)
    return 0


def main():
    if not os.path.exists(CATALOG):
        print(f"{CATALOG} not found — run from the root of the repository.", file=sys.stderr)
        return 2
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    cat = load()
    # Plain `if`s and not a `match`: the python3 macOS ships is a 3.9, which parses no
    # `match` at all — and a SyntaxError kills the WHOLE file, not just this line.
    command = args[0]
    if command == "check":   return cmd_check(cat)
    if command == "dump":    return cmd_dump(cat, args[1])
    if command == "set":     return cmd_set(cat, args[1])
    if command == "orphans": return cmd_orphans(cat)
    print(f"unknown command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
