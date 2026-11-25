#!/bin/bash
# Compatibility check for the macOS 12 deployment target: what the BUILD does not see.
#
# The build already refuses an API newer than macOS 12 that is called without a guard. It does NOT
# catch the four things below, which are silent on the machine that builds (macOS 14+, where
# Perception delegates to Observation, KeyEquivalent is Equatable, every SF Symbol exists):
#
#   1. Forbidden tokens, outside `objekat/Shared/Compat/`: the Observation macros (@Observable,
#      @Bindable, @ObservationIgnored, `import Observation`, withObservationTracking), the two-parameter
#      `.onChange(of:)` (the compat layer's `onChangeCompat` instead), `.onKeyPress` (`onKeyPressCompat`),
#      `ContinuousClock` / `Task.sleep(for:)` (`CompatClock` / `Task.compatSleep`).
#   2. `KeyEquivalent` compared or switched on: it is Equatable only from macOS 14, so on 12 the
#      conformance does not exist at run time (`KeyCompat` compares the character instead).
#   3. SF Symbols newer than macOS 12 written as literals, checked against the symbol availability
#      table of THIS system (name_availability.plist). A line that goes through `CompatSymbols` /
#      `Image(compatSystemName:)` is the guarded form and is not read.
#   4. A `View` whose `body` reads a Perceptible object (EditViewModel, a `.shared` store, the synoptic
#      levels...) without `WithPerceptionTracking`: on 12 and 13 it would never refresh, silently.
#      This one is a HEURISTIC (it looks at what the struct declares and names, not at what the body
#      really reads), hence the exceptions below.
#
# It does not replace a run on a real macOS 12 (the Debug "Perceptible state was accessed" log is the
# safety net there), it makes the regressions that need no Mac 12 to be seen impossible to commit.
#
# Exit status: 0 = clean, 1 = at least one finding (tools/release.sh stops on it), 2 = cannot run.
#
# Usage:   tools/check_macos12_compat.sh [--quiet]
#
# EXCEPTIONS — kept short and each with its reason; never a blanket rule.
#   * One line: append the comment `// compat12-ok: <why>` to it (tokens, KeyEquivalent, symbols).
#   * One struct for the Perception heuristic: add `"File.swift:StructName"` to ALLOW_BODY below.
#
# Delete this script (and the Compat layer) the day the deployment target is >= 15.

set -euo pipefail
cd "$(dirname "$0")/.."

command -v python3 >/dev/null || { echo "check_macos12_compat: python3 is required" >&2; exit 2; }

QUIET=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Structs allowed to read a Perceptible object in an unwrapped body (File.swift:StructName), with why.
# (empty today: every view of the tree the heuristic flagged was wrapped instead.)
ALLOW_BODY=(
)

CHECK_QUIET="$QUIET" CHECK_ALLOW_BODY="$(printf '%s\n' "${ALLOW_BODY[@]+"${ALLOW_BODY[@]}"}")" \
exec python3 -I - <<'PY'
import json, os, re, subprocess, sys

ROOT = "objekat"
COMPAT_DIR = os.path.join(ROOT, "Shared", "Compat") + os.sep
quiet = os.environ.get("CHECK_QUIET") == "1"
allow_body = {l.split("#")[0].strip() for l in os.environ.get("CHECK_ALLOW_BODY", "").splitlines() if l.strip()}

files = []
for d, _, names in os.walk(ROOT):
    for n in names:
        if n.endswith(".swift"):
            files.append(os.path.join(d, n))
files.sort()
sources = {f: open(f, encoding="utf-8", errors="replace").read() for f in files}

findings = []   # (category, "file:line", text)
def add(cat, f, line, text): findings.append((cat, f"{f}:{line}", text.strip()))

def code_lines(f):
    """(number, line) of the lines that carry code: no pure comment, no `compat12-ok` marker."""
    for i, line in enumerate(sources[f].splitlines(), 1):
        s = line.strip()
        if s.startswith("//") or "compat12-ok" in line:
            continue
        # a trailing comment is not code either
        yield i, re.sub(r"\s//(?![/:]).*$", "", line) if " //" in line else line

