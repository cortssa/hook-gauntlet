# shellcheck shell=bash
#
# owner-tree.sh - where a script of the kit may write its reports: never into a tree where the kit's convention is not
# installed. Source it:  . "$HERE/lib/owner-tree.sh"
#
# The problem it solves: census.sh (run mode and the --aggregate gate), size.sh, battery.sh, fuzz-long.sh and mutate.sh
# wrote their reports under <project>/.gauntlet/reports by default, and created it. In a tree without the convention -
# an existing hook, someone else's working tree (doctrine/RETROFIT.md: a bench of your own, never their working tree) -
# that is a directory nobody asked for, in their `git status` (V26b: `census.sh --aggregate <tsv> <proj>`, QUICKSTART's
# own line, made <proj>/.gauntlet/reports/06-census-gate.txt; `size.sh`, `census.sh`, `battery.sh`, and `fuzz-long.sh`
# with USE_BENCH=0 - whose refusal for a deep project used to suggest exactly that - made .gauntlet/reports). The gate is
# bench.sh's (K26b): inside the project only where the convention is installed, else a place outside it.
#
# report_dir_allowed <script> <project-dir> <report-dir>
#   <report-dir> is absolute, or relative to <project-dir> (as census.sh, size.sh and battery.sh read OUT_DIR). Nothing is
#   created. Allowed (return 0) when the report directory resolves OUTSIDE the project, or when the project is:
#     - a tree where the kit's convention is installed: <project>/.gauntlet/ exists (AGENTS.md section 4);
#     - a bench: a `.gauntlet-bench` marker (scripts/bench.sh writes one into every bench it makes) in the project or in a
#       directory above it (the v4 module benched with its parent) - a bench is the operator's copy, not the owner's tree;
#     - the kit's own worked examples: this checkout's foundry-kit/ and anything under it, whose .gauntlet/ the kit's
#       .gitignore keeps out of git (`scripts/battery.sh foundry-kit` on a fresh clone - QUICKSTART, CI - is the kit's
#       tree, not an owner's).
#   Otherwise it prints why and what to set, and returns 1: the caller refuses before it writes anything.
report_dir_allowed() {
  local who="$1" proj="$2" out="$3" proj_real out_abs probe rest out_real kit d pad
  pad="$(printf '%*s' "$((${#who} + 2))" '')"
  proj_real="$(cd "$proj" 2> /dev/null && pwd -P)" || { echo "$who: cannot enter $proj"; return 1; }
  case "$out" in /*) out_abs="$out" ;; *) out_abs="$proj_real/$out" ;; esac
  # the report directory as it WILL be: its longest part that exists, resolved (symlinks, ..), and the rest as written
  probe="$out_abs"; while [ ! -d "$probe" ] && [ "$probe" != "/" ] && [ "$probe" != "." ]; do probe="$(dirname "$probe")"; done
  rest="${out_abs#"$probe"}"
  case "/$rest/" in */../* | */./*)
    echo "$who: the report directory ($out_abs) has '.' or '..' after a directory that does not exist yet: give the place itself."
    return 1 ;;
  esac
  out_real="$(cd "$probe" 2> /dev/null && pwd -P)$rest"
  case "$out_real/" in "$proj_real"/*) ;; *) return 0 ;; esac   # outside the project
  [ ! -d "$proj_real/.gauntlet" ] || return 0                   # the convention is installed
  d="$proj_real"
  while :; do                                                    # a bench (bench.sh's marker), here or above
    [ ! -f "$d/.gauntlet-bench" ] || return 0
    [ "$d" != "/" ] || break
    d="$(dirname "$d")"
  done
  kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../foundry-kit" 2> /dev/null && pwd -P)"
  if [ -n "$kit" ]; then case "$proj_real/" in "$kit"/*) return 0 ;; esac; fi   # the kit's own worked examples
  echo "$who: $proj_real has no .gauntlet/ (the kit's convention is not installed there: someone else's tree,"
  echo "${pad}doctrine/RETROFIT.md - a bench of your own, never their working tree), and the report would go to $out_real,"
  echo "${pad}inside it. Refusing, nothing written: set OUT_DIR=<a directory outside the project> - or make a bench"
  echo "${pad}(scripts/bench.sh, BENCH_ROOT outside the project) and run it there."
  return 1
}

# bits_rule_skipped <project-dir>: 0, and the words in BITS_SKIP_WHY, where scripts/battery.sh does NOT hold a suite's
#   `_skipPermissionCheck` against the project's records (v0.4.2) - only where there are no such records to hold it
#   against: the kit's own worked examples (this checkout's foundry-kit/ and anything under it: its hostile hooks are
#   mis-flagged on purpose); a tree with no .gauntlet/ beside its suites (a bench: bench.sh never copies the project's
#   .gauntlet/); a bench (bench.sh's marker, here or above) whose .gauntlet/ holds nothing but the reports/ a script of
#   the kit wrote there. A `.gauntlet-bench` marker alone skips nothing (V60: a project with its records and such a file
#   had the rule turned off, silently): beside a .gauntlet/ with records in it the rule holds. The battery prints the
#   words, `bits not checked: <why>`. 1 otherwise: the rule holds.
# shellcheck disable=SC2034   # BITS_SKIP_WHY: read by the scripts that source this
BITS_SKIP_WHY=""
# shellcheck disable=SC2034   # BITS_SKIP_WHY: read by the scripts that source this
bits_rule_skipped() {
  local proj_real d kit other
  BITS_SKIP_WHY=""
  proj_real="$(cd "$1" 2> /dev/null && pwd -P)" || return 1
  kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../foundry-kit" 2> /dev/null && pwd -P)"
  if [ -n "$kit" ]; then case "$proj_real/" in "$kit"/*)
    BITS_SKIP_WHY="the kit's own worked examples (its hostile hooks are mis-flagged on purpose; no project's records here)"; return 0 ;; esac; fi
  if [ ! -d "$proj_real/.gauntlet" ]; then
    BITS_SKIP_WHY="no .gauntlet/ beside the suites (a bench, or a tree without the route's records): there is no red record here to hold _skipPermissionCheck against - the project's own battery does"
    return 0
  fi
  other="$(find "$proj_real/.gauntlet" -mindepth 1 -maxdepth 1 ! -name reports -print -quit 2> /dev/null)"
  [ -z "$other" ] || return 1
  d="$proj_real"
  while :; do
    if [ -f "$d/.gauntlet-bench" ]; then
      BITS_SKIP_WHY="a bench (scripts/bench.sh's marker in $d) whose .gauntlet/ holds only reports/: there is no red record here to hold _skipPermissionCheck against - the project's own battery does"
      return 0
    fi
    [ "$d" != "/" ] || break
    d="$(dirname "$d")"
  done
  return 1
}
