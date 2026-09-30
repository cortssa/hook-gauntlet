#!/usr/bin/env bash
#
# setup-deps.sh - a v4 hook project's dependencies in one command: its remappings.txt and foundry.toml pointed at the kit
# it vendors (QUICKSTART.md step 7b), then `forge build`.
#
# The problem it solves: step 7b's recipe was a block of text, and a reader who did not follow it copied the kit's
# libraries into the project by hand instead - measured (the local-model walk, 2026-09-30): about 17 minutes of `rm -rf lib &&
# cp -r ...`, two forge-std copies, five rewrites of remappings.txt. This script writes the lines the recipe prescribes for
# the layout it finds, and NEVER copies a library into the project: every dependency is reached through the kit.
#
# The kit: the first `lib/hook-gauntlet` found walking up from the project - in the project itself (the flat layout,
# `<kit>` = lib/hook-gauntlet) or in a directory above it (a proj/ beside lib/, `<kit>` = ../lib/hook-gauntlet) - or
# --kit PATH. `<kit>` is always written RELATIVE to the project, so the project stays portable; when it starts with
# `../`, forge needs `allow_paths = ["<kit>/foundry-kit"]` and gets it.
# remappings.txt: the kit's own foundry-kit/v4/remappings.txt with `<kit>/foundry-kit/v4/` prefixed (`../src/` becomes
# `<kit>/foundry-kit/src/`), less the periphery's three (v4-periphery/, permit2/, openzeppelin-contracts/: step 7b says
# they matter only with the periphery; a line of yours for them is kept), plus `gauntlet-v4/=<kit>/foundry-kit/v4/src/`.
# A line of yours with one of those prefixes is replaced in place (a second one is removed); every other line is kept,
# and named when its target does not exist.
# foundry.toml, [profile.default] only: `libs = []`, `solc_version = "0.8.26"`, `evm_version = "cancun"`, `allow_paths`
# (for `../`: your other entries kept, entries under `<kit>/foundry-kit` replaced by that one), the "manager" compiler
# profile and the PoolManager's compilation restriction through `<kit>`. A key that is there is replaced in place, a key
# that is not is added under the table's header, anything else in the file is left as it is; a line in ANOTHER table
# that still names the project's own lib/ is named, not changed. No foundry.toml: one is written with those lines.
#
# Usage:   scripts/setup-deps.sh [--kit PATH] [--dry-run | --check] <proj>
#   --kit PATH   the kit to point at, instead of the lib/hook-gauntlet found walking up from <proj>
#   --dry-run    print every line it would write and the build it would run; write nothing, build nothing
#   --check      write nothing, print one line: exit 0 set up, 1 not set up (what doctor.sh <proj> reads)
# Escape:  SETUP_DEPS_KEEP_LIB=1 - go ahead over a project that has its own lib/forge-std or lib/v4-core (they are kept,
#          and not what the remappings reach)
# Output:  one line per line written or changed - `setup-deps: remappings.txt: + <line>` (added), `~ <line>   (was: <old>)`
#          (changed), `- <line>   (...)` (removed); `setup-deps: foundry.toml [profile.default]: ...` the same way - or
#          `<file>: nothing to change`; then `setup-deps: running: forge build   (in <proj>)`, forge's output, and
#          `setup-deps: DONE - ...` or `setup-deps: forge build FAILED (rc N) - ...`.
# Exit:    0 set up and `forge build` green (--dry-run: printed; --check: already set up); 1 the files are written and the
#          build failed (--check: not set up); 2 REFUSED, nothing written - the reason on one line, with the way out: the
#          project's own lib/forge-std or lib/v4-core, no kit in reach, a kit without Uniswap's sources
#          (scripts/install-v4.sh), a project inside the kit, remappings set in foundry.toml's [profile.default], a .env
#          that sets a forge variable, bad arguments.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/forge-env.sh
. "$HERE/lib/forge-env.sh" || { echo "setup-deps: $HERE/lib/forge-env.sh is missing"; exit 2; }

refuse() { echo "setup-deps: REFUSED - $*"; exit 2; }