# --------------------------------------------------------------------------- 1. tokens
TOKENS = [
    (r"@Observable\b", "@Observable (use @Perceptible)"),
    (r"@Bindable\b", "@Bindable (use @Perception.Bindable)"),
    (r"@ObservationIgnored\b", "@ObservationIgnored (use @PerceptionIgnored)"),
    (r"\bimport\s+Observation\b", "import Observation (use import Perception)"),
    (r"\bwithObservationTracking\b", "withObservationTracking (use withPerceptionTracking)"),
    (r"\.onChange\(of:[^{]*\)\s*\{\s*\w+\s*,\s*\w+\s+in\b", "two-parameter .onChange (use .onChangeCompat)"),
    (r"\.onChange\(of:[^{]*initial:", ".onChange(initial:) (use .onChangeCompat)"),
    (r"\.onKeyPress\(", ".onKeyPress (use .onKeyPressCompat)"),
    (r"\bContinuousClock\b", "ContinuousClock (use CompatClock)"),
    (r"\bTask\.sleep\(for:", "Task.sleep(for:) (use Task.compatSleep)"),
]
for f in files:
    if f.startswith(COMPAT_DIR):
        continue
    for i, line in code_lines(f):
        for rx, why in TOKENS:
            if re.search(rx, line):
                add("token", f, i, f"{why}: {line}")

# --------------------------------------------------------------------------- 2. KeyEquivalent
# Always: anything that names KeyEquivalent itself in a comparison / hashed collection.
KEY_ALWAYS = [
    r"\bKeyEquivalent\b[^;{]*(==|!=)",
    r"(==|!=)[^;{]*\bKeyEquivalent\b",
    r"\bSet<KeyEquivalent>|\[KeyEquivalent\b|\bDictionary<KeyEquivalent",
]
# Only in a file that handles the NATIVE `KeyPress` type (a `KeyPressCompat` carries a `KeyCompat`, whose `==`
# compares the character and is safe): `press.key == .upArrow`, `switch press.key`, `== .downArrow`...
KEY_NATIVE = [
    r"\b(press|keyPress|kp)\.key\b[^;{]*(==|!=)",
    r"(==|!=)[^;{]*\b(press|keyPress|kp)\.key\b",
    r"\bswitch\s+(press|keyPress|kp)\.key\b",
    r"(==|!=)\s*\.(upArrow|downArrow|leftArrow|rightArrow|deleteForward|pageUp|pageDown)\b",
]
for f in files:
    if f.startswith(COMPAT_DIR):
        continue
    lines = list(code_lines(f))
    native = any(re.search(r"\bKeyPress\b", l) for _, l in lines)
    for i, line in lines:
        for rx in KEY_ALWAYS + (KEY_NATIVE if native else []):
            if re.search(rx, line):
                add("key", f, i, f"KeyEquivalent compared/hashed (macOS 14+ only): {line}")
                break

# --------------------------------------------------------------------------- 3. SF Symbols
plist = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
symbols_ok = True
if os.environ.get("OBJ_COMPAT_SKIP_SYMBOLS") == "1":
    symbols_ok = False
    print("check_macos12_compat: SF symbol audit SKIPPED (OBJ_COMPAT_SKIP_SYMBOLS=1)", file=sys.stderr)
elif not os.path.exists(plist):
    print(f"check_macos12_compat: {plist} not found: cannot audit the SF symbols "
          "(set OBJ_COMPAT_SKIP_SYMBOLS=1 to skip on purpose)", file=sys.stderr)
    sys.exit(2)
if symbols_ok:
    data = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", plist],
                                     capture_output=True, check=True).stdout)
    year_macos = {y: v.get("macOS", "0") for y, v in data["year_to_release"].items()}
    newer = {}   # name -> macOS version, for the symbols that need 13+
    for name, year in data["symbols"].items():
        v = year_macos.get(year, "0")
        if int(v.split(".")[0]) >= 13:
            newer[name] = v
    LINE_HINT = re.compile(r"systemName|systemImage|systemSymbolName|\bsymbol\b|Icon\b|icon", re.I)
    LIT = re.compile(r'"([a-z][a-z0-9]*(?:\.[a-z0-9]+)+|[a-z][a-z0-9]*)"')
    GUARDED = re.compile(r"CompatSymbols|compatSystemName")
    for f in files:
        if f.startswith(COMPAT_DIR):
            continue
        for i, line in code_lines(f):
            if GUARDED.search(line) or not LINE_HINT.search(line):
                continue
            for m in LIT.finditer(line):
                if m.group(1) in newer:
                    add("symbol", f, i,
                        f'SF Symbol "{m.group(1)}" needs macOS {newer[m.group(1)]} '
                        f"(wrap it with CompatSymbols.name(_, fallback:)): {line}")

# --------------------------------------------------------------------------- 4. Perception
# The Perceptible classes: the type that follows an `@Perceptible` attribute.
perceptible = set()
for f, s in sources.items():
    for m in re.finditer(r"@Perceptible\b", s):
        c = re.search(r"\bclass\s+(\w+)", s[m.end():m.end() + 300])
        if c:
            perceptible.add(c.group(1))
if not perceptible:
    print("check_macos12_compat: no @Perceptible class found: the Perception audit has nothing to look for", file=sys.stderr)
    sys.exit(2)
cls = "|".join(sorted(perceptible))

def match_brace(s, i):
    d = 0
    while i < len(s):
        c = s[i]
        if c == "{": d += 1
        elif c == "}":
            d -= 1
            if d == 0: return i
        i += 1
    return -1

STRUCT = re.compile(r"^[ \t]*(?:(?:private|fileprivate|public|internal)\s+)?struct\s+(\w+)[^{\n]*:\s*[^{\n]*\bView\b[^{\n]*\{", re.M)
for f in files:
    if f.startswith(COMPAT_DIR):
        continue
    s = sources[f]
    for m in STRUCT.finditer(s):
        end = match_brace(s, m.end() - 1)
        if end < 0:
            continue
        text = s[m.end() - 1:end]
        b = re.search(r"\bvar body: some View\s*\{(\s*WithPerceptionTracking)?", text)
        if not b or b.group(1):
            continue                      # no body of its own, or already wrapped
        name = m.group(1)
        if f"{os.path.basename(f)}:{name}" in allow_body:
            continue
        reads = sorted(set(re.findall(r"\b(?:let|var)\s+(\w+)\s*:\s*(?:" + cls + r")\b", text)))
        reads += sorted(set(x + ".shared" for x in re.findall(r"\b(" + cls + r")\.shared\b", text)))
        reads += sorted(set(re.findall(r"@Environment\(\\\.(\w*[Ll]evels?\w*|synoptic\w*)\)", text)))
        if reads:
            line = s.count("\n", 0, m.start()) + 1
            add("perception", f, line,
                f"struct {name}: its body is not wrapped in WithPerceptionTracking but it holds/reads "
                f"{', '.join(reads)}")

# --------------------------------------------------------------------------- report
titles = {
    "token": "Forbidden tokens (the target is 12: Observation / newer SwiftUI)",
    "key": "KeyEquivalent compared or hashed (not Equatable before macOS 14)",
    "symbol": "SF Symbols newer than macOS 12, unguarded",
    "perception": "Views reading a Perceptible object without WithPerceptionTracking (heuristic)",
}
if findings:
    for cat in ("token", "key", "symbol", "perception"):
        items = [x for x in findings if x[0] == cat]
        if not items:
            continue
        print(f"\n== {titles[cat]}: {len(items)}")
        for _, where, text in items:
            print(f"  {where}  {text}")
    print(f"\ncheck_macos12_compat: {len(findings)} finding(s). "
          "Fix them, or mark a line `// compat12-ok: <why>` / list a struct in ALLOW_BODY with its reason.")
    sys.exit(1)

if not quiet:
    print(f"check_macos12_compat: OK ({len(files)} files; {len(perceptible)} Perceptible classes"
          f"{'' if symbols_ok else '; SF symbols NOT audited'})")
PY