ARGS=("$@")
KITARG="" MODE=run PROJARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kit) [ $# -ge 2 ] || refuse "--kit has no value."; KITARG="$2"; shift 2 ;;
    --dry-run) MODE=dry; shift ;;
    --check) MODE=check; shift ;;
    -*) refuse "unknown argument '$1'." ;;
    *) [ -z "$PROJARG" ] || refuse "one project, not '$PROJARG' and '$1'."; PROJARG="$1"; shift ;;
  esac
done
[ -n "$PROJARG" ] || refuse "no project: scripts/setup-deps.sh [--kit PATH] [--dry-run | --check] <proj>"
[ -d "$PROJARG" ] || refuse "'$PROJARG' is not a directory."
# forge reads its configuration from the environment too: removed before anything is written (a build is run)
if [ "$MODE" = run ]; then forge_env_clean setup-deps "" "$0" ${ARGS[@]+"${ARGS[@]}"}; fi
PROJ="$(cd "$PROJARG" && pwd)"

# ---------------------------------------------------------------------------- the kit, and <kit> relative to the project
relpath() { # relpath <from dir> <to dir>, both absolute: the path from the first to the second
  local common="$1" up="" rest
  while [ "$2" != "$common" ] && [ "${2#"$common"/}" = "$2" ]; do
    [ "$common" = / ] && break
    common="$(dirname "$common")"; up="../$up"
  done
  if [ "$2" = "$common" ]; then rest=""; elif [ "$common" = / ]; then rest="${2#/}"; else rest="${2#"$common"/}"; fi
  rest="${up}${rest}"; printf '%s\n' "${rest%/}"
}
if [ -n "$KITARG" ]; then
  [ -d "$KITARG" ] || refuse "--kit '$KITARG' is not a directory."
  KITABS="$(cd "$KITARG" && pwd)"
  KITREL="$(relpath "$PROJ" "$KITABS")"
else
  d="$PROJ" up="" KITABS=""
  while :; do
    if [ -d "$d/lib/hook-gauntlet" ]; then KITABS="$(cd "$d/lib/hook-gauntlet" && pwd)"; KITREL="${up}lib/hook-gauntlet"; break; fi
    [ "$d" = / ] && break
    d="$(dirname "$d")"; up="../$up"
  done
  [ -n "$KITABS" ] || refuse "$PROJ is outside the kit's reach: no lib/hook-gauntlet in it or in any directory above it. Vendor the kit there (a submodule or a copy: QUICKSTART.md step 7b), or say where it is with --kit PATH."
fi
case "$PROJ/" in "$KITABS"/*) refuse "$PROJ is inside the kit ($KITABS): the kit's own modules keep their own foundry.toml. Point a project of yours at it." ;; esac
[ -f "$KITABS/foundry-kit/v4/remappings.txt" ] && [ -d "$KITABS/foundry-kit/src" ] \
  || refuse "$KITABS is not the kit: no foundry-kit/v4/remappings.txt or foundry-kit/src there."
[ -f "$KITABS/foundry-kit/v4/lib/v4-core/src/PoolManager.sol" ] \
  || refuse "the kit at $KITABS has no foundry-kit/v4/lib/v4-core: Uniswap's sources are not installed there. Run, from the kit: scripts/install-v4.sh foundry-kit/v4 (network; offline: V4_LOCAL_SRC=<dir with the clones>, QUICKSTART.md step 3), then this again."

# ---------------------------------------------------------------------------- the project's own copies of the kit's libraries
own=0
for x in forge-std v4-core; do
  if [ -e "$PROJ/lib/$x" ]; then
    if [ "${SETUP_DEPS_KEEP_LIB:-}" = 1 ]; then
      echo "setup-deps: SETUP_DEPS_KEEP_LIB=1 - $PROJ/lib/$x kept; the remappings below reach the kit's, not it"
    else
      echo "setup-deps: $PROJ/lib/$x exists - a copy of the kit's? remove it or SETUP_DEPS_KEEP_LIB=1"; own=1
    fi
  fi
done
[ "$own" = 0 ] || { echo "setup-deps: REFUSED - nothing written (the kit's libraries are reached through $KITREL, never copied into the project)"; exit 2; }
if [ "$MODE" = run ] && ! forge_dotenv_check setup-deps "$PROJ"; then echo "setup-deps: REFUSED - nothing written, nothing built"; exit 2; fi

# ---------------------------------------------------------------------------- remappings.txt: what the kit's module remaps, through <kit>
WANT_P=() WANT_L=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"; [ -n "$line" ] || continue
  case "$line" in \#*) continue ;; esac
  p="${line%%=*}"; t="${line#*=}"
  case "$p" in v4-periphery/ | permit2/ | openzeppelin-contracts/) continue ;; esac
  case "$t" in ../src/*) t="$KITREL/foundry-kit/src/${t#../src/}" ;; *) t="$KITREL/foundry-kit/v4/$t" ;; esac
  WANT_P+=("$p"); WANT_L+=("$p=$t")
done < "$KITABS/foundry-kit/v4/remappings.txt"
WANT_P+=("gauntlet-v4/"); WANT_L+=("gauntlet-v4/=$KITREL/foundry-kit/v4/src/")
# the four a v4 hook's build cannot do without must be there; the others are written as the kit's module writes them
# (its ds-test/ names a directory the forge-std v4-core pins no longer has - measured 2026-09-30, and harmless)
for l in "${WANT_L[@]}"; do
  t="${l#*=}"
  case "${l%%=*}" in v4-core/ | forge-std/ | gauntlet-kit/ | gauntlet-v4/) ;; *) continue ;; esac
  [ -d "$PROJ/$t" ] || refuse "the kit at $KITABS lacks ${t#"$KITREL"/}, which the remapping '$l' names (a submodule of v4-core missing? V4_FORCE=1 scripts/install-v4.sh foundry-kit/v4)."
done

TMPD="$(mktemp -d)" || refuse "no temporary directory."
trap 'rm -rf "$TMPD"' EXIT
changes=0
say() { # say <file> <what>: one line written or changed
  changes=$((changes + 1))
  if [ "$MODE" = dry ]; then echo "setup-deps: dry-run - $1: $2"; elif [ "$MODE" = run ]; then echo "setup-deps: $1: $2"; fi
}
idx_of() { local i; for i in "${!WANT_P[@]}"; do [ "${WANT_P[$i]}" = "$1" ] && { echo "$i"; return 0; }; done; return 1; }
R="$PROJ/remappings.txt"; RN="$TMPD/remappings.txt"; : > "$RN"
done_p=" "
if [ -f "$R" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    p="${line%%=*}"
    if [ -n "$line" ] && [ "$line" != "$p" ] && i="$(idx_of "$p")"; then
      case "$done_p" in *" $p "*) say remappings.txt "- $line   (a second $p line)"; continue ;; esac
      done_p="$done_p$p "
      [ "$line" = "${WANT_L[$i]}" ] || say remappings.txt "~ ${WANT_L[$i]}   (was: $line)"
      printf '%s\n' "${WANT_L[$i]}" >> "$RN"
    else
      printf '%s\n' "$line" >> "$RN"
      # a line of yours whose target is not there: named (it is yours to fix), never changed
      case "$line" in "" | \#* | *:*=*) ;; *=*)
        t="${line#*=}"; case "$t" in /*) tp="$t" ;; *) tp="$PROJ/$t" ;; esac
        [ -e "$tp" ] || echo "setup-deps: remappings.txt: your line '$line' names $tp, which does not exist - kept as it is" ;;
      esac
    fi
  done < "$R"
fi
for i in "${!WANT_P[@]}"; do
  case "$done_p" in *" ${WANT_P[$i]} "*) continue ;; esac
  say remappings.txt "+ ${WANT_L[$i]}"; printf '%s\n' "${WANT_L[$i]}" >> "$RN"
done
r_changes=$changes
[ "$r_changes" -gt 0 ] || { [ "$MODE" = check ] || echo "setup-deps: remappings.txt: nothing to change"; }

# ---------------------------------------------------------------------------- foundry.toml, [profile.default]
F="$PROJ/foundry.toml"; FN="$TMPD/foundry.toml"; FLOG="$TMPD/foundry.log"
export SD_KEYS="libs solc_version evm_version"
export SD_V_libs='libs = []' SD_V_solc_version='solc_version = "0.8.26"' SD_V_evm_version='evm_version = "cancun"'
case "$KITREL" in ../*) SD_KEYS="$SD_KEYS allow_paths"; export SD_ALLOW="$KITREL/foundry-kit" ;; *) export SD_ALLOW="" ;; esac
SD_KEYS="$SD_KEYS additional_compiler_profiles compilation_restrictions"
export SD_V_additional_compiler_profiles='additional_compiler_profiles = [{ name = "manager", via_ir = true, optimizer_runs = 44444444 }]'
export SD_KIT="$KITREL"   # the PoolManager restriction is written in awk (want), through <kit>
if [ -f "$F" ]; then tr -d '\r' < "$F" > "$TMPD/foundry.in"; else : > "$TMPD/foundry.in"; fi
# one pass to see which keys [profile.default] has, one to write; the log gets one line per key: same | added | changed
awk -v lf="$FLOG" '
  function norm(s) { gsub(/[ \t\n]/, "", s); gsub(/,\]/, "]", s); return s }
  function oneline(s) { gsub(/\n[ \t]*/, " ", s); return s }
  function strip(s) { if (s ~ /[ \t]#[^"]*$/) sub(/[ \t]+#[^"]*$/, "", s); return s }
  function depth(s,   t, o, c) { t = s; gsub(/"[^"]*"/, "", t); o = gsub(/\[/, "[", t); c = gsub(/\]/, "]", t); return o - c }
  function hdr(s) { return s ~ /^[ \t]*\[/ }
  function isdef(s) { return s ~ /^[ \t]*\[[ \t]*profile[ \t]*\.[ \t]*default[ \t]*\][ \t]*(#.*)?$/ }
  function keyof(s,   k) { if (!match(s, /^[ \t]*[A-Za-z0-9_-]+[ \t]*=/)) return ""; k = substr(s, RSTART, RLENGTH); gsub(/[ \t=]/, "", k); return k }
  function ownlib(s) { return s ~ /"(\.\/)?lib\/(forge-std|v4-core|v4-periphery)/ || s ~ /^[ \t]*libs[ \t]*=.*"(\.\/)?lib\/?"/ }
  function want(k,   v, e, out, seen, kit) {
    if (k == "compilation_restrictions") return "compilation_restrictions = [\n  { paths = \"" ENVIRON["SD_KIT"] "/foundry-kit/v4/lib/v4-core/src/PoolManager.sol\", via_ir = true, optimizer_runs = 44444444 },\n]"
    if (k != "allow_paths") return ENVIRON["SD_V_" k]
    # allow_paths: the entries you have that are not under <kit>/foundry-kit, then that one
    kit = ENVIRON["SD_ALLOW"]; out = ""; v = OLD[k]
    while (match(v, /"[^"]*"/)) {
      e = substr(v, RSTART + 1, RLENGTH - 2); v = substr(v, RSTART + RLENGTH)
      if (e == kit || index(e, kit "/") == 1 || e in seen) continue
      seen[e] = 1; out = out (out == "" ? "" : ", ") "\"" e "\""
    }
    return "allow_paths = [" out (out == "" ? "" : ", ") "\"" kit "\"]"
  }
  function addkeys(   i, k) { for (i = 1; i <= n; i++) { k = KEYS[i]; if (!(k in OLD)) { print want(k); print "added\t" k "\t" oneline(want(k)) > lf } } }
  BEGIN { n = split(ENVIRON["SD_KEYS"], KEYS, " "); for (i = 1; i <= n; i++) MANAGED[KEYS[i]] = 1 }
  # pass 1: the managed keys present in [profile.default], each with its whole value (a multi-line array included); the
  # lines inside ANY multi-line value are never read as a header or a key
  FNR == NR {
    if (cont) { if (cap) OLD[ck] = OLD[ck] "\n" $0; d += depth(strip($0)); if (d <= 0) { cont = 0; cap = 0 }; next }
    if (hdr($0)) { indef = isdef($0); if (indef) hasdef = 1; next }
    k = keyof($0)
    if (k != "") { d = depth(strip($0)); cont = (d > 0)
      if (indef && k == "remappings") remap = 1
      if (indef && (k in MANAGED)) { OLD[k] = $0; ck = k; cap = cont } }
    next
  }
  FNR == 1 && !pass2 { pass2 = 1; indef = 0; cont = 0; table = ""
    if (remap) { print "refuse remappings" > lf; exit 3 }
    if (!hasdef) { print "[profile.default]"; addkeys(); print "" }
  }
  {
    if (cont) { d += depth(strip($0)); if (d <= 0) cont = 0
      if (!skip && !indef && table != "" && ownlib($0)) print "warn\t" FNR "\t" table "\t" $0 > lf
      if (!skip) print; if (!cont) skip = 0; next }
    if (hdr($0)) { indef = isdef($0); table = $0; gsub(/^[ \t]+|[ \t]+$/, "", table); print; if (indef) addkeys(); next }
    k = keyof($0)
    if (k != "") { d = depth(strip($0)); cont = (d > 0) }
    if (indef && (k in MANAGED)) {
      w = want(k); skip = cont
      if (norm(strip(OLD[k])) == norm(w)) { print OLD[k]; print "same\t" k > lf }
      else { print w; print "changed\t" k "\t" oneline(w) "\t" oneline(OLD[k]) > lf }
      next }
    if (!indef && table != "" && ownlib($0)) print "warn\t" FNR "\t" table "\t" $0 > lf
    print
  }
  END { if (!pass2 && !remap) { print "[profile.default]"; print "src = \"src\""; print "test = \"test\""; addkeys() } }
' "$TMPD/foundry.in" "$TMPD/foundry.in" > "$FN"
arc=$?
if grep -q '^refuse remappings' "$FLOG" 2> /dev/null; then
  refuse "$F sets remappings in [profile.default]: forge would read those, not remappings.txt. Move your own into remappings.txt and remove the key, then run this again. Nothing written."
fi
[ "$arc" = 0 ] || refuse "could not read $F (awk rc $arc). Nothing written."
f_changes=0
while IFS=$'\t' read -r what k new old; do
  case "$what" in
    added) say "foundry.toml [profile.default]" "+ $new"; f_changes=$((f_changes + 1)) ;;
    changed) say "foundry.toml [profile.default]" "~ $new   (was: $old)"; f_changes=$((f_changes + 1)) ;;
    warn) [ "$MODE" = check ] || echo "setup-deps: foundry.toml:$k $new still names the project's own lib/: '$old' - only [profile.default] is repaired; this one is yours" ;;
  esac
done < "$FLOG"
[ -f "$F" ] || [ "$f_changes" = 0 ] || [ "$MODE" = check ] || echo "setup-deps: foundry.toml did not exist: written with [profile.default] src = \"src\", test = \"test\" and the lines above"
[ "$f_changes" -gt 0 ] || { [ "$MODE" = check ] || echo "setup-deps: foundry.toml: nothing to change"; }
others=0
for x in "$PROJ"/lib/* "$PROJ"/lib/.[!.]*; do [ -e "$x" ] && [ "${x##*/}" != hook-gauntlet ] && others=1; done
if [ "$others" = 1 ]; then
  [ "$MODE" = check ] || echo "setup-deps: note - with libs = [] forge does not remap $PROJ/lib/* by itself: a library of yours there needs its own line in remappings.txt"
fi

# ---------------------------------------------------------------------------- write, build
case "$MODE" in
  check)
    if [ "$changes" = 0 ]; then echo "setup-deps: $PROJ is set up (kit $KITREL)"; exit 0; fi
    echo "setup-deps: $PROJ is not set up: $changes line(s) to write (scripts/setup-deps.sh --dry-run $PROJ shows them)"; exit 1 ;;
  dry)
    echo "setup-deps: dry-run - would run: forge build   (in $PROJ)"
    echo "setup-deps: dry-run - nothing written, nothing built ($changes line(s) to write; kit $KITREL = $KITABS)"; exit 0 ;;
esac
if [ "$r_changes" -gt 0 ]; then cp "$RN" "$R" || refuse "cannot write $R."; fi
if [ "$f_changes" -gt 0 ]; then cp "$FN" "$F" || { echo "setup-deps: cannot write $F (remappings.txt is written)"; exit 1; }; fi
command -v forge > /dev/null 2>&1 || { echo "setup-deps: forge is not on the PATH - the files are written, the build is NOT run (scripts/doctor.sh)"; exit 1; }
echo "setup-deps: running: forge build   (in $PROJ)"
(cd "$PROJ" && forge build); rc=$?
if [ "$rc" = 0 ]; then
  echo "setup-deps: DONE - $PROJ reaches the kit at $KITREL ($KITABS); forge build green"; exit 0
fi
echo "setup-deps: forge build FAILED (rc $rc) - the files above are written; forge's first error is the next thing to read"
exit 1
