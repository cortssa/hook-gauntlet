#!/usr/bin/env bash
#
# selftest.sh - prove that every guard that can be exercised offline fails when it should.
#
# The problem it solves: a guard that has never been seen to go red is not a guard, it is a decoration. Both
# of the checks in this kit are the kind that sit silently green for months, which is exactly the kind that
# rots. Each case below is run twice: once where it must pass, and once where it must fail, with the exit
# code printed either way.
#
# What it does NOT exercise, because it needs the network: a SUCCESSFUL fetch-bytecode.sh against a real endpoint (its
# block and metadata are exercised against a stub `cast`, K16), the fork suites (foundry-kit/v4, FOUNDRY_PROFILE=fork), the
# backtest's replay (a fork; its fetch, refusals and report are here against a stub `cast` and a stub `forge` that prints
# a real replay's log, K19/K19b) and a
# successful install-v4.sh (GitHub). Their refusals are here; their success is the CI's `battery` job, which runs
# install-v4.sh on every push, and the fetch is run by hand (foundry-kit/v4/README.md). The OFFLINE install is here,
# success included, from fake local clones - with V4_WITH_PERIPHERY=1 too (K17b: the periphery's pin, its permit2,
# v4-core's OpenZeppelin, one v4-core) - and so are the v4 module's remappings, read by forge over a fake periphery.
#
# Usage:   scripts/selftest.sh             (--env-only: print the first line, the environment it cleared, and stop)
# Leaves:  on PASSED only, <kit>/.gauntlet/selftest-passed (git-ignored): the SHA-256 of the kit's scripts (scripts/*.sh,
#          scripts/lib/*.sh, scripts/*.py, scripts/lib/*.py), a hash of this machine's identity (/etc/machine-id, else the
#          hostname), the date, the first line of `forge --version` - the kit proven on this machine, which
#          scripts/next.sh checks before it names any row: the scripts, the machine and forge must all match (K31, K31b). It is removed at the start of every run, so any other
#          ending - FAILED, INCOMPLETE, --env-only, a run cut short - leaves none.
# Env:     none read. Every variable the scripts under test read as configuration is REMOVED at the start (the first
#          line of the run names them, and every one of them the calling shell had set); each case sets its own.
# Exit:   0 every case behaved as declared; 1 a case did not; 3 INCOMPLETE - a section was skipped (no forge, or no
#          foundry-kit/lib), so the scripts in it are NOT proven on this machine. A skipped section is not a pass.

set -uo pipefail

# ================================================================= the environment it runs in (K17c)
# Every case below sets the configuration it needs, and only that. A variable the scripts under test read as
# configuration, INHERITED from the shell that runs the selftest, changes what a case tests: measured by the verifier
# V17b - with REACH exported, three cases that must see census.sh's CORE floor go red passed "ok" against a census.sh
# whose floor was broken (a false green per case), and with CORE and REACH exported fifteen cases failed on a sound
# kit. So every such variable is removed here, before the first case, and named. The list: every name in the scripts'
# "Env:" headers (a case below fails if one is missing from it), the ones they read without listing them there, what
# the kit's Solidity reads (vm.envOr), the endpoint, the selftest's own KIT_PROJECT (it redirected the mutate, size,
# battery and census cases to another project in silence - V17c; nothing here sets it), and every name forge would read:
# FOUNDRY_*, FORGE_*, DAPP_*, in any case, dotted ones too (`FOUNDRY_FUZZ.RUNS`). Those are removed as the scripts'
# forge-env.sh removes them - by re-running this script without them (bash cannot unset a dotted name), once - and the
# first line names every one that was set: it said "none" over FORGE_ALLOW_FAILURE and a dotted name (V17c).
# Not removed: HOME, PATH and TMPDIR (the machine's, not the kit's configuration).
SELFTEST_CLEARED="ALLOW_SKIPS ALLOW_SMALL_BUDGET BASELINE BASELINE_MAY_BE_RED BENCH_ARTIFACTS BENCH_EXCLUDE BENCH_KEEP \
BENCH_ROOT CACHE_FILE CENSUS_FORGE_LOG CENSUS_TABLE_ONLY COPY_ROOT CORE DEPTH EXPECT EXTRA_SRC FORGE_FLAGS GATE_WHY \
GUARD_EXCLUDE HASH_PYTHON KEEP LABEL LINK_FROM LINK_LIB MATCH MIN_INIT_MARGIN MIN_MARGIN MIN_PCT OUT_DIR REACH RUNS SEED \
SRC_DIRS TEST_FLAGS USE_BENCH ESTIMATE_ONLY V4_ALLOW_UNTRACKED V4_CORE_SUBMODULES V4_FORCE V4_LOCAL_SRC V4_WITH_PERIPHERY \
V4_MANAGER V4_FIXTURE FORK_BLOCK GAUNTLET_CENSUS GAUNTLET_SIM SIM_SEED RPC_URL ETH_RPC_URL KIT_PROJECT \
BACKTEST_LOGS_CHUNK BACKTEST_FIXTURE NEXT_SELFTEST PENDING_RED CITED_FILES SETUP_DEPS_KEEP_LIB HERMES_HOME"
selftest_clears() { # selftest_clears <name>: 0 when the name is one this run removes
  case "$1" in [Ff][Oo][Uu][Nn][Dd][Rr][Yy]_* | [Ff][Oo][Rr][Gg][Ee]_* | [Dd][Aa][Pp][Pp]_*) return 0 ;; esac
  case " $SELFTEST_CLEARED " in *" $1 "*) return 0 ;; esac
  return 1
}
selftest_set_names() { # every name in the environment this run removes, one per line (env -0 sees dotted names; compgen does not)
  local kv n
  if env -0 > /dev/null 2>&1; then
    while IFS= read -r -d '' kv; do n="${kv%%=*}"; if selftest_clears "$n"; then printf '%s\n' "$n"; fi; done < <(env -0)
  else
    while IFS= read -r n; do if selftest_clears "$n"; then printf '%s\n' "$n"; fi; done < <(compgen -e)
  fi
}
if [ -z "${_SELFTEST_ENV_DONE:-}" ]; then
  selftest_drop=(); selftest_set=""
  while IFS= read -r v; do [ -n "$v" ] && { selftest_drop+=(-u "$v"); selftest_set="$selftest_set $v"; }; done < <(selftest_set_names)
  exec env ${selftest_drop[@]+"${selftest_drop[@]}"} _SELFTEST_ENV_DONE=1 _SELFTEST_WAS_SET="$selftest_set" "$BASH" "$0" "$@"
fi
selftest_was_set="${_SELFTEST_WAS_SET:-}"; unset _SELFTEST_ENV_DONE _SELFTEST_WAS_SET
# K31: the marker a PASSED run leaves - <kit>/.gauntlet/selftest-passed, which scripts/next.sh reads before it names any
# row - is removed before anything else: every other ending (FAILED, INCOMPLETE, --env-only, a run cut short) leaves none
SELFTEST_MARKER="$(cd "$(dirname "$0")/.." && pwd)/.gauntlet/selftest-passed"
rm -f "$SELFTEST_MARKER"
selftest_left="$(selftest_set_names | tr '\n' ' ')"
if [ -n "$selftest_left" ]; then
  echo "selftest: ${selftest_left% } still in the environment after the re-run that removed them (BASH_ENV?). Nothing run."; exit 1
fi
echo "selftest: environment cleared of: $SELFTEST_CLEARED FOUNDRY_* FORGE_* DAPP_* (any case); of these, set in the calling shell:${selftest_was_set:- none}"
if [ "${1:-}" = "--env-only" ]; then exit 0; fi

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || { echo "selftest: $HERE/lib/parse.sh is missing"; exit 1; }
# shellcheck source=lib/kit-proof.sh
. "$HERE/lib/kit-proof.sh" || { echo "selftest: $HERE/lib/kit-proof.sh is missing"; exit 1; }
SELFTEST_KIT="$(cd "$HERE/.." && pwd)"
selftest_hash0="$(kit_scripts_sha256 "$SELFTEST_KIT")"   # the scripts this run proves: checked again at the end
selftest_marker_write() { # selftest_marker_write <kit> <the scripts' sha256>: the marker next.sh reads (lib/kit-proof.sh)
  local m mh fv t; m="$(kit_marker "$1")"
  mh="$(kit_machine_sha256)" || return 1     # the machine (hashed) and forge next.sh will compare: both, or no marker
  fv="$(kit_forge_version)"; [ -n "$fv" ] || return 1
  mkdir -p "$(dirname "$m")" || return 1
  # a temporary file of this run's own (v0.4.2): two selftests in one kit shared one fixed name - one truncated it under the
  # other, whose rename then found nothing, and both ended FAILED (measured, 2026-10-02). mktemp, then one rename
  t="$(mktemp "$m.XXXXXX")" || return 1
  {
    echo "# the kit's selftest PASSED on this machine for these scripts: written by scripts/selftest.sh, read by scripts/next.sh"
    echo "scripts_sha256: $2"
    echo "scripts: $(kit_scripts_list "$1" | awk 'END { print NR }') files (scripts/*.sh, scripts/lib/*.sh, scripts/*.py, scripts/lib/*.py)"
    echo "machine_sha256: $mh (of $(kit_machine_source), hashed - never written as it is)"
    echo "date: $(date +%F)"
    echo "forge: $fv"
  } > "$t" && mv -f "$t" "$m" || { rm -f "$t"; return 1; }
}
FIX="$HERE/test/fixtures"
started=$SECONDS
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
skipped=0
check() { # check <label> <expected-rc> <actual-rc> [<the case's own output file>]
  if [ "$2" = "$3" ]; then
    echo "  ok    $1 (rc=$3, expected $2)"
  else
    echo "  FAIL  $1 (rc=$3, expected $2)"
    # the end of what THIS case printed, so that a failure can be read without a rerun. Every case that writes an output
    # file names it as the fourth argument: the newest o* file by mtime is only a fallback for a case that names none,
    # because it is often ANOTHER case's file (2026-09-23: a red "battery on a small green project" pasted the tail of the
    # symlink case, and the diagnosis started from the wrong log).
    if [ -n "${4:-}" ]; then
      if [ -f "$4" ]; then echo "          | tail of $(basename "$4"):"; tail -n 6 "$4" | sed "s/^/          | /"
      else echo "          | (this case's output file $(basename "$4") does not exist)"; fi
    else
      last="$(ls -t "$TMP"/o[0-9]* 2> /dev/null | head -1)"
      [ -n "$last" ] && { echo "          | no output file named; the NEWEST one, $(basename "$last"), which may be another case's:"; tail -n 6 "$last" | sed "s/^/          | /"; }
    fi
    fails=$((fails + 1))
  fi
}

if command -v sha256sum > /dev/null 2>&1; then
  hash_of() { sha256sum "$1" | cut -d' ' -f1; }
else
  hash_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

# ================================================================= the scripts themselves: bash -n, shellcheck
# CI's `shellcheck` job runs, from the checkout's root, exactly (a comment that STARTS with the tool's name is read by it
# as a directive, hence the "$"):
#   $ shellcheck --external-sources --source-path=SCRIPTDIR --severity=warning scripts/*.sh scripts/lib/*.sh
# and a finding at severity warning or error fails that job (style and info notes are not gated). The same command runs
# here, from the same directory, so a local selftest refuses what CI would refuse. With no shellcheck on this machine it
# is NOT run and the run says so; that is not counted as INCOMPLETE (it proves no guard, and CI runs it on every push).
echo "== the scripts themselves: bash -n, shellcheck =="
lint_scripts() { # lint_scripts <a scripts/ directory>: 0 clean, 1 a syntax error or a shellcheck finding
  local d f bad=0 files=()
  d="$(basename "$1")"
  for f in "$1"/*.sh "$1"/lib/*.sh; do [ -f "$f" ] && files+=("$d/${f#"$1"/}"); done
  [ "${#files[@]}" -gt 0 ] || { echo "no script under $1"; return 1; }
  for f in "${files[@]}"; do (cd "$1/.." && bash -n "$f") || { echo "bash -n: $f"; bad=1; }; done
  if command -v shellcheck > /dev/null 2>&1; then
    (cd "$1/.." && shellcheck --external-sources --source-path=SCRIPTDIR --severity=warning "${files[@]}") || bad=1
  fi
  return "$bad"
}
lint_scripts "$HERE" > "$TMP/o198" 2>&1; check "bash -n and shellcheck (CI's command) over scripts/*.sh and scripts/lib/*.sh" 0 $? "$TMP/o198"
LB="$TMP/lintbad/scripts"; mkdir -p "$LB/lib"
printf '#!/usr/bin/env bash\necho ok\n' > "$LB/lib/ok.sh"
printf '#!/usr/bin/env bash\nif then\n' > "$LB/bad.sh"
lint_scripts "$LB" > "$TMP/o199" 2>&1; check "a script with a syntax error is refused (bash -n)" 1 $? "$TMP/o199"
if command -v shellcheck > /dev/null 2>&1; then
  # SC2164 (cd without a fallback) is a WARNING: bash -n passes it, CI's shellcheck job fails on it
  printf '#!/usr/bin/env bash\ncd "$1"\necho "in $PWD"\n' > "$LB/bad.sh"
  lint_scripts "$LB" > "$TMP/o200" 2>&1; check "a script with a shellcheck warning is refused, as CI's job refuses it" 1 $? "$TMP/o200"
  if grep -q 'SC2164' "$TMP/o200"; then echo "  ok    and the refusal names the finding (SC2164)"; else
    echo "  FAIL  the refusal does not name SC2164"; fails=$((fails + 1)); fi
else
  echo "  --    shellcheck is not installed here: NOT run on this machine (CI's shellcheck job runs it on every push)"
fi
# the environment cleared at the top (K17c): every name the scripts' "Env:" headers document is in the list, so a name
# added to a header and not to the list is seen here; and none of the list is set any more
env_names() { # env_names <a scripts/ directory>: the names in each script's "Env:" block - at column 12, then "=" or two spaces
  local f
  for f in "$1"/*.sh "$1"/lib/*.sh; do
    [ -f "$f" ] && awk '/^[^#]/ && NR > 1 { exit } /^# Env:/ { on = 1 }
      on && match($0, /^#( Env:     |          )[A-Z][A-Z0-9_]+(=|  )/) {
        s = substr($0, RSTART, RLENGTH); sub(/^#( Env: +| +)/, "", s); sub(/(=|  )$/, "", s); print s }' "$f"
  done | sort -u
}
env_missing=""; env_left=""; env_n=0
for v in $(env_names "$HERE"); do
  env_n=$((env_n + 1))
  case "$v" in FOUNDRY_* | DAPP_*) continue ;; esac
  case " $SELFTEST_CLEARED " in *" $v "*) ;; *) env_missing="$env_missing $v" ;; esac
done
for v in $SELFTEST_CLEARED; do [ -n "${!v+x}" ] && env_left="$env_left $v"; done
if [ "$env_n" -ge 30 ] && [ -z "$env_missing" ] && [ -z "$env_left" ]; then
  echo "  ok    the environment: all $env_n names of the scripts' Env: headers are cleared at the start, and none is set"; else
  echo "  FAIL  the environment: $env_n Env: names read; not cleared:${env_missing:- -}; still set:${env_left:- -}"; fails=$((fails + 1)); fi
# the first line names EVERY name it removed that was set (V17c: "none" over FORGE_ALLOW_FAILURE, a dotted name and
# KIT_PROJECT, which this script read): a selftest of its own, stopped after that line
env KIT_PROJECT=/nonexistent FORGE_ALLOW_FAILURE=true 'FOUNDRY_FUZZ.RUNS=1' dapp_test_x=1 CORE=x "$HERE/selftest.sh" --env-only > "$TMP/o790" 2>&1
check "a selftest with KIT_PROJECT, FORGE_ALLOW_FAILURE, FOUNDRY_FUZZ.RUNS, dapp_test_x and CORE set (its first line only)" 0 $? "$TMP/o790"
env_first="$(head -1 "$TMP/o790")"; env_named=""
for v in KIT_PROJECT FORGE_ALLOW_FAILURE FOUNDRY_FUZZ.RUNS dapp_test_x CORE; do case "${env_first#*set in the calling shell:} " in *" $v "*) env_named="$env_named $v" ;; esac; done
if [ "$env_named" = " KIT_PROJECT FORGE_ALLOW_FAILURE FOUNDRY_FUZZ.RUNS dapp_test_x CORE" ] && [ "$(wc -l < "$TMP/o790" | tr -d ' ')" = "1" ]; then
  echo "  ok    and its first line names all five as set in the calling shell"; else
  echo "  FAIL  the first line does not name every one that was set (named:${env_named:- none}): $env_first"; fails=$((fails + 1)); fi

# ================================================================= doctor.sh (it checks; it never installs, never uses the network)
# doctor.sh runs here on a FAKE machine: a kit tree of its own (forge-std's package.json, and a v4-core that is a real git
# checkout whose HEAD is planted as the pin in a copy of install-v4.sh, as the install-v4 cases below do), an empty HOME,
# and a PATH of stubs - forge and cast that print the version a case names, a uname that says which system this is, and
# every installer and network tool (curl, wget, foundryup, apt-get, brew, pip, pipx, sudo, wsl...) as a stub that only
# writes its name to a log. That log must stay empty: a doctor that installs or fetches is seen doing it.
echo "== doctor.sh =="
DR="$TMP/doctor"; DK="$DR/kit"; DB="$DR/base"; DH="$DR/home"
mkdir -p "$DK/scripts/lib" "$DK/foundry-kit/lib/forge-std" "$DK/foundry-kit/v4/lib/v4-core/src" "$DK/foundry-kit/v4/lib/v4-core/lib/forge-std/src" \
  "$DK/foundry-kit/v4/lib/v4-core/lib/solmate/src" "$DB" "$DH"
cp "$HERE/doctor.sh" "$DK/scripts/" 2> /dev/null
cp "$HERE/lib/parse.sh" "$DK/scripts/lib/"
printf '{\n  "name": "forge-std",\n  "version": "1.16.2",\n  "license": "(Apache-2.0 OR MIT)"\n}\n' > "$DK/foundry-kit/lib/forge-std/package.json"
dstub() { mkdir -p "$1"; printf '#!/bin/sh\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }   # dstub <dir> <name> <body>
for t in env bash sed grep head tail tr cat dirname basename cut awk; do p="$(command -v "$t")" && ln -s "$p" "$DB/$t"; done
for t in curl wget foundryup apt apt-get brew pip pip3 pipx sudo wsl winget choco npm; do
  dstub "$DR/trap" "$t" "echo \"$t \$*\" >> \"$DR/installer-calls\"; exit 1"; done
dstub "$DR/linux" uname 'case "$1" in -s) echo Linux ;; -r) echo 6.1.0-generic ;; *) echo Linux ;; esac'
dstub "$DR/mac" uname 'case "$1" in -s) echo Darwin ;; -r) echo 23.6.0 ;; *) echo Darwin ;; esac'
dstub "$DR/win" uname 'case "$1" in -s) echo MINGW64_NT-10.0-19045 ;; -r) echo 3.5.4-0bc1222b.x86_64 ;; *) echo MINGW64_NT-10.0-19045 ;; esac'
for v in 1.8.1 1.8.3 1.9.0; do
  dstub "$DR/f$v" forge "printf 'forge Version: $v\nCommit SHA: 0000000\n'"; dstub "$DR/f$v" cast "printf 'cast Version: $v\n'"; done
dstub "$DR/tools" rsync "echo 'rsync  version 3.2.7  protocol version 31'"
dstub "$DR/oldbash" bash "echo 'GNU bash, version 3.2.57(1)-release (arm64-apple-darwin23)'"
if command -v git > /dev/null 2>&1 && [ -f "$DK/scripts/doctor.sh" ]; then
  ln -s "$(command -v git)" "$DR/tools/git"; mkdir -p "$DR/gitonly"; ln -s "$(command -v git)" "$DR/gitonly/git"
  DV="$DK/foundry-kit/v4/lib/v4-core"
  printf 'contract PoolManager {}\n' > "$DV/src/PoolManager.sol"; printf 'contract Test {}\n' > "$DV/lib/forge-std/src/Test.sol"
  printf 'contract Owned {}\n' > "$DV/lib/solmate/src/Owned.sol"
  (cd "$DV" && git init -q && git add -A && git -c user.name=selftest -c user.email=selftest@invalid -c commit.gpgsign=false commit -q -m fake) > /dev/null 2>&1
  sed "s/^V4_CORE_PIN=\"[0-9a-f]*\"/V4_CORE_PIN=\"$(git -C "$DV" rev-parse HEAD)\"/" "$HERE/install-v4.sh" > "$DK/scripts/install-v4.sh"
  # doc <out> <dirs before the base, colon-separated> [VAR=value...]: the doctor on the fake machine, RPC_URL unset unless given
  doc() { local o="$1" p="$2"; shift 2; env -u RPC_URL -u ETH_RPC_URL HOME="$DH" PATH="$p:$DR/trap:$DB" "$@" "$BASH" "$DK/scripts/doctor.sh" > "$o" 2>&1; }
  # every line is `ok|missing|optional-missing <name> ...`, an indented line (a command, a step), or the last line
  doc_shape() { ! grep -vE '^(ok|missing|optional-missing) [A-Za-z0-9_.-]+( |$)|^  |^static: (forge lint only|slither [0-9.]+(, aderyn [0-9.]+)?|aderyn [0-9.]+)$|^kit: (no MANIFEST|[0-9]+ files not in MANIFEST: .+)$|^doctor: (ready|missing: .+)$' "$1"; }
  expect_line() { # expect_line <label> <file> <grep -E pattern>...: every pattern is found
    local label="$1" f="$2" pat miss=""; shift 2
    for pat in "$@"; do grep -qE -- "$pat" "$f" || miss="$miss [$pat]"; done
    if [ -z "$miss" ]; then echo "  ok    $label"; else echo "  FAIL  $label: not found:$miss"; sed "s/^/        | /" "$f"; fails=$((fails + 1)); fi
  }
  L="$DR/f1.8.1:$DR/tools:$DR/linux"
  doc "$TMP/o220" "$L"; check "doctor: everything required is there, forge at the pin" 0 $? "$TMP/o220"
  expect_line "and it says ready on its last line, forge 1.8.1 ok, RPC_URL optional and not set" "$TMP/o220" \
    '^ok forge 1\.8\.1' '^ok forge-std 1\.16\.2' '^ok v4-core ' '^ok bash 5' '^optional-missing RPC_URL' '^optional-missing python3'
  if [ "$(tail -n 1 "$TMP/o220")" = "doctor: ready" ] && doc_shape "$TMP/o220"; then echo "  ok    the last line is exactly 'doctor: ready', and every line has the documented shape"; else
    echo "  FAIL  the last line is not 'doctor: ready', or a line has another shape"; sed "s/^/        | /" "$TMP/o220"; fails=$((fails + 1)); fi
  doc "$TMP/o221" "$DR/tools:$DR/linux"; check "doctor: no forge on the PATH" 1 $? "$TMP/o221"
  expect_line "and it names forge and cast, with the Linux install commands, and lists them on the last line" "$TMP/o221" \
    '^missing forge' '^missing cast' 'curl -L https://foundry\.paradigm\.xyz \| bash' 'foundryup --install 1\.8\.1' '^doctor: missing: forge, cast$'
  mkdir -p "$DH/.foundry/bin"; cp "$DR/f1.8.1/forge" "$DR/f1.8.1/cast" "$DH/.foundry/bin/"
  doc "$TMP/o222" "$DR/tools:$DR/linux"; check "doctor: forge installed in ~/.foundry/bin but not on the PATH" 1 $? "$TMP/o222"
  expect_line "and it says to put ~/.foundry/bin on the PATH, not to install again" "$TMP/o222" 'export PATH="\$HOME/\.foundry/bin:\$PATH"'
  rm -rf "$DH/.foundry"
  doc "$TMP/o223" "$DR/f1.9.0:$DR/tools:$DR/linux"; check "doctor: a forge of another version (1.9.0)" 1 $? "$TMP/o223"
  expect_line "and it names the version found, the supported ones and the command for the pinned one" "$TMP/o223" \
    '^missing forge .*1\.9\.0' '1\.8\.1' 'foundryup --install 1\.8\.1' '^doctor: missing: forge'
  doc "$TMP/o224" "$DR/f1.8.3:$DR/tools:$DR/linux"; check "doctor: forge 1.8.3, the second supported version" 0 $? "$TMP/o224"
  expect_line "and it is ok, named as supported beside the pin" "$TMP/o224" '^ok forge 1\.8\.3'
  doc "$TMP/o225" "$L" RPC_URL="https://k20-sentinel.example.invalid/v2/SENTINEL0KEY" ETH_RPC_URL="https://k20-sentinel.example.invalid/v2/SENTINEL0KEY"
  check "doctor: RPC_URL set" 0 $? "$TMP/o225"
  expect_line "and it says set" "$TMP/o225" '^ok RPC_URL set'
  if ! grep -qiE 'SENTINEL0KEY|k20-sentinel|example\.invalid' "$TMP/o225"; then echo "  ok    and no part of the value appears in the output"; else
    echo "  FAIL  the RPC_URL value (or part of it) was printed"; fails=$((fails + 1)); fi
  doc "$TMP/o226" "$DR/f1.8.1:$DR/tools:$DR/win"; check "doctor: Windows outside WSL (Git Bash / MSYS uname)" 1 $? "$TMP/o226"
  expect_line "and it gives the WSL steps: admin PowerShell wsl --install, reboot, install inside WSL, the project on the Linux side" "$TMP/o226" \
    '^missing platform' 'administrator.*wsl --install|wsl --install.*administrator' '[Rr]eboot' 'inside WSL' 'Linux side' '^doctor: missing: platform$'
  doc "$TMP/o227" "$DR/f1.8.1:$DR/gitonly:$DR/mac"; check "doctor: macOS with no rsync" 1 $? "$TMP/o227"
  expect_line "and the command is brew's" "$TMP/o227" '^missing rsync' 'brew install rsync' '^doctor: missing: rsync$'
  doc "$TMP/o228" "$DR/f1.8.1:$DR/gitonly:$DR/linux"; check "doctor: Linux with no rsync" 1 $? "$TMP/o228"
  expect_line "and the command is apt's" "$TMP/o228" '^missing rsync' 'sudo apt-get install -y rsync'
  doc "$TMP/o229" "$DR/oldbash:$L"; check "doctor: the bash on the PATH is 3.2 (macOS's own)" 1 $? "$TMP/o229"
  expect_line "and it names the version found" "$TMP/o229" '^missing bash .*3\.2' '^doctor: missing: bash$'
  mv "$DK/foundry-kit/lib/forge-std" "$DR/forge-std.away"
  doc "$TMP/o230" "$L"; check "doctor: foundry-kit/lib/forge-std absent" 1 $? "$TMP/o230"
  expect_line "and it gives the pinned clone command" "$TMP/o230" '^missing forge-std' 'git clone --quiet --depth 1 --branch v1\.16\.2 https://github\.com/foundry-rs/forge-std foundry-kit/lib/forge-std'
  mv "$DR/forge-std.away" "$DK/foundry-kit/lib/forge-std"
  cp "$DK/scripts/install-v4.sh" "$DR/install-v4.keep"
  sed -i.bak 's/^V4_CORE_PIN="[0-9a-f]*"/V4_CORE_PIN="0000000000000000000000000000000000000000"/' "$DK/scripts/install-v4.sh"
  doc "$TMP/o231" "$L"; check "doctor: foundry-kit/v4/lib/v4-core at another commit than the pin" 1 $? "$TMP/o231"
  expect_line "and it gives install-v4.sh with V4_FORCE=1" "$TMP/o231" '^missing v4-core' 'V4_FORCE=1 scripts/install-v4.sh foundry-kit/v4'
  cp "$DR/install-v4.keep" "$DK/scripts/install-v4.sh"; mv "$DV" "$DR/v4-core.away"
  doc "$TMP/o232" "$L"; check "doctor: foundry-kit/v4/lib/v4-core not installed" 1 $? "$TMP/o232"
  expect_line "and it gives install-v4.sh" "$TMP/o232" '^missing v4-core' 'scripts/install-v4.sh foundry-kit/v4'
  mv "$DR/v4-core.away" "$DV"
  # the static analysers (v0.5): one `static:` line, never a missing item - what scripts/static-triage.sh will run besides
  # forge lint. No analyser on the fake machine: forge lint only, with the install lines for the owner's yes
  expect_line "doctor: no Slither, no Aderyn - one line 'static: forge lint only', the Slither install command under it, never a missing item" "$TMP/o220" \
    '^static: forge lint only$' 'pipx install slither-analyzer' 'question 17b'
  if grep -qE '^(missing|optional-missing) (slither|aderyn)' "$TMP/o220"; then echo "  FAIL  doctor: Slither or Aderyn reported as a missing item"; fails=$((fails + 1)); else
    echo "  ok    and neither is a missing or optional-missing item"; fi
  dstub "$DR/sl" slither "echo 0.11.6"; dstub "$DR/ad" aderyn "echo 'aderyn 0.6.5'"
  doc "$TMP/o7001" "$DR/sl:$L"; check "doctor: a Slither on the PATH" 0 $? "$TMP/o7001"
  expect_line "and the line is 'static: slither 0.11.6'" "$TMP/o7001" '^static: slither 0\.11\.6$'
  doc "$TMP/o7002" "$DR/sl:$DR/ad:$L"; check "doctor: Slither and Aderyn on the PATH" 0 $? "$TMP/o7002"
  expect_line "and the line names both, Slither first" "$TMP/o7002" '^static: slither 0\.11\.6, aderyn 0\.6\.5$'
  doc "$TMP/o7003" "$DR/ad:$L"; check "doctor: Aderyn alone" 0 $? "$TMP/o7003"
  expect_line "and the line is 'static: aderyn 0.6.5'" "$TMP/o7003" '^static: aderyn 0\.6\.5$'
  if doc_shape "$TMP/o7001" && doc_shape "$TMP/o7002" && doc_shape "$TMP/o7003"; then echo "  ok    and every line of those three has the documented shape"; else
    echo "  FAIL  a line of the Slither / Aderyn runs has another shape"; fails=$((fails + 1)); fi
  if [ ! -e "$DR/installer-calls" ]; then echo "  ok    no installer and no network tool was called by any doctor run above"; else
    echo "  FAIL  the doctor called an installer or a network tool:"; sed "s/^/        | /" "$DR/installer-calls"; fails=$((fails + 1)); fi
  # the versions the doctor calls supported are the ones CI runs: a pin changed in one place only is seen here
  dpins="$(sed -n 's/^FORGE_PIN="\(.*\)"$/\1 /p; s/^FORGE_ALSO="\(.*\)"$/\1 /p; s/^FORGE_STD_PIN="\(.*\)"$/\1 /p; s/^REPORTLAB_PIN="\(.*\)"$/\1 /p; s/^PYPDF_PIN="\(.*\)"$/\1/p' "$HERE/doctor.sh" | tr -d '\n')"
  gpins="$(sed -n 's/^  FOUNDRY_VERSION: v\(.*\)$/\1 /p; s/^  FOUNDRY_VERSION_2: v\(.*\)$/\1 /p; s/^  FORGE_STD_TAG: v\(.*\)$/\1 /p; s/^  REPORTLAB_VERSION: "\(.*\)"$/\1 /p; s/^  PYPDF_VERSION: "\(.*\)"$/\1/p' "$HERE/../.github/workflows/gates.yml" | tr -d '\n')"
  if [ -n "$dpins" ] && [ "$dpins" = "$gpins" ]; then echo "  ok    doctor.sh's pins ($dpins) are gates.yml's"; else
    echo "  FAIL  doctor.sh's pins ($dpins) are not gates.yml's ($gpins)"; fails=$((fails + 1)); fi
  # the workflow must PARSE: an invalid gates.yml is not a red run, it is no run at all (GitHub shows "workflow file
  # issue" and none of the jobs start). An unquoted step name holding ": " did exactly that for four pushes.
  if command -v python3 > /dev/null 2>&1 && python3 -c 'import yaml' > /dev/null 2>&1; then
    if python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); assert d["jobs"]' "$HERE/../.github/workflows/gates.yml" > "$TMP/o234y" 2>&1; then
      echo "  ok    .github/workflows/gates.yml parses as YAML and has jobs"; else
      echo "  FAIL  .github/workflows/gates.yml does not parse - GitHub would start none of its jobs:"; tail -n 2 "$TMP/o234y" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  else
    echo "  --    python3 with PyYAML is not here: gates.yml NOT parsed on this machine (GitHub refuses an invalid one before any job)"
  fi
  # and on this machine, for real: whatever it finds, its last line and its exit code agree
  "$HERE/doctor.sh" > "$TMP/o233" 2>&1; rc233=$?
  case "$rc233:$(tail -n 1 "$TMP/o233")" in
    "0:doctor: ready" | "1:doctor: missing: "?*) echo "  ok    doctor.sh on this machine: $(tail -n 1 "$TMP/o233") (rc=$rc233)" ;;
    *) echo "  FAIL  doctor.sh on this machine: rc=$rc233 and last line '$(tail -n 1 "$TMP/o233")' do not agree"; fails=$((fails + 1)) ;;
  esac
else
  echo "  FAIL  doctor.sh is missing, or there is no git to build its fake v4-core with"; fails=$((fails + 1))
fi

# ================================================================= release-guard.sh
echo "== release-guard.sh =="
W="$TMP/work"; P="$TMP/published"
mkdir -p "$W" "$P"
printf 'contract A {}\n' > "$W/A.sol"
printf 'contract B {}\n' > "$W/B.sol"
cp "$W/A.sol" "$W/B.sol" "$P/"
{ printf '%s  A.sol\n' "$(hash_of "$P/A.sol")"; printf '%s  B.sol\n' "$(hash_of "$P/B.sol")"; } > "$P/MANIFEST.sha256"

"$HERE/release-guard.sh" "$W" "$P" > "$TMP/o1" 2>&1; check "identical trees, complete manifest" 0 $? "$TMP/o1"

printf 'contract A { uint256 x; }\n' > "$W/A.sol"
"$HERE/release-guard.sh" "$W" "$P" > "$TMP/o2" 2>&1; check "only the working tree was edited" 1 $? "$TMP/o2"
cp "$P/A.sol" "$W/A.sol"

printf 'contract C {}\n' > "$W/C.sol"; cp "$W/C.sol" "$P/C.sol"
"$HERE/release-guard.sh" "$W" "$P" > "$TMP/o3" 2>&1; check "a file added to BOTH trees with no hash" 2 $? "$TMP/o3"
rm -f "$W/C.sol" "$P/C.sol"

printf 'contract A { uint256 x; }\n' > "$W/A.sol"; cp "$W/A.sol" "$P/A.sol"
"$HERE/release-guard.sh" "$W" "$P" > "$TMP/o4" 2>&1; check "BOTH trees edited together, stale hash" 3 $? "$TMP/o4"

printf '%s  A.sol\n' "$(hash_of "$P/A.sol")" > "$P/MANIFEST.sha256"
printf '%s  B.sol\n' "$(hash_of "$P/B.sol")" >> "$P/MANIFEST.sha256"
"$HERE/release-guard.sh" "$W" "$P" > "$TMP/o5" 2>&1; check "manifest refreshed on purpose" 0 $? "$TMP/o5"

before="$(hash_of "$P/MANIFEST.sha256")"
"$HERE/release-guard.sh" "$W" "$P" > /dev/null 2>&1
after="$(hash_of "$P/MANIFEST.sha256")"
if [ "$before" = "$after" ]; then echo "  ok    the guard never writes into the published copy"; else
  echo "  FAIL  the guard modified the published copy"; fails=$((fails + 1)); fi

"$HERE/release-guard.sh" "$W" > "$TMP/o138" 2>&1; check "missing argument" 4 $? "$TMP/o138"

# ================================================================= assert-fresh-build.sh
# The VERDICT is forge's: the guard runs `forge build` and reads its answer ("No files changed, compilation skipped" =
# FRESH; a compilation = STALE, rebuilt; a failed build = nothing decided). Here, with no compiler, forge is a STUB that
# gives the answer each case names (FAKE_BUILD) - what forge 1.8.1 answered in the same situation on a real project
# (the real answers are cases o165-o167, o174 and o207-o212 in the forge section below). What this section tests is
# the rest: the guard's reading of each answer, and the EVIDENCE it prints before the verdict - the content of every
# source compared with forge's own record of what it compiled (cache/solidity-files-cache.json: one contentHash each).
# The fixture is a small project BUILT BY FORGE 1.8.1 - its sources in fixtures/fresh-project/, forge's cache of that
# build in fixtures/fresh-project.cache.json (the hashes are forge's, not this kit's; only the cache's library path was
# made relative). Its five sources fall in five size classes of the hash, so a hasher that disagrees with forge on any of
# them names a source that did not change. File times are SET, not waited for, and set on PURPOSE against the content:
# an edit dated before the build, a copy dated after it - the time must not decide either way.
echo "== assert-fresh-build.sh =="
FF="$TMP/fforge"; mkdir -p "$FF"
cat > "$FF/forge" <<'STUB'
#!/usr/bin/env bash
# a stub forge: answers `forge build` the way $FAKE_BUILD says, and refuses a repeated --offline as forge 1.8.1 does
n=0; for a in "$@"; do [ "$a" = "--offline" ] && n=$((n + 1)); done
if [ "$n" -gt 1 ]; then echo "error: the argument '--offline' cannot be used multiple times"; exit 2; fi
case "${FAKE_BUILD:-}" in
  skipped) echo "No files changed, compilation skipped" ;;
  compiled) printf 'Compiling 3 files with Solc 0.8.26\nSolc 0.8.26 finished in 1.00ms\nCompiler run successful!\n' ;;
  failed) printf 'Compiling 1 files with Solc 0.8.26\nError: Compiler run failed:\nError (2314): Expected identifier\n --> src/B.sol:4:10:\n'; exit 1 ;;
  *) echo "a line forge never printed" ;;
esac
exit 0
STUB
chmod +x "$FF/forge"
fresh() { PATH="$FF:$PATH" "$HERE/assert-fresh-build.sh" "$@"; }
J="$TMP/project"
cp -R "$FIX/fresh-project" "$J"
printf '[profile.default]\n' > "$J/foundry.toml"
T=1700000000
stamp() { T=$((T + 10)); touch -d "@$T" "$@"; }
stamp "$J/src/A.sol" "$J/src/B.sol" "$J/src/C.sol" "$J/test/D.t.sol" "$J/script/E.s.sol" "$J/foundry.toml"
before_build=$T
no_change_named() { ! grep -q '^evidence: .* changed after the last build' "$1" && ! grep -q '^evidence: .* is not in the cache' "$1"; }

FAKE_BUILD=compiled fresh "$J" > "$TMP/o6" 2>&1; check "nothing built yet (no out/): nothing decided, and no build run" 2 $? "$TMP/o6"

mkdir -p "$J/out/C.sol"
printf '{}\n' > "$J/out/C.sol/C.json"; stamp "$J/out/C.sol/C.json"
FAKE_BUILD=compiled fresh "$J" > "$TMP/o7" 2>&1; check "artifacts but no forge cache: nothing to compare against" 2 $? "$TMP/o7"

mkdir -p "$J/cache"; cp "$FIX/fresh-project.cache.json" "$J/cache/solidity-files-cache.json"; stamp "$J/cache/solidity-files-cache.json"
FAKE_BUILD=skipped fresh "$J" > "$TMP/o157" 2>&1; check "forge compiled nothing: FRESH" 0 $? "$TMP/o157"
if no_change_named "$TMP/o157" && grep -q '^evidence: 5 sources' "$TMP/o157"; then echo "  ok    and the evidence finds every source's content the one forge compiled (five size classes of its hash)"; else
  echo "  FAIL  the evidence names a source whose content is the one forge compiled (the hasher disagrees with forge?)"; fails=$((fails + 1)); fi

# forge's answer decides, whatever the evidence: every source is what forge compiled and forge compiled anyway (the
# settings changed, an artifact went missing...) - STALE, and it says the sources are not what changed
FAKE_BUILD=compiled fresh "$J" > "$TMP/o201" 2>&1; check "every source's content unchanged, and forge compiled: STALE (forge decides, not the hash)" 1 $? "$TMP/o201"
if grep -q '^STALE BUILD: forge compiled' "$TMP/o201" && grep -q 'not a source' "$TMP/o201"; then echo "  ok    and it says the sources are not what changed"; else
  echo "  FAIL  a STALE with unchanged sources does not say what else changes a build"; fails=$((fails + 1)); fi
FAKE_BUILD=failed fresh "$J" > "$TMP/o202" 2>&1; check "a build that fails decides nothing" 2 $? "$TMP/o202"
if grep -q 'Error (2314)' "$TMP/o202"; then echo "  ok    and it prints forge's error"; else
  echo "  FAIL  a failed build is not shown with its error"; fails=$((fails + 1)); fi
FAKE_BUILD=odd fresh "$J" > "$TMP/o203" 2>&1; check "an answer from forge this guard does not know decides nothing (never read as FRESH)" 2 $? "$TMP/o203"
FORGE_FLAGS="--offline" FAKE_BUILD=skipped fresh "$J" > "$TMP/o204" 2>&1; check "FORGE_FLAGS=--offline (the battery's) is not passed twice" 0 $? "$TMP/o204"
FORGE_FLAGS="--force" FAKE_BUILD=compiled fresh "$J" > "$TMP/o205" 2>&1; check "FORGE_FLAGS with --force (always compiles) is refused: nothing decided" 2 $? "$TMP/o205"

# (b) the case that used to flip: the same bytes copied in again AFTER the build (new mtime, same content)
cp "$FIX/fresh-project/src/C.sol" "$J/src/C.sol"; cp "$FIX/fresh-project/test/D.t.sol" "$J/test/D.t.sol"; stamp "$J/src/C.sol" "$J/test/D.t.sol"
FAKE_BUILD=skipped fresh "$J" > "$TMP/o158" 2>&1; check "sources copied in after the build, same content (new mtime): FRESH" 0 $? "$TMP/o158"
if grep -q 'newer than the cache with the same content' "$TMP/o158" && no_change_named "$TMP/o158"; then echo "  ok    and the newer times are printed as evidence, not as a change"; else
  echo "  FAIL  the copied sources' newer times are not reported as evidence, or are reported as a change"; fails=$((fails + 1)); fi

# (a) an edit that was not built - dated BEFORE the build, so that only its content can give it away
printf '// edited, not built\n' >> "$J/src/B.sol"; touch -d "@$before_build" "$J/src/B.sol"
FAKE_BUILD=compiled fresh "$J" > "$TMP/o159" 2>&1; check "a source edited without a build (dated before the build): STALE" 1 $? "$TMP/o159"
if grep -q '^evidence: src/B.sol changed after the last build' "$TMP/o159"; then echo "  ok    and the evidence names the edited source"; else
  echo "  FAIL  the evidence does not name src/B.sol"; fails=$((fails + 1)); fi
cp "$FIX/fresh-project/src/B.sol" "$J/src/B.sol"; stamp "$J/src/B.sol"
FAKE_BUILD=skipped fresh "$J" > "$TMP/o160" 2>&1; check "the edit undone (the compiled content again, a new mtime): FRESH" 0 $? "$TMP/o160"
if no_change_named "$TMP/o160"; then echo "  ok    and the evidence names no source"; else echo "  FAIL  the evidence names a source after the edit was undone"; fails=$((fails + 1)); fi

# (c) a new source, never built - also dated before the build
printf '// a new file\n' > "$J/src/F.sol"; touch -d "@$before_build" "$J/src/F.sol"
FAKE_BUILD=compiled fresh "$J" > "$TMP/o161" 2>&1; check "a new source that was never built: STALE" 1 $? "$TMP/o161"
if grep -q '^evidence: src/F.sol is not in the cache' "$TMP/o161"; then echo "  ok    and the evidence says the new source is not in the cache"; else
  echo "  FAIL  the evidence does not say src/F.sol is missing from the cache"; fails=$((fails + 1)); fi
rm -f "$J/src/F.sol"

# the config is not in forge's cache, so the evidence cannot compare its content - but forge's own build sees it: a changed
# optimizer recompiles (measured, forge 1.8.1: the stub answers what forge answered), so this is STALE now, not a note
printf 'optimizer = true\n' >> "$J/foundry.toml"; stamp "$J/foundry.toml"
FAKE_BUILD=compiled fresh "$J" > "$TMP/o162" 2>&1; check "a config changed after the build, no source changed: STALE (forge sees the settings)" 1 $? "$TMP/o162"
if grep -q '^evidence: foundry.toml is newer than the cache' "$TMP/o162"; then echo "  ok    and the evidence names foundry.toml as newer than the cache"; else
  echo "  FAIL  no evidence line about the config"; fails=$((fails + 1)); fi
printf '[profile.default]\n' > "$J/foundry.toml"; touch -d "@$before_build" "$J/foundry.toml"

# a cache the evidence cannot read (another forge's shape), or no interpreter to hash with: no evidence, and it says so -
# forge's answer still decides (these two were "nothing decided" while the hash was the verdict)
cp "$J/cache/solidity-files-cache.json" "$TMP/cache.keep"; printf '{"_format": "", "files": {"src/A.sol": {"sourceName": "src/A.sol"}}}\n' > "$J/cache/solidity-files-cache.json"
FAKE_BUILD=skipped fresh "$J" > "$TMP/o163" 2>&1; check "a cache with no contentHash: no evidence, forge's answer decides" 0 $? "$TMP/o163"
if grep -q '^evidence: none' "$TMP/o163"; then echo "  ok    and it says there is no evidence"; else echo "  FAIL  it does not say the evidence is missing"; fails=$((fails + 1)); fi
cp "$TMP/cache.keep" "$J/cache/solidity-files-cache.json"
HASH_PYTHON="$TMP/no-such-python" FAKE_BUILD=skipped fresh "$J" > "$TMP/o164" 2>&1; check "no interpreter to hash with: no evidence, forge's answer decides" 0 $? "$TMP/o164"
if grep -q '^evidence: none' "$TMP/o164"; then echo "  ok    and it says there is no evidence"; else echo "  FAIL  it does not say the evidence is missing"; fails=$((fails + 1)); fi
no_forge_path=""
while IFS= read -r -d ':' d; do [ -x "$d/forge" ] || no_forge_path="$no_forge_path$d:"; done <<< "$PATH:"
PATH="${no_forge_path%:}" "$HERE/assert-fresh-build.sh" "$J" > "$TMP/o206" 2>&1; check "no forge on the PATH decides nothing" 2 $? "$TMP/o206"

# line ends: forge 1.8.1 hashes the text with every CR LF turned into LF, in one pass, and nothing else - a lone CR, a CR CR LF,
# a missing last newline stay as they are (measured on eight fixtures against its own cache, 2026-09-23). A checkout with
# CRLF is therefore the text forge compiled, and the evidence used to name it as changed on a fresh build. The two cases
# after it pin the rule from the other side: a hasher that dropped EVERY CR, or turned a lone CR into LF, would not name them.
for f in src/A.sol src/B.sol src/C.sol test/D.t.sol script/E.s.sol; do
  sed 's/$/\r/' "$FIX/fresh-project/$f" > "$J/$f"; touch -d "@$before_build" "$J/$f"
done
FAKE_BUILD=skipped fresh "$J" > "$TMP/o171" 2>&1; check "the five sources with CRLF line ends (forge compiles nothing)" 0 $? "$TMP/o171"
if no_change_named "$TMP/o171"; then echo "  ok    and the evidence names no source: CRLF is the text forge compiled"; else
  echo "  FAIL  the evidence names a CRLF source as changed"; fails=$((fails + 1)); fi
for f in src/A.sol src/B.sol src/C.sol test/D.t.sol script/E.s.sol; do cp "$FIX/fresh-project/$f" "$J/$f"; touch -d "@$before_build" "$J/$f"; done
awk 'NR == 1 { printf "%s\r\r\n", $0; next } { print }' "$FIX/fresh-project/src/B.sol" > "$J/src/B.sol"; touch -d "@$before_build" "$J/src/B.sol"
FAKE_BUILD=compiled fresh "$J" > "$TMP/o172" 2>&1; check "a line ending CR CR LF (forge compiles)" 1 $? "$TMP/o172"
if grep -q '^evidence: src/B.sol changed after the last build' "$TMP/o172"; then echo "  ok    and the evidence names it: forge folds CR LF once"; else
  echo "  FAIL  the evidence does not name a CR CR LF source"; fails=$((fails + 1)); fi
awk 'NR == 1 { printf "%s\r", $0; next } { print }' "$FIX/fresh-project/src/B.sol" > "$J/src/B.sol"; touch -d "@$before_build" "$J/src/B.sol"
FAKE_BUILD=compiled fresh "$J" > "$TMP/o173" 2>&1; check "a lone CR where an LF was (forge compiles)" 1 $? "$TMP/o173"
if grep -q '^evidence: src/B.sol changed after the last build' "$TMP/o173"; then echo "  ok    and the evidence names it: forge keeps a lone CR"; else
  echo "  FAIL  the evidence does not name a lone-CR source"; fails=$((fails + 1)); fi
cp "$FIX/fresh-project/src/B.sol" "$J/src/B.sol"; touch -d "@$before_build" "$J/src/B.sol"

# ================================================================= fetch-bytecode.sh (the refusals; no network is used)
echo "== fetch-bytecode.sh =="
( unset RPC_URL ETH_RPC_URL; "$HERE/fetch-bytecode.sh" 0x000000000000000000000000000000000000dEaD "$TMP/x.hex" > "$TMP/o21" 2>&1 )
check "no RPC_URL in the environment: refuses, and says where the endpoint goes" 1 $? "$TMP/o21"
RPC_URL="http://127.0.0.1:9" "$HERE/fetch-bytecode.sh" "https://example.invalid/v2/SECRET" "$TMP/x.hex" > "$TMP/o22" 2>&1
check "an endpoint passed where the address goes is refused" 1 $? "$TMP/o22"
if grep -q "SECRET" "$TMP/o22"; then echo "  FAIL  the refused endpoint was echoed back"; fails=$((fails + 1)); else
  echo "  ok    the refused endpoint is not echoed back"; fi
RPC_URL="http://127.0.0.1:9" "$HERE/fetch-bytecode.sh" 0x1234 "$TMP/x.hex" > "$TMP/o23" 2>&1
check "a short address is refused" 1 $? "$TMP/o23"
if [ -e "$TMP/x.hex" ]; then echo "  FAIL  a fixture was written by a refused call"; fails=$((fails + 1)); else
  echo "  ok    no fixture is written by a refused call"; fi

RPC_URL="http://127.0.0.1:9" "$HERE/fetch-bytecode.sh" "0x12345678901234567890123456789012345678zz" "$TMP/x.hex" > "$TMP/o95" 2>&1
check "an address of the right LENGTH with non-hex digits is refused" 1 $? "$TMP/o95"
if grep -q "not an 0x address" "$TMP/o95"; then echo "  ok    and it is refused as an address, before any endpoint is tried"; else
  echo "  FAIL  the non-hex address got past the address check: $(tail -1 "$TMP/o95")"; fails=$((fails + 1)); fi
if [ -e "$TMP/x.hex" ]; then echo "  FAIL  a fixture was written by a refused call"; fails=$((fails + 1)); fi

# ================================================================= install-v4.sh (the refusals; no network is used)
# git is replaced by a shim that records every call and fails: a refusal must come BEFORE git is touched and before
# anything is created, so the log of git calls must stay empty and the project must stay as it was.
echo "== install-v4.sh =="
IV="$TMP/iv"; mkdir -p "$IV/scripts/lib" "$IV/proj" "$IV/gitshim"
cp "$HERE/install-v4.sh" "$IV/scripts/"; cp "$HERE/lib/parse.sh" "$IV/scripts/lib/"
printf '#!/usr/bin/env bash\necho "git $*" >> "%s/git-calls"\nexit 1\n' "$IV" > "$IV/gitshim/git"; chmod +x "$IV/gitshim/git"
sed -i.bak 's/^V4_CORE_PIN="[0-9a-f]*"/V4_CORE_PIN="main"/' "$IV/scripts/install-v4.sh"
if grep -q '^V4_CORE_PIN="main"' "$IV/scripts/install-v4.sh"; then
  PATH="$IV/gitshim:$PATH" "$IV/scripts/install-v4.sh" "$IV/proj" > "$TMP/o96" 2>&1
  check "a pin that is a branch name, not a commit hash, is refused" 1 $? "$TMP/o96"
  if [ ! -e "$IV/git-calls" ] && [ ! -e "$IV/proj/lib" ] && grep -q "not a full commit hash" "$TMP/o96"; then
    echo "  ok    and it was refused before git was called or lib/ was created"; else
    echo "  FAIL  install-v4.sh went on with a bad pin: $(head -2 "$IV/git-calls" 2> /dev/null)"; fails=$((fails + 1)); fi
else
  echo "  FAIL  could not plant a bad pin in a copy of install-v4.sh (the pin line changed shape?)"; fails=$((fails + 1))
fi
cp "$HERE/install-v4.sh" "$IV/scripts/"; rm -rf "$IV/git-calls" "$IV/proj/lib"
sed -i.bak 's/^V4_CORE_PIN="\([0-9a-f]*\)"/V4_CORE_PIN="\1a"/' "$IV/scripts/install-v4.sh"
PATH="$IV/gitshim:$PATH" "$IV/scripts/install-v4.sh" "$IV/proj" > "$TMP/o97" 2>&1
check "a pin one hex digit too long is refused" 1 $? "$TMP/o97"
if [ ! -e "$IV/git-calls" ]; then echo "  ok    and git was never called for it"; else
  echo "  FAIL  install-v4.sh called git with a 41-digit pin"; fails=$((fails + 1)); fi
cp "$HERE/install-v4.sh" "$IV/scripts/"; rm -rf "$IV/git-calls" "$IV/proj/lib"
PATH="$IV/gitshim:$PATH" "$IV/scripts/install-v4.sh" "$IV/no-such-project" > "$TMP/o98" 2>&1
check "a destination that does not exist is refused" 1 $? "$TMP/o98"
if [ ! -e "$IV/git-calls" ] && [ ! -e "$IV/no-such-project" ]; then echo "  ok    and nothing was created for it, and git was never called"; else
  echo "  FAIL  install-v4.sh created the missing destination or called git"; fails=$((fails + 1)); fi
PATH="$IV/gitshim:$PATH" "$IV/scripts/install-v4.sh" "$IV/proj" > "$TMP/o99" 2>&1
check "control: good pins and a real destination reach git (the shim fails it)" 1 $? "$TMP/o99"
if [ -s "$IV/git-calls" ]; then echo "  ok    and git WAS called: the refusals above are the guards, not a broken copy"; else
  echo "  FAIL  the control never reached git: the refusals above prove nothing"; fails=$((fails + 1)); fi
# the OFFLINE path (V4_LOCAL_SRC): a fake local clone at a commit that is not the pin must be refused before anything is
# copied, and nothing may be fetched. This one needs a real git (to make the clone); the shim is kept out of it.
if command -v git > /dev/null 2>&1; then
  LS="$TMP/localsrc"; mkdir -p "$LS/v4-core"; rm -rf "$IV/proj/lib"
  (cd "$LS/v4-core" && git init -q && printf 'x\n' > f && git add f \
    && git -c user.name=selftest -c user.email=selftest@invalid -c commit.gpgsign=false commit -q -m fake) > /dev/null 2>&1
  # GIT_ALLOW_PROTOCOL=file: whatever the script does, git itself refuses to reach the network from this case
  GIT_ALLOW_PROTOCOL="file" V4_LOCAL_SRC="$LS" "$IV/scripts/install-v4.sh" "$IV/proj" > "$TMP/o114" 2>&1
  check "offline install from a local clone at the WRONG pin is refused" 1 $? "$TMP/o114"
  if grep -q "is at $(git -C "$LS/v4-core" rev-parse HEAD), the pin is" "$TMP/o114" && [ ! -e "$IV/proj/lib/v4-core" ]; then
    echo "  ok    and it names both commits, and nothing was copied into the project"; else
    echo "  FAIL  the wrong-pin clone was not refused by name, or it was copied: $(grep install-v4 "$TMP/o114" | head -2)"; fails=$((fails + 1)); fi
  GIT_ALLOW_PROTOCOL="file" V4_LOCAL_SRC="$TMP/no-such-dir" "$IV/scripts/install-v4.sh" "$IV/proj" > "$TMP/o115" 2>&1
  check "offline install from a directory with no v4-core clone is refused" 1 $? "$TMP/o115"

  # A GOOD local clone, made here: a fake v4-core with the two submodules (lib/forge-std, lib/solmate) as real gitlinks,
  # and a copy of install-v4.sh whose V4_CORE_PIN is that fake's HEAD. Nothing about Uniswap is needed to test the copy.
  gc() { git -c user.name=selftest -c user.email=selftest@invalid -c commit.gpgsign=false -c advice.addEmbeddedRepo=false "$@"; }
  G="$TMP/goodsrc"; GV="$G/v4-core"; mkdir -p "$GV/src" "$GV/lib/forge-std/src" "$GV/lib/solmate/src"
  printf 'contract PoolManager {}\n' > "$GV/src/PoolManager.sol"
  printf 'contract Test {}\n' > "$GV/lib/forge-std/src/Test.sol"; printf 'contract Owned {}\n' > "$GV/lib/solmate/src/Owned.sol"
  for sm in forge-std solmate; do (cd "$GV/lib/$sm" && git init -q && git add -A && gc commit -q -m "$sm") > /dev/null 2>&1; done
  printf '[submodule "lib/forge-std"]\n\tpath = lib/forge-std\n\turl = https://example.invalid/forge-std\n[submodule "lib/solmate"]\n\tpath = lib/solmate\n\turl = https://example.invalid/solmate\n' > "$GV/.gitmodules"
  (cd "$GV" && git init -q && gc add .gitmodules src lib/forge-std lib/solmate && gc commit -q -m fake-v4-core) > /dev/null 2>&1
  PINNED="$TMP/ivpinned"; mkdir -p "$PINNED/scripts/lib"; cp "$HERE/lib/parse.sh" "$PINNED/scripts/lib/"
  sed "s/^V4_CORE_PIN=\"[0-9a-f]*\"/V4_CORE_PIN=\"$(git -C "$GV" rev-parse HEAD)\"/" "$HERE/install-v4.sh" > "$PINNED/scripts/install-v4.sh"
  chmod +x "$PINNED/scripts/install-v4.sh"
  inst() { GIT_ALLOW_PROTOCOL="file" "$PINNED/scripts/install-v4.sh" "$@"; }   # quoted: shellcheck reads a bare file as the file command (SC2209)
  if [ "$(git -C "$GV" ls-tree HEAD lib/solmate | awk '{print $2}')" = "commit" ] && grep -q "^V4_CORE_PIN=\"$(git -C "$GV" rev-parse HEAD)\"" "$PINNED/scripts/install-v4.sh"; then
    mkdir -p "$IV/p1" "$IV/p2" "$IV/p3" "$IV/p4"
    V4_LOCAL_SRC="$G" inst "$IV/p1" > "$TMP/o120" 2>&1; check "control: offline install from a GOOD local clone" 0 $? "$TMP/o120"
    V4_FORCE=1 V4_LOCAL_SRC="$G" inst "$IV/p1" > "$TMP/o121" 2>&1; check "the same, again, with V4_FORCE=1 (it used to fail with a false 'forge-std missing')" 0 $? "$TMP/o121"
    # a clone whose solmate submodule is not checked out: refused, and it must leave nothing behind
    B="$TMP/badsrc"; mkdir -p "$B"; cp -a "$GV" "$B/v4-core"; rm -rf "$B/v4-core/lib/solmate"; mkdir "$B/v4-core/lib/solmate"
    V4_LOCAL_SRC="$B" inst "$IV/p2" > "$TMP/o122" 2>&1; check "offline install from a clone with a submodule missing is refused" 1 $? "$TMP/o122"
    if [ ! -e "$IV/p2/lib" ]; then echo "  ok    and the refusal left no lib/ in a project that had none"; else
      echo "  FAIL  the refused install left a partial lib/: $(cd "$IV/p2" && find lib -maxdepth 2 | head -4 | tr '\n' ' ')"; fails=$((fails + 1)); fi
    V4_LOCAL_SRC="$G" inst "$IV/p2" > "$TMP/o123" 2>&1; check "the next attempt with a GOOD clone, no V4_FORCE, installs (the refusal did not poison it)" 0 $? "$TMP/o123"
    # a refused V4_FORCE over a good install leaves that install as it was
    V4_FORCE=1 V4_LOCAL_SRC="$B" inst "$IV/p1" > "$TMP/o124" 2>&1; check "V4_FORCE=1 from the broken clone over a good install is refused" 1 $? "$TMP/o124"
    if [ -f "$IV/p1/lib/v4-core/lib/solmate/src/Owned.sol" ] && [ -z "$(find "$IV/p1/lib" -maxdepth 1 -name '.install-v4-*')" ]; then
      echo "  ok    and the good install is intact, with no staging directory left behind"; else
      echo "  FAIL  a refused V4_FORCE damaged the install it was refused over"; fails=$((fails + 1)); fi
    # a lib/v4-core that is ALREADY broken (as a refused run of an older install-v4.sh left it): refused without FORCE, and
    # the message says FORCE is the way out; with FORCE it is replaced
    mkdir -p "$IV/p3/lib"; cp -a "$B/v4-core" "$IV/p3/lib/v4-core"
    V4_LOCAL_SRC="$G" inst "$IV/p3" > "$TMP/o125" 2>&1; check "an installed lib/v4-core with a submodule missing is refused without V4_FORCE" 1 $? "$TMP/o125"
    if grep -q "V4_FORCE=1" "$TMP/o125"; then echo "  ok    and the refusal names V4_FORCE=1 as the way out"; else
      echo "  FAIL  the refusal does not say how to recover"; fails=$((fails + 1)); fi
    V4_FORCE=1 V4_LOCAL_SRC="$G" inst "$IV/p3" > "$TMP/o126" 2>&1; check "V4_FORCE=1 with a good clone recovers it" 0 $? "$TMP/o126"
    [ -f "$IV/p3/lib/v4-core/lib/solmate/src/Owned.sol" ] || { echo "  FAIL  V4_FORCE said OK but solmate is not there"; fails=$((fails + 1)); }
    # untracked files in the clone: an untracked .sol under src/ (of the clone or of a submodule) is refused; anything
    # else untracked is copied, as the header says
    U="$TMP/untrsrc"; mkdir -p "$U"; cp -a "$GV" "$U/v4-core"; printf 'contract Extra {}\n' > "$U/v4-core/src/Extra.sol"
    V4_LOCAL_SRC="$U" inst "$IV/p4" > "$TMP/o127" 2>&1; check "a clone with an UNTRACKED .sol under src/ is refused" 1 $? "$TMP/o127"
    if grep -q "src/Extra.sol" "$TMP/o127" && [ ! -e "$IV/p4/lib" ]; then echo "  ok    and it names the file, and nothing was copied"; else
      echo "  FAIL  the untracked .sol was not named, or something was copied"; fails=$((fails + 1)); fi
    V4_ALLOW_UNTRACKED=1 V4_LOCAL_SRC="$U" inst "$IV/p4" > "$TMP/o128" 2>&1; check "the same clone with V4_ALLOW_UNTRACKED=1" 0 $? "$TMP/o128"
    if [ -f "$IV/p4/lib/v4-core/src/Extra.sol" ] && grep -q "src/Extra.sol" "$TMP/o128"; then echo "  ok    and the file was copied AND listed"; else
      echo "  FAIL  V4_ALLOW_UNTRACKED=1 did not copy and list the file"; fails=$((fails + 1)); fi
    rm -f "$U/v4-core/src/Extra.sol"; printf 'contract Evil {}\n' > "$U/v4-core/lib/forge-std/src/Evil.sol"; rm -rf "$IV/p4/lib"
    V4_LOCAL_SRC="$U" inst "$IV/p4" > "$TMP/o129" 2>&1; check "an untracked .sol under a SUBMODULE's src/ is refused too" 1 $? "$TMP/o129"
    if grep -q "lib/forge-std/src/Evil.sol" "$TMP/o129"; then echo "  ok    and it is refused BY NAME (not as some other local change)"; else
      echo "  FAIL  the submodule's untracked .sol was not named"; fails=$((fails + 1)); fi
    rm -f "$U/v4-core/lib/forge-std/src/Evil.sol"; printf 'contract Test { uint256 x; }\n' > "$U/v4-core/lib/forge-std/src/Test.sol"
    V4_LOCAL_SRC="$U" inst "$IV/p4" > "$TMP/o134" 2>&1; check "a changed TRACKED file in a submodule is still a local change, refused" 1 $? "$TMP/o134"
    grep -q "LOCAL CHANGES" "$TMP/o134" || { echo "  FAIL  the changed submodule file was not refused as a local change"; fails=$((fails + 1)); }
    (cd "$U/v4-core/lib/forge-std" && git checkout -q -- src/Test.sol)
    # a submodule holding only untracked files is treated like the clone itself: a .txt in it is copied, not refused
    printf 'notes\n' > "$U/v4-core/src/NOTES.txt"; printf 'notes\n' > "$U/v4-core/lib/forge-std/NOTES.txt"
    V4_LOCAL_SRC="$U" inst "$IV/p4" > "$TMP/o130" 2>&1; check "an untracked file that is not a .sol is copied (the documented limit)" 0 $? "$TMP/o130"
  else
    echo "  FAIL  could not build the fake good clone, or plant its pin (git or the pin line changed shape?)"; fails=$((fails + 1))
  fi
else
  echo "  SKIPPED - no git here: the offline install refusals are NOT proven on this machine"; skipped=1
fi

# ================================================================= install-v4.sh V4_WITH_PERIPHERY=1 (K17b; offline, fake clones)
# The periphery install, from fake local clones made here (nothing about Uniswap is needed): a v4-core with its three
# submodules (OpenZeppelin is needed once the periphery is), a v4-periphery whose tree pins lib/permit2 (checked out) and
# lib/v4-core (a gitlink to the fake core's HEAD), and a copy of install-v4.sh with BOTH pins planted. What is held: the
# periphery's pin, its permit2 submodule installed at what its tree pins, OpenZeppelin in v4-core, and ONE v4-core - the
# periphery's own lib/v4-core never copied (a --recursive clone as the source), never left checked out in a project,
# and a periphery that pins another v4-core refused. Then the kit's remappings, read by forge, send nothing there.
echo "== install-v4.sh V4_WITH_PERIPHERY=1 =="
if command -v git > /dev/null 2>&1; then
  gc() { git -c user.name=selftest -c user.email=selftest@invalid -c commit.gpgsign=false -c advice.addEmbeddedRepo=false "$@"; }
  mkrepo() { # mkrepo <dir> <file> <content>: a one-commit repository
    mkdir -p "$1"; printf '%s\n' "$3" > "$1/$2"; (cd "$1" && git init -q && git add -A && gc commit -q -m init) > /dev/null 2>&1
  }
  PS="$TMP/persrc"; PC="$PS/v4-core"; PP="$PS/v4-periphery"
  mkrepo "$PC/lib/forge-std" Test.sol 'contract Test {}'
  mkrepo "$PC/lib/solmate" Owned.sol 'contract Owned {}'
  mkrepo "$PC/lib/openzeppelin-contracts" IERC20.sol 'interface IERC20 {}'
  mkdir -p "$PC/src"; printf 'contract PoolManager {}\n' > "$PC/src/PoolManager.sol"
  printf '[submodule "lib/forge-std"]\n\tpath = lib/forge-std\n\turl = https://example.invalid/forge-std\n[submodule "lib/solmate"]\n\tpath = lib/solmate\n\turl = https://example.invalid/solmate\n[submodule "lib/openzeppelin-contracts"]\n\tpath = lib/openzeppelin-contracts\n\turl = https://example.invalid/oz\n' > "$PC/.gitmodules"
  (cd "$PC" && git init -q && gc add .gitmodules src lib/forge-std lib/solmate lib/openzeppelin-contracts && gc commit -q -m fake-v4-core) > /dev/null 2>&1
  CORE_SHA="$(git -C "$PC" rev-parse HEAD 2> /dev/null)"
  # mkper <dir> <core sha>: a periphery whose lib/v4-core gitlink is <core sha>; permit2 checked out; lib/v4-core empty
  mkper() {
    mkrepo "$1/lib/permit2" IAllowanceTransfer.sol 'interface IAllowanceTransfer {}'
    mkdir -p "$1/src" "$1/lib/v4-core"; printf 'contract PositionManager {}\n' > "$1/src/PositionManager.sol"
    printf '@uniswap/v4-core/=lib/v4-core/\nopenzeppelin-contracts/=lib/v4-core/lib/openzeppelin-contracts/\n' > "$1/remappings.txt"
    printf '[submodule "lib/v4-core"]\n\tpath = lib/v4-core\n\turl = https://example.invalid/v4-core\n[submodule "lib/permit2"]\n\tpath = lib/permit2\n\turl = https://example.invalid/permit2\n' > "$1/.gitmodules"
    (cd "$1" && git init -q && gc add .gitmodules remappings.txt src lib/permit2 \
      && git update-index --add --cacheinfo "160000,$2,lib/v4-core" && gc commit -q -m fake-v4-periphery) > /dev/null 2>&1
  }
  mkper "$PP" "$CORE_SHA"
  PER_SHA="$(git -C "$PP" rev-parse HEAD 2> /dev/null)"
  # plant <core pin> <periphery pin> <dir>: a copy of install-v4.sh (and its parse.sh) with both pins replaced
  plant() {
    mkdir -p "$3/lib"; cp "$HERE/lib/parse.sh" "$3/lib/"
    sed -e "s/^V4_CORE_PIN=\"[0-9a-f]*\"/V4_CORE_PIN=\"$1\"/" -e "s/^V4_PERIPHERY_PIN=\"[0-9a-f]*\"/V4_PERIPHERY_PIN=\"$2\"/" \
      "$HERE/install-v4.sh" > "$3/install-v4.sh"; chmod +x "$3/install-v4.sh"
  }
  PIN2="$TMP/ivper"; plant "$CORE_SHA" "$PER_SHA" "$PIN2"
  pinst() { GIT_ALLOW_PROTOCOL="file" V4_WITH_PERIPHERY=1 "$PIN2/install-v4.sh" "$@"; }
  if [ -n "$CORE_SHA" ] && [ -n "$PER_SHA" ] && [ "$(git -C "$PP" ls-tree HEAD lib/v4-core | awk '{print $3}')" = "$CORE_SHA" ] \
    && grep -q "^V4_PERIPHERY_PIN=\"$PER_SHA\"" "$PIN2/install-v4.sh"; then
    mkdir -p "$IV/q1" "$IV/q2" "$IV/q3" "$IV/q5" "$IV/q6"
    V4_LOCAL_SRC="$PS" pinst "$IV/q1" > "$TMP/o401" 2>&1; check "control: periphery install from GOOD local clones" 0 $? "$TMP/o401"
    if [ "$(git -C "$IV/q1/lib/v4-periphery" rev-parse HEAD 2> /dev/null)" = "$PER_SHA" ] \
      && [ "$(git -C "$IV/q1/lib/v4-periphery/lib/permit2" rev-parse HEAD 2> /dev/null)" = "$(git -C "$PP" ls-tree HEAD lib/permit2 | awk '{print $3}')" ] \
      && [ -f "$IV/q1/lib/v4-core/lib/openzeppelin-contracts/IERC20.sol" ]; then
      echo "  ok    the periphery at its pin, its lib/permit2 at what its tree pins, OpenZeppelin in v4-core"; else
      echo "  FAIL  the periphery, its permit2 or v4-core's OpenZeppelin is missing or at another commit"; fails=$((fails + 1)); fi
    if [ -d "$IV/q1/lib/v4-periphery/lib/v4-core" ] && [ -z "$(ls -A "$IV/q1/lib/v4-periphery/lib/v4-core")" ] \
      && grep -q "lib/v4-core is NOT initialised (one v4-core)" "$TMP/o401"; then
      echo "  ok    and the periphery's own lib/v4-core is empty, and the install says so"; else
      echo "  FAIL  the periphery's lib/v4-core is not an empty directory, or the install did not say so"; fails=$((fails + 1)); fi
    # the pin is checked: a periphery clone at another commit is refused by name, and nothing of it is copied
    PW="$TMP/perwrong"; mkdir -p "$PW"; cp -a "$PC" "$PW/v4-core"; cp -a "$PP" "$PW/v4-periphery"
    (cd "$PW/v4-periphery" && printf 'x\n' > extra && git add extra && gc commit -q -m moved) > /dev/null 2>&1
    V4_LOCAL_SRC="$PW" pinst "$IV/q2" > "$TMP/o402" 2>&1; check "a periphery clone at ANOTHER commit than its pin is refused" 1 $? "$TMP/o402"
    if grep -q "the pin is $PER_SHA" "$TMP/o402" && [ ! -e "$IV/q2/lib/v4-periphery" ]; then
      echo "  ok    and it names the pin, and nothing of the periphery was copied"; else
      echo "  FAIL  the wrong periphery was not refused by its pin, or it was copied"; fails=$((fails + 1)); fi
    # a --recursive clone as the source: its lib/v4-core is checked out, and it must NOT be copied
    PR="$TMP/perrec"; mkdir -p "$PR"; cp -a "$PC" "$PR/v4-core"; cp -a "$PP" "$PR/v4-periphery"
    rmdir "$PR/v4-periphery/lib/v4-core"; cp -a "$PC" "$PR/v4-periphery/lib/v4-core"
    V4_LOCAL_SRC="$PR" pinst "$IV/q3" > "$TMP/o403" 2>&1; check "a source periphery with its lib/v4-core checked out installs" 0 $? "$TMP/o403"
    if [ -z "$(ls -A "$IV/q3/lib/v4-periphery/lib/v4-core" 2> /dev/null)" ] && grep -q "NOT copied (one v4-core" "$TMP/o403"; then
      echo "  ok    without its second v4-core, and it says so"; else
      echo "  FAIL  the periphery's own v4-core was copied into the project: two v4-cores"; fails=$((fails + 1)); fi
    # a project whose periphery has its lib/v4-core checked out (by hand, or by an older install): refused, V4_FORCE named
    mkdir -p "$IV/q4"; cp -a "$IV/q1/lib" "$IV/q4/lib"; rmdir "$IV/q4/lib/v4-periphery/lib/v4-core"
    cp -a "$PC" "$IV/q4/lib/v4-periphery/lib/v4-core"
    V4_LOCAL_SRC="$PS" pinst "$IV/q4" > "$TMP/o404" 2>&1; check "an installed periphery with its lib/v4-core checked out is refused" 1 $? "$TMP/o404"
    grep -q "V4_FORCE=1 V4_WITH_PERIPHERY=1" "$TMP/o404" || { echo "  FAIL  the refusal does not name the way out"; fails=$((fails + 1)); }
    V4_FORCE=1 V4_LOCAL_SRC="$PS" pinst "$IV/q4" > "$TMP/o405" 2>&1; check "V4_FORCE=1 re-installs it with one v4-core" 0 $? "$TMP/o405"
    [ -z "$(ls -A "$IV/q4/lib/v4-periphery/lib/v4-core" 2> /dev/null)" ] || { echo "  FAIL  V4_FORCE left the second v4-core"; fails=$((fails + 1)); }
    # a periphery that pins ANOTHER v4-core than the script: refused (it would be built against a core it was not written for)
    PX="$TMP/perother"; mkdir -p "$PX"; cp -a "$PC" "$PX/v4-core"; OTHER_SHA="$(git -C "$PC/lib/solmate" rev-parse HEAD)"
    mkper "$PX/v4-periphery" "$OTHER_SHA"
    PIN3="$TMP/ivper3"; plant "$CORE_SHA" "$(git -C "$PX/v4-periphery" rev-parse HEAD)" "$PIN3"
    GIT_ALLOW_PROTOCOL="file" V4_WITH_PERIPHERY=1 V4_LOCAL_SRC="$PX" "$PIN3/install-v4.sh" "$IV/q5" > "$TMP/o406" 2>&1
    check "a periphery that pins another v4-core than the script is refused" 1 $? "$TMP/o406"
    grep -q "pins v4-core at $OTHER_SHA" "$TMP/o406" || { echo "  FAIL  the refusal does not name the periphery's v4-core pin"; fails=$((fails + 1)); }
    # ...and nothing of the refused periphery stays in lib/ (K17c, from the verifier V17b: it used to stay, under
    # INSTALL-V4 FAILED); v4-core, which passed, does
    if [ ! -e "$IV/q5/lib/v4-periphery" ] && [ "$(git -C "$IV/q5/lib/v4-core" rev-parse HEAD 2> /dev/null)" = "$CORE_SHA" ] \
      && grep -q "the periphery this run fetched is removed" "$TMP/o406"; then
      echo "  ok    and the refused periphery is removed from lib/ (v4-core, which passed, stays), and it says so"; else
      echo "  FAIL  the refused periphery stayed in lib/, or v4-core went with it, or the run did not say"; fails=$((fails + 1)); fi
    # the same refusal over a project that HAD a good periphery installed: that one is back, as it was
    mkdir -p "$IV/q8"; cp -a "$IV/q1/lib" "$IV/q8/lib"
    GIT_ALLOW_PROTOCOL="file" V4_WITH_PERIPHERY=1 V4_LOCAL_SRC="$PX" "$PIN3/install-v4.sh" "$IV/q8" > "$TMP/o411" 2>&1
    check "a periphery that pins another v4-core, over an installed periphery: refused" 1 $? "$TMP/o411"
    q8_extra=""
    for e in "$IV/q8/lib"/* "$IV/q8/lib"/.[!.]*; do
      [ -e "$e" ] || continue
      case "${e##*/}" in v4-core | v4-periphery) ;; *) q8_extra="$q8_extra ${e##*/}" ;; esac
    done
    if [ "$(git -C "$IV/q8/lib/v4-periphery" rev-parse HEAD 2> /dev/null)" = "$PER_SHA" ] \
      && [ "$(git -C "$IV/q8/lib/v4-periphery/lib/permit2" rev-parse HEAD 2> /dev/null)" = "$(git -C "$IV/q1/lib/v4-periphery/lib/permit2" rev-parse HEAD 2> /dev/null)" ] \
      && [ -z "$q8_extra" ]; then
      echo "  ok    and the periphery installed before is back, at its commit, with its permit2, and nothing else is left in lib/"; else
      echo "  FAIL  the periphery installed before is not back as it was, or lib/ holds more:${q8_extra:- -}"; fails=$((fails + 1)); fi
    # a periphery clone without its permit2 checked out: refused, nothing of it copied
    PN="$TMP/pernop2"; mkdir -p "$PN"; cp -a "$PC" "$PN/v4-core"; cp -a "$PP" "$PN/v4-periphery"
    rm -rf "$PN/v4-periphery/lib/permit2"; mkdir "$PN/v4-periphery/lib/permit2"; rm -rf "$IV/q2/lib"
    V4_LOCAL_SRC="$PN" pinst "$IV/q2" > "$TMP/o407" 2>&1; check "a periphery clone without lib/permit2 is refused" 1 $? "$TMP/o407"
    [ ! -e "$IV/q2/lib/v4-periphery" ] || { echo "  FAIL  the periphery without permit2 was installed"; fails=$((fails + 1)); }
    # without V4_WITH_PERIPHERY, OpenZeppelin is not asked for: the everyday install is what it was
    CS="$TMP/coreonly"; mkdir -p "$CS"; cp -a "$PC" "$CS/v4-core"
    rm -rf "$CS/v4-core/lib/openzeppelin-contracts"; mkdir "$CS/v4-core/lib/openzeppelin-contracts"
    GIT_ALLOW_PROTOCOL="file" V4_LOCAL_SRC="$CS" "$PIN2/install-v4.sh" "$IV/q6" > "$TMP/o408" 2>&1
    check "without V4_WITH_PERIPHERY a v4-core clone without OpenZeppelin still installs" 0 $? "$TMP/o408"
    # ...and with it, the same clone is refused: the position manager imports OpenZeppelin's IERC20 through IWETH9
    mkdir -p "$IV/q7"; cp -a "$PP" "$CS/v4-periphery"
    V4_LOCAL_SRC="$CS" pinst "$IV/q7" > "$TMP/o410" 2>&1; check "with V4_WITH_PERIPHERY a v4-core clone without OpenZeppelin is refused" 1 $? "$TMP/o410"
    grep -q "lib/openzeppelin-contracts is missing" "$TMP/o410" || { echo "  FAIL  the refusal does not name OpenZeppelin"; fails=$((fails + 1)); }
  else
    echo "  FAIL  could not build the fake periphery clones, or plant their pins (git or the pin lines changed shape?)"; fails=$((fails + 1))
  fi
else
  echo "  SKIPPED - no git here: the periphery install is NOT proven on this machine"; skipped=1
fi
# the kit's remappings, read by forge, over a fake lib/ with the periphery installed: `@uniswap/v4-core/` and every other
# name resolve into lib/v4-core, NOTHING into lib/v4-periphery/lib/v4-core (forge also reads the periphery's own
# remappings.txt, and without the kit's `openzeppelin-contracts/` line it maps that name into the periphery's v4-core)
if command -v forge > /dev/null 2>&1; then
  RM="$TMP/remap"; mkdir -p "$RM/lib"; cp "$HERE/../foundry-kit/v4/remappings.txt" "$RM/"
  printf '[profile.default]\nsrc = "src"\nlibs = ["lib"]\n' > "$RM/foundry.toml"
  mkdir -p "$RM/src" "$RM/lib/v4-core/src" "$RM/lib/v4-core/lib/forge-std/src" "$RM/lib/v4-periphery/src" \
    "$RM/lib/v4-periphery/lib/v4-core" "$RM/lib/v4-periphery/lib/permit2/src"
  printf '@uniswap/v4-core/=lib/v4-core/\nopenzeppelin-contracts/=lib/v4-core/lib/openzeppelin-contracts/\nsolmate/=lib/v4-core/lib/solmate/\n' > "$RM/lib/v4-periphery/remappings.txt"
  (cd "$RM" && forge remappings > "$TMP/o409" 2>&1); check "forge reads the kit's remappings over a periphery install" 0 $? "$TMP/o409"
  if grep -q '^@uniswap/v4-core/=lib/v4-core/$' "$TMP/o409" && grep -q '^permit2/=lib/v4-periphery/lib/permit2/$' "$TMP/o409" \
    && ! grep -q 'lib/v4-periphery/lib/v4-core' "$TMP/o409"; then
    echo "  ok    @uniswap/v4-core/ and permit2/ resolve to the one v4-core and the periphery's permit2; nothing into its v4-core"; else
    echo "  FAIL  a remapping resolves into lib/v4-periphery/lib/v4-core, or a periphery name is missing: $(grep 'v4-periphery/lib/v4-core\|^@uniswap\|^permit2' "$TMP/o409" | tr '\n' ' ')"; fails=$((fails + 1)); fi
else
  echo "  SKIPPED - no forge here: the kit's remappings over a periphery install are NOT proven on this machine"; skipped=1
fi

# ================================================================= parse.sh, on fixtures (real forge 1.8.1 output + near misses)
# scripts/test/fixtures: `*-real-*` captured from forge 1.8.1 on the kit's own projects (2026-09-23); `*-nm-*` near
# misses written by hand - the shapes an inline `grep | sed` misread in silence. A CRLF copy is made here, not stored:
# .gitattributes normalises line ends, and a stored CRLF fixture would silently become an LF one.
echo "== parse.sh =="
expect_out() { # expect_out <label> <expected stdout> <expected rc> <command...>
  local label="$1" want="$2" want_rc="$3" got rc; shift 3
  got="$("$@" 2> /dev/null)"; rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = "$want_rc" ]; then echo "  ok    $label (rc=$rc)"; else
    echo "  FAIL  $label: got \"$got\" rc=$rc, expected \"$want\" rc=$want_rc"; fails=$((fails + 1)); fi
}
first_row() { parse_sizes "$1" | grep "^$2 "; }
count_kept() { sim_ledger_filter "$1" | wc -l | tr -d ' '; }
expect_out "summary, real, 6 suites" "103 0 0 103" 0 parse_test_summary "$FIX/summary-real-many-suites.txt"
expect_out "summary, real, 1 suite ('test suite', singular)" "1 0 0 1" 0 parse_test_summary "$FIX/summary-real-one-suite.txt"
expect_out "summary, real, a failure and a skip" "1 1 1 3" 0 parse_test_summary "$FIX/summary-real-failed-and-skipped.txt"
sed 's/$/\r/' "$FIX/summary-real-one-suite.txt" > "$TMP/summary-crlf.txt"
expect_out "summary, the same with CRLF line ends" "1 0 0 1" 0 parse_test_summary "$TMP/summary-crlf.txt"
expect_out "summary, real, no test matched: there is none" "" 1 parse_test_summary "$FIX/summary-real-no-tests.txt"
expect_out "summary printed only by a test's console: there is none" "" 1 parse_test_summary "$FIX/summary-nm-console-only.txt"
expect_out "summary with no 'skipped' field: refused" "" 2 parse_test_summary "$FIX/summary-nm-no-skipped-field.txt"
expect_out "summary whose numbers do not add up: refused" "" 2 parse_test_summary "$FIX/summary-nm-total-mismatch.txt"
expect_out "campaigns, real, grouped (one line for 6 invariants)" "1 4096 4096" 0 parse_invariant_runs "$FIX/summary-real-many-suites.txt"
expect_out "campaigns, real, two, one printing a fake campaign line in its logs" "2 32 16" 0 parse_invariant_runs "$FIX/invariant-real-pass-with-logs.txt"
expect_out "campaigns, real, a failing one (forge prints it twice)" "1 1 1" 0 parse_invariant_runs "$FIX/invariant-real-fail.txt"
expect_out "campaign lines only inside a test's logs: none ran" "0 0 0" 0 parse_invariant_runs "$FIX/invariant-nm-console-only.txt"
expect_out "suites by directory, real" "test=4 test/examples=2" 0 parse_suites_by_dir "$FIX/summary-real-many-suites.txt"
# K32c (V32b): a finding's test that accepts ANY revert, in the three shapes mutate.sh warns on - read in the CODE, never in a
# comment (V32b's Q-1 cited the rule in its NatSpec and was warned against for it)
AR="$TMP/anyrevert"; mkdir -p "$AR"
cat > "$AR/bare.sol" << 'EOF'
contract T is Test { function test_bare() public { vm.prank(bob);
  vm.expectRevert(
  ); r.register(1); } }
EOF
cat > "$AR/exact.sol" << 'EOF'
/// @notice the exact error - not a bare vm.expectRevert(), which EVIDENCE section 2 refuses
contract T is Test { function test_exact() public { string memory u = "https://example.test/"; // vm.expectRevert()
  /* nor vm.expectRevert( ) here,
     nor (bool ok,) = address(r).call(""); assertFalse(ok); */
  vm.expectRevert(Reg.Taken.selector); r.register(1); } }
EOF
cat > "$AR/call.sol" << 'EOF'
contract T is Test { function test_call() public { vm.prank(bob);
  (bool ok,) = address(r).call(abi.encodeCall(Reg.register, (1)));
  assertFalse(ok, "must revert"); } }
EOF
cat > "$AR/call-data.sol" << 'EOF'
contract T is Test { function test_call() public {
  (bool ok, bytes memory ret) = address(r).call{value: 0}(abi.encodeCall(Reg.register, (1)));
  assertFalse(ok); assertEq(bytes4(ret), Reg.Taken.selector); } }
EOF
cat > "$AR/catch.sol" << 'EOF'
contract T is Test { function test_catch() public {
  try r.register(1) { fail(); } catch (bytes memory reason) { emit log_bytes(hex""); } } }
EOF
cat > "$AR/catch-cmp.sol" << 'EOF'
contract T is Test { function test_catch() public {
  try r.register(1) { fail(); } catch (bytes memory reason) { assertEq(bytes4(reason), Reg.Taken.selector); }
  try r.register(2) {} catch { fail(); } } }
EOF
# K32d (V32c): a string is not code either - its text is blanked, its quotes kept (Q-5: the rule cited in an assertion's
# message next to the exact selector; "no try/catch {} here"); a catch that only logs a string with "revert" in it
# accepts any revert; and a known gap, documented: the flag asserted false in a helper under another name (Q-6)
cat > "$AR/strings.sol" << 'EOF'
contract T is Test { function test_exact() public {
  vm.expectRevert(Reg.Taken.selector); r.register(1);
  assertEq(r.count(), 1, "exact selector above, not a bare vm.expectRevert()");
  emit log("no try/catch {} here, nor (bool ok,) = address(r).call(x); assertFalse(ok);"); emit log('it\'s "fine"'); } }
EOF
cat > "$AR/catch-log.sol" << 'EOF'
contract T is Test { function test_catch() public {
  try r.register(1) { fail(); } catch { emit log("revert as expected"); } } }
EOF
cat > "$AR/helper.sol" << 'EOF'
contract T is Test { function _mustFail(bool success) internal { assertFalse(success, "must revert"); }
  function test_call() public { (bool ok,) = address(r).call(abi.encodeCall(Reg.register, (1))); _mustFail(ok); } }
EOF
cat "$AR/bare.sol" "$AR/call.sol" > "$AR/all.sol"; printf 'contract U { function f() public { try r.g() {} catch {} } }\n' >> "$AR/all.sol"
expect_out "any revert: a bare vm.expectRevert() over two lines" "bare-expectRevert" 0 any_revert_shapes "$AR/bare.sol"
expect_out "any revert: none in the code - the rule cited in comments, a URL in a string, the exact selector" "" 0 any_revert_shapes "$AR/exact.sol"
expect_out "any revert: a low-level call whose success flag is only asserted false (V32b's Q-2)" "call-asserted-false" 0 any_revert_shapes "$AR/call.sol"
expect_out "any revert: the same call with its returned data compared: none" "" 0 any_revert_shapes "$AR/call-data.sol"
expect_out "any revert: a catch that never compares the error it names" "catch-not-compared" 0 any_revert_shapes "$AR/catch.sol"
expect_out "any revert: a catch that compares it, and one that fails the test: none" "" 0 any_revert_shapes "$AR/catch-cmp.sol"
expect_out "any revert: all three in one file, each named once" "$(printf 'bare-expectRevert\ncall-asserted-false\ncatch-not-compared')" 0 any_revert_shapes "$AR/all.sol"
expect_out "any revert: a file that cannot be read" "" 1 any_revert_shapes "$AR/no-such.sol"
expect_out "any revert: none in strings - the rule in an assertion's message, \"no try/catch {} here\" (V32c's Q-5)" "" 0 any_revert_shapes "$AR/strings.sol"
expect_out "any revert: a catch that only logs a string saying \"revert\" accepts any revert" "catch-not-compared" 0 any_revert_shapes "$AR/catch-log.sol"
expect_out "any revert: KNOWN GAP, documented - the flag asserted false in a helper under another name is not seen (V32c's Q-6)" "" 0 any_revert_shapes "$AR/helper.sol"
expect_out "sizes, real: ToyVault's runtime" "ToyVault 1672" 0 first_row "$FIX/sizes-real.txt" ToyVault
expect_out "sizes, columns in another order: still the RUNTIME column" "ToyVault 1672" 0 first_row "$FIX/sizes-nm-columns-swapped.txt" ToyVault
expect_out "sizes, no header: refused" "" 2 parse_sizes "$FIX/sizes-nm-no-header.txt"
expect_out "sizes, the runtime column renamed: refused" "" 2 parse_sizes "$FIX/sizes-nm-renamed-header.txt"
expect_out "ledger: the 2 well-formed lines are kept" "2" 0 count_kept "$FIX/sim-nm-nonnumeric.tsv"
expect_out "ledger: '12a', '-' and an empty field make 3 malformed lines" "3" 0 sim_ledger_malformed "$FIX/sim-nm-nonnumeric.tsv"
expect_out "address: 0x and 40 hex digits" "" 0 is_evm_address 0x000000000000000000000000000000000000dEaD
expect_out "address: 39 hex digits and a z" "" 1 is_evm_address 0x000000000000000000000000000000000000dEaz
expect_out "address: 41 hex digits" "" 1 is_evm_address 0x000000000000000000000000000000000000dEaD0
expect_out "pin: a full lower-case sha" "" 0 is_git_sha 59d3ecf53afa9264a16bba0e38f4c5d2231f80bc
expect_out "pin: a short sha" "" 1 is_git_sha 59d3ecf
expect_out "pin: upper case (not what git prints)" "" 1 is_git_sha 59D3ECF53AFA9264A16BBA0E38F4C5D2231F80BC
first_row_both() { parse_sizes_both "$1" | grep "^$2 "; }
expect_out "sizes, both columns, real: ToyVault's runtime AND initcode" "ToyVault 1672 1811" 0 first_row_both "$FIX/sizes-real.txt" ToyVault
expect_out "sizes, both columns, in another order: still read by header" "ToyVault 1672 1811" 0 first_row_both "$FIX/sizes-nm-columns-swapped.txt" ToyVault
expect_out "sizes, a table without the Initcode column: refused (never initcode 0)" "" 2 parse_sizes_both "$FIX/sizes-nm-no-initcode.txt"
# K32 (FR16): a project that reaches the kit by a RELATIVE path out of itself (`../lib/hook-gauntlet/...`) gets some of the
# kit's and v4-core's sources compiled twice, under that path and under the absolute one, and forge then names each such
# contract `<name> (<path>)` - a name with a space in it, which the scripts downstream read as the size. The fixture is
# forge 1.8.1's table from that layout (rows cut; the absolute root replaced by /home/user/work). One token now: <name>@<path>.
expect_out "sizes, real, a contract forge names with its path: one token, <name>@<path>" \
  "BalanceDeltaLibrary.default@../lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/src/types/BalanceDelta.sol 91 141" 0 \
  first_row_both "$FIX/sizes-real-v4-two-paths.txt" "BalanceDeltaLibrary.default@../lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/src/types/BalanceDelta.sol"
expect_out "sizes, the same table, runtime column only: the same token" \
  "BalanceDeltaLibrary.manager@/home/user/work/lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/src/types/BalanceDelta.sol 100" 0 \
  first_row "$FIX/sizes-real-v4-two-paths.txt" "BalanceDeltaLibrary.manager@/home/user/work/lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/src/types/BalanceDelta.sol"
# K32: the time of the suites that ran a campaign, which fuzz-long.sh scales into what the long campaign will cost
expect_out "campaign time, real: the one suite with a campaign (1.20s), not the five without" "1 1.20" 0 parse_campaign_seconds "$FIX/summary-real-many-suites.txt"
expect_out "campaign time, real: two suites with a campaign, added (4.15ms + 4.27ms)" "2 0.01" 0 parse_campaign_seconds "$FIX/invariant-real-pass-with-logs.txt"
expect_out "campaign time, a log with no campaign: none" "" 1 parse_campaign_seconds "$FIX/summary-real-one-suite.txt"
sed 's/finished in 1\.20s /finished in 1.20 fortnights /' "$FIX/summary-real-many-suites.txt" > "$TMP/camp-nm-unit.txt"
expect_out "campaign time, a campaign suite whose time is of another shape: refused, never 0" "" 2 parse_campaign_seconds "$TMP/camp-nm-unit.txt"
first_err_is() { first_error_line "$1" | cut -c1-60; }
expect_out "first error, real (v4 module copied without its parent): the unresolved import, not the warnings" \
  'Error (6275): Source "../src/HostileERC20.sol" not found: Fi' 0 first_err_is "$FIX/build-real-v4-without-copy-root.txt"
expect_out "first error, when the log ENDS in warnings" 'Error (6275): Source "../src/InvariantBase.sol" not found: F' 0 \
  first_err_is "$FIX/build-nm-error-then-warnings.txt"
expect_out "first error, in a log with none: refused" "" 1 first_error_line "$FIX/summary-real-one-suite.txt"
expect_out "build verdict, real: nothing compiled" "skipped" 0 parse_build_verdict "$FIX/build-real-noop.txt"
expect_out "build verdict, real: compiled (the lint notes after it are not read)" "compiled" 0 parse_build_verdict "$FIX/build-real-compiled.txt"
expect_out "build verdict, a log with neither line: refused (never read as nothing compiled)" "" 1 parse_build_verdict "$FIX/build-nm-neither.txt"

# ---- the scripts that read those shapes, fed them through a forge SHIM (no compiler runs): the parser is only half of
# the guard, the other half is the script acting on its refusal
FS="$TMP/fshim"; FP="$TMP/fproj"; mkdir -p "$FS" "$FP/src" "$FP/out/A.sol" "$FP/cache"
# its sources and cache are the forge-built freshness fixture, so the battery's freshness step reads a real cache
cp -R "$FIX/fresh-project/." "$FP/"; printf '[profile.default]\n' > "$FP/foundry.toml"
printf '{}\n' > "$FP/out/A.sol/A.json"; cp "$FIX/fresh-project.cache.json" "$FP/cache/solidity-files-cache.json"
touch -d "@1700000000" "$FP/src/A.sol" "$FP/foundry.toml"; touch -d "@1700000100" "$FP/out/A.sol/A.json" "$FP/cache/solidity-files-cache.json"
# the shim answers `forge build --sizes` with $SHIM_SIZES and `forge test` with $SHIM_TEST, and any other build with forge's
# "nothing to compile" (the freshness step builds too, and reads that answer as FRESH)
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" --sizes "*) cat "$SHIM_SIZES" ;;\n  " test "*) cat "$SHIM_TEST" ;;\n  *) echo "No files changed, compilation skipped" ;;\nesac\nexit 0\n' > "$FS/forge"; chmod +x "$FS/forge"
export SHIM_SIZES="$FIX/sizes-real.txt" SHIM_TEST="$FIX/summary-real-one-suite.txt"
PATH="$FS:$PATH" OUT_DIR="$TMP/fb" "$HERE/battery.sh" "$FP" > "$TMP/o100" 2>&1; check "battery through the shim on a real green summary (the control)" 0 $? "$TMP/o100"
SHIM_TEST="$FIX/summary-nm-console-only.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fb" "$HERE/battery.sh" "$FP" > "$TMP/o101" 2>&1
check "battery: a summary printed only by a test's console is NO summary" 1 $? "$TMP/o101"
SHIM_TEST="$FIX/summary-nm-no-skipped-field.txt" ALLOW_SKIPS=1 PATH="$FS:$PATH" OUT_DIR="$TMP/fb" "$HERE/battery.sh" "$FP" > "$TMP/o102" 2>&1
check "battery: a summary of another shape is refused, even with ALLOW_SKIPS=1" 1 $? "$TMP/o102"
SHIM_SIZES="$FIX/sizes-nm-columns-swapped.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o103" 2>&1
check "size.sh on a table with its columns in another order" 0 $? "$TMP/o103"
if grep -Eq '^ToyVault +1672 +22904' "$TMP/o103"; then echo "  ok    and it read the RUNTIME column by its header (1672, not the initcode 1811)"; else
  echo "  FAIL  size.sh read the wrong column: $(grep ToyVault "$TMP/o103")"; fails=$((fails + 1)); fi
SHIM_SIZES="$FIX/sizes-real.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o110" 2>&1
check "size.sh on the real table" 0 $? "$TMP/o110"
if grep -Eq '^ToyVault +1672 +22904 +1811 +47341 ' "$TMP/o110"; then echo "  ok    and it reports the INITCODE and its margin to 49 152 next to the runtime (1811, 47341)"; else
  echo "  FAIL  size.sh does not report the initcode size and margin: $(grep ToyVault "$TMP/o110")"; fails=$((fails + 1)); fi
SHIM_SIZES="$FIX/sizes-real.txt" MIN_INIT_MARGIN=48000 PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o111" 2>&1
check "size.sh: an initcode margin below MIN_INIT_MARGIN fails" 1 $? "$TMP/o111"
# a hook compiled next to the PoolManager's IR restriction has two builds, `<Hook>` and `<Hook>.manager` - the one the
# tests deploy, the one to cite (QUICKSTART 7b). Named on the command line, the hook's .manager row is in sizes.txt too
# (it was left out: `$1 == name` only). The fixture is cut from the v4 battery's own --sizes table (forge 1.8.1).
SHIM_SIZES="$FIX/sizes-real-v4-manager.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fsm" "$HERE/size.sh" "$FP" DeltaFeeHook > "$TMP/o666" 2>&1
check "size.sh DeltaFeeHook on the v4 module's table" 0 $? "$TMP/o666"
if [ "$(cut -d' ' -f1 "$TMP/fsm/sizes.txt" 2> /dev/null | tr '\n' ' ')" = "DeltaFeeHook DeltaFeeHook.manager " ]; then
  echo "  ok    and sizes.txt holds both builds of the hook - its .manager row included - and nothing else"; else
  echo "  FAIL  sizes.txt for DeltaFeeHook: $(tr '\n' ';' < "$TMP/fsm/sizes.txt" 2> /dev/null)"; fails=$((fails + 1)); fi
SHIM_SIZES="$FIX/sizes-nm-no-initcode.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o112" 2>&1
check "size.sh on a table with no Initcode column measures nothing (the phase-2 gate needs both)" 2 $? "$TMP/o112"
SHIM_SIZES="$FIX/sizes-nm-renamed-header.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o104" 2>&1
check "size.sh on a table whose runtime column is not called Runtime Size measures nothing" 2 $? "$TMP/o104"
SHIM_SIZES="$FIX/sizes-nm-no-header.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o105" 2>&1
check "size.sh on a table with no header measures nothing" 2 $? "$TMP/o105"
# K26c (V26b): no script writes its reports into a tree where the kit's convention is not installed (no .gauntlet/:
# someone else's tree, doctrine/RETROFIT.md). battery.sh, size.sh, census.sh (run and --aggregate), fuzz-long.sh
# (USE_BENCH=0 too) and mutate.sh made <project>/.gauntlet/reports in one; each now refuses before writing anything,
# unless OUT_DIR is outside the tree, the tree is a bench (bench.sh's .gauntlet-bench marker) or the kit's own
# foundry-kit/ (scripts/lib/owner-tree.sh). $FP has no .gauntlet/ here; the shim answers any forge call.
own_clean() { # own_clean <label> <out file> [<path that must not exist>...]: nothing written into $FP
  local label="$1" out="$2" p left=""; shift 2
  for p in "$FP/.gauntlet" "$FP/census" "$@"; do [ ! -e "$p" ] || left="$left ${p#"$FP"/}"; done
  if [ -z "$left" ] && grep -qF 'Refusing, nothing written: set OUT_DIR=<a directory outside the project>' "$out" && grep -q 'RETROFIT' "$out"; then
    echo "  ok    $label: refused before writing, with the reason and what to set"; else
    echo "  FAIL  $label: left in the owner's tree:${left:- nothing}"; sed "s/^/        | /" "$out" | head -8; fails=$((fails + 1)); fi
  rm -rf "$FP/.gauntlet" "$FP/census" "$@"
}
PATH="$FS:$PATH" env -u OUT_DIR "$HERE/battery.sh" "$FP" > "$TMP/o813" 2>&1; check "battery.sh in a tree with no .gauntlet/, OUT_DIR unset: refused, nothing run" 2 $? "$TMP/o813"
own_clean "battery.sh" "$TMP/o813"
PATH="$FS:$PATH" env -u OUT_DIR "$HERE/size.sh" "$FP" ToyVault > "$TMP/o814" 2>&1; check "size.sh in a tree with no .gauntlet/, OUT_DIR unset: refused" 2 $? "$TMP/o814"
own_clean "size.sh" "$TMP/o814"
PATH="$FS:$PATH" OUT_DIR="$FP/reports" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o815" 2>&1; check "size.sh with OUT_DIR inside that tree (given, not outside): refused" 2 $? "$TMP/o815"
own_clean "size.sh, OUT_DIR=<project>/reports" "$TMP/o815" "$FP/reports"
PATH="$FS:$PATH" OUT_DIR="rel-reports" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o816" 2>&1; check "size.sh with a relative OUT_DIR (under the project): refused" 2 $? "$TMP/o816"
own_clean "size.sh, OUT_DIR relative" "$TMP/o816" "$FP/rel-reports"
# K32 (FR16): size.sh lists a source forge compiled under two paths ONCE - the relative path, resolved from the project,
# and the absolute one are the same file - under its plain name when no other file has that name, and with the SIZES in
# the columns (FR16's sizes.txt: "BalanceDeltaLibrary.manager (/home/...) 24576 100 49052", the path read as the runtime).
TW="$TMP/twopaths"; mkdir -p "$TW/proj/.gauntlet"; TWR="$(cd "$TW" && pwd -P)"; TWS="$TW/proj/.gauntlet/reports/sizes.txt"
sed "s|/home/user/work|$TWR|g" "$FIX/sizes-real-v4-two-paths.txt" > "$TMP/sizes-two.txt"
SHIM_SIZES="$TMP/sizes-two.txt" PATH="$FS:$PATH" "$HERE/size.sh" "$TW/proj" > "$TMP/o950" 2>&1; check "size.sh on a table that names sources by two paths (FR16's layout)" 0 $? "$TMP/o950"
if [ "$(grep -c '^BalanceDeltaLibrary' "$TWS")" = "2" ] && grep -qx 'BalanceDeltaLibrary.default 91 24485 141 49011' "$TWS" \
  && grep -qx 'BalanceDeltaLibrary.manager 100 24476 128 49024' "$TWS" && grep -qx 'SafeCast.manager 16 24560 44 49108' "$TWS" \
  && ! grep -q '[(@]' "$TWS" && grep -q '2 row(s) .* listed once' "$TMP/o950"; then
  echo "  ok    each source once, under its plain name, with its own sizes and margins, and the run says how many were merged"; else
  echo "  FAIL  the two-path table:"; sed "s/^/        | /" "$TWS" "$TMP/o950" | head -16; fails=$((fails + 1)); fi
SHIM_SIZES="$TMP/sizes-two.txt" PATH="$FS:$PATH" "$HERE/size.sh" "$TW/proj" BalanceDeltaLibrary > "$TMP/o951" 2>&1; check "the same, one contract named" 0 $? "$TMP/o951"
if [ "$(wc -l < "$TWS" | tr -d ' ')" = "2" ] && grep -qx 'BalanceDeltaLibrary.manager 100 24476 128 49024' "$TWS"; then
  echo "  ok    and naming it gives its two builds, once each"; else echo "  FAIL  named:"; sed "s/^/        | /" "$TWS"; fails=$((fails + 1)); fi
# two DIFFERENT files with one name stay two rows, each with its path (one token): nothing is merged that is not the same file
sed "s|/home/user/work|/elsewhere|g" "$FIX/sizes-real-v4-two-paths.txt" > "$TMP/sizes-two-other.txt"
SHIM_SIZES="$TMP/sizes-two-other.txt" PATH="$FS:$PATH" "$HERE/size.sh" "$TW/proj" > "$TMP/o952" 2>&1; check "size.sh on two files of one name that are NOT the same file" 0 $? "$TMP/o952"
if [ "$(grep -c '^BalanceDeltaLibrary.*@' "$TWS")" = "4" ] && grep -qx 'BalanceDeltaLibrary.manager@/elsewhere/lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/src/types/BalanceDelta.sol 100 24476 128 49024' "$TWS" \
  && ! grep -q 'listed once' "$TMP/o952"; then
  echo "  ok    four rows, each named with its path, none merged"; else echo "  FAIL  two different files merged or misread:"; sed "s/^/        | /" "$TWS"; fails=$((fails + 1)); fi
rm -rf "$TW"
printf 'run\taction\tcalls\treverts\n1\tinc\t10\t0\n' > "$TMP/own.tsv"
PATH="$FS:$PATH" env -u OUT_DIR CORE=inc "$HERE/census.sh" --aggregate "$TMP/own.tsv" "$FP" > "$TMP/o817" 2>&1; check "the census gate (QUICKSTART's line) on a tree with no .gauntlet/: refused" 2 $? "$TMP/o817"
own_clean "census.sh --aggregate <tsv> <project>" "$TMP/o817"
case "$(tail -1 "$TMP/o817")" in "census gate: FAILED - no record written"*) echo "  ok    and its last line is the gate's verdict: FAILED, no record written" ;;
  *) echo "  FAIL  the gate's last line: $(tail -1 "$TMP/o817")"; fails=$((fails + 1)) ;; esac
PATH="$FS:$PATH" env -u OUT_DIR "$HERE/census.sh" "$FP" > "$TMP/o818" 2>&1; check "census.sh (run mode) on a tree with no .gauntlet/: refused" 2 $? "$TMP/o818"
own_clean "census.sh <project>" "$TMP/o818"
PATH="$FS:$PATH" env -u OUT_DIR USE_BENCH=0 "$HERE/fuzz-long.sh" "$FP" > "$TMP/o819" 2>&1; check "fuzz-long.sh USE_BENCH=0 on a tree with no .gauntlet/: refused" 2 $? "$TMP/o819"
own_clean "fuzz-long.sh USE_BENCH=0" "$TMP/o819"
PATH="$FS:$PATH" env -u OUT_DIR BENCH_ROOT="$TMP/own-benches" "$HERE/fuzz-long.sh" "$FP" > "$TMP/o820" 2>&1; check "fuzz-long.sh with BENCH_ROOT outside and OUT_DIR unset: refused" 2 $? "$TMP/o820"
[ ! -e "$TMP/own-benches" ] || { echo "  FAIL  and a bench was made under BENCH_ROOT"; fails=$((fails + 1)); }
own_clean "fuzz-long.sh, BENCH_ROOT outside, OUT_DIR unset" "$TMP/o820"
PATH="$FS:$PATH" env -u OUT_DIR BENCH_ROOT="$TMP/own-mr" "$HERE/mutate.sh" "$FP" src/A.sol "uint256 x;" "uint256 y;" > "$TMP/o821" 2>&1; check "mutate.sh with BENCH_ROOT outside and OUT_DIR unset: refused" 2 $? "$TMP/o821"
[ ! -e "$TMP/own-mr" ] || { echo "  FAIL  and the copy's root was made"; fails=$((fails + 1)); }
own_clean "mutate.sh, BENCH_ROOT outside, OUT_DIR unset" "$TMP/o821"
# ... allowed: a bench (the marker bench.sh writes into every bench), in it or in a folder below it
BL="$TMP/benchlike"; rm -rf "$BL"; cp -R "$FP" "$BL"; printf 'a bench made by hook-gauntlet scripts/bench.sh\n' > "$BL/.gauntlet-bench"; mkdir -p "$BL/sub"; cp "$FP/foundry.toml" "$BL/sub/"
PATH="$FS:$PATH" env -u OUT_DIR "$HERE/size.sh" "$BL" ToyVault > "$TMP/o822" 2>&1; check "size.sh in a bench (.gauntlet-bench), OUT_DIR unset: allowed" 0 $? "$TMP/o822"
PATH="$FS:$PATH" env -u OUT_DIR "$HERE/size.sh" "$BL/sub" ToyVault > "$TMP/o823" 2>&1; check "size.sh in a folder of a bench (the marker above it): allowed" 0 $? "$TMP/o823"
if [ -f "$BL/.gauntlet/reports/sizes.txt" ] && [ -f "$BL/sub/.gauntlet/reports/sizes.txt" ]; then echo "  ok    and the reports are in the bench"; else
  echo "  FAIL  the reports in the bench: $(find "$BL" -name sizes.txt | tr '\n' ' ')"; fails=$((fails + 1)); fi
rm -rf "$BL"
# ... and the kit's own worked examples (a fresh clone has no foundry-kit/.gauntlet: `scripts/battery.sh foundry-kit`,
# QUICKSTART and CI) - measured on a copy of the kit, so that this checkout's foundry-kit/ is not written
FKC="$TMP/kit-copy"; rm -rf "$FKC"; mkdir -p "$FKC/foundry-kit/v4" "$FKC/other"; cp -R "$HERE" "$FKC/scripts"
for d in foundry-kit foundry-kit/v4 other; do printf '[profile.default]\n' > "$FKC/$d/foundry.toml"; done
PATH="$FS:$PATH" env -u OUT_DIR "$FKC/scripts/size.sh" "$FKC/foundry-kit" ToyVault > "$TMP/o824" 2>&1; check "size.sh on the kit's own foundry-kit/, no .gauntlet/: allowed" 0 $? "$TMP/o824"
PATH="$FS:$PATH" env -u OUT_DIR "$FKC/scripts/size.sh" "$FKC/foundry-kit/v4" ToyVault > "$TMP/o825" 2>&1; check "... and on foundry-kit/v4" 0 $? "$TMP/o825"
PATH="$FS:$PATH" env -u OUT_DIR "$FKC/scripts/size.sh" "$FKC/other" ToyVault > "$TMP/o826" 2>&1; check "... but not on another folder of the kit's checkout" 2 $? "$TMP/o826"
if [ -f "$FKC/foundry-kit/.gauntlet/reports/sizes.txt" ] && [ -f "$FKC/foundry-kit/v4/.gauntlet/reports/sizes.txt" ] && [ ! -e "$FKC/other/.gauntlet" ]; then
  echo "  ok    and the reports are where the kit's .gitignore keeps them out of git"; else
  echo "  FAIL  the kit's own reports: $(cd "$FKC" && find . -path '*/.gauntlet/*' -type f | tr '\n' ' ')"; fails=$((fails + 1)); fi
rm -rf "$FKC"
unset SHIM_SIZES SHIM_TEST
# mutate.sh's baseline build fails; the shim prints a log whose END is warnings. The cause must be on the screen.
FS2="$TMP/fshim2"; mkdir -p "$FS2"
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" build "*) cat "%s"; exit 1 ;;\nesac\necho "Compiler run successful!"; exit 0\n' "$FIX/build-nm-error-then-warnings.txt" > "$FS2/forge"; chmod +x "$FS2/forge"
printf 'contract A { uint256 x; }\n' > "$FP/src/A.sol"
mkdir -p "$FP/.gauntlet"   # the kit's convention installed: mutate.sh's default copy root is <project>/.gauntlet/bench (K26b)
PATH="$FS2:$PATH" LABEL=m17 OUT_DIR="$TMP/mut0" "$HERE/mutate.sh" "$FP" src/A.sol "uint256 x;" "uint256 y;" > "$TMP/o113" 2>&1
check "mutate.sh on a copy that does not build: nothing proven" 2 $? "$TMP/o113"
if grep -q 'first error: Error (6275): Source "../src/InvariantBase.sol" not found' "$TMP/o113"; then
  echo "  ok    and it names the FIRST error, though the log ends in warnings"; else
  echo "  FAIL  mutate.sh did not show the error that stopped the build:"; sed "s/^/        | /" "$TMP/o113" | head -8; fails=$((fails + 1)); fi
# Where the throwaway copy goes. With a BENCH_ROOT (or TMPDIR) that did not exist, `mktemp -d -p` failed, the copy's path
# was EMPTY, and the script ran `cp -a <project>/. /` - "cannot create directory '/./src': Permission denied" for a fresh
# reader, and the project copied into the file system's root for anyone running as root (FR8). A BENCH_ROOT that does not
# exist is created; a place the copy cannot be made is refused in one line, rc 2, naming the variable and the path. The
# shim above fails the baseline build, so "does not compile BEFORE" is the proof the copy was made and used.
PATH="$FS2:$PATH" KEEP=1 BENCH_ROOT="$TMP/mr-new/deep/root" LABEL=m18 OUT_DIR="$TMP/mut0" "$HERE/mutate.sh" "$FP" src/A.sol "uint256 x;" "uint256 y;" > "$TMP/o193" 2>&1
check "mutate.sh with a BENCH_ROOT that does not exist yet: it is created and used" 2 $? "$TMP/o193"
kept193="$(sed -n 's/^copy kept at //p' "$TMP/o193")"
case "$kept193" in "$TMP/mr-new/deep/root/mutate."*) under193=1 ;; *) under193=0 ;; esac
if [ "$under193" -eq 1 ] && [ -f "$kept193/src/A.sol" ] && grep -q "does not compile BEFORE" "$TMP/o193" && ! grep -q "'/\./" "$TMP/o193" && ! grep -q "Permission denied" "$TMP/o193"; then
  echo "  ok    and the copy landed under the created root, not at /"; else
  echo "  FAIL  the copy did not land under the BENCH_ROOT it was given (kept at: ${kept193:-nothing}):"; sed "s/^/        | /" "$TMP/o193" | head -8; fails=$((fails + 1)); fi
[ -n "$kept193" ] && [ "$under193" -eq 1 ] && rm -rf "$kept193"
# no BENCH_ROOT: the copy goes under <project>/.gauntlet/bench (K26: never $HOME or a shared /tmp; TMPDIR is not read), and
# it holds no .gauntlet/ - the reports, the state, and the bench it sits in (`cp -a` of the project would copy it into itself)
mkdir -p "$FP/.gauntlet/reports"; printf 'a report\n' > "$FP/.gauntlet/reports/r.txt"
PATH="$FS2:$PATH" KEEP=1 TMPDIR="$TMP/no-such-tmp" LABEL=m19 OUT_DIR="$TMP/mut0" env -u BENCH_ROOT "$HERE/mutate.sh" "$FP" src/A.sol "uint256 x;" "uint256 y;" > "$TMP/o194" 2>&1
check "mutate.sh with no BENCH_ROOT: the copy is made under <project>/.gauntlet/bench" 2 $? "$TMP/o194"
kept194="$(sed -n 's/^copy kept at //p' "$TMP/o194")"
case "$kept194" in "$FP/.gauntlet/bench/mutate."*) under194=1 ;; *) under194=0 ;; esac
if [ "$under194" -eq 1 ] && [ -f "$kept194/src/A.sol" ] && [ ! -e "$kept194/.gauntlet" ] && grep -q "does not compile BEFORE" "$TMP/o194" && [ ! -e "$TMP/no-such-tmp" ]; then
  echo "  ok    and it landed there, without the project's .gauntlet/ in it, and TMPDIR was not used"; else
  echo "  FAIL  the copy with no BENCH_ROOT (kept at: ${kept194:-nothing}; .gauntlet in it: $([ -e "$kept194/.gauntlet" ] && echo YES || echo no)):"; sed "s/^/        | /" "$TMP/o194" | head -8; fails=$((fails + 1)); fi
[ "$under194" -eq 1 ] && rm -rf "$kept194"
rm -rf "$FP/.gauntlet"
# K26b (V26): no BENCH_ROOT, and the project has no .gauntlet/ (the convention not installed: someone else's tree,
# RETROFIT.md) - refused before anything is written, the log's default directory under .gauntlet/ included
PATH="$FS2:$PATH" LABEL=m19c env -u BENCH_ROOT -u OUT_DIR "$HERE/mutate.sh" "$FP" src/A.sol "uint256 x;" "uint256 y;" > "$TMP/o692" 2>&1
check "mutate.sh with no BENCH_ROOT, in a tree with no .gauntlet/, is refused" 2 $? "$TMP/o692"
if grep -qF 'set BENCH_ROOT=<a directory outside the project>' "$TMP/o692" && ! grep -q "does not compile" "$TMP/o692" && [ ! -e "$FP/.gauntlet" ]; then
  echo "  ok    before building anything, and nothing was written into the tree"; else
  echo "  FAIL  mutate.sh in the owner's tree: .gauntlet $([ -e "$FP/.gauntlet" ] && echo CREATED || echo absent):"; sed "s/^/        | /" "$TMP/o692" | head -8; fails=$((fails + 1)); fi
rm -rf "$FP/.gauntlet"
# ... and a BENCH_ROOT inside the project, anywhere but under a .gauntlet/, is refused before anything is copied into it -
# and the folder the run created for it is removed again (V26: it was left in the project)
PATH="$FS2:$PATH" BENCH_ROOT="$FP/scratch" LABEL=m19b OUT_DIR="$TMP/mut0" "$HERE/mutate.sh" "$FP" src/A.sol "uint256 x;" "uint256 y;" > "$TMP/o639" 2>&1
check "mutate.sh with a BENCH_ROOT inside the project (not under .gauntlet/) is refused" 2 $? "$TMP/o639"
if grep -qF "would be inside $FP, the directory it copies" "$TMP/o639" && ! grep -q "does not compile" "$TMP/o639" && [ ! -e "$FP/scratch" ]; then
  echo "  ok    in one line naming why, before building anything, and the folder it made for the root is gone"; else
  echo "  FAIL  a copy into the project itself was not refused, or its folder was left ($([ -e "$FP/scratch" ] && echo LEFT || echo gone)):"; sed "s/^/        | /" "$TMP/o639" | head -8; fails=$((fails + 1)); fi
mkdir -p "$FP/keep"; printf 'kept\n' > "$FP/keep/K.txt"
PATH="$FS2:$PATH" BENCH_ROOT="$FP/keep/a/b" LABEL=m19d OUT_DIR="$TMP/mut0" "$HERE/mutate.sh" "$FP" src/A.sol "uint256 x;" "uint256 y;" > "$TMP/o693" 2>&1
check "mutate.sh with a deeper BENCH_ROOT inside the project, under a folder that existed" 2 $? "$TMP/o693"
if [ ! -e "$FP/keep/a" ] && [ -f "$FP/keep/K.txt" ]; then echo "  ok    and every folder it made is gone, the one that existed is kept"; else
  echo "  FAIL  after the refusal: keep/a $([ -e "$FP/keep/a" ] && echo LEFT || echo gone), keep/K.txt $([ -f "$FP/keep/K.txt" ] && echo kept || echo GONE)"; fails=$((fails + 1)); fi
rm -rf "$FP/scratch" "$FP/keep"
printf 'not a directory\n' > "$TMP/afile"
PATH="$FS2:$PATH" BENCH_ROOT="$TMP/afile/root" LABEL=m20 OUT_DIR="$TMP/mut0" "$HERE/mutate.sh" "$FP" src/A.sol "uint256 x;" "uint256 y;" > "$TMP/o195" 2>&1
check "mutate.sh with a BENCH_ROOT that cannot be created is refused" 2 $? "$TMP/o195"
if [ "$(grep -cF "mutate: cannot make the throwaway copy under BENCH_ROOT=$TMP/afile/root" "$TMP/o195")" = "1" ] && ! grep -q "^cp: \|resolves to \|does not compile" "$TMP/o195"; then
  echo "  ok    and the refusal is one line naming BENCH_ROOT and its path, before anything is copied"; else
  echo "  FAIL  the refusal for a BENCH_ROOT that cannot be made:"; sed "s/^/        | /" "$TMP/o195" | head -8; fails=$((fails + 1)); fi
# a file that is a RELATIVE link leaving the project: in the copy it points at nothing, and the refusal used to read
# "src/L.sol resolves to , which is OUTSIDE the throwaway copy" - an empty path and the wrong cause (a symlinked lib/?)
mkdir -p "$TMP/relout"; printf 'contract L { uint256 x; }\n' > "$TMP/relout/L.sol"; ln -s ../../relout/L.sol "$FP/src/L.sol"
PATH="$FS2:$PATH" BENCH_ROOT="$TMP/mr-new/deep/root" LABEL=m21 OUT_DIR="$TMP/mut0" "$HERE/mutate.sh" "$FP" src/L.sol "uint256 x;" "uint256 y;" > "$TMP/o196" 2>&1
check "mutate.sh on a relative link whose target is not in the copy: nothing proven" 2 $? "$TMP/o196"
if ! grep -q "resolves to ," "$TMP/o196" && grep -qF "src/L.sol does not resolve inside the throwaway copy" "$TMP/o196" && grep -qF -- "-> ../../relout/L.sol" "$TMP/o196" && ! grep -q "symlinked lib" "$TMP/o196"; then
  echo "  ok    and the refusal names the real cause: a link whose target the copy does not hold"; else
  echo "  FAIL  the refusal for a link that points outside the copy:"; sed "s/^/        | /" "$TMP/o196" | head -8; fails=$((fails + 1)); fi
rm -f "$FP/src/L.sol"
# a copy that fails half-way (an unreadable file) must be refused, not built from what arrived. Root reads anything.
if [ "$(id -u)" != "0" ]; then
  printf 'secret\n' > "$FP/src/Unreadable.txt"; chmod 000 "$FP/src/Unreadable.txt"
  PATH="$FS2:$PATH" BENCH_ROOT="$TMP/mr-new/deep/root" LABEL=m22 OUT_DIR="$TMP/mut0" "$HERE/mutate.sh" "$FP" src/A.sol "uint256 x;" "uint256 y;" > "$TMP/o197" 2>&1
  check "mutate.sh when the copy of the project fails half-way is refused" 2 $? "$TMP/o197"
  if grep -qF "mutate: the copy of $FP into $TMP/mr-new/deep/root/mutate." "$TMP/o197" && ! grep -q "does not compile" "$TMP/o197"; then
    echo "  ok    and it says the copy failed, before building anything"; else
    echo "  FAIL  a failed copy was not refused:"; sed "s/^/        | /" "$TMP/o197" | head -8; fails=$((fails + 1)); fi
  chmod 600 "$FP/src/Unreadable.txt"; rm -f "$FP/src/Unreadable.txt"
fi
if [ -z "$(ls -A "$TMP/mr-new/deep/root" 2> /dev/null)" ]; then echo "  ok    and no copy was left behind under the root"; else
  echo "  FAIL  copies were left under the root: $(ls "$TMP/mr-new/deep/root")"; fails=$((fails + 1)); fi
"$HERE/sim-report.sh" "$FIX/sim-nm-nonnumeric.tsv" > "$TMP/o106" 2>&1; check "sim-report over a ledger with three malformed lines" 0 $? "$TMP/o106"
if grep -Eq '^nm +honest +2 +40\.0 +39\.0 +1\.0 ' "$TMP/o106" && grep -q "3 line(s) ignored (malformed" "$TMP/o106"; then
  echo "  ok    and the malformed lines are counted out loud, not added up as numbers"; else
  echo "  FAIL  sim-report added up a field that is not a number:"; sed "s/^/        | /" "$TMP/o106"; fails=$((fails + 1)); fi
printf 'x\ty\t1\t2\n' > "$TMP/allbad.tsv"; "$HERE/sim-report.sh" "$TMP/allbad.tsv" > "$TMP/o107" 2>&1
check "sim-report over a ledger with no well-formed line measured nothing" 2 $? "$TMP/o107"

# ================================================================= bench.sh refreshes (no forge needed)
echo "== bench.sh (refresh, dependency directories) =="
BP="$TMP/bproj"; mkdir -p "$BP/src" "$BP/fixtures" "$BP/lib/dep" "$BP/v4/src" "$BP/v4/lib/dep2" "$BP/scripts/lib"
printf '[profile.default]\n' > "$BP/foundry.toml"; printf '[profile.default]\n' > "$BP/v4/foundry.toml"
printf 'contract S {}\n' > "$BP/src/S.sol"; printf 'contract V {}\n' > "$BP/v4/src/V.sol"
printf 'contract D {}\n' > "$BP/lib/dep/D.sol"; printf 'contract D2 {}\n' > "$BP/v4/lib/dep2/D2.sol"
printf 'echo parse\n' > "$BP/scripts/lib/parse.sh"; printf '# fixtures\n' > "$BP/fixtures/README.md"
BENCH_ROOT="$TMP/bb2" "$HERE/bench.sh" two "$BP" > "$TMP/o116" 2>&1; check "a bench of a project with a nested foundry project" 0 $? "$TMP/o116"
if [ -L "$TMP/bb2/two/lib" ] && [ -L "$TMP/bb2/two/v4/lib" ] && [ "$(readlink "$TMP/bb2/two/v4/lib")" = "$BP/v4/lib" ] \
  && [ -f "$TMP/bb2/two/scripts/lib/parse.sh" ] && [ ! -L "$TMP/bb2/two/scripts/lib" ]; then
  echo "  ok    lib/ and v4/lib/ are LINKED, and scripts/lib/ (source, not a dependency) is copied"; else
  echo "  FAIL  LINK_LIB: root lib $(readlink "$TMP/bb2/two/lib" 2> /dev/null || echo none), v4/lib $(readlink "$TMP/bb2/two/v4/lib" 2> /dev/null || echo none), scripts/lib/parse.sh $([ -f "$TMP/bb2/two/scripts/lib/parse.sh" ] && echo present || echo MISSING)"; fails=$((fails + 1)); fi
# the v4 README's flow: a bench that keeps what was fetched INTO it. The project has no fixtures/*.hex and no v4/lib of
# its own here, so the bench's are its own; a refresh must keep both, and the bench itself must never be deleted.
rm -rf "$BP/v4/lib"
BENCH_ROOT="$TMP/bb2" BENCH_EXCLUDE="*.hex *.json" "$HERE/bench.sh" keep "$BP" > "$TMP/o117" 2>&1; check "a bench that excludes the fetched fixtures" 0 $? "$TMP/o117"
printf '0x6080\n' > "$TMP/bb2/keep/fixtures/PROBE.hex"; printf '{}\n' > "$TMP/bb2/keep/fixtures/PROBE.json"
mkdir -p "$TMP/bb2/keep/v4/lib/v4-core"; printf 'installed into the bench\n' > "$TMP/bb2/keep/v4/lib/v4-core/INSTALLED"
printf 'contract S { uint256 x; }\n' > "$BP/src/S.sol"
BENCH_ROOT="$TMP/bb2" BENCH_EXCLUDE="*.hex *.json" "$HERE/bench.sh" keep "$BP" > "$TMP/o118" 2>&1; check "the same bench, refreshed" 0 $? "$TMP/o118"
if [ -f "$TMP/bb2/keep/fixtures/PROBE.hex" ] && [ -f "$TMP/bb2/keep/fixtures/PROBE.json" ] && [ -f "$TMP/bb2/keep/v4/lib/v4-core/INSTALLED" ] \
  && grep -q "uint256 x" "$TMP/bb2/keep/src/S.sol"; then
  echo "  ok    the fetched fixtures and the bench's own v4/lib survived the refresh, and the source was refreshed"; else
  echo "  FAIL  the refresh deleted what it was asked to keep: PROBE.hex $([ -f "$TMP/bb2/keep/fixtures/PROBE.hex" ] && echo kept || echo GONE), v4/lib $([ -f "$TMP/bb2/keep/v4/lib/v4-core/INSTALLED" ] && echo kept || echo GONE)"; fails=$((fails + 1)); fi
# ... and a path the PROJECT has that matches the exclude is still withheld: a stale copy of it is removed, by name
printf '0xdead\n' > "$BP/fixtures/Project.hex"; printf '0xdead\n' > "$TMP/bb2/keep/fixtures/Project.hex"
BENCH_ROOT="$TMP/bb2" BENCH_EXCLUDE="*.hex *.json" "$HERE/bench.sh" keep "$BP" > "$TMP/o119" 2>&1; check "a refresh over a stale copy of a withheld file" 0 $? "$TMP/o119"
if [ ! -e "$TMP/bb2/keep/fixtures/Project.hex" ] && [ -f "$TMP/bb2/keep/fixtures/PROBE.hex" ]; then
  echo "  ok    the project's own .hex is withheld (the stale copy is gone), the bench's own PROBE.hex is kept"; else
  echo "  FAIL  withheld and kept are mixed up: Project.hex $([ -e "$TMP/bb2/keep/fixtures/Project.hex" ] && echo PRESENT || echo gone)"; fails=$((fails + 1)); fi
rm -f "$BP/fixtures/Project.hex"
# an exclude that names a DIRECTORY the project also has: the whole directory is withheld, so a file only the bench has
# inside it goes too on the next refresh. That is documented, and it is announced on every run, by name.
BENCH_ROOT="$TMP/bb2" BENCH_EXCLUDE="fixtures" "$HERE/bench.sh" wdir "$BP" > "$TMP/o131" 2>&1; check "a bench that excludes a directory the project has" 0 $? "$TMP/o131"
if grep -Eq '^bench: WARNING .*: fixtures$' "$TMP/o131"; then echo "  ok    and it warns, in one line, naming the directory"; else
  echo "  FAIL  no one-line warning naming the withheld directory:"; grep -i warn "$TMP/o131" | sed "s/^/        | /"; fails=$((fails + 1)); fi
mkdir -p "$TMP/bb2/wdir/fixtures"; printf '0x6080\n' > "$TMP/bb2/wdir/fixtures/BENCHONLY.hex"
BENCH_ROOT="$TMP/bb2" BENCH_EXCLUDE="fixtures" "$HERE/bench.sh" wdir "$BP" > "$TMP/o132" 2>&1; check "the same bench, refreshed" 0 $? "$TMP/o132"
if [ ! -e "$TMP/bb2/wdir/fixtures" ]; then echo "  ok    and the bench-only file inside it went with the directory, as the warning says"; else
  echo "  FAIL  the behaviour the warning describes did not happen (the header is now wrong)"; fails=$((fails + 1)); fi
if grep -q "WARNING" "$TMP/o117"; then echo "  FAIL  an exclude of file patterns only (*.hex *.json) warned about a directory"; fails=$((fails + 1)); else
  echo "  ok    an exclude of file patterns only does not warn"; fi
# BENCH_KEEP: a path the bench keeps across refreshes (the long fuzz's corpus/ and census/). Without it, a refresh with
# `rsync --delete` removes a directory the project does not have; with it, the bench's files survive and the project's
# own files under that path are MERGED in (added, never deleting the bench's).
mkdir -p "$TMP/bb2/two/corpus/invariant" "$TMP/bb2/two/census"
printf 'seq\n' > "$TMP/bb2/two/corpus/invariant/BENCH1.json"; printf 'run\t1\n' > "$TMP/bb2/two/census/earlier.tsv"
BENCH_ROOT="$TMP/bb2" "$HERE/bench.sh" two "$BP" > "$TMP/o150" 2>&1; check "a refresh without BENCH_KEEP" 0 $? "$TMP/o150"
if [ ! -e "$TMP/bb2/two/corpus" ]; then echo "  ok    and without BENCH_KEEP a directory only the bench has is deleted (the default, as documented)"; else
  echo "  FAIL  a bench-only corpus/ survived a refresh without BENCH_KEEP: the header's default is wrong"; fails=$((fails + 1)); fi
mkdir -p "$TMP/bb2/two/corpus/invariant" "$TMP/bb2/two/census" "$BP/corpus/invariant"
printf 'seq\n' > "$TMP/bb2/two/corpus/invariant/BENCH1.json"; printf 'run\t1\n' > "$TMP/bb2/two/census/earlier.tsv"
printf 'seq-from-project\n' > "$BP/corpus/invariant/PROJECT1.json"
BENCH_ROOT="$TMP/bb2" BENCH_KEEP="corpus census" "$HERE/bench.sh" two "$BP" > "$TMP/o151" 2>&1; check "a refresh with BENCH_KEEP=\"corpus census\"" 0 $? "$TMP/o151"
if [ -f "$TMP/bb2/two/corpus/invariant/BENCH1.json" ] && [ -f "$TMP/bb2/two/census/earlier.tsv" ] && [ -f "$TMP/bb2/two/corpus/invariant/PROJECT1.json" ]; then
  echo "  ok    the bench's corpus and census survived, and the project's corpus file was merged in"; else
  echo "  FAIL  BENCH_KEEP: BENCH1 $([ -f "$TMP/bb2/two/corpus/invariant/BENCH1.json" ] && echo kept || echo GONE), census $([ -f "$TMP/bb2/two/census/earlier.tsv" ] && echo kept || echo GONE), PROJECT1 $([ -f "$TMP/bb2/two/corpus/invariant/PROJECT1.json" ] && echo merged || echo MISSING)"; fails=$((fails + 1)); fi
rm -rf "$BP/corpus" "$TMP/bb2/two/corpus" "$TMP/bb2/two/census"

# LINK_FROM: a project with no lib/ of its own (forge-std installed elsewhere). Without LINK_FROM nothing is linked, and
# the script says so in one line; with it, <dir> becomes the bench's lib/.
NL="$TMP/nolibproj"; mkdir -p "$NL/src" "$TMP/fstd/forge-std/src"
printf '[profile.default]\n' > "$NL/foundry.toml"; printf 'contract N {}\n' > "$NL/src/N.sol"; printf '// std\n' > "$TMP/fstd/forge-std/src/Test.sol"
BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nl "$NL" > "$TMP/o152" 2>&1; check "a bench of a project with no lib/, no LINK_FROM" 0 $? "$TMP/o152"
if [ "$(grep -cF 'the project has no lib/: nothing linked; set LINK_FROM=<dir with forge-std>' "$TMP/o152")" = "1" ] && [ ! -e "$TMP/bb3/nl/lib" ]; then
  echo "  ok    and it says, in one line, that nothing was linked and how to link"; else
  echo "  FAIL  no one-line note about the missing lib/ (or a lib/ appeared):"; grep -i lib "$TMP/o152" | sed "s/^/        | /"; fails=$((fails + 1)); fi
LINK_FROM="$TMP/fstd" BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nl "$NL" > "$TMP/o153" 2>&1; check "the same bench with LINK_FROM=<dir with forge-std>" 0 $? "$TMP/o153"
if [ -L "$TMP/bb3/nl/lib" ] && [ "$(readlink "$TMP/bb3/nl/lib")" = "$(cd "$TMP/fstd" && pwd -P)" ] && [ -f "$TMP/bb3/nl/lib/forge-std/src/Test.sol" ] && [ ! -e "$NL/lib" ]; then
  echo "  ok    and <dir> is the bench's lib/ (a link), and the project is untouched"; else
  echo "  FAIL  LINK_FROM: bench lib $(readlink "$TMP/bb3/nl/lib" 2> /dev/null || echo none), project lib $([ -e "$NL/lib" ] && echo CREATED || echo absent)"; fails=$((fails + 1)); fi
LINK_FROM="$TMP/no-such-dir" BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nl2 "$NL" > "$TMP/o154" 2>&1; check "LINK_FROM naming a directory that does not exist is refused" 1 $? "$TMP/o154"
LINK_FROM="$TMP/fstd" BENCH_ROOT="$TMP/bb3" BENCH_EXCLUDE="src" "$HERE/bench.sh" nlbb "$NL" > "$TMP/o155" 2>&1; check "LINK_FROM on a bench that withholds src/" 0 $? "$TMP/o155"
if [ -d "$TMP/bb3/nlbb/lib" ] && [ ! -L "$TMP/bb3/nlbb/lib" ] && [ -f "$TMP/bb3/nlbb/lib/forge-std/src/Test.sol" ] && grep -q "isolation verified" "$TMP/o155"; then
  echo "  ok    and there <dir> is COPIED, not linked (a withholding bench holds no symlink)"; else
  echo "  FAIL  LINK_FROM on a withholding bench: lib $([ -L "$TMP/bb3/nlbb/lib" ] && echo LINK || { [ -d "$TMP/bb3/nlbb/lib" ] && echo dir || echo none; })"; fails=$((fails + 1)); fi
# the same no-lib/ bench refreshed WITHOUT LINK_FROM: its lib/ is the link the earlier LINK_FROM left, and the run must say
# so - not call it "the bench's own"
BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nl "$NL" > "$TMP/o170" 2>&1; check "a refresh without LINK_FROM of a bench an earlier LINK_FROM linked" 0 $? "$TMP/o170"
if grep -qF "bench: lib/ is a link left by an earlier LINK_FROM: $(cd "$TMP/fstd" && pwd -P)" "$TMP/o170" && ! grep -q "the bench's own" "$TMP/o170" && [ -L "$TMP/bb3/nl/lib" ]; then
  echo "  ok    and it says the lib/ is a link left by an earlier LINK_FROM, naming the target (kept)"; else
  echo "  FAIL  the leftover LINK_FROM link is not reported as such:"; grep -i 'lib/' "$TMP/o170" | sed "s/^/        | /"; fails=$((fails + 1)); fi
# no lib/, but foundry.toml already says where the dependencies are: an absolute `libs` entry, or a remapping to an
# absolute path. Then there is nothing to link, and advising LINK_FROM sent a fresh reader looking for a directory it
# did not need (FR7: the toy on forge's defaults, forge-std through an absolute libs, the kit through a remapping).
# (A `../` entry is not "nothing to link": it is followed into the bench - K32, below.)
NR="$TMP/nolib-deps"; mkdir -p "$NR/abslibs/src" "$NR/remap/src" "$NR/uplibs/src" "$NR/multiline/src" "$NR/inside/src"
printf '[profile.default]\nlibs = ["%s"]\n' "$(cd "$TMP/fstd" && pwd -P)" > "$NR/abslibs/foundry.toml"
printf '[profile.default]\nremappings = ["forge-std/=%s/forge-std/src/"]\n' "$(cd "$TMP/fstd" && pwd -P)" > "$NR/remap/foundry.toml"
printf '[profile.default]\nlibs = ["../deps"]\n' > "$NR/uplibs/foundry.toml"
printf '[profile.default]\nremappings = [\n  "a/=src/",\n  "forge-std/=%s/forge-std/src/",\n]\n' "$(cd "$TMP/fstd" && pwd -P)" > "$NR/multiline/foundry.toml"
printf '[profile.default]\nlibs = ["lib"]\nremappings = ["a/=src/"]\n' > "$NR/inside/foundry.toml"
for p in abslibs remap multiline; do
  BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" "nr-$p" "$NR/$p" > "$TMP/o181-$p" 2>&1; check "a bench of a project with no lib/ whose foundry.toml names its dependencies ($p)" 0 $? "$TMP/o181-$p"
  if [ "$(grep -cxF 'bench: no lib/; dependencies come from foundry.toml (libs / remappings): nothing to link' "$TMP/o181-$p")" = "1" ] && ! grep -q "LINK_FROM" "$TMP/o181-$p" && [ ! -e "$TMP/bb3/nr-$p/lib" ]; then
    echo "  ok    and it says the dependencies come from foundry.toml, without advising LINK_FROM"; else
    echo "  FAIL  the no-lib/ note on a project whose foundry.toml names its dependencies ($p):"; grep -i lib "$TMP/o181-$p" | sed "s/^/        | /"; fails=$((fails + 1)); fi
done
BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nr-inside "$NR/inside" > "$TMP/o182" 2>&1; check "a bench of a project with no lib/ whose libs and remappings stay inside it" 0 $? "$TMP/o182"
if grep -qF 'the project has no lib/: nothing linked; set LINK_FROM=<dir with forge-std>' "$TMP/o182" && ! grep -q "dependencies come from foundry.toml" "$TMP/o182"; then
  echo "  ok    and there it still advises LINK_FROM (nothing in foundry.toml reaches outside)"; else
  echo "  FAIL  the no-lib/ note on a project whose foundry.toml stays inside:"; grep -i lib "$TMP/o182" | sed "s/^/        | /"; fails=$((fails + 1)); fi
# ... and remappings.txt, which forge reads as well: a project whose ONLY absolute remapping is there (FR8) got the
# LINK_FROM advice. With CRLF line ends and a context-scoped line too; a relative target that stays inside the project
# still advises LINK_FROM (below), one that leaves it is followed (K32, further below).
mkdir -p "$NR/remaptxt/src" "$NR/remaptxt-inside/src"
printf '[profile.default]\n' > "$NR/remaptxt/foundry.toml"; printf '[profile.default]\n' > "$NR/remaptxt-inside/foundry.toml"
printf 'a/=src/\r\nsrc/:forge-std/=%s/forge-std/src/\r\n' "$(cd "$TMP/fstd" && pwd -P)" > "$NR/remaptxt/remappings.txt"
printf 'a/=src/\nb/=lib/b/\n' > "$NR/remaptxt-inside/remappings.txt"
BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nr-remaptxt "$NR/remaptxt" > "$TMP/o183" 2>&1; check "a bench of a project with no lib/ whose remappings.txt names an absolute target" 0 $? "$TMP/o183"
if [ "$(grep -cxF 'bench: no lib/; dependencies come from remappings.txt (an absolute remapping): nothing to link' "$TMP/o183")" = "1" ] && ! grep -q "LINK_FROM" "$TMP/o183" && [ ! -e "$TMP/bb3/nr-remaptxt/lib" ]; then
  echo "  ok    and it says the dependencies come from remappings.txt, without advising LINK_FROM"; else
  echo "  FAIL  the no-lib/ note on a project whose remappings.txt names its dependencies:"; grep -i lib "$TMP/o183" | sed "s/^/        | /"; fails=$((fails + 1)); fi
BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nr-remaptxt-inside "$NR/remaptxt-inside" > "$TMP/o184" 2>&1; check "a bench of a project with no lib/ whose remappings.txt stays relative, inside it" 0 $? "$TMP/o184"
if grep -qF 'the project has no lib/: nothing linked; set LINK_FROM=<dir with forge-std>' "$TMP/o184" && ! grep -q "nothing to link" "$TMP/o184"; then
  echo "  ok    and there it still advises LINK_FROM (no absolute target in remappings.txt, none that leaves the project)"; else
  echo "  FAIL  the no-lib/ note on a project whose remappings.txt is relative:"; grep -i lib "$TMP/o184" | sed "s/^/        | /"; fails=$((fails + 1)); fi
# K32 (FR16): a project that reaches OUT of itself by a relative path - the kit vendored BESIDE it, `../lib/hook-gauntlet/...`
# in remappings.txt and allow_paths, `libs = []` (QUICKSTART 7b) - got a bench whose `../lib` resolved to nothing, and the
# advice to set LINK_FROM, which fills the bench's OWN lib/, not ../lib: a fresh reader linked it by hand. Now the bench
# holds the project at <bench>/<its folder>, what `../` reaches is linked beside it (copied, in a bench that withholds) so
# the remapping resolves there, a sibling it does not reach is not copied, and the last line is the project's place.
FR="$TMP/fr16like"; mkdir -p "$FR/lib/hook-gauntlet/foundry-kit/src" "$FR/proj/src" "$FR/proj/.gauntlet" "$FR/walk-logs"
printf 'contract K {}\n' > "$FR/lib/hook-gauntlet/foundry-kit/src/K.sol"; printf 'a log\n' > "$FR/walk-logs/w.log"
printf '[profile.default]\n# ...the kit is beside, not inside\nsrc = "src" # the ... sources; see ../notes\nlibs = []\nallow_paths = ["../lib/hook-gauntlet/foundry-kit"]\n' > "$FR/proj/foundry.toml"
printf 'gauntlet-kit/=../lib/hook-gauntlet/foundry-kit/src/\nself/=../proj/src/\n' > "$FR/proj/remappings.txt"
printf 'contract P {}\n' > "$FR/proj/src/P.sol"
FRR="$(cd "$FR" && pwd -P)"; FRB="$FRR/proj/.gauntlet/bench/r01"
(cd "$TMP" && env -u BENCH_ROOT "$HERE/bench.sh" r01 "$FR/proj") > "$TMP/o740" 2>&1
check "a bench of a project whose remappings reach ../lib (the kit beside it, FR16's layout)" 0 $? "$TMP/o740"
w="$(tail -1 "$TMP/o740")"
if [ "$w" = "$FRB/proj" ] && [ -f "$w/src/P.sol" ] && (cd "$w" && [ -f ../lib/hook-gauntlet/foundry-kit/src/K.sol ] && [ -f ../proj/src/P.sol ]) \
  && [ -L "$FRB/lib" ] && [ -f "$FRB/.gauntlet-bench" ] && [ ! -e "$FRB/walk-logs" ] && [ ! -e "$FRB/proj/.gauntlet" ] \
  && ! grep -q LINK_FROM "$TMP/o740" && grep -qxF "bench: ../lib -> $FRR/lib: linked at $FRB/lib" "$TMP/o740"; then
  echo "  ok    the project is at <bench>/proj, ../lib resolves there (a link, named), no sibling copied, no LINK_FROM advice"; else
  echo "  FAIL  the bench of a project that reaches ../lib (last line '$w'):"; sed "s/^/        | /" "$TMP/o740"; fails=$((fails + 1)); fi
printf 'contract P { uint256 x; }\n' > "$FR/proj/src/P.sol"
(cd "$TMP" && env -u BENCH_ROOT "$HERE/bench.sh" r01 "$FR/proj") > "$TMP/o741" 2>&1; check "the same bench, refreshed" 0 $? "$TMP/o741"
if [ "$(tail -1 "$TMP/o741")" = "$FRB/proj" ] && grep -q 'uint256 x' "$FRB/proj/src/P.sol" && (cd "$FRB/proj" && [ -f ../lib/hook-gauntlet/foundry-kit/src/K.sol ]) \
  && [ -f "$FRR/lib/hook-gauntlet/foundry-kit/src/K.sol" ]; then
  echo "  ok    and the refresh keeps ../lib resolving, with the source refreshed and the kit beside the project untouched"; else
  echo "  FAIL  the refresh:"; sed "s/^/        | /" "$TMP/o741"; fails=$((fails + 1)); fi
BENCH_ROOT="$TMP/frout" BENCH_EXCLUDE="src" "$HERE/bench.sh" bb "$FR/proj" > "$TMP/o742" 2>&1; check "the same project, a bench that withholds src/" 0 $? "$TMP/o742"
w="$(tail -1 "$TMP/o742")"
if [ "$w" = "$(cd "$TMP" && pwd -P)/frout/bb/proj" ] && [ ! -e "$w/src" ] && [ -d "$TMP/frout/bb/lib" ] && [ ! -L "$TMP/frout/bb/lib" ] \
  && (cd "$w" && [ -f ../lib/hook-gauntlet/foundry-kit/src/K.sol ]) && [ -z "$(find "$TMP/frout/bb" -type l)" ] && grep -q 'isolation verified' "$TMP/o742" \
  && grep -qF "bench: ../lib -> $FRR/lib: copied at " "$TMP/o742"; then
  echo "  ok    and there ../lib is COPIED (no symlink), the project's src/ withheld, the isolation verified"; else
  echo "  FAIL  the withholding bench of a project that reaches ../lib:"; sed "s/^/        | /" "$TMP/o742"; fails=$((fails + 1)); fi
# `libs = ["../deps"]` likewise (it used to be "nothing to link", and the bench's ../deps resolved to nothing)
mkdir -p "$NR/deps/forge-std/src"; printf '// std\n' > "$NR/deps/forge-std/src/Test.sol"
BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nr-uplibs "$NR/uplibs" > "$TMP/o743" 2>&1; check "a bench of a project with no lib/ and libs = [\"../deps\"]" 0 $? "$TMP/o743"
w="$(tail -1 "$TMP/o743")"
if (cd "$w" 2> /dev/null && [ -f ../deps/forge-std/src/Test.sol ]) && ! grep -q LINK_FROM "$TMP/o743" && grep -qF 'bench: ../deps -> ' "$TMP/o743"; then
  echo "  ok    and ../deps resolves in the bench, without advising LINK_FROM"; else
  echo "  FAIL  libs = [\"../deps\"]:"; sed "s/^/        | /" "$TMP/o743"; fails=$((fails + 1)); fi
# a target that does not exist is named, and LINK_FROM (which would not help) is not advised; one that HOLDS the project
# (`../`) is refused - it cannot be linked beside the project without being the project
mkdir -p "$NR/upmissing/src" "$NR/upall/src"; printf '[profile.default]\n' > "$NR/upmissing/foundry.toml"; printf '[profile.default]\n' > "$NR/upall/foundry.toml"
printf 'b/=../nowhere/b/\n' > "$NR/upmissing/remappings.txt"; printf 'all/=../\n' > "$NR/upall/remappings.txt"
BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nr-upmissing "$NR/upmissing" > "$TMP/o744" 2>&1; check "a bench of a project whose remapping reaches a ../ that does not exist" 0 $? "$TMP/o744"
if grep -qE '^bench: \.\./nowhere -> .*: does not exist - nothing linked for it' "$TMP/o744" && ! grep -q LINK_FROM "$TMP/o744"; then
  echo "  ok    and it names the missing target, without advising LINK_FROM"; else
  echo "  FAIL  the missing ../ target:"; sed "s/^/        | /" "$TMP/o744"; fails=$((fails + 1)); fi
BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nr-upall "$NR/upall" > "$TMP/o745" 2>&1; check "a bench of a project whose remapping reaches the directory that holds it (../) is refused" 1 $? "$TMP/o745"
if grep -q 'holds the project' "$TMP/o745" && [ ! -e "$TMP/bb3/nr-upall" ]; then echo "  ok    saying why, and no bench was made"; else
  echo "  FAIL  the ../ that holds the project:"; sed "s/^/        | /" "$TMP/o745"; fails=$((fails + 1)); fi
rm -rf "$FR" "$TMP/frout"
# K32b (V32): the isolation is over the WHOLE bench, not the project's copy in it. A bench of the same name made in an
# earlier layout - the project at <bench>/ before its remappings reached ../, at <bench>/<folder> after - kept the old
# copy of src/ at <bench>/src, `../src` from where the script says to work, and said "isolation verified". Now a refresh
# removes what an earlier layout left at the bench's root, the check scans the whole bench, a `../` target that is a link
# into the project is refused, and a copied `../` target is said to come WHOLE.
LY="$TMP/layout"; mkdir -p "$LY/lib/kit/src" "$LY/lib/other-private" "$LY/proj/src" "$LY/proj/.gauntlet"
printf 'contract K {}\n' > "$LY/lib/kit/src/K.sol"; printf 'notes\n' > "$LY/lib/other-private/NOTES.txt"
printf 'contract SECRET_SOURCE {}\n' > "$LY/proj/src/S.sol"; printf '[profile.default]\nsrc = "src"\n' > "$LY/proj/foundry.toml"
LYR="$(cd "$LY" && pwd -P)"; LYB="$(cd "$TMP" && pwd -P)/lyout/ly"
BENCH_ROOT="$TMP/lyout" "$HERE/bench.sh" ly "$LY/proj" > "$TMP/o955" 2>&1; check "a bench of a project that does not reach ../ (its copy at <bench>/)" 0 $? "$TMP/o955"
printf 'kit/=../lib/kit/src/\n' > "$LY/proj/remappings.txt"
BENCH_ROOT="$TMP/lyout" BENCH_EXCLUDE="src" "$HERE/bench.sh" ly "$LY/proj" > "$TMP/o956" 2>&1
check "the same bench name, withholding src/, after the project came to reach ../lib (its copy now at <bench>/proj)" 0 $? "$TMP/o956"
if [ "$(tail -1 "$TMP/o956")" = "$LYB/proj" ] && [ -z "$(grep -rl SECRET_SOURCE "$LYB" 2> /dev/null)" ] && [ ! -e "$LYB/src" ] \
  && [ "$(ls -A "$LYB" | sort | tr '\n' ' ')" = ".gauntlet-bench lib proj " ] && grep -q 'isolation verified' "$TMP/o956" \
  && grep -qE "^bench: removed from the bench's root, left by an earlier layout:.* src( |$)" "$TMP/o956"; then
  echo "  ok    and the old copy at <bench>/ (src/ with it: ../src from the place to work) is removed, and said"; else
  echo "  FAIL  the bench after a change of layout ($(ls -A "$LYB" | tr '\n' ' '); source in it: $(grep -rl SECRET_SOURCE "$LYB" 2> /dev/null | tr '\n' ' ')):"
  sed "s/^/        | /" "$TMP/o956"; fails=$((fails + 1)); fi
if grep -qxF "bench: WARNING - ../lib is copied WHOLE into a bench that withholds: everything in $LYR/lib, not only what the project names in it: kit other-private" "$TMP/o956"; then
  echo "  ok    and the copied ../lib is said to come whole, naming what it brings"; else
  echo "  FAIL  no line names what the copied ../lib brings:"; grep -E '\.\./lib' "$TMP/o956" | sed "s/^/        | /"; fails=$((fails + 1)); fi
# ... and back: a white-box refresh at <bench>/proj (src/ copied there), then the project no longer reaches ../ (the kit
# moved inside it) and the bench withholds src/ again: the copy at <bench>/proj, src/ in it, must not survive as "the bench's own"
BENCH_ROOT="$TMP/lyout" "$HERE/bench.sh" ly "$LY/proj" > "$TMP/o957" 2>&1; check "the same bench, white-box, at <bench>/proj" 0 $? "$TMP/o957"
rm -f "$LY/proj/remappings.txt"
BENCH_ROOT="$TMP/lyout" BENCH_EXCLUDE="src" "$HERE/bench.sh" ly "$LY/proj" > "$TMP/o958" 2>&1
check "the same bench name, withholding src/, after the project stopped reaching ../ (its copy back at <bench>/)" 0 $? "$TMP/o958"
if [ "$(tail -1 "$TMP/o958")" = "$LYB" ] && [ -z "$(grep -rl SECRET_SOURCE "$LYB" 2> /dev/null)" ] && [ ! -e "$LYB/proj" ] && [ ! -e "$LYB/lib" ] \
  && grep -q 'isolation verified' "$TMP/o958"; then
  echo "  ok    and the copy the earlier layout left at <bench>/proj, and the ../lib beside it, are removed"; else
  echo "  FAIL  the bench after the layout changed back ($(ls -A "$LYB" | tr '\n' ' '); source in it: $(grep -rl SECRET_SOURCE "$LYB" 2> /dev/null | tr '\n' ' ')):"
  sed "s/^/        | /" "$TMP/o958"; fails=$((fails + 1)); fi
# the check scans the whole bench: a withheld path the removal could not take (a directory it may not write) is outside
# the project's copy, and the bench is refused - never "isolation verified". Root may write anything: not run as root.
if [ "$(id -u)" != "0" ]; then
  BENCH_ROOT="$TMP/lyout" "$HERE/bench.sh" lz "$LY/proj" > "$TMP/o959" 2>&1; check "a white-box bench at <bench>/ (src/ copied)" 0 $? "$TMP/o959"
  chmod 555 "$TMP/lyout/lz/src"; printf 'kit/=../lib/kit/src/\n' > "$LY/proj/remappings.txt"
  BENCH_ROOT="$TMP/lyout" BENCH_EXCLUDE="src" "$HERE/bench.sh" lz "$LY/proj" > "$TMP/o960" 2>&1
  check "the same bench, withholding src/, at <bench>/proj, with the old <bench>/src not removable: refused" 1 $? "$TMP/o960"
  if grep -qF "bench: EXCLUDED path 'src' is present in the bench, outside the project's copy" "$TMP/o960" && grep -q 'NOT isolated' "$TMP/o960" \
    && ! grep -q 'isolation verified' "$TMP/o960"; then
    echo "  ok    naming the path outside the project's copy, and never saying isolation verified"; else
    echo "  FAIL  a withheld path outside the project's copy:"; sed "s/^/        | /" "$TMP/o960"; fails=$((fails + 1)); fi
  chmod 755 "$TMP/lyout/lz/src"
fi
# a `../` target that is a LINK into the project: it would be the project, source and all - refused before anything is written
printf 'kit/=../lib/kit/src/\n' > "$LY/proj/remappings.txt"; ln -s "$LY/proj" "$LY/projlink"; printf 'x/=../projlink/test/\n' >> "$LY/proj/remappings.txt"
BENCH_ROOT="$TMP/lyout" BENCH_EXCLUDE="src" "$HERE/bench.sh" lk "$LY/proj" > "$TMP/o961" 2>&1; check "a ../ target that is a link to the project itself is refused" 1 $? "$TMP/o961"
if grep -qF "bench: ../projlink -> $LYR/projlink resolves into the project ($LYR/proj)" "$TMP/o961" && [ ! -e "$TMP/lyout/lk" ]; then
  echo "  ok    saying where it leads, and no bench was made"; else
  echo "  FAIL  the ../ link into the project:"; sed "s/^/        | /" "$TMP/o961"; ls -A "$TMP/lyout/lk" 2> /dev/null | sed "s/^/        | ls: /"; fails=$((fails + 1)); fi
rm -rf "$LY" "$TMP/lyout"

# the marker: every bench this script makes holds .gauntlet-bench, a refresh keeps it, and a directory that exists
# WITHOUT it is refused - rc 1, one line, nothing touched (a reused name once let a refresh with --delete wipe a working copy)
if [ -f "$TMP/bb3/nl/.gauntlet-bench" ] && [ -f "$TMP/bb2/two/.gauntlet-bench" ] && [ -f "$TMP/bb3/nlbb/.gauntlet-bench" ]; then
  echo "  ok    every bench made above holds the .gauntlet-bench marker, after its refreshes too"; else
  echo "  FAIL  a bench has no .gauntlet-bench marker: nl $([ -f "$TMP/bb3/nl/.gauntlet-bench" ] && echo yes || echo NO), two $([ -f "$TMP/bb2/two/.gauntlet-bench" ] && echo yes || echo NO), nlbb $([ -f "$TMP/bb3/nlbb/.gauntlet-bench" ] && echo yes || echo NO)"; fails=$((fails + 1)); fi
if [ -e "$NL/.gauntlet-bench" ]; then echo "  FAIL  the marker was written into the PROJECT"; fails=$((fails + 1)); else echo "  ok    and the project holds no marker"; fi
mkdir -p "$TMP/bb4/wc/src"; printf 'work in progress\n' > "$TMP/bb4/wc/NOTES.txt"; printf 'contract W {}\n' > "$TMP/bb4/wc/src/W.sol"
BENCH_ROOT="$TMP/bb4" "$HERE/bench.sh" wc "$NL" > "$TMP/o168" 2>&1; check "a directory that exists without the marker is refused" 1 $? "$TMP/o168"
if [ "$(wc -l < "$TMP/o168" | tr -d ' ')" = "1" ] && grep -q 'gauntlet-bench' "$TMP/o168" && [ -f "$TMP/bb4/wc/NOTES.txt" ] && [ -f "$TMP/bb4/wc/src/W.sol" ] \
  && [ ! -e "$TMP/bb4/wc/.gauntlet-bench" ] && [ ! -e "$TMP/bb4/wc/src/N.sol" ]; then
  echo "  ok    in one line naming the marker, and the directory is untouched (its files kept, nothing copied, no marker written)"; else
  echo "  FAIL  the refusal is not one line, or the directory was touched:"; sed "s/^/        | /" "$TMP/o168"; ls -A "$TMP/bb4/wc" | sed "s/^/        | ls: /"; fails=$((fails + 1)); fi
BENCH_ROOT="$TMP/bb4" "$HERE/bench.sh" fresh "$NL" > "$TMP/o169" 2>&1; check "a bench under a name that did not exist" 0 $? "$TMP/o169"
if [ -f "$TMP/bb4/fresh/.gauntlet-bench" ] && [ -f "$TMP/bb4/fresh/src/N.sol" ]; then echo "  ok    and it holds the marker"; else
  echo "  FAIL  a new bench has no marker"; fails=$((fails + 1)); fi
# the default root (K26): <project>/.gauntlet/bench - inside the project, in the one directory no copy enters (`.gauntlet`
# is left out of every bench), never $HOME. Two benches and a refresh: neither holds the other, nor the project's state
DP="$TMP/defproj"; mkdir -p "$DP/src" "$DP/v4/src" "$DP/.gauntlet/reports" "$TMP/fakehome"
printf '[profile.default]\n' > "$DP/foundry.toml"; printf 'contract S {}\n' > "$DP/src/S.sol"; printf 'contract V {}\n' > "$DP/v4/src/V.sol"
printf '# STATE\n' > "$DP/.gauntlet/STATE.md"; printf 'a report\n' > "$DP/.gauntlet/reports/r.txt"
DPR="$(cd "$DP" && pwd -P)"
(cd "$TMP" && env -u BENCH_ROOT HOME="$TMP/fakehome" "$HERE/bench.sh" d1 "$DP") > "$TMP/o660" 2>&1; check "a bench with BENCH_ROOT unset" 0 $? "$TMP/o660"
(cd "$TMP" && env -u BENCH_ROOT HOME="$TMP/fakehome" "$HERE/bench.sh" d2 "$DP") > "$TMP/o661" 2>&1; check "a second one beside it" 0 $? "$TMP/o661"
(cd "$TMP" && env -u BENCH_ROOT HOME="$TMP/fakehome" "$HERE/bench.sh" d1 "$DP") > "$TMP/o662" 2>&1; check "the first one, refreshed" 0 $? "$TMP/o662"
if [ "$(tail -1 "$TMP/o660")" = "$DPR/.gauntlet/bench/d1" ] && [ -f "$DP/.gauntlet/bench/d1/.gauntlet-bench" ] && [ -f "$DP/.gauntlet/bench/d1/src/S.sol" ] \
  && [ ! -e "$DP/.gauntlet/bench/d1/.gauntlet" ] && [ ! -e "$DP/.gauntlet/bench/d2/.gauntlet" ] && [ ! -e "$TMP/fakehome/.gauntlet" ] \
  && [ -f "$DP/.gauntlet/STATE.md" ] && [ -f "$DP/.gauntlet/reports/r.txt" ]; then
  echo "  ok    it is <project>/.gauntlet/bench/<name>, nothing of .gauntlet/ is in either bench, the state is kept, HOME untouched"; else
  echo "  FAIL  the default bench: path '$(tail -1 "$TMP/o660")', .gauntlet in d1 $([ -e "$DP/.gauntlet/bench/d1/.gauntlet" ] && echo YES || echo no), under HOME $([ -e "$TMP/fakehome/.gauntlet" ] && echo YES || echo no)"; fails=$((fails + 1)); fi
# a root under a NESTED .gauntlet (fuzz-long benches a module's parent into the module's own .gauntlet/bench) is allowed;
# the project's .gauntlet ITSELF as a bench, or a root anywhere else inside the project, is not
BENCH_ROOT="$DP/v4/.gauntlet/bench" "$HERE/bench.sh" n1 "$DP" > "$TMP/o663" 2>&1; check "a bench under the module's own .gauntlet/ (a nested one)" 0 $? "$TMP/o663"
if [ -f "$DP/v4/.gauntlet/bench/n1/v4/src/V.sol" ] && [ ! -e "$DP/v4/.gauntlet/bench/n1/v4/.gauntlet" ] && [ ! -e "$DP/v4/.gauntlet/bench/n1/.gauntlet" ]; then
  echo "  ok    and it holds the module, not the .gauntlet it lives in"; else echo "  FAIL  the nested bench holds a .gauntlet, or not the module"; fails=$((fails + 1)); fi
BENCH_ROOT="$DP" "$HERE/bench.sh" .gauntlet "$DP" > "$TMP/o664" 2>&1; check "the project's .gauntlet/ itself as a bench is refused" 1 $? "$TMP/o664"
if [ -f "$DP/.gauntlet/STATE.md" ] && [ ! -e "$DP/.gauntlet/.gauntlet-bench" ] && grep -q "overlap" "$TMP/o664"; then
  echo "  ok    as an overlap, and the state is untouched"; else echo "  FAIL  .gauntlet/ was made a bench, or the refusal is not the overlap:"; sed "s/^/        | /" "$TMP/o664"; fails=$((fails + 1)); fi
# K26b (V26): the default root only where the kit's convention is installed. A tree with no .gauntlet/ - an existing
# hook, someone else's working tree (doctrine/RETROFIT.md: a bench of your own, never their working tree) - is refused
# before anything is written, and asked for a BENCH_ROOT outside it
OT="$TMP/ownertree"; mkdir -p "$OT/src"; printf '[profile.default]\n' > "$OT/foundry.toml"; printf 'contract O {}\n' > "$OT/src/O.sol"
(cd "$TMP" && env -u BENCH_ROOT HOME="$TMP/fakehome" "$HERE/bench.sh" r1 "$OT") > "$TMP/o684" 2>&1
check "a bench with BENCH_ROOT unset, in a tree with no .gauntlet/ (the convention not installed), is refused" 1 $? "$TMP/o684"
if grep -qF 'set BENCH_ROOT=<a directory outside the project>' "$TMP/o684" && grep -q 'RETROFIT' "$TMP/o684" && [ ! -e "$OT/.gauntlet" ] && [ ! -e "$TMP/fakehome/.gauntlet" ]; then
  echo "  ok    and it says why (RETROFIT) and what to set, and nothing was written into the tree or HOME"; else
  echo "  FAIL  the owner's tree: .gauntlet $([ -e "$OT/.gauntlet" ] && echo CREATED || echo absent):"; sed "s/^/        | /" "$TMP/o684"; fails=$((fails + 1)); fi
BENCH_ROOT="$TMP/otb" "$HERE/bench.sh" r1 "$OT" > "$TMP/o685" 2>&1; check "the same tree with BENCH_ROOT outside it" 0 $? "$TMP/o685"
if [ -f "$TMP/otb/r1/src/O.sol" ] && [ ! -e "$OT/.gauntlet" ]; then echo "  ok    and the tree is untouched"; else
  echo "  FAIL  the bench outside the owner's tree: $(tail -1 "$TMP/o685"), .gauntlet in the tree $([ -e "$OT/.gauntlet" ] && echo CREATED || echo absent)"; fails=$((fails + 1)); fi
# a bench that withholds the SOURCE is refused anywhere inside the project, .gauntlet/ included: from
# <project>/.gauntlet/bench/<name>, ../../.. is the project (V26: "isolation verified", and ../../../src listed the source)
(cd "$TMP" && env -u BENCH_ROOT BENCH_EXCLUDE="src script" "$HERE/bench.sh" bb "$DP") > "$TMP/o686" 2>&1
check "a source-free bench (BENCH_EXCLUDE=\"src script\") with BENCH_ROOT unset is refused" 1 $? "$TMP/o686"
if grep -q 'withholds the source' "$TMP/o686" && grep -qF 'set BENCH_ROOT=<a directory outside the project>' "$TMP/o686" && ! grep -q 'isolation verified' "$TMP/o686" \
  && [ ! -e "$DP/.gauntlet/bench/bb" ]; then
  echo "  ok    with the reason and the fix, and no bench was made"; else
  echo "  FAIL  the source-free bench inside the project:"; sed "s/^/        | /" "$TMP/o686"; fails=$((fails + 1)); fi
BENCH_ROOT="$DP/.gauntlet/bench" BENCH_EXCLUDE="v4/src" "$HERE/bench.sh" bb2 "$DP" > "$TMP/o687" 2>&1
check "a source-free bench (v4/src) with BENCH_ROOT under the project's .gauntlet/ is refused" 1 $? "$TMP/o687"
[ ! -e "$DP/.gauntlet/bench/bb2" ] || { echo "  FAIL  and a bench was made"; fails=$((fails + 1)); }
BENCH_ROOT="$DP/.gauntlet/bench" BENCH_EXCLUDE="*.hex" "$HERE/bench.sh" hx "$DP" > "$TMP/o688" 2>&1
check "a bench that withholds fetched fixtures only (*.hex) may still live under .gauntlet/" 0 $? "$TMP/o688"
BENCH_ROOT="$TMP/bbout" BENCH_EXCLUDE="src script" "$HERE/bench.sh" bb "$DP" > "$TMP/o689" 2>&1
check "the source-free bench with BENCH_ROOT outside the project" 0 $? "$TMP/o689"
if grep -q 'isolation verified' "$TMP/o689" && [ -f "$TMP/bbout/bb/.gauntlet-bench" ] && ! grep -qF "$DPR" "$TMP/bbout/bb/.gauntlet-bench" \
  && ! grep -qF "$DP" "$TMP/bbout/bb/.gauntlet-bench" && grep -q 'cksum [0-9]' "$TMP/bbout/bb/.gauntlet-bench"; then
  echo "  ok    and its .gauntlet-bench marker names the project by a hash, not by its path"; else
  echo "  FAIL  the source-free bench's marker: $(cat "$TMP/bbout/bb/.gauntlet-bench" 2> /dev/null)"; fails=$((fails + 1)); fi
printf 'a bench made by hook-gauntlet scripts/bench.sh (name bb, from %s). A refresh deletes what the project does not have.\n' "$DPR" > "$TMP/bbout/bb/.gauntlet-bench"
BENCH_ROOT="$TMP/bbout" BENCH_EXCLUDE="src script" "$HERE/bench.sh" bb "$DP" > "$TMP/o690" 2>&1
check "the same bench refreshed over a marker an earlier version wrote with the path" 0 $? "$TMP/o690"
if ! grep -qF "$DPR" "$TMP/bbout/bb/.gauntlet-bench" && grep -q 'cksum [0-9]' "$TMP/bbout/bb/.gauntlet-bench"; then
  echo "  ok    and the refresh rewrote the marker without the path"; else
  echo "  FAIL  the old marker with the path survived the refresh: $(cat "$TMP/bbout/bb/.gauntlet-bench")"; fails=$((fails + 1)); fi
# fuzz-long.sh's default bench likewise (no forge is reached: the refusal comes first)
(cd "$TMP" && env -u BENCH_ROOT -u OUT_DIR HOME="$TMP/fakehome" "$HERE/fuzz-long.sh" "$OT") > "$TMP/o691" 2>&1
check "fuzz-long.sh with BENCH_ROOT unset, in a tree with no .gauntlet/, is refused" 2 $? "$TMP/o691"
if grep -qF 'set BENCH_ROOT=<a directory outside the project>' "$TMP/o691" && grep -q 'NOTHING PROVEN' "$TMP/o691" && [ ! -e "$OT/.gauntlet" ]; then
  echo "  ok    and nothing was written into the tree (the log's default directory included)"; else
  echo "  FAIL  fuzz-long.sh in the owner's tree: .gauntlet $([ -e "$OT/.gauntlet" ] && echo CREATED || echo absent):"; sed "s/^/        | /" "$TMP/o691" | head -6; fails=$((fails + 1)); fi
# K32c (V32b): ESTIMATE_ONLY makes no bench - its refusal there does not say one would be made (the campaign it prices would)
(cd "$TMP" && env -u BENCH_ROOT -u OUT_DIR HOME="$TMP/fakehome" ESTIMATE_ONLY=1 "$HERE/fuzz-long.sh" "$OT") > "$TMP/o969" 2>&1
check "fuzz-long.sh ESTIMATE_ONLY=1 with BENCH_ROOT unset, in a tree with no .gauntlet/, is refused" 2 $? "$TMP/o969"
if grep -qF 'fuzz-long: ESTIMATE_ONLY makes no bench and writes nothing' "$TMP/o969" && ! grep -q 'would be made' "$TMP/o969" \
  && grep -qF 'set BENCH_ROOT=<a directory outside the project>' "$TMP/o969" && [ ! -e "$OT/.gauntlet" ]; then
  echo "  ok    and the refusal is the campaign's, not a bench this run would make; nothing written"; else
  echo "  FAIL  ESTIMATE_ONLY's refusal in the owner's tree:"; sed "s/^/        | /" "$TMP/o969" | head -6; fails=$((fails + 1)); fi
rm -rf "$DP" "$TMP/fakehome" "$OT" "$TMP/otb" "$TMP/bbout"

# ================================================================= round.sh (the ROUND line, written and read back; no forge needed)
echo "== round.sh =="
RL="$TMP/round-LOG.md"; printf '# LOG\n\n## 2026-03-13 - r05 closed\n' > "$RL"
# rround [--field value]... [-- extra...]: round.sh on $RL with one good round's arguments, some of them overridden
rround() {
  local -a a=(--id r05 --phase 4 --type regression --model "vendor-a/large (1M)" --bench benches/hg-a05 --dates 2026-03-09..2026-03-12
    --high 0 --medium 1 --low 4 --info 7 --reasoned 0 --gate pass --tokens 230k --minutes 95 --files-read 41 --tests-written 6
    --report reports/r05.md --conf 0.7)
  local i
  while [ $# -ge 2 ] && [ "$1" != "--" ]; do
    for i in "${!a[@]}"; do if [ "${a[$i]}" = "$1" ]; then a[i+1]="$2"; fi; done
    shift 2
  done
  [ "${1:-}" = "--" ] && shift
  "$HERE/round.sh" "$RL" "${a[@]}" "$@"
}
want_line='ROUND r05 | phase 4 | regression | vendor-a/large (1M) | bench benches/hg-a05 | 2026-03-09..2026-03-12 | 0H 1M 4L 7I reasoned 0 | gate pass | 230k tokens, 95 min, 41 files read, 6 tests written | reports/r05.md | conf 0.7'
want_json='{"id":"r05","phase":4,"type":"regression","model":"vendor-a/large (1M)","bench":"benches/hg-a05","dates":{"start":"2026-03-09","end":"2026-03-12"},"findings":{"high":0,"medium":1,"low":4,"info":7,"reasoned_high_medium":0},"gate":"pass","cost":{"tokens":230000,"minutes":95,"files_read":41,"tests_written":6},"report":"reports/r05.md","raw_confidence":0.7}'
rround > "$TMP/o140" 2>&1; check "round.sh: a well-formed round is appended (the control)" 0 $? "$TMP/o140"
if [ "$(grep -c '^ROUND ' "$RL")" = "1" ] && [ "$(grep '^ROUND ' "$RL")" = "$want_line" ]; then echo "  ok    and LOG.md holds exactly that line"; else
  echo "  FAIL  the ROUND line in LOG.md is not the one asked for: $(grep '^ROUND ' "$RL")"; fails=$((fails + 1)); fi
"$HERE/round.sh" --json "$RL" > "$TMP/o141" 2>&1; check "round.sh --json reads it back" 0 $? "$TMP/o141"
if [ "$(cat "$TMP/o141")" = "$want_json" ]; then echo "  ok    and every field read back equals the argument it was written from"; else
  echo "  FAIL  the round trip changed a field:"; sed "s/^/        | /" "$TMP/o141"; fails=$((fails + 1)); fi
rl_hash="$(hash_of "$RL")"; rn=150
# refused <label> <the words the refusal must say> <override...>: exit 2, THAT refusal (not some other one: each case
# gets a fresh id, or every case would be refused as a duplicate of r05 and prove nothing about its own guard - a
# sabotage run of each guard found exactly that), and LOG.md byte for byte as it was
refused() {
  local label="$1" says="$2"; shift 2; rn=$((rn + 1))
  rround --id "x$rn" "$@" > "$TMP/o$rn" 2>&1; check "round.sh refuses $label" 2 $? "$TMP/o$rn"
  grep -qF -- "$says" "$TMP/o$rn" || { echo "  FAIL  and it was refused for another reason than \"$says\": $(head -1 "$TMP/o$rn")"; fails=$((fails + 1)); }
  [ "$(hash_of "$RL")" = "$rl_hash" ] || { echo "  FAIL  and yet LOG.md changed"; fails=$((fails + 1)); }
}
refused "a type that is not on the fixed list" "is not on the fixed list" --type audit
refused "a count that is not a whole number" "--medium is a whole number" --medium 1-2
refused "a negative count" "--low is a whole number" --low -1
refused "a date in the short form (not ISO in full)" "both in full" --dates 2026-03-09..03-12
refused "a day that is not in the calendar" "a real day (got '2026-02-30')" --dates 2026-02-30
refused "dates that end before they start" "ends before it starts" --dates 2026-03-12..2026-03-09
refused "a phase outside 0-8" "--phase is a whole number from 0 to 8" --phase 9
refused "a gate that is neither pass nor fail" "--gate is pass, fail" --gate green
refused "a confidence above 1" "--conf is a number from 0 to 1" --conf 1.5
refused "tokens that are not a number" "--tokens is a whole number" --tokens lots
refused "a text field with the separator in it" "--model contains '|'" --model "a | b"
refused "a text field with a newline in it" "--report contains a newline" --report "$(printf 'a\nb')"
refused "an id already in LOG.md" "already has a ROUND line for 'r05'" --id r05
refused "a required field left empty" "--model is required" --model ""
refused "an argument it does not know" "unknown argument '--frobnicate'" -- --frobnicate 1
# `gate pass (read-back pending)` (state/README.md): an interview played from an absent owner's files, the scope not yet
# read back - a real state, written for an interview only, in those words only ... and for a SPEC (K32, FR16): phase 1's
# gate also waits on the owner's read (AGENTS.md section 3), the owner absent the same way
rn=760
refused "the read-back gate on a round that is neither an interview nor a spec" "is an interview's or a spec's only" --gate "pass (read-back pending)"
refused "the read-back gate in other words" "--gate is pass, fail" --type interview --phase 0 --gate "pass (read back pending)"
rround --id i01 --type interview --phase 0 --gate "pass (read-back pending)" -- --dry-run > "$TMP/o736" 2>&1
check "round.sh: an interview with the read-back pending, gate 'pass (read-back pending)' (--dry-run)" 0 $? "$TMP/o736"
rround --id s01 --type spec --phase 1 --gate "pass (read-back pending)" -- --dry-run > "$TMP/o953" 2>&1
check "round.sh: a spec with the owner's read pending, gate 'pass (read-back pending)' (--dry-run)" 0 $? "$TMP/o953"
refused "the read-back gate on a battery round (phase 3's gate waits on no read)" "is an interview's or a spec's only" --type battery --phase 3 --gate "pass (read-back pending)"
RB="$TMP/round-LOG-readback.md"; printf '# LOG\n' > "$RB"; grep '^ROUND ' "$TMP/o736" >> "$RB"
printf 'ROUND x09 | phase 4 | regression | m | bench b | 2026-03-09 | 0H 0M 0L 0I reasoned 0 | gate pass (read-back pending) | cost not measured | r.md\n' >> "$RB"
grep '^ROUND ' "$TMP/o953" >> "$RB"
"$HERE/round.sh" --json "$RB" > "$TMP/o737" 2> "$TMP/o737e"; check "round.sh --json: the read-back gate read on an interview and a spec, refused on a regression round" 1 $? "$TMP/o737e"
if grep -q '"id":"i01",.*"gate":"pass (read-back pending)"' "$TMP/o737" && grep -q '"id":"s01",.*"type":"spec",.*"gate":"pass (read-back pending)"' "$TMP/o737" \
  && [ "$(wc -l < "$TMP/o737" | tr -d ' ')" = "2" ] && grep -q "line 3 is not a ROUND line of the fixed shape (gate" "$TMP/o737e"; then
  echo "  ok    and the interview's and the spec's gates read back as written; the regression round's is named"; else
  echo "  FAIL  --json did not read the read-back gate back, or did not refuse it on a regression round:"; cat "$TMP/o737" "$TMP/o737e" | sed "s/^/        | /"; fails=$((fails + 1)); fi
"$HERE/round.sh" "$RL" --id r06 --phase 4 --type regression --model m --bench b --dates 2026-03-09 --gate pass --report r.md > "$TMP/o143" 2>&1
check "round.sh refuses a round with the findings left out" 2 $? "$TMP/o143"
grep -qF -- "--high is a whole number of findings, required" "$TMP/o143" || { echo "  FAIL  and not for the missing findings: $(head -1 "$TMP/o143")"; fails=$((fails + 1)); }
"$HERE/round.sh" "$TMP/no-such-LOG.md" --id r01 > "$TMP/o145" 2>&1; check "round.sh refuses a LOG.md that does not exist" 2 $? "$TMP/o145"
[ ! -e "$TMP/no-such-LOG.md" ] || { echo "  FAIL  round.sh created the missing LOG.md"; fails=$((fails + 1)); }
if [ "$(hash_of "$RL")" = "$rl_hash" ]; then echo "  ok    and after every refusal LOG.md is byte for byte what the control left"; else
  echo "  FAIL  a refusal wrote into LOG.md"; fails=$((fails + 1)); fi
rround --id r06 --conf "" --tokens "" --minutes "" --files-read "" --tests-written "" -- --dry-run > "$TMP/o146" 2>&1
check "round.sh with every optional field left out, --dry-run" 0 $? "$TMP/o146"
if grep -q '^ROUND r06 .* | gate pass | cost not measured | reports/r05.md$' "$TMP/o146" && [ "$(hash_of "$RL")" = "$rl_hash" ]; then
  echo "  ok    and it says 'cost not measured' (never a guessed zero), and --dry-run wrote nothing"; else
  echo "  FAIL  a round without cost fields was written wrongly, or --dry-run wrote:"; sed "s/^/        | /" "$TMP/o146"; fails=$((fails + 1)); fi
printf 'ROUND r09 | phase 4 | audit | m | bench b | 2026-03-09 | 0H 0M 0L 0I reasoned 0 | gate pass | cost not measured | r.md\n' >> "$RL"
"$HERE/round.sh" --json "$RL" > "$TMP/o147" 2> "$TMP/o147e"; check "round.sh --json over a ROUND line typed by hand with a bad type" 1 $? "$TMP/o147e"
if grep -q "line $(grep -n '^ROUND r09' "$RL" | cut -d: -f1) is not a ROUND line of the fixed shape (type)" "$TMP/o147e" && [ "$(cat "$TMP/o147")" = "$want_json" ]; then
  echo "  ok    and it names that line and the field, and still prints the good one"; else
  echo "  FAIL  --json did not name the bad line, or dropped the good one:"; sed "s/^/        | /" "$TMP/o147e"; fails=$((fails + 1)); fi
"$HERE/round.sh" --json "$HERE/../state/LOG.md" > "$TMP/o148" 2>&1; check "round.sh --json reads the ROUND line of the kit's example LOG.md" 0 $? "$TMP/o148"
"$HERE/round.sh" --json "$HERE/../state/README.md" > "$TMP/o149" 2>&1; check "round.sh --json reads the ROUND line documented in state/README.md" 0 $? "$TMP/o149"
if [ "$(wc -l < "$TMP/o148" | tr -d ' ')" = "1" ] && [ "$(wc -l < "$TMP/o149" | tr -d ' ')" = "1" ]; then echo "  ok    one JSON line from each"; else
  echo "  FAIL  the example files did not give one JSON line each"; fails=$((fails + 1)); fi

# ================================================================= next.sh (STATE.md's flags -> the row of doctrine/NEXT.md; no forge needed)
# One fixture per row of the table (scripts/test/fixtures/state-row-<id>.md) whose FIRST line says how it is run and what
# it must give: `judge=` the answers to the rows that need judgement, `rows=` the rows the output names, in order (the
# gates in force - row 2, row 14 - then the row given), `rc=`. A fixture whose own row needs judgement is run a second
# time without that answer, and must then stop there (rc 3). The fixtures are listed from NEXT.md, not from the directory,
# and by the same rule next.sh reads the table with - every row under "## The table", whatever the form of its id (12,
# 12b, 12a): a row added to the table with no fixture is a red here, as it is (with no entry in next.sh) in its drift guard.
echo "== next.sh =="
NX="$HERE/next.sh"; NXT="$HERE/../doctrine/NEXT.md"
# v0.4.1 (K50, D2): next.sh refuses `phase:` 2 or higher without a green build record, <proj>/.gauntlet/reports/01-build.txt
# (the project: the STATE.md's directory, or its parent when that is .gauntlet/). The fixtures are states of projects
# whose hook compiles: in this section they are read from a copy (NXFIX) in a directory that has that record - forge's
# real output, build-real-compiled.txt - and so is $TMP, where the cases write their variants (removed at the end of the
# section). The rule itself, and a fixture refused without the record: the K50 cases.
NXFIX="$TMP/nxfix"; mkdir -p "$NXFIX/.gauntlet/reports" "$TMP/.gauntlet/reports"
cp "$FIX"/state-*.md "$NXFIX/"; cp "$FIX/build-real-compiled.txt" "$NXFIX/.gauntlet/reports/01-build.txt"; cp "$FIX/build-real-compiled.txt" "$TMP/.gauntlet/reports/01-build.txt"
# v0.4.2 (K60): and the records the flags claim from phase 3 on - a green test record (`battery: green`, and tests that ran
# for phase 3+), an invariant suite under test/, a census report (phase 4+); the fork question is a note in each fixture
for d in "$NXFIX" "$TMP"; do
  cp "$FIX/summary-real-many-suites.txt" "$d/.gauntlet/reports/02-test.txt"; printf 'the everyday campaign'"'"'s census\n' > "$d/.gauntlet/reports/06-census.txt"
  mkdir -p "$d/test"; printf 'contract Inv { function invariant_fixture() public {} }\n' > "$d/test/Inv.t.sol"
  # v0.5: and the independent threat model the phase 4+ fixtures' `threat_model: diffed (1 matched, 0 new, 0
  # refused)` claims - one independent threat, the walker's one threat matching it (the threat-diff.sh section's cases)
  printf 'model: fixture/none\nreceived: the fixture spec\n\nT-1: a stranger / the fees of a pool / a pool naming the hook, then a claim\n' > "$d/.gauntlet/THREATS-independent.md"
  printf 'W-1: a stranger / the fees / a second pool, then a claim\nfrom: doctrine/HOOK-ATTACKS.md class 3\nmatches: T-1\n' > "$d/.gauntlet/THREATS.md"
  # (v0.5) and the diff's report: next.sh reads a diffed line against the two lists' sha256 it keeps (frozen after the diff)
  "$HERE/threat-diff.sh" "$d" > /dev/null 2>&1
done
# next.sh names no row until the kit's selftest has PASSED here (K31) - and this IS the selftest, which has not passed
# yet: its cases run with NEXT_SELFTEST=1, which next.sh names in the first line of its stderr every time it is set. nx
# runs next.sh (or a copy) so, checks that line is there - a run that did not print it is written down, and one is a
# FAIL at the end of this section - and takes it out of what the case reads: every case below reads what next.sh
# prints for a user whose kit is proven. The marker itself, its absence and next.sh honouring it: the K31 cases below.
NX_NOTICE="next: NEXT_SELFTEST=1 - the kit's selftest marker is NOT checked (the selftest's own cases set this; a user never does)"
: > "$TMP/nx-silent"
# K50: the kit's own next.sh adds a note after its answer when the kit has a MANIFEST and a file under it is not listed
# (D6) - the kit's own battery's reports, a MANIFEST not regenerated after an edit. That note is the kit's state, not the
# case's: nx takes it out of what a case reads from the kit's own next.sh, and keeps it ($TMP/nx-kitnotes; the K50
# section says it). A copy of next.sh in a kit copy keeps its note: the K50 cases read it.
: > "$TMP/nx-kitnotes"
nx() { # nx <next.sh or a copy> [its arguments]: its stdout as printed; its stderr, without the notice line, after it
  local bin="$1" rc; shift
  NEXT_SELFTEST=1 "$bin" "$@" 2> "$TMP/nx-stderr" > "$TMP/nx-stdout"; rc=$?
  if [ "$bin" = "$NX" ] && grep -q '^next: note - the kit has ' "$TMP/nx-stdout"; then
    grep '^next: note - the kit has ' "$TMP/nx-stdout" >> "$TMP/nx-kitnotes"
    grep -v '^next: note - the kit has ' "$TMP/nx-stdout" > "$TMP/nx-stdout2"; mv "$TMP/nx-stdout2" "$TMP/nx-stdout"
  fi
  cat "$TMP/nx-stdout"
  if [ "$(sed -n 1p "$TMP/nx-stderr")" = "$NX_NOTICE" ]; then sed 1d "$TMP/nx-stderr" >&2
  else echo "$bin $*" >> "$TMP/nx-silent"; cat "$TMP/nx-stderr" >&2; fi
  return "$rc"
}
nx_ids() { # nx_ids <NEXT.md>: the id of every row of the table, in order
  LC_ALL=C awk '{ sub(/\r$/, "") } /^## / { t = ($0 ~ /^## The table/); next }
    t && /^\|/ && !/^\|[-:| ]+$/ { split($0, c, /[|]/); id = c[2]; gsub(/^[ \t]+|[ \t]+$/, "", id); if (id != "#") print id }' "$1"
}
# the rows the output names, in order - and STOP for row 3's pause (`next: STOP - paused, waiting on the owner: ...`), STOP?
# for the line that says the pause is only CONDITIONAL, rows still to judge (`if every answer is false: STOP - paused, ...`)
nx_rows() { sed -nE 's/^(next|passed|in force|needs judgement): row ([0-9]+[A-Za-z]*)( .*)?$/\2/p; s/^next: (STOP) - .*/\1/p; s/^if every answer is false: (STOP) - .*/\1?/p' "$1" | tr '\n' ',' | sed 's/,$//'; }
nx_meta() { sed -nE "1s/.* $2=([^ ]+).*/\\1/p" "$1"; }   # nx_meta <fixture> <judge|rows|rc>
nx "$NX" --check-table > "$TMP/o400" 2>&1
if [ -n "$(nx_ids "$NXT")" ] && grep -qF " rows, $(nx_ids "$NXT" | tr '\n' ' ' | sed 's/ $//')." "$TMP/o400"; then
  echo "  ok    the fixture list and next.sh read the same rows from NEXT.md: $(nx_ids "$NXT" | tr '\n' ' ')"; else
  echo "  FAIL  the fixture list ($(nx_ids "$NXT" | tr '\n' ' ')) and next.sh (below) do not read the same rows:"; sed "s/^/        | /" "$TMP/o400"; fails=$((fails + 1)); fi
nn=400
for id in $(nx_ids "$NXT"); do
  f="$NXFIX/state-row-$id.md"; nn=$((nn + 1))
  if [ ! -f "$f" ]; then echo "  FAIL  NEXT.md row $id has no fixture (state-row-$id.md)"; fails=$((fails + 1)); continue; fi
  j="$(nx_meta "$f" judge)"; want="$(nx_meta "$f" rows)"; wrc="$(nx_meta "$f" rc)"
  a=(); [ "$j" = "none" ] || a=(--judge "$j")
  nx "$NX" "$f" "${a[@]}" > "$TMP/o$nn" 2>&1; check "next.sh: the fixture for row $id gives rows $want" "$wrc" $? "$TMP/o$nn"
  got="$(nx_rows "$TMP/o$nn")"
  rid="$id"; [ "$id" != 3 ] || rid=STOP   # row 3's action, when it is given, is the pause
  case ",$want," in *",$rid,"*) ;; *) echo "  FAIL  the fixture for row $id does not name row $id in rows="; fails=$((fails + 1)) ;; esac
  if [ "$got" != "$want" ]; then echo "  FAIL  and it named rows '$got', not '$want'"; sed "s/^/        | /" "$TMP/o$nn"; fails=$((fails + 1)); fi
  if [ "$wrc" = "0" ] && ! grep -q '^because: ' "$TMP/o$nn"; then echo "  FAIL  and it did not say which flags made row $id true"; fails=$((fails + 1)); fi
  case ",$j," in *",$id=true,"*)
    j2="$(printf ',%s,' "$j" | sed "s/,$id=true,/,/; s/^,//; s/,$//")"
    a=(); [ -z "$j2" ] || a=(--judge "$j2")
    nx "$NX" "$f" "${a[@]}" > "$TMP/o${nn}j" 2>&1; check "next.sh: row $id without its answer stops there, needing judgement" 3 $? "$TMP/o${nn}j"
    [ "$(grep -m 1 '^needs judgement: ' "$TMP/o${nn}j" | sed -nE 's/^needs judgement: row ([0-9]+[A-Za-z]*) .*/\1/p')" = "$id" ] \
      || { echo "  FAIL  and the first row needing judgement is not row $id"; sed "s/^/        | /" "$TMP/o${nn}j"; fails=$((fails + 1)); } ;;
  esac
done
nx "$NX" "$NXFIX/state-row-6.md" --judge 5=false > "$TMP/o440" 2>&1
if grep -q '^next: row 6 - run the battery$' "$TMP/o440" && grep -q '^because: .*bytecode_changed_since.last_battery=yes' "$TMP/o440"; then
  echo "  ok    the row is printed with its action as NEXT.md words it, and the flag that made it true"; else
  echo "  FAIL  row 6 was not printed as 'next: row 6 - run the battery' with its flag:"; sed "s/^/        | /" "$TMP/o440"; fails=$((fails + 1)); fi
# the second branch of a row, and a note that quiets one
nx_variant() { # nx_variant <n> <label> <fixture> <sed script> <judge|-> <rc> <rows>
  local n="$1" label="$2" fx="$3" sc="$4" j="$5" wrc="$6" want="$7"; local -a a=()
  sed "$sc" "$NXFIX/$fx" > "$TMP/state-$n.md"; [ "$j" = "-" ] || a=(--judge "$j")
  nx "$NX" "$TMP/state-$n.md" "${a[@]}" > "$TMP/o$n" 2>&1; check "next.sh: $label" "$wrc" $? "$TMP/o$n"
  [ "$(nx_rows "$TMP/o$n")" = "$want" ] || { echo "  FAIL  and it named rows '$(nx_rows "$TMP/o$n")', not '$want'"; sed "s/^/        | /" "$TMP/o$n"; fails=$((fails + 1)); }
}
nx_variant 445 "row 13b by its second branch: a clean discovery round, a REASONED medium still open" state-row-13b.md \
  's/^last_audit_round: .*/last_audit_round: r04 discovery 0H 0M 0L/; s/^open_findings: .*/open_findings: high=0 medium=1 low=0 reasoned_high_or_medium=1/' \
  5=false,8=false,9=false,9b=false,10=false,11b=false 0 13b
nx_variant 446 "a pending: note does not make row 1 by itself: a provisional high is counted in open_findings high (row 6b)" state-row-5.md \
  's/^notes: .*/notes: pending: F-3 - no fee-on-transfer loss, owner undecided; fork: n\/a - a next.sh fixture, no chain/' - 3 "5,8,10,11b,13b"
nx_variant 447 "row 7b is quiet when notes: says what replaced the real manager" state-row-7b.md \
  's/^notes: .*/notes: fork: n\/a - its own manager; real manager: the hook runs on its own manager, dossier section 8/' \
  5=false 3 "8,10,11b,13b"
nx_variant 448 "phase 2 is row 4b's, not row 4's" state-row-4b.md 's/^phase: .*/phase: 2/' - 0 4b
nx "$NX" "$NXFIX/state-new-project.md" > "$TMP/o441" 2>&1; check "next.sh: a new project, NEXT.md's starting values, gives row 4" 0 $? "$TMP/o441"
[ "$(nx_rows "$TMP/o441")" = "4" ] || { echo "  FAIL  and it named rows '$(nx_rows "$TMP/o441")', not 4"; fails=$((fails + 1)); }
# cases beyond one per row, and the hole (state-case-*.md, state-hole*.md): the same first line, `rc=1` for a hole. The
# hole left is a STALE flag: open_findings says a medium is open at the ceiling, the answers say no finding waits (9 and
# 9b false) - no row is true, and neither the black-box (row 12, off at the ceiling) nor promotion (row 14 is not in
# force while a finding is open) may be given instead.
nn=500
for f in "$NXFIX"/state-case-*.md "$NXFIX"/state-hole*.md; do
  nn=$((nn + 1)); j="$(nx_meta "$f" judge)"; want="$(nx_meta "$f" rows)"; wrc="$(nx_meta "$f" rc)"
  a=(); [ "$j" = "none" ] || a=(--judge "$j")
  nx "$NX" "$f" "${a[@]}" > "$TMP/o$nn" 2>&1; nrc=$?   # before the label's $(...), which would reset $?
  check "next.sh: $(basename "$f" .md) gives rows $want" "$wrc" "$nrc" "$TMP/o$nn"
  got="$(nx_rows "$TMP/o$nn")"; [ -n "$got" ] || got=none
  if [ "$got" != "$want" ]; then echo "  FAIL  and it named rows '$got', not '$want'"; sed "s/^/        | /" "$TMP/o$nn"; fails=$((fails + 1)); fi
  if [ "$wrc" = "1" ] && ! grep -qx 'no row is true: the table has a hole or a flag is stale' "$TMP/o$nn"; then
    echo "  FAIL  and not with NEXT.md's STOP line"; fails=$((fails + 1)); fi
done
[ "$nn" -ge 538 ] || { echo "  FAIL  fewer case fixtures than written (state-case-*.md, state-hole*.md): $((nn - 500)) of 38"; fails=$((fails + 1)); }
# V26b's probes a1-a11 (row 1 was quiet by an id that is not an open high: `high all`, `TBA`, the count `1`, a medium's
# id, one high spelled twice...), as fixtures (state-v26b-*.md, the same first line): with open_findings naming the open
# highs (K28) each is REFUSED (an id recorded to tell that is not an open high) or ASKED - never quiet, never a STOP. And
# the same file with the ids taken out of open_findings (as V26b wrote it: `high=1`, no ids) is refused: a count needs
# its ids. V28's probes (state-v28-*.md: the same non-id on BOTH sides - `high=1 (all)` and `high all - to tell`, `TBA`,
# `pending`, `1`, `TBD.`, `None.` - quieted row 1: STOP rc 0) are run the same way: an id has at least one letter and one
# digit, and a word that is not one is refused where it stands (`refused=not-an-id` in the first line, K29).
nn=840
for f in "$NXFIX"/state-v26b-*.md "$NXFIX"/state-v28-*.md; do
  nn=$((nn + 1)); j="$(nx_meta "$f" judge)"; want="$(nx_meta "$f" rows)"; wrc="$(nx_meta "$f" rc)"
  a=(); [ "$j" = "none" ] || a=(--judge "$j")
  nx "$NX" "$f" "${a[@]}" > "$TMP/o$nn" 2>&1; nrc=$?
  check "next.sh: $(basename "$f" .md) gives rows $want" "$wrc" "$nrc" "$TMP/o$nn"
  got="$(nx_rows "$TMP/o$nn")"; [ -n "$got" ] || got=none
  if [ "$got" != "$want" ]; then echo "  FAIL  and it named rows '$got', not '$want'"; sed "s/^/        | /" "$TMP/o$nn"; fails=$((fails + 1)); fi
  if grep -qE '^next: STOP|row 1 is quiet' "$TMP/o$nn"; then echo "  FAIL  and row 1 was quiet, or the pause was given"; sed "s/^/        | /" "$TMP/o$nn"; fails=$((fails + 1)); fi
  case "$wrc" in
    2) if [ "$(nx_meta "$f" refused)" = not-an-id ]; then
         grep -qE "'[^']*' is not an id: an id has at least one letter and one digit" "$TMP/o$nn" \
           || { echo "  FAIL  and not refused as a word that is not an id: $(head -1 "$TMP/o$nn")"; fails=$((fails + 1)); }
       else
         grep -qF "is not an open high in open_findings" "$TMP/o$nn" && grep -qF "a recorded high is no longer open: remove it" "$TMP/o$nn" \
           || { echo "  FAIL  and not refused as a recorded high that is not open: $(head -1 "$TMP/o$nn")"; fails=$((fails + 1)); }
       fi ;;
    3) [ "$(sed -n 1p "$TMP/o$nn" | cut -c1-24)" = "needs judgement: row 1 -" ] \
         || { echo "  FAIL  and row 1 is not the first question"; sed "s/^/        | /" "$TMP/o$nn"; fails=$((fails + 1)); } ;;
    *) echo "  FAIL  $(basename "$f"): rc=$wrc in its first line is neither 2 (refused) nor 3 (asked)"; fails=$((fails + 1)) ;;
  esac
  sed -E 's/^(open_findings:[[:space:]]+high=[0-9]+) [(][^()]*[)]/\1/' "$f" > "$TMP/state-${nn}n.md"
  cmp -s "$f" "$TMP/state-${nn}n.md" && { echo "  FAIL  $(basename "$f"): no ids to take out of open_findings"; fails=$((fails + 1)); }
  nx "$NX" "$TMP/state-${nn}n.md" "${a[@]}" > "$TMP/o${nn}n" 2>&1
  check "next.sh: the same, open_findings without its ids (as V26b wrote it): refused" 2 $? "$TMP/o${nn}n"
  grep -qF "names no ids" "$TMP/o${nn}n" || { echo "  FAIL  and not for a count with no ids: $(head -1 "$TMP/o${nn}n")"; fails=$((fails + 1)); }
done
[ "$nn" -ge 857 ] || { echo "  FAIL  fewer V26b and V28 fixtures than written (state-v26b-*.md, state-v28-*.md): $((nn - 840)) of 17"; fails=$((fails + 1)); }
nx_variant 449 "full mode at the ceiling, the black-box STALE, the owner wants to freeze: row 16" \
  state-case-ceiling-full-blackbox-never.md 's/^blackbox: .*/blackbox: stale (an event changed since it ran)/' \
  5=false,8=false,10=false,16=true 0 "2,14,16"
nx_variant 488 "promoted, the rehearsal not yet done, at the ceiling: still row 17" state-row-17.md \
  's/^ceiling: .*/ceiling: 4 model rounds (light mode) agreed; 4 used/' 5=false,8=false,10=false 0 "2,14,17"
# row 7b waits on the owner while waiting_on_owner asks for the endpoint or the chain: an item that contains RPC_URL, or that
# IS the chain question (`chain`, or starting with `chain`, `target chain`, `which chain`) - not the word inside another question
nx_variant 601 "waiting_on_owner names chain as its second item: row 7b is off, round 1 goes on" state-case-waiting-rpc-url.md \
  's/^waiting_on_owner: .*/waiting_on_owner: severity of F-7; chain - which one?/' 5=false,11b=false 0 11
nx_variant 602 "the word chain inside another question (severity of F-7, it depends on the chain) is not the chain question: 7b stands" \
  state-case-waiting-rpc-url.md 's/^waiting_on_owner: .*/waiting_on_owner: severity of F-7 (it depends on the chain)/' 5=false 0 7b
nx_variant 738 "an item that starts with target chain is the chain question: row 7b is off" state-case-waiting-rpc-url.md \
  "s/^waiting_on_owner: .*/waiting_on_owner: severity of F-7 $(printf '\302\267') target chain (the owner has not said)/" 5=false,11b=false 0 11
nx_variant 739 "an item that starts with which chain is the chain question: row 7b is off" state-case-waiting-rpc-url.md \
  's/^waiting_on_owner: .*/waiting_on_owner: which chain does it deploy on?/' 5=false,11b=false 0 11
nx_variant 740 "an item that is chain alone is the chain question: row 7b is off" state-case-waiting-rpc-url.md \
  's/^waiting_on_owner: .*/waiting_on_owner: triage of F-2; chain/' 5=false,11b=false 0 11
nx_variant 741 "a told: note written as a Markdown list item (* told: ...) does not quiet row 1: it is asked (K26b)" state-row-1.md \
  's/^notes: .*/notes: fork: n\/a - no chain yet\n  * told: F-1 (2026-09-27)/' 5=false,8=false,9=true 3 "1,9"
nx_variant 620 "waiting_on_owner names neither (a blockchain explorer, the RPC endpoint in words): row 7b stands" \
  state-case-waiting-rpc-url.md 's/^waiting_on_owner: .*/waiting_on_owner: severity of F-7 (a blockchain explorer link; the RPC endpoint is set)/' \
  5=false,11b=false 0 7b
nx_variant 627 "waiting_on_owner names the Chain with a capital, at the start of a sentence: row 7b is off" \
  state-case-waiting-rpc-url.md 's/^waiting_on_owner: .*/waiting_on_owner: Chain - which one does the owner deploy on? (asked 2026-09-24)/' \
  5=false,11b=false 0 11
# row 2 keeps 11b off (a retry is a model round), whatever the answer
nx_variant 603 "at the ceiling a stopped round is not retried: 11b answered true is still off" state-row-2.md '' \
  5=false,8=false,10=false,11b=true,16=true 0 "2,14,16"
# the same state, CRLF: the same row
nx_variant 604 "a STATE.md with CRLF line endings gives the same rows as with LF" state-row-17.md 's/$/\r/' \
  5=false,8=false,10=false,11b=false 0 "14,17"
nx_variant 605 "rehearsal: done on a leap day (2024-02-29) is a date" state-row-18.md 's/^rehearsal: .*/rehearsal: done (2024-02-29)/' \
  5=false,8=false,10=false,11b=false 0 "14,18"
# row 1 (K26b, K28): ONLY items `high <id>[, <id>...] - to tell` of waiting_on_owner quiet it, and only when EVERY id of
# open_findings' `high=N (<ids>)` is among them (case aside); a told: note is not read (the owner present: the question
# is asked, and answered 1=false) - V26's T3, T5-T7, T9-T11, T13: `told: F-1` of a closed high, `told: none`, `told: TBD`,
# `Told: F-1`, `told: nobody` ...
nx_variant 606 "a told: note (told: none) does not quiet row 1: it is asked" state-row-1.md \
  's/^notes: .*/notes: fork: n\/a - no chain yet; told: none/' 5=false,8=false,9=true 3 "1,9"
nx_variant 607 "a told: note on an indented line under notes: does not quiet row 1: it is asked" state-row-1.md \
  's/^notes: .*/notes: fork: n\/a - no chain yet\n  told: F-1/' 5=false,8=false,9=true 3 "1,9"
nx_variant 671 "the same, answered 1=false (the owner told, present): row 9" state-row-1.md \
  's/^notes: .*/notes: fork: n\/a - no chain yet\n  told: F-1/' 1=false,5=false,8=false,9=true 0 9
nx_variant 672 "an item that says the high was told (high F-1 - told) is not a high to tell: row 1 is asked" state-row-1.md \
  's/^waiting_on_owner: .*/waiting_on_owner: high F-1 - told/' 5=false,8=false,9=true 3 "1,9"
nx_variant 630 "two highs open, one item naming both between commas: row 1 is quiet" state-row-1.md \
  's/^open_findings: .*/open_findings: high=2 (F-1, F-2) medium=0 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high F-1, F-2 - to tell (with their tests)/' \
  5=false,8=false,9=true 0 9
nx_variant 673 "two highs open, one item naming both between spaces: row 1 is quiet" state-row-1.md \
  's/^open_findings: .*/open_findings: high=2 (F-1 F-2) medium=0 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high F-1 F-2 - to tell/' \
  5=false,8=false,9=true 0 9
nx_variant 631 "two highs open, the same id recorded twice (F-1 and f-1: one id, case aside): row 1 is asked" state-row-1.md \
  's/^open_findings: .*/open_findings: high=2 (F-1, F-2) medium=0 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high F-1 - to tell; high f-1 - to tell/' \
  5=false,8=false,9=true 3 "1,9"
nx_variant 674 "one high open, the same id in two items (F-1, f-1): counted once, row 1 is quiet" state-row-1.md \
  's/^waiting_on_owner: .*/waiting_on_owner: high F-1 - to tell; high f-1 - to tell/' 5=false,8=false,9=true 0 9
# K28: row 1 by ids - quiet only when every id of open_findings' `high=N (<ids>)` is recorded to tell, in any order, case
# aside, in one item or several; one not recorded, and it is asked (the question names it)
nx_variant 830 "two highs open, recorded in the other order and case (high f-2 F-1): row 1 is quiet" state-row-1.md \
  's/^open_findings: .*/open_findings: high=2 (F-1, F-2) medium=0 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high f-2 F-1 - to tell/' \
  5=false,8=false,9=true 0 9
nx_variant 831 "two highs open, one per item: row 1 is quiet" state-row-1.md \
  's/^open_findings: .*/open_findings: high=2 (F-1, F-2) medium=0 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high F-2 - to tell; triage of F-1 F-2; high F-1 - to tell/' \
  5=false,8=false,9=true 0 9
nx_variant 832 "the ids after a key other than first (medium=0 high=1 (F-1) ...), a comment after: row 1 is quiet" state-row-1.md \
  's/^open_findings: .*/open_findings: medium=0 high=1 (F-1) low=0 reasoned_high_or_medium=0   (F-1: the fee cap; see the report)/; s/^waiting_on_owner: .*/waiting_on_owner: high F-1 - to tell/' \
  5=false,8=false,9=true 0 9
nx "$NX" "$NXFIX/state-case-high-not-all-told.md" --judge 5=false,8=false,9=false > "$TMP/o833" 2>&1
if grep -q '^needs judgement: row 1 - .*F-2 not recorded to tell' "$TMP/o833" && ! grep -q 'F-1 not recorded' "$TMP/o833"; then
  echo "  ok    one high of two recorded: row 1's question names the one not recorded (F-2), not the one recorded"; else
  echo "  FAIL  row 1's question does not name F-2 as the high not recorded to tell:"; sed "s/^/        | /" "$TMP/o833"; fails=$((fails + 1)); fi
nx "$NX" "$NXFIX/state-case-high-not-all-told.md" > "$TMP/o632" 2>&1
if [ "$(sed -n 1p "$TMP/o632" | cut -c1-24)" = "needs judgement: row 1 -" ] && grep -q '^needs judgement: row 1 - .*high <id>' "$TMP/o632" \
  && [ "$(tail -1 "$TMP/o632")" = "if every answer is false: STOP - paused, waiting on the owner: high F-1 - to tell" ]; then
  echo "  ok    one high of two recorded to tell: row 1 is ASKED (the flags quiet it only when every open high is recorded)"; else
  echo "  FAIL  one high of two recorded: row 1 is not asked:"; sed "s/^/        | /" "$TMP/o632"; fails=$((fails + 1)); fi
# ... and when the flags quiet it, the because: line names the ids that did (V26: a stale entry quieted it without a trace)
nx "$NX" "$NXFIX/state-case-high-recorded-to-tell.md" --judge 5=false,8=false,9=false,10=false,11b=false > "$TMP/o675" 2>&1
if grep -q '^because: .*row 1 is quiet: the 1 high open is recorded to tell in waiting_on_owner (F-1)' "$TMP/o675"; then
  echo "  ok    row 1 quiet by the flags: the because: line names the id that quieted it"; else
  echo "  FAIL  row 1 quiet, and the because: line does not name the id:"; sed "s/^/        | /" "$TMP/o675"; fails=$((fails + 1)); fi
nx "$NX" "$NXFIX/state-case-walk-ids-space.md" --judge 5=false,8=false,9=false,9b=true,10=false > "$TMP/o676" 2>&1
if grep -q '^because: .*row 1 is quiet: the 6 highs open are recorded to tell in waiting_on_owner (F1, F3, F4, R01-1, R01-2, R01-5)' "$TMP/o676"; then
  echo "  ok    and on a row given below it too (the real walk's six ids, in the order written)"; else
  echo "  FAIL  the row given does not say which ids quieted row 1:"; sed "s/^/        | /" "$TMP/o676"; fails=$((fails + 1)); fi
# row 9 (NEXT.md): a finding triaged "fix at the cause" whose fix is not written is still open - its question says so,
# and its action is to write the fix
nx "$NX" "$NXFIX/state-case-fix-not-written.md" --judge 5=false,8=false > "$TMP/o608" 2>&1
check "next.sh: a medium triaged fix-at-the-cause, not written: row 9 needs judgement" 3 $? "$TMP/o608"
grep -q '^needs judgement: row 9 - .*fix at the cause' "$TMP/o608" \
  || { echo "  FAIL  and row 9's question does not name a fix at the cause not yet written"; sed "s/^/        | /" "$TMP/o608"; fails=$((fails + 1)); }
nx "$NX" "$NXFIX/state-case-fix-not-written.md" --judge 5=false,8=false,9=true > "$TMP/o609" 2>&1
check "next.sh: the same, row 9 answered true: row 9" 0 $? "$TMP/o609"
grep -q '^next: row 9 - .*a fix already decided: write it' "$TMP/o609" \
  || { echo "  FAIL  and row 9's action does not say: a fix already decided: write it";sed "s/^/        | /" "$TMP/o609"; fails=$((fails + 1)); }
# notes are read by name only at the START of a note item: a note line (the value of notes:, or an indented line under it),
# or a part of one after the middle dot or ";" - real manager: (row 7b) as pending: (row 1)
nx_variant 610 "a real manager: note after the middle dot quiets row 7b: 14, 16" state-case-real-manager-note-not-at-start.md \
  "s/^notes: .*/notes: fork: ran on a fork $(printf '\302\267') real manager: the hook runs on its own vault, dossier section 8/" \
  5=false,8=false,10=false,11b=false,16=true 0 "14,16"
nx_variant 611 "a told: note after a ';' on the notes: line does not quiet row 1: it is asked (K26b)" state-row-1.md \
  's/^notes: .*/notes: fork: n\/a - no chain yet; told: F-1/' 5=false,8=false,9=true 3 "1,9"
# rows 12 and 16 wait on 7b while the chain is known and the real manager never ran (or is stale), unless a real manager:
# note answers it; with 7b silenced by a wait and nothing else standing, row 3 pauses the route (STOP) and says what is waiting
nx_variant 612 "the loop over, 16 off until 7b has run - the owner declined promotion in writing: 18b stands" \
  state-case-real-manager-owed-before-16.md '' 5=false,8=false,10=false,11b=false,16=true,18b=true 0 "14,18b"
nx_variant 613 "the same wait, a real manager: note answers 7b another way: row 12 stands" state-case-real-manager-owed-before-12.md \
  's/^notes: .*/notes: fork: ran on a fork; real manager: the hook runs on its own vault, dossier section 8/' \
  5=false,8=false,10=false,11b=false,12=true 0 12
nx_variant 614 "the real manager never run and nothing waiting: row 7b, before the black-box" state-case-real-manager-owed-before-12.md \
  's/^waiting_on_owner: .*/waiting_on_owner: none/' 5=false,8=false,10=false,11b=false,12=true 0 7b
nx_variant 621 "the real-manager battery STALE, the chain known, 7b waiting: row 16 is off too, row 3 pauses (STOP)" \
  state-case-real-manager-owed-before-16.md 's/^real_manager_battery: .*/real_manager_battery: stale (bytecode changed since)/' \
  5=false,8=false,10=false,11b=false,16=true,18b=false 0 "14,STOP"
# a wait that explains nothing below (the real manager is current) is still a wait: with waiting_on_owner not none and no
# row standing, the flags say PAUSED (NEXT.md row 3, K26) - the STOP line names the item, so a stale one is read there
nx_variant 628 "the same wait, the real manager CURRENT (7b not owed), the owner neither freezes nor declines: paused (STOP), not a hole" \
  state-case-real-manager-owed-before-16.md 's/^real_manager_battery: .*/real_manager_battery: current/' \
  5=false,8=false,10=false,11b=false,16=false,18b=false 0 "14,STOP"
nx_variant 624 "at the ceiling too: the black-box not run, 16 off while 7b waits on RPC_URL - row 3 pauses (STOP)" \
  state-case-ceiling-full-blackbox-never.md \
  's/^real_manager_battery: .*/real_manager_battery: never/; s/^waiting_on_owner: .*/waiting_on_owner: RPC_URL for the real-manager battery/' \
  5=false,8=false,10=false,16=true,18b=false 0 "2,14,STOP"
nx "$NX" "$NXFIX/state-case-real-manager-owed-before-16.md" --judge 5=false,8=false,10=false,11b=false,16=true,18b=false > "$TMP/o615" 2>&1
if grep -qx 'next: STOP - paused, waiting on the owner: RPC_URL for the real-manager battery' "$TMP/o615" && grep -q '^because: .*RPC_URL.*7b' "$TMP/o615"; then
  echo "  ok    and the pause says what is waiting, and that row 7b waits on it"; else
  echo "  FAIL  the pause was not given with its reason (7b waits on the answer; 12 and 16 wait on 7b):"; sed "s/^/        | /" "$TMP/o615"; fails=$((fails + 1)); fi
# the end of the route with the owner absent (NEXT.md row 3, K26): the skeleton names the open findings, the triage is
# asked, nothing below stands - `next: STOP - paused, ...`, exit 0, decided by the flags: row 3's question is not asked
F9S="$NXFIX/state-case-skeleton-written-owner-away.md"
nx "$NX" "$F9S" --judge 5=false,8=false,9=false,10=false,11b=false > "$TMP/o633" 2>&1; check "next.sh: the skeleton written, the owner away: the pause" 0 $? "$TMP/o633"
if [ "$(head -1 "$TMP/o633")" = "next: STOP - paused, waiting on the owner: triage of F-1, F-2" ] && ! grep -q '^needs judgement' "$TMP/o633" \
  && grep -q '^because: .*dossier names the 2 open finding' "$TMP/o633"; then
  echo "  ok    its first word is STOP, it names the items waiting and the skeleton, and it asks nothing about row 3"; else
  echo "  FAIL  the pause is not 'next: STOP - paused, waiting on the owner: <items>' alone:"; sed "s/^/        | /" "$TMP/o633"; fails=$((fails + 1)); fi
nx "$NX" "$F9S" > "$TMP/o634" 2>&1; check "next.sh: the same, no answers: the questions, and the pause only as a condition" 3 $? "$TMP/o634"
# K26b: while a row below row 3 still awaits judgement the pause is not given (V26: "next: STOP" and "no row below row 3
# stands" said more than was true) - the questions, then ONE line saying what an all-false answer gives
if [ "$(nx_rows "$TMP/o634")" = "5,8,9,10,11b,STOP?" ] && [ "$(tail -1 "$TMP/o634")" = 'if every answer is false: STOP - paused, waiting on the owner: triage of F-1, F-2' ] \
  && ! grep -q '^next: \|^because: \|no row below row 3' "$TMP/o634"; then
  echo "  ok    and row 3 is not among them, no next: or because: line - the last line says what an all-false answer gives"; else
  echo "  FAIL  the rows needing judgement before the pause:"; sed "s/^/        | /" "$TMP/o634"; fails=$((fails + 1)); fi
# ... the answers a walker gave in the A/B (its second round): 9b=true (row 3 is no longer answered, K26c) - the pause, not row 9b again
nx_variant 635 "the skeleton written, 9b=true answered: still the pause, not row 9b again" state-case-skeleton-written-owner-away.md '' \
  5=false,8=false,9=false,9b=true,10=false,11b=false 0 STOP
# ... the skeleton stale (a finding opened since): 9b again - and with K written in words, or no K, refused (row 9b reads it)
# ... a `complete` dossier with a finding open is refused (K28, NEXT.md: `complete` means no finding is open - with one
# open the dossier is a skeleton); with none open it is read as before
sed 's/^dossier: .*/dossier: complete (1 judge not done)/' "$NXFIX/state-case-skeleton-written-owner-away.md" > "$TMP/state-636.md"
nx "$NX" "$TMP/state-636.md" --judge 5=false,8=false,9=false,10=false,11b=false > "$TMP/o636" 2>&1
check "next.sh: a complete dossier with 2 findings open is refused" 2 $? "$TMP/o636"
if grep -qF "a dossier with an open finding is a skeleton" "$TMP/o636" && ! grep -qE '^next: (STOP|row) ' "$TMP/o636"; then
  echo "  ok    and it says a dossier with an open finding is a skeleton, and gives no next: line"; else
  echo "  FAIL  the complete dossier with findings open was not refused as a skeleton:"; sed "s/^/        | /" "$TMP/o636"; fails=$((fails + 1)); fi
sed 's/^dossier: .*/dossier: complete (1 judge not done)/; s/^open_findings: .*/open_findings: high=0 medium=0 low=1 reasoned_high_or_medium=0/' \
  "$NXFIX/state-case-skeleton-written-owner-away.md" > "$TMP/state-641.md"
nx "$NX" "$TMP/state-641.md" --judge 5=false,8=false,9=false,10=false,11b=false > "$TMP/o641" 2>&1
check "next.sh: a complete dossier with one LOW open is refused too (high + medium + low)" 2 $? "$TMP/o641"
nx_variant 642 "a complete dossier with no finding open: read as before (the loop over, neither freeze nor decline: the pause)" \
  state-case-skeleton-written-owner-away.md \
  's/^dossier: .*/dossier: complete (1 judge not done)/; s/^open_findings: .*/open_findings: high=0 medium=0 low=0 reasoned_high_or_medium=0/' \
  5=false,8=false,10=false,11b=false,16=false,18b=false 0 "14,STOP"
nx_variant 637 "the skeleton names 2, open_findings has 1 (one fixed since): stale, row 9b" state-case-skeleton-written-owner-away.md \
  's/^open_findings: .*/open_findings: high=0 medium=1 low=0 reasoned_high_or_medium=0/' 5=false,8=false,9=false,9b=true 0 9b
nx_variant 638 "waiting_on_owner none, the skeleton written, nothing stands: a hole, not a pause" state-case-skeleton-written-owner-away.md \
  's/^waiting_on_owner: .*/waiting_on_owner: none/' 5=false,8=false,9=false,10=false,11b=false 1 ""
# ... below the ceiling the black-box (12) and a retry (11b) are still to judge (V26 S8): an answer true gives that row
# (row 3 asks nothing: K26c); the pause only once they are false too
nx_variant 678 "below the ceiling, the black-box judged to stand (12=true): row 12, and no question about row 3 (V26 S8, K26c)" \
  state-case-pause-below-ceiling.md '' 5=false,8=false,9=false,10=false,11b=false,12=true 0 12
nx_variant 680 "the same, every one false: the pause" state-case-pause-below-ceiling.md '' 5=false,8=false,9=false,10=false,11b=false,12=false 0 STOP
# ... and row 1 still to judge (a high not recorded to tell) is a row to judge like the others: the pause is conditional
nx_variant 681 "the high not recorded to tell, the rest answered false: row 1 asked, the pause only as a condition" \
  state-case-pause-rows-to-judge.md 's/^waiting_on_owner: .*/waiting_on_owner: triage of F-1 F-2/' 5=false,8=false,9=false,10=false 3 "1,2,STOP?"
nx_variant 682 "the same, 1=false: the pause" \
  state-case-pause-rows-to-judge.md 's/^waiting_on_owner: .*/waiting_on_owner: triage of F-1 F-2/' 1=false,5=false,8=false,9=false,10=false 0 "2,STOP"
nx_variant 683 "the same, 1=true: row 1 - tell them (record it to tell)" \
  state-case-pause-rows-to-judge.md 's/^waiting_on_owner: .*/waiting_on_owner: triage of F-1 F-2/' 1=true,5=false,8=false,9=false,10=false 0 1
# K26c (V26b): row 3 is decided by the flags and never answered. `--judge 3=true` was read, and gave `next: STOP -
# paused` over the rows the flags made true below it - the answer to row 3 hid them: with `dossier: none` and findings
# open (row 9b), with `battery: never` (row 6), on the real walk before 9b was answered. Now an answer to row 3 is
# REFUSED (exit 2, no next: line at all - a refusal can hide no row; an answer ignored would still read as judged), and
# each case gives its row. The old question ("3=false when the row given does not depend on it") is no longer asked: a
# row below that waits on the owner's answer is answered false itself, or is off by its flags (7b).
F3N="$NXFIX/state-case-row3-dossier-none.md"
sed 's/^battery: .*/battery:                   never/' "$F3N" > "$TMP/state-808.md"
for c in "805|$F3N|3=true|dossier none, findings open (row 9b stands)" "806|$F3N|3=false|the same, 3=false" \
  "807|$FIX/state-case-walk-ids-comma.md|5=false,3=true|the real walk, 9b not answered yet" "808|$TMP/state-808.md|3=true|battery: never (row 6 stands on the flags)"; do
  IFS='|' read -r n f j label <<< "$c"
  nx "$NX" "$f" --judge "$j" > "$TMP/o$n" 2>&1; check "next.sh: --judge $j is refused: $label (V26b)" 2 $? "$TMP/o$n"
  if grep -qF "row 3 is decided by the flags: waiting_on_owner and the rows below" "$TMP/o$n" && ! grep -qE '^next: (STOP|row) ' "$TMP/o$n"; then
    echo "  ok    and it says row 3 is the flags', and gives no next: line - neither STOP nor a row"; else
    echo "  FAIL  the answer to row 3 was not refused as the flags':"; sed "s/^/        | /" "$TMP/o$n"; fails=$((fails + 1)); fi
done
nx_variant 809 "dossier none, findings open, row 3 not answered: row 9b is given (the rows below are read on)" state-case-row3-dossier-none.md '' \
  5=false,8=false,9=false,9b=true 0 "2,9b"
# (K50: was `battery: never` at phase 4, which next.sh now refuses - phase 3+ claims a battery run, D2; row 6 here by its
# other branch, the battery's inputs changed)
nx_variant 810 "the battery's inputs changed (last_battery=yes), the owner away, row 3 not answered: row 6, and no question about row 3" state-case-row3-dossier-none.md \
  's/last_battery=no/last_battery=yes/' 5=false 0 "2,6"
nx_variant 811 "the real walk, 9b answered true, row 3 not answered: row 9b" state-case-walk-ids-comma.md '' 5=false,8=false,9=false,9b=true 0 "2,9b"
nx_variant 812 "the real walk, nothing answered: the questions and the pause as a condition, never a question about row 3" \
  state-case-walk-ids-comma.md '' - 3 "2,5,8,9,9b,10,STOP?"
# rows 9 and 9b count EVERY open finding, from any round - a phase-3 pending: finding too, once round 1 has run
nx "$NX" "$NXFIX/state-case-pending-after-round1.md" --judge 5=false,8=false > "$TMP/o616" 2>&1
check "next.sh: a phase-3 pending medium after round 1, not answered: rows 9 and 9b need judgement" 3 $? "$TMP/o616"
grep -q '^needs judgement: row 9 - .*from any round' "$TMP/o616" && grep -q '^needs judgement: row 9b - .*from any round' "$TMP/o616" \
  || { echo "  FAIL  and rows 9 and 9b do not ask about a finding from any round:"; sed "s/^/        | /" "$TMP/o616"; fails=$((fails + 1)); }
# ... unless the ceiling is reached before round 1 delivered: round 1 will not run, and row 2 sends every open finding to 9/9b
nx_variant 622 "a phase-3 pending medium, the ceiling reached before round 1 delivered: row 9 (the owner there)" \
  state-case-pending-before-round1.md 's/^ceiling: .*/ceiling: 4 model rounds (light mode) agreed; 4 used/' 5=false,9=true 0 "2,9"
nx_variant 623 "the same, the owner away: row 9b writes the skeleton with it" \
  state-case-pending-before-round1.md 's/^ceiling: .*/ceiling: 4 model rounds (light mode) agreed; 4 used/' 5=false,9=false,9b=true 0 "2,9b"
# blackbox: stopped (<round id>) - a black-box round stopped twice by the environment: rows 12 and 15 do not fire again
nx_variant 618 "a black-box stopped twice before the loop is over: row 12 does not fire again, 13b does" \
  state-case-closing-blackbox-stopped-twice.md 's/^last_audit_round: .*/last_audit_round: r02 regression 0H 0M 0L/' \
  5=false,8=false,10=false,11b=false,12=true 0 13b
nx_variant 625 "a black-box stopped twice, then the ceiling reached: row 16 takes it too" \
  state-case-closing-blackbox-stopped-twice.md 's/^ceiling: .*/ceiling: 8 model rounds (full mode) agreed in phase 0; 8 used/' \
  5=false,8=false,10=false,16=true 0 "2,14,16"
nx "$NX" "$NXFIX/state-case-closing-blackbox-stopped.md" --judge 5=false,8=false,10=false,11b=true > "$TMP/o626" 2>&1
if grep -q '^next: row 11b - .*blackbox: stopped (<round id>).*black-box: stopped at <step>' "$TMP/o626"; then
  echo "  ok    row 11b's action says what a black-box round stopped twice sets: blackbox: stopped (<round id>), and the dossier's words"; else
  echo "  FAIL  row 11b's action does not name blackbox: stopped (<round id>) and black-box: stopped at <step>:"; sed "s/^/        | /" "$TMP/o626"; fails=$((fails + 1)); fi
# the kit's example STATE.md is refused (K40: its marker line, BlockCapHook in its title - the K40/K41 cases below), and
# so is a copy without either and with one more space after the name of five of its non-generic flags: the same
# values (K49: the example's values are compared with the spacing collapsed - V41 walked a re-spaced copy to row 13).
# Its rows are no longer read here; a project's starting values (state/README.md) are the must-pass instead.
sed '/Example file. The project is fictional/d; 1s/BlockCapHook/ExampleHook/; s/^\(last_audit_round\|open_findings\|ceiling\|waiting_on_owner\|notes\): /\1:  /' \
  "$HERE/../state/STATE.md" > "$TMP/state-example-flags.md"
nx "$NX" "$TMP/state-example-flags.md" > "$TMP/o443" 2>&1; check "next.sh refuses the example state/STATE.md re-spaced, unmarked and retitled: the same values (K49)" 2 $? "$TMP/o443"
grep -qxF "next: FIRST - fill STATE.md: its values are still the kit's example's ($(LC_ALL=C awk '/^```/ { f = !f; next } f' "$HERE/../state/STATE.md" | grep -m 1 '^bytecode_changed_since:'))" "$TMP/o443" \
  || { echo "  FAIL  and not with the FIRST line of the example's values:"; sed "s/^/        | /" "$TMP/o443"; fails=$((fails + 1)); }
{ echo '# STATE - ExampleHook'; echo; LC_ALL=C awk '/^## Installing/ { s = 1 } s && /^```$/ { if (b) exit; b = 1; print; next } b { print }' "$HERE/../state/README.md"; echo '```'; } > "$TMP/state-start-flags.md"
nx "$NX" "$TMP/state-start-flags.md" > "$TMP/o444" 2>&1; check "next.sh: a project's starting values (state/README.md), no answers: the row" 0 $? "$TMP/o444"
grep -q '^next: row 4 - ' "$TMP/o444" || { echo "  FAIL  and it did not give row 4:"; sed "s/^/        | /" "$TMP/o444"; fails=$((fails + 1)); }
# refusals: rc 2, one line, naming the flag
NP="$NXFIX/state-new-project.md"; nn=450
nx_refused() { # nx_refused <label> <the words the refusal must say> <sed script applied to the new-project fixture> [next.sh args]
  local label="$1" says="$2" sc="$3"; shift 3; nn=$((nn + 1))
  sed "$sc" "$NP" > "$TMP/state-$nn.md"
  nx "$NX" "$TMP/state-$nn.md" "$@" > "$TMP/o$nn" 2>&1; check "next.sh refuses $label" 2 $? "$TMP/o$nn"
  grep -qF -- "$says" "$TMP/o$nn" || { echo "  FAIL  and not for \"$says\": $(head -1 "$TMP/o$nn")"; fails=$((fails + 1)); }
  [ "$(wc -l < "$TMP/o$nn" | tr -d ' ')" = "1" ] || { echo "  FAIL  and the refusal is not one line"; fails=$((fails + 1)); }
}
nx_refused "a mistyped enum (battery: gren)" "battery: 'gren' is not one of" 's/^battery: .*/battery:                   gren/'
nx_refused "a missing flag (no blackbox: line)" "flag 'blackbox' is missing" '/^blackbox:/d'
nx_refused "a flag with no value (phase:)" "flag 'phase' has no value" 's/^phase: .*/phase:/'
nx_refused "a phase outside sketch | 0-8" "phase: '9' is not one of" 's/^phase: .*/phase: 9/'
nx_refused "a bytecode_changed_since with a key missing" "bytecode_changed_since: last_long_fuzz= is missing" 's/last_long_fuzz=yes *//'
nx_refused "a bytecode_changed_since value that is not yes/no" "bytecode_changed_since: last_battery='maybe'" 's/last_battery=yes/last_battery=maybe/'
nx_refused "an open_findings count that is not a number" "open_findings: medium='1-2'" 's/medium=0/medium=1-2/'
nx_refused "a black-box round in last_audit_round" "last_audit_round: 'black-box' is not discovery or regression" 's/^last_audit_round: .*/last_audit_round: bb1 black-box no divergence/'
nx_refused "a ceiling of no known shape" "flag 'ceiling'" 's/^ceiling: .*/ceiling: lots/'
nx_refused "an enum followed by words that are not a comment" "battery: after 'never' only a comment" 's/^battery: .*/battery: never green/'
nx_refused "a line of the block that is not 'name: value'" "is not 'name: value'" 's/^battery: .*/battery never/'
nx_refused "a flag it does not know (a typo in the name)" "unknown flag 'batery'" 's/^battery:/batery:/'
nx_refused "a flag given twice" "flag 'battery' appears twice" 's/^battery: .*/&\nbattery: green/'
nx_refused "an answer to a row the flags decide (--judge 6=false)" "row 6 is decided by the flags" '' --judge 6=false
nx_refused "an answer to a row NEXT.md does not have (--judge 99=true)" "no row 99" '' --judge 99=true
nx_refused "a STATE.md with no flag block" "no flag block" '/^```/d'
nn=490
nx_refused "a missing rehearsal: flag" "flag 'rehearsal' is missing" '/^rehearsal:/d'
nx_refused "a rehearsal: value not on its list" "rehearsal: 'yes' is not" 's/^rehearsal: .*/rehearsal: yes/'
nx_refused "a rehearsal: done with no date" "rehearsal: 'done' is not" 's/^rehearsal: .*/rehearsal: done/'
nx_refused "an answer to row 17, which the rehearsal: flag now decides (--judge 17=true)" "row 17 is decided by the flags" '' --judge 17=true
nn=700
nx_refused "rehearsal: done (date) - the placeholder, not a date" "rehearsal: 'done (date)' is not" 's/^rehearsal: .*/rehearsal: done (date)/'
nx_refused "rehearsal: done (not yet) - words, not a date" "rehearsal: 'done (not yet)' is not" 's/^rehearsal: .*/rehearsal: done (not yet)/'
nx_refused "rehearsal: done (2026-02-30) - no such day" "rehearsal: 'done (2026-02-30)' is not" 's/^rehearsal: .*/rehearsal: done (2026-02-30)/'
nx_refused "rehearsal: done (2026-13-01) - no such month" "rehearsal: 'done (2026-13-01)' is not" 's/^rehearsal: .*/rehearsal: done (2026-13-01)/'
nx_refused "rehearsal: done (2026-03-22) with words after the date" "rehearsal: 'done (2026-03-22) by F-agent' is not" 's/^rehearsal: .*/rehearsal: done (2026-03-22) by F-agent/'
nx_refused "more REASONED high/medium than high+medium open" "open_findings: reasoned_high_or_medium=2 is more than" 's/^open_findings: .*/open_findings: high=0 medium=1 low=0 reasoned_high_or_medium=2/'
nx_refused "blackbox: stopped without the round id" "blackbox: 'stopped' is not" 's/^blackbox: .*/blackbox: stopped/'
nx_refused "blackbox: stopped (b1) with words after it" "blackbox: 'stopped (b1) twice' is not" 's/^blackbox: .*/blackbox: stopped (b1) twice/'
nx_refused "a line that is not 'name: value' in a CRLF STATE.md" "is not 'name: value': 'battery never'" 's/^battery: .*/battery never/; s/$/\r/'
if grep -q "$(printf '\r')" "$TMP/o$nn"; then echo "  FAIL  and the refusal carries the file's CR"; fails=$((fails + 1)); fi
# the ceiling the OPERATOR set, the owner absent in full mode (COST.md 1): one form, read strictly - never as the owner's
nn=750
nx_refused "an operator's ceiling without (owner absent)" "is not the operator's form" 's/^ceiling: .*/ceiling: 6 model rounds, set by the operator; 6 used/'
nx_refused "an operator's ceiling without its '; M used'" "is not the operator's form" 's/^ceiling: .*/ceiling: 6 model rounds, set by the operator (owner absent)/'
nx_refused "an operator's ceiling with words after 'used'" "is not the operator's form" 's/^ceiling: .*/ceiling: 6 model rounds, set by the operator (owner absent); 2 used by the agent/'
nx_refused "an operator's ceiling in words, not a number" "is not the operator's form" 's/^ceiling: .*/ceiling: six model rounds, set by the operator (owner absent); 2 used/'
nx "$NX" "$NXFIX/state-case-ceiling-operator.md" --judge 5=false,8=false,9=false,9b=true > "$TMP/o755" 2>&1
if grep -qx '  because: ceiling=reached (6 of 6 used, set by the operator (owner absent))' "$TMP/o755"; then
  echo "  ok    row 2 in force on the operator's ceiling says whose ceiling it was"; else
  echo "  FAIL  row 2's reason does not say the ceiling was the operator's:"; sed "s/^/        | /" "$TMP/o755"; fails=$((fails + 1)); fi
# ... and "operator" in ANOTHER CASE is refused too: it passed as the owner's ceiling, with a `because` that named no
# operator (a verifier, V24: `set by the Operator`, `set by the OPERATOR`)
nn=755
nx_refused "an operator's ceiling with 'Operator' capitalised (never read as the owner's)" "is not the operator's form" 's/^ceiling: .*/ceiling: 6 model rounds, set by the Operator (owner absent); 6 used/'
nx_refused "an operator's ceiling with 'OPERATOR' (never read as the owner's)" "is not the operator's form" 's/^ceiling: .*/ceiling: 6 model rounds, set by the OPERATOR (owner absent); 6 used/'
# row 1 and row 9b read the flags in one form each (K26, K26b): a high to tell is an item `high <id>[, <id>...] - to tell`,
# ids between commas or spaces, no placeholder, never more ids than highs open; a skeleton says how many open findings it
# names - anything else is refused, never counted and never ignored
nn=650
nx_refused "a high to tell naming a placeholder (high none - to tell, V26 T14)" "'none' is a placeholder, not a finding id" 's/^waiting_on_owner: .*/waiting_on_owner: high none - to tell/'
nx_refused "a high to tell naming a placeholder (TBD)" "'TBD' is a placeholder, not a finding id" 's/^open_findings: .*/open_findings: high=1 (F-1) medium=0 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high TBD - to tell/'
nx_refused "a high to tell naming a placeholder (nobody)" "'nobody' is a placeholder, not a finding id" 's/^open_findings: .*/open_findings: high=1 (F-1) medium=0 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high nobody - to tell/'
nx_refused "a high to tell naming a placeholder (n/a)" "'n/a' is a placeholder, not a finding id" 's/^open_findings: .*/open_findings: high=1 (F-1) medium=0 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high n\/a - to tell/'
nx_refused "a high to tell naming a placeholder (?)" "'?' is a placeholder, not a finding id" 's/^open_findings: .*/open_findings: high=1 (F-1) medium=0 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high ? - to tell/'
nx_refused "a high to tell with no id (high - to tell)" "names no finding id" 's/^open_findings: .*/open_findings: high=1 (F-1) medium=0 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high - to tell/'
nx_refused "a high to tell with a word between the ids (high F-1 and F-2 - to tell, 3 highs open)" "'and' is a word, not a finding id" 's/^open_findings: .*/open_findings: high=3 (F-1, F-2, F-3) medium=0 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high F-1 and F-2 - to tell/'
nx_refused "more highs recorded to tell than are open (a stale entry)" "a recorded high is no longer open: remove it" 's/^open_findings: .*/open_findings: high=1 (F-1) medium=0 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high F-1, F-2 - to tell/'
nx_refused "a high to tell recorded when no high is open" "a recorded high is no longer open: remove it" 's/^waiting_on_owner: .*/waiting_on_owner: high F-1 - to tell/'
nx_refused "a high to tell in another shape (F-1 high - to tell)" "is not 'high <id>[, <id>...] - to tell'" 's/^waiting_on_owner: .*/waiting_on_owner: F-1 high - to tell/'
nx_refused "a dossier skeleton that does not say how many open findings it names" "is not skeleton (<K> open" 's/^dossier: .*/dossier: skeleton/'
nx_refused "a dossier skeleton with K in words" "is not skeleton (<K> open" 's/^dossier: .*/dossier: skeleton (two open, 1 judge not done)/'
# K28: open_findings names the open highs, `high=N (<ids>)` - the parentheses exactly when N > 0, one id per high, each
# once; and a recorded high to tell must be one of them. Anything else is refused, never counted and never ignored
nn=860
OFH='s/^open_findings: .*/open_findings: '
nx_refused "a high open with no ids (high=1 medium=0 ...)" "open_findings: high=1 names no ids" "${OFH}high=1 medium=0 low=0 reasoned_high_or_medium=0/"
nx_refused "a high open with its id only in the comment after" "open_findings: high=1 names no ids" "${OFH}high=1 medium=0 low=0 reasoned_high_or_medium=0 (F-1)/"
nx_refused "ids when no high is open (high=0 (F-1))" "open_findings: high=0 with ids" "${OFH}high=0 (F-1) medium=0 low=0 reasoned_high_or_medium=0/"
nx_refused "an empty id list when no high is open (high=0 ())" "open_findings: high=0 with ids" "${OFH}high=0 () medium=0 low=0 reasoned_high_or_medium=0/"
nx_refused "fewer ids than highs (high=2 (F-1))" "open_findings: high=2 names 1 id" "${OFH}high=2 (F-1) medium=0 low=0 reasoned_high_or_medium=0/"
nx_refused "more ids than highs (high=1 (F-1, F-2))" "open_findings: high=1 names 2 ids" "${OFH}high=1 (F-1, F-2) medium=0 low=0 reasoned_high_or_medium=0/"
nx_refused "an empty id list for a high (high=1 ())" "open_findings: high=1 names 0 ids" "${OFH}high=1 () medium=0 low=0 reasoned_high_or_medium=0/"
nx_refused "the same id twice among the open highs (F-1, f-1)" "is named twice" "${OFH}high=2 (F-1, f-1) medium=0 low=0 reasoned_high_or_medium=0/"
nx_refused "a placeholder for an open high's id (high=1 (TBD))" "'TBD' is a placeholder, not a finding id" "${OFH}high=1 (TBD) medium=0 low=0 reasoned_high_or_medium=0/"
nx_refused "a word between the open highs' ids (F-1 and F-2)" "'and' is a word, not a finding id" "${OFH}high=3 (F-1 and F-2) medium=0 low=0 reasoned_high_or_medium=0/"
nx_refused "an open high's id that is not one id (F-1/F-2)" "is not one finding id" "${OFH}high=1 (F-1\/F-2) medium=0 low=0 reasoned_high_or_medium=0/"
nx_refused "a high recorded to tell that is not an open high (F-2 recorded, F-1 open)" "a recorded high is no longer open: remove it" \
  "${OFH}high=1 (F-1) medium=0 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high F-2 - to tell/"
nx_refused "a medium's id recorded as a high to tell (V26b a6)" "a recorded high is no longer open: remove it" \
  "${OFH}high=1 (F-1) medium=1 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high F-1, M-1 - to tell/"
nx_refused "a complete dossier with a finding open" "a dossier with an open finding is a skeleton" \
  "${OFH}high=0 medium=1 low=0 reasoned_high_or_medium=0/; s/^dossier: .*/dossier: complete (0 judges not done)/"
# K29: an id is an id - at least one letter and one digit - on either side, alone (V28's non-ids on both sides are the
# state-v28-*.md fixtures above); and the ids the real walks wrote pass
nn=880
nx_refused "a word that is not an id among the open highs (high=1 (all))" "'all' is not an id: an id has at least one letter and one digit" "${OFH}high=1 (all) medium=0 low=0 reasoned_high_or_medium=0/"
nx_refused "a number that is not an id among the open highs (high=2 (F-1, 2))" "'2' is not an id" "${OFH}high=2 (F-1, 2) medium=0 low=0 reasoned_high_or_medium=0/"
nx_refused "a word that is not an id recorded to tell (high TBA - to tell)" "'TBA' is not an id" \
  "${OFH}high=1 (F-1) medium=0 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high TBA - to tell/"
nx_refused "an id with a full stop and no digit (None.)" "'None.' is not an id" "${OFH}high=1 (None.) medium=0 low=0 reasoned_high_or_medium=0/"
sed "${OFH}high=4 (F-1, P-02, r01-A1, R01-3) medium=0 low=0 reasoned_high_or_medium=0/; s/^waiting_on_owner: .*/waiting_on_owner: high F-1, P-02 - to tell · high r01-A1 R01-3 - to tell/" "$NP" > "$TMP/state-885.md"
nx "$NX" "$TMP/state-885.md" > "$TMP/o885" 2>&1; check "next.sh: ids of every shape the walks wrote (F-1, P-02, r01-A1, R01-3) are ids, and quiet row 1 when all are recorded" 0 $? "$TMP/o885"
grep -q '^because: .*row 1 is quiet: the 4 highs open are recorded to tell in waiting_on_owner (F-1, P-02, r01-A1, R01-3)$' "$TMP/o885" \
  || { echo "  FAIL  and the because: line does not name the four:"; sed "s/^/        | /" "$TMP/o885"; fails=$((fails + 1)); }
# K29: row 9b by the flags after the skeleton - a skeleton naming the number open decides it false, never asked; with
# `dossier: none` or a stale K the question is the owner's presence, and it says what the dossier flag shows
nx "$NX" "$NXFIX/state-case-skeleton-written-owner-away.md" > "$TMP/o886" 2>&1
if grep -q '^needs judgement: ' "$TMP/o886" && ! grep -q '^needs judgement: row 9b ' "$TMP/o886"; then
  echo "  ok    a skeleton naming the number open: row 9b is not asked (the flags decide it)"; else
  echo "  FAIL  a skeleton naming the number open, and row 9b is asked (or nothing is):"; sed "s/^/        | /" "$TMP/o886"; fails=$((fails + 1)); fi
nx "$NX" "$NXFIX/state-case-skeleton-stale.md" --judge 5=false,8=false,9=false > "$TMP/o887" 2>&1
if grep -q '^needs judgement: row 9b - .*the dossier does not name them yet (the skeleton names 2, open_findings has 3 open): is the owner unavailable to triage them now' "$TMP/o887"; then
  echo "  ok    a stale skeleton: row 9b asks for the owner's presence, and says what the skeleton names"; else
  echo "  FAIL  a stale skeleton: row 9b's question does not say what the skeleton names and ask for the owner's presence:"; sed "s/^/        | /" "$TMP/o887"; fails=$((fails + 1)); fi
sed 's/^dossier: .*/dossier: none/' "$NXFIX/state-case-skeleton-written-owner-away.md" > "$TMP/state-888.md"
nx "$NX" "$TMP/state-888.md" --judge 5=false,8=false,9=false > "$TMP/o888" 2>&1
grep -q '^needs judgement: row 9b - .*the dossier does not name them yet (dossier: none): is the owner unavailable' "$TMP/o888" \
  || { echo "  FAIL  dossier: none, and row 9b's question does not say so and ask for the owner's presence:"; sed "s/^/        | /" "$TMP/o888"; fails=$((fails + 1)); }
# ... and a told: note is a note like any other: not read, not refused (row 1 is asked while a high is open, owner present)
sed 's/^open_findings: .*/open_findings: high=1 (F-1) medium=0 low=0 reasoned_high_or_medium=0/; s/^notes:.*/notes: told: F-1 and F-2 (by mail)/' "$NP" > "$TMP/state-677.md"
nx "$NX" "$TMP/state-677.md" > "$TMP/o677" 2>&1; check "next.sh: a told: note in any shape is not refused (it is not read)" 3 $? "$TMP/o677"
[ "$(sed -n 1p "$TMP/o677" | cut -c1-26)" = "needs judgement: row 1 - d" ] || { echo "  FAIL  and row 1 is not the first question:"; sed "s/^/        | /" "$TMP/o677"; fails=$((fails + 1)); }
# drift guard: next.sh's rows and NEXT.md's table must name the same rows, in the same order, and each row's condition
# must be the text next.sh's entry was written from (a hash of the cell, whitespace normalised)
nx "$NX" --check-table > "$TMP/o470" 2>&1; check "next.sh --check-table: its rows and doctrine/NEXT.md's table agree" 0 $? "$TMP/o470"
sed 's/^| 18b |.*/&\n| 19 | a row added to the table | do something new | a reason |/' "$NXT" > "$TMP/next-added.md"
nx "$NX" --check-table "$TMP/next-added.md" > "$TMP/o471" 2>&1; check "next.sh --check-table: a row added to NEXT.md with no entry (drift)" 2 $? "$TMP/o471"
grep -qF "row 19" "$TMP/o471" || { echo "  FAIL  and the refusal does not name row 19: $(head -1 "$TMP/o471")"; fails=$((fails + 1)); }
grep -v '^| 7b |' "$NXT" > "$TMP/next-removed.md"
nx "$NX" "$NP" --table "$TMP/next-removed.md" > "$TMP/o472" 2>&1; check "next.sh on a STATE.md, with a row removed from NEXT.md (drift)" 2 $? "$TMP/o472"
grep -qF "row 7b" "$TMP/o472" || { echo "  FAIL  and the refusal does not name row 7b: $(head -1 "$TMP/o472")"; fails=$((fails + 1)); }
nx_drift() { # nx_drift <n> <label> <sed or awk program -> the edited NEXT.md> <want rc> <words the output must say>
  local n="$1" label="$2" prog="$3" wrc="$4" says="$5"
  case "$prog" in awk:*) awk "${prog#awk:}" "$NXT" > "$TMP/next-$n.md" ;; *) sed "$prog" "$NXT" > "$TMP/next-$n.md" ;; esac
  cmp -s "$TMP/next-$n.md" "$NXT" && { echo "  FAIL  $label: the edit changed nothing"; fails=$((fails + 1)); return; }
  nx "$NX" --check-table "$TMP/next-$n.md" > "$TMP/o$n" 2>&1; check "next.sh --check-table: $label" "$wrc" $? "$TMP/o$n"
  grep -qF -- "$says" "$TMP/o$n" || { echo "  FAIL  and it does not say \"$says\": $(head -1 "$TMP/o$n")"; fails=$((fails + 1)); }
}
nx_drift 711 "a row 12a inserted after row 12 (an id of another form)" 's/^| 12 |.*/&\n| 12a | a row inserted | x | y |/' 2 "row 12a"
nx_drift 712 "row 11b written 11B" 's/^| 11b |/| 11B |/' 2 "row 11B"
nx_drift 713 "rows 17 and 18 swapped" 'awk:/^\| 17 \|/ { h = $0; next } { print } /^\| 18 \|/ { print h }' 2 "another order"
nx_drift 714 "row 16's condition cell changed, its id kept" 's/^| 16 | the loop is over; /| 16 | the loop is over (and nothing else); /' 2 "row 16"
nx_drift 715 "row 16's condition cell with its spaces changed only" 's/^\(| 16 | the loop is over;\) /\1    /; s/^| 16 | /|  16  |   /' 0 "agree"
nx_drift 718 "NEXT.md with CRLF line endings" 's/$/\r/' 0 "agree"
# inside the table every non-blank line is a row: a "|" at column 0 and four cells - an indented row, a row without its
# leading "|" (GFM shows both in the table) or a line of prose is refused, naming the line
nx_drift 719 "a row 12c indented two spaces inside the table" 's/^| 12 |.*/&\n  | 12c | a row inserted | x | y |/' 2 "  | 12c |"
nx_drift 720 "a row 12c without its leading |" 's/^| 12 |.*/&\n12c | a row inserted | x | y |/' 2 "12c | a row inserted"
nx_drift 721 "a line of prose inside the table" 's/^| 12 |.*/&\nsee also row 12c, which is not a row/' 2 "which is not a row"
# ... and the table ends at its first blank line: prose under the same heading after it is not a row, and is not refused
nx_drift 722 "a paragraph after the table's blank line, under the same heading" \
  's/^| 18b |.*/&\n\nA paragraph after the table, still under its heading./' 0 "agree"
# the hash --check-table prints is the one to paste: in a copy of next.sh, pasted over the old one, the edited table agrees
h_new="$(sed -nE 's/^row 16: .* new hash ([0-9a-f]{8}) over ([0-9a-f]{8}).*/\1/p' "$TMP/o714")"
h_old="$(sed -nE 's/^row 16: .* new hash ([0-9a-f]{8}) over ([0-9a-f]{8}).*/\2/p' "$TMP/o714")"
if [ -n "$h_new" ] && [ -n "$h_old" ] && grep -q "| $h_old |" "$NX"; then
  sed "s/| $h_old |/| $h_new |/" "$NX" > "$TMP/next-pasted.sh"
  bash "$TMP/next-pasted.sh" --check-table "$TMP/next-714.md" > "$TMP/o716" 2>&1
  check "next.sh --check-table: the hash it printed for row 16, pasted into its entry, makes the edited table agree" 0 $? "$TMP/o716"
else echo "  FAIL  --check-table did not print row 16's new hash over the one in next.sh ('$h_new' over '$h_old')"; fails=$((fails + 1)); fi
nx "$NX" "$NP" --table "$TMP/next-714.md" > "$TMP/o717" 2>&1; check "next.sh on a STATE.md, with row 16's condition changed in NEXT.md (drift)" 2 $? "$TMP/o717"
grep -qF "row 16" "$TMP/o717" || { echo "  FAIL  and the refusal does not name row 16: $(head -1 "$TMP/o717")"; fails=$((fails + 1)); }
# K31, decision 1 (K31b: bound to the machine and to forge): before any row, next.sh checks that the kit's selftest
# PASSED on this machine, with this forge, for THESE scripts - the marker <kit>/.gauntlet/selftest-passed. On a copy of
# the kit (its scripts, its NEXT.md), run as a user runs it, with no NEXT_SELFTEST: no marker, a marker of other
# scripts, of another machine, of another forge, one with a field missing, a script edited or added after it was
# written - each is the one line FIRST (rc 0), saying which, and nothing else; the right marker, and the row.
# --check-table never looks. forge here is a stub on the PATH (its version is a file), so that another forge, and none,
# are cases and not this machine's; "another machine" is the marker written with another machine id read
# (lib/kit-proof.sh's _kit_machine_id_file, reassigned in a subshell - it is never read from the environment).
KM="$TMP/kitm"; mkdir -p "$KM/scripts/lib" "$KM/doctrine"
cp "$HERE"/*.sh "$HERE"/*.py "$KM/scripts/"; cp "$HERE"/lib/*.sh "$HERE"/lib/*.py "$KM/scripts/lib/"; cp "$NXT" "$KM/doctrine/"
KMD="$(cd "$KM" && pwd)"; KMN="$KM/scripts/next.sh"; KMM="$(kit_marker "$KM")"
KMF="$TMP/kmforge"; mkdir -p "$KMF"; printf 'forge Version: 9.9.9-selftest-stub\n' > "$KMF/version"
printf '#!/usr/bin/env bash\nv="$(cat "$(dirname "$0")/version" 2> /dev/null)"; [ -n "$v" ] || exit 127; echo "$v"; echo "Commit SHA: 0"\n' > "$KMF/forge"
chmod +x "$KMF/forge"
# v0.4.1 (K50, D3): the FIRST line says what the selftest costs - SELFTEST_MINUTES in next.sh, measured - and how to run it
# (a walker's tool timeout of 300 s cut it short at ~320 s, twice)
KM_MIN="$(sed -n 's/^SELFTEST_MINUTES=\([0-9][0-9]*\)$/\1/p' "$NX")"
KM_FIRST="next: FIRST - prove the kit on this machine: $KMD/scripts/selftest.sh - it takes about ${KM_MIN:-<SELFTEST_MINUTES>} minutes; give it a tool timeout above that or run it in the background (then run next.sh again)"
km_run() { env -u NEXT_SELFTEST PATH="$KMF:$PATH" "$KMN" "$@"; }                 # the kit copy's next.sh, as a user runs it
km_mark() { (PATH="$KMF:$PATH"; selftest_marker_write "$KM" "${1:-$(kit_scripts_sha256 "$KM")}"); }   # its own selftest's marker
km_first() { # km_first <n> <label> <why> [next.sh args]: FIRST alone, saying why
  local n="$1" label="$2" why="$3"; shift 3
  km_run "$@" > "$TMP/o$n" 2>&1; check "next.sh, the kit not proven: $label" 0 $? "$TMP/o$n"
  if [ "$(cat "$TMP/o$n")" = "$KM_FIRST - $why" ]; then echo "  ok    one line, FIRST - $why"; else
    echo "  FAIL  not the one line '$KM_FIRST - $why':"; sed "s/^/        | /" "$TMP/o$n"; fails=$((fails + 1)); fi
}
km_row() { # km_row <n> <label>: the row, alone
  local n="$1" label="$2"
  km_run "$NXFIX/state-new-project.md" > "$TMP/o$n" 2>&1; check "next.sh, the kit proven: $label" 0 $? "$TMP/o$n"
  grep -q '^next: row 4 - ' "$TMP/o$n" && ! grep -qE 'FIRST|NEXT_SELFTEST' "$TMP/o$n" \
    || { echo "  FAIL  and it did not name row 4, alone:"; sed "s/^/        | /" "$TMP/o$n"; fails=$((fails + 1)); }
}
km_first 901 "no marker" "the selftest has not passed here" "$NXFIX/state-new-project.md"
km_first 902 "no marker, and an answer it would refuse (--judge 6=false): the kit first, nothing else is read" "the selftest has not passed here" "$NXFIX/state-new-project.md" --judge 6=false
km_mark "$(printf '%064d' 0)"
km_first 903 "a marker recording other scripts' hash" "the scripts changed since its selftest passed" "$NXFIX/state-new-project.md"
km_mark; grep -v '^scripts_sha256: ' "$KMM" > "$TMP/km-m"; mv "$TMP/km-m" "$KMM"
km_first 904 "a marker with no scripts_sha256 line" "its marker does not record the scripts" "$NXFIX/state-new-project.md"
km_mark
km_row 905 "the selftest's own marker for these scripts, this machine, this forge: the row"
for f in scripts_sha256 machine_sha256 date forge; do grep -q "^$f: ." "$KMM" || { echo "  FAIL  the marker has no $f line:"; sed "s/^/        | /" "$KMM"; fails=$((fails + 1)); }; done
cp "$KM/scripts/lib/parse.sh" "$TMP/km-parse.sh"; echo "# one comment more" >> "$KM/scripts/lib/parse.sh"
km_first 906 "a script under scripts/lib/ edited after the marker was written" "the scripts changed since its selftest passed" "$NXFIX/state-new-project.md"
cp "$TMP/km-parse.sh" "$KM/scripts/lib/parse.sh"; printf '#!/usr/bin/env bash\n' > "$KM/scripts/new.sh"
km_first 907 "a script added to scripts/ after the marker was written" "the scripts changed since its selftest passed" "$NXFIX/state-new-project.md"
rm -f "$KM/scripts/new.sh"; mv "$KM/scripts/dossier-pdf.py" "$KM/scripts/dossier.py"
km_first 908 "a script renamed after the marker was written" "the scripts changed since its selftest passed" "$NXFIX/state-new-project.md"
mv "$KM/scripts/dossier.py" "$KM/scripts/dossier-pdf.py"
km_row 909 "the same kit put back as it was: the marker holds again"
# K31b: the machine. A marker written on another machine (another machine id read when it was written) and copied here
# with the kit - the V31 case: a kit copied with its .gauntlet/, a project copied with the kit in lib/hook-gauntlet
printf '0123456789abcdef0123456789abcdef\n' > "$TMP/km-other-id"
(_kit_machine_id_file="$TMP/km-other-id"; km_mark)
km_first 913 "a marker written on another machine (another machine id), copied here with the kit" "the machine changed since its selftest passed" "$NXFIX/state-new-project.md"
if grep -q "0123456789abcdef0123456789abcdef" "$KMM"; then echo "  FAIL  the marker holds the other machine's id as it is:"; sed "s/^/        | /" "$KMM"; fails=$((fails + 1)); else
  echo "  ok    and the marker holds that machine's id hashed, not as it is"; fi
km_mark; rm -rf "$TMP/kitm-copy"; cp -a "$KM" "$TMP/kitm-copy"
env -u NEXT_SELFTEST PATH="$KMF:$PATH" "$TMP/kitm-copy/scripts/next.sh" "$NXFIX/state-new-project.md" > "$TMP/o914" 2>&1
check "next.sh, the kit copied with its .gauntlet/ to another directory of THIS machine, the same forge: the row (the marker binds the machine and forge, not the path)" 0 $? "$TMP/o914"
grep -q '^next: row 4 - ' "$TMP/o914" || { echo "  FAIL  and it did not name row 4:"; sed "s/^/        | /" "$TMP/o914"; fails=$((fails + 1)); }
rm -rf "$TMP/kitm-copy"
# the machine's identity: /etc/machine-id when readable and not empty, else the hostname - and only ever hashed
km_h_id="$(_kit_machine_id_file="$TMP/km-other-id"; kit_machine_sha256)"; km_s_id="$(_kit_machine_id_file="$TMP/km-other-id"; kit_machine_source)"
: > "$TMP/km-empty-id"
km_h_empty="$(_kit_machine_id_file="$TMP/km-empty-id"; kit_machine_sha256)"; km_s_empty="$(_kit_machine_id_file="$TMP/km-empty-id"; kit_machine_source)"
km_h_none="$(_kit_machine_id_file="$TMP/km-no-such-file"; kit_machine_sha256)"; km_s_none="$(_kit_machine_id_file="$TMP/km-no-such-file"; kit_machine_source)"
km_host="$( (hostname 2> /dev/null || uname -n) | tr -d '[:space:]')"
if [ "$km_s_id" = "$TMP/km-other-id" ] && [ "$km_h_id" = "$(printf 'hook-gauntlet selftest marker, %s: 0123456789abcdef0123456789abcdef' "$TMP/km-other-id" | _kit_sha256)" ] \
  && [ "$km_s_none" = "the hostname" ] && [ "$km_s_empty" = "the hostname" ] && [ -n "$km_host" ] \
  && [ "$km_h_none" = "$(printf 'hook-gauntlet selftest marker, the hostname: %s' "$km_host" | _kit_sha256)" ] && [ "$km_h_empty" = "$km_h_none" ] \
  && [ "$km_h_id" != "$(printf '0123456789abcdef0123456789abcdef' | _kit_sha256)" ] && [ "$km_h_id" != "$km_h_none" ]; then
  echo "  ok    the machine: a readable machine-id file is read (hashed with where it came from); none, or an empty one, and the hostname (hashed)"; else
  echo "  FAIL  the machine's identity: file '$km_s_id' $km_h_id; empty '$km_s_empty' $km_h_empty; none '$km_s_none' $km_h_none (hostname '$km_host')"; fails=$((fails + 1)); fi
# K31b: forge. The marker records the first line of `forge --version`; next.sh compares it with the forge on its PATH
km_mark; printf 'forge Version: 9.9.8-another-forge\n' > "$KMF/version"
km_first 915 "another forge on the PATH than the one the selftest passed with" "forge changed since its selftest passed" "$NXFIX/state-new-project.md"
: > "$KMF/version"
km_first 916 "no forge answering on the PATH" "forge changed since its selftest passed" "$NXFIX/state-new-project.md"
printf 'forge Version: 9.9.9-selftest-stub\n' > "$KMF/version"
km_row 917 "the forge the selftest passed with, back on the PATH"
# every field required: a marker missing one - hand-written, or from an older kit - is FIRST, saying which
cp "$KMM" "$TMP/km-good"
grep -v '^machine_sha256: ' "$TMP/km-good" > "$KMM"
km_first 918 "a marker with no machine_sha256 line" "its marker does not record the machine" "$NXFIX/state-new-project.md"
grep -v '^forge: ' "$TMP/km-good" > "$KMM"
km_first 919 "a marker with no forge line" "its marker does not record forge" "$NXFIX/state-new-project.md"
sed 's/^forge: .*/forge: /' "$TMP/km-good" > "$KMM"
km_first 91a "a marker whose forge line is empty" "its marker does not record forge" "$NXFIX/state-new-project.md"
grep '^scripts_sha256: ' "$TMP/km-good" > "$KMM"
km_first 91b "a hand-written marker of one line, the right scripts_sha256 (V31)" "its marker does not record the machine and forge" "$NXFIX/state-new-project.md"
(_kit_machine_id_file="$TMP/km-other-id"; km_mark "$(printf '%064d' 0)"); printf 'forge Version: 9.9.8-another-forge\n' > "$KMF/version"
km_first 91c "a marker of other scripts, another machine and another forge" "the scripts, the machine and forge changed since its selftest passed" "$NXFIX/state-new-project.md"
printf 'forge Version: 9.9.9-selftest-stub\n' > "$KMF/version"
rm -f "$KMM"
env -u NEXT_SELFTEST "$KMN" --check-table > "$TMP/o910" 2>&1; check "next.sh --check-table, the kit not proven: the drift guard runs all the same" 0 $? "$TMP/o910"
grep -q "^next: next.sh's rows and .* agree" "$TMP/o910" || { echo "  FAIL  and not the drift guard's answer:"; sed "s/^/        | /" "$TMP/o910"; fails=$((fails + 1)); }
NEXT_SELFTEST=1 "$KMN" "$NXFIX/state-new-project.md" > "$TMP/o911" 2> "$TMP/o911e"; check "next.sh with NEXT_SELFTEST=1, no marker: the row" 0 $? "$TMP/o911"
if [ "$(cat "$TMP/o911e")" = "$NX_NOTICE" ] && grep -q '^next: row 4 - ' "$TMP/o911"; then
  echo "  ok    and it says so, on one line of stderr: $NX_NOTICE"; else
  echo "  FAIL  NEXT_SELFTEST=1 not said on one line:"; sed "s/^/        | /" "$TMP/o911e"; fails=$((fails + 1)); fi
NEXT_SELFTEST=yes "$KMN" "$NXFIX/state-new-project.md" > "$TMP/o912" 2>&1; check "next.sh refuses NEXT_SELFTEST set to anything but 1" 2 $? "$TMP/o912"
grep -qF "NEXT_SELFTEST='yes' is not 1" "$TMP/o912" || { echo "  FAIL  and not for that: $(head -1 "$TMP/o912")"; fails=$((fails + 1)); }
# K31, decision 2: a test in pending/ that STATE.md does not name is refused, and a pending: note with no file. The
# project is the STATE.md's directory, or its parent for .gauntlet/STATE.md. The fixture is a real walk's end: four
# pending: notes, and here their four files. These cases are about the notes: the red records (K41) are not checked in
# them - PENDING_RED=0, said on stderr every run - and are the K40/K41 cases' own
export PENDING_RED=0
# (K50: each project here gets the green build record its phase 4 claims - D2, NXFIX above)
nx_build() { # (K60: with the test record, the census and the invariant suite phase 3+ and 4+ claim)
  mkdir -p "$1/.gauntlet/reports" "$1/test" && cp "$FIX/build-real-compiled.txt" "$1/.gauntlet/reports/01-build.txt" \
    && cp "$FIX/summary-real-many-suites.txt" "$1/.gauntlet/reports/02-test.txt" && printf 'census\n' > "$1/.gauntlet/reports/06-census.txt" \
    && printf 'contract Inv { function invariant_fixture() public {} }\n' > "$1/test/Inv.t.sol" \
    && cp "$NXFIX/.gauntlet/THREATS-independent.md" "$NXFIX/.gauntlet/THREATS.md" "$1/.gauntlet/" \
    && cp "$NXFIX/.gauntlet/reports/06-threats.txt" "$1/.gauntlet/reports/"   # v0.5: the threat diff phase 4 claims, and its report
}
PJ="$TMP/pendp"; mkdir -p "$PJ/.gauntlet" "$PJ/pending/lib"; nx_build "$PJ"
cp "$NXFIX/state-case-round-end-owner-absent.md" "$PJ/.gauntlet/STATE.md"
for i in 1 2 3 4; do printf '// pending F-%s\n' "$i" > "$PJ/pending/F-$i.t.sol"; done
printf 'not a test\n' > "$PJ/pending/README.md"; printf 'not Solidity\n' > "$PJ/pending/lib/notes.txt"
PJJ="5=false,8=false,9=false,10=false"
nx "$NX" "$PJ/.gauntlet/STATE.md" --judge "$PJJ" > "$TMP/o920" 2>&1; check "next.sh: pending/ holds the four tests the notes name (and files that are not .sol): the pause" 0 $? "$TMP/o920"
[ "$(nx_rows "$TMP/o920")" = "2,STOP" ] || { echo "  FAIL  and it named rows '$(nx_rows "$TMP/o920")', not 2,STOP"; sed "s/^/        | /" "$TMP/o920"; fails=$((fails + 1)); }
printf '// a fifth\n' > "$PJ/pending/F-5.t.sol"
nx "$NX" "$PJ/.gauntlet/STATE.md" --judge "$PJJ" > "$TMP/o921" 2>&1; check "next.sh refuses a test in pending/ that no pending: note names" 2 $? "$TMP/o921"
if grep -qF "$PJ/pending/F-5.t.sol is a test in pending/, and STATE.md's notes have no 'pending: F-5 ...' for it: write it in STATE.md notes and in open_findings before anything else - NEXT.md row 6b." "$TMP/o921" \
  && [ "$(grep -vc '^next: PENDING_RED=0 - ' "$TMP/o921")" = 1 ]; then echo "  ok    one line, naming the file, and what to do (besides PENDING_RED=0's own)"; else
  echo "  FAIL  not the refusal naming pending/F-5.t.sol:"; sed "s/^/        | /" "$TMP/o921"; fails=$((fails + 1)); fi
nx "$NX" "$PJ/.gauntlet/STATE.md" > "$TMP/o922" 2>&1; check "next.sh: the same, no answers: refused before any row is asked" 2 $? "$TMP/o922"
grep -q '^needs judgement' "$TMP/o922" && { echo "  FAIL  and rows were asked:"; sed "s/^/        | /" "$TMP/o922"; fails=$((fails + 1)); }
rm -f "$PJ/pending/F-5.t.sol" "$PJ/pending/F-3.t.sol"
nx "$NX" "$PJ/.gauntlet/STATE.md" --judge "$PJJ" > "$TMP/o923" 2>&1; check "next.sh refuses a pending: note whose file is not in pending/" 2 $? "$TMP/o923"
grep -qF "STATE.md's notes name 'pending: F-3', and $PJ/pending/F-3.t.sol does not exist" "$TMP/o923" \
  || { echo "  FAIL  not the refusal naming pending/F-3.t.sol:"; sed "s/^/        | /" "$TMP/o923"; fails=$((fails + 1)); }
printf '// pending F-3\n' > "$PJ/pending/f-3.t.sol"
nx "$NX" "$PJ/.gauntlet/STATE.md" --judge "$PJJ" > "$TMP/o924" 2>&1; check "next.sh: a file f-3.t.sol for the note pending: F-3 (ids compared case aside): the pause" 0 $? "$TMP/o924"
sed 's/^\(notes: .*\)$/\1 · pending: F-6 - a promise, owner undecided/' "$PJ/.gauntlet/STATE.md" > "$TMP/pend-state.md"; mv "$TMP/pend-state.md" "$PJ/.gauntlet/STATE.md"
printf '// pending F-6\n' > "$PJ/pending/F-6.t.sol"
nx "$NX" "$PJ/.gauntlet/STATE.md" --judge "$PJJ" > "$TMP/o925" 2>&1; check "next.sh: a pending: note after a middle dot names its file like any other: the pause" 0 $? "$TMP/o925"
PR="$TMP/pendroot"; mkdir -p "$PR/pending"; nx_build "$PR"; sed 's/^location: .*/location:                  root/' "$NXFIX/state-case-round-end-owner-absent.md" > "$PR/STATE.md"
printf '// X-1\n' > "$PR/pending/X-1.t.sol"
nx "$NX" "$PR/STATE.md" --judge "$PJJ" > "$TMP/o926" 2>&1; check "next.sh, STATE.md at the project's root: pending/ beside it is read (X-1.t.sol, no note)" 2 $? "$TMP/o926"
grep -qF "$PR/pending/X-1.t.sol is a test in pending/" "$TMP/o926" || { echo "  FAIL  not the refusal naming pending/X-1.t.sol:"; sed "s/^/        | /" "$TMP/o926"; fails=$((fails + 1)); }
mkdir -p "$TMP/pendnone/.gauntlet"; nx_build "$TMP/pendnone"; cp "$NXFIX/state-case-round-end-owner-absent.md" "$TMP/pendnone/.gauntlet/STATE.md"
nx "$NX" "$TMP/pendnone/.gauntlet/STATE.md" --judge "$PJJ" > "$TMP/o927" 2>&1; check "next.sh: pending: notes and no pending/ at all: nothing is checked, the pause" 0 $? "$TMP/o927"
# K31b: every file row 6b's profile runs is seen. forge 1.8.1 (`[profile.pending] test = "pending"`, measured) compiles
# and runs every .sol below pending/ - in a subdirectory, without .t, hidden, in a hidden directory, a helper too: each
# one is refused without its note, by its path, the id its name without .t.sol or .sol (and a leading dot)
pj_reset() { rm -rf "$TMP/pendq"; mkdir -p "$TMP/pendq/.gauntlet" "$TMP/pendq/pending"; nx_build "$TMP/pendq"; cp "$NXFIX/state-case-round-end-owner-absent.md" "$TMP/pendq/.gauntlet/STATE.md"
  for i in 1 2 3 4; do printf '// pending F-%s\n' "$i" > "$TMP/pendq/pending/F-$i.t.sol"; done; }
PQ="$TMP/pendq"; n=928
for rel in sub/F-5.t.sol F-5.sol .F-5.t.sol .h/F-5.t.sol sub/deeper/F-5.sol; do
  pj_reset; mkdir -p "$(dirname "$PQ/pending/$rel")"; printf '// F-5\n' > "$PQ/pending/$rel"
  nx "$NX" "$PQ/.gauntlet/STATE.md" --judge "$PJJ" > "$TMP/o$n" 2>&1; check "next.sh refuses pending/$rel (forge runs it under row 6b's profile), no note" 2 $? "$TMP/o$n"
  grep -qF "$PQ/pending/$rel is a test in pending/, and STATE.md's notes have no 'pending: F-5 ...' for it" "$TMP/o$n" \
    || { echo "  FAIL  not the refusal naming pending/$rel as F-5:"; sed "s/^/        | /" "$TMP/o$n"; fails=$((fails + 1)); }
  n=$((n + 1))
done
pj_reset; mkdir -p "$PQ/pending/lib"; : > "$PQ/pending/lib/Helper.sol"
nx "$NX" "$PQ/.gauntlet/STATE.md" --judge "$PJJ" > "$TMP/o933" 2>&1; check "next.sh refuses a helper pending/lib/Helper.sol (forge compiles it with the pending tests; a helper lives outside pending/)" 2 $? "$TMP/o933"
grep -qF "$PQ/pending/lib/Helper.sol is a test in pending/" "$TMP/o933" || { echo "  FAIL  not the refusal naming it:"; sed "s/^/        | /" "$TMP/o933"; fails=$((fails + 1)); }
pj_reset; mkdir -p "$PQ/pending/sub"; mv "$PQ/pending/F-3.t.sol" "$PQ/pending/sub/F-3.t.sol"; mv "$PQ/pending/F-4.t.sol" "$PQ/pending/F-4.sol"
nx "$NX" "$PQ/.gauntlet/STATE.md" --judge "$PJJ" > "$TMP/o934" 2>&1; check "next.sh: F-3's test in pending/sub/, F-4's as F-4.sol, each with its note: the pause" 0 $? "$TMP/o934"
[ "$(nx_rows "$TMP/o934")" = "2,STOP" ] || { echo "  FAIL  and it named rows '$(nx_rows "$TMP/o934")', not 2,STOP"; fails=$((fails + 1)); }
# a note naming several ids: each is read, and each needs its file
PQS='                           pending: F-4 - '
pq_note() { # pq_note <what replaces "F-4 - " in F-4's note>: the fixture so edited, as the project's STATE.md
  local l
  while IFS= read -r l; do
    [[ $l == "$PQS"* ]] && l="                           pending: $1${l#"$PQS"}"
    printf '%s\n' "$l"
  done < "$NXFIX/state-case-round-end-owner-absent.md" > "$PQ/.gauntlet/STATE.md"
}
n=935
for form in 'F-4, F-5 - ' 'F-4,F-5 - ' 'F-4 and F-5 - ' 'F-4, and F-5: ' 'F-4 & F-5 - '; do
  pj_reset; pq_note "$form"
  grep -qF "pending: $form" "$PQ/.gauntlet/STATE.md" || { echo "  FAIL  (the case's own sed did not write 'pending: $form')"; fails=$((fails + 1)); }
  nx "$NX" "$PQ/.gauntlet/STATE.md" --judge "$PJJ" > "$TMP/o$n" 2>&1; check "next.sh refuses the note 'pending: $form...' with no file for F-5" 2 $? "$TMP/o$n"
  grep -qF "STATE.md's notes name 'pending: F-5', and $PQ/pending/F-5.t.sol does not exist (nor any F-5.sol below pending/)" "$TMP/o$n" \
    || { echo "  FAIL  not the refusal naming F-5:"; sed "s/^/        | /" "$TMP/o$n"; fails=$((fails + 1)); }
  n=$((n + 1))
done
mkdir -p "$PQ/pending/sub"; printf '// F-5\n' > "$PQ/pending/sub/F-5.t.sol"
nx "$NX" "$PQ/.gauntlet/STATE.md" --judge "$PJJ" > "$TMP/o940" 2>&1; check "next.sh: the note 'pending: F-4 & F-5 - ...' and F-5's file in pending/sub/: the pause" 0 $? "$TMP/o940"
pj_reset; pq_note "TBD - "
nx "$NX" "$PQ/.gauntlet/STATE.md" --judge "$PJJ" > "$TMP/o941" 2>&1; check "next.sh refuses a pending: note whose first word is not an id ('pending: TBD - ...')" 2 $? "$TMP/o941"
grep -qF "notes: a pending: note names no id ('pending: TBD - " "$TMP/o941" || { echo "  FAIL  not the refusal naming the note:"; sed "s/^/        | /" "$TMP/o941"; fails=$((fails + 1)); }
unset PENDING_RED
# K31, decision 3 (K31b: the whole workspace - bench/, backtests/, rounds/ too, V31): row 10 does not count the route's
# own files. The same end state, row 10 not answered: its question
# says the skeleton, STATE.md and the rest do not make it true (a walker answered it false against the letter, to reach
# the pause); and NEXT.md's row 10 says the same
nx "$NX" "$NXFIX/state-case-round-end-owner-absent.md" --judge 5=false,8=false,9=false > "$TMP/o930" 2>&1
check "next.sh: a walk's end with the skeleton written, row 10 not answered: asked" 3 $? "$TMP/o930"
if grep -qF "The route's whole workspace does not count - everything under .gauntlet/ (STATE.md, DECISIONS.md, LOG.md, the route's SPEC.md, the dossier, STATIC-TRIAGE.md, briefs/, reports/, rounds/, the benches in bench/ and the tests written in them, backtests/, the triage notes), or with location: root those same files and directories at the root; an owner's own SPEC.md, README or NatSpec outside that workspace still counts. A skeleton written since the last round does not make this row true" "$TMP/o930" \
  && grep -q "^needs judgement: row 10 - .*The route's whole workspace does not count" "$TMP/o930" \
  && [ "$(tail -1 "$TMP/o930")" = "if every answer is false: STOP - paused, waiting on the owner: $(sed -n 's/^waiting_on_owner: *//p' "$NXFIX/state-case-round-end-owner-absent.md")" ]; then
  echo "  ok    row 10's question says the route's whole workspace does not count, an owner's own documents do; answered false, the pause"; else
  echo "  FAIL  row 10's question does not say the route's whole workspace does not count:"; sed "s/^/        | /" "$TMP/o930"; fails=$((fails + 1)); fi
grep -qF "| 10 | only documents, comments, scripts or tests changed since the last round (before any round: false), and they make claims about the code. The route's whole workspace does not count: everything under \`.gauntlet/\` - \`STATE.md\`, \`DECISIONS.md\`, \`LOG.md\`, the route's \`SPEC.md\`, the dossier, \`STATIC-TRIAGE.md\`, \`briefs/\`, \`reports/\`, \`rounds/\`, the benches in \`bench/\` and the tests written in them, \`backtests/\`, the triage notes - or, with \`location: root\`, those same files and directories at the project's root. An owner's own \`SPEC.md\`, README or NatSpec outside that workspace still counts." "$NXT" \
  && echo "  ok    and NEXT.md's row 10 says the same in its condition" \
  || { echo "  FAIL  NEXT.md's row 10 does not exclude the route's whole workspace"; fails=$((fails + 1)); }
# every run of next.sh above, through nx, said NEXT_SELFTEST=1 on its first line of stderr
if [ -s "$TMP/nx-silent" ]; then echo "  FAIL  next.sh ran with NEXT_SELFTEST=1 and did not say so:"; sed "s/^/        | /" "$TMP/nx-silent"; fails=$((fails + 1)); else
  echo "  ok    every run with NEXT_SELFTEST=1 said so, on the first line of its stderr"; fi

rm -rf "$TMP/.gauntlet"   # the build record the next.sh section's cases read in $TMP (above): no other section's
# ================================================================= skills: gen-skills.sh, skills-check.sh, install-skills.sh (K30; no forge needed)
# The skills are generated from AGENTS.md and doctrine/NEXT.md; skills-check.sh regenerates and compares. Each way a skill
# can go wrong is made here, on a copy of the kit, and must be seen red: a hand edit in a SKILL.md, the invariants marker
# moved in AGENTS.md (and doubled), a file a skill points at renamed, a skill grown past 9000 bytes (the skills
# regenerated, so that size is the only red), a NEXT.md row no skill owns. Then the installer, into temporary projects
# and a temporary HOME only: {{KIT}} written, the kit absent said so, a kit lacking a file named, its own skills replaced
# only with --force, a directory that is not the kit's never replaced, user level only with --user.
echo "== skills (gen-skills.sh, skills-check.sh, install-skills.sh) =="
"$HERE/skills-check.sh" > "$TMP/o900" 2>&1; check "skills-check.sh on this kit: the skills are what the doctrine generates" 0 $? "$TMP/o900"
SK="$TMP/skkit"; mkdir -p "$SK/foundry-kit/v4"
for x in AGENTS.md QUICKSTART.md README.md doctrine briefs state scripts skills; do cp -R "$HERE/../$x" "$SK/"; done
cp "$HERE/../foundry-kit/README.md" "$SK/foundry-kit/"; cp "$HERE/../foundry-kit/v4/README.md" "$SK/foundry-kit/v4/"
sk_restore() { rm -rf "$SK/skills" "$SK/doctrine" "$SK/AGENTS.md"; cp -R "$HERE/../skills" "$HERE/../doctrine" "$HERE/../AGENTS.md" "$SK/"; }
sk_says() { # sk_says <output file> <text>: the red names what it should
  if grep -qF "$2" "$1"; then echo "  ok    and it says: $2"; else echo "  FAIL  it does not say: $2"; sed "s/^/        | /" "$1" | tail -n 5; fails=$((fails + 1)); fi
}
"$SK/scripts/skills-check.sh" > "$TMP/o901" 2>&1; check "skills-check.sh on a copy of the kit (every pointer is in the copy)" 0 $? "$TMP/o901"
# a hand edit
sed -i.bak 's/^- \*\*Row 13\*\* - a REGRESSION round/- **Row 13** - a regression round/' "$SK/skills/hook-gauntlet-round/SKILL.md"
cmp -s "$SK/skills/hook-gauntlet-round/SKILL.md" "$HERE/../skills/hook-gauntlet-round/SKILL.md" && { echo "  FAIL  the hand edit did not land"; fails=$((fails + 1)); }
rm -f "$SK/skills/hook-gauntlet-round/SKILL.md.bak"
"$SK/scripts/skills-check.sh" > "$TMP/o902" 2>&1; check "a hand edit in a SKILL.md is red" 1 $? "$TMP/o902"
sk_says "$TMP/o902" "skills/hook-gauntlet-round/SKILL.md: differs from what gen-skills.sh writes"
sk_restore
# the end marker moved up one line in AGENTS.md: the last rule falls out of the block
awk '/^<!-- invariants:end -->$/ { next } { print } /^- \*\*Words you never write/ { w = 1 } w && /^  and "audited"/ { print "<!-- invariants:end -->"; w = 0 }' \
  "$HERE/../AGENTS.md" > "$SK/AGENTS.md"
"$SK/scripts/skills-check.sh" > "$TMP/o903" 2>&1; check "the invariants:end marker moved in AGENTS.md is red" 1 $? "$TMP/o903"
sk_says "$TMP/o903" "skills/hook-gauntlet/SKILL.md: differs from what gen-skills.sh writes"
sk_says "$TMP/o903" "skills/hook-gauntlet-battery/SKILL.md: its six rules are not AGENTS.md's block"
awk '{ print } /^<!-- invariants:end -->$/ { print "<!-- invariants:begin -->" }' "$HERE/../AGENTS.md" > "$SK/AGENTS.md"
"$SK/scripts/skills-check.sh" > "$TMP/o904" 2>&1; check "a second invariants:begin marker in AGENTS.md is red" 1 $? "$TMP/o904"
sk_says "$TMP/o904" "refused to regenerate the skills: gen-skills: REFUSED - AGENTS.md has 2 '<!-- invariants:begin -->'"
sk_restore
# a file a skill points at, renamed
mv "$SK/doctrine/JUDGES.md" "$SK/doctrine/JUDGES-renamed.md"
"$SK/scripts/skills-check.sh" > "$TMP/o905" 2>&1; check "a file a skill points at, renamed, is red" 1 $? "$TMP/o905"
sk_says "$TMP/o905" "skills/hook-gauntlet-battery/SKILL.md: points at '{{KIT}}/doctrine/JUDGES.md', which is not in the kit"
sk_restore
# a skill past 9000 bytes, regenerated so that nothing drifts: row 7's cell grown by 2000 bytes in NEXT.md
pad="$(printf ' - padding%.0s' $(seq 1 200))"
sed -i.bak "s/^\(| 7 | .*mutation (\`JUDGES.md\`)\) |/\1$pad |/" "$SK/doctrine/NEXT.md"; rm -f "$SK/doctrine/NEXT.md.bak"
"$SK/scripts/gen-skills.sh" > "$TMP/o906" 2>&1; check "gen-skills.sh regenerates the copy's skills after row 7 grew" 0 $? "$TMP/o906"
"$SK/scripts/skills-check.sh" > "$TMP/o907" 2>&1; check "a skill over 9000 bytes is red" 1 $? "$TMP/o907"
sk_says "$TMP/o907" "skills/hook-gauntlet-battery/SKILL.md: is "
sk_says "$TMP/o907" "bytes, over 9000"
if grep -q 'differs from what gen-skills.sh writes' "$TMP/o907"; then echo "  FAIL  and it also reported drift: the size is not the only red"; fails=$((fails + 1)); else
  echo "  ok    and the size is the only red (the skills were regenerated)"; fi
sk_restore
# a NEXT.md row no skill owns
awk '{ print } /^\| 18b \|/ { print "| 19 | a row added to the table | do something | a reason |" }' "$HERE/../doctrine/NEXT.md" > "$SK/doctrine/NEXT.md"
"$SK/scripts/gen-skills.sh" --out "$TMP/skgen19" > "$TMP/o908" 2>&1; check "gen-skills.sh refuses a NEXT.md row no skill owns" 2 $? "$TMP/o908"
sk_says "$TMP/o908" "row 19 of doctrine/NEXT.md's table is owned by no skill"
"$SK/scripts/skills-check.sh" > "$TMP/o909" 2>&1; check "and skills-check.sh is red on it" 1 $? "$TMP/o909"
sk_restore
# the generator never overwrites a SKILL.md it did not write
mkdir -p "$TMP/skhand/hook-gauntlet"; printf -- '---\nname: hook-gauntlet\ndescription: mine\n---\nmine\n' > "$TMP/skhand/hook-gauntlet/SKILL.md"
"$HERE/gen-skills.sh" --out "$TMP/skhand" > "$TMP/o910" 2>&1; check "gen-skills.sh refuses to overwrite a SKILL.md it did not write" 2 $? "$TMP/o910"
if grep -qx 'mine' "$TMP/skhand/hook-gauntlet/SKILL.md"; then echo "  ok    and the file is untouched"; else echo "  FAIL  the file was changed"; fails=$((fails + 1)); fi
# the installer: a project with no kit vendored yet
mkdir -p "$TMP/skproj"; SP="$(cd "$TMP/skproj" && pwd)"   # as the installer resolves it (a /tmp behind a symlink)
"$HERE/install-skills.sh" --harness claude --project "$SP" > "$TMP/o911" 2>&1; check "install-skills.sh --harness claude --project (no kit vendored)" 0 $? "$TMP/o911"
sk_says "$TMP/o911" "pointers: NOT checked - no kit at $SP/lib/hook-gauntlet"
sk_n="$(find "$SP/.claude/skills" -name SKILL.md | wc -l | tr -d ' ')"; sk_all="$(find "$SP/.claude/skills" -type f | wc -l | tr -d ' ')"
if [ "$sk_n" = 9 ] && [ "$sk_all" = 9 ] && ! grep -rqF '{{KIT}}' "$SP/.claude/skills" && grep -qF '`lib/hook-gauntlet/doctrine/NEXT.md`' "$SP/.claude/skills/hook-gauntlet/SKILL.md"; then
  echo "  ok    nine SKILL.md and nothing else, {{KIT}} written as lib/hook-gauntlet"; else
  echo "  FAIL  installed: $sk_n SKILL.md, $sk_all files; {{KIT}} left: $(grep -rlF '{{KIT}}' "$SP/.claude/skills" | wc -l)"; fails=$((fails + 1)); fi
"$HERE/install-skills.sh" --harness claude --project "$SP" > "$TMP/o912" 2>&1; check "installing again without --force is refused" 2 $? "$TMP/o912"
sk_says "$TMP/o912" "rerun with --force"
mkdir -p "$SP/lib"; ln -s "$(cd "$HERE/.." && pwd)" "$SP/lib/hook-gauntlet"
"$HERE/install-skills.sh" --harness claude --project "$SP" --force > "$TMP/o913" 2>&1; check "with the kit vendored at lib/hook-gauntlet and --force, every pointer resolves" 0 $? "$TMP/o913"
sk_says "$TMP/o913" "resolve under $SP/lib/hook-gauntlet"
rm -f "$SK/doctrine/JUDGES.md"
"$HERE/install-skills.sh" --harness codex --project "$SP" --kit "$SK" > "$TMP/o914" 2>&1; check "a kit at --kit that lacks a file a skill names is red, into .agents/skills" 1 $? "$TMP/o914"
sk_says "$TMP/o914" "names $SK/doctrine/JUDGES.md, which the kit at $SK does not have"
[ -f "$SP/.agents/skills/hook-gauntlet/SKILL.md" ] || { echo "  FAIL  --harness codex did not write .agents/skills"; fails=$((fails + 1)); }
sk_restore
# a directory that is not the kit's is never replaced, even with --force, and nothing else is written
SQ="$TMP/skproj2"; mkdir -p "$SQ/.claude/skills/hook-gauntlet-battery"
printf -- '---\nname: hook-gauntlet-battery\ndescription: somebody else'"'"'s\n---\ntheirs\n' > "$SQ/.claude/skills/hook-gauntlet-battery/SKILL.md"
sk_h="$(hash_of "$SQ/.claude/skills/hook-gauntlet-battery/SKILL.md")"
"$HERE/install-skills.sh" --harness claude --project "$SQ" --force > "$TMP/o915" 2>&1; check "a skills directory that is not this kit's is refused, even with --force" 2 $? "$TMP/o915"
sk_says "$TMP/o915" "is not one of this kit's skills"
if [ "$(hash_of "$SQ/.claude/skills/hook-gauntlet-battery/SKILL.md")" = "$sk_h" ] && [ "$(find "$SQ/.claude/skills" -type f | wc -l | tr -d ' ')" = 1 ]; then
  echo "  ok    and it is untouched, and nothing else was written"; else echo "  FAIL  something was written"; fails=$((fails + 1)); fi
# where: a project or, on purpose, the user level - never by default
"$HERE/install-skills.sh" --harness claude > "$TMP/o916" 2>&1; check "neither --project nor --user is refused" 2 $? "$TMP/o916"
sk_says "$TMP/o916" "say where: --project DIR"
HOME="$TMP/skhome" "$HERE/install-skills.sh" --harness claude --user > "$TMP/o917" 2>&1; check "--user with the default (relative) --kit is refused" 2 $? "$TMP/o917"
mkdir -p "$TMP/skhome"
HOME="$TMP/skhome" "$HERE/install-skills.sh" --harness claude --user --kit "$(cd "$HERE/.." && pwd)" > "$TMP/o918" 2>&1; check "--user with an absolute --kit writes the user-level directory (a temporary HOME)" 0 $? "$TMP/o918"
[ -f "$TMP/skhome/.claude/skills/hook-gauntlet/SKILL.md" ] || { echo "  FAIL  nothing in \$HOME/.claude/skills"; fails=$((fails + 1)); }
# the gate: skills that do not pass skills-check.sh are not installed
printf 'hand edit\n' >> "$SK/skills/hook-gauntlet-spec/SKILL.md"; mkdir -p "$TMP/skproj3"
"$SK/scripts/install-skills.sh" --harness claude --project "$TMP/skproj3" > "$TMP/o919" 2>&1; check "install-skills.sh refuses skills that fail skills-check.sh" 2 $? "$TMP/o919"
sk_says "$TMP/o919" "skills-check.sh does not pass on this kit's skills"
[ ! -e "$TMP/skproj3/.claude" ] || { echo "  FAIL  and it wrote something"; fails=$((fails + 1)); }
sk_restore

# ================================================================= dossier-pdf.py (the dossier's reading copy; no forge needed)
# The PDF is the auditor's reading copy of DOSSIER.md; the Markdown stays the record. What a PDF must never do is lose a
# line on the way to paper, so the check below reads the text back out of the PDF (pypdf) and looks for every line of
# the Markdown in it. The rendering needs the reportlab package and the read-back needs pypdf: the kit installs neither
# locally. Without them those cases are NOT run and the run says so, like shellcheck above: not counted as INCOMPLETE
# (the PDF is optional, the Markdown is what is handed over either way), and CI's selftest job installs both and checks
# that they ran.
echo "== dossier-pdf.py =="
DPY="$HERE/dossier-pdf.py"; DTPL="$HERE/../briefs/handoff-dossier.md"; DFIX="$FIX/dossier-wide-table.md"
DFIX_PAGES=2   # measured once (reportlab 4.4.9, 2026-09-24); a change of more than one page is a layout change to look at
lines_in_pdf() { # lines_in_pdf <md> <pdf>: 0 every line of the Markdown is in the PDF's text; 1 names the ones that are not
  python3 - "$1" "$2" << 'PY'
import re, sys
from pypdf import PdfReader
md, pdf = sys.argv[1], sys.argv[2]
# markup the renderer turns into layout, removed from both sides; letters, digits and every other sign must survive
def norm(s):
    return re.sub(r"[\s`|\\\[\]()]", "", s.replace("**", ""))
text = []
for page in PdfReader(pdf).pages:   # the footer ("... the Markdown is the record", "page N") is not the dossier's text
    text += [l for l in page.extract_text().split("\n")
             if "the Markdown is the record" not in l and not re.fullmatch(r"\s*page \d+\s*", l)]
text = norm("".join(text))
lost, fence = [], None
for n, line in enumerate(open(md, encoding="utf-8").read().replace("\r\n", "\n").split("\n"), 1):
    s = line
    m = re.match(r"^\s*(```+|~~~+)(.*)$", s)
    if m and (fence is None or m.group(1).startswith(fence)):
        fence = m.group(1) if fence is None else None
        s = m.group(2) if fence else ""        # the opening fence's language tag is text; the fences are not
    elif fence is None:
        if re.match(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$", s) or s.strip() == "---":
            continue                            # a table's separator row, a horizontal rule
        s = re.sub(r"^#+ ", "", s)
        s = re.sub(r"^\s*[-*] ", "", s)
    if norm(s) and norm(s) not in text:
        lost.append(n)
if lost:
    print("lost on the way to paper: line(s) %s of %s" % (", ".join(map(str, lost[:20])), md))
    sys.exit(1)
print("every line of %s is in the PDF's text" % md)
PY
}
if ! command -v python3 > /dev/null 2>&1; then
  echo "  --    python3 is not installed here: dossier-pdf.py NOT run on this machine (CI's selftest job runs it)"
else
  printf 'Notes with no title line.\n\n## A section\n\nSome text.\n' > "$TMP/notitle.md"
  python3 "$DPY" "$TMP/notitle.md" "$TMP/notitle.pdf" > "$TMP/o213" 2>&1; check "dossier-pdf.py: a file with no '# ' title line is not a dossier" 1 $? "$TMP/o213"
  if [ ! -e "$TMP/notitle.pdf" ]; then echo "  ok    and nothing was written"; else echo "  FAIL  a PDF was written for a file that is not a dossier"; fails=$((fails + 1)); fi
  # reportlab hidden, even where it is installed: a package of the same name first on PYTHONPATH that refuses to import
  mkdir -p "$TMP/no-reportlab/reportlab"
  printf 'raise ImportError("reportlab hidden by scripts/selftest.sh")\n' > "$TMP/no-reportlab/reportlab/__init__.py"
  PYTHONPATH="$TMP/no-reportlab" python3 "$DPY" "$DTPL" "$TMP/norl.pdf" > "$TMP/o214" 2>&1
  check "dossier-pdf.py: reportlab missing" 2 $? "$TMP/o214"
  if [ ! -e "$TMP/norl.pdf" ] && [ "$(wc -l < "$TMP/o214" | tr -d ' ')" = "1" ] && grep -q 'reportlab' "$TMP/o214"; then
    echo "  ok    one line that names reportlab, and nothing written"; else
    echo "  FAIL  not one line naming reportlab with nothing written:"; sed "s/^/        | /" "$TMP/o214"; fails=$((fails + 1)); fi
  if python3 -c 'import reportlab' > /dev/null 2>&1; then
    python3 "$DPY" "$DTPL" "$TMP/template.pdf" > "$TMP/o215" 2>&1; check "dossier-pdf.py renders the template, briefs/handoff-dossier.md" 0 $? "$TMP/o215"
    if [ -s "$TMP/template.pdf" ] && [ "$(head -c 5 "$TMP/template.pdf")" = "%PDF-" ]; then echo "  ok    and the PDF exists and is not empty"; else
      echo "  FAIL  no PDF, or an empty one, for the template"; fails=$((fails + 1)); fi
    python3 "$DPY" "$DFIX" "$TMP/fixture.pdf" > "$TMP/o216" 2>&1
    check "dossier-pdf.py renders a dossier with a wide table of long cells, code, nested lists, an HTML-comment preamble" 0 $? "$TMP/o216"
    pg216="$(sed -n 's/.* (\([0-9]*\) pages*, .*/\1/p' "$TMP/o216")"
    if [ -n "$pg216" ] && [ "$pg216" -ge $((DFIX_PAGES - 1)) ] && [ "$pg216" -le $((DFIX_PAGES + 1)) ]; then
      echo "  ok    in $pg216 page(s), $DFIX_PAGES expected (plus or minus one)"; else
      echo "  FAIL  in ${pg216:-an unstated number of} page(s), $DFIX_PAGES expected (plus or minus one)"; fails=$((fails + 1)); fi
    if python3 -c 'import pypdf' > /dev/null 2>&1; then
      lines_in_pdf "$DFIX" "$TMP/fixture.pdf" > "$TMP/o217" 2>&1; check "no line of the fixture is lost on the way to paper (read back with pypdf)" 0 $? "$TMP/o217"
      lines_in_pdf "$DTPL" "$TMP/template.pdf" > "$TMP/o218" 2>&1; check "no line of the template is lost on the way to paper" 0 $? "$TMP/o218"
      # the entry page: the dossier as an author copies it (the template from its '# {{PROJECT}}' line on) opens on "Start
      # here" and nothing else - section 0 first appears on page 2, which it can only do if "Start here" fitted on page 1
      sed -n '/^# {{PROJECT}}/,$p' "$DTPL" > "$TMP/entry.md"
      python3 "$DPY" "$TMP/entry.md" "$TMP/entry.pdf" > "$TMP/o234" 2>&1; check "dossier-pdf.py renders the template's dossier as an author copies it" 0 $? "$TMP/o234"
      python3 - "$TMP/entry.pdf" > "$TMP/o235" 2>&1 << 'PY'
import sys
from pypdf import PdfReader
pages = [pg.extract_text() for pg in PdfReader(sys.argv[1]).pages]
first = next((k for k, t in enumerate(pages) if "0. Executive summary" in t), None)
print("pages: %d; 'Start here' on page 1: %s; section 0 first on page: %s" % (len(pages), "Start here" in pages[0], None if first is None else first + 1))
sys.exit(0 if "Start here" in pages[0] and first == 1 else 1)
PY
      check "the PDF opens on the 'Start here' page: all of it on page 1, section 0 from page 2" 0 $? "$TMP/o235"
      lines_in_pdf "$TMP/entry.md" "$TMP/entry.pdf" > "$TMP/o236" 2>&1; check "and no line of it is lost on the way to paper" 0 $? "$TMP/o236"
      # the read-back seen red: the fixture with one table row taken out, rendered, is checked against the whole fixture
      grep -v '^| coverage |' "$DFIX" > "$TMP/fixture-short.md"
      python3 "$DPY" "$TMP/fixture-short.md" "$TMP/fixture-short.pdf" > /dev/null 2>&1
      lines_in_pdf "$DFIX" "$TMP/fixture-short.pdf" > "$TMP/o219" 2>&1; check "the read-back goes red on a PDF that lost a table row" 1 $? "$TMP/o219"
      if grep -q "line(s) $(grep -n '^| coverage |' "$DFIX" | cut -d: -f1) of" "$TMP/o219"; then echo "  ok    and it names that line"; else
        echo "  FAIL  it does not name the lost line:"; sed "s/^/        | /" "$TMP/o219"; fails=$((fails + 1)); fi
    else
      echo "  --    pypdf is not installed here: the no-line-lost read-back NOT run on this machine (CI's selftest job runs it)"
    fi
  else
    echo "  --    reportlab is not installed here: rendering the template and the wide-table fixture, and the no-line-lost"
    echo "        read-back, NOT run on this machine (CI's selftest job installs reportlab and pypdf and runs them)"
  fi
fi

# ================================================================= mutate.sh and size.sh (need forge and a project)
echo "== mutate.sh / size.sh =="
KIT="$HERE/../foundry-kit"   # always the kit's own: KIT_PROJECT is removed at the start (see there)
if command -v forge > /dev/null 2>&1 && [ -e "$KIT/lib" ]; then
  export OUT_DIR="$TMP/mut"
  # the kit's own tree, with the convention: mutate.sh's default copy root is <project>/.gauntlet/bench, and only where
  # <project>/.gauntlet/ exists (K26b; `.gauntlet/` is git-ignored in the kit, and its battery makes one anyway)
  mkdir -p "$KIT/.gauntlet"
  V="src/examples/ToyVault.sol"

  LABEL=m1 "$HERE/mutate.sh" "$KIT" "$V" "credited = post - pre;" "credited = amount;" > "$TMP/o12" 2>&1
  check "a mutant that credits the requested amount is KILLED" 0 $? "$TMP/o12"

  LABEL=m2 "$HERE/mutate.sh" "$KIT" "$V" "the sum of every credit." "the SUM of every credit." > "$TMP/o13" 2>&1
  check "a change in a comment SURVIVES, and is reported as surviving" 1 $? "$TMP/o13"

  LABEL=m3 "$HERE/mutate.sh" "$KIT" "$V" "nonReentrant" "nonReentrantX" > "$TMP/o14" 2>&1
  check "a string that matches more than once proves nothing" 2 $? "$TMP/o14"

  LABEL="m4" "$HERE/mutate.sh" "$KIT" "$V" "credited = post - pre;" "credited = post - ;" > "$TMP/o15" 2>&1   # quoted: shellcheck reads a bare m4 as the m4 command (SC2209)
  check "a mutant that does not compile proves nothing" 2 $? "$TMP/o15"

  LABEL=m5 EXPECT=green "$HERE/mutate.sh" "$KIT" "$V" "the sum of every credit." "the SUM of every credit." > "$TMP/o16" 2>&1
  check "a harmless variant PASSES under EXPECT=green" 0 $? "$TMP/o16"
  if grep -q '^ToyVault ' "$TMP/mut/m5-sizes.txt" 2> /dev/null; then echo "  ok    the variant's sizes were measured"; else
    echo "  FAIL  the variant's sizes were not measured"; fails=$((fails + 1)); fi

  LABEL=m6 EXPECT=green "$HERE/mutate.sh" "$KIT" "$V" "credited = post - pre;" "credited = amount;" > "$TMP/o17" 2>&1
  check "a broken variant FAILS under EXPECT=green" 1 $? "$TMP/o17"

  if grep -q "credited = post - pre;" "$KIT/$V"; then echo "  ok    the original was never touched"; else
    echo "  FAIL  the original was modified"; fails=$((fails + 1)); fi

  OUT_DIR="$TMP/sz" LABEL=base "$HERE/size.sh" "$KIT" ToyVault > "$TMP/o18" 2>&1; check "size of one named contract" 0 $? "$TMP/o18"
  OUT_DIR="$TMP/sz" LABEL=tight MIN_MARGIN=24576 "$HERE/size.sh" "$KIT" ToyVault > "$TMP/o19" 2>&1
  check "a margin below MIN_MARGIN fails" 1 $? "$TMP/o19"
  OUT_DIR="$TMP/sz" LABEL=ghost "$HERE/size.sh" "$KIT" NoSuchContract > "$TMP/o20" 2>&1
  check "a contract that does not exist measures nothing" 2 $? "$TMP/o20"
  unset OUT_DIR

  LABEL=m7 OUT_DIR="$TMP/mut" TEST_FLAGS="--match-contrct Typo" "$HERE/mutate.sh" "$KIT" "$V" "the sum of every credit." "the SUM of every credit." > "$TMP/o24" 2>&1
  check "a bad TEST_FLAGS makes the BASELINE red: nothing proven, never KILLED" 2 $? "$TMP/o24"
  LABEL=m8 OUT_DIR="$TMP/mut" EXPECT=green TEST_FLAGS="--match-contract NoSuchContractAnywhere" "$HERE/mutate.sh" "$KIT" "$V" "credited = post - pre;" "credited = amount;" > "$TMP/o25" 2>&1
  check "a filter that matches nothing proves nothing about a broken variant" 2 $? "$TMP/o25"

  # ================================================================= battery.sh, fuzz-long.sh, bench.sh
  echo "== battery.sh / fuzz-long.sh / bench.sh =="
  M="$TMP/mini"; mkdir -p "$M/src" "$M/test" "$M/.gauntlet"; ln -s "$(cd "$KIT/lib" && pwd -P)" "$M/lib"   # .gauntlet/: the convention installed
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n[invariant]\nruns = 4\ndepth = 4\nfail_on_revert = true\n[profile.long.invariant]\nruns = 8\ndepth = 8\nfail_on_revert = true\n' > "$M/foundry.toml"
  printf 'pragma solidity ^0.8.26;\ncontract A { uint256 public x; function inc() external { x++; } }\n' > "$M/src/A.sol"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/A.sol";\ncontract AUnit is Test { function test_inc() public { A a = new A(); a.inc(); assertEq(a.x(), 1); } }\ncontract AInvariant is Test { A a; function setUp() public { a = new A(); targetContract(address(a)); } function invariant_never_decreases() public view { assertGe(a.x(), 0); } }\n' > "$M/test/A.t.sol"

  # ---- a mutant that bricks setUp() prints `[FAIL: ...] setUp()` and NO test ran. mutate.sh must say NOTHING PROVEN and
  # never KILLED: the test file below makes setUp depend on inc(), and the mutant turns inc() into an underflow.
  printf 'pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/A.sol";
contract SetUpDep is Test { A a; function setUp() public { a = new A(); a.inc(); require(a.x() == 1, "setUp depends on inc"); } function test_x() public { assertEq(a.x(), 1); } }
' > "$M/test/SetUpDep.t.sol"
  LABEL=m9s OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$M" "src/A.sol" "x++;" "x--;" > "$TMP/o35" 2>&1
  check "a mutant that bricks setUp() proves nothing, and is never KILLED" 2 $? "$TMP/o35"
  if grep -q "setUp()" "$TMP/o35"; then echo "  ok    the refusal names setUp()"; else echo "  FAIL  the refusal does not name setUp()"; fails=$((fails + 1)); fi
  rm -f "$M/test/SetUpDep.t.sol"
  # its filter is TEST_FLAGS alone: forge's own FOUNDRY_MATCH_TEST from the environment (a --match-contract on the command
  # line overrides FOUNDRY_MATCH_CONTRACT, but not the others) made its baseline empty; ignored now, and said
  LABEL=m20 OUT_DIR="$TMP/mut" EXPECT=green TEST_FLAGS="--match-contract AUnit" FOUNDRY_MATCH_TEST=no_test_is_named_this \
    "$HERE/mutate.sh" "$M" "src/A.sol" "x++;" "x += 1;" > "$TMP/o733" 2>&1
  check "mutate.sh with FOUNDRY_MATCH_TEST in the environment runs on TEST_FLAGS alone" 0 $? "$TMP/o733"
  if grep -qx 'mutate: ignoring FOUNDRY_MATCH_TEST from the environment' "$TMP/o733" && grep -qx 'tests: forge test --match-contract AUnit' "$TMP/o733"; then
    echo "  ok    and it says it ignored it, and the mutant's log names the tests it ran"; else
    echo "  FAIL  mutate.sh did not name the ignored variable or its own filter:"; grep -a -e '^mutate:' -e '^tests:' "$TMP/o733" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # a failed test is never a pass: the verdict comes from forge's COUNTS, not its exit code alone. A forge that exits 0 on
  # `forge test` whatever happened (what `--allow-failure` does) made a killed mutant SURVIVED and a broken variant PASSED
  # (a verifier, V24, with FORGE_ALLOW_FAILURE=true); and FORGE_ALLOW_FAILURE itself is removed from the environment
  FW0="$TMP/fw0"; mkdir -p "$FW0"
  # shellcheck disable=SC2016   # the wrapper's own $@ and $?, written literally
  printf '#!/usr/bin/env bash\n"%s" "$@"; rc=$?\n[ "$1" = test ] && exit 0\nexit $rc\n' "$(command -v forge)" > "$FW0/forge"; chmod +x "$FW0/forge"
  PATH="$FW0:$PATH" LABEL=m21 OUT_DIR="$TMP/mut" TEST_FLAGS="--match-contract AUnit" "$HERE/mutate.sh" "$M" "src/A.sol" "x++;" "x += 2;" > "$TMP/o765" 2>&1
  check "mutate.sh, a forge that exits 0 over a failed test: the mutant is KILLED, from the counts" 0 $? "$TMP/o765"
  PATH="$FW0:$PATH" LABEL=m22 OUT_DIR="$TMP/mut" EXPECT=green TEST_FLAGS="--match-contract AUnit" "$HERE/mutate.sh" "$M" "src/A.sol" "x++;" "x += 2;" > "$TMP/o766" 2>&1
  check "mutate.sh, a forge that exits 0 over a failed test: the broken variant FAILED, from the counts" 1 $? "$TMP/o766"
  FORGE_ALLOW_FAILURE=true LABEL=m23 OUT_DIR="$TMP/mut" TEST_FLAGS="--match-contract AUnit" "$HERE/mutate.sh" "$M" "src/A.sol" "x++;" "x += 2;" > "$TMP/o767" 2>&1
  check "mutate.sh with FORGE_ALLOW_FAILURE=true in the environment: the mutant is KILLED" 0 $? "$TMP/o767"
  if grep -qx 'mutate: ignoring FORGE_ALLOW_FAILURE from the environment' "$TMP/o767" && grep -q '^KILLED - ' "$TMP/o767"; then
    echo "  ok    and it says it removed FORGE_ALLOW_FAILURE"; else
    echo "  FAIL  mutate.sh kept FORGE_ALLOW_FAILURE, or did not say so:"; grep -a -e '^mutate:' -e 'KILLED' -e 'SURVIVED' "$TMP/o767" | sed "s/^/        | /"; fails=$((fails + 1)); fi

  # ---- a FILE reached through a symlinked lib/ is the ORIGINAL, not the copy's: mutate.sh must refuse it, and the
  # original must be byte-for-byte what it was. (`cp -a` keeps the link; the mutation used to be written through it.)
  SH="$TMP/shared"; SL="$TMP/symlib"; mkdir -p "$SH" "$SL/src" "$SL/test" "$SL/.gauntlet"
  ln -s "$(cd "$KIT/lib/forge-std" && pwd -P)" "$SH/forge-std"
  printf 'pragma solidity ^0.8.26;\ncontract X { uint256 public x; function inc() external { x++; } }\n' > "$SH/X.sol"
  ln -s "$SH" "$SL/lib"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n' > "$SL/foundry.toml"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../lib/X.sol";\ncontract XUnit is Test { function test_inc() public { X a = new X(); a.inc(); assertEq(a.x(), 1); } }\n' > "$SL/test/X.t.sol"
  sh_before="$(hash_of "$SH/X.sol")"
  LABEL=m16 OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$SL" lib/X.sol "x++;" "x += 2;" > "$TMP/o94" 2>&1
  check "a FILE whose real path leaves the copy (symlinked lib/) is refused: nothing proven" 2 $? "$TMP/o94"
  if [ "$(hash_of "$SH/X.sol")" = "$sh_before" ] && [ ! -e "$SH/X.sol.mutated" ]; then echo "  ok    and the original behind the link is unchanged (sha256 before = after)"; else
    echo "  FAIL  mutate.sh WROTE THROUGH the symlink into the original"; fails=$((fails + 1)); fi
  if grep -q "NOTHING PROVEN" "$TMP/o94" && grep -qF "$(cd -P "$SH" && pwd -P)/X.sol" "$TMP/o94"; then echo "  ok    and the refusal names the resolved path"; else
    echo "  FAIL  the refusal does not name the resolved path"; fails=$((fails + 1)); fi

  "$HERE/battery.sh" "$M" > "$TMP/o26" 2>&1; check "battery on a small green project" 0 $? "$TMP/o26"
  # the guard against the REAL forge, on the project the battery just built. The stranger's case: the sources copied in
  # again after the build (new mtime, same bytes) are FRESH. An edit is STALE - and the guard's own build has now compiled
  # it, so the edit UNDONE is a change too: STALE again (it was FRESH while the hash decided and nothing was rebuilt)
  CB="$TMP/copyback"; mkdir -p "$CB"
  cp -R "$M/src" "$M/test" "$CB/" && rm -rf "$M/src" "$M/test" && cp -R "$CB/src" "$CB/test" "$M/" && touch "$M/src/A.sol" "$M/test/A.t.sol"
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o165" 2>&1; check "freshness after the sources were copied in again (real forge): FRESH" 0 $? "$TMP/o165"
  cp "$M/src/A.sol" "$TMP/A.sol.keep"; printf '// edited after the build\n' >> "$M/src/A.sol"
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o166" 2>&1; check "freshness after an edit with no build (real forge): STALE" 1 $? "$TMP/o166"
  if grep -q '^evidence: src/A.sol changed after the last build' "$TMP/o166"; then echo "  ok    and the evidence names the edited source"; else
    echo "  FAIL  the evidence does not name src/A.sol"; fails=$((fails + 1)); fi
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o207" 2>&1; check "the guard rebuilt what it called STALE: the next run is FRESH" 0 $? "$TMP/o207"
  cp "$TMP/A.sol.keep" "$M/src/A.sol"
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o167" 2>&1; check "the edit undone after the guard rebuilt it: a change again, STALE (real forge)" 1 $? "$TMP/o167"
  # the case the content hash could not see: only the SETTINGS changed, no source touched. forge 1.8.1 recompiles on a new
  # optimizer or evm_version (measured on a toy: the runtime went from 690 to 388 bytes with the optimizer on)
  cp "$M/foundry.toml" "$TMP/mini.toml.keep"
  sed -i 's/^libs = \["lib"\]$/&\noptimizer = true/' "$M/foundry.toml"
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o208" 2>&1; check "only the optimizer turned on in foundry.toml, no source changed: STALE (real forge)" 1 $? "$TMP/o208"
  if grep -q 'not a source' "$TMP/o208"; then echo "  ok    and it says no source changed: the settings, the compiler or an artifact did"; else
    echo "  FAIL  a settings-only STALE does not say that no source changed"; fails=$((fails + 1)); fi
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o209" 2>&1; check "and rebuilt: the next run is FRESH" 0 $? "$TMP/o209"
  sed -i 's/^optimizer = true$/&\nevm_version = "shanghai"/' "$M/foundry.toml"
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o210" 2>&1; check "only evm_version changed: STALE (real forge)" 1 $? "$TMP/o210"
  cp "$TMP/mini.toml.keep" "$M/foundry.toml"
  # a build that fails, and no build at all: nothing decided
  printf 'contract {\n' >> "$M/src/A.sol"
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o211" 2>&1; check "a source that does not compile: nothing decided (real forge)" 2 $? "$TMP/o211"
  if grep -q 'Error (' "$TMP/o211"; then echo "  ok    and it prints solc's error"; else echo "  FAIL  the failed build's error is not printed"; fails=$((fails + 1)); fi
  cp "$TMP/A.sol.keep" "$M/src/A.sol"
  rm -rf "$M/out" "$M/cache"
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o212" 2>&1; check "no build at all (no out/, no cache): nothing decided, nothing built" 2 $? "$TMP/o212"
  if [ ! -e "$M/out" ]; then echo "  ok    and it did not build"; else echo "  FAIL  the guard built a project that had no build"; fails=$((fails + 1)); fi
  (cd "$M" && forge build > "$TMP/o212.build" 2>&1)
  # the fresh reader's case: a CRLF checkout, built, checked at once - forge hashed the LF text, the guard must too
  cp "$M/test/A.t.sol" "$TMP/At.sol.keep"; sed -i 's/$/\r/' "$M/src/A.sol" "$M/test/A.t.sol"
  (cd "$M" && forge build > "$TMP/o174.build" 2>&1)
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o174" 2>&1; check "a fresh build of sources with CRLF line ends (forge's own cache): FRESH" 0 $? "$TMP/o174"
  cp "$TMP/A.sol.keep" "$M/src/A.sol"; cp "$TMP/At.sol.keep" "$M/test/A.t.sol"
  # a filter exported for mutate.sh (QUICKSTART: TEST_FLAGS="--match-contract ...") or forge's own FOUNDRY_MATCH_* must not
  # narrow the battery: it made the root kit's battery run 5 tests of 107 and say BATTERY PASSED (2026-09-27)
  n26="$(sed -nE 's/^test +rc=0 +\(passed ([0-9]+), failed 0, skipped 0; filter: none\)$/\1/p' "$TMP/o26")"
  TEST_FLAGS="--match-contract AUnit" "$HERE/battery.sh" "$M" > "$TMP/o730" 2>&1; check "battery with TEST_FLAGS in the environment (a filter meant for mutate.sh)" 0 $? "$TMP/o730"
  if [ -n "$n26" ] && grep -qx 'battery: ignoring TEST_FLAGS from the environment' "$TMP/o730" \
    && grep -Eq "^test +rc=0 +\(passed $n26, failed 0, skipped 0; filter: none\)$" "$TMP/o730"; then
    echo "  ok    and it says it ignored it, ran every test ($n26, as without it), and the summary says filter: none"; else
    echo "  FAIL  the battery took TEST_FLAGS from the environment, or did not say so (${n26:-no} tests without it):"; grep -a -e '^battery:' -e '^test ' "$TMP/o730" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  FOUNDRY_MATCH_CONTRACT=AUnit FOUNDRY_NO_MATCH_TEST=test_inc "$HERE/battery.sh" "$M" > "$TMP/o731" 2>&1; check "battery with forge's own FOUNDRY_MATCH_CONTRACT / FOUNDRY_NO_MATCH_TEST in the environment" 0 $? "$TMP/o731"
  if [ -n "$n26" ] && grep -qx 'battery: ignoring FOUNDRY_MATCH_CONTRACT from the environment' "$TMP/o731" && grep -qx 'battery: ignoring FOUNDRY_NO_MATCH_TEST from the environment' "$TMP/o731" \
    && grep -Eq "^test +rc=0 +\(passed $n26, failed 0, skipped 0; filter: none\)$" "$TMP/o731"; then
    echo "  ok    and it names each one it ignored, and ran every test ($n26)"; else
    echo "  FAIL  forge's environment filters narrowed the battery, or were not named:"; grep -a -e '^battery:' -e '^test ' "$TMP/o731" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # ... and every OTHER way forge reads the environment (K24b, from a verifier's V24): the prefix in any case, dapptools'
  # DAPP_, a name that is not a shell identifier, and FORGE_ALLOW_FAILURE - each ran a narrower or weaker battery that
  # said BATTERY PASSED. By allowlist now: all removed, each named; the whole suite runs
  env 'FOUNDRY_FUZZ.RUNS=1' foundry_match_contract=AUnit DAPP_MATCH_CONTRACT=AUnit FORGE_ALLOW_FAILURE=true "$HERE/battery.sh" "$M" > "$TMP/o760" 2>&1
  check "battery with foundry_match_contract, DAPP_MATCH_CONTRACT, FOUNDRY_FUZZ.RUNS and FORGE_ALLOW_FAILURE in the environment" 0 $? "$TMP/o760"
  if [ -n "$n26" ] && grep -qx 'battery: ignoring foundry_match_contract from the environment' "$TMP/o760" \
    && grep -qx 'battery: ignoring DAPP_MATCH_CONTRACT from the environment' "$TMP/o760" && grep -qx 'battery: ignoring FOUNDRY_FUZZ.RUNS from the environment' "$TMP/o760" \
    && grep -qx 'battery: ignoring FORGE_ALLOW_FAILURE from the environment' "$TMP/o760" && grep -Eq "^test +rc=0 +\(passed $n26, failed 0, skipped 0; filter: none\)$" "$TMP/o760"; then
    echo "  ok    and it names each one it removed, and ran every test ($n26)"; else
    echo "  FAIL  the battery kept one, or did not name it:"; grep -a -e '^battery:' -e '^test ' "$TMP/o760" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  FOUNDRY_PROFILE=long "$HERE/battery.sh" "$M" > "$TMP/o761" 2>&1; check "battery with FOUNDRY_PROFILE=long (allowed)" 0 $? "$TMP/o761"
  if grep -qx 'battery: FOUNDRY_PROFILE=long from the environment (allowed)' "$TMP/o761" && grep -Eq '^profile +long \(FOUNDRY_PROFILE\)$' "$TMP/o761"; then
    echo "  ok    and the profile is named, at the top and in the summary"; else
    echo "  FAIL  the allowed profile is not named:"; grep -a -e '^battery:' -e '^profile' "$TMP/o761" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # a .env in the project: forge loads it (the same effect, measured), the battery cannot remove it - refused, by name
  printf 'export FOUNDRY_MATCH_CONTRACT = AUnit\n' > "$M/.env"
  "$HERE/battery.sh" "$M" > "$TMP/o762" 2>&1; check "battery with a .env that sets FOUNDRY_MATCH_CONTRACT is refused" 1 $? "$TMP/o762"
  if grep -q '^battery: .*/\.env sets FOUNDRY_MATCH_CONTRACT, which forge loads' "$TMP/o762" && ! grep -q '^== build' "$TMP/o762"; then
    echo "  ok    and it names the variable and the file, before building anything"; else
    echo "  FAIL  the .env refusal:"; grep -a -e '^battery:' -e '^BATTERY' "$TMP/o762" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -f "$M/.env"
  # ... saved with a UTF-8 byte-order mark and CR LF (Notepad's): forge reads the key behind the mark, and the check read
  # past it (V24b: BATTERY PASSED on 5 tests of 107). Read as forge reads it now
  printf '\357\273\277FOUNDRY_MATCH_CONTRACT = AUnit\r\n' > "$M/.env"
  "$HERE/battery.sh" "$M" > "$TMP/o780" 2>&1; check "battery with a .env saved with a BOM and CR LF that sets FOUNDRY_MATCH_CONTRACT is refused" 1 $? "$TMP/o780"
  if grep -q '^battery: .*/\.env sets FOUNDRY_MATCH_CONTRACT, which forge loads' "$TMP/o780" && ! grep -q '^== build' "$TMP/o780"; then
    echo "  ok    and it names the variable behind the byte-order mark"; else
    echo "  FAIL  the .env with a BOM was not refused by name:"; grep -a -e '^battery:' -e '^BATTERY' "$TMP/o780" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -f "$M/.env"
  # FORGE_FLAGS is printed (a filter in it narrows the run), never the value after a flag that carries an endpoint or a key
  ff_shown="$(. "$HERE/lib/forge-env.sh" && forge_flags_shown "--offline --fork-url https://K25-A/x --rpc-url=https://K25-B -r K25-C -rK25-D --etherscan-api-key K25-E --private-key=K25-F --match-contract AUnit")"
  if [ "$ff_shown" = "--offline --fork-url <set> --rpc-url=<set> -r <set> -r<set> --etherscan-api-key <set> --private-key=<set> --match-contract AUnit" ]; then
    echo "  ok    FORGE_FLAGS as printed: every endpoint and key is <set>, every other flag as it is"; else
    echo "  FAIL  FORGE_FLAGS as printed: $ff_shown"; fails=$((fails + 1)); fi
  FWS="$TMP/fws"; mkdir -p "$FWS"
  # a forge that drops those flags (they would reach the network) and runs the real one with the rest
  cat > "$FWS/forge" << 'EOF'
#!/usr/bin/env bash
a=(); skip=0
for x in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$x" in --fork-url | --rpc-url | --etherscan-api-key | --private-key | -[a-z]*r) skip=1; continue ;; --fork-url=* | --rpc-url=* | --etherscan-api-key=* | --private-key=* | -[a-z]*r?*) continue ;; esac
  a+=("$x")
done
exec "$K25_REAL_FORGE" "${a[@]}"
EOF
  chmod +x "$FWS/forge"
  K25_REAL_FORGE="$(command -v forge)" PATH="$FWS:$PATH" FORGE_FLAGS="--offline --fork-url https://K25SENTINEL.example/key --private-key=K25SENTINEL" \
    "$HERE/battery.sh" "$M" > "$TMP/o781" 2>&1; check "battery with an endpoint and a key in FORGE_FLAGS" 0 $? "$TMP/o781"
  if ! grep -q K25SENTINEL "$TMP/o781" && grep -qx 'battery: FORGE_FLAGS=--offline --fork-url <set> --private-key=<set> from the environment (allowed)' "$TMP/o781" \
    && grep -q 'FORGE_FLAGS: --offline --fork-url <set> --private-key=<set>)$' "$TMP/o781" && grep -q '^decision: forge build --offline --fork-url <set>' "$TMP/o781"; then
    echo "  ok    and neither value is printed anywhere in its output: the flags are, with <set>"; else
    echo "  FAIL  a value from FORGE_FLAGS was printed, or the flags were not:"; grep -a -e K25SENTINEL -e 'FORGE_FLAGS' -e '^decision' "$TMP/o781" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # ... by its SHAPE, not by the flag's spelling: forge takes grouped short flags (`-vr <url>` is --rpc-url), and a list
  # of names printed those (V25). A word with ://, a word that is 0x and 64 hex digits, the value of a group with an r
  hx="0x$(printf 'ab%.0s' $(seq 32))"
  ff_shown="$(. "$HERE/lib/forge-env.sh" && forge_flags_shown "-vr https://K25B-A/x -sr K25B-B -vrK25B-C -vvvr=K25B-D wss://K25B-E/k --sender $hx --some-url=https://K25B-F -j 2 --match-test test_a -vvv ${hx%?}")"
  if [ "$ff_shown" = "-vr <set> -sr <set> -vr<set> -vvvr<set> <set> --sender <set> --some-url=<set> -j 2 --match-test test_a -vvv ${hx%?}" ]; then
    echo "  ok    FORGE_FLAGS as printed, by shape: grouped short flags with r, a URL, a 64-hex word are <set>; the rest as it is"; else
    echo "  FAIL  FORGE_FLAGS as printed, by shape: $ff_shown"; fails=$((fails + 1)); fi
  K25_REAL_FORGE="$(command -v forge)" PATH="$FWS:$PATH" FORGE_FLAGS="--offline -vr https://K25SENTINEL.example/key" \
    "$HERE/battery.sh" "$M" > "$TMP/o797" 2>&1; check "battery with -vr <endpoint> in FORGE_FLAGS" 0 $? "$TMP/o797"
  if ! grep -q K25SENTINEL "$TMP/o797" && grep -qx 'battery: FORGE_FLAGS=--offline -vr <set> from the environment (allowed)' "$TMP/o797" \
    && grep -q 'FORGE_FLAGS: --offline -vr <set>)$' "$TMP/o797" && grep -q '^decision: forge build --offline -vr <set>' "$TMP/o797"; then
    echo "  ok    and the endpoint is printed nowhere in its output"; else
    echo "  FAIL  the endpoint after -vr was printed:"; grep -a -e K25SENTINEL -e 'FORGE_FLAGS' -e '^decision' "$TMP/o797" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # a line break in FORGE_FLAGS: forge gets every line, what printed it showed the first (V25: "long fuzz passed (...;
  # FORGE_FLAGS: --offline)" over 1 invariant of 6, the filter on the second line). Refused by every script that reads
  # it: rc 2, one line, the variable named and never its value
  nlf=$'--offline\n--match-contract AUnit --fork-url https://K25SENTINEL.example/key'
  n=798
  for sc in battery fuzz-long census mutate assert-fresh-build size; do
    case "$sc" in
      mutate) FORGE_FLAGS="$nlf" LABEL=m25b OUT_DIR="$TMP/mut" EXPECT=green "$HERE/mutate.sh" "$M" "src/A.sol" "x++;" "x += 1;" > "$TMP/o$n" 2>&1 ;;
      size) FORGE_FLAGS="$nlf" OUT_DIR="$TMP/sz25b" "$HERE/size.sh" "$M" > "$TMP/o$n" 2>&1 ;;
      fuzz-long) FORGE_FLAGS="$nlf" USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o$n" 2>&1 ;;
      *) FORGE_FLAGS="$nlf" "$HERE/$sc.sh" "$M" > "$TMP/o$n" 2>&1 ;;
    esac
    check "$sc.sh with a line break in FORGE_FLAGS: refused" 2 $? "$TMP/o$n"
    if [ "$(wc -l < "$TMP/o$n" | tr -d ' ')" = 1 ] && grep -q "^$sc: FORGE_FLAGS holds a line break" "$TMP/o$n" && ! grep -q -e K25SENTINEL -e AUnit "$TMP/o$n"; then
      echo "  ok    in one line that names FORGE_FLAGS and prints none of its value"; else
      echo "  FAIL  the refusal:"; sed "s/^/        | /" "$TMP/o$n"; fails=$((fails + 1)); fi
    n=$((n + 1))
  done
  FORGE_FLAGS=$'--offline\r--match-contract AUnit' "$HERE/battery.sh" "$M" > "$TMP/o804" 2>&1; check "battery with a CR in FORGE_FLAGS: refused" 2 $? "$TMP/o804"
  # a build cache written at ANOTHER path (the project copied with its out/ and cache/, V24b): forge's incremental build
  # there recompiled the changed source without the test file that derives from it (recorded by absolute path) and the
  # tests ran the OLD code - a unit test and an invariant green over a broken B, and the freshness check rc 0. Here only
  # the derived contract (BMock) sees B, so nothing else can catch it
  MK="$TMP/mockp"; mkdir -p "$MK/src" "$MK/test" "$MK/.gauntlet";   # .gauntlet/: the convention installed (K26c)
  ln -s "$(cd "$KIT/lib" && pwd -P)" "$MK/lib"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n[invariant]\nruns = 4\ndepth = 4\nfail_on_revert = true\n[profile.long.invariant]\nruns = 8\ndepth = 8\nfail_on_revert = true\n' > "$MK/foundry.toml"
  printf 'pragma solidity ^0.8.26;\ncontract B { uint256 public x; function add() external { x += 2; } }\n' > "$MK/src/B.sol"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/B.sol";\ncontract BMock is B {}\ncontract BUnit is Test { function test_add() public { B b = new BMock(); b.add(); assertEq(b.x(), 2); } }\ncontract BInvariant is Test { B b; function setUp() public { b = new BMock(); targetContract(address(b)); } function invariant_even() public view { assertEq(b.x() %% 2, 0); } }\n' > "$MK/test/B.t.sol"
  (cd "$MK" && forge build > "$TMP/o782.build" 2>&1)
  moved() { rm -rf "$TMP/mockp-moved"; cp -a "$MK" "$TMP/mockp-moved"; sed -i 's/x += 2;/x += 3;/' "$TMP/mockp-moved/src/B.sol"; }
  moved; "$HERE/battery.sh" "$TMP/mockp-moved" > "$TMP/o782" 2>&1; check "battery on a project copied with its build to another path, then broken: BATTERY FAILED" 1 $? "$TMP/o782"
  if grep -q "^battery: forge's cache was written at another path (/.*/mockp/test/B\.t\.sol)" "$TMP/o782" && grep -Eq '^test +rc=1 +\(passed [0-9]+, failed [1-9]' "$TMP/o782"; then
    echo "  ok    and it says so in a line, builds from nothing, and the tests see the broken code"; else
    echo "  FAIL  the battery ran the old code, or did not say why it rebuilt:"; grep -a -e '^battery:' -e '^test ' -e '^freshness' "$TMP/o782" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  moved; USE_BENCH=0 "$HERE/fuzz-long.sh" "$TMP/mockp-moved" > "$TMP/o783" 2>&1; check "fuzz-long (USE_BENCH=0) on the same copy: LONG FUZZ FAILED" 1 $? "$TMP/o783"
  grep -q "^fuzz-long: forge's cache was written at another path" "$TMP/o783" || { echo "  FAIL  and fuzz-long.sh does not say why it built from nothing"; fails=$((fails + 1)); }
  # (this toy writes no census: rc 2, NOTHING MEASURED either way - what tells the two apart is the campaign's own verdict)
  moved; "$HERE/census.sh" "$TMP/mockp-moved" > "$TMP/o784" 2>&1; check "census.sh on the same copy (a toy with no census)" 2 $? "$TMP/o784"
  if grep -q "^census: forge's cache was written at another path" "$TMP/o784" && grep -q '^census: the campaign itself FAILED (rc=1)' "$TMP/o784"; then
    echo "  ok    and it says why it built from nothing, and the campaign FAILED on the broken code"; else
    echo "  FAIL  census.sh ran the old code, or did not say why it rebuilt:"; grep -a '^census:' "$TMP/o784" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -rf "$TMP/mockp-moved"; cp -a "$MK" "$TMP/mockp-moved"
  "$HERE/assert-fresh-build.sh" "$TMP/mockp-moved" > "$TMP/o785" 2>&1; check "the freshness check on a copy with a cache written at another path: STALE, rebuilt from nothing" 1 $? "$TMP/o785"
  grep -q '^STALE BUILD: the artifacts in out came with a cache written at another path' "$TMP/o785" || { echo "  FAIL  and it does not say why"; fails=$((fails + 1)); }
  "$HERE/assert-fresh-build.sh" "$TMP/mockp-moved" > "$TMP/o786" 2>&1; check "and the next run is FRESH (the cache is this path's now)" 0 $? "$TMP/o786"
  rm -rf "$TMP/mockp-moved"
  # ... copied one level UP (built in nest/inner, `cp -a inner/. nest/`): the path forge recorded, nest/inner/test/B.t.sol,
  # is UNDER the project, and "outside it?" said no (V25: BATTERY PASSED, freshness rc 0, over a broken B). The question is
  # "exactly <project>/<that file's key in the cache>?"
  NST="$TMP/nest"; mkdir -p "$NST/.gauntlet"; cp -a "$MK" "$NST/inner"; rm -rf "$NST/inner/cache" "$NST/inner/out"
  (cd "$NST/inner" && forge build > "$TMP/o793.build" 2>&1)
  cp -a "$NST/inner/." "$NST/"; sed -i 's/x += 2;/x += 3;/' "$NST/src/B.sol"
  "$HERE/battery.sh" "$NST" > "$TMP/o793" 2>&1; check "battery on a project built one directory down and copied up into it, then broken: BATTERY FAILED" 1 $? "$TMP/o793"
  if grep -q "^battery: forge's cache was written at another path (/.*/nest/inner/test/B\.t\.sol)" "$TMP/o793" && grep -Eq '^test +rc=1 +\(passed [0-9]+, failed [1-9]' "$TMP/o793"; then
    echo "  ok    and it says so, builds from nothing, and the tests see the broken code"; else
    echo "  FAIL  the battery ran the old code, or did not say why it rebuilt:"; grep -a -e '^battery:' -e '^test ' -e '^freshness' "$TMP/o793" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -rf "$NST"
  # and the project where it was built, reached through a symlink (forge and this check both see the real path): quiet
  ln -s "$MK" "$TMP/mockp-link"
  "$HERE/battery.sh" "$TMP/mockp-link" > "$TMP/o794" 2>&1; check "battery on the project where it was built, through a symlink" 0 $? "$TMP/o794"
  grep -q "written at another path" "$TMP/o794" && { echo "  FAIL  and it took its own cache for another path's"; fails=$((fails + 1)); }
  rm -f "$TMP/mockp-link"
  # a project with its own cache_path: the freshness check read cache/ always and said NO CACHE, and the battery failed
  # on every run (V25)
  FCP="$TMP/fcache-p"; mkdir -p "$FCP/src" "$FCP/test" "$FCP/.gauntlet"; ln -s "$(cd "$KIT/lib" && pwd -P)" "$FCP/lib"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\ncache_path = "fcache"\n' > "$FCP/foundry.toml"
  printf 'pragma solidity ^0.8.26;\ncontract C { function f() external pure returns (uint256) { return 1; } }\n' > "$FCP/src/C.sol"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/C.sol";\ncontract CUnit is Test { function test_f() public { assertEq(new C().f(), 1); } }\n' > "$FCP/test/C.t.sol"
  "$HERE/battery.sh" "$FCP" > "$TMP/o795" 2>&1; check "battery on a project whose cache_path is fcache" 0 $? "$TMP/o795"
  grep -Eq '^freshness rc=0 ' "$TMP/o795" || { echo "  FAIL  and its freshness line is not rc=0"; fails=$((fails + 1)); }
  "$HERE/assert-fresh-build.sh" "$FCP" > "$TMP/o796" 2>&1; check "the freshness check on it, alone: FRESH" 0 $? "$TMP/o796"
  grep -q '^evidence: cache fcache/solidity-files-cache.json' "$TMP/o796" || { echo "  FAIL  and it did not read fcache/"; fails=$((fails + 1)); }
  rm -rf "$FCP"
  # what the build READ (K27): forge 1.8.1 links tests to sources dynamically, and after a change that keeps a source's
  # interface it recompiles the source and not the tests - right for a plain file under src/ imported by path, wrong for
  # the rest: the tests ran the OLD code, no copy anywhere, and the freshness check said FRESH. Measured on the root kit
  # with src/ a symlink (BATTERY PASSED 107 over a mutant that fails 3 suites) and on toys of the v4 module's shape (the
  # v4 module itself was judged right: its suites derive from what they use). The kit's record of what the build read decides.
  rk_toy() { # rk_toy <dir> <import of B in the test>: a toy whose unit test and invariant new B() and read x
    mkdir -p "$1/src" "$1/test" "$1/.gauntlet"; ln -s "$(cd "$KIT/lib" && pwd -P)" "$1/lib"
    printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n%s\n[invariant]\nruns = 4\ndepth = 4\nfail_on_revert = true\n[profile.long.invariant]\nruns = 8\ndepth = 8\nfail_on_revert = true\n' "${3:-}" > "$1/foundry.toml"
    printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "%s";\ncontract BUnit is Test { function test_add() public { B b = new B(); b.add(); assertEq(b.x(), 2); } }\ncontract BInvariant is Test { B b; function setUp() public { b = new B(); targetContract(address(b)); } function invariant_even() public view { assertEq(b.x() %% 2, 0); } }\n' "$2" > "$1/test/B.t.sol"
  }
  rk_b() { printf 'pragma solidity ^0.8.26;\ncontract B { uint256 public x; function add() external { x += %s; } }\n' "$2" > "$1"; }
  # (a) the v4 module's shape: the source outside the project, through a remapping (kit/=../ext/), new'd by the test
  RK="$TMP/rk-remap"; mkdir -p "$RK/ext"; rk_toy "$RK/p" kit/B.sol 'allow_paths = ["../ext"]'; echo 'kit/=../ext/' > "$RK/p/remappings.txt"; rk_b "$RK/ext/B.sol" 2
  "$HERE/battery.sh" "$RK/p" > "$TMP/o827" 2>&1; check "battery on a project whose test news a source outside it, through a remapping" 0 $? "$TMP/o827"
  rk_b "$RK/ext/B.sol" 3
  "$HERE/battery.sh" "$RK/p" > "$TMP/o828" 2>&1; check "the same battery after that source is broken: BATTERY FAILED (it ran the old code: BATTERY PASSED)" 1 $? "$TMP/o828"
  if grep -q '^battery: \.\./ext/B\.sol changed since the last build the kit recorded.*outside this project: .*Its record cache/solidity-files-cache\.json is removed, so this build is from nothing\.$' "$TMP/o828" \
    && grep -Eq '^test +rc=1 +\(passed [0-9]+, failed [1-9]' "$TMP/o828" && grep -q '^cache     \.\./ext/B\.sol changed, where forge.s incremental build is not trusted: its record removed' "$TMP/o828"; then
    echo "  ok    and one line names the file and why, it builds from nothing, and the tests see the broken code"; else
    echo "  FAIL  the battery ran the old code, or did not say why it rebuilt:"; grep -a -e '^battery:' -e '^test ' -e '^cache ' "$TMP/o828" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # (a trusted build of the good B - recorded - then the break, then a plain `forge build`: forge says nothing is left)
  rk_reset() { rk_b "$RK/ext/B.sol" 2; "$HERE/battery.sh" "$RK/p" > /dev/null 2>&1; rk_b "$RK/ext/B.sol" 3; (cd "$RK/p" && forge build > /dev/null 2>&1); }
  rk_reset; USE_BENCH=0 "$HERE/fuzz-long.sh" "$RK/p" > "$TMP/o829" 2>&1; check "fuzz-long (USE_BENCH=0) after the same break and a forge build: LONG FUZZ FAILED" 1 $? "$TMP/o829"
  grep -q '^fuzz-long: \.\./ext/B\.sol changed since the last build the kit recorded' "$TMP/o829" || { echo "  FAIL  and fuzz-long.sh does not say why it built from nothing"; fails=$((fails + 1)); }
  rk_reset; "$HERE/census.sh" "$RK/p" > "$TMP/o830" 2>&1; check "census.sh after the same break (a toy with no census)" 2 $? "$TMP/o830"
  if grep -q '^census: \.\./ext/B\.sol changed since the last build the kit recorded' "$TMP/o830" && grep -q '^census: the campaign itself FAILED (rc=1)' "$TMP/o830"; then
    echo "  ok    and it says why it built from nothing, and the campaign FAILED on the broken code"; else
    echo "  FAIL  census.sh ran the old code, or did not say why it rebuilt:"; grep -a '^census:' "$TMP/o830" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rk_reset; "$HERE/assert-fresh-build.sh" "$RK/p" > "$TMP/o831" 2>&1; check "the freshness check after the break and a forge build (forge: 'No files changed'): STALE, rebuilt from nothing" 1 $? "$TMP/o831"
  grep -q '^evidence: \.\./ext/B\.sol changed since the last build the kit recorded' "$TMP/o831" || { echo "  FAIL  and it does not say why"; fails=$((fails + 1)); }
  "$HERE/assert-fresh-build.sh" "$RK/p" > "$TMP/o832" 2>&1; check "and the next run is FRESH (recorded)" 0 $? "$TMP/o832"
  rm -rf "$RK"
  # (b) src/ a symlink (V25b's shape, and the root kit's with src linked): battery, break B through the link, battery
  RK="$TMP/rk-link"; mkdir -p "$RK/shared"; rk_toy "$RK/p" ../src/B.sol; rmdir "$RK/p/src"; ln -s "$RK/shared" "$RK/p/src"; rk_b "$RK/shared/B.sol" 2
  "$HERE/battery.sh" "$RK/p" > "$TMP/o833" 2>&1; check "battery on a project whose src/ is a symlink" 0 $? "$TMP/o833"
  "$HERE/battery.sh" "$RK/p" > "$TMP/o834" 2>&1; check "and again, nothing changed" 0 $? "$TMP/o834"
  grep -q 'changed since the last build\|no record of what' "$TMP/o834" && { echo "  FAIL  and it rebuilt from nothing with nothing changed"; fails=$((fails + 1)); }
  rk_b "$RK/shared/B.sol" 3
  "$HERE/battery.sh" "$RK/p" > "$TMP/o835" 2>&1; check "the same battery after B is broken through the link: BATTERY FAILED" 1 $? "$TMP/o835"
  if grep -q '^battery: .*B\.sol changed since the last build the kit recorded' "$TMP/o835" && grep -Eq '^test +rc=1 +\(passed [0-9]+, failed [1-9]' "$TMP/o835"; then
    echo "  ok    and it says which file, builds from nothing, and the tests see the broken code"; else
    echo "  FAIL  the battery ran the old code, or did not say why:"; grep -a -e '^battery:' -e '^test ' "$TMP/o835" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -rf "$RK"
  # (c) src/ imported through a remapping into it (app/=src/): the same, for a plain file under src/
  RK="$TMP/rk-app"; rk_toy "$RK" app/B.sol; echo 'app/=src/' > "$RK/remappings.txt"; rk_b "$RK/src/B.sol" 2
  "$HERE/battery.sh" "$RK" > /dev/null 2>&1; rk_b "$RK/src/B.sol" 3
  "$HERE/battery.sh" "$RK" > "$TMP/o836" 2>&1; check "battery after a break in src/B.sol, which the test imports as app/B.sol: BATTERY FAILED" 1 $? "$TMP/o836"
  grep -q '^battery: src/B\.sol changed since the last build the kit recorded, and a remapping (app/=src/) reaches into src/' "$TMP/o836" || { echo "  FAIL  and it does not say why it rebuilt"; grep -a '^battery:' "$TMP/o836" | sed "s/^/        | /"; fails=$((fails + 1)); }
  rm -rf "$RK"
  # (d) what forge IS right for is left to it (the cost: no build from nothing on every edit): a plain src/B.sol imported
  # by path - the battery sees the break with an incremental build, and says nothing about the record
  RK="$TMP/rk-plain"; rk_toy "$RK" ../src/B.sol; rk_b "$RK/src/B.sol" 2
  (cd "$RK" && forge build > /dev/null 2>&1)
  "$HERE/battery.sh" "$RK" > "$TMP/o837" 2>&1; check "battery on a project forge built, with no record of what that build read" 0 $? "$TMP/o837"
  grep -q "^battery: there is no record of what forge's last build here read" "$TMP/o837" || { echo "  FAIL  and it did not build from nothing, or did not say why"; fails=$((fails + 1)); }
  rk_b "$RK/src/B.sol" 3
  "$HERE/battery.sh" "$RK" > "$TMP/o838" 2>&1; check "the battery after a break in a plain src/B.sol: BATTERY FAILED, incrementally" 1 $? "$TMP/o838"
  if ! grep -q 'changed since the last build\|no record of what' "$TMP/o838" && grep -Eq '^test +rc=1 +\(passed [0-9]+, failed [1-9]' "$TMP/o838"; then
    echo "  ok    and without a build from nothing"; else
    echo "  FAIL  it rebuilt from nothing, or ran the old code:"; grep -a -e '^battery:' -e '^test ' "$TMP/o838" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -rf "$RK"
  # (e) the record hashes with SHA-256 (K29). It was POSIX cksum - a CRC and a size - and a mutant with twelve chosen
  # characters in a revert string had the original's cksum: BATTERY PASSED over code that fails (V28, the root kit with
  # src/ a symlink). The pair below has one cksum (checked here, or the case proves nothing)
  rk_rs() { printf 'pragma solidity ^0.8.26;\ncontract B { uint256 public x; function add() external { x += %s; require(x < 1000000, "%s"); } }\n' "$2" "$3" > "$1"; }
  RK="$TMP/rk-crc"; mkdir -p "$RK/shared"; rk_toy "$RK/p" ../src/B.sol; rmdir "$RK/p/src"; ln -s "$RK/shared" "$RK/p/src"
  rk_rs "$RK/shared/B.sol" 2 '@@@@@@@@@@@@'; cp "$RK/shared/B.sol" "$RK/good.sol"
  "$HERE/battery.sh" "$RK/p" > "$TMP/o890" 2>&1; check "battery on a project whose src/ is a symlink (before the CRC forgery)" 0 $? "$TMP/o890"
  rk_rs "$RK/shared/B.sol" 3 'HJMNIHF@A@@@'
  if [ "$(cksum < "$RK/good.sol")" = "$(cksum < "$RK/shared/B.sol")" ] && ! cmp -s "$RK/good.sol" "$RK/shared/B.sol"; then
    echo "  ok    the forged B.sol has the good one's cksum (CRC and size), and other bytes"; else
    echo "  FAIL  the forged B.sol does not have the good one's cksum: the next check proves nothing"; fails=$((fails + 1)); fi
  "$HERE/battery.sh" "$RK/p" > "$TMP/o891" 2>&1; check "the same battery over the CRC-forged B.sol (V28: BATTERY PASSED on a cksum record): BATTERY FAILED" 1 $? "$TMP/o891"
  if grep -q '^battery: .*B\.sol changed since the last build the kit recorded' "$TMP/o891" && grep -Eq '^test +rc=1 +\(passed [0-9]+, failed [1-9]' "$TMP/o891"; then
    echo "  ok    and it says which file, builds from nothing, and the tests see the forged code"; else
    echo "  FAIL  the battery ran the old code over the forgery, or did not say why:"; grep -a -e '^battery:' -e '^test ' "$TMP/o891" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # a record written by an older kit (v0.2's cksum record), or in no format this kit writes, is read as none: one build
  # from nothing, one line saying why - then the record is this kit's, and the next run builds nothing from scratch
  cp "$RK/good.sol" "$RK/shared/B.sol"; "$HERE/battery.sh" "$RK/p" > /dev/null 2>&1
  REC="$RK/p/cache/gauntlet-sources.tsv"
  # (captured, then matched: a pipeline into `grep -q` under pipefail can lose its writer to SIGPIPE and read false, K62)
  rk_head="$(head -1 "$REC" 2> /dev/null)"; rk_bad="$(grep -v '^#' "$REC" 2> /dev/null | grep -cvE "^[0-9a-f]{64}$(printf '\t').")"
  if [[ $rk_head == '# hook-gauntlet sources record 2, sha256 ('* ]] && [ "$rk_bad" = 0 ]; then
    echo "  ok    the record says what it is and how it hashes, and holds a SHA-256 per file"; else
    echo "  FAIL  the record is not '# hook-gauntlet sources record 2, sha256 (...)' with a SHA-256 per file:"; sed "s/^/        | /" "$REC"; fails=$((fails + 1)); fi
  { echo "# hook-gauntlet: the sources forge's build here read (not test/ or script/), and their content (cksum) when it started."
    echo "# Written by the kit after a build it trusts (scripts/lib/forge-env.sh, forge_sources_record); compared before the next."
    grep -v '^#' "$REC" | cut -f2 | (cd "$RK/p" && while IFS= read -r k; do printf '%s\t%s\n' "$(cksum < "$k")" "$k"; done); } > "$RK/old.tsv"
  cp "$RK/old.tsv" "$REC"
  "$HERE/battery.sh" "$RK/p" > "$TMP/o892" 2>&1; check "battery with a record an older kit wrote (cksum)" 0 $? "$TMP/o892"
  if grep -q "^battery: the record of what forge's last build here read (.*) was written by an older kit with cksum, a CRC that a deliberate edit can match .*read as no record.* Its record cache/solidity-files-cache\.json is removed, so this build is from nothing\.$" "$TMP/o892" \
    && [ "$(grep -c '^battery: ' "$TMP/o892")" -ge 1 ] && [[ "$(head -1 "$REC")" == '# hook-gauntlet sources record 2, sha256 ('* ]]; then
    echo "  ok    one build from nothing, one line saying why, and the record rewritten in SHA-256"; else
    echo "  FAIL  an older kit's cksum record was trusted, or the rebuild did not say why:"; grep -a -e '^battery:' -e '^cache ' "$TMP/o892" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  "$HERE/battery.sh" "$RK/p" > "$TMP/o893" 2>&1; check "and the next battery, nothing changed" 0 $? "$TMP/o893"
  grep -q 'changed since the last build\|no record\|read as no record' "$TMP/o893" && { echo "  FAIL  and it built from nothing again"; fails=$((fails + 1)); }
  printf 'a record of no known shape\n' > "$REC"
  "$HERE/assert-fresh-build.sh" "$RK/p" > "$TMP/o894" 2>&1; check "the freshness check alone with a record in no format this kit writes (read as none: forge decides)" 0 $? "$TMP/o894"
  grep -q "^evidence: the record of what forge's last build here read (.*) is not in the format this kit writes" "$TMP/o894" \
    || { echo "  FAIL  and it does not say the record was read as none:"; grep -a '^evidence:' "$TMP/o894" | sed "s/^/        | /"; fails=$((fails + 1)); }
  # sha256_of: sha256sum, else `shasum -a 256`, else `openssl dgst -sha256` - the same digests, in the order given, a
  # missing file skipped - else refused, naming the three (never a weaker hash). Each tool alone on a PATH of its own
  SD="$TMP/sha-files"; mkdir -p "$SD"; printf 'one\n' > "$SD/a.sol"; printf 'two\n' > "$SD/b c.sol"; printf 'three\n' > "$SD/-d.sol"
  printf 'four\n' > "$SD/e\\f.sol"
  sha_list() { printf '%s\n' "$SD/a.sol" "$SD/missing.sol" "$SD/b c.sol" "-d.sol" "$SD/e\\f.sol"; }
  for tool in sha256sum shasum openssl none; do
    TB="$TMP/sha-path-$tool"; mkdir -p "$TB"
    for t in xargs sed grep env perl "$tool"; do
      [ "$t" != none ] || continue; p="$(command -v "$t" 2> /dev/null)" || continue; case "$p" in /*) ln -sf "$p" "$TB/$t" ;; esac
    done
    if [ "$tool" != none ] && [ ! -e "$TB/$tool" ]; then echo "  --    $tool is not here: sha256_of with $tool alone NOT run on this machine"; continue; fi
    (cd "$SD" && sha_list | PATH="$TB" "$BASH" -c '. "$1"; sha256_of; echo "rc=$?"; echo "tool=$FORGE_SHA256_TOOL"' _ "$HERE/lib/forge-env.sh") > "$TMP/o895-$tool" 2>&1
  done
  sed -n '/^rc=/!p' "$TMP/o895-sha256sum" | grep -v '^tool=' > "$TMP/o895-ref"
  if [ "$(wc -l < "$TMP/o895-ref" | tr -d ' ')" = 4 ] && grep -q '^rc=0$' "$TMP/o895-sha256sum" \
    && [ "$(cut -f2 "$TMP/o895-ref" | tr '\n' '|')" = "$SD/a.sol|$SD/b c.sol|-d.sol|$SD/e\\f.sol|" ] \
    && [ "$(cut -f1 "$TMP/o895-ref" | sed -n 1p)" = "$(sha256sum < "$SD/a.sol" | cut -c1-64)" ]; then
    echo "  ok    sha256_of with sha256sum: a SHA-256 per file, in order, the missing one skipped"; else
    echo "  FAIL  sha256_of with sha256sum:"; sed "s/^/        | /" "$TMP/o895-sha256sum"; fails=$((fails + 1)); fi
  for tool in shasum openssl; do
    [ -f "$TMP/o895-$tool" ] || continue
    if grep -q '^rc=0$' "$TMP/o895-$tool" && grep -q "^tool=$tool" "$TMP/o895-$tool" && [ "$(grep -v '^rc=\|^tool=' "$TMP/o895-$tool")" = "$(cat "$TMP/o895-ref")" ]; then
      echo "  ok    sha256_of with $tool alone: the same lines as sha256sum's"; else
      echo "  FAIL  sha256_of with $tool alone does not give sha256sum's lines:"; sed "s/^/        | /" "$TMP/o895-$tool"; fails=$((fails + 1)); fi
  done
  if grep -q '^rc=2$' "$TMP/o895-none" && grep -q '^none of sha256sum, shasum or openssl is on this PATH' "$TMP/o895-none" && ! grep -qE '^[0-9a-f]{64}' "$TMP/o895-none"; then
    echo "  ok    sha256_of with none of the three: refused (rc 2), naming them"; else
    echo "  FAIL  sha256_of with none of the three was not refused naming them:"; sed "s/^/        | /" "$TMP/o895-none"; fails=$((fails + 1)); fi
  # ... and the judging scripts refuse to run without one: every command on PATH but the three
  NH="$TMP/nohash-bin"; mkdir -p "$NH"
  IFS=':' read -ra pdirs <<< "$PATH"
  for d in "${pdirs[@]}"; do
    case "$d" in /mnt/*|'') continue ;; esac
    for p in "$d"/*; do
      t="${p##*/}"; case "$t" in sha256sum|shasum|openssl) continue ;; esac
      [ -x "$p" ] && [ ! -e "$NH/$t" ] && ln -s "$p" "$NH/$t" 2> /dev/null
    done
  done
  PATH="$NH" "$HERE/battery.sh" "$RK/p" > "$TMP/o896" 2>&1; check "battery with none of sha256sum, shasum, openssl on PATH: refused" 1 $? "$TMP/o896"
  if grep -q '^battery: none of sha256sum, shasum or openssl is on this PATH.*Refused: nothing built\.$' "$TMP/o896" && ! grep -q '^== test' "$TMP/o896"; then
    echo "  ok    and it names the three, and builds and tests nothing"; else
    echo "  FAIL  and it does not name the three, or it ran:"; sed "s/^/        | /" "$TMP/o896" | head -20; fails=$((fails + 1)); fi
  PATH="$NH" "$HERE/assert-fresh-build.sh" "$RK/p" > "$TMP/o897" 2>&1; check "the freshness check with none of the three: nothing decided" 2 $? "$TMP/o897"
  grep -q '^CANNOT CHECK: none of sha256sum, shasum or openssl' "$TMP/o897" || { echo "  FAIL  and it does not name them"; fails=$((fails + 1)); }
  rm -rf "$RK" "$SD" "$NH" "$TMP"/sha-path-*
  # ~/.foundry/foundry.toml, the machine's configuration forge merges into every project's (a temporary HOME, never the
  # real one; the compilers linked from the real one). V24b: `skip` there, BATTERY PASSED on 86 of 107 with "filter:
  # none"; `match_test` there, "long fuzz passed" over 1 invariant of 6 and "VARIANT PASSED" over a variant that breaks 8
  GH="$TMP/ghome"; mkdir -p "$GH/.foundry"
  for d in .svm .local/share/svm "Library/Application Support/svm"; do
    if [ -e "$HOME/$d" ]; then mkdir -p "$GH/$(dirname "$d")"; ln -s "$HOME/$d" "$GH/$d"; fi
  done
  printf '[profile.default]\nno_match_contract = "K25GlobalValue"\n' > "$GH/.foundry/foundry.toml"
  HOME="$GH" "$HERE/battery.sh" "$M" > "$TMP/o787" 2>&1; check "battery with a filter in ~/.foundry/foundry.toml: BATTERY FAILED" 1 $? "$TMP/o787"
  if grep -q "^battery: $GH/.foundry/foundry.toml narrows the tests forge runs here (profile.default.no_match_contract)" "$TMP/o787" \
    && ! grep -q 'K25GlobalValue' "$TMP/o787" && ! grep -q '^== build' "$TMP/o787"; then
    echo "  ok    and it names the file and the key, never the value, before building anything"; else
    echo "  FAIL  the global filter was not refused by file and key, or its value was printed:"; grep -a -e '^battery:' -e 'K25GlobalValue' "$TMP/o787" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  printf '[fuzz]\nruns = 3\n' > "$GH/.foundry/foundry.toml"
  HOME="$GH" "$HERE/battery.sh" "$M" > "$TMP/o788" 2>&1; check "battery with a fuzz budget in ~/.foundry/foundry.toml (not a filter): it runs" 0 $? "$TMP/o788"
  if grep -q "^battery: $GH/.foundry/foundry.toml, forge's configuration for every project on this machine, changes this run's: fuzz.runs " "$TMP/o788" \
    && grep -q "^profile .*; and from $GH/.foundry/foundry.toml: fuzz.runs\$" "$TMP/o788"; then
    echo "  ok    and it names the file and the key, at the top and in the summary"; else
    echo "  FAIL  the global key was not named:"; grep -a -e '^battery:' -e '^profile' "$TMP/o788" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  HOME="$GH" USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o789" 2>&1; check "fuzz-long with the same file" 0 $? "$TMP/o789"
  grep -q "^long fuzz passed (filter: MATCH=--match-contract Invariant; from $GH/.foundry/foundry.toml: fuzz.runs)" "$TMP/o789" || {
    echo "  FAIL  fuzz-long.sh's verdict line does not name it:"; grep -a -e '^fuzz-long:' -e 'long fuzz passed' "$TMP/o789" | sed "s/^/        | /"; fails=$((fails + 1)); }
  HOME="$GH" "$HERE/census.sh" "$M" > "$TMP/o791" 2>&1
  grep -q "^census: $GH/.foundry/foundry.toml, forge's configuration for every project on this machine, changes this run's: fuzz.runs " "$TMP/o791" \
    && echo "  ok    census.sh names it" || { echo "  FAIL  census.sh does not name it"; fails=$((fails + 1)); }
  HOME="$GH" LABEL=m25 OUT_DIR="$TMP/mut" EXPECT=green TEST_FLAGS="--match-contract AUnit" "$HERE/mutate.sh" "$M" "src/A.sol" "x++;" "x += 1;" > "$TMP/o792" 2>&1
  check "mutate.sh with the same file" 0 $? "$TMP/o792"
  grep -qx "machine configuration: $GH/.foundry/foundry.toml changes fuzz.runs" "$TMP/o792" || { echo "  FAIL  and the mutant's header does not name it"; fails=$((fails + 1)); }
  # a failed test is never a pass, whatever forge exits with: a forge that exits 0 on `forge test` (what --allow-failure does)
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\ncontract AFails is Test { function test_fails_on_purpose() public pure { assertEq(uint256(1), 2, "red on purpose"); } }\n' > "$M/test/Fails.t.sol"
  PATH="$FW0:$PATH" "$HERE/battery.sh" "$M" > "$TMP/o763" 2>&1; check "battery, a forge that exits 0 over a failed test: BATTERY FAILED" 1 $? "$TMP/o763"
  if grep -q '^battery: forge exited 0, and 1 test(s) FAILED' "$TMP/o763" && grep -Eq '^test +rc=1 +\(passed [0-9]+, failed 1,' "$TMP/o763"; then
    echo "  ok    and it says forge exited 0 over a failed test"; else
    echo "  FAIL  the battery read forge's exit code, not the count:"; grep -a -e '^battery:' -e '^test ' "$TMP/o763" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  FORGE_ALLOW_FAILURE=true "$HERE/battery.sh" "$M" > "$TMP/o764" 2>&1; check "battery with FORGE_ALLOW_FAILURE=true over a failed test: BATTERY FAILED" 1 $? "$TMP/o764"
  grep -qx 'battery: ignoring FORGE_ALLOW_FAILURE from the environment' "$TMP/o764" || { echo "  FAIL  and FORGE_ALLOW_FAILURE is not named"; fails=$((fails + 1)); }
  rm -f "$M/test/Fails.t.sol"
  # a filter in the project's OWN foundry.toml is its configuration: not removed, but named - and one that matches nothing
  # is not a pass
  cp "$M/foundry.toml" "$TMP/mini.toml.filter"; sed -i 's/^libs = \["lib"\]$/&\nmatch_contract = "NoSuchContractAnywhere"/' "$M/foundry.toml"
  "$HERE/battery.sh" "$M" > "$TMP/o27" 2>&1
  check "battery with a filter that matches NOTHING (in the project's foundry.toml) is not a pass" 1 $? "$TMP/o27"
  if grep -Eq '^test +rc=1 .*filter: match_contract = "NoSuchContractAnywhere" \(the project.s foundry\.toml\)\)$' "$TMP/o27"; then
    echo "  ok    and the summary names that filter and where it came from"; else
    echo "  FAIL  the summary does not name the foundry.toml filter:"; grep -a '^test ' "$TMP/o27" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  cp "$TMP/mini.toml.filter" "$M/foundry.toml"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\ncontract Skipper is Test { function test_skipped() public { vm.skip(true); } }\n' > "$M/test/Skip.t.sol"
  "$HERE/battery.sh" "$M" > "$TMP/o28" 2>&1; check "battery with a SKIPPED test is not a pass" 1 $? "$TMP/o28"
  ALLOW_SKIPS=1 "$HERE/battery.sh" "$M" > "$TMP/o29" 2>&1; check "unless the skip is accepted on purpose" 0 $? "$TMP/o29"
  rm -f "$M/test/Skip.t.sol"

  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o30" 2>&1; check "long fuzz on a project that has the profile and a campaign" 0 $? "$TMP/o30"
  # K32 (FR16: four long campaigns of ~10 minutes and a shrink of ~10 more, the cost said only after - "far over my
  # estimate"): the long fuzz says what it will cost BEFORE the campaign - runs x depth, the everyday campaigns' measured
  # time (the battery's last log, just written above) scaled by calls, and what shrinking a failure adds
  fl_first="$(grep -n -m1 '^Ran [0-9]* test' "$TMP/o30" | cut -d: -f1)"; fl_cost="$(grep -n -m1 '^fuzz-long: what it will cost' "$TMP/o30" | cut -d: -f1)"
  if [ -n "$fl_cost" ] && [ -n "$fl_first" ] && [ "$fl_cost" -lt "$fl_first" ] \
    && grep -qF 'fuzz-long: what it will cost, said before it runs (AGENTS.md section 5): 8 runs x 8 depth = 64 calls per campaign, 4x the everyday 4 x 4' "$TMP/o30" \
    && grep -qE "^fuzz-long: the everyday campaigns took [0-9.]+ s in the battery's last log \(.*/02-test\.txt, [0-9]+ suite\(s\) with a campaign\): about [0-9.]+ (s|min) at 4x the calls" "$TMP/o30" \
    && grep -qE '^fuzz-long: a failure is then shrunk \(shrink_run_limit [0-9]+, about 10 minutes on a v4 hook measured\)' "$TMP/o30"; then
    echo "  ok    and before the campaign it said what it will cost: runs x depth, the everyday time scaled, the shrink"; else
    echo "  FAIL  the long fuzz did not say its cost before the campaign (cost line ${fl_cost:-none}, first test line ${fl_first:-none}):"
    grep -a '^fuzz-long:' "$TMP/o30" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  mv "$M/.gauntlet/reports/02-test.txt" "$TMP/02-test.keep"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o954" 2>&1; check "long fuzz with no battery log to scale from" 0 $? "$TMP/o954"
  if grep -q "^fuzz-long: no everyday time measured (no battery log at .*/02-test.txt with a campaign in it)" "$TMP/o954" \
    && grep -qF '8 runs x 8 depth = 64 calls per campaign' "$TMP/o954"; then
    echo "  ok    and there it says the time is not measured, not a guess"; else
    echo "  FAIL  with no battery log:"; grep -a '^fuzz-long:' "$TMP/o954" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  mv "$TMP/02-test.keep" "$M/.gauntlet/reports/02-test.txt"
  # K32b (V32): "say how long first" had no place to stop but Ctrl-C - the cost was printed and the campaign started in
  # the same breath. ESTIMATE_ONLY=1 says the cost and stops there: rc 0, no campaign, no bench, nothing written.
  fl_before="$(cksum < "$M/.gauntlet/reports/05-fuzz-long.txt" 2> /dev/null)"
  ESTIMATE_ONLY=1 "$HERE/fuzz-long.sh" "$M" > "$TMP/o967" 2>&1; check "fuzz-long with ESTIMATE_ONLY=1: the cost, and no campaign" 0 $? "$TMP/o967"
  if grep -qF 'fuzz-long: what it will cost, said before it runs (AGENTS.md section 5): 8 runs x 8 depth' "$TMP/o967" \
    && grep -q "^fuzz-long: the everyday campaigns took [0-9.]* s in the battery's last log" "$TMP/o967" && ! grep -q '^Ran [0-9]' "$TMP/o967" \
    && [ "$(tail -1 "$TMP/o967")" = "fuzz-long: ESTIMATE_ONLY=1 - the cost above, and no campaign: nothing was run, nothing written. The same command without it runs the campaign." ] \
    && [ "$(cksum < "$M/.gauntlet/reports/05-fuzz-long.txt" 2> /dev/null)" = "$fl_before" ] && [ -z "$(ls -d "$M/.gauntlet/bench/fuzz-long-"* 2> /dev/null)" ]; then
    echo "  ok    and it stops there: no test ran, no bench was made, the last log untouched, the last line says so"; else
    echo "  FAIL  ESTIMATE_ONLY=1 (benches: $(ls -d "$M/.gauntlet/bench/fuzz-long-"* 2> /dev/null | wc -l | tr -d ' ')):"; grep -a -e '^fuzz-long:' -e '^Ran ' "$TMP/o967" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # ... and a battery log whose campaign's time is of a shape not read here is not "no battery log with a campaign in it"
  mkdir -p "$TMP/garbled"; sed -E 's/finished in [0-9.]+(s|ms|µs|μs)/finished in 1.2m/' "$M/.gauntlet/reports/02-test.txt" > "$TMP/garbled/02-test.txt"
  ESTIMATE_ONLY=1 OUT_DIR="$TMP/garbled" "$HERE/fuzz-long.sh" "$M" > "$TMP/o968" 2>&1; check "fuzz-long's estimate over a battery log whose campaign time is unreadable" 0 $? "$TMP/o968"
  if grep -qF "fuzz-long: no everyday time measured (the battery's last log, $TMP/garbled/02-test.txt, has a campaign whose time is not of a shape read here): the long campaign's time is not guessed here" "$TMP/o968" \
    && ! grep -q 'with a campaign in it' "$TMP/o968"; then
    echo "  ok    and it says the time could not be read, not that there was no campaign"; else
    echo "  FAIL  the unreadable time:"; grep -a '^fuzz-long:' "$TMP/o968" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # K32c (V32b): any value but empty or 0 asks for the cost alone - `true` ran a real campaign
  ESTIMATE_ONLY=true "$HERE/fuzz-long.sh" "$M" > "$TMP/o970" 2>&1; check "fuzz-long with ESTIMATE_ONLY=true: the cost, and no campaign" 0 $? "$TMP/o970"
  if ! grep -q '^Ran [0-9]' "$TMP/o970" && [ "$(cksum < "$M/.gauntlet/reports/05-fuzz-long.txt" 2> /dev/null)" = "$fl_before" ] \
    && [ "$(tail -1 "$TMP/o970")" = "fuzz-long: ESTIMATE_ONLY=true - the cost above, and no campaign: nothing was run, nothing written. The same command without it runs the campaign." ] \
    && [ -z "$(ls -d "$M/.gauntlet/bench/fuzz-long-"* 2> /dev/null)" ]; then
    echo "  ok    and it stops there, as with 1: no test ran, no bench, the last log untouched"; else
    echo "  FAIL  ESTIMATE_ONLY=true ran something:"; grep -a -e '^fuzz-long:' -e '^Ran ' "$TMP/o970" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  USE_BENCH=0 FOUNDRY_PROFILE=nosuchprofile "$HERE/fuzz-long.sh" "$M" > "$TMP/o31" 2>&1
  check "a profile that does not exist proves nothing" 2 $? "$TMP/o31"
  USE_BENCH=0 MATCH="--match-contract NoSuchContractAnywhere" "$HERE/fuzz-long.sh" "$M" > "$TMP/o32" 2>&1
  check "a long fuzz in which no campaign ran proves nothing" 2 $? "$TMP/o32"
  # its filter is MATCH alone: forge's own FOUNDRY_MATCH_TEST from the environment narrowed it to nothing ("MATCH matched
  # nothing?", measured on HEAD 26966e8); ignored now, and said
  USE_BENCH=0 FOUNDRY_MATCH_TEST=no_test_is_named_this "$HERE/fuzz-long.sh" "$M" > "$TMP/o732" 2>&1
  check "a long fuzz with FOUNDRY_MATCH_TEST in the environment runs on MATCH alone" 0 $? "$TMP/o732"
  if grep -qx 'fuzz-long: ignoring FOUNDRY_MATCH_TEST from the environment' "$TMP/o732" && grep -q '^long fuzz passed (filter: MATCH=--match-contract Invariant)' "$TMP/o732"; then
    echo "  ok    and it says it ignored it, and its verdict line names the filter it ran with"; else
    echo "  FAIL  fuzz-long.sh did not name the ignored variable or its own filter:"; grep -a -e '^fuzz-long:' -e 'long fuzz passed' "$TMP/o732" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # forge FAILS and no campaign ran: a build error is not a counterexample
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../nowhere/Missing.sol";\ncontract Broken is Test { function test_b() public {} }\n' > "$M/test/Broken.t.sol"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o135" 2>&1
  check "a long fuzz whose build fails proves nothing (never a counterexample)" 2 $? "$TMP/o135"
  if grep -q "NOTHING PROVEN" "$TMP/o135" && grep -q 'first error: .*nowhere/Missing.sol' "$TMP/o135" && ! grep -q "counterexample and the seed" "$TMP/o135"; then
    echo "  ok    and it names the compile error, and says nothing about a counterexample"; else
    echo "  FAIL  fuzz-long.sh reported a build failure as something else:"; grep -E "fuzz-long|LONG FUZZ|first error" "$TMP/o135" | head -4 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -f "$M/test/Broken.t.sol"
  # USE_BENCH=1 on a project that imports from its PARENT (the v4 module's shape): the bench must hold the parent
  TL="$TMP/twolevel"; mkdir -p "$TL/src" "$TL/child/src" "$TL/child/test" "$TL/child/.gauntlet"   # the convention installed in the child (K26c: the log goes there)
  ln -s "$(cd "$KIT/lib" && pwd -P)" "$TL/lib"; ln -s "$(cd "$KIT/lib" && pwd -P)" "$TL/child/lib"
  printf '[profile.default]\n' > "$TL/foundry.toml"
  printf 'pragma solidity ^0.8.26;\ncontract Base { uint256 public x; function inc() external { x++; } }\n' > "$TL/src/Base.sol"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\nallow_paths = ["../src"]\nremappings = ["parent/=../src/"]\n[invariant]\nruns = 4\ndepth = 4\nfail_on_revert = true\n[profile.long.invariant]\nruns = 8\ndepth = 8\nfail_on_revert = true\n' > "$TL/child/foundry.toml"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "parent/Base.sol";\ncontract ChildInvariant is Test { Base b; function setUp() public { b = new Base(); targetContract(address(b)); } function invariant_x() public view { assertGe(b.x(), 0); } }\n' > "$TL/child/test/C.t.sol"
  BENCH_ROOT="$TMP/fzb" "$HERE/fuzz-long.sh" "$TL/child" > "$TMP/o136" 2>&1
  check "USE_BENCH=1 on a project that imports from its parent: the bench holds the parent, and the campaign runs" 0 $? "$TMP/o136"
  if grep -q "the bench is of $TL" "$TMP/o136"; then echo "  ok    and it says which directory it benched"; else
    echo "  FAIL  fuzz-long.sh did not bench the parent: $(grep -E 'fuzz-long|in /' "$TMP/o136" | head -2)"; fails=$((fails + 1)); fi
  mkdir -p "$TMP/deep/a/b/c"; printf '[profile.default]\nallow_paths = ["../../../x"]\n' > "$TMP/deep/a/b/c/foundry.toml"
  BENCH_ROOT="$TMP/fzb" "$HERE/fuzz-long.sh" "$TMP/deep/a/b/c" > "$TMP/o137" 2>&1
  check "USE_BENCH=1 on a project that reaches three levels up is refused, in one line" 2 $? "$TMP/o137"
  if [ "$(grep -c "refused" "$TMP/o137")" = "1" ] && [ -z "$(find "$TMP/fzb" -maxdepth 1 -name 'fuzz-long-c-*' -print -quit 2> /dev/null)" ]; then
    echo "  ok    and no bench was made for it"; else echo "  FAIL  the deep project was benched, or refused unclearly"; fails=$((fails + 1)); fi
  # K26c (V26b): the refusal used to say "Run with USE_BENCH=0" - in someone else's tree, the campaign in their tree
  if ! grep -q 'Run with USE_BENCH=0' "$TMP/o137" && grep -qF 'Bench the directory it reaches yourself' "$TMP/o137" && [ ! -e "$TMP/deep/a/b/c/.gauntlet" ]; then
    echo "  ok    and it does not send you to USE_BENCH=0 in that tree: bench it yourself, then USE_BENCH=0 in the bench"; else
    echo "  FAIL  the deep refusal still points at USE_BENCH=0 as the way out, or wrote into the tree:"; sed "s/^/        | /" "$TMP/o137"; fails=$((fails + 1)); fi
  # the long fuzz's corpus and census live in the BENCH: the next run's refresh must keep them (they used to be deleted by
  # `rsync --delete`, so every long run with a bench started cold), and a corpus the project has of its own is merged in
  FZ="$(find "$TMP/fzb" -maxdepth 1 -name 'fuzz-long-child-*' -print -quit 2> /dev/null)"
  if [ -n "$FZ" ] && [ -d "$FZ/child" ]; then
    mkdir -p "$FZ/child/corpus/invariant" "$FZ/child/census" "$TL/child/corpus/invariant"
    printf 'seq\n' > "$FZ/child/corpus/invariant/PLANTED.json"; printf 'run\t1\n' > "$FZ/child/census/earlier-run.tsv"
    printf 'seq-from-project\n' > "$TL/child/corpus/invariant/FROMPROJECT.json"
    BENCH_ROOT="$TMP/fzb" "$HERE/fuzz-long.sh" "$TL/child" > "$TMP/o156" 2>&1
    check "a second long fuzz in the same bench" 0 $? "$TMP/o156"
    if [ -f "$FZ/child/corpus/invariant/PLANTED.json" ] && [ -f "$FZ/child/census/earlier-run.tsv" ] && [ -f "$FZ/child/corpus/invariant/FROMPROJECT.json" ]; then
      echo "  ok    and the bench's corpus and census survived the refresh, and the project's corpus file was merged in"; else
      echo "  FAIL  fuzz-long.sh's refresh: PLANTED $([ -f "$FZ/child/corpus/invariant/PLANTED.json" ] && echo kept || echo GONE), census $([ -f "$FZ/child/census/earlier-run.tsv" ] && echo kept || echo GONE), FROMPROJECT $([ -f "$FZ/child/corpus/invariant/FROMPROJECT.json" ] && echo merged || echo MISSING)"; fails=$((fails + 1)); fi
    rm -rf "$TL/child/corpus"
    # v0.4.2 (K60): the bench's corpus belongs to the test directories it was recorded on - kept while they are the same
    # (the run above), cleared and said when they change (a changed handler replayed stale selectors: round 4)
    grep -qF "fuzz-long: the bench's corpus was recorded on these test directories (test/ " "$TMP/o156" && echo "  ok    the second run says the bench's corpus was kept: the test directories are the ones it was recorded on" \
      || { echo "  FAIL  the second run did not say the corpus was kept:"; grep -a '^fuzz-long:' "$TMP/o156" | sed "s/^/        | /"; fails=$((fails + 1)); }
    printf '\n// K60: the handler changed\n' >> "$TL/child/test/C.t.sol"; printf 'seq\n' > "$FZ/child/corpus/invariant/PLANTED2.json"
    BENCH_ROOT="$TMP/fzb" "$HERE/fuzz-long.sh" "$TL/child" > "$TMP/o6070" 2>&1
    check "a long fuzz in the same bench after the test directory changed" 0 $? "$TMP/o6070"
    if grep -q "^fuzz-long: test/ changed since the bench's corpus was recorded (" "$TMP/o6070" && [ ! -e "$FZ/child/corpus/invariant/PLANTED2.json" ] && [ ! -e "$FZ/child/corpus/invariant/PLANTED.json" ]; then
      echo "  ok    and the bench's corpus was cleared before the campaign, and it says so"; else
      echo "  FAIL  the bench's corpus after a changed test directory: PLANTED2 $([ -e "$FZ/child/corpus/invariant/PLANTED2.json" ] && echo kept || echo gone)"; grep -a '^fuzz-long:' "$TMP/o6070" | sed "s/^/        | /"; fails=$((fails + 1)); fi
    BENCH_ROOT="$TMP/fzb" "$HERE/fuzz-long.sh" "$TL/child" > "$TMP/o6071" 2>&1
    check "and again, nothing changed" 0 $? "$TMP/o6071"
    grep -qF "fuzz-long: the bench's corpus was recorded on these test directories (test/ " "$TMP/o6071" && echo "  ok    ... the corpus kept, said" \
      || { echo "  FAIL  not said kept:"; grep -a '^fuzz-long:' "$TMP/o6071" | sed "s/^/        | /"; fails=$((fails + 1)); }
  else
    echo "  FAIL  the bench of the two-level project is not where the case above left it ($TMP/fzb/fuzz-long-child-*)"; fails=$((fails + 1))
  fi
  # BENCH_ROOT unset (K26): the bench is under the PROJECT's own .gauntlet/bench - also when what is benched is its parent
  # (the parent's copy then holds child/ without child/.gauntlet) - and nothing is written under $HOME
  mkdir -p "$TL/child/.gauntlet"   # the convention installed (made with the child above): the default applies
  env -u BENCH_ROOT "$HERE/fuzz-long.sh" "$TL/child" > "$TMP/o665" 2>&1
  check "a long fuzz with BENCH_ROOT unset" 0 $? "$TMP/o665"
  FZD="$(find "$TL/child/.gauntlet/bench" -maxdepth 1 -name 'fuzz-long-child-*' -print -quit 2> /dev/null)"
  if [ -n "$FZD" ] && [ -f "$FZD/src/Base.sol" ] && [ -f "$FZD/child/test/C.t.sol" ] && [ ! -e "$FZD/child/.gauntlet" ] \
    && [ ! -e "$HOME/.gauntlet/bench/$(basename "$FZD")" ] && grep -q "in $FZD/child" "$TMP/o665"; then
    echo "  ok    it ran in <project>/.gauntlet/bench/$(basename "$FZD")/child, which holds no .gauntlet, and nothing went under HOME"; else
    echo "  FAIL  the default bench of the long fuzz: '${FZD:-none}' under $TL/child/.gauntlet/bench"; grep -a 'in /' "$TMP/o665" | head -2 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -rf "$TL/child/.gauntlet/bench"

  BENCH_ROOT="$TMP/benches" "$HERE/bench.sh" bb "$M" > "$TMP/o33" 2>&1; check "an ordinary bench" 0 $? "$TMP/o33"
  BENCH_ROOT="$TMP/benches" BENCH_EXCLUDE="src" "$HERE/bench.sh" bb "$M" > "$TMP/o34" 2>&1
  check "a black-box bench over a bench of the same name" 0 $? "$TMP/o34"
  if [ ! -e "$TMP/benches/bb/src" ] && [ -z "$(find "$TMP/benches/bb" -type l -print -quit)" ]; then
    echo "  ok    the withheld directory is really gone, and nothing in the bench links out of it"
  else
    echo "  FAIL  the black-box bench still holds src/ or a symlink"; fails=$((fails + 1))
  fi

  # ---- bench.sh must never delete what it was asked to copy. Each case counts the project's files afterwards.
  WS="$TMP/ws"; mkdir -p "$WS/myhook/src" "$WS/myhook/script"
  printf 'contract H {}\n' > "$WS/myhook/src/H.sol"; printf '// deploy\n' > "$WS/myhook/script/D.sol"; printf '[profile.default]\n' > "$WS/myhook/foundry.toml"
  BENCH_ROOT="$WS" BENCH_EXCLUDE="script" "$HERE/bench.sh" myhook "$WS/myhook" > "$TMP/o40" 2>&1
  check "a bench that IS the project is refused" 1 $? "$TMP/o40"
  BENCH_ROOT="$WS/myhook/benches" BENCH_EXCLUDE="script" "$HERE/bench.sh" inner "$WS/myhook" > "$TMP/o41" 2>&1
  check "a bench INSIDE the project is refused" 1 $? "$TMP/o41"
  mkdir -p "$WS/outer/proj/src"; printf 'contract P {}\n' > "$WS/outer/proj/src/P.sol"
  BENCH_ROOT="$WS" BENCH_EXCLUDE="script" "$HERE/bench.sh" outer "$WS/outer/proj" > "$TMP/o42" 2>&1
  check "a bench that CONTAINS the project is refused" 1 $? "$TMP/o42"
  BENCH_ROOT="$WS/benches" "$HERE/bench.sh" . "$WS/myhook" > "$TMP/o43" 2>&1; check "'.' is not a bench name" 1 $? "$TMP/o43"
  BENCH_ROOT="$WS/benches" "$HERE/bench.sh" .. "$WS/myhook" > "$TMP/o44" 2>&1; check "'..' is not a bench name" 1 $? "$TMP/o44"
  # the same refusals by the routes a path can be DISGUISED: a `..` after a component that does not exist yet (the guard
  # used to compare it as text, then mkdir made it real, and src/ was overwritten), a RELATIVE root that does not exist
  # yet (it lost a slash and compared "<cwd>benches"), a root reached through a symlink, and a bench NAME that is
  # itself a link to the project.
  BENCH_ROOT="$WS/ghost/../myhook" BENCH_EXCLUDE="script" "$HERE/bench.sh" src "$WS/myhook" > "$TMP/o70" 2>&1
  check "a BENCH_ROOT with '..' in it is refused" 1 $? "$TMP/o70"
  (cd "$WS/myhook" && BENCH_ROOT="benchesrel" BENCH_EXCLUDE="script" "$HERE/bench.sh" c3 . > "$TMP/o71" 2>&1)
  check "a RELATIVE bench root inside the project is refused the FIRST time too" 1 $? "$TMP/o71"
  ln -s "$WS/myhook" "$WS/alias"
  BENCH_ROOT="$WS/alias/benches2" BENCH_EXCLUDE="script" "$HERE/bench.sh" viaLink "$WS/myhook" > "$TMP/o72" 2>&1
  check "a bench root that reaches the project through a symlink is refused" 1 $? "$TMP/o72"
  mkdir -p "$WS/benches"; ln -s "$WS/myhook" "$WS/benches/namelink"
  BENCH_ROOT="$WS/benches" BENCH_EXCLUDE="script" "$HERE/bench.sh" namelink "$WS/myhook" > "$TMP/o73" 2>&1
  check "a bench NAME that is a link to the project is refused" 1 $? "$TMP/o73"
  rm -f "$WS/alias" "$WS/benches/namelink"
  if [ -f "$WS/myhook/src/H.sol" ] && [ -f "$WS/myhook/script/D.sol" ] && [ -f "$WS/outer/proj/src/P.sol" ] \
    && [ "$(find "$WS/myhook" -type f | wc -l | tr -d ' ')" = "3" ] && [ ! -e "$WS/myhook/benchesrel/c3" ] && [ ! -e "$WS/myhook/benches2/viaLink" ]; then
    echo "  ok    and every project is still on disk, with nothing added to it, after the nine refusals"
  else
    echo "  FAIL  bench.sh DELETED project files, or built a bench inside the project"; fails=$((fails + 1))
  fi

  # ---- a link under lib/ that leads back into the project would carry the withheld source into the black-box bench
  mkdir -p "$WS/mono/src" "$WS/mono/lib/real"; printf 'contract Secret {}\n' > "$WS/mono/src/Secret.sol"
  printf '[profile.default]\n' > "$WS/mono/foundry.toml"; ln -s ../src "$WS/mono/lib/core"
  BENCH_ROOT="$WS/benches" BENCH_EXCLUDE="src" "$HERE/bench.sh" mono "$WS/mono" > "$TMP/o45" 2>&1
  check "a black-box bench whose lib/ links back into the project is refused" 1 $? "$TMP/o45"
  if [ -z "$(find "$WS/benches" -name Secret.sol -print -quit 2> /dev/null)" ]; then echo "  ok    and the withheld file is nowhere in the benches"; else
    echo "  FAIL  the withheld file reached a bench through lib/"; fails=$((fails + 1)); fi

  # ... and the FINAL verification has to be seen refusing too: a link anywhere else in the project survives the copy
  mkdir -p "$WS/linky/src" "$WS/elsewhere"; printf 'contract L {}\n' > "$WS/linky/src/L.sol"
  printf '[profile.default]\n' > "$WS/linky/foundry.toml"; ln -s "$WS/elsewhere" "$WS/linky/shortcut"
  BENCH_ROOT="$WS/benches" BENCH_EXCLUDE="src" "$HERE/bench.sh" linky "$WS/linky" > "$TMP/o39" 2>&1
  check "a black-box bench that still holds a symlink is not handed over" 1 $? "$TMP/o39"

  # ---- mutate.sh: the two halves of "KILLED means a test went red BECAUSE of the mutant", each seen red alone
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\ncontract AlwaysRed is Test { function test_red() public pure { assertEq(uint256(1), 2); } }\n' > "$M/test/Red.t.sol"
  # the change is harmless AND compiles (A.sol is one line: a trailing `//` comment would swallow the rest of it, the
  # mutant would not build, and this case would answer 2 for that reason instead - it did, and a sabotage run caught it)
  LABEL=m9 OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$M" src/A.sol "uint256 public x;" "uint256 public x; uint256 public y;" > "$TMP/o46" 2>&1
  check "a baseline with a red test: nothing proven, never KILLED" 2 $? "$TMP/o46"
  if grep -q "UNCHANGED code does not pass" "$TMP/o46"; then echo "  ok    and it is the BASELINE that was refused, not the mutant"; else
    echo "  FAIL  the case answered 2 for some other reason: $(tail -1 "$TMP/o46")"; fails=$((fails + 1)); fi
  LABEL=m10 OUT_DIR="$TMP/mut" EXPECT=green BASELINE_MAY_BE_RED=1 \
    "$HERE/mutate.sh" "$M" test/Red.t.sol "assertEq(uint256(1), 2);" "assertEq(uint256(2), 2);" > "$TMP/o47" 2>&1
  check "regression test first: a red baseline is accepted on request, and the fix must be all green" 0 $? "$TMP/o47"
  LABEL=m11 OUT_DIR="$TMP/mut" EXPECT=green BASELINE_MAY_BE_RED=1 \
    "$HERE/mutate.sh" "$M" test/Red.t.sol "assertEq(uint256(1), 2);" "assertEq(uint256(1), 3);" > "$TMP/o48" 2>&1
  check "and a 'fix' that leaves it red FAILS" 1 $? "$TMP/o48"
  # ---- a finding's MUTATION-TESTED takes TWO runs on the same fix variant (K32b, V32): the finding's test green on it
  # (EXPECT=green BASELINE_MAY_BE_RED=1, that test alone) AND the everyday suite green on it (EXPECT=green, the battery's
  # filter) - doctrine/EVIDENCE.md section 2. V32's P-8: a "fix" that refused every pool but the test's own turned the finding's
  # test green and broke the everyday suite, and the first run alone said VARIANT PASSED. The same shape here: only the
  # test's own registrant may register. It passes the first run, fails the second, and does not earn the label.
  MF="$TMP/minif"; mkdir -p "$MF/src" "$MF/test" "$MF/pending" "$MF/.gauntlet"; ln -s "$(cd "$KIT/lib" && pwd -P)" "$MF/lib"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n[profile.pending]\nsrc = "src"\ntest = "pending"\nlibs = ["lib"]\n' > "$MF/foundry.toml"
  printf 'pragma solidity ^0.8.26;\ncontract Reg {\n    error Taken();\n    mapping(uint256 => address) public ownerOf;\n    function register(uint256 id) external {\n        ownerOf[id] = msg.sender;\n    }\n}\n' > "$MF/src/Reg.sol"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/Reg.sol";\ncontract RegUnit is Test { function test_anyone_registers_a_free_id() public { Reg r = new Reg(); r.register(7); assertEq(r.ownerOf(7), address(this)); } }\n' > "$MF/test/Reg.t.sol"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/Reg.sol";\n/// the exact error - not a bare vm.expectRevert(), which EVIDENCE section 2 refuses\ncontract F1 is Test { function test_F1_a_stranger_cannot_take_a_registered_id() public { Reg r = new Reg(); vm.prank(address(0xA11CE)); r.register(1); vm.prank(address(0xB0B)); vm.expectRevert(Reg.Taken.selector); r.register(1); assertEq(r.ownerOf(1), address(0xA11CE), "exact selector above, not a bare vm.expectRevert()"); } }\n' > "$MF/pending/F-1.t.sol"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/Reg.sol";\ncontract F2 is Test { function test_F2_the_same_with_a_bare_expectRevert() public { Reg r = new Reg(); vm.prank(address(0xA11CE)); r.register(1); vm.prank(address(0xB0B)); vm.expectRevert(); r.register(1); } }\n' > "$MF/pending/F-2.t.sol"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/Reg.sol";\ncontract F3 is Test { function test_F3_the_same_by_a_low_level_call() public { Reg r = new Reg(); vm.prank(address(0xA11CE)); r.register(1); vm.prank(address(0xB0B)); (bool ok,) = address(r).call(abi.encodeCall(Reg.register, (1))); assertFalse(ok, "taken"); } }\n' > "$MF/pending/F-3.t.sol"
  mf_run() { # mf_run <label> <new string> <finding|everyday> [test file]: one mutate.sh run of the documented pair
    if [ "$3" = finding ]; then
      FOUNDRY_PROFILE=pending EXPECT=green BASELINE_MAY_BE_RED=1 TEST_FLAGS="--match-path pending/${4:-F-1.t.sol}" LABEL="$1" OUT_DIR="$TMP/mut" \
        "$HERE/mutate.sh" "$MF" src/Reg.sol "ownerOf[id] = msg.sender;" "$2"
    else
      EXPECT=green LABEL="$1" OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$MF" src/Reg.sol "ownerOf[id] = msg.sender;" "$2"
    fi
  }
  MF_GONE='if (msg.sender != address(0xA11CE)) revert Taken(); ownerOf[id] = msg.sender;'
  MF_FIX='if (ownerOf[id] != address(0)) revert Taken(); ownerOf[id] = msg.sender;'
  mf_run mf1 "$MF_GONE" finding > "$TMP/o962" 2>&1; mf1=$?
  mf_run mf2 "$MF_GONE" everyday > "$TMP/o963" 2>&1; mf2=$?
  check "a finding's fix variant that deletes the test's subject: the finding's test alone passes it" 0 "$mf1" "$TMP/o962"
  check "... and the everyday suite on the same variant FAILS it: MUTATION-TESTED not earned" 1 "$mf2" "$TMP/o963"
  if grep -qF "mutate: VARIANT PASSED is HALF of a finding's MUTATION-TESTED" "$TMP/o962" && grep -q 'test_anyone_registers_a_free_id' "$TMP/o963"; then
    echo "  ok    the first run says it is half, and names the second; the second names the everyday test the variant broke"; else
    echo "  FAIL  the finding run does not say it is half of the label, or the everyday run did not name the broken test:"
    grep -E '^mutate:|VARIANT|FAIL' "$TMP/o962" "$TMP/o963" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  mf_run mf3 "$MF_FIX" finding > "$TMP/o964" 2>&1; mf3=$?
  mf_run mf4 "$MF_FIX" everyday > "$TMP/o965" 2>&1; mf4=$?
  if [ "$mf3" = 0 ] && [ "$mf4" = 0 ] && ! grep -q 'WARNING' "$TMP/o964"; then
    echo "  ok    a real fix passes both runs (rc $mf3 and $mf4): the pair that earns MUTATION-TESTED, no warning on a named error - the rule cited in a comment and in an assertion's message beside it is not code"; else
    echo "  FAIL  a real fix: finding run rc $mf3, everyday run rc $mf4"; tail -n 4 "$TMP/o964" "$TMP/o965" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # ... and the finding's test must expect the EXACT failure: a bare vm.expectRevert() is green on any revert
  mf_run mf5 "$MF_FIX" finding F-2.t.sol > "$TMP/o966" 2>&1; mf5=$?
  mf_warned() { # mf_warned <out> <file> <shape>: the WARNING line for that file, the shape named under it, and (K32d,
    # V32c) the line that says the check knows a few shapes only
    grep -qF "mutate: WARNING - $2: the finding's test accepts any revert - not evidence for a finding's label, EVIDENCE section 2" "$1" \
      && grep -qF "($3)" "$1" && grep -qF "        This check knows a few shapes only: its silence is not evidence." "$1"
  }
  if [ "$mf5" = 0 ] && mf_warned "$TMP/o966" pending/F-2.t.sol "a bare vm.expectRevert()"; then
    echo "  ok    a finding's test with a bare vm.expectRevert(): the variant passes, and a WARNING names the file - not the label"; else
    echo "  FAIL  a bare vm.expectRevert() in the finding's test is not named (rc $mf5):"; grep -E '^mutate:|^        \(|VARIANT' "$TMP/o966" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # K32c (V32b's Q-2): the same claim by a low-level call whose success flag is only asserted false is green on any revert too
  mf_run mf6 "$MF_FIX" finding F-3.t.sol > "$TMP/o971" 2>&1; mf6=$?
  if [ "$mf6" = 0 ] && mf_warned "$TMP/o971" pending/F-3.t.sol "a low-level call whose success flag is only asserted false"; then
    echo "  ok    a finding's test by call + assertFalse: the variant passes, and the WARNING names that shape"; else
    echo "  FAIL  a call whose flag is only asserted false is not named (rc $mf6):"; grep -E '^mutate:|^        \(|VARIANT' "$TMP/o971" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # K32c (V32b): BASELINE_MAY_BE_RED=1 over a baseline that came out GREEN - the finding's test is not red on the code
  EXPECT=green BASELINE_MAY_BE_RED=1 LABEL=mf7 OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$MF" src/Reg.sol "ownerOf[id] = msg.sender;" "$MF_FIX" > "$TMP/o972" 2>&1
  check "BASELINE_MAY_BE_RED=1 over a green baseline: the variant is still judged" 0 $? "$TMP/o972"
  if grep -qF "mutate: BASELINE_MAY_BE_RED=1, and the baseline came out GREEN: condition 1 of a finding's MUTATION-TESTED (red on the code as it is) FAILED" "$TMP/o972" \
    && ! grep -q 'HALF' "$TMP/o972"; then
    echo "  ok    and one line says condition 1 (red on the code) failed"; else
    echo "  FAIL  a green baseline under BASELINE_MAY_BE_RED=1 is not said:"; grep -E '^mutate:|VARIANT' "$TMP/o972" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # K32c (V32b), K32d (V32c): a guard that reverts with the finding's OWN error turns an exact-selector test green without
  # fixing anything - both runs pass. Only a CONTROL goes red on it: the SAME call on the SAME shape accepted, only the
  # finding's condition different (doctrine/EVIDENCE.md section 2, condition 3). The finding: a LIVE launch cannot be
  # registered again. F-5's control is the weak one K32c taught (a fresh key, another fee, on the same terms): V32c's two
  # non-fix variants pass it, both runs. F-6's is the tight one (V32c's Q-1t): the same pool shape registered twice while
  # NOT live, accepted - both variants go red on it, V32b's guard too, and the real fix earns the label.
  printf 'pragma solidity ^0.8.26;\ncontract Launch {\n    error BadTerms();\n    struct L { address treasury; uint256 maxBuy; bool live; }\n    mapping(bytes32 => L) internal launches;\n    function register(uint256 id, uint24 fee, address treasury, uint256 maxBuy) external {\n        if (maxBuy == 0) revert BadTerms();\n        L storage l = launches[keccak256(abi.encode(id, fee))];\n        l.treasury = treasury;\n        l.maxBuy = maxBuy;\n    }\n    function start(uint256 id, uint24 fee) external { launches[keccak256(abi.encode(id, fee))].live = true; }\n    function maxBuyOf(uint256 id, uint24 fee) external view returns (uint256) { return launches[keccak256(abi.encode(id, fee))].maxBuy; }\n}\n' > "$MF/src/Launch.sol"
  LH='pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/Launch.sol";\n'
  LS='Launch l = new Launch(); l.register(1, 3000, address(0x7EA), 10e18); l.start(1, 3000);'
  LQ='vm.expectRevert(Launch.BadTerms.selector); l.register(1, 3000, address(0xE71), 1000e18);'
  printf "${LH}contract LaunchUnit is Test { function test_a_launch_registers_and_starts() public { %s assertEq(l.maxBuyOf(1, 3000), 10e18); } }\n" "$LS" > "$MF/test/Launch.t.sol"
  printf "${LH}contract F4 is Test { function test_F4_a_live_launch_cannot_be_registered_again() public { %s %s } }\n" "$LS" "$LQ" > "$MF/pending/F-4.t.sol"
  printf "${LH}contract F5 is Test { function test_F5_with_a_weak_control() public { %s l.register(2, 500, address(0xE71), 1000e18); assertEq(l.maxBuyOf(2, 500), 1000e18); %s } }\n" "$LS" "$LQ" > "$MF/pending/F-5.t.sol"
  printf "${LH}contract F6 is Test { function test_F6_with_a_tight_control() public { %s l.register(2, 3000, address(0x7EA), 10e18); l.register(2, 3000, address(0xE71), 1000e18); assertEq(l.maxBuyOf(2, 3000), 1000e18); %s } }\n" "$LS" "$LQ" > "$MF/pending/F-6.t.sol"
  LF_MB='if (maxBuy == 0) revert BadTerms();'; LF_TR='l.treasury = treasury;'
  lf_run() { # lf_run <label> <old string> <new string> <finding's test file | everyday>
    if [ "$4" = everyday ]; then
      EXPECT=green LABEL="$1" OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$MF" src/Launch.sol "$2" "$3"
    else
      FOUNDRY_PROFILE=pending EXPECT=green BASELINE_MAY_BE_RED=1 TEST_FLAGS="--match-path pending/$4" LABEL="$1" OUT_DIR="$TMP/mut" \
        "$HERE/mutate.sh" "$MF" src/Launch.sol "$2" "$3"
    fi
  }
  LF_SAME='if (maxBuy == 0 || maxBuy > 100e18) revert BadTerms();'                              # V32b: a guard on another argument
  LF_VX='if (maxBuy == 0 || (treasury == address(0xE71) && fee == 3000)) revert BadTerms();'   # V32c: the test's values and shape
  LF_VS='if (l.treasury != address(0) && fee == 3000) revert BadTerms(); l.treasury = treasury;' # V32c: any registered 3000 pool
  LF_FIX='if (l.live) revert BadTerms(); l.treasury = treasury;'
  lf_run lf1 "$LF_MB" "$LF_SAME" F-4.t.sol > "$TMP/o973" 2>&1; lf1=$?
  lf_run lf2 "$LF_MB" "$LF_SAME" everyday > "$TMP/o974" 2>&1; lf2=$?
  if [ "$lf1" = 0 ] && [ "$lf2" = 0 ] && ! grep -q 'WARNING' "$TMP/o973"; then
    echo "  ok    the same-error guard passes BOTH runs for an exact-selector test with no control (rc $lf1, $lf2), unwarned: the gap"; else
    echo "  FAIL  the same-error variant without a control: finding run rc $lf1, everyday rc $lf2"; grep -E '^mutate:|VARIANT|FAIL' "$TMP/o973" "$TMP/o974" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  lf_run lw1 "$LF_MB" "$LF_VX" F-5.t.sol > "$TMP/o980" 2>&1; lw1=$?
  lf_run lw2 "$LF_MB" "$LF_VX" everyday > "$TMP/o981" 2>&1; lw2=$?
  lf_run lw3 "$LF_TR" "$LF_VS" F-5.t.sol > "$TMP/o982" 2>&1; lw3=$?
  lf_run lw4 "$LF_TR" "$LF_VS" everyday > "$TMP/o983" 2>&1; lw4=$?
  if [ "$lw1$lw2$lw3$lw4" = 0000 ]; then
    echo "  ok    the WEAK control (a fresh key, another fee, the same terms): both non-fix variants pass both runs (V32c) - why it is not taught"; else
    echo "  FAIL  the weak control: rc $lw1 $lw2 (test's values) $lw3 $lw4 (any registered pool of that fee)"
    grep -E '^mutate:|VARIANT|^\[FAIL' "$TMP/o980" "$TMP/o981" "$TMP/o982" "$TMP/o983" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  for v in SAME:975 VX:984 VS:985; do
    case "${v%%:*}" in SAME) o="$LF_MB" n="$LF_SAME" ;; VX) o="$LF_MB" n="$LF_VX" ;; VS) o="$LF_TR" n="$LF_VS" ;; esac
    lf_run "lt-${v%%:*}" "$o" "$n" F-6.t.sol > "$TMP/o${v#*:}" 2>&1
    check "a non-fix variant (${v%%:*}) against the TIGHT control in the finding's file: VARIANT FAILED, the label refused" 1 $? "$TMP/o${v#*:}"
    if grep -q '^\[FAIL: BadTerms()\] test_F6_with_a_tight_control' "$TMP/o${v#*:}"; then
      echo "  ok    and it is the control that went red: the same shape, not live, refused with the finding's own error"; else
      echo "  FAIL  the tight control did not go red for ${v%%:*}:"; grep -E '^\[FAIL|VARIANT' "$TMP/o${v#*:}" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  done
  lf_run lf4 "$LF_TR" "$LF_FIX" F-6.t.sol > "$TMP/o976" 2>&1; lf4=$?
  lf_run lf5 "$LF_TR" "$LF_FIX" everyday > "$TMP/o986" 2>&1; lf5=$?
  if [ "$lf4" = 0 ] && [ "$lf5" = 0 ]; then
    echo "  ok    the real fix passes both runs against the tight control (rc $lf4, $lf5): the label earned - the control does not block a fix"; else
    echo "  FAIL  the real fix with the tight control: finding run rc $lf4, everyday rc $lf5"; grep -E '^mutate:|VARIANT|^\[FAIL' "$TMP/o976" "$TMP/o986" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -rf "$MF"
  # the exception has TWO conditions, and each has to be seen refusing alone: without the variable a red baseline proves
  # nothing under EXPECT=green, and WITH it a mutant (EXPECT=red) over a red baseline must never come out KILLED
  LABEL=m14 OUT_DIR="$TMP/mut" EXPECT=green \
    "$HERE/mutate.sh" "$M" test/Red.t.sol "assertEq(uint256(1), 2);" "assertEq(uint256(2), 2);" > "$TMP/o74" 2>&1
  check "EXPECT=green over a red baseline WITHOUT the variable proves nothing" 2 $? "$TMP/o74"
  LABEL=m15 OUT_DIR="$TMP/mut" BASELINE_MAY_BE_RED=1 \
    "$HERE/mutate.sh" "$M" src/A.sol "x++;" "x += 2;" > "$TMP/o75" 2>&1
  check "BASELINE_MAY_BE_RED does not apply to a mutant: red baseline, nothing proven, never KILLED" 2 $? "$TMP/o75"
  rm -f "$M/test/Red.t.sol"

  LABEL=m12 OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$M" src/A.sol "x++;" "x += 2;" > "$TMP/o49" 2>&1
  check "a real mutant on the small project is KILLED" 0 $? "$TMP/o49"
  if grep -q "KILLED - 1 test(s) went red" "$TMP/o49"; then echo "  ok    and ONE failing test is counted as one (forge prints it twice)"; else
    echo "  FAIL  the number of failing tests is wrong: $(grep KILLED "$TMP/o49" | head -1)"; fails=$((fails + 1)); fi

  # a forge that dies on the MUTANT without any test failing (a crash, not a verdict). The shim lets the two baseline
  # commands and the mutant's build through, and kills the second `forge test`.
  SHIM="$TMP/shim"; mkdir -p "$SHIM"; REAL_FORGE="$(command -v forge)"
  printf '#!/usr/bin/env bash\nif [ "$1" = "test" ]; then n=$(cat "%s/n" 2> /dev/null || echo 0); n=$((n + 1)); echo "$n" > "%s/n"; if [ "$n" -ge 2 ]; then echo "forge: simulated crash"; exit 1; fi; fi\nexec "%s" "$@"\n' "$SHIM" "$SHIM" "$REAL_FORGE" > "$SHIM/forge"
  chmod +x "$SHIM/forge"
  PATH="$SHIM:$PATH" LABEL=m13 OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$M" src/A.sol "x++;" "x += 2;" > "$TMP/o50" 2>&1
  check "forge failing on the mutant with NO failing test is not a kill" 2 $? "$TMP/o50"

  # ---- fuzz-long.sh: the pre-check must fire BEFORE the campaign, a 'long' profile needs a long budget, a skip is not a pass
  # by ITS OWN message: the budget check further down also stops a missing profile (it falls back to the default
  # budget), so "exit 2 before the campaign" alone does not show that this check is alive
  if grep -q "does not exist in this project's foundry.toml" "$TMP/o31" && ! grep -q "Ran [0-9]* test" "$TMP/o31"; then
    echo "  ok    the missing profile was caught BEFORE any campaign ran"
  else
    echo "  FAIL  the missing profile was only noticed after the campaign had run"; fails=$((fails + 1))
  fi
  cp "$M/foundry.toml" "$TMP/toml.keep"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n[invariant]\nruns = 4\ndepth = 4\nfail_on_revert = true\n[profile.long.fuzz]\nruns = 500\n' > "$M/foundry.toml"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o51" 2>&1
  check "a 'long' profile with no invariant budget of its own proves nothing" 2 $? "$TMP/o51"
  cp "$TMP/toml.keep" "$M/foundry.toml"
  USE_BENCH=0 RUNS=1 DEPTH=1 "$HERE/fuzz-long.sh" "$M" > "$TMP/o52" 2>&1
  check "RUNS and DEPTH cannot shrink the long fuzz below the everyday budget" 2 $? "$TMP/o52"
  # both refusals are ACTIONABLE: they print the everyday budget they measured and a block to paste computed from it
  # (runs = 4 x the everyday runs, at least 1000; depth = the everyday depth). $M's everyday budget is 4 x 4.
  if grep -qF "which here is" "$TMP/o31" && grep -qF "4 x 4 = 16 calls" "$TMP/o31" && grep -qx '\[profile.nosuchprofile.invariant\]' "$TMP/o31" \
    && grep -qx 'runs = 1000' "$TMP/o31" && grep -qx 'depth = 4' "$TMP/o31" && grep -qx 'corpus_dir = "corpus/long"' "$TMP/o31"; then
    echo "  ok    the missing-profile refusal prints the everyday budget and the block to paste"; else
    echo "  FAIL  the missing-profile refusal is not actionable:"; grep -A8 "does not exist" "$TMP/o31" | head -10 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  if grep -qF "4 x 4 = 16 calls" "$TMP/o52" && grep -qx '\[profile.long.invariant\]' "$TMP/o52" && grep -qx 'runs = 1000' "$TMP/o52" \
    && grep -qx 'depth = 4' "$TMP/o52" && grep -qx 'fail_on_revert = true' "$TMP/o52" && grep -qF "must be LARGER than YOUR everyday one" "$TMP/o52"; then
    echo "  ok    the budget refusal prints the everyday budget, the rule and the block to paste"; else
    echo "  FAIL  the budget refusal is not actionable:"; grep -A8 "not larger" "$TMP/o52" | head -10 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # forge's DEFAULT everyday budget (no [invariant] section: 256 x 500 = 128 000) against the kit's 1000 x 128: refused,
  # and the block says 1024 x 500 - the fresh reader's case, where no document said what to pick
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n[profile.long.invariant]\nruns = 1000\ndepth = 128\nfail_on_revert = true\n' > "$M/foundry.toml"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o176" 2>&1
  check "forge's default everyday budget (256 x 500) against a long profile of 1000 x 128: refused" 2 $? "$TMP/o176"
  if grep -qF "256 x 500 = 128000 calls" "$TMP/o176" && grep -qx 'runs = 1024' "$TMP/o176" && grep -qx 'depth = 500' "$TMP/o176" && ! grep -q "Ran [0-9]* test" "$TMP/o176"; then
    echo "  ok    and the block it prints is 1024 x 500, computed from forge's defaults, before any campaign ran"; else
    echo "  FAIL  the refusal on forge's defaults does not print 1024 x 500:"; grep -A8 "not larger" "$TMP/o176" | head -10 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # the block, pasted as printed into a project with no long profile, gives a long fuzz that runs and passes
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n[invariant]\nruns = 4\ndepth = 4\nfail_on_revert = true\n' > "$M/foundry.toml"
  sed -n '/^\[profile\.nosuchprofile\.invariant\]$/,/^corpus_dir = /p' "$TMP/o31" | sed 's/nosuchprofile/long/' >> "$M/foundry.toml"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o177" 2>&1
  check "the printed block, pasted as is: the long fuzz runs and passes" 0 $? "$TMP/o177"
  if grep -qF "4000 under 'long', 16 under the default profile" "$TMP/o177"; then echo "  ok    and the budget it ran under is the block's (1000 x 4)"; else
    echo "  FAIL  the pasted block was not the budget that ran: $(grep 'invariant budget' "$TMP/o177")"; fails=$((fails + 1)); fi
  cp "$TMP/toml.keep" "$M/foundry.toml"; rm -rf "$M/corpus"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\ncontract SkippedInvariant is Test { function setUp() public { vm.skip(true); } function invariant_never_runs() public pure { assertTrue(true); } }\n' > "$M/test/SkipInv.t.sol"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o53" 2>&1
  check "a campaign that SKIPPED itself next to one that ran is not a pass" 2 $? "$TMP/o53"
  rm -f "$M/test/SkipInv.t.sol"
  # the budget that was READ is not the budget that RAN when a test carries its own inline configuration
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/A.sol";\ncontract InlineInvariant is Test { A a; function setUp() public { a = new A(); targetContract(address(a)); }\n/// forge-config: long.invariant.runs = 1\n/// forge-config: long.invariant.depth = 1\nfunction invariant_inline() public view { assertGe(a.x(), 0); } }\n' > "$M/test/Inline.t.sol"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o76" 2>&1
  check "a campaign that RAN less than the long budget (inline config) is not a long fuzz" 2 $? "$TMP/o76"
  rm -f "$M/test/Inline.t.sol"
  V4_MANAGER=source USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o77" 2>&1; check "long fuzz with V4_MANAGER set" 0 $? "$TMP/o77"
  if [ -d "$M/corpus/invariant-source" ]; then echo "  ok    and forge really wrote the corpus into the manager's own directory"; else
    echo "  FAIL  fuzz-long.sh: V4_MANAGER did not move the corpus"; fails=$((fails + 1)); fi
  # cases share $M: leave no fuzz state behind for the next one to inherit
  rm -rf "$M/corpus" "$M/cache/invariant" "$M/census"

  # ---- battery.sh: one corpus per manager
  V4_MANAGER=fixture "$HERE/battery.sh" "$M" > "$TMP/o54" 2>&1; check "battery with V4_MANAGER set" 0 $? "$TMP/o54"
  # the EFFECT, not the echo: the directory forge wrote to. (The first version of this case read the script's own
  # message, and a sabotage that kept the message and dropped the `export` left it green.)
  if [ -d "$M/corpus/invariant-fixture" ]; then echo "  ok    and forge really wrote the corpus into the manager's own directory"; else
    echo "  FAIL  V4_MANAGER did not select a corpus of its own"; fails=$((fails + 1)); fi
  V4_MANAGER=third "$HERE/census.sh" "$M" > "$TMP/o78" 2>&1
  if [ -d "$M/corpus/invariant-third" ]; then echo "  ok    census.sh keeps one corpus per manager too"; else
    echo "  FAIL  census.sh ran the campaigns on the shared corpus"; fails=$((fails + 1)); fi
  rm -rf "$M/corpus" "$M/cache/invariant" "$M/census"

  # ---- sim-report.sh: the arithmetic on a ledger written by hand
  SR="$TMP/sim.tsv"
  printf 'cal	honest	40	40	0	100	98	98	0	0	0	7000	-2
' > "$SR"
  printf 'cal	honest	40	38	2	100	96	99	4	3	1	9000	-6
' >> "$SR"
  printf 'cal	broken line with five fields	1	2	3
' >> "$SR"
  "$HERE/sim-report.sh" "$SR" > "$TMP/o90" 2>&1; check "sim-report over two runs and a broken line" 0 $? "$TMP/o90"
  # 13-field lines are from a ledger that did not price gas: 0 priced runs, and "-" for gasCost and net, never 0
  if grep -Eq '^cal +honest +2 +40\.0 +39\.0 +1\.0 +2 +0 +3 +8000 +-4 +0 +- +- +0 +-$' "$TMP/o90" && grep -q "1 line(s) ignored" "$TMP/o90"; then
    echo "  ok    and the means, the worst-ever and the ignored line are right"
  else
    echo "  FAIL  sim-report arithmetic is wrong:"; sed "s/^/        | /" "$TMP/o90"; fails=$((fails + 1))
  fi
  # 15-field lines carry gasCost and pnlNet: their means are over the priced runs, and a group that mixes priced and
  # unpriced lines is named, because there pnl/run - net/run is not gasCost/run
  SG="$TMP/simgas.tsv"
  printf 'gas\thonest\t40\t40\t0\t100\t98\t98\t0\t0\t0\t7000\t-2\t10\t-12\n' > "$SG"
  printf 'gas\thonest\t40\t38\t2\t100\t96\t99\t4\t3\t1\t9000\t-6\t30\t-36\n' >> "$SG"
  printf 'mix\thonest\t40\t40\t0\t100\t98\t98\t0\t0\t0\t7000\t-2\t10\t-12\n' >> "$SG"
  printf 'mix\thonest\t40\t38\t2\t100\t96\t99\t4\t3\t1\t9000\t-6\n' >> "$SG"
  "$HERE/sim-report.sh" "$SG" > "$TMP/o92" 2>&1; check "sim-report over priced and mixed runs" 0 $? "$TMP/o92"
  if grep -Eq '^gas +honest +2 +40\.0 +39\.0 +1\.0 +2 +0 +3 +8000 +-4 +2 +20 +-24 +0 +-$' "$TMP/o92" \
    && grep -Eq '^mix +honest +2 +40\.0 +39\.0 +1\.0 +2 +0 +3 +8000 +-4 +1 +10 +-12 +0 +-$' "$TMP/o92" \
    && grep -q "mix honest: pnl/run is over 2 runs, gasCost/run and net/run over 1" "$TMP/o92" \
    && ! grep -q "gas honest: pnl/run is over" "$TMP/o92"; then
    echo "  ok    and the gas cost, the net P&L, the priced count and the mixed-group note are right"
  else
    echo "  FAIL  sim-report gas arithmetic is wrong:"; sed "s/^/        | /" "$TMP/o92"; fails=$((fails + 1))
  fi
  # 16-field lines carry atQuote: swaps the engine never sent because their own quote was 0. Its mean is over the lines
  # that carry it (never over the older ones, which would dilute it), and a group mixing the two is named
  SQ="$TMP/simatq.tsv"
  printf 'atq\tarb\t40\t30\t2\t100\t96\t99\t4\t3\t1\t9000\t-6\t30\t-36\t8\n' > "$SQ"
  printf 'atq\tarb\t40\t30\t2\t100\t96\t99\t4\t3\t1\t9000\t-6\t30\t-36\t4\n' >> "$SQ"
  printf 'atqmix\tarb\t40\t30\t2\t100\t96\t99\t4\t3\t1\t9000\t-6\t30\t-36\t8\n' >> "$SQ"
  printf 'atqmix\tarb\t40\t30\t2\t100\t96\t99\t4\t3\t1\t9000\t-6\t30\t-36\n' >> "$SQ"
  "$HERE/sim-report.sh" "$SQ" > "$TMP/o93" 2>&1; check "sim-report over runs with and without refusals at quote" 0 $? "$TMP/o93"
  if grep -Eq '^atq +arb +2 +40\.0 +30\.0 +2\.0 +4 +1 +3 +9000 +-6 +2 +30 +-36 +2 +6\.0$' "$TMP/o93" && grep -Eq '^atqmix +arb +2 +40\.0 +30\.0 +2\.0 +4 +1 +3 +9000 +-6 +2 +30 +-36 +1 +8\.0$' "$TMP/o93" && grep -q "atqmix arb: atQuote/run is over 1 runs of 2" "$TMP/o93" && grep -q "1 line(s) from a ledger without the atQuote column" "$TMP/o93" && ! grep -q "atq arb: atQuote/run is over" "$TMP/o93"; then
    echo "  ok    and the refused-at-quote mean, its run count and the mixed-group note are right"
  else
    echo "  FAIL  sim-report refused-at-quote arithmetic is wrong:"; sed "s/^/        | /" "$TMP/o93"; fails=$((fails + 1))
  fi
  : > "$TMP/empty.tsv"; "$HERE/sim-report.sh" "$TMP/empty.tsv" > "$TMP/o91" 2>&1; check "an empty ledger measured nothing" 2 $? "$TMP/o91"

  # ---- census.sh: the arithmetic on a file written by hand, then end to end on the kit's own example
  C="$TMP/census.tsv"
  printf 'Toy\tU=0\tA:deposit=5/4\tA:withdraw=3/0\tB:whole credit=1\n' > "$C"
  printf 'Toy\tU=0\tA:deposit=6/6\tA:withdraw=2/1\n' >> "$C"
  printf 'Toy\tU=0\tA:deposit=1/0\tA:set=x=1/1\tB:whole credit=2\n' >> "$C"
  OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C" > "$TMP/o55" 2>&1; check "census of three hand-written runs with no floor named is NOTHING JUDGED, not a pass" 2 $? "$TMP/o55"
  if grep -q '^census gate: NOTHING JUDGED - CORE and REACH are both empty' "$TMP/o55"; then
    echo "  ok    and the last line says so"
  else
    echo "  FAIL  the empty-floor gate did not say NOTHING JUDGED"; fails=$((fails+1)); sed 's/^/          | /' "$TMP/o55" | tail -n 4
  fi
  if grep -Eq '^withdraw +5 +1 +1 +2$' "$TMP/o55" && grep -Eq '^deposit +12 +10 +2 +1$' "$TMP/o55" \
    && grep -Eq '^whole credit +2 +3$' "$TMP/o55" && grep -Eq '^set=x +1 +1 +1 +2$' "$TMP/o55"; then
    echo "  ok    and the sums are right (an action missing from a run counts as zero successes in it)"
  else
    echo "  FAIL  the census arithmetic is wrong:"; sed "s/^/        | /" "$TMP/o55"; fails=$((fails + 1))
  fi
  CORE="withdraw" MIN_PCT=50 OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C" > "$TMP/o56" 2>&1; check "a CORE action that worked in 1 run of 3 is below a floor of 50" 1 $? "$TMP/o56"
  CORE="deposit" MIN_PCT=50 OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C" > "$TMP/o57" 2>&1; check "a CORE action that worked in 2 runs of 3 is above it" 0 $? "$TMP/o57"
  CORE="withdraw" OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C" > "$TMP/o57b" 2>&1; check "and the default floor (25) lets 1 run of 3 through" 0 $? "$TMP/o57b"
  CORE="nosuchaction" OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C" > "$TMP/o58" 2>&1; check "a CORE action that never ran at all" 1 $? "$TMP/o58"
  printf 'Toy\tU=2\tA:deposit=1/1\n' >> "$C"
  OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C" > "$TMP/o59" 2>&1; check "a run with an unexplained revert fails the census" 1 $? "$TMP/o59"
  : > "$TMP/empty.tsv"; OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$TMP/empty.tsv" > "$TMP/o60" 2>&1; check "an empty census measured nothing" 2 $? "$TMP/o60"

  # CORE is judged PER SUITE: an action that is dead in one suite must not be rescued by a namesake in another
  C2="$TMP/census2.tsv"
  printf 'Vault\tU=0\tA:deposit=2/2\tB:whole credit=1\nVault\tU=0\tA:deposit=3/3\n' > "$C2"
  printf 'Hook\tU=0\tA:deposit=4/0\nHook\tU=0\tA:deposit=1/0\nHook\tU=0\tA:deposit=2/0\n' >> "$C2"
  CORE="deposit" OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o79" 2>&1; check "a CORE action dead in ONE suite fails, whatever its namesake did" 1 $? "$TMP/o79"
  CORE="deposit" MIN_PCT=lots OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o80" 2>&1; check "a floor that is not a number is refused" 2 $? "$TMP/o80"
  CORE="deposit" MIN_PCT=0 OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o81" 2>&1; check "a floor of zero is refused: it would pass an action that never worked" 2 $? "$TMP/o81"
  REACH="whole credit" MIN_PCT=50 OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o82" 2>&1; check "a REACH boundary met in 1 run of 2 is at a floor of 50" 0 $? "$TMP/o82"
  REACH="whole credit" MIN_PCT=51 OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o83" 2>&1; check "and below a floor of 51" 1 $? "$TMP/o83"
  REACH="the cap" OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o84" 2>&1; check "a REACH boundary that is in no suite at all" 1 $? "$TMP/o84"
  printf 'Vault\tU=0\tA:broken\tfield=3/1\tA:deposit=1/1\n' >> "$C2"
  OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o85" 2>&1
  if grep -q "2 field(s) ignored" "$TMP/o85"; then echo "  ok    a field the census cannot read is counted out loud, not dropped"; else
    echo "  FAIL  malformed census fields were ignored in silence"; fails=$((fails + 1)); fi
  # ---- the GATE (--aggregate) leaves a record and says its verdict: <OUT_DIR>/06-census-gate.txt holds the table and the
  # verdict, and the last line printed is that verdict. It used to write nothing and print nothing on a pass (rc 0 only).
  gate_last() { tail -n 1 "$1" | tr -d '\r'; }
  gate_ok() { # gate_ok <label> <output> <record>: the record exists, holds the table, and ends in the same verdict as the output
    if [ -f "$3" ] && grep -Eq '^== campaign census: ' "$3" && [ "$(gate_last "$3")" = "$(gate_last "$2")" ]; then
      echo "  ok    $1: the record holds the table and ends in the verdict printed"; else
      echo "  FAIL  $1: record $([ -f "$3" ] && echo "ends in '$(gate_last "$3")'" || echo MISSING), output ends in '$(gate_last "$2")'"; fails=$((fails + 1)); fi
  }
  C3="$TMP/census3.tsv"
  printf 'Toy\tU=0\tA:deposit=5/4\tA:withdraw=3/0\tB:whole credit=1\nToy\tU=0\tA:deposit=6/6\tA:withdraw=2/1\nToy\tU=0\tA:deposit=1/0\tB:whole credit=2\n' > "$C3"
  CORE="deposit withdraw" REACH="whole credit" MIN_PCT=30 OUT_DIR="$TMP/g183" "$HERE/census.sh" --aggregate "$C3" > "$TMP/o183" 2>&1
  check "the gate passes: 2 CORE actions and 1 REACH boundary at or above 30%" 0 $? "$TMP/o183"
  if [ "$(gate_last "$TMP/o183")" = "census gate: PASSED - 2 CORE actions and 1 REACH boundaries at or above 30%" ]; then
    echo "  ok    and its last line says so"; else echo "  FAIL  the passing gate's last line: '$(gate_last "$TMP/o183")'"; fails=$((fails + 1)); fi
  gate_ok "a passing gate" "$TMP/o183" "$TMP/g183/06-census-gate.txt"
  CORE="deposit withdraw" MIN_PCT=50 OUT_DIR="$TMP/g184" "$HERE/census.sh" --aggregate "$C3" > "$TMP/o184" 2>&1
  check "the gate fails: a CORE action below a floor of 50" 1 $? "$TMP/o184"
  l184="$(gate_last "$TMP/o184")"
  case "$l184" in "census gate: FAILED - "*'"withdraw"'*"50%"*) echo "  ok    and its last line names the action and the floor";; *)
    echo "  FAIL  the failing gate's last line does not name the action and the floor: '$l184'"; fails=$((fails + 1));; esac
  case "$l184" in *'"deposit"'*) echo "  FAIL  and it names deposit, which met the floor: '$l184'"; fails=$((fails + 1));; esac
  gate_ok "a gate failed on a CORE floor" "$TMP/o184" "$TMP/g184/06-census-gate.txt"
  REACH="whole credit" MIN_PCT=70 OUT_DIR="$TMP/g185" "$HERE/census.sh" --aggregate "$C3" > "$TMP/o185" 2>&1
  check "the gate fails: a REACH boundary below a floor of 70" 1 $? "$TMP/o185"
  case "$(gate_last "$TMP/o185")" in "census gate: FAILED - "*'"whole credit"'*"70%"*) echo "  ok    and its last line names the boundary and the floor";; *)
    echo "  FAIL  the failing gate's last line does not name the boundary and the floor: '$(gate_last "$TMP/o185")'"; fails=$((fails + 1));; esac
  gate_ok "a gate failed on a REACH floor" "$TMP/o185" "$TMP/g185/06-census-gate.txt"
  { cat "$C3"; printf 'Toy\tU=2\tA:deposit=1/1\n'; } > "$TMP/census3u.tsv"
  CORE="deposit" OUT_DIR="$TMP/g186" "$HERE/census.sh" --aggregate "$TMP/census3u.tsv" > "$TMP/o186" 2>&1
  check "the gate fails: a run met an unexplained revert" 1 $? "$TMP/o186"
  case "$(gate_last "$TMP/o186")" in "census gate: FAILED - "*"UNEXPLAINED"*) echo "  ok    and its last line says why";; *)
    echo "  FAIL  the gate failed on an unexplained revert says: '$(gate_last "$TMP/o186")'"; fails=$((fails + 1));; esac
  OUT_DIR="$TMP/g187" "$HERE/census.sh" --aggregate "$TMP/empty.tsv" > "$TMP/o187" 2>&1
  check "the gate over an empty census: nothing measured" 2 $? "$TMP/o187"
  if [ "$(gate_last "$TMP/o187")" = "census gate: FAILED - NOTHING MEASURED: $TMP/empty.tsv is empty or missing" ] \
    && [ "$(gate_last "$TMP/g187/06-census-gate.txt" 2> /dev/null)" = "$(gate_last "$TMP/o187")" ]; then
    echo "  ok    and its last line and its record say NOTHING MEASURED"; else
    echo "  FAIL  the gate over an empty census: output '$(gate_last "$TMP/o187")', record '$(gate_last "$TMP/g187/06-census-gate.txt" 2> /dev/null)'"; fails=$((fails + 1)); fi
  if [ "$(gate_last "$TMP/o80")" = "census gate: FAILED - MIN_PCT must be a whole number from 1 to 100 (got 'lots'). NOTHING MEASURED." ]; then
    echo "  ok    a floor the gate refuses is its verdict too"; else echo "  FAIL  the refused floor's last line: '$(gate_last "$TMP/o80")'"; fails=$((fails + 1)); fi
  # where the record goes, resolved as run mode resolves it: OUT_DIR (relative to the project), else <project>/.gauntlet/
  # reports - and with no project given the project is the directory it ran from, which is NOT the bench the tsv is in,
  # so the gate says where it wrote
  mkdir -p "$TMP/gbench/census" "$TMP/gcwd/.gauntlet" "$TMP/gproj/.gauntlet";   # the convention installed in both (K26c)
  cp "$C3" "$TMP/gbench/census/long.tsv"
  (cd "$TMP/gcwd" && env -u OUT_DIR CORE="deposit" "$HERE/census.sh" --aggregate "$TMP/gbench/census/long.tsv") > "$TMP/o188" 2>&1
  check "the gate with no project and no OUT_DIR, the tsv in another directory" 0 $? "$TMP/o188"
  g188="$(cd "$TMP/gcwd" && pwd -P)/.gauntlet/reports/06-census-gate.txt"
  if grep -qxF "census gate: record written to $g188 (the census is in $(cd "$TMP/gbench/census" && pwd -P); give the project as the third argument to write it there)" "$TMP/o188"; then
    echo "  ok    and it says where it wrote, and that the census lives elsewhere"; else
    echo "  FAIL  the gate does not say where it wrote:"; grep -a "census gate" "$TMP/o188" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  gate_ok "the record of a gate run with no project" "$TMP/o188" "$g188"
  env -u OUT_DIR CORE="deposit" "$HERE/census.sh" --aggregate "$TMP/gbench/census/long.tsv" "$TMP/gproj" > "$TMP/o189" 2>&1
  check "the gate with the project given as the third argument" 0 $? "$TMP/o189"
  gate_ok "the record in the project given" "$TMP/o189" "$TMP/gproj/.gauntlet/reports/06-census-gate.txt"
  CORE="deposit" OUT_DIR="rel-reports" "$HERE/census.sh" --aggregate "$TMP/gbench/census/long.tsv" "$TMP/gproj" > "$TMP/o190" 2>&1
  check "the gate with a relative OUT_DIR and a project" 0 $? "$TMP/o190"
  gate_ok "a relative OUT_DIR is under the project, as in run mode" "$TMP/o190" "$TMP/gproj/rel-reports/06-census-gate.txt"
  "$HERE/census.sh" "$M" > "$TMP/o61" 2>&1; check "a suite that never calls writeCensus measured nothing" 2 $? "$TMP/o61"

  K="$TMP/kitcopy"; mkdir -p "$K/.gauntlet"; cp -R "$KIT/src" "$KIT/test" "$KIT/foundry.toml" "$K/"; ln -s "$(cd "$KIT/lib" && pwd -P)" "$K/lib"
  # a census file left over from an EARLIER campaign, with a surprise in it: the script has to start from an empty file
  mkdir -p "$K/census"; printf 'ToyVault\tU=5\tA:deposit=1/1\n' > "$K/census/runs.tsv"; cp "$K/census/runs.tsv" "$K/census/long.tsv"
  # This case proves the PLUMBING, not the vault, so a fuzz draw must not be able to fail it: the seed is pinned, and the
  # floor sits far below the measured range (withdraw succeeded in 35 % of runs on 2026-09-23 with forge 1.8.1; a floor
  # of 25 failed on the CI runner by luck - the very gate census.sh's own header warns against). On failure the table is
  # pasted, so the next red is readable without the file.
  MATCH="--match-contract ToyVaultInvariants" CORE="deposit withdraw" MIN_PCT=10 FORGE_FLAGS="--fuzz-seed 0x6b6974" "$HERE/census.sh" "$K" > "$TMP/o62" 2>&1; rc62=$?
  check "end to end: the kit's own vault campaign writes a census, and its core actions are above the floor" 0 $rc62 "$TMP/o62"
  if [ "$rc62" -ne 0 ]; then grep -E "^==|^deposit|^withdraw|floor|FAILED|measured" "$TMP/o62" | head -12 | sed "s/^/        | /"; fi
  if grep -Eq '^== campaign census: ToyVault - [0-9]+ runs ==$' "$TMP/o62"; then echo "  ok    one line per run reached the file"; else
    echo "  FAIL  no census table came out of the kit's own campaign"; tail -5 "$TMP/o62" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # run mode is the smoke check, not the gate: it keeps its 06-census.txt and writes no gate record, prints no gate verdict
  if [ -s "$K/.gauntlet/reports/06-census.txt" ] && [ ! -e "$K/.gauntlet/reports/06-census-gate.txt" ] && ! grep -aq '^census gate:' "$TMP/o62"; then
    echo "  ok    and run mode keeps 06-census.txt, with no gate record and no gate verdict"; else
    echo "  FAIL  run mode's report: 06-census.txt $([ -s "$K/.gauntlet/reports/06-census.txt" ] && echo there || echo MISSING), gate record $([ -e "$K/.gauntlet/reports/06-census-gate.txt" ] && echo WRITTEN || echo absent), verdict line $(grep -ac '^census gate:' "$TMP/o62")"; fails=$((fails + 1)); fi
  # ... and a SECOND draw, with a different pinned seed, over the same floor: one seed that clears the floor could be the
  # lucky one; two different draws that both clear it are the guard against that. The two tables must differ, or the
  # seed was not what chose the draw.
  MATCH="--match-contract ToyVaultInvariants" CORE="deposit withdraw" MIN_PCT=10 FORGE_FLAGS="--fuzz-seed 0x4b33" "$HERE/census.sh" "$K" > "$TMP/o133" 2>&1; rc133=$?
  check "end to end, a second draw (another pinned seed): the core actions are above the floor too" 0 $rc133 "$TMP/o133"
  if [ "$rc133" -ne 0 ]; then grep -E "^==|^deposit|^withdraw|floor|FAILED|measured" "$TMP/o133" | head -12 | sed "s/^/        | /"; fi
  w62="$(grep -E '^withdraw ' "$TMP/o62")"; w133="$(grep -E '^withdraw ' "$TMP/o133")"
  echo "          withdraw, seed 0x6b6974: ${w62:-none}"; echo "          withdraw, seed 0x4b33  : ${w133:-none}"
  if [ -n "$w62" ] && [ -n "$w133" ] && ! cmp -s <(grep -E '^(deposit|withdraw) ' "$TMP/o62") <(grep -E '^(deposit|withdraw) ' "$TMP/o133"); then
    echo "  ok    and the two draws are different draws (their tables differ)"; else
    echo "  FAIL  the two seeds gave the same table, or no table: the second run is not a second draw"; fails=$((fails + 1)); fi
  # the long fuzz starts from an empty census too (65 x 64 is just above the everyday 64 x 64, so it counts as "long")
  USE_BENCH=0 RUNS=65 DEPTH=64 MATCH="--match-contract ToyVaultInvariants" "$HERE/fuzz-long.sh" "$K" > "$TMP/o86" 2>&1
  check "long fuzz on the kit's vault, over a stale census file" 0 $? "$TMP/o86"
  if grep -q "UNEXPLAINED revert: 0" "$TMP/o86"; then echo "  ok    and the stale line did not reach its table"; else
    echo "  FAIL  fuzz-long.sh added an old campaign's lines to the new one"; fails=$((fails + 1)); fi
  # the census path, in one line to paste into the gate (QUICKSTART: "the path fuzz-long.sh printed"); and fuzz-long's
  # own table is not the gate: no gate verdict, no gate record
  if grep -qxF "census: $(cd "$K" && pwd -P)/census/long.tsv" "$TMP/o86" && [ -s "$K/census/long.tsv" ]; then
    echo "  ok    and it prints the census path, absolute, in one line"; else
    echo "  FAIL  fuzz-long.sh does not print the census path: $(grep -a '^census' "$TMP/o86" | head -2 | tr '\n' ' ')"; fails=$((fails + 1)); fi
  if ! grep -aq '^census gate:' "$TMP/o86" && [ ! -e "$K/.gauntlet/reports/06-census-gate.txt" ]; then
    echo "  ok    and its own census table carries no gate verdict and writes no gate record"; else
    echo "  FAIL  fuzz-long.sh's census printed a gate verdict or wrote a gate record"; fails=$((fails + 1)); fi
  # a campaign that is RED next to one that wrote a census: the census must not turn the failure into a pass
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\ncontract T87 { uint256 public n; function poke() external { n++; } }\ncontract RedOnPurposeInvariants is Test { T87 t; function setUp() public { t = new T87(); targetContract(address(t)); }\nfunction invariant_red_on_purpose() public view { assertEq(t.n(), type(uint256).max, "red on purpose"); } }\n' > "$K/test/RedOnPurpose.t.sol"
  MATCH="--match-contract (ToyVaultInvariants|RedOnPurposeInvariants)" MIN_PCT=25 "$HERE/census.sh" "$K" > "$TMP/o87" 2>&1; rc87=$?
  if [ "$rc87" -ne 0 ] && [ "$rc87" -ne 2 ] && grep -q "campaign itself FAILED" "$TMP/o87"; then echo "  ok    a red campaign fails census.sh even when the census table is clean (rc=$rc87)"; else
    echo "  FAIL  census.sh answered $rc87 over a red campaign"; fails=$((fails + 1)); fi
  # a red campaign has NO census (K12): forge calls afterInvariant on every shrink replay, so the file holds a line per
  # replay (measured on a stranger's v4 hook: 198 991 lines for 53 runs). Renamed runs.FAILED.tsv, no table printed.
  if [ ! -e "$K/census/runs.tsv" ] && [ -s "$K/census/runs.FAILED.tsv" ] && ! grep -aq '^== campaign census:' "$TMP/o87" \
    && grep -aqF "$(cd "$K" && pwd -P)/census/runs.FAILED.tsv" "$TMP/o87"; then
    echo "  ok    and it prints no census table: the file is renamed runs.FAILED.tsv, and named"; else
    echo "  FAIL  a red campaign's census: runs.tsv $([ -e "$K/census/runs.tsv" ] && echo KEPT || echo gone), runs.FAILED.tsv $([ -s "$K/census/runs.FAILED.tsv" ] && echo there || echo MISSING), tables $(grep -ac '^== campaign census:' "$TMP/o87")"; fails=$((fails + 1)); fi
  # ... and the long fuzz of that red campaign, in a bench: it FAILS, prints no census path (a red campaign has no census:
  # it was printed until K12, and the gate read 198 991 "runs" of a 53-run campaign), renames the bench's census/long.tsv
  # to long.FAILED.tsv and names it; the gate refuses that file in one line
  BENCH_ROOT="$TMP/fzk" RUNS=65 DEPTH=64 MATCH="--match-contract (ToyVaultInvariants|RedOnPurposeInvariants)" "$HERE/fuzz-long.sh" "$K" > "$TMP/o191" 2>&1; rc191=$?
  FZK="$(find "$TMP/fzk" -maxdepth 1 -name 'fuzz-long-kitcopy-*' -print -quit 2> /dev/null)"
  p191="${FZK:+$(cd "$FZK" && pwd -P)/census/long.FAILED.tsv}"
  if [ "$rc191" -ne 0 ] && [ "$rc191" -ne 2 ] && grep -q "LONG FUZZ FAILED" "$TMP/o191" && [ -n "$FZK" ] \
    && [ "$(grep -ac '^census: ' "$TMP/o191")" = "0" ] && [ ! -e "$FZK/census/long.tsv" ] && [ -s "$p191" ] \
    && grep -aq "the campaign FAILED, so it has NO census" "$TMP/o191" && grep -aqF "$p191" "$TMP/o191"; then
    echo "  ok    a long fuzz that FAILED in a bench prints no census path: it renames the census long.FAILED.tsv and names it (rc=$rc191)"; else
    echo "  FAIL  the failed long fuzz (rc=$rc191) and its census: long.tsv $([ -e "$FZK/census/long.tsv" ] && echo KEPT || echo gone), '$p191' $([ -s "$p191" ] && echo there || echo MISSING)"; grep -a -e 'LONG FUZZ' -e '^census' -e 'NO census' "$TMP/o191" | head -4 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  CORE="deposit" MIN_PCT=1 OUT_DIR="$TMP/g191" "$HERE/census.sh" --aggregate "$p191" > "$TMP/o192" 2>&1
  check "the gate over a FAILED campaign's census refuses it: nothing measured" 2 $? "$TMP/o192"
  if [ "$(wc -l < "$TMP/o192" | tr -d ' ')" = "1" ] && grep -aq '^census gate: FAILED - .*FAILED campaign' "$TMP/o192" && [ ! -e "$TMP/g191/06-census-gate.txt" ]; then
    echo "  ok    in one line, the verdict, and no record"; else
    echo "  FAIL  the refusal of a FAILED census: $(wc -l < "$TMP/o192" | tr -d ' ') line(s), record $([ -e "$TMP/g191/06-census-gate.txt" ] && echo WRITTEN || echo absent)"; sed "s/^/        | /" "$TMP/o192" | head -4; fails=$((fails + 1)); fi
  # the same red campaign with forge told to exit 0 over it (--allow-failure, which FORGE_FLAGS may carry; and
  # FORGE_ALLOW_FAILURE, which is removed): census.sh tabled it and fuzz-long.sh said "long fuzz passed" (V24)
  rm -f "$K/census/runs.FAILED.tsv"
  MATCH="--match-contract (ToyVaultInvariants|RedOnPurposeInvariants)" FORGE_FLAGS="--allow-failure" "$HERE/census.sh" "$K" > "$TMP/o768" 2>&1
  check "census.sh over a red campaign that forge exited 0 on (--allow-failure): not judged" 1 $? "$TMP/o768"
  if grep -q '^census: forge exited 0, and a test FAILED' "$TMP/o768" && ! grep -aq '^== campaign census:' "$TMP/o768" && [ -s "$K/census/runs.FAILED.tsv" ]; then
    echo "  ok    and it says so, prints no table, and renames the census runs.FAILED.tsv"; else
    echo "  FAIL  census.sh judged a failed campaign:"; grep -a -e '^census' -e '^== campaign' "$TMP/o768" | head -5 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  MATCH="--match-contract (ToyVaultInvariants|RedOnPurposeInvariants)" FORGE_ALLOW_FAILURE=true "$HERE/census.sh" "$K" > "$TMP/o769" 2>&1
  check "census.sh over a red campaign with FORGE_ALLOW_FAILURE=true: removed, the campaign FAILED" 1 $? "$TMP/o769"
  grep -qx 'census: ignoring FORGE_ALLOW_FAILURE from the environment' "$TMP/o769" || { echo "  FAIL  and FORGE_ALLOW_FAILURE is not named"; fails=$((fails + 1)); }
  USE_BENCH=0 RUNS=65 DEPTH=64 MATCH="--match-contract (ToyVaultInvariants|RedOnPurposeInvariants)" FORGE_FLAGS="--allow-failure" "$HERE/fuzz-long.sh" "$K" > "$TMP/o770" 2>&1
  check "fuzz-long.sh over a red campaign that forge exited 0 on (--allow-failure): LONG FUZZ FAILED" 1 $? "$TMP/o770"
  if grep -q '^fuzz-long: forge exited 0, and a test FAILED' "$TMP/o770" && grep -q '^LONG FUZZ FAILED' "$TMP/o770" && ! grep -q '^long fuzz passed' "$TMP/o770"; then
    echo "  ok    and it says forge exited 0 over a failed test"; else
    echo "  FAIL  fuzz-long.sh passed a failed campaign:"; grep -a -e '^fuzz-long:' -e 'LONG FUZZ' -e 'long fuzz passed' "$TMP/o770" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -f "$K/census/long.FAILED.tsv" "$K/census/long.tsv"
  # a handler with NO targetSelector: the fuzzer calls every non-view function it has, HandlerBase's `writeCensus(string)`
  # included, with labels of its own making. The fuzzer's calls arrive as their own transactions (msg.sender == tx.origin)
  # and `writeCensus` ignores those, so the census holds one line per run, all under the suite's own label - it used to
  # hold the fuzzer's labels too (bytes nobody can read) and extra lines under the real one.
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/InvariantBase.sol";\ncontract NSHandler is HandlerBase { uint256 public n; constructor() { _addActor(address(0xA1)); } function poke(uint256) external countedSetter("poke") { n++; } }\ncontract NoSelectorInvariants is Test { NSHandler h; function setUp() public { h = new NSHandler(); targetContract(address(h)); }\nfunction invariant_n() public view { assertGe(h.n(), 0); }\nfunction afterInvariant() public { h.writeCensus("NoSelector"); } }\n' > "$K/test/NoSelector.t.sol"
  MATCH="--match-contract NoSelectorInvariants" CORE="poke" FORGE_FLAGS="--fuzz-seed 0x6b37" "$HERE/census.sh" "$K" > "$TMP/o175" 2>&1
  check "a handler without targetSelector: the census is still the suite's own" 0 $? "$TMP/o175"
  # 65, not 64: forge 1.8.1 calls afterInvariant once more than `runs` (measured on a toy, 64 runs: 65 lines with a
  # targetSelector and 65 without, two seeds each); the fuzzer's own writes used to add dozens more, under every label
  if [ "$(grep -ac '^== campaign census:' "$TMP/o175")" = "1" ] && grep -aEq '^== campaign census: NoSelector - 6[45] runs ==$' "$TMP/o175"; then
    echo "  ok    and it holds one label, one line per run: nothing the fuzzer wrote"; else
    echo "  FAIL  the fuzzer's own calls reached the census:"; grep -a '^== campaign census:' "$TMP/o175" | head -5 | cat -v | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # ... but the calls are SPENT, so they are counted and shown: a boundary row in the table, and one line under it
  if grep -aEq '^handler unrestricted: bookkeeping selectors were fuzzed +[1-9][0-9]* +[1-9][0-9]*$' "$TMP/o175" \
    && grep -aqxF "the fuzzer reached HandlerBase's own functions: restrict the handler with targetSelector (doctrine/INVARIANTS.md)" "$TMP/o175"; then
    echo "  ok    and the unrestricted handler is flagged: a boundary row, and the line under the table"; else
    echo "  FAIL  the unrestricted handler is not flagged in the census:"; grep -a -A8 '^== campaign census:' "$TMP/o175" | head -10 | cat -v | sed "s/^/        | /"; fails=$((fails + 1)); fi
  if ! grep -aq "handler unrestricted\|the fuzzer reached HandlerBase" "$TMP/o62" "$TMP/o133"; then
    echo "  ok    and the kit's own vault suite (restricted with targetSelector) is not flagged"; else
    echo "  FAIL  a restricted handler was flagged as unrestricted:"; grep -a "handler unrestricted\|the fuzzer reached" "$TMP/o62" "$TMP/o133" | head -3 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # its filter is MATCH alone: forge's own FOUNDRY_MATCH_TEST from the environment is ignored, and said
  FOUNDRY_MATCH_TEST=no_test_is_named_this MATCH="--match-contract NoSelectorInvariants" CORE="poke" FORGE_FLAGS="--fuzz-seed 0x6b37" "$HERE/census.sh" "$K" > "$TMP/o734" 2>&1
  check "census.sh with FOUNDRY_MATCH_TEST in the environment runs on MATCH alone" 0 $? "$TMP/o734"
  if grep -qx 'census: ignoring FOUNDRY_MATCH_TEST from the environment' "$TMP/o734" && grep -aEq '^== campaign census: NoSelector - 6[45] runs ==$' "$TMP/o734"; then
    echo "  ok    and it says it ignored it, and the campaign MATCH names ran"; else
    echo "  FAIL  census.sh took forge's environment filter, or did not say so:"; grep -a -e '^census' -e '^== campaign' "$TMP/o734" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # an ENVIRONMENT failure (no fs_permissions for ./census) is persisted by forge under cache/invariant/failures/<suite>/
  # and replayed first on the next run, silently (measured: one extra census line per run for as long as it stays).
  # The fix hint has to name that directory, exactly, and it has to be one that exists.
  cp "$K/foundry.toml" "$TMP/kit-toml.keep"; grep -v '^fs_permissions' "$TMP/kit-toml.keep" > "$K/foundry.toml"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/InvariantBase.sol";\ncontract EnvHandler is HandlerBase { uint256 public n; constructor() { _addActor(address(0xA1)); } function poke(uint256) external countedSetter("poke") { n++; } }\ncontract EnvFailInvariants is Test { EnvHandler h; function setUp() public { h = new EnvHandler(); targetContract(address(h)); bytes4[] memory s = new bytes4[](1); s[0] = EnvHandler.poke.selector; targetSelector(FuzzSelector({addr: address(h), selectors: s})); }\nfunction invariant_n() public view { assertGe(h.n(), 0); }\nfunction afterInvariant() public { h.writeCensus("EnvFail"); } }\n' > "$K/test/EnvFail.t.sol"
  rm -rf "$K/cache/invariant/failures/EnvFailInvariants"
  MATCH="--match-contract EnvFailInvariants" "$HERE/census.sh" "$K" > "$TMP/o178" 2>&1; rc178=$?
  if [ "$rc178" -ne 0 ] && [ "$rc178" -ne 1 ]; then echo "  ok    a campaign that cannot write its census fails census.sh (rc=$rc178)"; else
    echo "  FAIL  census.sh answered $rc178 on a campaign with no fs_permissions"; fails=$((fails + 1)); fi
  persisted="$(cd "$K" && pwd -P)/cache/invariant/failures/EnvFailInvariants"
  if [ -d "$persisted" ] && grep -aqF "rm -rf $persisted" "$TMP/o178"; then
    echo "  ok    and the hint names forge's record of the failure, the exact directory, which exists"; else
    echo "  FAIL  the hint does not name the persisted failure ($([ -d "$persisted" ] && echo exists || echo 'not there')):"; grep -a -A4 "no census line" "$TMP/o178" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # ... and it names it whatever the clock says. This case was flaky (K23c 2 of 6): measured 2026-09-27, WSL's clock stepped
  # back 2.3 s during a campaign next to a CPU load, forge's record came out OLDER than census.sh's start marker, and
  # `find -newer` found nothing. Forced here: a wrapper sets the record's mtime to 2023 after `forge test`.
  FW="$TMP/fwrap"; mkdir -p "$FW"
  printf '#!/usr/bin/env bash\n"%s" "$@"; rc=$?\n[ "$1" = test ] && find cache/invariant/failures -type f -exec touch -d @1700000000 {} + 2> /dev/null\nexit $rc\n' "$(command -v forge)" > "$FW/forge"; chmod +x "$FW/forge"
  rm -rf "$persisted"
  PATH="$FW:$PATH" MATCH="--match-contract EnvFailInvariants" "$HERE/census.sh" "$K" > "$TMP/o735" 2>&1
  if [ -d "$persisted" ] && grep -aqF "rm -rf $persisted" "$TMP/o735" && [ -z "$(find "$persisted" -type f -newer "$TMP/o178" 2> /dev/null)" ]; then
    echo "  ok    and it names the record even when the record is OLDER than the start of the campaign (the clock stepped back)"; else
    echo "  FAIL  a record older than the start marker is not named ($([ -d "$persisted" ] && echo exists || echo 'not there')):"; grep -a -A4 "no census line" "$TMP/o735" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  cp "$TMP/kit-toml.keep" "$K/foundry.toml"; rm -rf "$persisted"
  MATCH="--match-contract EnvFailInvariants" "$HERE/census.sh" "$K" > "$TMP/o179" 2>&1
  check "the config fixed and the directory deleted as the hint says: the census passes" 0 $? "$TMP/o179"
  # ---- K12: a persisted failure replays FIRST on the next run and writes a census line like a run (measured on a stranger's
  # v4 hook: 1 011 lines for 1 000 runs, ten persisted failures). forge exposes nothing that tells the replay from a run,
  # so census.sh says it under the table: `runs: <n> (<dir>/failures holds <k> persisted failures of <suites>: ...)`.
  mkdir -p "$TMP/pbench/census" "$TMP/pbench/cache/invariant/failures/SomeInvariants/invariants"
  cp "$C3" "$TMP/pbench/census/long.tsv"
  printf 'seq\n' > "$TMP/pbench/cache/invariant/failures/SomeInvariants/invariants/invariant_a"
  printf 'seq\n' > "$TMP/pbench/cache/invariant/failures/SomeInvariants/invariants/invariant_b"
  CORE="deposit" OUT_DIR="$TMP/g193" "$HERE/census.sh" --aggregate "$TMP/pbench/census/long.tsv" "$TMP/gproj" > "$TMP/o193" 2>&1
  check "the gate over a census next to two persisted failures" 0 $? "$TMP/o193"
  l193="runs: 3 (cache/invariant/failures holds 2 persisted failures of SomeInvariants: they replay first and count)"
  if grep -aqxF "$l193" "$TMP/o193" && grep -aqxF "$l193" "$TMP/g193/06-census-gate.txt" 2> /dev/null \
    && case "$(gate_last "$TMP/o193")" in "census gate: PASSED - "*) true ;; *) false ;; esac; then
    echo "  ok    and it says, under the table and in the record, that they replay first and count; the verdict is still last"; else
    echo "  FAIL  the persisted failures are not named under the census:"; grep -a -e '^runs:' -e '^census gate:' "$TMP/o193" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  if ! grep -aq '^runs: ' "$TMP/o189" "$TMP/o62"; then echo "  ok    and with no persisted failure there is no such line"; else
    echo "  FAIL  a 'runs:' line with no persisted failure:"; grep -a '^runs: ' "$TMP/o189" "$TMP/o62" | head -2 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # a persisted failure of ANOTHER suite is not replayed by this campaign, and it must not be told it was
  mkdir -p "$K/cache/invariant/failures/OtherInvariants/invariants"; printf 'seq\n' > "$K/cache/invariant/failures/OtherInvariants/invariants/invariant_x"
  MATCH="--match-contract NoSelectorInvariants" FORGE_FLAGS="--fuzz-seed 0x6b37" "$HERE/census.sh" "$K" > "$TMP/o194" 2>&1
  if grep -aq '^== campaign census: NoSelector' "$TMP/o194" && ! grep -aq '^runs: ' "$TMP/o194"; then
    echo "  ok    and a suite's persisted failures are not counted against another suite's campaign"; else
    echo "  FAIL  persisted failures of a suite that did not run:"; grep -a -e '^runs:' -e '^== campaign' "$TMP/o194" | head -3 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -rf "$K/cache/invariant/failures/OtherInvariants"
  CENSUS_TABLE_ONLY=1 "$HERE/census.sh" --aggregate "$p191" > "$TMP/o195" 2>&1
  check "the table-only mode refuses a FAILED campaign's census too" 2 $? "$TMP/o195"
  if [ "$(wc -l < "$TMP/o195" | tr -d ' ')" = "1" ] && grep -aq 'FAILED campaign' "$TMP/o195" && ! grep -aq '^== campaign census:' "$TMP/o195"; then echo "  ok    in one line, with no table"; else
    echo "  FAIL  the table-only refusal printed $(wc -l < "$TMP/o195" | tr -d ' ') line(s)"; fails=$((fails + 1)); fi
  # end to end: a long campaign red on purpose persists its failure in the bench; the next, green, replays it first
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/InvariantBase.sol";\ncontract FlipHandler is HandlerBase { uint256 public n; constructor() { _addActor(address(0xA1)); } function poke(uint256) external countedSetter("poke") { n++; } }\ncontract FlipInvariants is Test { FlipHandler h; function setUp() public { h = new FlipHandler(); targetContract(address(h)); bytes4[] memory s = new bytes4[](1); s[0] = FlipHandler.poke.selector; targetSelector(FuzzSelector({addr: address(h), selectors: s})); }\nfunction invariant_flip() public view { if (vm.envOr("K12_FLIP_RED", false)) assertEq(h.n(), 0, "red on purpose"); }\nfunction afterInvariant() public { h.writeCensus("Flip"); } }\n' > "$K/test/Flip.t.sol"
  K12_FLIP_RED=true BENCH_ROOT="$TMP/fzflip" RUNS=65 DEPTH=64 MATCH="--match-contract FlipInvariants" "$HERE/fuzz-long.sh" "$K" > "$TMP/o196" 2>&1; rc196=$?
  FZF="$(find "$TMP/fzflip" -maxdepth 1 -name 'fuzz-long-kitcopy-*' -print -quit 2> /dev/null)"
  BENCH_ROOT="$TMP/fzflip" RUNS=65 DEPTH=64 MATCH="--match-contract FlipInvariants" "$HERE/fuzz-long.sh" "$K" > "$TMP/o197" 2>&1
  check "the same long campaign, green, in the bench where it failed" 0 $? "$TMP/o197"
  n197="$(awk 'END { print NR }' "$FZF/census/long.tsv" 2> /dev/null)"
  if [ "$rc196" -ne 0 ] && [ "$rc196" -ne 2 ] && [ -d "$FZF/cache/invariant/failures/FlipInvariants" ] && [ "${n197:-0}" = "67" ] \
    && grep -aqxF "runs: 67 (cache/invariant/failures holds 1 persisted failures of FlipInvariants: they replay first and count)" "$TMP/o197"; then
    echo "  ok    the persisted failure replayed first and counted: 67 lines for 65 runs (N + 1 + 1), and the line under the table says so"; else
    echo "  FAIL  the red run (rc=$rc196), then the green: ${n197:-no} census lines for 65 runs, persisted $([ -d "$FZF/cache/invariant/failures/FlipInvariants" ] && echo there || echo MISSING)"; grep -a -e '^runs:' -e '^== campaign' "$TMP/o197" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -f "$K/test/NoSelector.t.sol" "$K/test/EnvFail.t.sol" "$K/test/Flip.t.sol"
else
  echo "  SKIPPED - forge, or $KIT/lib, is not available here. mutate.sh, size.sh, battery.sh, fuzz-long.sh and the"
  echo "            black-box mode of bench.sh are NOT proven on this machine."
  skipped=1
fi

# ================================================================= fetch-bytecode.sh --block (K16: a fixture names its block; no network)
# A stub `cast` answers for the chain: it logs how it was called, so these cases see WHICH block the code was read at, and
# what the metadata says, without an endpoint. The refusals come first and write nothing.
echo "== fetch-bytecode.sh --block =="
CB="$TMP/castbin"; mkdir -p "$CB"
cat > "$CB/cast" <<'STUB'
#!/bin/sh
echo "$*" >> "$CAST_LOG"
case "$1" in
  chain-id) echo 1 ;;
  block-number) echo 777 ;;
  block) echo 0x00000000000000000000000000000000000000000000000000000000000000bb ;;
  code) echo 0x6001600155 ;;
  keccak) echo 0x1111111111111111111111111111111111111111111111111111111111111111 ;;
esac
STUB
chmod +x "$CB/cast"
fb() { PATH="$CB:$PATH" CAST_LOG="$TMP/cast.log" RPC_URL="http://127.0.0.1:9" "$HERE/fetch-bytecode.sh" "$@"; }
for bad in latest 0x10 012 -5 ""; do
  fb --block "$bad" 0x000000000000000000000000000000000000dEaD "$TMP/xb.hex" > "$TMP/o301" 2>&1
  check "--block '$bad' is refused (a block NUMBER, decimal)" 1 $? "$TMP/o301"
done
fb --block "https://example.invalid/v2/SECRET" 0x000000000000000000000000000000000000dEaD "$TMP/xb.hex" > "$TMP/o302" 2>&1
check "an endpoint passed as the block is refused" 1 $? "$TMP/o302"
if grep -q "SECRET" "$TMP/o302"; then echo "  FAIL  the refused endpoint was echoed back"; fails=$((fails + 1)); else
  echo "  ok    and it is not echoed back"; fi
fb --block 55 0x000000000000000000000000000000000000dEaD "$TMP/xb.hex" extra > "$TMP/o303" 2>&1
check "a third argument after the block and the two is refused" 1 $? "$TMP/o303"
if [ -e "$TMP/xb.hex" ] || [ -s "$TMP/cast.log" ]; then echo "  FAIL  a refused call wrote a fixture or asked the chain"; fails=$((fails + 1)); else
  echo "  ok    no refused call wrote a fixture or asked the chain"; fi
: > "$TMP/cast.log"
fb --block 55 0x000000000000000000000000000000000000dEaD "$TMP/xb.hex" > "$TMP/o304" 2>&1
check "--block 55: written" 0 $? "$TMP/o304"
if grep -q '"block": 55,' "$TMP/xb.json" && grep -qx 'code --block 55 0x000000000000000000000000000000000000dEaD' "$TMP/cast.log" \
  && ! grep -q '^block-number' "$TMP/cast.log"; then echo "  ok    the code was read AT block 55 and the metadata says 55"; else
  echo "  FAIL  --block 55: metadata $(grep '"block"' "$TMP/xb.json" 2> /dev/null | tr -d ' '), calls: $(tr '\n' ';' < "$TMP/cast.log")"; fails=$((fails + 1)); fi
: > "$TMP/cast.log"; rm -f "$TMP/xb.hex" "$TMP/xb.json"
fb 0x000000000000000000000000000000000000dEaD "$TMP/xb.hex" > "$TMP/o305" 2>&1
check "no --block: written" 0 $? "$TMP/o305"
if grep -q '"block": 777,' "$TMP/xb.json" && grep -qx 'code --block 777 0x000000000000000000000000000000000000dEaD' "$TMP/cast.log"; then
  echo "  ok    without --block the latest number is read FIRST, the code is read at it, and the metadata names it"; else
  echo "  FAIL  no --block: metadata $(grep '"block"' "$TMP/xb.json" 2> /dev/null | tr -d ' '), calls: $(tr '\n' ';' < "$TMP/cast.log")"; fails=$((fails + 1)); fi
if grep -q '"blockHash": "0x0*bb"' "$TMP/xb.json"; then echo "  ok    and the block's hash is recorded next to it"; else
  echo "  FAIL  no blockHash in the metadata"; fails=$((fails + 1)); fi

# ================================================================= backtest.sh (K19: the fixture, its refusals, the report's shape; no network)
# A stub `cast` answers for the chain - chain id, block hash, the PositionManager's key, the manager's state of the pool
# at <from> (extsload: the real slot0 and liquidity of block 26049800), the logs (one real Swap of the chain's ETH / USDC
# 0.05 % pool, in block 26049804, scripts/test/fixtures/backtest-logs-real.json, returned to any range that holds that
# block) - and hands everything that needs no network (abi-encode, keccak, abi-decode, index, to-dec, --version) to the
# real cast. A stub `forge` prints a REAL replay's log of that one swap (DeltaFeeHookBacktest and its control, forge
# 1.8.1: scripts/test/fixtures/backtest-forge-real-1swap.txt), so the report is built from what forge prints (K19b).
# Without a real cast the section is SKIPPED. The replay itself forks the chain and is not here: it is the fork
# battery's (foundry-kit/v4/test/backtest/, README "Backtests").
echo "== backtest.sh =="
REALCAST="$(command -v cast 2> /dev/null)"
if [ -n "$REALCAST" ]; then
  BB="$TMP/btbin"; mkdir -p "$BB"
  cat > "$BB/cast" <<'STUB'
#!/bin/sh
echo "$*" >> "$CAST_LOG"
case "$1" in
  chain-id) echo "${STUB_CHAIN:-1}" ;;
  block) case "$*" in
      *timestamp*) echo 1790282963 ;;
      *) echo "${STUB_HASH:-0x42890220c0576cfd58ac43f6f4418fed0a5eca1b1a39efe43a2b76567864f7a9}" ;;
    esac ;;
  call)
    case "$*" in
      *extsload*) # the pool's state at block 26049800 as the chain holds it: slot0, two fee growths, the liquidity
        printf '[%s, 0x%064d, 0x%064d, %s]\n' "0x0000000001f407d07dfcfd19000000000000000000036600131e3164b4640b8f" 0 0 \
          "${STUB_LIQW:-0x0000000000000000000000000000000000000000000000000260c8a698a0b15f}" ;;
      *)
        if [ -n "${STUB_NOKEY:-}" ]; then z=0x0000000000000000000000000000000000000000; printf '%s\n%s\n0\n0\n%s\n' "$z" "$z" "$z"
        else printf '0x0000000000000000000000000000000000000000\n0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48\n500 [5e2]\n10\n0x0000000000000000000000000000000000000000\n'; fi ;;
    esac ;;
  logs)
    if [ -n "${STUB_429:-}" ] && { [ -n "${STUB_429_ALWAYS:-}" ] || [ ! -e "$STUB_429" ]; }; then
      : > "$STUB_429"; echo "Error: HTTP error 429 with body: {\"error\":\"too many requests\"} from https://example.invalid/v2/SECRET" >&2; exit 1
    fi
    # the stub chain's one Swap is in block 26049804: any range that holds it gets it
    f=""; t=""; p=""
    for w in "$@"; do case "$p" in --from-block) f="$w" ;; --to-block) t="$w" ;; esac; p="$w"; done
    if [ -n "$f" ] && [ -n "$t" ] && [ "$f" -le 26049804 ] && [ "$t" -ge 26049804 ]; then cat "$STUB_LOGS"; else echo "[]"; fi ;;
  *) exec "$REALCAST" "$@" ;;
esac
STUB
  sed -i "s#\"\$REALCAST\"#$REALCAST#" "$BB/cast"; chmod +x "$BB/cast"
  # the stub forge: `forge test` prints a real replay's log (STUB_FORGE_OUT) and exits STUB_FORGE_RC; every call is logged
  cat > "$BB/forge" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_FORGE_CALLS"
case "$1" in
  test) cat "${STUB_FORGE_OUT:?}"; exit "${STUB_FORGE_RC:-0}" ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$BB/forge"
  BTP="$TMP/btp"; mkdir -p "$BTP/.gauntlet"; : > "$BTP/foundry.toml"
  BTID=0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27
  BTF="$BTP/.gauntlet/backtests/21c67e77-26049800-26049810"
  bt() { PATH="$BB:$PATH" CAST_LOG="$TMP/btcast.log" STUB_FORGE_CALLS="$TMP/btforge.log" STUB_LOGS="$FIX/backtest-logs-real.json" \
    STUB_FORGE_OUT="${STUB_FORGE_OUT:-$FIX/backtest-forge-real-1swap.txt}" "${BT_SCRIPT:-$HERE/backtest.sh}" "$@"; }
  btw() { bt "$BTP" --pool "$BTID" --from 26049800 --to 26049810 "$@"; }
  : > "$TMP/btcast.log"
  ( unset RPC_URL; bt > "$TMP/o400" 2>&1 ); check "backtest.sh with no arguments: the usage, refused" 1 $? "$TMP/o400"
  for bad in latest 012 -5 0x10 26049800.0; do
    ( unset RPC_URL; bt "$BTP" --pool "$BTID" --from "$bad" --to 26049810 > "$TMP/o401" 2>&1 )
    check "backtest.sh --from '$bad' is refused (a block NUMBER, decimal)" 1 $? "$TMP/o401"
    grep -q "takes a block number in decimal" "$TMP/o401" || { echo "  FAIL  --from '$bad' was not refused AS a block number"; fails=$((fails + 1)); }
  done
  ( unset RPC_URL; bt "$BTP" --pool "$BTID" --from 26049810 --to 26049810 > "$TMP/o402" 2>&1 )
  check "backtest.sh --to not after --from is refused" 1 $? "$TMP/o402"
  grep -q "must be after --from" "$TMP/o402" || { echo "  FAIL  --to not after --from was not refused for that"; fails=$((fails + 1)); }
  for bad in 0x1234 "0x${BTID:4}zz" "${BTID:2}"; do
    ( unset RPC_URL; bt "$BTP" --pool "$bad" --from 26049800 --to 26049810 > "$TMP/o403" 2>&1 )
    check "backtest.sh --pool '${bad:0:12}...' is refused (0x and 64 hex digits)" 1 $? "$TMP/o403"
    grep -q "takes a v4 pool id" "$TMP/o403" || { echo "  FAIL  --pool '${bad:0:12}...' was not refused AS a pool id"; fails=$((fails + 1)); }
  done
  ( unset RPC_URL; bt "$BTP" --pool "https://example.invalid/v2/SECRET" --from 26049800 --to 26049810 > "$TMP/o404" 2>&1 )
  check "backtest.sh: an endpoint passed as the pool is refused" 1 $? "$TMP/o404"
  if grep -q "SECRET" "$TMP/o404" || ! grep -q "is an endpoint" "$TMP/o404"; then echo "  FAIL  the endpoint was echoed back, or not refused AS an endpoint"; fails=$((fails + 1)); else
    echo "  ok    refused as an endpoint, and not echoed back"; fi
  ( unset RPC_URL; btw --hook 'My;Hook' > "$TMP/o405" 2>&1 ); check "backtest.sh --hook that is not a contract name is refused" 1 $? "$TMP/o405"
  mkdir -p "$TMP/btnotoml/.gauntlet"
  ( unset RPC_URL; bt "$TMP/btnotoml" --pool "$BTID" --from 26049800 --to 26049810 > "$TMP/o406" 2>&1 )
  check "backtest.sh on a directory with no foundry.toml is refused" 1 $? "$TMP/o406"
  mkdir -p "$TMP/btowner"; : > "$TMP/btowner/foundry.toml"
  ( unset RPC_URL; bt "$TMP/btowner" --pool "$BTID" --from 26049800 --to 26049810 > "$TMP/o407" 2>&1 )
  check "backtest.sh in a tree without .gauntlet/ (someone else's): nothing run, exit 2" 2 $? "$TMP/o407"
  if [ -e "$TMP/btowner/.gauntlet" ]; then echo "  FAIL  it created .gauntlet/ in that tree"; fails=$((fails + 1)); else
    echo "  ok    and it created nothing there"; fi
  # the fixture's own directory is held to the same rule when the report goes elsewhere (OUT_DIR outside the tree)
  OUT_DIR="$TMP/btout" RPC_URL="http://127.0.0.1:9" bt "$TMP/btowner" --pool "$BTID" --from 26049800 --to 26049810 --fetch-only > "$TMP/o407b" 2>&1
  check "backtest.sh in someone else's tree with OUT_DIR outside it: the fixture is not written there either, exit 2" 2 $? "$TMP/o407b"
  if [ -e "$TMP/btowner/.gauntlet" ] || [ -s "$TMP/btcast.log" ]; then echo "  FAIL  it wrote into that tree or asked the chain"; fails=$((fails + 1)); else
    echo "  ok    nothing written in that tree, nothing asked of the chain"; fi
  ( unset RPC_URL; btw > "$TMP/o408" 2>&1 ); check "backtest.sh with no fixture and no RPC_URL is refused" 1 $? "$TMP/o408"
  if [ -s "$TMP/btcast.log" ] || [ -e "$BTP/.gauntlet/backtests" ]; then
    echo "  FAIL  a refused call asked the chain or wrote something: $(tr '\n' ';' < "$TMP/btcast.log")"; fails=$((fails + 1)); else
    echo "  ok    no refused call asked the chain or wrote a fixture"; fi
  # a key that does not hash to the pool id, the PositionManager not knowing the pool, another chain: refused, nothing written
  RPC_URL="http://127.0.0.1:9" btw --key 0x0000000000000000000000000000000000000000,0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,3000,60,0x0000000000000000000000000000000000000000 --fetch-only > "$TMP/o409" 2>&1
  check "backtest.sh: a --key that does not hash to the pool id is refused" 1 $? "$TMP/o409"
  STUB_NOKEY=1 RPC_URL="http://127.0.0.1:9" btw --fetch-only > "$TMP/o410" 2>&1
  check "backtest.sh: a pool the PositionManager does not know, and no --key, is refused" 1 $? "$TMP/o410"
  STUB_CHAIN=5 RPC_URL="http://127.0.0.1:9" btw --fetch-only > "$TMP/o411" 2>&1
  check "backtest.sh: an endpoint of another chain is refused" 1 $? "$TMP/o411"
  if ls "$BTP/.gauntlet/backtests/"* > /dev/null 2>&1; then echo "  FAIL  a refused fetch wrote a fixture"; fails=$((fails + 1)); else
    echo "  ok    no refused fetch wrote a fixture"; fi
  # a rate limit twice: stopped, nothing written, the endpoint scrubbed from the error shown
  rm -f "$TMP/bt429"
  STUB_429="$TMP/bt429" STUB_429_ALWAYS=1 RPC_URL="http://127.0.0.1:9" btw --fetch-only > "$TMP/o412" 2>&1
  check "backtest.sh: HTTP 429 twice on the same call stops the fetch" 1 $? "$TMP/o412"
  if [ ! -e "$BTF.tsv" ] && grep -q "retrying once" "$TMP/o412" && ! grep -q SECRET "$TMP/o412"; then
    echo "  ok    it waited, retried once, wrote nothing, and the error shown is scrubbed"; else
    echo "  FAIL  429 twice: fixture $([ -e "$BTF.tsv" ] && echo WRITTEN || echo absent), retry line $(grep -c 'retrying once' "$TMP/o412"), endpoint $(grep -c SECRET "$TMP/o412")"; fails=$((fails + 1)); fi
  # the fetch: one 429 waited out, then the real Swap written as the fixture's line, and a sidecar that names it
  rm -f "$TMP/bt429"; : > "$TMP/btcast.log"
  STUB_429="$TMP/bt429" RPC_URL="http://127.0.0.1:9" btw --fetch-only > "$TMP/o413" 2>&1
  check "backtest.sh --fetch-only with a stub chain (one 429 waited out): fixture written" 0 $? "$TMP/o413"
  want="$(printf '26049804\t1790282963\t198\t474\t0x23617e59a5925b2a4bf75d73ff6711cd0b29de85\t29154854076950637\t-78448606\t4108496466221074272367801\t171357403690873183\t-197351\t625')"
  if [ "$(sed -n 3p "$BTF.tsv" 2> /dev/null)" = "$want" ] && [ "$(awk 'END { print NR }' "$BTF.tsv")" = 3 ]; then
    echo "  ok    the fixture holds the real Swap, decoded: block, timestamp, indices, sender, the six numbers"; else
    echo "  FAIL  the fixture's line: '$(sed -n 3p "$BTF.tsv" 2> /dev/null)'"; fails=$((fails + 1)); fi
  if grep -q '"swaps": 1,' "$BTF.json" && grep -q '"toBlockHash": "0x42890220' "$BTF.json" && grep -qx '  "castCalls": 5' "$BTF.json" \
    && grep -q "\"tsvSha256\": \"0x$(hash_of "$BTF.tsv")\"" "$BTF.json" && grep -q '"fee": 500,' "$BTF.json" \
    && grep -qx 'logs --json --from-block 26049801 --to-block 26049810 --address 0x000000000004444c5dc75cB358380D2e3dE08A90 0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f 0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27' "$TMP/btcast.log"; then
    echo "  ok    the sidecar names 1 swap, block 26049810's hash, the .tsv's SHA-256, the key, 5 calls (the 429 counted); the logs were read from block 26049801"; else
    echo "  FAIL  the sidecar or the calls: $(tr -d '\n' < "$BTF.json" | cut -c1-300) | $(tr '\n' ';' < "$TMP/btcast.log")"; fails=$((fails + 1)); fi
  # K19b, decision 1: after the fetch, the window's swap count and the pool's in-range liquidity at <from>, said
  if grep -qx 'swaps     1 swap in blocks 26049801 .. 26049810' "$TMP/o413" \
    && grep -q '^liquidity 171357403690873183 at the end of block 26049800 (thin below ' "$TMP/o413" \
    && grep -qx 'call --block 26049800 0x000000000004444c5dc75cB358380D2e3dE08A90 extsload(bytes32,uint256)(bytes32\[\]) 0xda8cac368d67cd2f2d8aaa5cc531768e0fa3b1d205c5c5de60da078e1f59bdfc 4' "$TMP/btcast.log" \
    && ! grep -q 'WARNING' "$TMP/o413"; then
    echo "  ok    after the fetch: '1 swap', and the liquidity at block 26049800 read from the manager's state (one extsload), not thin"; else
    echo "  FAIL  no swap count or liquidity after the fetch: $(grep -E '^(swaps|liquidity|backtest: WARNING)' "$TMP/o413" | tr '\n' ';')"; fails=$((fails + 1)); fi
  # reused: offline, nothing asked; with RPC_URL, block <to> re-checked, and another hash refused
  : > "$TMP/btcast.log"
  ( unset RPC_URL; btw --fetch-only > "$TMP/o414" 2>&1 ); check "backtest.sh: the fixture reused without RPC_URL (--fetch-only)" 0 $? "$TMP/o414"
  if [ ! -s "$TMP/btcast.log" ] && grep -q "not re-checked (RPC_URL not set)" "$TMP/o414"; then
    echo "  ok    and nothing was asked of the chain, and it says the block was not re-checked"; else
    echo "  FAIL  reuse offline: calls $(tr '\n' ';' < "$TMP/btcast.log")"; fails=$((fails + 1)); fi
  ( unset RPC_URL; btw > "$TMP/o415" 2>&1 ); check "backtest.sh: a fixture but no RPC_URL - the replay (a fork) refused, fixture kept" 1 $? "$TMP/o415"
  STUB_HASH=0x00000000000000000000000000000000000000000000000000000000000000bb RPC_URL="http://127.0.0.1:9" btw --fetch-only > "$TMP/o416" 2>&1
  check "backtest.sh: block <to> with another hash than the sidecar's (a reorg, another chain) is refused" 1 $? "$TMP/o416"
  # the pair must agree: an edited .tsv, a sidecar's count, a fixture alone, a sidecar alone
  cp "$BTF.tsv" "$TMP/bt.tsv"; cp "$BTF.json" "$TMP/bt.json"
  sed -i '3s/-78448606/-78448607/' "$BTF.tsv"
  ( unset RPC_URL; btw --fetch-only > "$TMP/o417" 2>&1 ); check "backtest.sh: a .tsv edited after its sidecar is refused" 1 $? "$TMP/o417"
  grep -q "disagree on: tsvSha256" "$TMP/o417" && echo "  ok    and it names the hash" || { echo "  FAIL  the refusal does not name the hash"; fails=$((fails + 1)); }
  cp "$TMP/bt.tsv" "$BTF.tsv"; sed -i 's/"swaps": 1,/"swaps": 2,/' "$BTF.json"
  ( unset RPC_URL; btw --fetch-only > "$TMP/o418" 2>&1 ); check "backtest.sh: a sidecar whose count is not the .tsv's is refused" 1 $? "$TMP/o418"
  cp "$TMP/bt.json" "$BTF.json"; rm -f "$BTF.json"
  ( unset RPC_URL; btw --fetch-only > "$TMP/o419" 2>&1 ); check "backtest.sh: a fixture without its sidecar is refused" 1 $? "$TMP/o419"
  grep -q "is there but its sidecar" "$TMP/o419" || { echo "  FAIL  a fixture without its sidecar was not refused for that"; fails=$((fails + 1)); }
  cp "$TMP/bt.json" "$BTF.json"; rm -f "$BTF.tsv"
  ( unset RPC_URL; btw --fetch-only > "$TMP/o420" 2>&1 ); check "backtest.sh: a sidecar without its fixture is refused" 1 $? "$TMP/o420"
  grep -q "is there but its fixture" "$TMP/o420" || { echo "  FAIL  a sidecar without its fixture was not refused for that"; fails=$((fails + 1)); }
  cp "$TMP/bt.tsv" "$BTF.tsv"
  ( unset RPC_URL; btw --fetch-only > "$TMP/o421" 2>&1 ); check "backtest.sh: the pair restored reads again" 0 $? "$TMP/o421"

  # ---- K19b, decision 1: a window with NO swap is said, loudly, and never replayed; a thin one is a warning
  : > "$TMP/btcast.log"; : > "$TMP/btforge.log"
  bw0() { bt "$BTP" --pool "$BTID" --from 26049810 --to 26049820 "$@"; } # the stub chain has no swap in 26049811 .. 26049820
  RPC_URL="http://127.0.0.1:9" bw0 --fetch-only > "$TMP/o430" 2>&1
  check "backtest.sh --fetch-only on a window with no swap: the fixture is written, FIXTURE READY (0 swaps)" 0 $? "$TMP/o430"
  if grep -q '^backtest: FIXTURE READY (0 swaps) - ' "$TMP/o430" \
    && grep -qx 'backtest: no swap in this window: pick another; the pool had 1 swap in the 1 000 blocks before 26049810 (blocks 26048810 .. 26049809)' "$TMP/o430" \
    && grep -qx 'liquidity 171357403690873183 at the end of block 26049810 (no swap in the window: nothing to measure it against)' "$TMP/o430" \
    && [ "$(grep -c '^logs ' "$TMP/btcast.log")" = 101 ] && grep -qx 'logs --json --from-block 26049800 --to-block 26049809 .*' "$TMP/btcast.log"; then
    echo "  ok    it says 0 swaps, and the 1 swap of the 1 000 blocks before 26049810 (100 more eth_getLogs, in the fetch's chunks of 10)"; else
    echo "  FAIL  0 swaps not said, or the count before <from> is not the stub chain's: $(grep '^backtest:' "$TMP/o430" | tr '\n' ';') logs calls $(grep -c '^logs ' "$TMP/btcast.log")"; fails=$((fails + 1)); fi
  : > "$TMP/btforge.log"
  RPC_URL="http://127.0.0.1:9" bw0 > "$TMP/o431" 2>&1
  check "backtest.sh: the replay of a window with no swap is refused" 1 $? "$TMP/o431"
  if grep -q '^backtest: no swap in this window: pick another; the pool had 1 swap in the 1 000 blocks before 26049810' "$TMP/o431" \
    && [ ! -s "$TMP/btforge.log" ] && ! ls "$BTP/.gauntlet/reports/"*26049810-26049820* > /dev/null 2>&1; then
    echo "  ok    and forge was never run, no report written"; else
    echo "  FAIL  a window with no swap reached forge ($(tr '\n' ';' < "$TMP/btforge.log")) or wrote a report"; fails=$((fails + 1)); fi
  : > "$TMP/btcast.log"
  ( unset RPC_URL; bw0 --fetch-only > "$TMP/o432" 2>&1 ); check "backtest.sh: a fixture with no swap, reused offline: FIXTURE READY (0 swaps)" 0 $? "$TMP/o432"
  if grep -q '^backtest: FIXTURE READY (0 swaps) - ' "$TMP/o432" && grep -q 'before 26049810 was not counted (RPC_URL not set)' "$TMP/o432" \
    && [ ! -s "$TMP/btcast.log" ]; then echo "  ok    and offline it says the count before <from> was not made, asking nothing"; else
    echo "  FAIL  offline, 0 swaps: $(grep '^backtest:' "$TMP/o432" | tr '\n' ';') calls $(tr '\n' ';' < "$TMP/btcast.log")"; fails=$((fails + 1)); fi
  # thin: 10^12 in range, where the window's one swap (78.4 USDC in) calls for 3.0e14 - a WARNING, and the fixture ready
  STUB_LIQW=0x000000000000000000000000000000000000000000000000000000e8d4a51000 RPC_URL="http://127.0.0.1:9" btw --fetch-only > "$TMP/o433" 2>&1
  check "backtest.sh: a liquidity thin for the window is a warning, not a refusal" 0 $? "$TMP/o433"
  if grep -q '^backtest: WARNING: thin for this window - 1000000000000 in range at block 26049800 is below 302562934815562' "$TMP/o433" \
    && grep -q '^backtest: FIXTURE READY - ' "$TMP/o433"; then echo "  ok    it warns with both numbers, and goes on"; else
    echo "  FAIL  no thin warning: $(grep -E '^(liquidity|backtest:)' "$TMP/o433" | tr '\n' ';')"; fails=$((fails + 1)); fi
  STUB_LIQW=0x0000000000000000000000000000000000000000000000000000000000000000 RPC_URL="http://127.0.0.1:9" btw --fetch-only > "$TMP/o433b" 2>&1
  check "backtest.sh: no liquidity in range at <from> is a warning that names the replay's stop" 0 $? "$TMP/o433b"
  grep -q '^backtest: WARNING: the pool has NO liquidity in range at the end of block 26049800' "$TMP/o433b" \
    && echo "  ok    it says so" || { echo "  FAIL  no warning for 0 in range"; fails=$((fails + 1)); }

  # ---- K19b, decisions 4 and 5: one report per pool, window and hook; the report's words and its hook-minus-control
  : > "$TMP/btforge.log"
  RPC_URL="http://127.0.0.1:9" btw > "$TMP/o434" 2>&1
  check "backtest.sh: the replay (stub forge, a real log) writes its report" 0 $? "$TMP/o434"
  BTR="$BTP/.gauntlet/reports/07-backtest-21c67e77-26049800-26049810"
  if [ -f "$BTR-all.txt" ] && [ -f "$BTR-all-forge.txt" ] && [ ! -e "$BTP/.gauntlet/reports/07-backtest.txt" ] \
    && grep -qx "backtest: REPORT WRITTEN - $BTR-all.txt (DeltaFeeHook; passed 2)" "$TMP/o434" \
    && grep -q "^test --match-contract Backtest\$ -vv" "$TMP/btforge.log"; then
    echo "  ok    the report is 07-backtest-<id8>-<from>-<to>-all.txt (no --hook), forge's log next to it"; else
    echo "  FAIL  the report's name: $(ls "$BTP/.gauntlet/reports/" 2> /dev/null | tr '\n' ' ') | $(tail -1 "$TMP/o434")"; fails=$((fails + 1)); fi
  cp "$BTR-all.txt" "$TMP/bt-all.txt" 2> /dev/null
  sed -i 's/"castCalls": 5/"castCalls": 1/' "$BTF.json" # castCalls is not in the pair's check: the report's plural is
  RPC_URL="http://127.0.0.1:9" btw --hook DeltaFeeHook > "$TMP/o435" 2>&1
  check "backtest.sh --hook DeltaFeeHook: a report of its own" 0 $? "$TMP/o435"
  sed -i 's/"castCalls": 1/"castCalls": 5/' "$BTF.json"
  if [ -f "$BTR-DeltaFeeHook.txt" ] && [ -f "$BTR-DeltaFeeHook-forge.txt" ] && cmp -s "$BTR-all.txt" "$TMP/bt-all.txt"; then
    echo "  ok    07-backtest-<id8>-<from>-<to>-DeltaFeeHook.txt, and the -all report of the run before is untouched"; else
    echo "  FAIL  --hook's report: $(ls "$BTP/.gauntlet/reports/" 2> /dev/null | tr '\n' ' ')"; fails=$((fails + 1)); fi
  if grep -q '^fixture      .gauntlet/backtests/21c67e77-26049800-26049810.tsv: 1 swap, sha256 ' "$BTR-all.txt" \
    && grep -q '^rpc          fetch: 5 calls to the endpoint' "$BTR-all.txt" && grep -q '^rpc          fetch: 1 call to the endpoint' "$BTR-DeltaFeeHook.txt" \
    && grep -q '^             this run, this script: 2 calls (the re-check of block 26049810 and the liquidity at block 26049800' "$BTR-all.txt" \
    && grep -q "^             the replay: forge's own requests (its fork at block 26049800), and UNCOUNTED" "$BTR-all.txt" \
    && grep -q '^liquidity    in range: 171357403690873183 at the end of block 26049800' "$BTR-all.txt"; then
    echo "  ok    the report: '1 swap', '5 calls' / '1 call', the replay's requests forge's and uncounted, the liquidity at <from>"; else
    echo "  FAIL  the report's words: $(grep -E '^(fixture|rpc|liquidity|  +this run|  +the replay)' "$BTR-all.txt" | tr '\n' ';' | cut -c1-600)"; fails=$((fails + 1)); fi
  # (captured, then matched: a pipeline into `grep -q` under pipefail can lose its writer to SIGPIPE and read false, K62)
  bt_minus="$(sed -n '/^== each hook minus its control, per total/,/^$/p' "$BTR-all.txt")"
  if grep -qx 'DeltaFeeHook 0 0 0 0 87475501957618 0 0 0 0 0 0 0 0 0 122294 122294 0 0' <<< "$bt_minus"; then
    echo "  ok    the hook minus its control, per total: took0 87475501957618, gas +122294"; else
    echo "  FAIL  hook minus control: $(sed -n '/^== each hook minus/,/^$/p' "$BTR-all.txt" | tr '\n' ';')"; fails=$((fails + 1)); fi
  if grep -q "^control(DeltaFeeHook): NOT asserted: this window (26049800 .. 26049810) is not the kit's committed one" "$BTR-all.txt"; then
    echo "  ok    the control's fidelity: NOT asserted on a window that is not the kit's, said in the report"; else
    echo "  FAIL  no fidelity line: $(sed -n '/^== the control.s fidelity/,/^$/p' "$BTR-all.txt" | tr '\n' ';')"; fails=$((fails + 1)); fi
  # exact on amounts a double cannot hold: lpFees0 10^24 + 1 against 10^24 - 1, and a negative (lpFees1 39224 - 39226)
  awk -F'|' -v OFS='|' '$2 == "total" && $3 == "DeltaFeeHook" { $14 = "1000000000000000000000001" }
    $2 == "total" && $3 == "control(DeltaFeeHook)" { $14 = "999999999999999999999999"; $15 = "39226" } { print }' \
    "$FIX/backtest-forge-real-1swap.txt" > "$TMP/btbig.txt"
  STUB_FORGE_OUT="$TMP/btbig.txt" RPC_URL="http://127.0.0.1:9" btw > "$TMP/o436" 2>&1
  check "backtest.sh: a log with 25-digit totals is reported" 0 $? "$TMP/o436"
  bt_minus="$(sed -n '/^== each hook minus its control, per total/,/^$/p' "$BTR-all.txt")"
  if grep -qx 'DeltaFeeHook 0 0 0 0 87475501957618 0 0 0 0 0 2 -2 0 0 122294 122294 0 0' <<< "$bt_minus"; then
    echo "  ok    the difference is exact (2, not 0) and signed (-2)"; else
    echo "  FAIL  25 digits: $(sed -n '/^== each hook minus/,/^$/p' "$BTR-all.txt" | tr '\n' ';')"; fails=$((fails + 1)); fi
  grep -v 'BT|fidelity|' "$FIX/backtest-forge-real-1swap.txt" > "$TMP/btnofid.txt"
  STUB_FORGE_OUT="$TMP/btnofid.txt" RPC_URL="http://127.0.0.1:9" btw > "$TMP/o437" 2>&1
  check "backtest.sh: a log whose control printed no fidelity line is reported" 0 $? "$TMP/o437"
  grep -q '^control(DeltaFeeHook): no line - its _checkControl printed none' "$BTR-all.txt" \
    && echo "  ok    and the report says the control's _checkControl printed nothing" \
    || { echo "  FAIL  a control with no fidelity line is not said"; fails=$((fails + 1)); }

  # ---- K19b, decision 4: the kit's own module takes no fixture a user fetches, unless --allow-kit-fixtures
  BTK="$TMP/btkit"; mkdir -p "$BTK/scripts/lib" "$BTK/foundry-kit/v4/.gauntlet"
  cp "$HERE/backtest.sh" "$BTK/scripts/"; cp "$HERE/lib/"*.sh "$BTK/scripts/lib/"; : > "$BTK/foundry-kit/v4/foundry.toml"
  : > "$TMP/btcast.log"
  BT_SCRIPT="$BTK/scripts/backtest.sh" RPC_URL="http://127.0.0.1:9" bt "$BTK/foundry-kit/v4" --pool "$BTID" --from 26049800 --to 26049810 --fetch-only > "$TMP/o438" 2>&1
  check "backtest.sh: a fetch into the kit's own v4 module is refused" 1 $? "$TMP/o438"
  if grep -q "is the kit's own v4 module" "$TMP/o438" && [ ! -e "$BTK/foundry-kit/v4/.gauntlet/backtests" ] && [ ! -s "$TMP/btcast.log" ]; then
    echo "  ok    nothing asked of the chain, nothing written there"; else
    echo "  FAIL  the kit's module: $(ls -R "$BTK/foundry-kit/v4/.gauntlet" | tr '\n' ' ') calls $(tr '\n' ';' < "$TMP/btcast.log")"; fails=$((fails + 1)); fi
  BT_SCRIPT="$BTK/scripts/backtest.sh" RPC_URL="http://127.0.0.1:9" bt "$BTK/foundry-kit/v4" --pool "$BTID" --from 26049800 --to 26049810 --fetch-only --allow-kit-fixtures > "$TMP/o439" 2>&1
  check "backtest.sh --allow-kit-fixtures: the fetch into the kit's module goes ahead" 0 $? "$TMP/o439"
  ( unset RPC_URL; BT_SCRIPT="$BTK/scripts/backtest.sh" bt "$BTK/foundry-kit/v4" --pool "$BTID" --from 26049800 --to 26049810 --fetch-only > "$TMP/o440" 2>&1 )
  check "backtest.sh: a fixture already in the kit's module (its committed window) is reused without the flag" 0 $? "$TMP/o440"
else
  echo "  SKIPPED - no cast on the PATH: backtest.sh's fetch and refusals are NOT proven on this machine."
  skipped=1
fi
# the report's totals table, read by scripts/lib/parse.sh: a real report, and near misses that must be refused
parse_backtest_totals "$FIX/backtest-report-real.txt" > "$TMP/o422"; rc=$?
check "parse_backtest_totals: a real report's table is read" 0 $rc "$TMP/o422"
if [ "$(awk 'END { print NR }' "$TMP/o422")" = 6 ] && grep -q '^DeltaFeeHook 44 44 0 0 ' "$TMP/o422"; then
  echo "  ok    six runs, the DeltaFeeHook row as written"; else echo "  FAIL  rows read: $(tr '\n' ';' < "$TMP/o422")"; fails=$((fails + 1)); fi
for nm in dash short header twice sum; do
  out="$(parse_backtest_totals "$FIX/backtest-report-nm-$nm.txt")"; rc=$?
  check "parse_backtest_totals refuses backtest-report-nm-$nm.txt (never a number read as 0)" 2 $rc
  [ -z "$out" ] || { echo "  FAIL  and it printed rows: $out"; fails=$((fails + 1)); }
done
parse_backtest_totals "$FIX/backtest-report-nm-none.txt" > /dev/null; check "parse_backtest_totals: no totals table at all" 1 $?

# --- K40/K41 ---
# ================================================================= next.sh refuses the kit's example, a pending test not
# seen red, a cited file that does not exist; pending-red.sh (K40, K41: what the local-model walk's agent wrote that nothing read, judged 2026-09-30)
echo "== next.sh: the kit's example, pending/ seen red, cited files (K40/K41) =="
# shellcheck source=lib/pending-record.sh
. "$HERE/lib/pending-record.sh" || { echo "selftest: $HERE/lib/pending-record.sh is missing"; exit 1; }
KX_KIT="$(cd "$HERE/.." && pwd)"
KX_FIRST='next: FIRST - fill STATE.md: it is still the kit'"'"'s example (state/README.md, "empty the examples")'
kx_one() { # kx_one <n> <label> <expected rc> <the exact line it must print, alone> <next.sh args...>
  local n="$1" label="$2" rc="$3" line="$4"; shift 4
  nx "$NX" "$@" > "$TMP/o$n" 2>&1; check "$label" "$rc" $? "$TMP/o$n"
  if [ "$(cat "$TMP/o$n")" = "$line" ]; then echo "  ok    one line: ${line:0:150}"; else
    echo "  FAIL  not the one line '${line:0:150}':"; sed "s/^/        | /" "$TMP/o$n"; fails=$((fails + 1)); fi
}
kx_row() { # kx_row <n> <label> <the row it must give> <next.sh args...>: rc 0 and that row
  local n="$1" label="$2" row="$3"; shift 3
  nx "$NX" "$@" > "$TMP/o$n" 2>&1; check "$label" 0 $? "$TMP/o$n"
  grep -q "^next: row $row - " "$TMP/o$n" || { echo "  FAIL  and it did not give row $row:"; sed "s/^/        | /" "$TMP/o$n"; fails=$((fails + 1)); }
}
kx_proj() { # kx_proj <dir>: a project with .gauntlet/STATE.md, a new project's (row 4), and nothing else
  rm -rf "$1"; mkdir -p "$1/.gauntlet"; cp "$FIX/state-new-project.md" "$1/.gauntlet/STATE.md"
}
# ---- K40: the kit's example is not a state (the local-model walk, at 00:48 and 00:55: "next: row 13 - a REGRESSION round ... r05")
kx_one 4001 "next.sh refuses the kit's example state/STATE.md (it answered row 13 on it, twice, in the local-model walk)" 2 "$KX_FIRST" "$HERE/../state/STATE.md"
PENDING_RED=0 CITED_FILES=0 nx "$NX" "$HERE/../state/STATE.md" > "$TMP/o4002" 2>&1; check "... and no escape turns that off (PENDING_RED=0 CITED_FILES=0)" 2 $? "$TMP/o4002"
grep -qxF "$KX_FIRST" "$TMP/o4002" || { echo "  FAIL  and not with the FIRST line"; fails=$((fails + 1)); }
KX="$TMP/kx"; kx_proj "$KX"
kx_row 4003 "next.sh: a new project's STATE.md, no DECISIONS.md or LOG.md beside it: the row" 4 "$KX/.gauntlet/STATE.md"
sed '/Example file. The project is fictional/d' "$HERE/../state/STATE.md" > "$KX/.gauntlet/STATE.md"
kx_init() { printf '%s - %s/scripts/init-state.sh %s writes an empty one' "$KX_FIRST" "$KX_KIT" "$(cd "$1" && pwd)"; }   # K50: the STATE.md refusal names init-state.sh
kx_one 4004 "next.sh refuses the example without its marker line: BlockCapHook in the title" 2 "$(kx_init "$KX")" "$KX/.gauntlet/STATE.md"
sed '1s/BlockCapHook/SomeHook/' "$HERE/../state/STATE.md" > "$KX/.gauntlet/STATE.md"
kx_one 4005 "next.sh refuses the example with another title: its marker line" 2 "$(kx_init "$KX")" "$KX/.gauntlet/STATE.md"
kx_proj "$KX"; printf '\nThe owner'"'"'s notes compare this hook with the kit'"'"'s example, BlockCapHook.\n' >> "$KX/.gauntlet/STATE.md"
kx_row 4006 "next.sh: a real STATE.md that names BlockCapHook in its prose, not in its title: the row" 4 "$KX/.gauntlet/STATE.md"
kx_proj "$KX"; cp "$HERE/../state/LOG.md" "$KX/.gauntlet/LOG.md"
kx_one 4007 "next.sh refuses a filled STATE.md beside the kit's example LOG.md" 2 "${KX_FIRST/STATE.md:/LOG.md:}" "$KX/.gauntlet/STATE.md"
kx_proj "$KX"; cp "$HERE/../state/DECISIONS.md" "$KX/.gauntlet/DECISIONS.md"
kx_one 4008 "next.sh refuses a filled STATE.md beside the kit's example DECISIONS.md" 2 "${KX_FIRST/STATE.md:/DECISIONS.md:}" "$KX/.gauntlet/STATE.md"
for f in STATE LOG DECISIONS; do
  if grep -qxF '*Example file. The project is fictional. Delete this and start yours.*' "$HERE/../state/$f.md"; then
    echo "  ok    the kit's example state/$f.md keeps its marker line"; else echo "  FAIL  state/$f.md has lost its marker line"; fails=$((fails + 1)); fi
done
# ---- K41: a file the record cites must exist (the local-model walk's judge: DECISIONS.md cited five pending tests and a fork test that never existed)
KX_CITE='next: DECISIONS.md cites a file that does not exist: pending/F-2_units.t.sol'
kx_cite() { # kx_cite <n> <label> <expected rc> <DECISIONS.md body>: the new project, a DECISIONS.md, next.sh
  local n="$1" label="$2" rc="$3"
  kx_proj "$KX"; mkdir -p "$KX/src" "$KX/test" "$KX/.gauntlet/reports"; echo "contract Hook {}" > "$KX/src/Hook.sol"; echo "contract HookTest {}" > "$KX/test/Hook.t.sol"   # K48: a cited file is a non-empty one
  printf '# DECISIONS - SomeHook\n\n%s\n' "$4" > "$KX/.gauntlet/DECISIONS.md"
  nx "$NX" "$KX/.gauntlet/STATE.md" > "$TMP/o$n" 2>&1; check "$label" "$rc" $? "$TMP/o$n"
}
kx_cite 4010 "next.sh refuses a DECISIONS.md citing pending/F-2_units.t.sol, which does not exist" 2 'D-02: the test is `pending/F-2_units.t.sol` (red).'
if grep -q "^$KX_CITE (line 3 of " "$TMP/o4010" && ! grep -q 'CITED_FILES' "$TMP/o4010" && [ "$(wc -l < "$TMP/o4010" | tr -d ' ')" = 1 ]; then
  echo "  ok    one line, naming the file, the path and its line - and no escape (v0.4.2: the header has it)"; else echo "  FAIL  not the line:"; sed "s/^/        | /" "$TMP/o4010"; fails=$((fails + 1)); fi
kx_cite 4011 "next.sh: the files it cites exist (src/, test/): the row" 0 'The hook is `src/Hook.sol`, its tests ./test/Hook.t.sol and the round report .gauntlet/reports/ (a directory).'
kx_cite 4012 "next.sh: the missing path inside a fenced code block is not a citation" 0 "$(printf '```\npending/F-2_units.t.sol\n```')"
for w in "to write" "planned" "TODO"; do
  kx_cite 4013 "next.sh: the missing path after '$w' on its line is not a citation" 0 "The finding's test, $w: \`pending/F-2_units.t.sol\`."
done
kx_cite 4014 "next.sh: a pattern (pending/F-*.t.sol), a placeholder (pending/<id>.t.sol) and a range (pending/F-1..F-4.t.sol) are not citations" 0 \
  'Run `pending/F-*.t.sol`; each finding in pending/<id>.t.sol; the tests pending/F-1..F-4.t.sol.'
kx_cite 4015 "next.sh: a missing path inside a longer one (lib/forge-std/src/Nope.sol) is not a citation" 0 'Imports lib/forge-std/src/Nope.sol and ../v4-core/src/Nope.sol.'
kx_cite 4016 "next.sh refuses the missing path before 'TODO' on the same line" 2 'The test is pending/F-2_units.t.sol (TODO: the fork test test/fork/Fork.t.sol).'
grep -q "^$KX_CITE " "$TMP/o4016" || { echo "  FAIL  and not for the path before TODO: $(head -1 "$TMP/o4016")"; fails=$((fails + 1)); }
mkdir -p "$KX/.gauntlet/bench/v01/test/verify"; echo "contract V01 {}" > "$KX/.gauntlet/bench/v01/test/verify/V01.t.sol"
printf '# DECISIONS - SomeHook\n\nReproduced in bench `.gauntlet/bench/v01`, `test/verify/V01.t.sol`.\n' > "$KX/.gauntlet/DECISIONS.md"
kx_row 4017 "next.sh: a path found in one of the project's benches (.gauntlet/bench/v01/test/verify/V01.t.sol) exists" 4 "$KX/.gauntlet/STATE.md"
# K47: LOG.md is history - a file it names may have been moved or deleted since, legitimately; it is not read for citations
kx_proj "$KX"; printf '# LOG - SomeHook\n\nr01 closed: .gauntlet/reports/r01.md.\n' > "$KX/.gauntlet/LOG.md"
kx_row 4018 "next.sh: a LOG.md citing .gauntlet/reports/r01.md, which does not exist, is not refused (a LOG is history)" 4 "$KX/.gauntlet/STATE.md"
printf '# LOG - SomeHook\n\n2026-09-01: wrote `pending/F-3_fee.t.sol` and `src/OldHook.sol`.\n2026-09-02: F-3 fixed, `pending/F-3_fee.t.sol` moved to `test/F-3_fee.t.sol`; `src/OldHook.sol` deleted.\n' > "$KX/.gauntlet/LOG.md"
kx_row 4024 "next.sh: a LOG.md naming files deleted or moved since (pending/F-3_fee.t.sol, src/OldHook.sol, test/F-3_fee.t.sol) is not refused" 4 "$KX/.gauntlet/STATE.md"
grep -q 'cites a file' "$TMP/o4024" && { echo "  FAIL  and a cited file was reported: $(grep 'cites a file' "$TMP/o4024")"; fails=$((fails + 1)); }
printf '# DECISIONS - SomeHook\n\nD-03: F-3 is fixed; its test is `test/F-3_fee.t.sol`.\n' > "$KX/.gauntlet/DECISIONS.md"
nx "$NX" "$KX/.gauntlet/STATE.md" > "$TMP/o4025" 2>&1; check "... but the DECISIONS.md beside it citing test/F-3_fee.t.sol, which does not exist, still is" 2 $? "$TMP/o4025"
grep -q '^next: DECISIONS.md cites a file that does not exist: test/F-3_fee.t.sol ' "$TMP/o4025" || { echo "  FAIL  and not naming DECISIONS.md and the path: $(head -1 "$TMP/o4025")"; fails=$((fails + 1)); }
# K47: next.sh <proj> - the project's directory reads its .gauntlet/STATE.md, then its STATE.md (the entry skill's last line)
kx_proj "$KX"
kx_row 4026 "next.sh <proj>: a project directory with .gauntlet/STATE.md - the row" 4 "$KX"
KXR="$TMP/kxr"; rm -rf "$KXR"; mkdir -p "$KXR"; cp "$FIX/state-new-project.md" "$KXR/STATE.md"
kx_row 4027 "next.sh <proj>: a project directory with STATE.md at its root - the row" 4 "$KXR"
cp "$HERE/../state/STATE.md" "$KXR/STATE.md"
kx_one 4028 "next.sh <proj>: the kit's example there is refused as the file is" 2 "$(kx_init "$KXR")" "$KXR"
rm -f "$KXR/STATE.md"; KXRA="$(cd "$KXR" && pwd)"
# K53: the refusal names the command that writes one, absolute like the others (V50: the walk from nothing read
# state/README.md here, a step the other refusals do not cost)
kx_one 4029 "next.sh <proj>: a directory with no STATE.md is refused, naming the directory, both places and the command" 2 \
  "next: REFUSED - $KXRA has no .gauntlet/STATE.md and no STATE.md: $KX_KIT/scripts/init-state.sh $KXRA writes one (or give the STATE.md)" "$KXR"
kx_proj "$KX"; sed 's/^notes: .*/notes:                     pending: F-7 - see test\/Gone.t.sol, owner undecided/' "$FIX/state-new-project.md" > "$KX/.gauntlet/STATE.md"
nx "$NX" "$KX/.gauntlet/STATE.md" > "$TMP/o4019" 2>&1; check "next.sh refuses a pending: note in the flag block citing test/Gone.t.sol, which does not exist (the fence does not hide the notes)" 2 $? "$TMP/o4019"
grep -q '^next: STATE.md cites a file that does not exist: test/Gone.t.sol ' "$TMP/o4019" || { echo "  FAIL  and not for that: $(head -1 "$TMP/o4019")"; fails=$((fails + 1)); }
sed 's/^notes: .*/notes:                     see test\/Gone.t.sol/' "$FIX/state-new-project.md" > "$KX/.gauntlet/STATE.md"
kx_row 4020 "next.sh: another note in the flag block (a fenced block) citing test/Gone.t.sol is not read" 4 "$KX/.gauntlet/STATE.md"
kx_cite 4021 "next.sh refuses the missing citation again, for the escape's case" 2 'D-02: `pending/F-2_units.t.sol`.'
CITED_FILES=0 nx "$NX" "$KX/.gauntlet/STATE.md" > "$TMP/o4022" 2>&1; check "next.sh with CITED_FILES=0: the row" 0 $? "$TMP/o4022"
grep -q '^next: CITED_FILES=0 - ' "$TMP/o4022" || { echo "  FAIL  and CITED_FILES=0 was not said"; fails=$((fails + 1)); }
CITED_FILES=no nx "$NX" "$KX/.gauntlet/STATE.md" > "$TMP/o4023" 2>&1; check "next.sh refuses CITED_FILES set to anything but 0" 2 $? "$TMP/o4023"
grep -qF "CITED_FILES='no' is not 0" "$TMP/o4023" || { echo "  FAIL  and not for that: $(head -1 "$TMP/o4023")"; fails=$((fails + 1)); }
# ---- K41: a pending test needs its record of being seen red on src/ as it stands (no forge: the records are written here)
KP="$TMP/kp"; kx_proj "$KP"; mkdir -p "$KP/src" "$KP/pending"; printf 'contract H {}\n' > "$KP/src/H.sol"; printf '// F-1\n' > "$KP/pending/F-1.t.sol"
sed 's/^notes: .*/notes:                     pending: F-1 - a stranger takes a registered id, owner undecided/' "$FIX/state-new-project.md" > "$KP/.gauntlet/STATE.md"
KPA="$(cd "$KP" && pwd)"
KP_LINE="next: pending/F-1.t.sol - not seen red on the code as it stands: $KX_KIT/scripts/pending-red.sh $KPA pending/F-1.t.sol"
# K61: a record made on another key is named stale, with the part that changed when the record says its parts (these
# handwritten ones do not)
KP_STALE="next: pending/F-1.t.sol - not seen red on the code as it stands (its red record of $(date +%F) is stale - one of src/, test/, pending/, foundry.toml and remappings.txt changed since; that record does not say which): $KX_KIT/scripts/pending-red.sh $KPA pending/F-1.t.sol"
kx_one 4030 "next.sh refuses pending/F-1.t.sol with no record of being seen red" 2 "$KP_LINE" "$KP/.gauntlet/STATE.md"
kp_rec="$(pending_record_path "$KPA" pending/F-1.t.sol)"; mkdir -p "$(dirname "$kp_rec")"; pending_record_head pending/F-1.t.sol "${kp_rec##*.}" > "$kp_rec"
kx_row 4031 "next.sh: the record for the file and src/ as they stand: the row" 4 "$KP/.gauntlet/STATE.md"
echo '// edited' >> "$KP/src/H.sol"
kx_one 4032 "next.sh: src/ edited since the record - not current, refused" 2 "$KP_STALE" "$KP/.gauntlet/STATE.md"
printf 'contract H {}\n' > "$KP/src/H.sol"; echo '// edited' >> "$KP/pending/F-1.t.sol"
kx_one 4033 "next.sh: the test edited since the record - not current, refused" 2 "$KP_STALE" "$KP/.gauntlet/STATE.md"
printf '// F-1\n' > "$KP/pending/F-1.t.sol"
kx_row 4034 "next.sh: both as recorded again - the record is current again: the row" 4 "$KP/.gauntlet/STATE.md"
mkdir -p "$KP/src/lib"; printf 'library L {}\n' > "$KP/src/lib/L.sol"
kx_one 4035 "next.sh: a file added below src/ - not current, refused" 2 "$KP_STALE" "$KP/.gauntlet/STATE.md"
PENDING_RED=0 nx "$NX" "$KP/.gauntlet/STATE.md" > "$TMP/o4036" 2>&1; check "next.sh with PENDING_RED=0: the row" 0 $? "$TMP/o4036"
grep -q '^next: PENDING_RED=0 - ' "$TMP/o4036" || { echo "  FAIL  and PENDING_RED=0 was not said"; fails=$((fails + 1)); }
PENDING_RED=1 nx "$NX" "$KP/.gauntlet/STATE.md" > "$TMP/o4037" 2>&1; check "next.sh refuses PENDING_RED set to anything but 0" 2 $? "$TMP/o4037"
grep -qF "PENDING_RED='1' is not 0" "$TMP/o4037" || { echo "  FAIL  and not for that: $(head -1 "$TMP/o4037")"; fails=$((fails + 1)); }
# ---- pending-red.sh on a small forge project: red -> record; green -> refused; a compile error -> refused; setUp -> refused
KPF="$HERE/../foundry-kit"
if command -v forge > /dev/null 2>&1 && [ -e "$KPF/lib" ]; then
  KR="$TMP/kr"; rm -rf "$KR"; mkdir -p "$KR/src" "$KR/pending" "$KR/.gauntlet"; ln -s "$(cd "$KPF/lib" && pwd -P)" "$KR/lib"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n[profile.pending]\ntest = "pending"\n' > "$KR/foundry.toml"
  printf 'pragma solidity ^0.8.26;\ncontract Reg {\n    error Taken();\n    mapping(uint256 => address) public ownerOf;\n    function register(uint256 id) external {\n        ownerOf[id] = msg.sender;\n    }\n}\n' > "$KR/src/Reg.sol"
  kr_red() { # kr_red [<a line to put first in the contract>]: the finding's test (red on Reg) and its control (green)
    printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/Reg.sol";\ncontract F1 is Test {\n%s\n' "${1:-}"
    printf '    function test_F1_a_stranger_cannot_take_a_registered_id() public { Reg r = new Reg(); vm.prank(address(0xA11CE)); r.register(1); vm.prank(address(0xB0B)); vm.expectRevert(Reg.Taken.selector); r.register(1); }\n'
    printf '    function test_F1_control_a_free_id_is_taken() public { Reg r = new Reg(); vm.prank(address(0xB0B)); r.register(2); assertEq(r.ownerOf(2), address(0xB0B)); }\n}\n'
  }
  kr_red > "$KR/pending/F-1.t.sol"
  sed 's/^notes: .*/notes:                     pending: F-1 - a stranger takes a registered id, owner undecided/' "$FIX/state-new-project.md" > "$KR/.gauntlet/STATE.md"
  KRA="$(cd "$KR" && pwd)"
  kr_recs() { find "$KR/.gauntlet/pending-red" -type f -name 'F-1.t.sol.*' ! -name '*.log' 2> /dev/null | wc -l | tr -d ' '; }
  nx "$NX" "$KR/.gauntlet/STATE.md" > "$TMP/o4040" 2>&1; check "next.sh on the small project before pending-red.sh: not seen red" 2 $? "$TMP/o4040"
  "$HERE/pending-red.sh" "$KR" > "$TMP/o4041" 2>&1; check "pending-red.sh: the finding's test fails on the code (its control passes): RED, the record written" 0 $? "$TMP/o4041"
  kr_rec="$(pending_record_path "$KRA" pending/F-1.t.sol)"
  if [ -f "$kr_rec" ] && grep -q '^result: 1 passed, 1 failed' "$kr_rec"; then
    echo "  ok    the record is the one next.sh reads, and holds the counts"; else echo "  FAIL  no current record, or not its counts:"; ls -a "$KR/.gauntlet/pending-red" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  kx_row 4042 "next.sh on the small project after it: the row" 4 "$KR/.gauntlet/STATE.md"
  cp "$KR/src/Reg.sol" "$TMP/kr-Reg.sol"; printf '// edited after the red\n' >> "$KR/src/Reg.sol"
  nx "$NX" "$KR/.gauntlet/STATE.md" > "$TMP/o4043" 2>&1; check "next.sh: src/ edited after the red: the record is stale, refused" 2 $? "$TMP/o4043"
  grep -qF "next: pending/F-1.t.sol - not seen red on the code as it stands (its red record of $(date +%F) is stale - src/ changed since): " "$TMP/o4043" || { echo "  FAIL  and not for that: $(head -1 "$TMP/o4043")"; fails=$((fails + 1)); }
  cp "$TMP/kr-Reg.sol" "$KR/src/Reg.sol"
  kr_red | grep -v 'a_stranger_cannot' > "$KR/pending/F-1.t.sol"
  "$HERE/pending-red.sh" "$KR" pending/F-1.t.sol > "$TMP/o4044" 2>&1; check "pending-red.sh refuses a pending test that PASSES on the code" 2 $? "$TMP/o4044"
  grep -qF "pending/F-1.t.sol passes on the code: it is not a finding's test (EVIDENCE.md section 2)" "$TMP/o4044" || { echo "  FAIL  and not for that: $(head -1 "$TMP/o4044")"; fails=$((fails + 1)); }
  if [ "$(kr_recs)" = 0 ]; then echo "  ok    and no record of F-1 is left (the earlier red's went first)"; else echo "  FAIL  a record of F-1 is left: $(kr_recs)"; fails=$((fails + 1)); fi
  kr_red | sed 's/r.register(1); }/r.register(1) }/' > "$KR/pending/F-1.t.sol"
  "$HERE/pending-red.sh" "$KR" F-1.t.sol > "$TMP/o4045" 2>&1; check "pending-red.sh refuses a pending test that does not compile" 2 $? "$TMP/o4045"
  grep -q 'pending/F-1.t.sol does not compile' "$TMP/o4045" || { echo "  FAIL  and not for that: $(head -1 "$TMP/o4045")"; fails=$((fails + 1)); }
  [ "$(kr_recs)" = 0 ] || { echo "  FAIL  a record of F-1 is left after a compile error"; fails=$((fails + 1)); }
  kr_red '    function setUp() public { revert("the bench is broken"); }' > "$KR/pending/F-1.t.sol"
  "$HERE/pending-red.sh" "$KR" "$KR/pending/F-1.t.sol" > "$TMP/o4046" 2>&1; check "pending-red.sh refuses a pending test whose setUp() fails (the harness, not the code)" 2 $? "$TMP/o4046"
  grep -q 'setUp() failed' "$TMP/o4046" || { echo "  FAIL  and not for that: $(head -1 "$TMP/o4046")"; fails=$((fails + 1)); }
  [ "$(kr_recs)" = 0 ] || { echo "  FAIL  a record of F-1 is left after a setUp failure"; fails=$((fails + 1)); }
  nx "$NX" "$KR/.gauntlet/STATE.md" > "$TMP/o4047" 2>&1; check "next.sh after those refusals: still not seen red" 2 $? "$TMP/o4047"
  kr_red > "$KR/pending/F-1.t.sol"; printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n' > "$KR/foundry.toml"
  "$HERE/pending-red.sh" "$KR" > "$TMP/o4048" 2>&1; check "pending-red.sh refuses a project with no [profile.pending] (NEXT.md row 6b)" 2 $? "$TMP/o4048"
  "$HERE/pending-red.sh" "$KR" src/Reg.sol > "$TMP/o4049" 2>&1; check "pending-red.sh refuses a file that is not below pending/" 2 $? "$TMP/o4049"
else
  echo "  SKIPPED - no forge or no foundry-kit/lib here: pending-red.sh's runs are NOT proven on this machine"; skipped=1
fi
if [ -s "$TMP/nx-silent" ]; then echo "  FAIL  next.sh ran with NEXT_SELFTEST=1 and did not say so (K40/K41 cases):"; sed "s/^/        | /" "$TMP/nx-silent"; fails=$((fails + 1)); fi
# --- end K40/K41 ---

# --- K48 ---
# ================================================================= what the verifier of v0.4 found (V40): the example known
# by its values, the marker only as a whole line in DECISIONS.md and LOG.md, a cited file that is empty or a directory,
# a directory in pending/, a record that is read, a key that covers test/, pending/, foundry.toml and remappings.txt,
# a pending-red.sh that builds from nothing, and the harness's permission-bits refusal named as a finding
echo "== next.sh and pending-red.sh: the example by its values, whole-line markers, records read, builds from nothing (K48) =="
K8_EX="$HERE/../state/STATE.md"
K8_FIRST_VAL="next: FIRST - fill STATE.md: its values are still the kit's example's ($(LC_ALL=C awk '/^```/ { f = !f; next } f' "$K8_EX" | grep -m 1 '^bytecode_changed_since:'))"
K8="$TMP/k8"
# ---- the example by its values (V40: its marker deleted, as the line says, and retitled, as QUICKSTART 5 says: row 13)
kx_proj "$K8"; sed '/Example file. The project is fictional/d; 1s/BlockCapHook/VolumeRewardsHook/' "$K8_EX" > "$K8/.gauntlet/STATE.md"
kx_one 4801 "next.sh refuses the example with its marker deleted AND retitled: its values are the example's" 2 "$K8_FIRST_VAL" "$K8/.gauntlet/STATE.md"
PENDING_RED=0 CITED_FILES=0 nx "$NX" "$K8/.gauntlet/STATE.md" > "$TMP/o4802" 2>&1; check "... and no escape turns that off" 2 $? "$TMP/o4802"
grep -qxF "$K8_FIRST_VAL" "$TMP/o4802" || { echo "  FAIL  and not with the FIRST line: $(tail -1 "$TMP/o4802")"; fails=$((fails + 1)); }
sed 's/$/\r/' "$K8/.gauntlet/STATE.md" > "$K8/.gauntlet/STATE.crlf"; mv "$K8/.gauntlet/STATE.crlf" "$K8/.gauntlet/STATE.md"
kx_one 4803 "next.sh refuses the same with CRLF line ends" 2 "$K8_FIRST_VAL" "$K8/.gauntlet/STATE.md"
k8_with() { # k8_with <flag> ...: the new project's STATE.md with those flags' lines taken from the kit's example, byte for byte
  local f l; kx_proj "$K8"
  for f in "$@"; do
    l="$(LC_ALL=C awk '/^```/ { b = !b; next } b' "$K8_EX" | grep -m 1 "^$f:")"
    LC_ALL=C awk -v f="$f" -v l="$l" 'index($0, f ":") == 1 { print l; next } { print }' "$K8/.gauntlet/STATE.md" > "$K8/s" && mv "$K8/s" "$K8/.gauntlet/STATE.md"
  done
}
k8_with notes
kx_row 4804 "next.sh: a real project sharing two of the example's non-generic lines (last_other_round: none, and its notes) - not refused: the row" 4 "$K8/.gauntlet/STATE.md"
k8_with notes waiting_on_owner
nx "$NX" "$K8/.gauntlet/STATE.md" > "$TMP/o4805" 2>&1; check "next.sh refuses three shared lines (last_other_round, waiting_on_owner, notes), naming the first" 2 $? "$TMP/o4805"
grep -qxF "next: FIRST - fill STATE.md: its values are still the kit's example's ($(grep -m 1 '^last_other_round:' "$K8/.gauntlet/STATE.md"))" "$TMP/o4805" \
  && echo "  ok    the line names last_other_round's, the first shared in the file's order" || { echo "  FAIL  not the line: $(cat "$TMP/o4805")"; fails=$((fails + 1)); }
k8_with open_findings blackbox dossier rehearsal location
kx_row 4806 "next.sh: the example's generic lines (blackbox, dossier, rehearsal, location) do not count: two non-generic shared (last_other_round, open_findings), the row" 4 "$K8/.gauntlet/STATE.md"
# the starting values state/README.md gives, as a STATE.md: not the example
kx_proj "$K8"; { echo '# STATE - SomeHook'; echo; LC_ALL=C awk '/^## Installing/ { s = 1 } s && /^```$/ { if (b) exit; b = 1; print; next } b { print }' "$HERE/../state/README.md"; echo '```'; } > "$K8/.gauntlet/STATE.md"
kx_row 4807 "next.sh: state/README.md's starting values of a new project, as a STATE.md: the row" 4 "$K8/.gauntlet/STATE.md"
grep -q '^phase:  *0$' "$K8/.gauntlet/STATE.md" || { echo "  FAIL  state/README.md's Installing section has no starting values block:"; sed "s/^/        | /" "$K8/.gauntlet/STATE.md"; fails=$((fails + 1)); }
grep -q 'keep its flag block' "$HERE/../state/README.md" && echo "  ok    state/README.md says to keep the flag block" || { echo "  FAIL  state/README.md does not say to keep the flag block"; fails=$((fails + 1)); }
# ---- the marker counts only as a whole line in DECISIONS.md and LOG.md (V40: an honest LOG.md quoting it was refused)
kx_proj "$K8"; printf '# LOG - SomeHook\n\n## 2026-09-30 - examples emptied\nDeleted the line "*Example file. The project is fictional. Delete this and start yours.*" from the three files.\n' > "$K8/.gauntlet/LOG.md"
kx_row 4810 "next.sh: an honest LOG.md that quotes the marker it deleted, inside a line: the row" 4 "$K8/.gauntlet/STATE.md"
printf '# DECISIONS - SomeHook\n\nD-01: emptied the examples (their line *Example file. The project is fictional. Delete this and start yours.* gone).\n' > "$K8/.gauntlet/DECISIONS.md"
kx_row 4811 "next.sh: an honest DECISIONS.md that quotes it inside a line: the row" 4 "$K8/.gauntlet/STATE.md"
printf '# LOG - SomeHook\n\n*Example file. The project is fictional. Delete this and start yours.*\n\n## 2026-09-30 - state installed\n' > "$K8/.gauntlet/LOG.md"
kx_one 4812 "next.sh still refuses a LOG.md that keeps the marker as a line of its own" 2 "${KX_FIRST/STATE.md:/LOG.md:}" "$K8/.gauntlet/STATE.md"
# ---- a cited file must be a non-empty regular file (V40: test/fork/Fork.t.sol 0 bytes, or a directory, passed)
kx_proj "$K8"; mkdir -p "$K8/test/fork"; : > "$K8/test/fork/Fork.t.sol"
printf '# DECISIONS - SomeHook\n\n**Test:** `test/fork/Fork.t.sol` written for the hook, run against a fork.\n' > "$K8/.gauntlet/DECISIONS.md"
nx "$NX" "$K8/.gauntlet/STATE.md" > "$TMP/o4820" 2>&1; check "next.sh refuses a cited test/fork/Fork.t.sol of 0 bytes" 2 $? "$TMP/o4820"
grep -q '^next: DECISIONS.md cites a file that is empty: test/fork/Fork.t.sol (line 3 of ' "$TMP/o4820" && ! grep -q 'CITED_FILES' "$TMP/o4820" || { echo "  FAIL  and not the line (or it names the escape): $(cat "$TMP/o4820")"; fails=$((fails + 1)); }
rm -f "$K8/test/fork/Fork.t.sol"; mkdir -p "$K8/test/fork/Fork.t.sol"
nx "$NX" "$K8/.gauntlet/STATE.md" > "$TMP/o4821" 2>&1; check "next.sh refuses a cited test/fork/Fork.t.sol that is a directory" 2 $? "$TMP/o4821"
grep -q '^next: DECISIONS.md cites a file that is a directory: test/fork/Fork.t.sol (line 3 of ' "$TMP/o4821" || { echo "  FAIL  and not the line: $(cat "$TMP/o4821")"; fails=$((fails + 1)); }
rmdir "$K8/test/fork/Fork.t.sol"; echo 'contract ForkTest {}' > "$K8/test/fork/Fork.t.sol"
kx_row 4822 "next.sh: the same file with content: the row" 4 "$K8/.gauntlet/STATE.md"
# ---- a directory in pending/ named *.sol is not a test (V40: it passed the walk, which saw files only)
kx_proj "$K8"; mkdir -p "$K8/pending/F-13_dir.t.sol"
sed 's/^notes: .*/notes:                     pending: F-13_dir - x, owner undecided/' "$FIX/state-new-project.md" > "$K8/.gauntlet/STATE.md"
nx "$NX" "$K8/.gauntlet/STATE.md" > "$TMP/o4823" 2>&1; check "next.sh refuses a directory pending/F-13_dir.t.sol" 2 $? "$TMP/o4823"
grep -qF 'pending/F-13_dir.t.sol is a directory: a test in pending/ is a file' "$TMP/o4823" || { echo "  FAIL  and not for that: $(cat "$TMP/o4823")"; fails=$((fails + 1)); }
# ---- the record is read: its first line (V40: an empty file with the key's name was taken, for a test that PASSES)
K8P="$TMP/k8p"; kx_proj "$K8P"; mkdir -p "$K8P/src" "$K8P/pending" "$K8P/test" "$K8P/lib/dep"; printf 'contract H {}\n' > "$K8P/src/H.sol"
printf '// F-1\n' > "$K8P/pending/F-1.t.sol"; printf 'abstract contract Helper {}\n' > "$K8P/test/Helper.sol"; printf '[profile.default]\n' > "$K8P/foundry.toml"; printf 'contract D {}\n' > "$K8P/lib/dep/D.sol"
sed 's/^notes: .*/notes:                     pending: F-1 - a stranger takes a registered id, owner undecided/' "$FIX/state-new-project.md" > "$K8P/.gauntlet/STATE.md"
K8PA="$(cd "$K8P" && pwd)"
k8_rec() { pending_record_path "$K8PA" pending/F-1.t.sol; }
k8_unread() { # k8_unread <n> <label>: next.sh says the record is unreadable
  nx "$NX" "$K8P/.gauntlet/STATE.md" > "$TMP/o$1" 2>&1; check "$2" 2 $? "$TMP/o$1"
  grep -q '^next: pending/F-1.t.sol: record unreadable - run scripts/pending-red.sh again' "$TMP/o$1" || { echo "  FAIL  and not 'record unreadable': $(cat "$TMP/o$1")"; fails=$((fails + 1)); }
}
r="$(k8_rec)"; mkdir -p "$(dirname "$r")"; : > "$r"
k8_unread 4830 "next.sh refuses an EMPTY record at the current key (a handwritten one)"
echo '# a record' > "$r"
k8_unread 4831 "next.sh refuses a record whose first line is not pending-red's"
pending_record_head pending/F-2.t.sol "${r##*.}" > "$r"
k8_unread 4832 "next.sh refuses a record whose first line names another file"
pending_record_head pending/F-1.t.sol "$(printf '%064d' 0)" > "$r"
k8_unread 4833 "next.sh refuses a record whose first line carries another key than its name"
pending_record_head pending/F-1.t.sol "${r##*.}" > "$r"; echo 'failed: test_x()' >> "$r"
kx_row 4834 "next.sh: a record with pending-red's first line for that file and key: the row" 4 "$K8P/.gauntlet/STATE.md"
# ---- the key covers test/, pending/, foundry.toml and remappings.txt (V40: a helper in test/ edited kept the record current)
k8_stale() { # k8_stale <n> <label>: the record is not the current one any more
  nx "$NX" "$K8P/.gauntlet/STATE.md" > "$TMP/o$1" 2>&1; check "$2" 2 $? "$TMP/o$1"
  grep -q '^next: pending/F-1.t.sol - not seen red on the code as it stands (its red record of [0-9-]* is stale - ' "$TMP/o$1" || { echo "  FAIL  and not for that: $(cat "$TMP/o$1")"; fails=$((fails + 1)); }
}
k8_again() { r="$(k8_rec)"; pending_record_head pending/F-1.t.sol "${r##*.}" > "$r"; }
echo '// edited' >> "$K8P/test/Helper.sol"; k8_stale 4835 "next.sh: a helper in test/ edited since the record - not current"
k8_again; mkdir -p "$K8P/pending/lib"; echo 'abstract contract PH {}' > "$K8P/pending/lib/PH.sol.txt"; k8_stale 4836 "next.sh: a file added below pending/ - not current"
rm -rf "$K8P/pending/lib"; k8_again; echo '[profile.pending]' >> "$K8P/foundry.toml"; k8_stale 4837 "next.sh: foundry.toml edited - not current"
k8_again; echo 'dep/=lib/dep/' > "$K8P/remappings.txt"; k8_stale 4838 "next.sh: remappings.txt added - not current"
k8_again; echo '// edited' >> "$K8P/lib/dep/D.sol"
kx_row 4839 "next.sh: a library edited is NOT in the key (said in the docs): the record stays current" 4 "$K8P/.gauntlet/STATE.md"
grep -qF 'src/, test/, pending/, foundry.toml and remappings.txt' "$HERE/lib/pending-record.sh" && grep -qF '`test/`, `pending/`, `foundry.toml` and `remappings.txt`' "$HERE/../state/README.md" \
  && echo "  ok    the docs list what the key covers" || { echo "  FAIL  the docs do not list what the key covers"; fails=$((fails + 1)); }
# ---- pending-red.sh on a small forge project: builds from nothing (a helper in test/ edited, both ways), the record's
# content, a directory in pending/, the harness's permission-bits refusal
if command -v forge > /dev/null 2>&1 && [ -e "$KPF/lib" ]; then
  K8R="$TMP/k8r"; rm -rf "$K8R"; mkdir -p "$K8R/src" "$K8R/pending" "$K8R/test" "$K8R/.gauntlet"; ln -s "$(cd "$KPF/lib" && pwd -P)" "$K8R/lib"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n[profile.pending]\ntest = "pending"\n' > "$K8R/foundry.toml"
  printf 'pragma solidity ^0.8.26;\ncontract Reg {\n    mapping(uint256 => address) public ownerOf;\n    function register(uint256 id) external {\n        ownerOf[id] = msg.sender;\n    }\n}\n' > "$K8R/src/Reg.sol"
  k8_helper() { printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nabstract contract Pb is Test {\n    function _who() internal pure returns (address) { return address(%s); }\n}\n' "$1" > "$K8R/test/Pb.sol"; }
  k8_helper 0xA11CE
  printf 'pragma solidity ^0.8.26;\nimport "../test/Pb.sol";\nimport "../src/Reg.sol";\ncontract F1 is Pb {\n' > "$K8R/pending/F-1.t.sol"
  printf '    function test_F1_the_registrant_owns_it() public { Reg r = new Reg(); vm.prank(address(0xB0B)); r.register(1); assertEq(r.ownerOf(1), _who()); }\n' >> "$K8R/pending/F-1.t.sol"
  printf '    function test_F1_control() public { Reg r = new Reg(); r.register(2); assertEq(r.ownerOf(2), address(this)); }\n}\n' >> "$K8R/pending/F-1.t.sol"
  mkdir -p "$K8R/cache/fuzz" "$K8R/cache/invariant/failures/S"; echo x > "$K8R/cache/fuzz/failures"; echo y > "$K8R/cache/invariant/failures/S/x"
  "$HERE/pending-red.sh" "$K8R" > "$TMP/o4850" 2>&1; check "pending-red.sh: the helper in test/ says 0xA11CE, the test asserts the registrant 0xB0B: RED" 0 $? "$TMP/o4850"
  K8RA="$(cd "$K8R" && pwd)"; r="$(pending_record_path "$K8RA" pending/F-1.t.sol)"
  if pending_record_ok "$r" pending/F-1.t.sol "${r##*.}" && grep -q '^failed: test_F1_the_registrant_owns_it()$' "$r" && grep -q 'failing test' "$r"; then
    echo "  ok    the record: pending-red's first line, the failing test, the end of forge's output"; else echo "  FAIL  the record is not that:"; sed "s/^/        | /" "$r" 2> /dev/null | head -12; fails=$((fails + 1)); fi
  [ "$(sed -n '/^# the last 20 lines/,$p' "$r" | sed 1d | wc -l | tr -d ' ')" -le 20 ] || { echo "  FAIL  more than 20 lines of forge's output in the record"; fails=$((fails + 1)); }
  k8_helper 0xB0B
  "$HERE/pending-red.sh" "$K8R" > "$TMP/o4851" 2>&1; check "pending-red.sh: the helper edited to 0xB0B - the test now PASSES, and is refused (not the old red of a stale build)" 2 $? "$TMP/o4851"
  grep -qF "pending/F-1.t.sol passes on the code" "$TMP/o4851" || { echo "  FAIL  and not for that: $(head -1 "$TMP/o4851")"; fails=$((fails + 1)); }
  k8_helper 0xA11CE
  "$HERE/pending-red.sh" "$K8R" > "$TMP/o4852" 2>&1; check "pending-red.sh: the helper back to 0xA11CE - RED again (not the old pass of a stale build)" 0 $? "$TMP/o4852"
  if [ -f "$K8R/cache/fuzz/failures" ] && [ -f "$K8R/cache/invariant/failures/S/x" ] && [ ! -e "$K8R/out" ] && [ ! -e "$K8R/cache/solidity-files-cache.json" ]; then
    echo "  ok    the project's persisted fuzz and invariant failures kept, its out/ and forge's cache record untouched (the build is pending-red's own)"; else
    echo "  FAIL  the project's cache/ or out/ was touched:"; find "$K8R/cache" "$K8R/out" 2> /dev/null | sed "s/^/        | /" | head; fails=$((fails + 1)); fi
  mkdir -p "$K8R/pending/F-13_dir.t.sol"
  "$HERE/pending-red.sh" "$K8R" > "$TMP/o4853" 2>&1; check "pending-red.sh refuses a directory pending/F-13_dir.t.sol when it walks pending/" 2 $? "$TMP/o4853"
  grep -qF 'pending/F-13_dir.t.sol is a directory' "$TMP/o4853" || { echo "  FAIL  and not for that: $(head -1 "$TMP/o4853")"; fails=$((fails + 1)); }
  "$HERE/pending-red.sh" "$K8R" pending/F-13_dir.t.sol > "$TMP/o4854" 2>&1; check "... and when it is named" 2 $? "$TMP/o4854"
  grep -qF 'pending/F-13_dir.t.sol is a directory' "$TMP/o4854" || { echo "  FAIL  and not for that: $(head -1 "$TMP/o4854")"; fails=$((fails + 1)); }
  rmdir "$K8R/pending/F-13_dir.t.sol"
  K8_BITS='V4Harness: afterInitialize implemented but its permission bit is not set on 0x0000000000000000000000000000000000001000 - the manager never calls it. This is a finding, not a fix (doctrine/NEXT.md row 6b). In this order: write its test as pending/<id>.t.sol - its own setUp sets _skipPermissionCheck = true, then a test function of its own calls _checkHookPermissions(address(hook)) directly (V4Harness: function _checkHookPermissions(address hook) internal), with no vm.expectRevert, so this revert fails that test - record that red with scripts/pending-red.sh <proj> pending/<id>.t.sol, count it in STATE.md; then put _skipPermissionCheck = true and a header line // _skipPermissionCheck: <id> open in the suites that deploy the hook; then the battery, which holds them to that red record, current while src/ and pending/<id>.t.sol are as recorded (doctrine/EVIDENCE.md section 2).'
  { printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\ncontract F1 is Test {\n    function setUp() public { revert("%s"); }\n' "$K8_BITS"
    printf '    function test_F1_x() public { assertTrue(false); }\n}\n'; } > "$K8R/pending/F-1.t.sol"
  "$HERE/pending-red.sh" "$K8R" pending/F-1.t.sol > "$TMP/o4855" 2>&1; check "pending-red.sh: setUp() fails on the harness's permission-bits refusal - no record" 2 $? "$TMP/o4855"
  if grep -qF "$K8_BITS" "$TMP/o4855" \
    && grep -qxF 'pending-red: the harness refused the deploy: that IS the finding - its test sets _skipPermissionCheck = true in setUp and holds the hook to the check in a test of its own, _checkHookPermissions(address(hook)); - that test'"'"'s failure is this line, recorded red like any other (doctrine/EVIDENCE.md section 2, "while a permission-bits finding is open")' "$TMP/o4855" \
    && ! grep -q 'the harness broke' "$TMP/o4855"; then
    echo "  ok    the harness's whole line (no cut), and the line that names the finding and EVIDENCE.md section 2"; else echo "  FAIL  not those lines:"; sed "s/^/        | /" "$TMP/o4855"; fails=$((fails + 1)); fi
  grep -qiF 'while a permission-bits finding is open' "$HERE/../doctrine/EVIDENCE.md" || { echo "  FAIL  doctrine/EVIDENCE.md has no paragraph 'while a permission-bits finding is open'"; fails=$((fails + 1)); }
  grep -qF '(doctrine/EVIDENCE.md section 2)."' "$HERE/../foundry-kit/v4/src/V4Harness.sol" && ! grep -qF 'Declare the bit and mine for it' "$HERE/../foundry-kit/v4/src/V4Harness.sol" \
    && echo "  ok    the harness's refusal points at doctrine/EVIDENCE.md section 2, not at a fix" || { echo "  FAIL  the harness's refusal does not point at EVIDENCE.md section 2"; fails=$((fails + 1)); }
else
  echo "  SKIPPED - no forge or no foundry-kit/lib here: pending-red.sh's builds from nothing are NOT proven on this machine"; skipped=1
fi
if [ -s "$TMP/nx-silent" ]; then echo "  FAIL  next.sh ran with NEXT_SELFTEST=1 and did not say so (K48 cases):"; sed "s/^/        | /" "$TMP/nx-silent"; fails=$((fails + 1)); fi
# --- end K48 ---

# --- K49 ---
# ================================================================= the example's values, whatever the spacing (V41: the
# example unmarked, retitled and re-aligned - one space after each colon, the same values - answered "row 13 - a
# REGRESSION round" again, the local-model walk's answer); and what pending-red.sh leaves in the project (V41: its
# header said the project's cache/ was not touched; forge writes cache/test-failures there)
echo "== next.sh: the example's values whatever the spacing; what pending-red.sh leaves in the project (K49) =="
K9="$TMP/k9"
k9_tabs() { # k9_tabs: stdin, each flag line's spacing changed: a tab after its colon, runs of spaces in it one, two spaces at its end
  LC_ALL=C sed -E '/^[a-z_]+:/ { s/^([a-z_]+):[[:space:]]*/\1:	/; s/  +/ /g; s/$/  /; }'
}
kx_proj "$K9"; LC_ALL=C sed -E '/Example file. The project is fictional/d; 1s/BlockCapHook/VolumeRewardsHook/; s/^([a-z_]+):[[:space:]]+/\1: /' "$K8_EX" > "$K9/.gauntlet/STATE.md"
kx_one 4901 "next.sh refuses the example unmarked, retitled and re-aligned (one space after each colon: V41's case), with the same line" 2 "$K8_FIRST_VAL" "$K9/.gauntlet/STATE.md"
kx_proj "$K9"; LC_ALL=C sed -E '/Example file. The project is fictional/d; 1s/BlockCapHook/VolumeRewardsHook/' "$K8_EX" | k9_tabs > "$K9/.gauntlet/STATE.md"
if grep -q '^bytecode_changed_since:	last_battery=no last_long_fuzz=no .*  $' "$K9/.gauntlet/STATE.md"; then echo "  ok    (the copy has a tab after each colon, one space inside, two at the end)"; else
  echo "  FAIL  the re-spaced copy is not re-spaced:"; grep '^bytecode' "$K9/.gauntlet/STATE.md" | sed "s/^/        | /"; fails=$((fails + 1)); fi
kx_one 4902 "next.sh refuses the same with tabs, the runs inside a value made one space, and spaces at the ends: the same line" 2 "$K8_FIRST_VAL" "$K9/.gauntlet/STATE.md"
# a project's starting values, re-spaced: they share ONE non-generic line with the example (last_other_round: none)
kx_proj "$K9"; { echo '# STATE - SomeHook'; echo; LC_ALL=C awk '/^## Installing/ { s = 1 } s && /^```$/ { if (b) exit; b = 1; print; next } b { print }' "$HERE/../state/README.md" | k9_tabs; echo '```'; } > "$K9/.gauntlet/STATE.md"
kx_row 4903 "next.sh: a project's starting values (state/README.md) re-spaced - one line shared with the example, last_other_round: none: the row" 4 "$K9/.gauntlet/STATE.md"
k9_with() { # k9_with <flag> ...: the new project's STATE.md with those flags' lines the kit's example's, then every flag line re-spaced
  local f l; kx_proj "$K9"
  for f in "$@"; do
    l="$(LC_ALL=C awk '/^```/ { b = !b; next } b' "$K8_EX" | grep -m 1 "^$f:")"
    LC_ALL=C awk -v f="$f" -v l="$l" 'index($0, f ":") == 1 { print l; next } { print }' "$K9/.gauntlet/STATE.md" > "$K9/s" && mv "$K9/s" "$K9/.gauntlet/STATE.md"
  done
  k9_tabs < "$K9/.gauntlet/STATE.md" > "$K9/s" && mv "$K9/s" "$K9/.gauntlet/STATE.md"
}
k9_with notes
kx_row 4904 "next.sh: two lines shared with the example, re-spaced (last_other_round, notes): not refused, the row" 4 "$K9/.gauntlet/STATE.md"
k9_with notes waiting_on_owner
kx_one 4905 "next.sh refuses three lines shared with the example with other spacing (last_other_round, waiting_on_owner, notes), naming the example's own first line" \
  2 "next: FIRST - fill STATE.md: its values are still the kit's example's ($(LC_ALL=C awk '/^```/ { b = !b; next } b' "$K8_EX" | grep -m 1 '^last_other_round:'))" "$K9/.gauntlet/STATE.md"
grep -qF 'the same values, whatever the spacing' "$HERE/../state/README.md" && echo "  ok    state/README.md says the example's values count whatever the spacing" \
  || { echo "  FAIL  state/README.md does not say \"the same values, whatever the spacing\""; fails=$((fails + 1)); }
# ---- pending-red.sh: its own build directory emptied each run; the project's cache/fuzz, cache/invariant,
# cache/solidity-files-cache.json and out/ untouched; forge writes cache/test-failures, and nothing in the kit reads it
K9_PR="$HERE/pending-red.sh"
# (captured, then matched: sed piped into `grep -q` under pipefail failed ~1 % of runs with the text there - grep's early exit,
# sed's SIGPIPE on a header past 4 KB; V60c measured it, K62)
k9_head="$(sed -n '2,/^set -uo pipefail/p' "$K9_PR")"
if [[ $k9_head == *'cache/test-failures'* && $k9_head == *'--rerun'* ]]; then
  echo "  ok    pending-red.sh's header names cache/test-failures, what forge writes in the project, and --rerun"; else
  echo "  FAIL  pending-red.sh's header does not name cache/test-failures and --rerun (V41: forge writes it; the header said cache/ was not touched)"; fails=$((fails + 1)); fi
k9_rerun="$(for f in "$HERE"/*.sh "$HERE"/lib/*; do [ "$f" = "$HERE/selftest.sh" ] && continue; grep -HnE -- '--rerun|test-failures' "$f" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'; done)"
[ -z "$k9_rerun" ] && echo "  ok    no script of the kit runs forge with --rerun or reads cache/test-failures (comments aside)" \
  || { echo "  FAIL  a script uses --rerun or cache/test-failures:"; printf '%s\n' "$k9_rerun" | sed "s/^/        | /"; fails=$((fails + 1)); }
if command -v forge > /dev/null 2>&1 && [ -e "$KPF/lib" ]; then
  K9R="$TMP/k9r"; rm -rf "$K9R"; mkdir -p "$K9R/src" "$K9R/pending" "$K9R/.gauntlet"; ln -s "$(cd "$KPF/lib" && pwd -P)" "$K9R/lib"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n[profile.pending]\ntest = "pending"\n' > "$K9R/foundry.toml"
  printf 'pragma solidity ^0.8.26;\ncontract Reg {\n    error Taken();\n    mapping(uint256 => address) public ownerOf;\n    function register(uint256 id) external {\n        ownerOf[id] = msg.sender;\n    }\n}\n' > "$K9R/src/Reg.sol"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/Reg.sol";\ncontract F1 is Test {\n' > "$K9R/pending/F-1.t.sol"
  printf '    function test_F1_a_stranger_cannot_take_a_registered_id() public { Reg r = new Reg(); vm.prank(address(0xA11CE)); r.register(1); vm.prank(address(0xB0B)); vm.expectRevert(Reg.Taken.selector); r.register(1); }\n' >> "$K9R/pending/F-1.t.sol"
  printf '    function test_F1_control_a_free_id_is_taken() public { Reg r = new Reg(); vm.prank(address(0xB0B)); r.register(2); assertEq(r.ownerOf(2), address(0xB0B)); }\n}\n' >> "$K9R/pending/F-1.t.sol"
  mkdir -p "$K9R/cache/fuzz" "$K9R/cache/invariant/failures/F1" "$K9R/out/Reg.sol" "$K9R/.gauntlet/pending-red-build/out"
  printf 'k49 a persisted fuzz failure\n' > "$K9R/cache/fuzz/failures"; printf 'k49 a persisted invariant failure\n' > "$K9R/cache/invariant/failures/F1/invariant_x"
  printf '{"k49": "the project build record"}\n' > "$K9R/cache/solidity-files-cache.json"; printf '{"k49": "an artifact"}\n' > "$K9R/out/Reg.sol/Reg.json"
  printf 'k49 stale\n' > "$K9R/.gauntlet/pending-red-build/out/k49-stale"
  k9_sum() { (cd "$K9R" && find cache/fuzz cache/invariant cache/solidity-files-cache.json out | LC_ALL=C sort | while IFS= read -r f; do echo "$f"; [ ! -f "$f" ] || cat "$f"; done) | cksum; }
  k9_before="$(k9_sum)"
  "$K9_PR" "$K9R" pending/F-1.t.sol > "$TMP/o4910" 2>&1; check "pending-red.sh on a project with its own cache/ and out/: RED, the record written" 0 $? "$TMP/o4910"
  [ "$(k9_sum)" = "$k9_before" ] && echo "  ok    the project's cache/fuzz, cache/invariant, cache/solidity-files-cache.json and out/: untouched, byte for byte" \
    || { echo "  FAIL  the project's cache/ or out/ changed:"; (cd "$K9R" && find cache out -type f | sed "s/^/        | /"); fails=$((fails + 1)); }
  [ ! -e "$K9R/.gauntlet/pending-red-build/out/k49-stale" ] && echo "  ok    its own build directory was emptied first (a stale artifact planted there is gone)" \
    || { echo "  FAIL  a stale artifact in .gauntlet/pending-red-build/ survived the run"; fails=$((fails + 1)); }
  grep -q 'test_F1_a_stranger_cannot_take_a_registered_id' "$K9R/cache/test-failures" 2> /dev/null \
    && echo "  ok    forge wrote the project's cache/test-failures, the pending failures (the header says so)" \
    || { echo "  FAIL  no cache/test-failures naming the failing pending test (the header says forge writes it):"; ls -la "$K9R/cache" | sed "s/^/        | /"; fails=$((fails + 1)); }
else
  echo "  SKIPPED - no forge or no foundry-kit/lib here: what pending-red.sh leaves in the project is NOT proven on this machine"; skipped=1
fi
# --- end K49 ---

# --- K50 ---
# ================================================================= v0.4.1 (K50): what the hosted and local walks showed,
# turned into refusals - the spec is the owner's (init-state.sh records its hash; next.sh refuses it changed or gone),
# the phase against its records (phase 2+ needs a green build record, phase 3+ a battery run), the FIRST line names the
# selftest's cost (the KM cases above, KM_FIRST), `key:value` copies of the example, and the MANIFEST note
echo "== init-state.sh; next.sh: the spec, the phase against its records, key:value, the MANIFEST note (K50) =="
K5="$TMP/k50"; rm -rf "$K5"; mkdir -p "$K5"; K5_IS="$HERE/init-state.sh"
k5_proj() { # k5_proj <dir> [<the spec's path in it>]: a project with a hook and a spec, nothing else
  rm -rf "$1"; mkdir -p "$1/src" "$(dirname "$1/${2:-SPEC.md}")"; printf 'contract Hook {}\n' > "$1/src/Hook.sol"
  printf '# SPEC - Hook\n\nThe hook promises one thing: a swap never pays more than its quote.\n' > "$1/${2:-SPEC.md}"
}
k5_sha() { if command -v sha256sum > /dev/null 2>&1; then sha256sum < "$1" | cut -d' ' -f1; else shasum -a 256 < "$1" | cut -d' ' -f1; fi; }
k5_has() { # k5_has <file> <label> <fixed string>...: each string is in the file
  local f="$1" l="$2" s; shift 2
  for s in "$@"; do grep -qF -- "$s" "$f" || { echo "  FAIL  $l: '$s' not in:"; sed "s/^/        | /" "$f"; fails=$((fails + 1)); return 1; }; done
  echo "  ok    $l"
}
k5_no_by() { # k5_no_by <file> <label>: no line of init-state's output carries the runnable form of the signature, `--by "`
  if grep -qF -- '--by "' "$1"; then echo "  FAIL  $2: a line hands over a runnable --by:"; grep -nF -- '--by "' "$1" | sed "s/^/        | /"; fails=$((fails + 1)); else echo "  ok    $2"; fi
}
# ---- init-state.sh on an empty project: the three files, the examples emptied, the spec's hash, the next command
P1="$K5/p1"; k5_proj "$P1"; P1A="$(cd "$P1" && pwd)"
"$K5_IS" "$P1" > "$TMP/o5001" 2>&1; check "init-state.sh on a project with a SPEC.md and nothing else" 0 $? "$TMP/o5001"
k5_ok=1; for f in STATE.md DECISIONS.md LOG.md .gitignore spec.sha256; do [ -s "$P1/.gauntlet/$f" ] || { echo "  FAIL  it did not write .gauntlet/$f"; fails=$((fails + 1)); k5_ok=0; }; done
[ "$k5_ok" = 1 ] && echo "  ok    it wrote .gauntlet/STATE.md, DECISIONS.md, LOG.md, .gitignore and spec.sha256"
[ "$(cat "$P1/.gauntlet/spec.sha256" 2> /dev/null)" = "$(k5_sha "$P1/SPEC.md")  SPEC.md" ] && echo "  ok    spec.sha256 is '<sha256 of SPEC.md>  SPEC.md'" \
  || { echo "  FAIL  spec.sha256 is not the spec's hash and its path: $(cat "$P1/.gauntlet/spec.sha256" 2> /dev/null)"; fails=$((fails + 1)); }
k5_block() { [ -f "$1" ] || return 0; LC_ALL=C awk '{ sub(/\r$/, "") } /^```/ { if (b && has) { f = 1; exit } b = !b; n = 0; has = 0; next } b { l[++n] = $0; if ($0 ~ /^phase:/) has = 1 } END { for (i = 1; i <= n; i++) print l[i] }' "$1"; }
[ -n "$(k5_block "$HERE/../state/README.md")" ] && [ "$(k5_block "$P1/.gauntlet/STATE.md")" = "$(k5_block "$HERE/../state/README.md")" ] \
  && echo "  ok    its STATE.md's flag block is state/README.md's starting values, line for line" \
  || { echo "  FAIL  its STATE.md's flag block is not state/README.md's starting values:"; k5_block "$P1/.gauntlet/STATE.md" | sed "s/^/        | /"; fails=$((fails + 1)); }
grep -q '^phase: *0$' "$P1/.gauntlet/STATE.md" 2> /dev/null && grep -q '^location: *\.gauntlet/$' "$P1/.gauntlet/STATE.md" && grep -q '^battery: *never$' "$P1/.gauntlet/STATE.md" \
  && echo "  ok    phase: 0, battery: never, location: .gauntlet/" || { echo "  FAIL  not phase 0 / battery never / location .gauntlet/"; fails=$((fails + 1)); }
if [ ! -f "$P1/.gauntlet/STATE.md" ] || grep -qlE 'Example file|BlockCapHook|F-24|r05' "$P1/.gauntlet/STATE.md" "$P1/.gauntlet/DECISIONS.md" "$P1/.gauntlet/LOG.md" 2> /dev/null; then
  echo "  FAIL  no STATE.md, or the example's content is left in what it wrote:"; grep -nE 'Example file|BlockCapHook|F-24|r05' "$P1/.gauntlet"/*.md 2> /dev/null | sed "s/^/        | /"; fails=$((fails + 1)); else
  echo "  ok    no example content in the three files (no marker, no BlockCapHook, no example finding or round)"; fi
[ "$(grep -c '^## ' "$P1/.gauntlet/STATE.md" 2> /dev/null)" = "$(grep -c '^## ' "$HERE/../state/STATE.md")" ] && grep -q '^# DECISIONS - p1$' "$P1/.gauntlet/DECISIONS.md" \
  && grep -q '^# LOG - p1$' "$P1/.gauntlet/LOG.md" && grep -q 'source: assumed, owner absent' "$P1/.gauntlet/DECISIONS.md" \
  && echo "  ok    the example's section headings in STATE.md; DECISIONS.md and LOG.md titled for the project, with their rules (source: assumed, owner absent)" \
  || { echo "  FAIL  the headings, the titles or the rules are not there"; fails=$((fails + 1)); }
[ "$(tail -1 "$TMP/o5001")" = "init-state: next: $KX_KIT/scripts/next.sh $P1A" ] && echo "  ok    and it ends with the next command: next.sh <proj>" \
  || { echo "  FAIL  its last line is not the next command:"; tail -2 "$TMP/o5001" | sed "s/^/        | /"; fails=$((fails + 1)); }
kx_row 5002 "next.sh after init-state.sh on that project: not refused by the example checks (by marker, title or values) - the row" 4 "$P1"
grep -qE 'FIRST|REFUSED' "$TMP/o5002" && { echo "  FAIL  and something was refused or put first"; fails=$((fails + 1)); }
k5_sum() { (cd "$1/.gauntlet" 2> /dev/null && cat STATE.md DECISIONS.md LOG.md .gitignore 2> /dev/null) | cksum; }
k5_before="$(k5_sum "$P1")"; k5_spec_before="$(cat "$P1/.gauntlet/spec.sha256" 2> /dev/null)"
"$K5_IS" "$P1" > "$TMP/o5003" 2>&1; check "init-state.sh refuses a project that has a .gauntlet/STATE.md" 2 $? "$TMP/o5003"
k5_has "$TMP/o5003" "it names the file and never overwrites it" "init-state: REFUSED - $P1A/.gauntlet/STATE.md exists" "never overwrites"
k5_has "$TMP/o5003" "... and the owner's re-record is named, not handed over (--by; the header says how)" "the owner signs it (--by; the header of scripts/init-state.sh says how)."
k5_no_by "$TMP/o5003" "... and no line of it hands over the runnable form (--by and a quoted name)"
[ "$(k5_sum "$P1")" = "$k5_before" ] && [ "$(cat "$P1/.gauntlet/spec.sha256" 2> /dev/null)" = "$k5_spec_before" ] && echo "  ok    and nothing was written" \
  || { echo "  FAIL  the refusal wrote something"; fails=$((fails + 1)); }
P1R="$K5/p1r"; k5_proj "$P1R"; cp "$FIX/state-new-project.md" "$P1R/STATE.md"
"$K5_IS" "$P1R" > "$TMP/o5004" 2>&1; check "init-state.sh refuses a project with a STATE.md at its root (location: root; next.sh <proj> would read the new one first)" 2 $? "$TMP/o5004"
[ ! -e "$P1R/.gauntlet" ] && echo "  ok    and wrote nothing" || { echo "  FAIL  and it wrote $P1R/.gauntlet"; fails=$((fails + 1)); }
# ---- the K40 refusal names init-state.sh, and init-state.sh replaces the example in that one step (K52: it refused the
# example in its turn - "delete it, then run this again" - two steps where the refusal promised one). The same test as
# next.sh's (scripts/lib/state-example.sh: marker, title, values); a STATE.md of the project's own still refused
P2="$K5/p2"; k5_proj "$P2"; P2A="$(cd "$P2" && pwd)"; mkdir -p "$P2/.gauntlet"; cp "$HERE/../state/STATE.md" "$P2/.gauntlet/STATE.md"
cp "$HERE/../state/DECISIONS.md" "$P2/.gauntlet/DECISIONS.md"
printf '# LOG - Hook\n\n## 2026-09-30 - an entry of the project%ss own\n' "'" > "$P2/.gauntlet/LOG.md"; cp "$P2/.gauntlet/LOG.md" "$TMP/k5-log"
kx_one 5005 "next.sh: the kit's example copied in - the K40 refusal names the command that writes an empty one" 2 "$KX_FIRST - $KX_KIT/scripts/init-state.sh $P2A writes an empty one" "$P2"
"$K5_IS" "$P2" > "$TMP/o5006" 2>&1; check "init-state.sh on it, as the refusal says: the kit's example STATE.md replaced, in that one step (K52)" 0 $? "$TMP/o5006"
k5_has "$TMP/o5006" "... it says so, and for the example DECISIONS.md beside it" "init-state: replaced the kit's example STATE.md - wrote $P2A/.gauntlet/STATE.md" \
  "init-state: replaced the kit's example DECISIONS.md - wrote $P2A/.gauntlet/DECISIONS.md"
[ "$(k5_block "$P2/.gauntlet/STATE.md")" = "$(k5_block "$HERE/../state/README.md")" ] && ! grep -qlE 'Example file|BlockCapHook|F-24|r05' "$P2/.gauntlet/STATE.md" "$P2/.gauntlet/DECISIONS.md" \
  && echo "  ok    STATE.md is now a new project's (state/README.md's starting values), and no example is left in it or in DECISIONS.md" \
  || { echo "  FAIL  the example is still there:"; grep -nE 'Example file|BlockCapHook|F-24|r05' "$P2/.gauntlet/STATE.md" "$P2/.gauntlet/DECISIONS.md" | sed "s/^/        | /"; fails=$((fails + 1)); }
cmp -s "$P2/.gauntlet/LOG.md" "$TMP/k5-log" && grep -q "kept $P2A/.gauntlet/LOG.md" "$TMP/o5006" && echo "  ok    the project's own LOG.md beside it kept as it was, and it says so" \
  || { echo "  FAIL  the project's LOG.md was not kept, or not said"; fails=$((fails + 1)); }
kx_row 5009 "next.sh on it, straight after: the row - the path the K40 refusal names is one command" 4 "$P2"
# the example by its values alone (unmarked, retitled - K48's shape): next.sh refuses it by its values, init-state replaces it
P2V="$K5/p2v"; k5_proj "$P2V"; mkdir -p "$P2V/.gauntlet"
LC_ALL=C sed -E '/Example file. The project is fictional/d; 1s/BlockCapHook/VolumeRewardsHook/' "$HERE/../state/STATE.md" > "$P2V/.gauntlet/STATE.md"
kx_one 5070 "next.sh: the example unmarked and retitled - refused by its values" 2 "$K8_FIRST_VAL" "$P2V"
"$K5_IS" "$P2V" > "$TMP/o5071" 2>&1; check "init-state.sh on it: replaced too - next.sh's own test, by the values" 0 $? "$TMP/o5071"
k5_has "$TMP/o5071" "... and it says so" "init-state: replaced the kit's example STATE.md - wrote"
kx_row 5072 "next.sh on it: the row" 4 "$P2V"
# a STATE.md of the project's own: refused, whatever is beside it - the example DECISIONS.md there too (the STATE wins)
P2R="$K5/p2r"; kx_proj "$P2R"; P2RA="$(cd "$P2R" && pwd)"; cp "$HERE/../state/DECISIONS.md" "$P2R/.gauntlet/DECISIONS.md"; k5_before="$(k5_sum "$P2R")"
kx_one 5073 "next.sh: a STATE.md of the project's own beside the example DECISIONS.md - refused, no init-state.sh suffix" 2 "${KX_FIRST/STATE.md:/DECISIONS.md:}" "$P2R"
"$K5_IS" "$P2R" > "$TMP/o5074" 2>&1; check "init-state.sh: a STATE.md of the project's own, the example DECISIONS.md beside it - refused: the STATE wins" 2 $? "$TMP/o5074"
k5_has "$TMP/o5074" "... naming the STATE.md, never overwritten" "init-state: REFUSED - $P2RA/.gauntlet/STATE.md exists" "never overwrites"
k5_no_by "$TMP/o5074" "... and no line of it hands over the runnable form (--by and a quoted name)"
[ "$(k5_sum "$P2R")" = "$k5_before" ] && echo "  ok    and nothing was written: the example DECISIONS.md is the owner's to delete" \
  || { echo "  FAIL  the refusal wrote something"; fails=$((fails + 1)); }
# no STATE.md, the example LOG.md in .gauntlet/: replaced with the rest
rm -rf "$P2R/.gauntlet"; mkdir -p "$P2R/.gauntlet"; cp "$HERE/../state/LOG.md" "$P2R/.gauntlet/LOG.md"
"$K5_IS" "$P2R" > "$TMP/o5075" 2>&1; check "init-state.sh: no STATE.md, the kit's example LOG.md in .gauntlet/ - written, the LOG.md replaced" 0 $? "$TMP/o5075"
k5_has "$TMP/o5075" "... and it says so" "init-state: replaced the kit's example LOG.md - wrote $P2RA/.gauntlet/LOG.md" "init-state: wrote $P2RA/.gauntlet/STATE.md"
# the example at the project's root (location: root): only .gauntlet/ is replaced - refused, named, nothing written
P2T="$K5/p2t"; k5_proj "$P2T"; P2TA="$(cd "$P2T" && pwd)"; cp "$HERE/../state/STATE.md" "$P2T/STATE.md"
"$K5_IS" "$P2T" > "$TMP/o5076" 2>&1; check "init-state.sh: the kit's example at the project's root - refused, named as the example" 2 $? "$TMP/o5076"
k5_has "$TMP/o5076" "... and it says to delete it" "$P2TA/STATE.md exists, and it is the kit's example" "delete it"
[ ! -e "$P2T/.gauntlet" ] && cmp -s "$P2T/STATE.md" "$HERE/../state/STATE.md" && echo "  ok    and nothing was written" || { echo "  FAIL  the refusal wrote something"; fails=$((fails + 1)); }
# ---- the spec is the owner's: a re-record is REFUSED by default and SIGNED when taken (D1b); the route's spec is
# .gauntlet/SPEC.md (D1c). The old K53 --spec re-record path is gone (K54). Numbered to the plan of v0.4.1b.
K5_TAIL="the spec is the owner's. Undo the change (put the owner's text back) and write what you assumed in DECISIONS.md (source: assumed, owner absent); the route's own spec - phase 1's rows - is $P1A/.gauntlet/SPEC.md, never the owner's file (AGENTS.md section 4). The owner, present, re-records a change of their own with scripts/init-state.sh, signed; an agent never does it."
printf '\n## Decided by the owner\n\n1. The fee is 0.3 percent.\n' >> "$P1/SPEC.md"
# plan case 6 (changed spec): the new tail, and no escape an agent could run (no --by, no `init-state.sh --spec`)
kx_one 5010 "next.sh refuses a SPEC.md changed since init-state recorded it (a walker appended owner decisions): the new tail" 2 "next: REFUSED - $P1A/SPEC.md changed since init-state recorded it: $K5_TAIL" "$P1"
PENDING_RED=0 CITED_FILES=0 nx "$NX" "$P1" > "$TMP/o5011" 2>&1; check "... and no escape turns it off (PENDING_RED=0 CITED_FILES=0)" 2 $? "$TMP/o5011"
if grep -qE -- '--by|init-state\.sh --spec' "$TMP/o5011"; then echo "  FAIL  the changed-spec refusal printed an escape an agent could run:"; grep -nE -- '--by|init-state\.sh --spec' "$TMP/o5011" | sed "s/^/        | /"; fails=$((fails + 1)); else echo "  ok    the refusal names neither --by nor an init-state.sh --spec command"; fi
# plan case 1 (--spec, unsigned): REFUSED by default - nothing written (spec.sha256, LOG.md, STATE.md byte-identical)
k5_before="$(k5_sum "$P1")"; k5_spec_before="$(cat "$P1/.gauntlet/spec.sha256" 2> /dev/null)"; cp "$P1/.gauntlet/LOG.md" "$TMP/k5-log0"; cp "$P1/.gauntlet/STATE.md" "$TMP/k5-state0"
(cd "$K5" && "$K5_IS" --spec SPEC.md "$P1A") > "$TMP/o5012" 2>&1; check "init-state.sh --spec SPEC.md <proj> on a project with a STATE.md, UNSIGNED: REFUSED by default (D1b), run from elsewhere" 2 $? "$TMP/o5012"
k5_has "$TMP/o5012" "the refusal names .gauntlet/SPEC.md, --by and records nothing" ".gauntlet/SPEC.md" "--by" "records nothing"
k5_no_by "$TMP/o5012" "... and no line of it hands over the runnable form (--by and a quoted name)"
[ "$(k5_sum "$P1")" = "$k5_before" ] && [ "$(cat "$P1/.gauntlet/spec.sha256" 2> /dev/null)" = "$k5_spec_before" ] && cmp -s "$P1/.gauntlet/LOG.md" "$TMP/k5-log0" && cmp -s "$P1/.gauntlet/STATE.md" "$TMP/k5-state0" \
  && echo "  ok    spec.sha256, LOG.md and STATE.md byte-identical before and after" || { echo "  FAIL  the unsigned refusal wrote something"; fails=$((fails + 1)); }
# plan case 6 (missing spec): the new tail, on the clean record (before any re-record: no note)
mv "$P1/SPEC.md" "$TMP/k5-spec"
kx_one 5014 "next.sh refuses when the recorded spec is missing: the new tail" 2 "next: REFUSED - $P1A/SPEC.md is missing since init-state recorded it: $K5_TAIL" "$P1"
mv "$TMP/k5-spec" "$P1/SPEC.md"
# plan case 2 (--spec --by "Selftest"): the owner's SIGNED re-record - rc 0, the hash, the signed line, one LOG paragraph, STATE untouched
k5_old8="$(sed -n '1{s/\r$//;p;}' "$P1/.gauntlet/spec.sha256" | cut -c1-8)"
(cd "$K5" && "$K5_IS" --spec SPEC.md --by "Selftest" "$P1A") > "$TMP/o5012b" 2>&1; check "init-state.sh --spec SPEC.md --by \"Selftest\" <proj>: the owner's SIGNED re-record, run from elsewhere" 0 $? "$TMP/o5012b"
k5_has "$TMP/o5012b" "it says it re-recorded, signed --by \"Selftest\"" "a re-record signed --by \"Selftest\"."
k5_new8="$(sed -n '1{s/\r$//;p;}' "$P1/.gauntlet/spec.sha256" | cut -c1-8)"
[ "$(sed -n 1p "$P1/.gauntlet/spec.sha256")" = "$(k5_sha "$P1/SPEC.md")  SPEC.md" ] && [ "$(sed -n 2p "$P1/.gauntlet/spec.sha256")" = "re-recorded $(date +%F) by \"Selftest\" $k5_old8 -> $k5_new8" ] && cmp -s "$P1/.gauntlet/STATE.md" "$TMP/k5-state0" \
  && echo "  ok    spec.sha256 line 1 the new hash and path, line 2 the signed re-record; STATE.md untouched" || { echo "  FAIL  spec.sha256 lines wrong or STATE.md touched:"; sed "s/^/        | /" "$P1/.gauntlet/spec.sha256"; fails=$((fails + 1)); }
[ "$(grep -c 'spec re-recorded' "$P1/.gauntlet/LOG.md")" = 1 ] && grep -qF 'signed --by "Selftest"' "$P1/.gauntlet/LOG.md" && ! grep -qF "the owner's act" "$P1/.gauntlet/LOG.md" \
  && echo "  ok    LOG.md gained exactly one paragraph, signed --by \"Selftest\", without \"the owner's act\"" || { echo "  FAIL  LOG.md paragraph wrong:"; grep -n 're-recorded' "$P1/.gauntlet/LOG.md" | sed "s/^/        | /"; fails=$((fails + 1)); }
# plan case 5 (next.sh after the signed re-record): the row, plus the note under it, exact text
nx "$NX" "$P1" > "$TMP/o5013" 2>&1; check "next.sh after the signed re-record: the row" 0 $? "$TMP/o5013"
grep -q '^next: row 4 - ' "$TMP/o5013" && grep -qxF "next: note - the spec SPEC.md was re-recorded on $(date +%F), signed --by \"Selftest\" ($k5_old8 -> $k5_new8; .gauntlet/spec.sha256): the owner confirms that signature is theirs, or the spec in force is not the owner's" "$TMP/o5013" \
  && echo "  ok    the row, plus the re-record note under it, exact text" || { echo "  FAIL  the row or the note is wrong:"; sed "s/^/        | /" "$TMP/o5013"; fails=$((fails + 1)); }
# plan case 4 (a second signed re-record): line 3 appended, line 2 kept; the note counts them
k5_l2="$(sed -n 2p "$P1/.gauntlet/spec.sha256")"; k5_o8b="$k5_new8"
printf '\n2. A floor applies.\n' >> "$P1/SPEC.md"
(cd "$K5" && "$K5_IS" --spec SPEC.md --by "Selftest" "$P1A") > "$TMP/o5013b" 2>&1; check "a second signed re-record (the re-records accumulate)" 0 $? "$TMP/o5013b"
k5_n8b="$(sed -n '1{s/\r$//;p;}' "$P1/.gauntlet/spec.sha256" | cut -c1-8)"
[ "$(sed -n 2p "$P1/.gauntlet/spec.sha256")" = "$k5_l2" ] && [ "$(sed -n 3p "$P1/.gauntlet/spec.sha256")" = "re-recorded $(date +%F) by \"Selftest\" $k5_o8b -> $k5_n8b" ] \
  && echo "  ok    line 2 kept, line 3 appended" || { echo "  FAIL  the re-record lines are wrong:"; sed "s/^/        | /" "$P1/.gauntlet/spec.sha256"; fails=$((fails + 1)); }
nx "$NX" "$P1" > "$TMP/o5013c" 2>&1
grep -qF "was re-recorded (2 re-records; the last:) on $(date +%F), signed --by \"Selftest\" ($k5_o8b -> $k5_n8b;" "$TMP/o5013c" \
  && echo "  ok    next.sh note counts them: (2 re-records; the last:), the last line's hashes" || { echo "  FAIL  the two-re-record note is wrong:"; grep 'note - the spec' "$TMP/o5013c" | sed "s/^/        | /"; fails=$((fails + 1)); }
# plan case 3 (--by with no name, --by on a new project): rc 2 each, nothing written, each named
PBY="$K5/pby"; k5_proj "$PBY"; "$K5_IS" "$PBY" > /dev/null 2>&1
(cd "$K5" && "$K5_IS" --spec SPEC.md --by "" pby) > "$TMP/o5080a" 2>&1; check "init-state.sh --by \"\" on a project with a STATE.md: refused (--by has no name)" 2 $? "$TMP/o5080a"
k5_has "$TMP/o5080a" "... named" "--by has no name"
(cd "$K5" && "$K5_IS" pby --spec SPEC.md --by) > "$TMP/o5080b" 2>&1; check "init-state.sh ... --by with no value: refused" 2 $? "$TMP/o5080b"
PNEW="$K5/pnew"; k5_proj "$PNEW"
(cd "$K5" && "$K5_IS" --spec SPEC.md --by "Selftest" pnew) > "$TMP/o5080c" 2>&1; check "init-state.sh --by on a NEW project (no STATE.md): refused - a new project records its spec without a signature" 2 $? "$TMP/o5080c"
k5_has "$TMP/o5080c" "... named as the signature" "--by is the re-record's signature"
[ ! -e "$PNEW/.gauntlet" ] && echo "  ok    and --by on a new project wrote nothing" || { echo "  FAIL  --by on a new project wrote $PNEW/.gauntlet"; fails=$((fails + 1)); }
# plan case 7 (first run): stdout names .gauntlet/SPEC.md and prints no --spec command; and case 5's other half -
# a project whose spec.sha256 has one line only (every project before this change): no note
P1F="$K5/p1f"; k5_proj "$P1F"; P1FA="$(cd "$P1F" && pwd)"
"$K5_IS" "$P1F" > "$TMP/o5081" 2>&1; check "init-state.sh <proj> first run: the state and the spec recorded" 0 $? "$TMP/o5081"
grep -qF "$P1FA/.gauntlet/SPEC.md" "$TMP/o5081" && ! grep -qF -- '--spec' "$TMP/o5081" \
  && echo "  ok    first-run stdout names .gauntlet/SPEC.md and prints no --spec command" || { echo "  FAIL  first-run stdout wrong:"; sed "s/^/        | /" "$TMP/o5081"; fails=$((fails + 1)); }
nx "$NX" "$P1F" > "$TMP/o5082" 2>&1
grep -q '^next: note - the spec' "$TMP/o5082" && { echo "  FAIL  a project with a one-line spec.sha256 got a re-record note:"; grep 'note - the spec' "$TMP/o5082" | sed "s/^/        | /"; fails=$((fails + 1)); } || echo "  ok    a one-line spec.sha256 (every project before this change): no re-record note"
# a project set up by hand (no spec record): still silent (unchanged)
rm -f "$P1/.gauntlet/spec.sha256"; printf 'one more line\n' >> "$P1/SPEC.md"
kx_row 5015 "next.sh with no spec record (a project set up by hand), the spec edited: silent - the row" 4 "$P1"
grep -qi 'spec' "$TMP/o5015" && { echo "  FAIL  and it said something of the spec: $(grep -i spec "$TMP/o5015")"; fails=$((fails + 1)); }
mkdir -p "$P1/.gauntlet"; printf 'not a record\n' > "$P1/.gauntlet/spec.sha256"
nx "$NX" "$P1" > "$TMP/o5016" 2>&1; check "next.sh refuses a spec.sha256 that is not '<sha256>  <path>'" 2 $? "$TMP/o5016"
P3="$K5/p3"; k5_proj "$P3"; rm -f "$P3/SPEC.md"
"$K5_IS" "$P3" > "$TMP/o5017" 2>&1; check "init-state.sh on a project with no SPEC.md: the state written, nothing recorded" 0 $? "$TMP/o5017"
k5_has "$TMP/o5017" "... and it says no spec was found" "init-state: no spec found"
k5_has "$TMP/o5017" "... and the later record it names is the owner's, signed, named and not handed over (K55: --spec --by; the header says how)" "until one is - the owner's act, signed (--spec --by; the header of scripts/init-state.sh says how)."
k5_no_by "$TMP/o5017" "... and no line of it hands over the runnable form (--by and a quoted name)"
[ ! -e "$P3/.gauntlet/spec.sha256" ] && [ -f "$P3/.gauntlet/STATE.md" ] && echo "  ok    no spec.sha256" || { echo "  FAIL  a spec.sha256 was written, or no STATE.md"; fails=$((fails + 1)); }
P4="$K5/p4"; k5_proj "$P4" docs/SPEC-v1.md; P4A="$(cd "$P4" && pwd)"
"$K5_IS" "$P4" --spec docs/SPEC-v1.md > "$TMP/o5018" 2>&1; check "init-state.sh <proj> --spec docs/SPEC-v1.md (a spec of another name, the arguments the other way round)" 0 $? "$TMP/o5018"
[ "$(cat "$P4/.gauntlet/spec.sha256" 2> /dev/null)" = "$(k5_sha "$P4/docs/SPEC-v1.md")  docs/SPEC-v1.md" ] && echo "  ok    recorded as docs/SPEC-v1.md, relative to the project" \
  || { echo "  FAIL  not recorded as docs/SPEC-v1.md: $(cat "$P4/.gauntlet/spec.sha256" 2> /dev/null)"; fails=$((fails + 1)); }
echo 'x' >> "$P4/docs/SPEC-v1.md"
nx "$NX" "$P4" > "$TMP/o5019" 2>&1; check "next.sh refuses docs/SPEC-v1.md changed" 2 $? "$TMP/o5019"
k5_has "$TMP/o5019" "... naming it" "next: REFUSED - $P4A/docs/SPEC-v1.md changed since init-state recorded it"
P5="$K5/p5"; k5_proj "$P5"; printf '# SPEC elsewhere\n' > "$K5/outside.md"
"$K5_IS" "$P5" --spec "$K5/outside.md" > "$TMP/o5020" 2>&1; check "init-state.sh refuses a --spec outside the project" 2 $? "$TMP/o5020"
"$K5_IS" "$P5" --spec NOPE.md > "$TMP/o5021" 2>&1; check "init-state.sh refuses a --spec that does not exist" 2 $? "$TMP/o5021"
[ ! -e "$P5/.gauntlet" ] && echo "  ok    and neither wrote anything" || { echo "  FAIL  a refusal wrote $P5/.gauntlet"; fails=$((fails + 1)); }
# ---- the phase against its records (D2): phase 2+ needs a green build record, phase 3+ a battery run
P6="$K5/p6"; kx_proj "$P6"; P6A="$(cd "$P6" && pwd)"
k5_phase() { sed -E "s/^phase: .*/phase:                     $1/; s/^battery: .*/battery:                   $2/" "$FIX/state-new-project.md" > "$P6/.gauntlet/STATE.md"; }
K5_BUILD="next: REFUSED - phase 2 is open but there is no green build record (.gauntlet/reports/01-build.txt): run $KX_KIT/scripts/setup-deps.sh $P6A then $KX_KIT/scripts/battery.sh $P6A (they may run at phase 1), or write the phase that is open"
k5_phase 1 never
kx_row 5030 "next.sh: phase 1, no build record: not refused (phase 1 claims no compiling hook) - the row" 4 "$P6"
k5_phase 2 never
kx_one 5031 "next.sh refuses phase 2 with no build record (a walker wrote phase 2 by hand; the hook never compiled)" 2 "$K5_BUILD" "$P6"
PENDING_RED=0 CITED_FILES=0 nx "$NX" "$P6" > "$TMP/o5032" 2>&1; check "... and no escape turns it off" 2 $? "$TMP/o5032"
mkdir -p "$P6/.gauntlet/reports"; cp "$FIX/build-nm-error-then-warnings.txt" "$P6/.gauntlet/reports/01-build.txt"
kx_one 5033 "next.sh refuses phase 2 with a RED build record (Compiler run failed)" 2 "$K5_BUILD" "$P6"
: > "$P6/.gauntlet/reports/01-build.txt"
kx_one 5034 "next.sh refuses phase 2 with an empty build record" 2 "$K5_BUILD" "$P6"
cp "$FIX/build-real-compiled.txt" "$P6/.gauntlet/reports/01-build.txt"
kx_row 5035 "next.sh: phase 2, a green build record (forge's 'Compiler run successful!'): the row" 4b "$P6"
cp "$FIX/build-real-noop.txt" "$P6/.gauntlet/reports/01-build.txt"
kx_row 5036 "next.sh: phase 2, a green build record ('No files changed, compilation skipped'): the row" 4b "$P6"
printf 'Compiling 2 files with Solc 0.8.26\r\nSolc 0.8.26 finished in 1.00ms\r\nCompiler run successful with warnings:\r\nWarning (2018): Function state mutability can be restricted to view\r\n' > "$P6/.gauntlet/reports/01-build.txt"
kx_row 5037 "next.sh: phase 2, a green build record with warnings, CRLF: the row" 4b "$P6"
k5_phase 3 never
kx_one 5038 "next.sh refuses phase 3 with battery: never (phase 2's gate includes a battery run)" 2 "next: REFUSED - phase 3 claims phase 2 closed and battery is never: $KX_KIT/scripts/battery.sh $P6A, or write the phase that is open" "$P6"
k5_phase 4 never
nx "$NX" "$P6" > "$TMP/o5039" 2>&1; check "next.sh refuses phase 4 with battery: never" 2 $? "$TMP/o5039"
k5_has "$TMP/o5039" "... naming the phase" "next: REFUSED - phase 4 claims phase 2 closed and battery is never"
k5_phase 3 green
cp "$FIX/summary-real-many-suites.txt" "$P6/.gauntlet/reports/02-test.txt"   # K60: battery green claims a green test record
kx_row 5040 "next.sh: phase 3, battery green, a green build record and a green test record: the row" 4b "$P6"
rm -rf "$P6/.gauntlet/reports"; k5_phase 3 green
nx "$NX" "$P6" > "$TMP/o5041" 2>&1; check "next.sh refuses phase 3, battery green, with no build record" 2 $? "$TMP/o5041"
k5_has "$TMP/o5041" "... for the build record" "next: REFUSED - phase 3 is open but there is no green build record (.gauntlet/reports/01-build.txt): run $KX_KIT/scripts/setup-deps.sh $P6A then $KX_KIT/scripts/battery.sh $P6A (they may run at phase 1), or write the phase that is open"
mkdir -p "$K5/fx"; cp "$FIX/state-row-13.md" "$K5/fx/"
nx "$NX" "$K5/fx/state-row-13.md" --judge "$(nx_meta "$FIX/state-row-13.md" judge)" > "$TMP/o5042" 2>&1
check "next.sh: the fixture of row 13 (phase 4) from a directory with no build record is refused - the cases above run in projects that have one (NXFIX)" 2 $? "$TMP/o5042"
# ---- `key:value` copies of the example (D7: K49's known gap, `ceiling:8 model rounds ...`)
P7="$K5/p7"; kx_proj "$P7"
LC_ALL=C sed -E '/Example file. The project is fictional/d; 1s/BlockCapHook/VolumeRewardsHook/; s/^([a-z_]+):[[:space:]]+/\1:/' "$K8_EX" > "$P7/.gauntlet/STATE.md"
grep -q '^ceiling:8 model rounds' "$P7/.gauntlet/STATE.md" && echo "  ok    (the copy has no space after any colon: ceiling:8 model rounds ...)" || { echo "  FAIL  the copy is not key:value"; fails=$((fails + 1)); }
kx_one 5050 "next.sh refuses the example unmarked, retitled, every flag line key:value (ceiling:8 ...), naming the example's line" 2 "$K8_FIRST_VAL" "$P7/.gauntlet/STATE.md"
k5_kv() { # k5_kv <flag>...: the new project's STATE.md with those flags' lines the kit's example's, written key:value
  local f l; kx_proj "$P7"
  for f in "$@"; do
    l="$(LC_ALL=C awk '/^```/ { b = !b; next } b' "$K8_EX" | grep -m 1 "^$f:" | LC_ALL=C sed -E 's/^([a-z_]+):[[:space:]]+/\1:/')"
    LC_ALL=C awk -v f="$f" -v l="$l" 'index($0, f ":") == 1 { print l; next } { print }' "$P7/.gauntlet/STATE.md" > "$P7/s" && mv "$P7/s" "$P7/.gauntlet/STATE.md"
  done
}
k5_kv ceiling
kx_row 5051 "next.sh: the example's ceiling alone, written ceiling:8 ... (two lines shared with last_other_round): not refused, the row" 4 "$P7/.gauntlet/STATE.md"
k5_kv ceiling notes
kx_one 5052 "next.sh refuses three lines shared with the example, two of them key:value (ceiling:8 ..., notes:static ...)" \
  2 "next: FIRST - fill STATE.md: its values are still the kit's example's ($(LC_ALL=C awk '/^```/ { b = !b; next } b' "$K8_EX" | grep -m 1 '^last_other_round:'))" "$P7/.gauntlet/STATE.md"
# ---- the MANIFEST note (D6): a kit copy, its MANIFEST, files it does not list
MK="$K5/kit"; mkdir -p "$MK/scripts/lib" "$MK/doctrine" "$MK/state" "$MK/foundry-kit/v4/test/examples"
cp "$HERE"/*.sh "$HERE"/*.py "$MK/scripts/"; cp "$HERE"/lib/*.sh "$HERE"/lib/*.py "$MK/scripts/lib/"; cp "$NXT" "$MK/doctrine/"; cp "$K8_EX" "$MK/state/"
printf '// the kit\n' > "$MK/foundry-kit/v4/test/examples/Ex.t.sol"
MKN="$MK/scripts/next.sh"
nx "$NX" "$FIX/state-new-project.md" > "$TMP/o5060r" 2>&1
printf '// a stray\n' > "$MK/foundry-kit/stray.sol"
nx "$MKN" "$FIX/state-new-project.md" > "$TMP/o5060" 2>&1; check "next.sh, a kit copy with no MANIFEST and a stray file: the row" 0 $? "$TMP/o5060"
cmp -s "$TMP/o5060" "$TMP/o5060r" && echo "  ok    and nothing more than the kit's own next.sh prints: no MANIFEST, no note" \
  || { echo "  FAIL  it printed more than the row:"; sed "s/^/        | /" "$TMP/o5060"; fails=$((fails + 1)); }
rm -f "$MK/foundry-kit/stray.sol"
(cd "$MK" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do printf '%s  %s\n' "$(k5_sha "$f")" "$f"; done) > "$TMP/k5-manifest" && mv "$TMP/k5-manifest" "$MK/MANIFEST"
mkdir -p "$MK/foundry-kit/lib/dep/src" "$MK/foundry-kit/v4/out/A.sol" "$MK/cache" "$MK/foundry-kit/v4/test/cache" "$MK/.gauntlet" "$MK/.git/refs"
# what the kit's own runs write (K52): the selftest's corpus/, the batteries' .gauntlet/reports/, census/, broadcast/
mkdir -p "$MK/foundry-kit/corpus/T" "$MK/foundry-kit/v4/.gauntlet/reports" "$MK/foundry-kit/v4/census" "$MK/foundry-kit/v4/broadcast/S.s.sol/1"
printf 'c\n' > "$MK/foundry-kit/corpus/T/1"; printf 'r\n' > "$MK/foundry-kit/v4/.gauntlet/reports/02-test.txt"; printf 'n\n' > "$MK/foundry-kit/v4/census/c.tsv"
printf '{}\n' > "$MK/foundry-kit/v4/broadcast/S.s.sol/1/run.json"
printf 'dep\n' > "$MK/foundry-kit/lib/dep/src/D.sol"; printf '{}\n' > "$MK/foundry-kit/v4/out/A.sol/A.json"; printf '{}\n' > "$MK/cache/solidity-files-cache.json"
printf 'x\n' > "$MK/foundry-kit/v4/test/cache/x"; printf 'marker\n' > "$MK/.gauntlet/selftest-passed"; printf 'ref: refs/heads/main\n' > "$MK/.git/HEAD"
mkdir -p "$MK/foundry-kit/v4/sub/.git"; printf 'ref: refs/heads/main\n' > "$MK/foundry-kit/v4/sub/.git/HEAD"
nx "$MKN" "$FIX/state-new-project.md" > "$TMP/o5061" 2>&1; check "next.sh, a kit copy with a MANIFEST; files only in lib/, cache/, out/, corpus/, census/, broadcast/, .gauntlet/ (anywhere), .git (any depth): the row" 0 $? "$TMP/o5061"
cmp -s "$TMP/o5061" "$TMP/o5060r" && echo "  ok    and no note: MANIFEST itself, the marker, deps, builds, .git and what the kit's own runs write are not counted" \
  || { echo "  FAIL  it printed more than the row:"; sed "s/^/        | /" "$TMP/o5061"; fails=$((fails + 1)); }
mkdir -p "$MK/foundry-kit/v4/test/examples/proj/test"; printf '// written by a walker whose cd drifted\n' > "$MK/foundry-kit/v4/test/examples/proj/test/Stray.t.sol"
NEXT_SELFTEST=1 "$MKN" "$FIX/state-new-project.md" > "$TMP/o5062" 2> /dev/null; check "next.sh, the kit copy with a file its MANIFEST does not list: the row, the exit code unchanged" 0 $? "$TMP/o5062"
[ "$(tail -1 "$TMP/o5062")" = "next: note - the kit has 1 file not in its MANIFEST (foundry-kit/v4/test/examples/proj/test/Stray.t.sol): the kit is not to be changed; move it out" ] \
  && grep -q '^next: row 4 - ' "$TMP/o5062" && echo "  ok    and, after the answer, on stdout: the note naming the file" \
  || { echo "  FAIL  not the row then the note on stdout:"; sed "s/^/        | /" "$TMP/o5062"; fails=$((fails + 1)); }
mkdir -p "$MK/.github"; printf 'x\n' > "$MK/a-stray.md"; printf 'x\n' > "$MK/scripts/stray.sh.bak"; printf 'x\n' > "$MK/.github/stray.yml"; printf 'x\n' > "$MK/scripts/lib/stray.sh"
printf 'x\n' > "$MK/.gauntlet/reports.txt"   # under .gauntlet/: not counted (K52)
NEXT_SELFTEST=1 "$MKN" "$FIX/state-new-project.md" > "$TMP/o5063" 2> /dev/null; check "next.sh, five files not listed (one in scripts/lib/, the kit's own library - not a dependency): the row" 0 $? "$TMP/o5063"
[ "$(tail -1 "$TMP/o5063")" = "next: note - the kit has 5 files not in its MANIFEST (.github/stray.yml, a-stray.md, foundry-kit/v4/test/examples/proj/test/Stray.t.sol): the kit is not to be changed; move them out" ] \
  && echo "  ok    the note counts them (scripts/lib/stray.sh with them) and names the first three" || { echo "  FAIL  not the note for five:"; tail -1 "$TMP/o5063" | sed "s/^/        | /"; fails=$((fails + 1)); }
NEXT_SELFTEST=1 "$MKN" "$K8_EX" > "$TMP/o5064" 2> "$TMP/o5064e"; check "next.sh refusing (the kit's example), the kit copy with files not listed: the refusal's exit code" 2 $? "$TMP/o5064e"
grep -q '^next: note - the kit has 5 files not in its MANIFEST' "$TMP/o5064" && grep -q "^next: FIRST - fill STATE.md: it is still the kit's example" "$TMP/o5064e" \
  && echo "  ok    the refusal on stderr, the note on stdout after it" || { echo "  FAIL  not the refusal and the note:"; cat "$TMP/o5064" "$TMP/o5064e" | sed "s/^/        | /"; fails=$((fails + 1)); }
nx "$MKN" --check-table > "$TMP/o5065" 2>&1; check "next.sh --check-table on the kit copy: no note (it reads no project)" 0 $? "$TMP/o5065"
grep -q 'note' "$TMP/o5065" && { echo "  FAIL  and it printed the note"; fails=$((fails + 1)); }
rm -f "$MK/MANIFEST"
nx "$MKN" "$FIX/state-new-project.md" > "$TMP/o5066" 2>&1; check "next.sh, the same kit copy with its MANIFEST removed: the row" 0 $? "$TMP/o5066"
cmp -s "$TMP/o5066" "$TMP/o5060r" && echo "  ok    and no note: no MANIFEST, nothing said" || { echo "  FAIL  it printed more than the row:"; sed "s/^/        | /" "$TMP/o5066"; fails=$((fails + 1)); }
# ---- the words, where a reader looks
k5_row0="$(LC_ALL=C awk '/^\| 0 \|/' "$NXT")"   # captured, then matched (pipefail, K62)
[[ $k5_row0 == *'scripts/init-state.sh'* ]] \
  && echo "  ok    NEXT.md's row 0 names scripts/init-state.sh" || { echo "  FAIL  NEXT.md's row 0 does not name scripts/init-state.sh"; fails=$((fails + 1)); }
grep -q 'scripts/init-state.sh' "$HERE/../state/README.md" && echo "  ok    state/README.md names scripts/init-state.sh" \
  || { echo "  FAIL  state/README.md does not name scripts/init-state.sh"; fails=$((fails + 1)); }
k5_min="$(sed -n 's/^SELFTEST_MINUTES=\([0-9][0-9]*\)$/\1/p' "$NX")"
[ -n "$k5_min" ] && [ "$k5_min" -ge 1 ] && echo "  ok    next.sh's FIRST line says the selftest takes about $k5_min minutes (SELFTEST_MINUTES, measured)" \
  || { echo "  FAIL  next.sh has no SELFTEST_MINUTES=<whole minutes>"; fails=$((fails + 1)); }
if [ -s "$TMP/nx-silent" ]; then echo "  FAIL  next.sh ran with NEXT_SELFTEST=1 and did not say so (K50 cases):"; sed "s/^/        | /" "$TMP/nx-silent"; fails=$((fails + 1)); fi
if [ -s "$TMP/nx-kitnotes" ]; then
  echo "  note  this kit's own next.sh printed its MANIFEST note in $(grep -c . "$TMP/nx-kitnotes") of its runs above (taken out of what the cases read; not a case): $(LC_ALL=C sort -u "$TMP/nx-kitnotes" | head -1)"
elif [ -f "$HERE/../MANIFEST" ]; then echo "  ok    this kit's own next.sh printed no MANIFEST note in its runs above: every file under the kit is in its MANIFEST"
else echo "  ok    this kit has no MANIFEST: its next.sh printed no note"; fi
# --- end K50 ---

# --- K42/K43 ---
# ================================================================= setup-deps.sh, doctor.sh's deps line, install-skills.sh --harness hermes (no forge needed)
# setup-deps.sh writes a project's remappings.txt and foundry.toml for the vendored layout (QUICKSTART.md step 7b) and
# then runs `forge build`. Here the kit it finds is a FAKE one (the directories its remappings name, empty), and the
# forge on the PATH is a stub that writes its arguments and directory to a log and exits with what the case asks
# (K42_FORGE_RC): what is proven is what the script writes, refuses and runs - not that forge compiles it (that was
# measured on real projects, LOG). Then install-skills.sh --harness hermes into a temporary HERMES_HOME and projects.
echo "== setup-deps.sh, doctor.sh's deps line, install-skills.sh --harness hermes (K42/K43) =="
k42_has() { # k42_has <label> <file> <fixed string>...: every string is in the file
  local label="$1" f="$2" s miss=""; shift 2
  for s in "$@"; do grep -qF -- "$s" "$f" || miss="$miss [$s]"; done
  if [ -z "$miss" ]; then echo "  ok    $label"; else echo "  FAIL  $label: not found:$miss"; sed "s/^/        | /" "$f" | tail -n 12; fails=$((fails + 1)); fi
}
k42_not() { # k42_not <label> <file> <fixed string>: the string is NOT in the file
  if grep -qF -- "$3" "$2"; then echo "  FAIL  $1: found [$3]"; sed "s/^/        | /" "$2" | tail -n 12; fails=$((fails + 1)); else echo "  ok    $1"; fi
}
K42="$TMP/k42"; mkdir -p "$K42/bin"
# the stub forge: its arguments and directory, one line per call
printf '#!/usr/bin/env bash\necho "forge $* in $PWD" >> "%s/forge.log"\nexit "${K42_FORGE_RC:-0}"\n' "$K42" > "$K42/bin/forge"; chmod +x "$K42/bin/forge"
k42_kit() { # k42_kit <dir>: a fake kit there - the files setup-deps.sh checks, and every directory the v4 module's remappings name
  local k="$1" line t
  mkdir -p "$k/foundry-kit/src" "$k/foundry-kit/v4/src" "$k/scripts"
  cp "$HERE/../foundry-kit/v4/remappings.txt" "$k/foundry-kit/v4/"; : > "$k/foundry-kit/v4/src/V4Harness.sol"
  while IFS= read -r line; do
    t="${line#*=}"; case "$t" in ../*) continue ;; esac
    case "$line" in v4-periphery/* | permit2/* | openzeppelin-contracts/*) continue ;; esac
    mkdir -p "$k/foundry-kit/v4/$t"
  done < "$HERE/../foundry-kit/v4/remappings.txt"
  mkdir -p "$k/foundry-kit/v4/lib/v4-core/src"; : > "$k/foundry-kit/v4/lib/v4-core/src/PoolManager.sol"
}
k42_run() { # k42_run <output file> [args...]: setup-deps.sh with the stub forge first on the PATH, SETUP_DEPS_KEEP_LIB unset unless given
  local o="$1"; shift
  : > "$K42/forge.log"
  env -u SETUP_DEPS_KEEP_LIB PATH="$K42/bin:$PATH" "$@" > "$o" 2>&1
}
SD="$HERE/setup-deps.sh"
# the ../ layout: a proj/ beside lib/hook-gauntlet, no remappings.txt, no foundry.toml
W1="$K42/w1"; k42_kit "$W1/lib/hook-gauntlet"; mkdir -p "$W1/proj/src"; W1="$(cd "$W1" && pwd)"
k42_run "$TMP/k42-o01" "$SD" "$W1/proj"; check "setup-deps.sh: a proj/ beside lib/hook-gauntlet, nothing set up yet" 0 $? "$TMP/k42-o01"
k42_exp="$TMP/k42-exp01"
printf '%s\n' 'forge-std/=../lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/lib/forge-std/src/' \
  'ds-test/=../lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/lib/forge-std/lib/ds-test/src/' \
  'solmate/=../lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/lib/solmate/' \
  '@openzeppelin/=../lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/lib/openzeppelin-contracts/' \
  'v4-core/=../lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/' '@uniswap/v4-core/=../lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/' \
  'gauntlet-kit/=../lib/hook-gauntlet/foundry-kit/src/' 'gauntlet-v4/=../lib/hook-gauntlet/foundry-kit/v4/src/' > "$k42_exp"
if cmp -s "$k42_exp" "$W1/proj/remappings.txt"; then echo "  ok    remappings.txt is the eight lines of the 7b recipe, through ../lib/hook-gauntlet (FR16's, measured)"; else
  echo "  FAIL  remappings.txt is not the eight lines:"; diff "$k42_exp" "$W1/proj/remappings.txt" | sed "s/^/        | /"; fails=$((fails + 1)); fi
k42_has "foundry.toml has the 7b lines, allow_paths for ../" "$W1/proj/foundry.toml" '[profile.default]' 'libs = []' \
  'solc_version = "0.8.26"' 'evm_version = "cancun"' 'allow_paths = ["../lib/hook-gauntlet/foundry-kit"]' \
  'additional_compiler_profiles = [{ name = "manager", via_ir = true, optimizer_runs = 44444444 }]' \
  '{ paths = "../lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/src/PoolManager.sol", via_ir = true, optimizer_runs = 44444444 },'
k42_has "and it printed each line it wrote, then the build it ran" "$TMP/k42-o01" \
  'setup-deps: remappings.txt: + gauntlet-v4/=../lib/hook-gauntlet/foundry-kit/v4/src/' \
  'setup-deps: foundry.toml [profile.default]: + allow_paths = ["../lib/hook-gauntlet/foundry-kit"]' 'setup-deps: running: forge build' \
  'setup-deps: DONE'
if [ "$(cat "$K42/forge.log")" = "forge build in $W1/proj" ]; then echo "  ok    forge build ran once, in the project"; else
  echo "  FAIL  forge calls: $(tr '\n' ';' < "$K42/forge.log")"; fails=$((fails + 1)); fi
if [ ! -e "$W1/proj/lib" ] && [ "$(find "$W1/proj" -type f | wc -l | tr -d ' ')" = 2 ]; then echo "  ok    and nothing was copied into the project: remappings.txt and foundry.toml only"; else
  echo "  FAIL  the project holds: $(cd "$W1/proj" && find . -type f | tr '\n' ' ')"; fails=$((fails + 1)); fi
k42_h1="$(hash_of "$W1/proj/remappings.txt")$(hash_of "$W1/proj/foundry.toml")"
k42_run "$TMP/k42-o02" "$SD" "$W1/proj"; check "setup-deps.sh again: nothing to change" 0 $? "$TMP/k42-o02"
k42_has "it says so for both files and still builds" "$TMP/k42-o02" 'setup-deps: remappings.txt: nothing to change' 'setup-deps: foundry.toml: nothing to change' 'setup-deps: running: forge build'
[ "$(hash_of "$W1/proj/remappings.txt")$(hash_of "$W1/proj/foundry.toml")" = "$k42_h1" ] || { echo "  FAIL  and the files changed"; fails=$((fails + 1)); }
# --check (what doctor.sh reads) and doctor.sh's line
k42_run "$TMP/k42-o03" "$SD" --check "$W1/proj"; check "setup-deps.sh --check on the project it set up" 0 $? "$TMP/k42-o03"
"$HERE/doctor.sh" "$W1/proj" > "$TMP/k42-o04" 2>&1
k42_has "doctor.sh <proj>: deps: ok" "$TMP/k42-o04" 'deps: ok'
mkdir -p "$K42/w1/proj2/src"
"$HERE/doctor.sh" "$W1/proj2" > "$TMP/k42-o05" 2>&1; k42_rc=$?
check "doctor.sh <proj> on a project not set up: not ready" 1 "$k42_rc" "$TMP/k42-o05"
k42_has "and it names the command" "$TMP/k42-o05" "deps: $W1/proj2: not set up - scripts/setup-deps.sh $W1/proj2"
k42_last="$(tail -n 1 "$TMP/k42-o05")"   # captured, then matched (pipefail, K62)
if grep -qE '^doctor: missing: (.*, )?deps$' <<< "$k42_last"; then echo "  ok    and its last line lists deps as missing"; else
  echo "  FAIL  last line: $(tail -n 1 "$TMP/k42-o05")"; fails=$((fails + 1)); fi
k42_run "$TMP/k42-o06" "$SD" --check "$W1/proj2"; check "setup-deps.sh --check on a project not set up" 1 $? "$TMP/k42-o06"
# --dry-run: printed, nothing written, nothing built
k42_run "$TMP/k42-o07" "$SD" --dry-run "$W1/proj2"; check "setup-deps.sh --dry-run" 0 $? "$TMP/k42-o07"
k42_has "it prints what it would write and the build it would run" "$TMP/k42-o07" \
  'setup-deps: dry-run - remappings.txt: + v4-core/=../lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/' 'setup-deps: dry-run - would run: forge build'
if [ "$(find "$W1/proj2" -type f | wc -l | tr -d ' ')" = 0 ] && [ ! -s "$K42/forge.log" ]; then echo "  ok    and nothing was written, forge never called"; else
  echo "  FAIL  written: $(find "$W1/proj2" -type f | tr '\n' ' '); forge: $(tr '\n' ';' < "$K42/forge.log")"; fails=$((fails + 1)); fi
# the project's own lib/v4-core (the local-model walk's copy of the kit's): refused, nothing written; SETUP_DEPS_KEEP_LIB=1 goes ahead
mkdir -p "$W1/proj2/lib/v4-core/src" "$W1/proj2/lib/forge-std"
k42_run "$TMP/k42-o08" "$SD" "$W1/proj2"; check "setup-deps.sh: a project with its own lib/v4-core and lib/forge-std is refused" 2 $? "$TMP/k42-o08"
k42_has "and the refusal says which, and the way out" "$TMP/k42-o08" \
  "setup-deps: $W1/proj2/lib/v4-core exists - a copy of the kit's? remove it or SETUP_DEPS_KEEP_LIB=1" \
  "setup-deps: $W1/proj2/lib/forge-std exists - a copy of the kit's? remove it or SETUP_DEPS_KEEP_LIB=1"
if [ ! -e "$W1/proj2/remappings.txt" ] && [ ! -e "$W1/proj2/foundry.toml" ] && [ ! -s "$K42/forge.log" ]; then echo "  ok    nothing written, nothing built"; else
  echo "  FAIL  something was written or built"; fails=$((fails + 1)); fi
k42_run "$TMP/k42-o09" env SETUP_DEPS_KEEP_LIB=1 "$SD" "$W1/proj2"; check "SETUP_DEPS_KEEP_LIB=1: the same project goes ahead" 0 $? "$TMP/k42-o09"
k42_has "and it says the lib/ was kept and is not what the remappings reach" "$TMP/k42-o09" 'SETUP_DEPS_KEEP_LIB=1' 'kept'
if cmp -s "$k42_exp" "$W1/proj2/remappings.txt"; then echo "  ok    and the remappings still point at the kit, not at the project's lib/"; else
  echo "  FAIL  remappings.txt differs"; fails=$((fails + 1)); fi
# repair: the local-model walk's shape - remappings into the project's lib/, a line of the owner's, libs = ["lib"], the restriction under lib/
W3="$W1/proj3"; mkdir -p "$W3/src"
printf '%s\n' 'v4-core/=lib/v4-core/' 'forge-std/=lib/v4-core/lib/forge-std/src/' 'mine/=src/' 'v4-core/=lib/v4-core/' > "$W3/remappings.txt"
printf '%s\n' '[profile.default]' 'src = "src"' 'libs = ["lib"]' 'optimizer_runs = 800' 'allow_paths = [' '  "../lib/hook-gauntlet/foundry-kit/src",' \
  '  "../elsewhere",' ']' 'compilation_restrictions = [' '  { paths = "lib/v4-core/src/PoolManager.sol", via_ir = true, optimizer_runs = 44444444 },' ']' \
  '' '[profile.pending]' 'test = "pending"' 'libs = ["lib"]' > "$W3/foundry.toml"
k42_run "$TMP/k42-o10" "$SD" "$W3"; check "setup-deps.sh repairs the local-model walk's shape (remappings into lib/, libs = [\"lib\"])" 0 $? "$TMP/k42-o10"
k42_has "each changed line is printed with what it was" "$TMP/k42-o10" \
  'setup-deps: remappings.txt: ~ v4-core/=../lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/   (was: v4-core/=lib/v4-core/)' \
  'setup-deps: remappings.txt: - v4-core/=lib/v4-core/   (a second v4-core/ line)' \
  'setup-deps: foundry.toml [profile.default]: ~ libs = []   (was: libs = ["lib"])' \
  'setup-deps: foundry.toml [profile.default]: ~ allow_paths = ["../elsewhere", "../lib/hook-gauntlet/foundry-kit"]' \
  'foundry.toml:15 [profile.pending]'
k42_has "the owner's lines stay" "$W3/remappings.txt" 'mine/=src/'
k42_has "and in foundry.toml" "$W3/foundry.toml" 'optimizer_runs = 800' 'src = "src"' '[profile.pending]' \
  '{ paths = "../lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/src/PoolManager.sol", via_ir = true, optimizer_runs = 44444444 },'
k42_not "and no restriction under the project's lib/ is left" "$W3/foundry.toml" '"lib/v4-core/src/PoolManager.sol"'
if [ "$(grep -c '^v4-core/=' "$W3/remappings.txt")" = 1 ] && [ "$(grep -c '^libs = ' "$W3/foundry.toml")" = 2 ]; then echo "  ok    one v4-core/ line; one libs per table"; else
  echo "  FAIL  duplicated lines"; fails=$((fails + 1)); fi
# a build that fails: rc 1, said
k42_run "$TMP/k42-o11" env K42_FORGE_RC=1 "$SD" "$W3"; check "setup-deps.sh: forge build fails after the files are written" 1 $? "$TMP/k42-o11"
k42_has "and it says so" "$TMP/k42-o11" 'setup-deps: forge build FAILED'
# remappings set in foundry.toml's default profile: refused (forge would read them before remappings.txt's)
W4="$W1/proj4"; mkdir -p "$W4"; printf '%s\n' '[profile.default]' 'remappings = ["v4-core/=lib/v4-core/"]' > "$W4/foundry.toml"
k42_run "$TMP/k42-o12" "$SD" "$W4"; check "setup-deps.sh: remappings in foundry.toml's [profile.default] are refused" 2 $? "$TMP/k42-o12"
k42_has "and it says why" "$TMP/k42-o12" 'remappings'
[ ! -e "$W4/remappings.txt" ] || { echo "  FAIL  and it wrote remappings.txt"; fails=$((fails + 1)); }
# the flat layout: the kit inside the project as lib/hook-gauntlet - no ../, no allow_paths
W5="$K42/w5"; k42_kit "$W5/lib/hook-gauntlet"; W5="$(cd "$W5" && pwd)"
k42_run "$TMP/k42-o13" "$SD" "$W5"; check "setup-deps.sh: the flat layout (the kit at the project's lib/hook-gauntlet)" 0 $? "$TMP/k42-o13"
k42_has "remappings through lib/hook-gauntlet" "$W5/remappings.txt" 'v4-core/=lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/' 'gauntlet-v4/=lib/hook-gauntlet/foundry-kit/v4/src/'
k42_not "and no allow_paths" "$W5/foundry.toml" 'allow_paths'
k42_not "and no ../ anywhere" "$W5/remappings.txt" '../'
# a project inside the kit, a project outside any kit's reach, a kit without Uniswap's sources, --kit
k42_run "$TMP/k42-o14" "$SD" "$W5/lib/hook-gauntlet/foundry-kit/v4"; check "setup-deps.sh: a project inside the kit itself is refused" 2 $? "$TMP/k42-o14"
mkdir -p "$K42/lone/proj"
k42_run "$TMP/k42-o15" "$SD" "$K42/lone/proj"; check "setup-deps.sh: no lib/hook-gauntlet in the project or above it is refused" 2 $? "$TMP/k42-o15"
k42_has "and it says the project is outside the kit's reach, and the way out" "$TMP/k42-o15" "outside the kit's reach" '--kit'
W6="$K42/w6"; k42_kit "$W6/lib/hook-gauntlet"; rm -rf "$W6/lib/hook-gauntlet/foundry-kit/v4/lib"; mkdir -p "$W6/proj"
k42_run "$TMP/k42-o16" "$SD" "$W6/proj"; check "setup-deps.sh: a kit whose foundry-kit/v4/lib is not installed is refused" 2 $? "$TMP/k42-o16"
k42_has "and it points at install-v4.sh" "$TMP/k42-o16" 'scripts/install-v4.sh'
[ ! -e "$W6/proj/remappings.txt" ] || { echo "  FAIL  and it wrote remappings.txt"; fails=$((fails + 1)); }
k42_run "$TMP/k42-o17" "$SD" --kit "$W1/lib/hook-gauntlet" "$K42/lone/proj"; check "setup-deps.sh --kit: a kit elsewhere, reached by ../" 0 $? "$TMP/k42-o17"
k42_has "remappings relative to the project, allow_paths for it" "$K42/lone/proj/remappings.txt" 'v4-core/=../../w1/lib/hook-gauntlet/foundry-kit/v4/lib/v4-core/'
k42_has "and allow_paths" "$K42/lone/proj/foundry.toml" 'allow_paths = ["../../w1/lib/hook-gauntlet/foundry-kit"]'

# install-skills.sh --harness hermes: HERMES_HOME and HOME temporary, never the machine's
KH="$K42/hermes-home"; KHP="$K42/hproj"; mkdir -p "$KHP"; KHP="$(cd "$KHP" && pwd)"; KKIT="$(cd "$HERE/.." && pwd)"
HOME="$K42/home" HERMES_HOME="$KH" "$HERE/install-skills.sh" --harness hermes --user --kit "$KKIT" --dry-run > "$TMP/k42-o20" 2>&1
check "install-skills.sh --harness hermes --user --dry-run" 0 $? "$TMP/k42-o20"
k42_has "into \$HERMES_HOME/skills, and the start line last" "$TMP/k42-o20" "would write $KH/skills/hook-gauntlet/SKILL.md" "dry-run: 9 skills into $KH/skills"
k42_last="$(tail -n 1 "$TMP/k42-o20")"
if grep -qF 'start Hermes with: hermes chat -s hook-gauntlet (the entry skill stays in the system prompt, which Hermes'"'"'s compression protects)' <<< "$k42_last"; then
  echo "  ok    its last line is the start line"; else echo "  FAIL  last line: $(tail -n 1 "$TMP/k42-o20")"; fails=$((fails + 1)); fi
[ ! -e "$KH" ] || { echo "  FAIL  and the dry run wrote $KH"; fails=$((fails + 1)); }
env -u HERMES_HOME HOME="$K42/home" "$HERE/install-skills.sh" --harness hermes --user --kit "$KKIT" --dry-run > "$TMP/k42-o21" 2>&1
check "install-skills.sh --harness hermes --user --dry-run, HERMES_HOME unset" 0 $? "$TMP/k42-o21"
k42_has "into ~/.hermes/skills" "$TMP/k42-o21" "would write $K42/home/.hermes/skills/hook-gauntlet/SKILL.md"
HOME="$K42/home" HERMES_HOME="$KH" "$HERE/install-skills.sh" --harness hermes --user > "$TMP/k42-o22" 2>&1
check "install-skills.sh --harness hermes --user with the default (relative) --kit is refused" 2 $? "$TMP/k42-o22"
k42_has "and it says why" "$TMP/k42-o22" '--user needs an absolute --kit'
HOME="$K42/home" HERMES_HOME="$KH" "$HERE/install-skills.sh" --harness hermes --project "$KHP" --dry-run > "$TMP/k42-o23" 2>&1
check "install-skills.sh --harness hermes --project --dry-run" 0 $? "$TMP/k42-o23"
k42_has "into the project's .agents/skills, with the two lines Hermes needs" "$TMP/k42-o23" "would write $KHP/.agents/skills/hook-gauntlet/SKILL.md" \
  'skills:' "  external_dirs: [$KHP/.agents/skills]" 'start Hermes with: hermes chat -s hook-gauntlet'
[ ! -e "$KHP/.agents" ] || { echo "  FAIL  and the dry run wrote $KHP/.agents"; fails=$((fails + 1)); }
HOME="$K42/home" HERMES_HOME="$KH" "$HERE/install-skills.sh" --harness hermes --project "$KHP" > "$TMP/k42-o24" 2>&1
check "install-skills.sh --harness hermes --project" 0 $? "$TMP/k42-o24"
k42_has "the external_dirs lines printed after the install" "$TMP/k42-o24" "installed: 9 skills into $KHP/.agents/skills" "  external_dirs: [$KHP/.agents/skills]"
if [ "$(find "$KHP/.agents/skills" -name SKILL.md | wc -l | tr -d ' ')" = 9 ] && [ ! -e "$KH" ] && [ ! -e "$K42/home/.hermes" ]; then
  echo "  ok    nine skills in the project, nothing in any Hermes home"; else echo "  FAIL  the install wrote elsewhere"; fails=$((fails + 1)); fi
k42_last="$(tail -n 1 "$TMP/k42-o24")"
if grep -qF 'start Hermes with: hermes chat -s hook-gauntlet' <<< "$k42_last"; then echo "  ok    and its last line is the start line"; else
  echo "  FAIL  last line: $(tail -n 1 "$TMP/k42-o24")"; fails=$((fails + 1)); fi
# --- K51 ---
# ================================================================= the import lines and [profile.pending] (setup-deps.sh);
# the harness's permission-bits refusal names the act; the kit's MANIFEST (gen-manifest.sh, doctor.sh's kit line).
# Measured before (v0.4.1): a model spent 83 of 112 minutes guessing the import line, which the examples (relative to
# the kit) never show; a run read the harness's bits refusal and bypassed it instead of recording it; a test file was
# written inside the vendored kit and nothing in the kit noticed. No forge needed: the stub forge and the fake kit of
# the K42/K43 cases above, and a fake kit of its own for the MANIFEST.
echo "== setup-deps.sh's import lines and [profile.pending]; the harness's refusal; the kit's MANIFEST (K51) =="
k51_exp="$TMP/k51-imports"
printf '%s\n' 'import {V4Harness} from "gauntlet-v4/V4Harness.sol";' 'import {MinimalRouter} from "gauntlet-v4/MinimalRouter.sol";' \
  'import {LiquidityHelper} from "gauntlet-v4/LiquidityHelper.sol";' 'import {HookMiner} from "gauntlet-v4/HookMiner.sol";' \
  'import {HostileERC20} from "gauntlet-kit/HostileERC20.sol";' \
  "The kit's own examples import these relative to the kit (../../src/...): do not copy their import lines." > "$k51_exp"
k51_ends() { # k51_ends <label> <file>: the file's last six lines are the six lines, verbatim
  if tail -n 6 "$2" | cmp -s "$k51_exp" -; then echo "  ok    $1"; else
    echo "  FAIL  $1: its last six lines are not the import lines:"; tail -n 8 "$2" | sed "s/^/        | /"; fails=$((fails + 1)); fi
}
k51_in() { # k51_in <file>: the six lines are in the file, one after the other, leading whitespace aside
  LC_ALL=C awk 'NR == FNR { w[++n] = $0; next }
    { sub(/^[ \t]+/, ""); if ($0 == w[i + 1]) { i++; if (i == n) { f = 1; exit } } else i = ($0 == w[1]) }
    END { exit !f }' "$k51_exp" "$1"
}
# the block as setup-deps.sh holds it (scripts/gen-skills.sh reads it from there for the entry skill's step 2)
LC_ALL=C awk "/^  cat <<'IMPORTS'\$/ { on = 1; next } /^IMPORTS\$/ { on = 0 } on" "$SD" > "$TMP/k51-block"
if cmp -s "$k51_exp" "$TMP/k51-block"; then echo "  ok    setup-deps.sh holds the six lines (five imports, then the sentence about the examples), verbatim"; else
  echo "  FAIL  setup-deps.sh's import block is not the six lines:"; diff "$k51_exp" "$TMP/k51-block" | sed "s/^/        | /"; fails=$((fails + 1)); fi
# each import names, through the remapping setup-deps.sh writes for it, a file of the kit that declares the symbol
k51_bad="" k51_n=0
while IFS= read -r l; do
  case "$l" in import*) ;; *) continue ;; esac
  if [[ $l =~ ^import\ \{([A-Za-z0-9_]+)\}\ from\ \"(gauntlet-v4|gauntlet-kit)/([A-Za-z0-9_]+\.sol)\"\;$ ]]; then
    k51_sym="${BASH_REMATCH[1]}"; k51_f="${BASH_REMATCH[3]}"
    if [ "${BASH_REMATCH[2]}" = gauntlet-v4 ]; then k51_f="$HERE/../foundry-kit/v4/src/$k51_f"; else k51_f="$HERE/../foundry-kit/src/$k51_f"; fi
    if [ -f "$k51_f" ] && grep -qE "^(abstract )?(contract|library|interface) $k51_sym( |\{|$)" "$k51_f"; then k51_n=$((k51_n + 1)); else k51_bad="$k51_bad [$l]"; fi
  else k51_bad="$k51_bad [$l]"; fi
done < "$k51_exp"
if [ -z "$k51_bad" ] && [ "$k51_n" = 5 ] && grep -qxF 'gauntlet-v4/=../lib/hook-gauntlet/foundry-kit/v4/src/' "$W1/proj/remappings.txt" \
  && grep -qxF 'gauntlet-kit/=../lib/hook-gauntlet/foundry-kit/src/' "$W1/proj/remappings.txt"; then
  echo "  ok    each of the five imports names a file of the kit that declares it, through the gauntlet-v4/ and gauntlet-kit/ lines setup-deps.sh writes"; else
  echo "  FAIL  an import line names no such file or symbol of the kit (or the remapping is not written):${k51_bad:- ($k51_n of 5 resolved)}"; fails=$((fails + 1)); fi
# a project from nothing: the six lines last, and [profile.pending] with test = "pending" and nothing else
W51="$K42/w51"; k42_kit "$W51/lib/hook-gauntlet"; mkdir -p "$W51/proj/src" "$W51/proj2/src" "$W51/proj3/src"; W51="$(cd "$W51" && pwd)"
k42_run "$TMP/k51-o01" "$SD" "$W51/proj"; check "setup-deps.sh: a new project, the build green" 0 $? "$TMP/k51-o01"
k51_ends "its output ends with the six lines, verbatim" "$TMP/k51-o01"
k42_has "and it says it wrote [profile.pending], for row 6b's command" "$TMP/k51-o01" \
  'setup-deps: foundry.toml: + [profile.pending] test = "pending"' "FOUNDRY_PROFILE=pending forge test --match-path 'pending/*'"
k51_pend() { LC_ALL=C awk '/^[ \t]*\[/ { on = ($0 ~ /^[ \t]*\[[ \t]*profile[ \t]*\.[ \t]*pending[ \t]*\]/); if (on) h++; next } on && NF { print } END { print "headers " h }' "$1"; }
if [ "$(k51_pend "$W51/proj/foundry.toml" | tr '\n' '|')" = 'test = "pending"|headers 1|' ]; then
  echo "  ok    foundry.toml has one [profile.pending], and in it only test = \"pending\" (the rest inherited from [profile.default])"; else
  echo "  FAIL  foundry.toml's [profile.pending]: $(k51_pend "$W51/proj/foundry.toml" | tr '\n' '|')"; fails=$((fails + 1)); fi
k51_h1="$(hash_of "$W51/proj/foundry.toml")"
k42_run "$TMP/k51-o02" "$SD" "$W51/proj"; check "setup-deps.sh again on it" 0 $? "$TMP/k51-o02"
k42_has "it says [profile.pending] is there and leaves it" "$TMP/k51-o02" 'setup-deps: foundry.toml: [profile.pending] is there - left as it is'
[ "$(hash_of "$W51/proj/foundry.toml")" = "$k51_h1" ] && echo "  ok    and foundry.toml is unchanged, byte for byte" \
  || { echo "  FAIL  and foundry.toml changed"; fails=$((fails + 1)); }
k51_ends "and ends with the six lines again" "$TMP/k51-o02"
# the owner's own [profile.pending] (other keys in it): kept as it is, said
printf '%s\n' '[profile.default]' 'src = "src"' '' '[profile.pending]' 'test = "pending"' 'fuzz = { runs = 7 }' > "$W51/proj2/foundry.toml"
k42_run "$TMP/k51-o03" "$SD" "$W51/proj2"; check "setup-deps.sh: a project with a [profile.pending] of its own" 0 $? "$TMP/k51-o03"
if [ "$(k51_pend "$W51/proj2/foundry.toml" | tr '\n' '|')" = 'test = "pending"|fuzz = { runs = 7 }|headers 1|' ]; then
  echo "  ok    its [profile.pending] is kept as it was (test, and its fuzz line), and no second one is written"; else
  echo "  FAIL  its [profile.pending]: $(k51_pend "$W51/proj2/foundry.toml" | tr '\n' '|')"; fails=$((fails + 1)); fi
k42_has "and it says so" "$TMP/k51-o03" 'setup-deps: foundry.toml: [profile.pending] is there - left as it is'
# --check: a project set up before [profile.pending] existed is not set up; --check never prints the import lines
LC_ALL=C awk '/^\[profile\.pending\]$/ { skip = 1; next } /^\[/ { skip = 0 } !skip' "$W51/proj/foundry.toml" > "$TMP/k51-f" && cp "$TMP/k51-f" "$W51/proj/foundry.toml"
k42_run "$TMP/k51-o04" "$SD" --check "$W51/proj"; check "setup-deps.sh --check on a project set up but with no [profile.pending]: not set up" 1 $? "$TMP/k51-o04"
k42_not "and --check does not print the import lines" "$TMP/k51-o04" 'gauntlet-v4/V4Harness.sol'
# --dry-run: says it would write [profile.pending], ends with the six lines, writes nothing
k42_run "$TMP/k51-o05" "$SD" --dry-run "$W51/proj3"; check "setup-deps.sh --dry-run on a new project" 0 $? "$TMP/k51-o05"
k42_has "it prints the [profile.pending] it would write" "$TMP/k51-o05" 'setup-deps: dry-run - foundry.toml: + [profile.pending] test = "pending"'
k51_ends "and ends with the six lines" "$TMP/k51-o05"
[ "$(find "$W51/proj3" -type f | wc -l | tr -d ' ')" = 0 ] || { echo "  FAIL  and the dry run wrote: $(find "$W51/proj3" -type f | tr '\n' ' ')"; fails=$((fails + 1)); }
# a build that fails: the six lines last too (the next thing read is forge's error, then them)
k42_run "$TMP/k51-o06" env K42_FORGE_RC=1 "$SD" "$W51/proj3"; check "setup-deps.sh: the build fails" 1 $? "$TMP/k51-o06"
k51_ends "and the output still ends with the six lines" "$TMP/k51-o06"
# the same block where a model looks: QUICKSTART 7b (where it names gauntlet-v4/) and the entry skill
sed -n '/^## 7b\./,/^## 8\./p' "$HERE/../QUICKSTART.md" > "$TMP/k51-7b"
if k51_in "$TMP/k51-7b" && grep -qF 'gauntlet-v4/=<kit>/foundry-kit/v4/src/' "$TMP/k51-7b"; then echo "  ok    QUICKSTART.md step 7b has the six lines, beside the gauntlet-v4/ remapping it names"; else
  echo "  FAIL  QUICKSTART.md step 7b does not have the six lines, in order"; fails=$((fails + 1)); fi
if k51_in "$HERE/../skills/hook-gauntlet/SKILL.md"; then echo "  ok    the entry skill (skills/hook-gauntlet/SKILL.md) has the six lines, in order"; else
  echo "  FAIL  the entry skill does not have the six lines, in order"; fails=$((fails + 1)); fi
# each of the kit's tests that imports the kit relatively says so in one header line - every .sol file under its test
# directories, the examples and the module's own tests, fork/ and test-periphery/ (K53: V50 found ForkExamples and
# PeripheryExamples without it, and the CHANGELOG saying each example had it)
K51_HDR="// Inside the kit: imports are relative. In your project: see scripts/setup-deps.sh's import lines."
k51_miss="" k51_n=0
for f in $(find "$HERE/../foundry-kit/test" "$HERE/../foundry-kit/v4/test" "$HERE/../foundry-kit/v4/test-periphery" -name '*.sol' | LC_ALL=C sort); do
  grep -qE '^import .*"\.\./' "$f" || continue; k51_n=$((k51_n + 1))
  grep -qxF "$K51_HDR" "$f" || k51_miss="$k51_miss ${f#"$HERE"/../}"
done
if [ -z "$k51_miss" ] && [ "$k51_n" -ge 51 ]; then echo "  ok    the $k51_n test files that import the kit relatively (foundry-kit/test/, foundry-kit/v4/test/, foundry-kit/v4/test-periphery/) carry the header line"; else
  echo "  FAIL  test files without the header line ($k51_n read):${k51_miss:- none - but fewer than 51 read}"; fails=$((fails + 1)); fi
# the harness's permission-bits refusal names the act (the whole line is held by test/HookPermissions.t.sol, v4 battery)
K51_V4H="$HERE/../foundry-kit/v4/src/V4Harness.sol"
k42_has "V4Harness's bits refusal: a finding, not a fix - in its order: the pending test (its setUp sets the flag, a test function of its own calls the check directly, no vm.expectRevert), pending-red.sh, STATE.md, then the flag in the suites, then the battery (v0.4.2, K61, K62)" "$K51_V4H" \
  ' - the manager never calls it. This is a finding, not a fix (doctrine/NEXT.md row 6b). In this order: write its test as' \
  ' pending/<id>.t.sol - its own setUp sets _skipPermissionCheck = true, then a test function of its own calls' \
  ' _checkHookPermissions(address(hook)) directly (V4Harness: function _checkHookPermissions(address hook) internal), with' \
  ' no vm.expectRevert, so this revert fails that test - record that red with scripts/pending-red.sh <proj> pending/<id>.t.sol, count it' \
  ' in STATE.md; then put _skipPermissionCheck = true and a header line // _skipPermissionCheck: <id> open in the suites' \
  ' that deploy the hook; then the battery, which holds them to that red record, current while src/ and pending/<id>.t.sol are as recorded (doctrine/EVIDENCE.md section 2).'
k42_not "and the old endings are gone (the K46 one; the first v0.4.1 one, which said the flag belonged to that test alone)" "$K51_V4H" 'That is a finding (the owner decides its fix' 'only inside that pending test'
k42_not "... and v0.4.1's, which kept the flag to pending tests (round 4: the everyday suite could not go green)" "$K51_V4H" 'only in pending tests'
# ---- the MANIFEST: a fake kit of its own (lib/, cache/, out/ at depth, the selftest marker, scripts/lib/)
MK="$TMP/k51-kit"; mkdir -p "$MK/scripts/lib" "$MK/doctrine" "$MK/foundry-kit/lib/forge-std" "$MK/foundry-kit/v4/lib/v4-core/src" \
  "$MK/foundry-kit/cache" "$MK/foundry-kit/v4/out/X.sol" "$MK/.gauntlet" "$MK/foundry-kit/v4/test/examples"
cp "$HERE/gen-manifest.sh" "$HERE/doctor.sh" "$MK/scripts/" 2> /dev/null; cp "$HERE/lib/parse.sh" "$MK/scripts/lib/"
echo a > "$MK/doctrine/NEXT.md"; echo b > "$MK/foundry-kit/v4/test/examples/E.t.sol"; echo c > "$MK/foundry-kit/lib/forge-std/x"
echo d > "$MK/foundry-kit/v4/lib/v4-core/src/PoolManager.sol"; echo e > "$MK/foundry-kit/cache/c"; echo f > "$MK/foundry-kit/v4/out/X.sol/X.json"
echo g > "$MK/.gauntlet/selftest-passed"
"$MK/scripts/gen-manifest.sh" > "$TMP/k51-o10" 2>&1; check "gen-manifest.sh on a kit (not a git checkout)" 0 $? "$TMP/k51-o10"
printf '%s\n' doctrine/NEXT.md foundry-kit/v4/test/examples/E.t.sol scripts/doctor.sh scripts/gen-manifest.sh scripts/lib/parse.sh > "$TMP/k51-paths"
if [ -f "$MK/MANIFEST" ] && cut -c67- "$MK/MANIFEST" | cmp -s "$TMP/k51-paths" - && ! grep -qvE '^[0-9a-f]{64}  [^ ]' "$MK/MANIFEST" \
  && grep -qxF "$(hash_of "$MK/doctrine/NEXT.md")  doctrine/NEXT.md" "$MK/MANIFEST"; then
  echo "  ok    MANIFEST: sha256sum's format, sorted, every file but itself, the selftest marker and lib/, cache/, out/ (scripts/lib/ kept: source)"; else
  echo "  FAIL  MANIFEST is not that:"; sed "s/^/        | /" "$MK/MANIFEST" 2> /dev/null | head -12; fails=$((fails + 1)); fi
"$MK/scripts/gen-manifest.sh" --check > "$TMP/k51-o11" 2>&1; check "gen-manifest.sh --check on the kit it just listed" 0 $? "$TMP/k51-o11"
echo x >> "$MK/doctrine/NEXT.md"
"$MK/scripts/gen-manifest.sh" --check > "$TMP/k51-o12" 2>&1; check "gen-manifest.sh --check: a listed file changed - stale" 1 $? "$TMP/k51-o12"
k42_has "and it names the file" "$TMP/k51-o12" 'doctrine/NEXT.md'
echo a > "$MK/doctrine/NEXT.md"; mv "$MK/foundry-kit/v4/test/examples/E.t.sol" "$TMP/k51-E"
"$MK/scripts/gen-manifest.sh" --check > "$TMP/k51-o13" 2>&1; check "gen-manifest.sh --check: a listed file missing - stale" 1 $? "$TMP/k51-o13"
k42_has "and it names the file" "$TMP/k51-o13" 'foundry-kit/v4/test/examples/E.t.sol'
mv "$TMP/k51-E" "$MK/foundry-kit/v4/test/examples/E.t.sol"
# doctor.sh's kit line: the shape measured on 2026-10-01 - a test file written under the kit's examples from a cd that drifted
"$BASH" "$MK/scripts/doctor.sh" > "$TMP/k51-o14" 2>&1
if grep -q "^kit: " "$TMP/k51-o14"; then echo "  FAIL  doctor.sh: a kit line with every file in MANIFEST: $(grep "^kit: " "$TMP/k51-o14")"; fails=$((fails + 1)); else echo "  ok    doctor.sh: no kit line when every file is in MANIFEST (lib/, cache/, out/, the marker not counted)"; fi
mkdir -p "$MK/foundry-kit/v4/test/examples/proj/test"; echo h > "$MK/foundry-kit/v4/test/examples/proj/test/VolumeRewardsHook.t.sol"
"$BASH" "$MK/scripts/doctor.sh" > "$TMP/k51-o15" 2>&1
if grep -qxF 'kit: 1 files not in MANIFEST: foundry-kit/v4/test/examples/proj/test/VolumeRewardsHook.t.sol' "$TMP/k51-o15"; then
  echo "  ok    doctor.sh names a file written inside the kit: kit: 1 files not in MANIFEST: <it>"; else
  echo "  FAIL  doctor.sh does not name it:"; grep '^kit' "$TMP/k51-o15" | sed "s/^/        | /"; fails=$((fails + 1)); fi
"$MK/scripts/gen-manifest.sh" --check > "$TMP/k51-o16" 2>&1; check "gen-manifest.sh --check outside a git checkout: a file not listed is named, not failed (doctor's line says it)" 0 $? "$TMP/k51-o16"
k42_has "and it names it" "$TMP/k51-o16" 'foundry-kit/v4/test/examples/proj/test/VolumeRewardsHook.t.sol'
echo i > "$MK/doctrine/Z1.md"; echo j > "$MK/doctrine/Z2.md"; echo k > "$MK/README.md"
"$BASH" "$MK/scripts/doctor.sh" > "$TMP/k51-o17" 2>&1
if [ "$(grep -c '^kit: ' "$TMP/k51-o17")" = 1 ] && grep -qE '^kit: 4 files not in MANIFEST: [^,]+, [^,]+, [^,]+$' "$TMP/k51-o17"; then
  echo "  ok    four such files: the count and the first three, one line"; else
  echo "  FAIL  four such files:"; grep '^kit' "$TMP/k51-o17" | sed "s/^/        | /"; fails=$((fails + 1)); fi
rm -f "$MK/doctrine/Z1.md" "$MK/doctrine/Z2.md" "$MK/README.md"; rm -rf "$MK/foundry-kit/v4/test/examples/proj"
mv "$MK/MANIFEST" "$TMP/k51-M"
"$BASH" "$MK/scripts/doctor.sh" > "$TMP/k51-o18" 2>&1
grep -qxF 'kit: no MANIFEST' "$TMP/k51-o18" && echo "  ok    doctor.sh with no MANIFEST: kit: no MANIFEST" \
  || { echo "  FAIL  doctor.sh with no MANIFEST:"; grep '^kit' "$TMP/k51-o18" | sed "s/^/        | /"; fails=$((fails + 1)); }
"$MK/scripts/gen-manifest.sh" --check > "$TMP/k51-o19" 2>&1; check "gen-manifest.sh --check with no MANIFEST" 1 $? "$TMP/k51-o19"
mv "$TMP/k51-M" "$MK/MANIFEST"
# a git checkout: what git tracks and would add (not ignored); a file not listed fails --check there
if command -v git > /dev/null 2>&1; then
  printf 'ignored.hex\n' > "$MK/.gitignore"; echo l > "$MK/ignored.hex"
  (cd "$MK" && git init -q && git add -A && git -c user.name=selftest -c user.email=selftest@invalid -c commit.gpgsign=false commit -q -m k51) > /dev/null 2>&1
  "$MK/scripts/gen-manifest.sh" > "$TMP/k51-o20" 2>&1; check "gen-manifest.sh in a git checkout" 0 $? "$TMP/k51-o20"
  if grep -q '  \.gitignore$' "$MK/MANIFEST" && ! grep -q 'ignored\.hex' "$MK/MANIFEST" && ! grep -q '\.git/' "$MK/MANIFEST"; then
    echo "  ok    it lists what git tracks (.gitignore), not what git ignores (ignored.hex), nothing of .git/"; else
    echo "  FAIL  the git checkout's MANIFEST:"; sed "s/^/        | /" "$MK/MANIFEST" | head; fails=$((fails + 1)); fi
  echo m > "$MK/doctrine/NEW.md"
  "$MK/scripts/gen-manifest.sh" --check > "$TMP/k51-o21" 2>&1; check "gen-manifest.sh --check in a git checkout: a file git would add is not listed - stale" 1 $? "$TMP/k51-o21"
  k42_has "and it names it" "$TMP/k51-o21" 'doctrine/NEW.md'
  rm -f "$MK/doctrine/NEW.md"
fi
# the kit's own MANIFEST is current (the merge regenerates it: scripts/gen-manifest.sh)
"$HERE/gen-manifest.sh" --check > "$TMP/k51-o22" 2>&1; check "the kit's MANIFEST is current (scripts/gen-manifest.sh --check)" 0 $? "$TMP/k51-o22"
# --- end K51 ---

# --- K52 ---
# ================================================================= generated outputs are not intruders: the MANIFEST's
# exclusions - one rule in gen-manifest.sh, doctor.sh and next.sh - also leave out every corpus/, census/, broadcast/
# and .gauntlet/ directory under the kit (measured before: after the selftest and the kit's own batteries, doctor.sh
# said `kit: 152 files not in MANIFEST` - corpus/ and .gauntlet/reports/ - and next.sh's note told the walker to move
# the kit's own outputs out). A fake kit of its own; no forge.
echo "== the MANIFEST's exclusions: generated outputs are not intruders, one rule in three places (K52) =="
k52_rule() { LC_ALL=C awk '/^# THE EXCLUSIONS - one rule/ { on = 1 } on { print } on && /^KIT_SKIP_DIRS=/ { exit }' "$1"; }
k52_rule "$HERE/gen-manifest.sh" > "$TMP/k52-r1"; k52_rule "$HERE/doctor.sh" > "$TMP/k52-r2"; k52_rule "$HERE/next.sh" > "$TMP/k52-r3"
if [ -s "$TMP/k52-r1" ] && cmp -s "$TMP/k52-r1" "$TMP/k52-r2" && cmp -s "$TMP/k52-r1" "$TMP/k52-r3" \
  && grep -qxF 'KIT_SKIP_DIRS="lib cache out corpus census broadcast .gauntlet"' "$TMP/k52-r1" \
  && grep -qF 'scripts/gen-manifest.sh, scripts/doctor.sh and scripts/next.sh' "$TMP/k52-r1"; then
  echo "  ok    THE EXCLUSIONS: the same lines, word for word, in gen-manifest.sh, doctor.sh and next.sh (naming the three; lib cache out corpus census broadcast .gauntlet)"; else
  echo "  FAIL  THE EXCLUSIONS differ between gen-manifest.sh, doctor.sh and next.sh, or are not the decided list:"; diff "$TMP/k52-r1" "$TMP/k52-r2" | sed "s/^/        | /"; diff "$TMP/k52-r1" "$TMP/k52-r3" | sed "s/^/        | /"; fails=$((fails + 1)); fi
K52K="$TMP/k52-kit"; rm -rf "$K52K"; mkdir -p "$K52K/scripts/lib" "$K52K/doctrine" "$K52K/state" "$K52K/foundry-kit/v4/test/examples"
cp "$HERE"/*.sh "$HERE"/*.py "$K52K/scripts/"; cp "$HERE"/lib/*.sh "$HERE"/lib/*.py "$K52K/scripts/lib/"; cp "$NXT" "$K52K/doctrine/"; cp "$K8_EX" "$K52K/state/"
printf '// the kit\n' > "$K52K/foundry-kit/v4/test/examples/Ex.t.sol"
"$K52K/scripts/gen-manifest.sh" > "$TMP/k52-o01" 2>&1; check "gen-manifest.sh on a fake kit (not a git checkout)" 0 $? "$TMP/k52-o01"
# what the selftest and the batteries write, at depth: corpus/ (forge's invariant corpus), .gauntlet/reports/ and the
# marker, census/, broadcast/ - each at the root of the kit and under a module
for d in foundry-kit/corpus/T foundry-kit/v4/corpus/U/V .gauntlet/reports foundry-kit/v4/.gauntlet/reports foundry-kit/v4/.gauntlet/pending-red \
  census foundry-kit/v4/census broadcast/S.s.sol/1 foundry-kit/v4/broadcast/S.s.sol/31337; do mkdir -p "$K52K/$d"; printf 'out\n' > "$K52K/$d/f.txt"; done
printf 'marker\n' > "$K52K/.gauntlet/selftest-passed"
"$BASH" "$K52K/scripts/doctor.sh" > "$TMP/k52-o02" 2>&1
if grep -q '^kit: ' "$TMP/k52-o02"; then echo "  FAIL  doctor.sh counts generated outputs: $(grep '^kit: ' "$TMP/k52-o02")"; fails=$((fails + 1)); else
  echo "  ok    doctor.sh: no kit line with corpus/, census/, broadcast/ and .gauntlet/ written at the root and under a module"; fi
NEXT_SELFTEST=1 "$K52K/scripts/next.sh" "$FIX/state-new-project.md" > "$TMP/k52-o03" 2> /dev/null; check "next.sh in that kit: the row" 0 $? "$TMP/k52-o03"
grep -q '^next: note' "$TMP/k52-o03" && { echo "  FAIL  and next.sh's note counts generated outputs: $(grep '^next: note' "$TMP/k52-o03")"; fails=$((fails + 1)); } \
  || echo "  ok    and no note from next.sh: the same outputs not counted"
"$K52K/scripts/gen-manifest.sh" --check > "$TMP/k52-o04" 2>&1; check "gen-manifest.sh --check in that kit: current" 0 $? "$TMP/k52-o04"
grep -q 'note' "$TMP/k52-o04" && { echo "  FAIL  and it notes generated outputs:"; sed "s/^/        | /" "$TMP/k52-o04"; fails=$((fails + 1)); } || echo "  ok    and no note: the same rule"
# a file named like those directories is not one of them; a file written by a walker among them still is named
printf 'x\n' > "$K52K/foundry-kit/corpus.md"
mkdir -p "$K52K/foundry-kit/v4/test/examples/proj/test"; printf '// a walker whose cd drifted\n' > "$K52K/foundry-kit/v4/test/examples/proj/test/VolumeRewardsHook.t.sol"
"$BASH" "$K52K/scripts/doctor.sh" > "$TMP/k52-o05" 2>&1
grep -qxF 'kit: 2 files not in MANIFEST: foundry-kit/corpus.md, foundry-kit/v4/test/examples/proj/test/VolumeRewardsHook.t.sol' "$TMP/k52-o05" \
  && echo "  ok    doctor.sh names the intruder (and a FILE named corpus.md: only directories are left out)" \
  || { echo "  FAIL  doctor.sh does not name the two:"; grep '^kit' "$TMP/k52-o05" | sed "s/^/        | /"; fails=$((fails + 1)); }
NEXT_SELFTEST=1 "$K52K/scripts/next.sh" "$FIX/state-new-project.md" > "$TMP/k52-o06" 2> /dev/null; check "next.sh in that kit, the intruder in it: the row, the exit code unchanged" 0 $? "$TMP/k52-o06"
[ "$(tail -1 "$TMP/k52-o06")" = "next: note - the kit has 2 files not in its MANIFEST (foundry-kit/corpus.md, foundry-kit/v4/test/examples/proj/test/VolumeRewardsHook.t.sol): the kit is not to be changed; move them out" ] \
  && echo "  ok    and next.sh's note names the same two" || { echo "  FAIL  next.sh's note:"; tail -1 "$TMP/k52-o06" | sed "s/^/        | /"; fails=$((fails + 1)); }
"$K52K/scripts/gen-manifest.sh" --check > "$TMP/k52-o07" 2>&1; check "gen-manifest.sh --check: the two named as notes (not a git checkout)" 0 $? "$TMP/k52-o07"
k42_has "and it names both, and no generated output" "$TMP/k52-o07" 'foundry-kit/corpus.md' 'foundry-kit/v4/test/examples/proj/test/VolumeRewardsHook.t.sol'
grep -q 'f\.txt' "$TMP/k52-o07" && { echo "  FAIL  and it names a generated output"; fails=$((fails + 1)); }
# --- end K52 ---

# --- K53 ---
# What a walk from nothing met (V50): the refusal of a project with no state named state/README.md, not the command,
# and the route's own words (AGENTS.md 4, so the entry skill's step 4; QUICKSTART 5) still installed the state by hand,
# which records no spec. And the owner's re-record of the spec left nothing written (K54: it is now signed, --by).
echo "== the route from nothing: the no-state refusal names init-state.sh, the route's words run it first; the owner's signed re-record leaves a line (K53, K54) =="
K53="$TMP/k53"; rm -rf "$K53"; mkdir -p "$K53"
# ---- a project with no state: the refusal names the command, absolute, from a relative <proj>; that command, then the row
K53W="$K53/w"; k5_proj "$K53W"; K53WA="$(cd "$K53W" && pwd)"
K53_NONE="next: REFUSED - $K53WA has no .gauntlet/STATE.md and no STATE.md: $KX_KIT/scripts/init-state.sh $K53WA writes one (or give the STATE.md)"
(cd "$K53" && nx "$NX" w) > "$TMP/k53-o01" 2>&1; check "next.sh w (a relative <proj>, no state): refused" 2 $? "$TMP/k53-o01"
if [ "$(cat "$TMP/k53-o01")" = "$K53_NONE" ]; then echo "  ok    one line, the project and the command absolute: ${K53_NONE:0:150}"; else
  echo "  FAIL  not the one line '${K53_NONE:0:150}':"; sed "s/^/        | /" "$TMP/k53-o01"; fails=$((fails + 1)); fi
k53_cmd="$(sed -n 's/^next: REFUSED - .* has no \.gauntlet\/STATE\.md and no STATE\.md: \(.*\) writes one (or give the STATE\.md)$/\1/p' "$TMP/k53-o01")"
if [ "$k53_cmd" = "$K5_IS $K53WA" ]; then echo "  ok    the command it names is this kit's init-state.sh on that project"; else
  echo "  FAIL  the command it names is not '$K5_IS $K53WA': '$k53_cmd'"; fails=$((fails + 1)); fi
"$K5_IS" "$K53WA" > "$TMP/k53-o02" 2>&1; check "... that command, as named: the state written, the spec recorded" 0 $? "$TMP/k53-o02"
k42_has "... and it says so" "$TMP/k53-o02" "init-state: wrote $K53WA/.gauntlet/STATE.md" "init-state: recorded the spec: $K53WA/.gauntlet/spec.sha256"
(cd "$K53" && nx "$NX" w) > "$TMP/k53-o03" 2>&1; check "next.sh w, straight after: the row - one command from the refusal" 0 $? "$TMP/k53-o03"
grep -q '^next: row 4 - ' "$TMP/k53-o03" || { echo "  FAIL  and it did not give row 4:"; sed "s/^/        | /" "$TMP/k53-o03"; fails=$((fails + 1)); }
# ---- the owner's SIGNED re-record (K54, D1b: unsigned it is refused - the K50 cases): one line in LOG.md, its own
# paragraph, the old and new hashes' first 8 hex and the name; said on stdout
k53_log0="$(cat "$K53W/.gauntlet/LOG.md")"; k53_old="$(head -n 1 "$K53W/.gauntlet/spec.sha256" | cut -c1-8)"; cp "$K53W/.gauntlet/STATE.md" "$TMP/k53-state"
printf '\n## Decided by the owner\n\n1. The fee is 0.3 percent.\n' >> "$K53W/SPEC.md"; k53_new="$(k5_sha "$K53W/SPEC.md" | cut -c1-8)"
k53_signed() { printf '%s spec re-recorded: SPEC.md %s -> %s, signed --by "Selftest" (init-state --spec --by: the kit cannot tell whose hands these were; the owner reads this line, and the dossier carries it)' "$(date +%F)" "$1" "$2"; }
k53_note() { printf 'next: note - the spec SPEC.md was re-recorded on %s, signed --by "Selftest" (%s -> %s; .gauntlet/spec.sha256): the owner confirms that signature is theirs, or the spec in force is not the owner'"'"'s' "$(date +%F)" "$1" "$2"; }
"$K5_IS" --spec SPEC.md --by Selftest "$K53W" > "$TMP/k53-o04" 2>&1; check "init-state.sh --spec SPEC.md --by Selftest <proj> on a project with a STATE.md (the owner's signed re-record)" 0 $? "$TMP/k53-o04"
K53_LINE="$(k53_signed "$k53_old" "$k53_new")"
if [ "$(tail -n 1 "$K53W/.gauntlet/LOG.md")" = "$K53_LINE" ]; then echo "  ok    LOG.md ends with '${K53_LINE:0:150}'"; else
  echo "  FAIL  LOG.md does not end with '$K53_LINE':"; tail -n 3 "$K53W/.gauntlet/LOG.md" | sed "s/^/        | /"; fails=$((fails + 1)); fi
if [ "$(printf '%s\n\n%s' "$k53_log0" "$K53_LINE")" = "$(cat "$K53W/.gauntlet/LOG.md")" ]; then echo "  ok    one line appended, its own paragraph; the rest of LOG.md as it was"; else
  echo "  FAIL  LOG.md is not what it was plus a blank line and that line"; fails=$((fails + 1)); fi
k42_has "... said on stdout, with both hashes" "$TMP/k53-o04" "init-state: appended to $(cd "$K53W" && pwd)/.gauntlet/LOG.md: $K53_LINE" "spec.sha256 now: $(k5_sha "$K53W/SPEC.md")  SPEC.md"
cmp -s "$K53W/.gauntlet/STATE.md" "$TMP/k53-state" && echo "  ok    STATE.md untouched" || { echo "  FAIL  STATE.md touched"; fails=$((fails + 1)); }
(cd "$K53" && nx "$NX" w) > "$TMP/k53-o05" 2>&1; check "next.sh after the re-record: the row (the trace does not stop the route)" 0 $? "$TMP/k53-o05"
grep -qxF "$(k53_note "$k53_old" "$k53_new")" "$TMP/k53-o05" && echo "  ok    ... with the signed note under it" \
  || { echo "  FAIL  no signed note under the row:"; sed "s/^/        | /" "$TMP/k53-o05"; fails=$((fails + 1)); }
# no record before (a project set up by hand): `none`, in LOG.md, in spec.sha256's line 2 and in next.sh's note
rm -f "$K53W/.gauntlet/spec.sha256"
"$K5_IS" --spec SPEC.md --by Selftest "$K53W" > "$TMP/k53-o06" 2>&1; check "init-state.sh --spec --by with no record before" 0 $? "$TMP/k53-o06"
[ "$(tail -n 1 "$K53W/.gauntlet/LOG.md")" = "$(k53_signed none "$k53_new")" ] && [ "$(sed -n 2p "$K53W/.gauntlet/spec.sha256")" = "re-recorded $(date +%F) by \"Selftest\" none -> $k53_new" ] \
  && echo "  ok    'none -> $k53_new' in LOG.md and in spec.sha256's line 2" || { echo "  FAIL  not 'none -> $k53_new':"; tail -n 1 "$K53W/.gauntlet/LOG.md" | sed "s/^/        | /"; sed "s/^/        | /" "$K53W/.gauntlet/spec.sha256"; fails=$((fails + 1)); }
(cd "$K53" && nx "$NX" w) > "$TMP/k53-o06b" 2>&1; check "next.sh after a re-record with no record before: the row" 0 $? "$TMP/k53-o06b"
grep -qxF "$(k53_note none "$k53_new")" "$TMP/k53-o06b" && echo "  ok    ... with the note, 'none -> $k53_new'" \
  || { echo "  FAIL  no note for a 'none ->' re-record:"; sed "s/^/        | /" "$TMP/k53-o06b"; fails=$((fails + 1)); }
# location: root - the LOG.md beside the STATE.md, at the root; none written in .gauntlet/
K53R="$K53/r"; k5_proj "$K53R"; cp "$FIX/state-new-project.md" "$K53R/STATE.md"; printf '# LOG - r\n\n## an entry\n' > "$K53R/LOG.md"
"$K5_IS" --spec SPEC.md --by Selftest "$K53R" > "$TMP/k53-o07" 2>&1; check "init-state.sh --spec --by on a project at its root (location: root)" 0 $? "$TMP/k53-o07"
[ "$(tail -n 1 "$K53R/LOG.md")" = "$(k53_signed none "$(k5_sha "$K53R/SPEC.md" | cut -c1-8)")" ] && [ ! -e "$K53R/.gauntlet/LOG.md" ] \
  && echo "  ok    the line in the root's LOG.md, beside its STATE.md; no .gauntlet/LOG.md" || { echo "  FAIL  not in the root's LOG.md, or a .gauntlet/LOG.md written"; fails=$((fails + 1)); }
# ---- the route's words: init-state.sh first, the hand copy only as the fallback that records no spec
k53_first() { # k53_first <label> <file> <section start regex> <section end regex>: init-state.sh named before the hand copy
  local s; s="$(sed -n "/$3/,/$4/p" "$2" | tr '\n' ' ')"
  case "$s" in *init-state.sh*records\ no\ spec*) ;; *) echo "  FAIL  $1: no init-state.sh, or no 'records no spec'"; fails=$((fails + 1)); return ;; esac
  local k53_a="${s%%init-state.sh*}" k53_b="${s%%copy the three files*}"
  [ "$k53_b" = "$s" ] && k53_b="${s%%copy \`<kit>/state/STATE.md\`*}"
  if [ "${#k53_a}" -lt "${#k53_b}" ]; then echo "  ok    $1: init-state.sh first, the hand copy a fallback that records no spec"; else
    echo "  FAIL  $1: the hand copy comes before init-state.sh"; fails=$((fails + 1)); fi
}
k53_first "AGENTS.md section 4" "$HERE/../AGENTS.md" '^## 4\. ' '^## 5\. '
k53_first "QUICKSTART.md step 5" "$HERE/../QUICKSTART.md" '^## 5\. ' '^## 6\. '
k53_first "the entry skill's step 4 (generated from AGENTS.md 4)" "$HERE/../skills/hook-gauntlet/SKILL.md" '^4\. \*\*A new project' '^5\. '
grep -q '^4\. \*\*A new project\.\*\* .*`{{KIT}}/scripts/init-state\.sh <proj>`' "$HERE/../skills/hook-gauntlet/SKILL.md" \
  && echo "  ok    the entry skill's step 4 names {{KIT}}/scripts/init-state.sh <proj>" || { echo "  FAIL  the entry skill's step 4 does not name {{KIT}}/scripts/init-state.sh <proj>"; fails=$((fails + 1)); }
# --- end K53 ---

# --- K60 ---
# ================================================================= v0.4.2 (K60): what round 4 showed - the flags against
# their records, the escapes out of the refusals, src/ anchored like the spec, _skipPermissionCheck under test/ and the
# battery, setup-deps.sh's fuzz configuration and COPY_ROOT, the marker by mktemp, the texts
echo "== v0.4.2 (K60): flags against records, escapes written down, the src/ anchor, the bits rule, setup-deps's fuzz configuration =="
K6="$TMP/k60"; rm -rf "$K6"; mkdir -p "$K6"; K6_IS="$HERE/init-state.sh"
# shellcheck source=lib/src-anchor.sh
. "$HERE/lib/src-anchor.sh" || { echo "selftest: $HERE/lib/src-anchor.sh is missing"; exit 1; }
k6_not() { # k6_not <file> <label> <fixed string>: the string is in no line of the file
  if grep -qF -- "$3" "$1"; then echo "  FAIL  $2: '$3' in:"; grep -nF -- "$3" "$1" | sed "s/^/        | /" | head -3; fails=$((fails + 1)); else echo "  ok    $2"; fi
}
# ---- the flags against their records (next.sh; the judge's phase walk of round 4: battery: green typed over a battery that
# had FAILED, phase 4 with no invariant suite, no census and no fork note - each was answered with a row)
F6="$K6/f"; kx_proj "$F6"; F6A="$(cd "$F6" && pwd)"; mkdir -p "$F6/.gauntlet/reports"; cp "$FIX/build-real-compiled.txt" "$F6/.gauntlet/reports/01-build.txt"
k6_state() { # k6_state <phase> <battery> [<notes>]: the new project's STATE.md with those values
  sed -E "s/^phase: .*/phase:                     $1/; s/^battery: .*/battery:                   $2/" "$FIX/state-new-project.md" > "$F6/.gauntlet/STATE.md"
  [ -z "${3:-}" ] || sed -i -E "s|^notes:.*|notes:                     $3|" "$F6/.gauntlet/STATE.md"
}
K6_BAT="$KX_KIT/scripts/battery.sh $F6A"
k6_state 2 green
kx_one 6001 "next.sh refuses battery: green with no test record (02-test.txt)" 2 \
  "next: REFUSED - battery is green and there is no test record (.gauntlet/reports/02-test.txt): $K6_BAT, then write the battery flag its verdict gives" "$F6"
cp "$FIX/summary-real-failed-and-skipped.txt" "$F6/.gauntlet/reports/02-test.txt"
kx_one 6002 "next.sh refuses battery: green over a test record with a FAILED test" 2 \
  "next: REFUSED - battery is green and its test record (.gauntlet/reports/02-test.txt) says 1 test(s) FAILED: $K6_BAT, then write the battery flag its verdict gives" "$F6"
cp "$FIX/summary-real-no-tests.txt" "$F6/.gauntlet/reports/02-test.txt"
kx_one 6003 "next.sh refuses battery: green over a test record where no test ran (the battery FAILED before its tests)" 2 \
  "next: REFUSED - battery is green and its test record (.gauntlet/reports/02-test.txt) has no summary of forge's: no test ran: $K6_BAT, then write the battery flag its verdict gives" "$F6"
PENDING_RED=0 CITED_FILES=0 nx "$NX" "$F6" > "$TMP/o6004" 2>&1; check "... and no escape turns it off" 2 $? "$TMP/o6004"
k6_state 2 red
kx_row 6005 "next.sh: phase 2, battery: red, no test ran: the row (phase 2 open needs a green build record, not a battery that ran)" 4b "$F6"
k6_state 3 red
kx_one 6006 "next.sh refuses phase 3 when the test record shows no test ran (its green 01-build.txt is not a battery that ran)" 2 \
  "next: REFUSED - phase 3 claims phase 2 closed and the battery's test record (.gauntlet/reports/02-test.txt) shows no test ran - a battery that failed before its tests left only a build record: $K6_BAT, or write the phase that is open" "$F6"
cp "$FIX/summary-real-failed-and-skipped.txt" "$F6/.gauntlet/reports/02-test.txt"
kx_row 6007 "next.sh: phase 3, battery: red, a test record with a failed test: the row (phase 3 is row 4b's; the battery ran, and is red)" 4b "$F6" --judge 5=false
cp "$FIX/summary-real-many-suites.txt" "$F6/.gauntlet/reports/02-test.txt"; k6_state 3 green
kx_row 6008 "next.sh: phase 3, battery: green, a green test record: the row" 4b "$F6"
k6_state 4 green
kx_one 6009 "next.sh refuses phase 4 with no invariant suite under test/, naming QUICKSTART 7b and the battery" 2 \
  "next: REFUSED - phase 4 claims phase 3 closed and there is no invariant suite under $F6A/test (no .sol file with a function invariant...()): write it on the kit's InvariantBase (QUICKSTART.md 7b), then $K6_BAT - or write the phase that is open" "$F6"
mkdir -p "$F6/test"
printf 'contract I { function invariant_balance_covers_claims() public view {} }\n' > "$F6/test/I.t.sol"
K6_CEN="next: REFUSED - phase 4 claims phase 3 closed and there is no census report (.gauntlet/reports/06-census.txt or 06-census-gate.txt): $KX_KIT/scripts/census.sh $F6A - or write the phase that is open"
kx_one 6010 "next.sh refuses phase 4 with an invariant suite and no census report, naming census.sh" 2 "$K6_CEN" "$F6"
printf 'census: the campaign FAILED - no census (renamed x)\n' > "$F6/.gauntlet/reports/06-census.txt"
kx_one 6011 "... and with a FAILED campaign's census report" 2 "$K6_CEN" "$F6"
printf 'census gate: PASSED - 2 CORE actions\n' > "$F6/.gauntlet/reports/06-census.txt"
K6_FORK="next: REFUSED - phase 4 claims phase 3 closed and the fork question is unanswered: write the note 'fork: <what ran against what exists, or n/a - no chain, no manager yet>' in STATE.md notes (NEXT.md row 4b) - or write the phase that is open"
kx_one 6012 "next.sh refuses phase 4 with no fork: note" 2 "$K6_FORK" "$F6"
k6_state 4 green "the fork: question is open"
kx_one 6013 "... and with fork: inside a note, not at its start" 2 "$K6_FORK" "$F6"
k6_state 4 green "static triage: forge lint only; - fork: n/a - no chain, no manager yet"
# v0.5: and the independent threat model diffed (threat_model: not yet is refused here; the lists and the line, the row)
kx_one 6016 "next.sh refuses phase 4 with every record above and threat_model: not yet, naming the brief and threat-diff.sh" 2 \
  "next: REFUSED - phase 4 claims phase 3 closed and the independent threat model is not diffed (threat_model: not yet): a fresh agent writes $F6A/.gauntlet/THREATS-independent.md from $KX_KIT/briefs/threat-model.md, then $KX_KIT/scripts/threat-diff.sh $F6A - or write the phase that is open" "$F6"
cp "$FIX/threats-independent.md" "$F6/.gauntlet/THREATS-independent.md"; cp "$FIX/threats-walker.md" "$F6/.gauntlet/THREATS.md"
"$HERE/threat-diff.sh" "$F6" > /dev/null 2>&1   # (v0.5) the report, with the lists' sha256 next.sh reads a diffed line against
sed -i 's/^threat_model: .*/threat_model:              diffed (2 matched, 0 new, 0 refused, 0 handed)/' "$F6/.gauntlet/STATE.md"
kx_row 6014 "next.sh: phase 4 with the suite, the census and a fork: note (a list item after ;): the row" 6 "$F6" --judge 5=false
rm -f "$F6/.gauntlet/reports/06-census.txt"; printf 'census gate: PASSED\n' > "$F6/.gauntlet/reports/06-census-gate.txt"
kx_row 6015 "... the census gate's report (06-census-gate.txt) is a census report too" 6 "$F6" --judge 5=false
# ---- the escapes out of the refusal lines, written down when used (a walker read the escape in a refusal and used it)
E6="$K6/e"; kx_proj "$E6"; E6A="$(cd "$E6" && pwd)"; mkdir -p "$E6/pending"; printf '// F-1\n' > "$E6/pending/F-1.t.sol"
sed 's/^notes: .*/notes:                     pending: F-1 - a stranger takes a registered id, owner undecided/' "$FIX/state-new-project.md" > "$E6/.gauntlet/STATE.md"
printf '# LOG - SomeHook\n\nrules.\n' > "$E6/.gauntlet/LOG.md"
kx_one 6020 "next.sh refuses pending/F-1.t.sol with no red record - the line names pending-red.sh and no escape" 2 \
  "next: pending/F-1.t.sol - not seen red on the code as it stands: $KX_KIT/scripts/pending-red.sh $E6A pending/F-1.t.sol" "$E6"
PENDING_RED=0 nx "$NX" "$E6" > "$TMP/o6021" 2>&1; check "next.sh with PENDING_RED=0: the row" 0 $? "$TMP/o6021"
k5_has "$TMP/o6021" "... it says it was set, and that what it let through was written down" "next: PENDING_RED=0 - the tests in pending/ are NOT checked" \
  "next: PENDING_RED=0 let through pending/F-1.t.sol (not seen red on the code as it stands) - written down in $E6A/.gauntlet/LOG.md"
if [ "$(tail -n 1 "$E6/.gauntlet/LOG.md")" = "$(date +%F) next.sh ran with PENDING_RED=0, an escape: it let through pending/F-1.t.sol (not seen red on the code as it stands) - not checked here (the owner reads this line, and the dossier carries it)" ] \
  && [ "$(tail -n 2 "$E6/.gauntlet/LOG.md" | head -1)" = "" ]; then echo "  ok    LOG.md gained one paragraph: the date, the escape, the file and why"; else
  echo "  FAIL  LOG.md's end:"; tail -n 3 "$E6/.gauntlet/LOG.md" | sed "s/^/        | /"; fails=$((fails + 1)); fi
PENDING_RED=0 nx "$NX" "$E6" > /dev/null 2>&1
[ "$(grep -c 'next.sh ran with PENDING_RED=0' "$E6/.gauntlet/LOG.md")" = 2 ] && echo "  ok    every use is written down (a second run, a second line)" || { echo "  FAIL  $(grep -c 'next.sh ran with PENDING_RED=0' "$E6/.gauntlet/LOG.md") lines for two uses"; fails=$((fails + 1)); }
printf '# DECISIONS - SomeHook\n\nD-02: the test is `test/Missing.t.sol`.\n' > "$E6/.gauntlet/DECISIONS.md"
PENDING_RED=0 nx "$NX" "$E6" > "$TMP/o6022" 2>&1; check "next.sh refuses a citation of a file that does not exist" 2 $? "$TMP/o6022"
k6_not "$TMP/o6022" "... and the refusal names no escape" "CITED_FILES"
PENDING_RED=0 CITED_FILES=0 nx "$NX" "$E6" > "$TMP/o6023" 2>&1; check "next.sh with CITED_FILES=0 too: the row" 0 $? "$TMP/o6023"
k5_has "$E6/.gauntlet/LOG.md" "... and LOG.md names the citation it let through" \
  "next.sh ran with CITED_FILES=0, an escape: it let through test/Missing.t.sol (cited by DECISIONS.md line 3; it does not exist) - not checked here"
rm -rf "$E6/pending" "$E6/.gauntlet/DECISIONS.md"; sed 's/^notes: .*/notes:/' "$FIX/state-new-project.md" > "$E6/.gauntlet/STATE.md"; k6_n="$(wc -l < "$E6/.gauntlet/LOG.md")"
PENDING_RED=0 CITED_FILES=0 nx "$NX" "$E6" > "$TMP/o6024" 2>&1; check "next.sh with both escapes set and nothing to let through: the row" 0 $? "$TMP/o6024"
[ "$(wc -l < "$E6/.gauntlet/LOG.md")" = "$k6_n" ] && echo "  ok    and nothing is written down (the stderr line alone)" || { echo "  FAIL  LOG.md grew"; fails=$((fails + 1)); }
for f in doctrine/NEXT.md state/README.md QUICKSTART.md AGENTS.md; do
  if grep -qE 'PENDING_RED=0|CITED_FILES=0' "$HERE/../$f"; then echo "  FAIL  $f still names an escape: $(grep -nE 'PENDING_RED=0|CITED_FILES=0' "$HERE/../$f" | head -2)"; fails=$((fails + 1)); else echo "  ok    $f names no escape (next.sh's header has them)"; fi
done
# ---- src/ anchored like the spec: init-state records it, the owner re-records it, signed (a local model edited the hook it audited)
S6="$K6/s"; mkdir -p "$S6/src/lib"; printf 'contract H {}\n' > "$S6/src/H.sol"; printf 'library L {}\n' > "$S6/src/lib/L.sol"; printf '# the owner spec\n' > "$S6/SPEC.md"; S6A="$(cd "$S6" && pwd)"
"$K6_IS" "$S6" > "$TMP/o6030" 2>&1; check "init-state.sh on a project with src/: written" 0 $? "$TMP/o6030"
k6_h="$(src_anchor_hash "$S6A")"
if [ "$(cat "$S6/.gauntlet/src.sha256")" = "$k6_h  src/" ] && [ ${#k6_h} = 64 ]; then echo "  ok    .gauntlet/src.sha256 is '<sha256>  src/' - the hash of src/'s file list and contents"; else
  echo "  FAIL  src.sha256: $(cat "$S6/.gauntlet/src.sha256" 2>&1)"; fails=$((fails + 1)); fi
k5_has "$TMP/o6030" "... and it says so" "init-state: recorded src/: $S6A/.gauntlet/src.sha256 = $k6_h  src/"
S6N="$K6/sn"; mkdir -p "$S6N/src"
"$K6_IS" "$S6N" > "$TMP/o6031" 2>&1; check "init-state.sh on a project whose src/ has no file (the hook still to be written)" 0 $? "$TMP/o6031"
if [ -e "$S6N/.gauntlet/src.sha256" ]; then echo "  FAIL  and it wrote src.sha256"; fails=$((fails + 1)); else
  k5_has "$TMP/o6031" "... nothing anchored, and it says so - the owner's act once the hook exists" "init-state: no file under " "nothing anchored"; fi
k5_no_by "$TMP/o6031" "... and no line of it hands over the runnable form"
"$K6_IS" "$S6" --src > "$TMP/o6032" 2>&1; check "init-state.sh --src on a project that has its state, unsigned: refused" 2 $? "$TMP/o6032"
k5_has "$TMP/o6032" "... naming the act, the owner's, signed" "src/ is the owner's code (anchor: ${k6_h:0:8})" "(--by; the header of scripts/init-state.sh says how)"
k5_no_by "$TMP/o6032" "... and no line of it hands over the runnable form"
"$K6_IS" "$S6" --by "Pat Owner" > "$TMP/o6033" 2>&1; check "init-state.sh --by alone: refused" 2 $? "$TMP/o6033"
k5_has "$TMP/o6033" "... saying what it signs" "--by signs a re-record of the spec or of src/: give --spec <the spec> or --src too"
printf '// the owner changed it\n' >> "$S6/src/H.sol"; k6_h2="$(src_anchor_hash "$S6A")"
"$K6_IS" "$S6" --src --by "Pat Owner" > "$TMP/o6034" 2>&1; check "init-state.sh --src --by: the owner's signed re-record" 0 $? "$TMP/o6034"
if [ "$(sed -n 1p "$S6/.gauntlet/src.sha256")" = "$k6_h2  src/" ] && [ "$(sed -n 2p "$S6/.gauntlet/src.sha256")" = "re-recorded $(date +%F) by \"Pat Owner\" ${k6_h:0:8} -> ${k6_h2:0:8}" ]; then
  echo "  ok    src.sha256: the new anchor on line 1, the signed re-record on line 2"; else echo "  FAIL  src.sha256:"; sed "s/^/        | /" "$S6/.gauntlet/src.sha256"; fails=$((fails + 1)); fi
[ "$(tail -n 1 "$S6/.gauntlet/LOG.md")" = "$(date +%F) src/ re-recorded: ${k6_h:0:8} -> ${k6_h2:0:8}, signed --by \"Pat Owner\" (init-state --src --by: the kit cannot tell whose hands these were; the owner reads this line, and the dossier carries it)" ] \
  && echo "  ok    and LOG.md: the dated, signed line" || { echo "  FAIL  LOG.md's last line: $(tail -n 1 "$S6/.gauntlet/LOG.md")"; fails=$((fails + 1)); }
printf '# the owner spec, changed\n' > "$S6/SPEC.md"; printf '// again\n' >> "$S6/src/H.sol"
"$K6_IS" "$S6" --spec SPEC.md --src --by "Pat Owner" > "$TMP/o6035" 2>&1; check "init-state.sh --spec --src --by: both in one signed act" 0 $? "$TMP/o6035"
[ "$(tail -n 3 "$S6/.gauntlet/LOG.md" | grep -cE ' (spec|src/) re-recorded: ')" = 2 ] && [ "$(grep -c '^re-recorded ' "$S6/.gauntlet/src.sha256")" = 2 ] \
  && echo "  ok    two LOG.md lines (the spec's, src/'s), and src.sha256 keeps both re-records" || { echo "  FAIL  not both"; tail -n 4 "$S6/.gauntlet/LOG.md" | sed "s/^/        | /"; fails=$((fails + 1)); }
rm -f "$S6/.gauntlet/src.sha256"
"$K6_IS" "$S6" --src --by "Pat Owner" > "$TMP/o6036" 2>&1; check "init-state.sh --src --by on a project with no anchor (set up before v0.4.2)" 0 $? "$TMP/o6036"
grep -qE '^re-recorded [0-9-]+ by "Pat Owner" none -> [0-9a-f]{8}$' "$S6/.gauntlet/src.sha256" && echo "  ok    none -> <new8>" || { echo "  FAIL  src.sha256: $(cat "$S6/.gauntlet/src.sha256")"; fails=$((fails + 1)); }
"$K6_IS" "$S6N" --src --by "Pat Owner" > "$TMP/o6037" 2>&1; check "init-state.sh --src --by on a src/ with no file: refused" 2 $? "$TMP/o6037"
# ---- pending-red.sh and battery.sh: src/ against its anchor, before anything runs; _skipPermissionCheck under test/
if command -v forge > /dev/null 2>&1 && [ -e "$HERE/../foundry-kit/lib" ]; then
  A6="$K6/a"; rm -rf "$A6"; mkdir -p "$A6/src" "$A6/pending" "$A6/test"; ln -s "$(cd "$HERE/../foundry-kit/lib" && pwd -P)" "$A6/lib"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n[profile.pending]\ntest = "pending"\n' > "$A6/foundry.toml"
  printf 'pragma solidity ^0.8.26;\ncontract H { uint256 public x; function set(uint256 v) external { x = v; } }\n' > "$A6/src/H.sol"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/H.sol";\nabstract contract Base is Test {\n    bool internal _skipPermissionCheck;\n    H internal h;\n    function setUp() public virtual { h = new H(); }\n}\n' > "$A6/test/Base.sol"
  printf 'pragma solidity ^0.8.26;\nimport "./Base.sol";\ncontract HT is Base { function test_set() public { h.set(2); assertEq(h.x(), 2); } }\n' > "$A6/test/H.t.sol"
  printf 'pragma solidity ^0.8.26;\nimport "../test/Base.sol";\ncontract F1 is Base { function test_F1_x_is_never_one() public { h.set(1); assertTrue(h.x() != 1, "x is one"); } }\n' > "$A6/pending/F-1.t.sol"
  "$K6_IS" "$A6" > /dev/null 2>&1; A6A="$(cd "$A6" && pwd -P)"; a6_h="$(src_anchor_hash "$A6A")"
  printf '// edited in place\n' >> "$A6/src/H.sol"; a6_h2="$(src_anchor_hash "$A6A")"
  K6_SRC="the code under audit is the owner's. Undo the change (put the owner's code back) and write what you assumed in DECISIONS.md (source: assumed, owner absent): a finding's fix is the owner's decision (doctrine/NEXT.md row 6b), shown on a copy (scripts/mutate.sh), never written into src/. The owner, present, re-records a change of their own with scripts/init-state.sh, signed; an agent never does it. Nothing run."
  "$HERE/pending-red.sh" "$A6" > "$TMP/o6040" 2>&1; check "pending-red.sh refuses src/ changed since init-state anchored it (the local model's edit)" 2 $? "$TMP/o6040"
  k5_has "$TMP/o6040" "... the spec's refusal, for the code" "pending-red: REFUSED - $A6A/src changed since init-state recorded it (.gauntlet/src.sha256 ${a6_h:0:8}, now ${a6_h2:0:8}): $K6_SRC"
  k5_no_by "$TMP/o6040" "... no runnable --by in it"; k6_not "$TMP/o6040" "... no escape in it" "PENDING_RED"
  [ ! -e "$A6/.gauntlet/pending-red" ] && echo "  ok    and nothing ran, nothing was written" || { echo "  FAIL  pending-red wrote $A6/.gauntlet/pending-red"; fails=$((fails + 1)); }
  "$HERE/battery.sh" "$A6" > "$TMP/o6041" 2>&1; check "battery.sh refuses it too: nothing run (exit 2)" 2 $? "$TMP/o6041"
  k5_has "$TMP/o6041" "... the same refusal" "battery: REFUSED - $A6A/src changed since init-state recorded it (.gauntlet/src.sha256 ${a6_h:0:8}, now ${a6_h2:0:8}): $K6_SRC" "battery: nothing run."
  k5_no_by "$TMP/o6041" "... no runnable --by in it"
  [ ! -e "$A6/.gauntlet/reports" ] && echo "  ok    and no report was written" || { echo "  FAIL  the battery wrote $A6/.gauntlet/reports"; fails=$((fails + 1)); }
  "$K6_IS" "$A6" --src --by "Pat Owner" > /dev/null 2>&1
  "$HERE/pending-red.sh" "$A6" > "$TMP/o6042" 2>&1; check "pending-red.sh after the owner's signed re-record: red, recorded" 0 $? "$TMP/o6042"
  k5_has "$TMP/o6042" "... saying src/ is as recorded, and who re-recorded it (no runnable form)" "pending-red: src/ is as recorded (.gauntlet/src.sha256 ${a6_h2:0:8}); re-recorded on $(date +%F), signed by \"Pat Owner\" (${a6_h:0:8} -> ${a6_h2:0:8}): the owner confirms that signature is theirs."
  k5_no_by "$TMP/o6042" "... no runnable --by in it"
  a6_rec="$(pending_record_path "$A6A" pending/F-1.t.sol)"
  k5_has "$a6_rec" "the red record names the anchor it was made on" "anchor: src/ as recorded (.gauntlet/src.sha256 ${a6_h2:0:8})"
  rm -f "$A6/.gauntlet/src.sha256"
  "$HERE/pending-red.sh" "$A6" > "$TMP/o6043" 2>&1; check "pending-red.sh on a project with its state and no anchor: not refused" 0 $? "$TMP/o6043"
  [ "$(grep -c 'src/ has no anchor' "$TMP/o6043")" = 1 ] && k5_has "$TMP/o6043" "... told once how one is made" "init-state.sh records it when it writes a new project's state; on this project, which has its state, recording it is the owner's act, signed (--src --by; the header of scripts/init-state.sh says how)." \
    || { echo "  FAIL  not told once:"; sed "s/^/        | /" "$TMP/o6043"; fails=$((fails + 1)); }
  k5_no_by "$TMP/o6043" "... no runnable --by in it"
  "$K6_IS" "$A6" --src --by "Pat Owner" > /dev/null 2>&1
  # _skipPermissionCheck = true under test/: only while a permission-bits finding is open AND recorded (round 4: both
  # strong models set it in the everyday base, and the battery said nothing)
  sed -i 's/function setUp() public virtual { h = new H(); }/function setUp() public virtual { _skipPermissionCheck = true; h = new H(); }/' "$A6/test/Base.sol"
  K6_BITS_TAIL="A suite under test/ may assign _skipPermissionCheck only while that permission-bits finding is OPEN AND RECORDED, in this order"
  "$HERE/battery.sh" "$A6" > "$TMP/o6050" 2>&1; check "battery.sh refuses test/Base.sol setting _skipPermissionCheck with no finding named" 2 $? "$TMP/o6050"
  k5_has "$TMP/o6050" "... naming the file, the rule and pending-red.sh" "battery: REFUSED - test/Base.sol sets _skipPermissionCheck = true and names no permission-bits finding" "$K6_BITS_TAIL" "$HERE/pending-red.sh $A6A pending/<id>.t.sol"
  sed -i '1a // _skipPermissionCheck: F-2 open' "$A6/test/Base.sol"
  "$HERE/battery.sh" "$A6" > "$TMP/o6051" 2>&1; check "... with a header naming F-2 and no pending/F-2.t.sol" 2 $? "$TMP/o6051"
  k5_has "$TMP/o6051" "... said" "battery: REFUSED - test/Base.sol sets _skipPermissionCheck = true under F-2, and there is no pending/F-2.t.sol"
  printf 'pragma solidity ^0.8.26;\nimport "../test/Base.sol";\ncontract F2 is Base { function test_F2_callback_never_runs() public { assertTrue(false, "the callback never ran"); } }\n' > "$A6/pending/F-2.t.sol"
  "$HERE/battery.sh" "$A6" > "$TMP/o6052" 2>&1; check "... with pending/F-2.t.sol and no red record of it" 2 $? "$TMP/o6052"
  k5_has "$TMP/o6052" "... said, naming pending-red.sh" "battery: REFUSED - test/Base.sol sets _skipPermissionCheck = true under F-2, and pending/F-2.t.sol has no current red record" "$HERE/pending-red.sh"
  "$HERE/pending-red.sh" "$A6" pending/F-2.t.sol > "$TMP/o6053" 2>&1; check "pending-red.sh: F-2 red on an assertion of its own" 0 $? "$TMP/o6053"
  "$HERE/battery.sh" "$A6" > "$TMP/o6054" 2>&1; check "battery.sh: F-2 recorded red, but not on the harness's line - refused" 2 $? "$TMP/o6054"
  k5_has "$TMP/o6054" "... said" "and the red record of pending/F-2.t.sol has no permission-bits failure: its tests are red, but none of them on the harness's own line"
  printf 'pragma solidity ^0.8.26;\nimport "../test/Base.sol";\ncontract F2 is Base {\n    function test_F2_callback_never_runs() public { assertTrue(false, "the callback never ran"); }\n    function test_F2_the_harness_refuses_the_bits() public { revert("V4Harness: afterInitialize implemented but its permission bit is not set on 0x0000000000000000000000000000000000001000 - the manager never calls it."); }\n}\n' > "$A6/pending/F-2.t.sol"
  "$HERE/pending-red.sh" "$A6" pending/F-2.t.sol > "$TMP/o6055" 2>&1; check "pending-red.sh: F-2 red, one test failing on the harness's line" 0 $? "$TMP/o6055"
  a6_rec="$(pending_record_path "$A6A" pending/F-2.t.sol)"
  k5_has "$a6_rec" "the record carries the permission-bits line" "permission-bits: [FAIL: V4Harness: afterInitialize implemented but its permission bit is not set on 0x0000000000000000000000000000000000001000"
  "$HERE/battery.sh" "$A6" > "$TMP/o6056" 2>&1; check "battery.sh: the flag under test/ with the finding open and recorded - it runs, and passes" 0 $? "$TMP/o6056"
  k5_has "$TMP/o6056" "... and its summary says the green is UNDER that finding" "bits      UNDER open permission-bits finding F-2: _skipPermissionCheck set in test/Base.sol" "BATTERY PASSED - green UNDER open permission-bits finding F-2"
  sed -i -e '/_skipPermissionCheck: F-2 open/d' -e 's/_skipPermissionCheck = true; h = new H();/h = new H();/' -e '1a // set _skipPermissionCheck = true; here while a bits finding is open (a comment: not code)' "$A6/test/Base.sol"
  "$HERE/battery.sh" "$A6" > "$TMP/o6057" 2>&1; check "battery.sh: the flag only in a comment - not set, a plain battery" 0 $? "$TMP/o6057"
  [ "$(tail -n 1 "$TMP/o6057")" = "BATTERY PASSED" ] && echo "  ok    BATTERY PASSED, nothing under" || { echo "  FAIL  last line: $(tail -n 1 "$TMP/o6057")"; fails=$((fails + 1)); }
else
  echo "  SKIP  the src/ anchor and the bits rule against forge (no forge or no foundry-kit/lib)"; skipped=1
fi
# ---- setup-deps.sh writes the fuzz configuration QUICKSTART 7b needs, and says the COPY_ROOT of its layout
W60="$K42/w60"; k42_kit "$W60/lib/hook-gauntlet"; mkdir -p "$W60/proj/src"; W60="$(cd "$W60" && pwd)"
k42_run "$TMP/o6060" "$SD" "$W60/proj"; check "setup-deps.sh from nothing: the fuzz configuration too" 0 $? "$TMP/o6060"
k42_has "foundry.toml: fs_permissions for ./census, [invariant] with fail_on_revert, [profile.long.invariant] larger" "$W60/proj/foundry.toml" \
  'fs_permissions = [{ access = "read-write", path = "./census" }]' '[invariant]' 'runs = 64' 'depth = 64' 'fail_on_revert = true' \
  'corpus_dir = "corpus/invariant"' '[profile.long.invariant]' 'runs = 1000' 'depth = 128' 'shrink_run_limit = 20000'
k42_has "... each line said, then the COPY_ROOT of the ../ layout" "$TMP/o6060" \
  'setup-deps: foundry.toml [profile.default]: + fs_permissions = [{ access = "read-write", path = "./census" }]' \
  'setup-deps: foundry.toml: + [invariant] runs = 64, depth = 64, fail_on_revert = true, shrink_run_limit = 5000, corpus_dir = "corpus/invariant"' \
  'setup-deps: foundry.toml: + [profile.long.invariant] runs = 1000, depth = 128, fail_on_revert = true, shrink_run_limit = 20000' \
  "setup-deps: COPY_ROOT=.. - the kit is reached through .., outside the project: scripts/mutate.sh needs it, run from the project ($W60, which holds both"
k42_run "$TMP/o6061" "$SD" "$W60/proj"; check "setup-deps.sh again" 0 $? "$TMP/o6061"
k42_has "... the lines that are there are left as they are, and said" "$TMP/o6061" \
  'setup-deps: foundry.toml [profile.default]: fs_permissions is there - left as it is: fs_permissions = [{ access = "read-write", path = "./census" }]' \
  'setup-deps: foundry.toml: [invariant] is there - left as it is (fail_on_revert = true)' 'setup-deps: foundry.toml: [profile.long.invariant] is there - left as it is' \
  'setup-deps: foundry.toml: nothing to change'
mkdir -p "$W60/own"; printf '%s\n' '[profile.default]' 'src = "src"' 'fs_permissions = [{ access = "read", path = "./fixtures" }]' '' '[invariant]' 'runs = 500' 'depth = 20' > "$W60/own/foundry.toml"
k42_run "$TMP/o6062" "$SD" "$W60/own"; check "setup-deps.sh on a project with a fuzz configuration of its own" 0 $? "$TMP/o6062"
k42_has "... its [invariant] gets fail_on_revert, the long budget is 4 x its runs at its depth, its fs_permissions is named" "$TMP/o6062" \
  'setup-deps: foundry.toml: + fail_on_revert = true   (under your [invariant], which had none: QUICKSTART.md 7b)' \
  'setup-deps: foundry.toml: + [profile.long.invariant] runs = 2000, depth = 20' \
  'it has no ./census: the census (scripts/census.sh, fuzz-long.sh) needs read-write there, yours to add'
k42_has "... and its own lines are kept" "$W60/own/foundry.toml" 'runs = 500' 'depth = 20' 'fs_permissions = [{ access = "read", path = "./fixtures" }]'
[ "$(grep -c '^\[invariant\]' "$W60/own/foundry.toml")" = 1 ] && echo "  ok    one [invariant]" || { echo "  FAIL  [invariant] written twice"; fails=$((fails + 1)); }
k42_has "the flat layout says it needs no COPY_ROOT" "$TMP/k42-o13" 'setup-deps: no COPY_ROOT - the kit is inside the project (lib/hook-gauntlet)'
# ---- the selftest marker by mktemp (round 4: two selftests in one kit shared one fixed temporary name and both ended FAILED)
k6_tmp='"$m'; k6_tmp="$k6_tmp.tmp\""
if grep -qF 't="$(mktemp "$m.XXXXXX")"' "$HERE/selftest.sh" && ! grep -qF "$k6_tmp" "$HERE/selftest.sh"; then echo "  ok    the marker is written through a temporary file of its own (mktemp), never a shared name"; else
  echo "  FAIL  the marker's temporary file is not by mktemp"; fails=$((fails + 1)); fi
# ---- the texts (v0.4.2, item 8)
k6_prop='PROPERTY-TESTED means the claim survived generated sequences over a stated domain, with the success and reach censuses attached'
grep -qF "$k6_prop" "$HERE/../briefs/handoff-dossier.md" && grep -qF '| **PROPERTY-TESTED** | the claim survived generated sequences over a stated domain, with the success and reach censuses attached |' "$HERE/../doctrine/EVIDENCE.md" \
  && echo "  ok    the dossier template's PROPERTY-TESTED is EVIDENCE.md's" || { echo "  FAIL  the dossier template and EVIDENCE.md define PROPERTY-TESTED differently"; fails=$((fails + 1)); }
k42_has "QUICKSTART: REACH's separator, and the floor below the lowest of three short campaigns" "$HERE/../QUICKSTART.md" 'REACH names by `;`' \
  'run the short campaign three times (`scripts/census.sh <proj>`); the floor goes below the lowest'
k42_has "NEXT.md: next.sh's refusals go to stderr" "$HERE/../doctrine/NEXT.md" 'A refusal goes to stderr (`next: REFUSED - ...`, exit 2)'
k42_has "the battery skill names _setUpV4() and block.timestamp" "$HERE/../skills/hook-gauntlet-battery/SKILL.md" '_setUpV4()' 'block.timestamp'
k6_left="$(grep -rlF 'only in pending tests' "$HERE/.." --include='*.md' --include='*.sol' --include='*.sh' 2> /dev/null | grep -vE '/(lib|out|cache)/|/CHANGELOG\.md$|/scripts/selftest\.sh$' | head -3)"
[ -z "$k6_left" ] && echo "  ok    no text of the kit keeps the flag to pending tests (the CHANGELOG's history aside)" || { echo "  FAIL  still 'only in pending tests': $k6_left"; fails=$((fails + 1)); }
# --- end K60 ---

# --- K61 ---
# ================================================================= v0.4.2 (K61): what V60 found on the bits path - the
# order trap (record the red, put the flag in test/, and the record went stale: the battery refused seconds after RED),
# a refusal that named neither the part that changed nor the real file, `= !false` unseen, a .gauntlet-bench marker that
# turned the rule off silently; the harness's line that did not say the finding's own test sets the flag; NEXT.md on
# stdout/stderr; the selftest's minutes; the missing src/ anchor said on every command; setup-deps's fail_on_revert line
echo "== v0.4.2 (K61): the bits record keyed to src/ and its own file, stale records named, any assignment to the flag, bits not checked said =="
K61="$TMP/k61"; rm -rf "$K61"; mkdir -p "$K61"
if command -v forge > /dev/null 2>&1; then
  # a project of the route, with no forge-std (cheap to build): the bits finding F-1 - its own setUp sets the flag, a
  # test of its own fails on the harness's line - and F-3, a finding red on an assertion of its own
  B7="$K61/b"; mkdir -p "$B7/src" "$B7/pending" "$B7/test"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = []\n[profile.pending]\ntest = "pending"\n' > "$B7/foundry.toml"
  printf 'pragma solidity ^0.8.26;\ncontract H { uint256 public x; function set(uint256 v) external { x = v; } }\n' > "$B7/src/H.sol"
  printf 'pragma solidity ^0.8.26;\nimport "../src/H.sol";\nabstract contract Base {\n    bool internal _skipPermissionCheck;\n    H internal h;\n    function setUp() public virtual { h = new H(); }\n}\n' > "$B7/test/Base.sol"
  printf 'pragma solidity ^0.8.26;\nimport "./Base.sol";\ncontract HT is Base { function test_set() public { h.set(2); require(h.x() == 2, "x"); } }\n' > "$B7/test/H.t.sol"
  K61_LINE="V4Harness: afterInitialize implemented but its permission bit is not set on 0x0000000000000000000000000000000000001000 - the manager never calls it."
  printf 'pragma solidity ^0.8.26;\nimport "../test/Base.sol";\ncontract F1 is Base {\n    function setUp() public override { _skipPermissionCheck = true; super.setUp(); }\n    function test_F1_the_harness_refuses_the_bits() public { revert("%s"); }\n}\n' "$K61_LINE" > "$B7/pending/F-1.t.sol"
  printf 'pragma solidity ^0.8.26;\nimport "../test/Base.sol";\ncontract F3 is Base { function test_F3_x_is_never_one() public { h.set(1); require(h.x() != 1, "x is one"); } }\n' > "$B7/pending/F-3.t.sol"
  printf '# the owner spec\n' > "$B7/SPEC.md"
  "$K6_IS" "$B7" > /dev/null 2>&1; B7A="$(cd "$B7" && pwd -P)"; B7N="$(cd "$B7" && pwd)"; b7_h="$(src_anchor_hash "$B7A")"
  sed 's/^notes: .*/notes:                     pending: F-1, F-3 - a callback never called; x is one, owner undecided/' "$FIX/state-new-project.md" > "$B7/.gauntlet/STATE.md"
  "$HERE/pending-red.sh" "$B7" > "$TMP/o6101" 2>&1; check "pending-red.sh: F-1 red on the harness's line, F-3 on an assertion of its own - both recorded" 0 $? "$TMP/o6101"
  b7_r1="$(pending_record_path "$B7A" pending/F-1.t.sol)"
  k5_has "$b7_r1" "F-1's record: src/'s hash on its anchor: line, each part of the key hashed alone on its keyed: line" \
    "anchor: src/ as recorded (.gauntlet/src.sha256 ${b7_h:0:8}) - src/ sha256 $b7_h" "keyed: src/ $b7_h test/ " " file $(k5_sha "$B7/pending/F-1.t.sol")"
  k5_has "$TMP/o6101" "... and pending-red.sh names what comes next, in its order, with the finding's id" \
    "pending-red: pending/F-1.t.sol fails on the harness's permission-bits line: the finding is OPEN AND RECORDED. Now put _skipPermissionCheck = true and the header line '// _skipPermissionCheck: F-1 open' in the suites that deploy the hook, then run the battery ($HERE/battery.sh $B7A)"
  # the texts' order: record the red, THEN the flag and header in the suites (V60, Q2 step 10: that edit staled the record)
  sed -i -e '1a // _skipPermissionCheck: F-1 open' -e 's/function setUp() public virtual { h = new H(); }/function setUp() public virtual { _skipPermissionCheck = true; h = new H(); }/' "$B7/test/Base.sol"
  "$HERE/battery.sh" "$B7" > "$TMP/o6102" 2>&1; check "battery.sh: the flag and header put into test/ AFTER F-1 was recorded - F-1's record is still current: green UNDER F-1" 0 $? "$TMP/o6102"
  k5_has "$TMP/o6102" "... saying the record is current on src/ and its own file" \
    "battery: test/Base.sol set _skipPermissionCheck UNDER open permission-bits finding F-1 (recorded red on the harness's line; F-1's record current on src/ and pending/F-1.t.sol as recorded" \
    "BATTERY PASSED - green UNDER open permission-bits finding F-1"
  kx_one 6103 "next.sh after that test/ edit: F-1's bits record current, F-3's (an assertion's, the full key) stale - refused, naming the part that changed" 2 \
    "next: pending/F-3.t.sol - not seen red on the code as it stands (its red record of $(date +%F) is stale - test/ changed since): $KX_KIT/scripts/pending-red.sh $B7N pending/F-3.t.sol" "$B7"
  sed -i 's|^// _skipPermissionCheck: F-1 open|// _skipPermissionCheck: F-3 open|' "$B7/test/Base.sol"
  "$HERE/battery.sh" "$B7" > "$TMP/o6104" 2>&1; check "battery.sh: a header naming F-3, whose record keeps the full key - stale after the test/ edit, refused" 2 $? "$TMP/o6104"
  k5_has "$TMP/o6104" "... saying which part changed, and naming the finding's own file and id, not a placeholder" \
    "battery: REFUSED - test/Base.sol sets _skipPermissionCheck = true under F-3, and pending/F-3.t.sol has no current red record: its red record of $(date +%F) is stale - test/ changed since" \
    "$HERE/pending-red.sh $B7A pending/F-3.t.sol records that red" "'// _skipPermissionCheck: F-3 open'"
  k6_not "$TMP/o6104" "... (no pending/<id>.t.sol in it)" "pending/<id>.t.sol"
  sed -i 's|^// _skipPermissionCheck: F-3 open|// _skipPermissionCheck: F-1 open|' "$B7/test/Base.sol"
  cp "$B7/pending/F-1.t.sol" "$K61/F-1.keep"; printf '// a comment\n' >> "$B7/pending/F-1.t.sol"
  "$HERE/battery.sh" "$B7" > "$TMP/o6105" 2>&1; check "battery.sh: pending/F-1.t.sol itself edited since its record - stale, refused" 2 $? "$TMP/o6105"
  k5_has "$TMP/o6105" "... saying so, and naming pending/F-1.t.sol in the command" \
    "and pending/F-1.t.sol has no current red record: its red record of $(date +%F) is stale - pending/F-1.t.sol itself changed since (a permission-bits record stays current while src/ and its own file are as recorded)" \
    "$HERE/pending-red.sh $B7A pending/F-1.t.sol records that red"
  cp "$K61/F-1.keep" "$B7/pending/F-1.t.sol"
  mv "$B7/.gauntlet/src.sha256" "$K61/src.keep"; cp "$B7/src/H.sol" "$K61/H.keep"; printf '// edited\n' >> "$B7/src/H.sol"
  "$HERE/battery.sh" "$B7" > "$TMP/o6106" 2>&1; check "battery.sh with no anchor recorded: src/ edited since F-1's record - stale, refused" 2 $? "$TMP/o6106"
  k5_has "$TMP/o6106" "... saying src/ changed" "and pending/F-1.t.sol has no current red record: its red record of $(date +%F) is stale - src/ changed since"
  k5_has "$TMP/o6106" "... and the missing anchor told, with how one is made, once" "battery: src/ has no anchor (.gauntlet/src.sha256): nothing compared." "Said once"
  "$HERE/battery.sh" "$B7" > "$TMP/o6107" 2>&1; check "battery.sh again" 2 $? "$TMP/o6107"
  k6_not "$TMP/o6107" "... the missing anchor is not told again (once per project, not per command)" "src/ has no anchor"
  "$HERE/pending-red.sh" "$B7" pending/F-3.t.sol > "$TMP/o6107b" 2>&1; check "pending-red.sh then, on the same project" 0 $? "$TMP/o6107b"
  k6_not "$TMP/o6107b" "... nor by pending-red.sh (its record says it: anchor: src/ no anchor recorded)" "src/ has no anchor"
  cp "$K61/H.keep" "$B7/src/H.sol"; mv "$K61/src.keep" "$B7/.gauntlet/src.sha256"
  # any assignment to the flag, not only the literal `= true` (V60, Q2 step 17: `= !false` was not seen)
  sed -i -e '/_skipPermissionCheck: F-1 open/d' -e 's/_skipPermissionCheck = true; h = new H();/_skipPermissionCheck = !false; h = new H();/' "$B7/test/Base.sol"
  "$HERE/battery.sh" "$B7" > "$TMP/o6108" 2>&1; check "battery.sh: _skipPermissionCheck = !false with no header - refused" 2 $? "$TMP/o6108"
  k5_has "$TMP/o6108" "... naming the assignment it read" "battery: REFUSED - test/Base.sol sets _skipPermissionCheck = !false and names no permission-bits finding"
  sed -i 's/_skipPermissionCheck = !false; h = new H();/_skipPermissionCheck = false; h = new H();/' "$B7/test/Base.sol"
  "$HERE/battery.sh" "$B7" > "$TMP/o6109" 2>&1; check "... and _skipPermissionCheck = false: an assignment too, refused" 2 $? "$TMP/o6109"
  k5_has "$TMP/o6109" "... said" "battery: REFUSED - test/Base.sol sets _skipPermissionCheck = false and names no permission-bits finding"
  # a .gauntlet-bench marker beside a .gauntlet/ with records: the rule holds (V60, Q2 step 16: it was off, silently)
  sed -i 's/_skipPermissionCheck = false; h = new H();/_skipPermissionCheck = true; h = new H();/' "$B7/test/Base.sol"; : > "$B7/.gauntlet-bench"
  "$HERE/battery.sh" "$B7" > "$TMP/o6110" 2>&1; check "battery.sh: a .gauntlet-bench marker in a project with its records - the rule holds: refused" 2 $? "$TMP/o6110"
  k5_has "$TMP/o6110" "... said" "battery: REFUSED - test/Base.sol sets _skipPermissionCheck = true and names no permission-bits finding"
  rm -f "$B7/.gauntlet-bench"
  # a bench: no .gauntlet/ beside the suites - not checked, and said; and again once its reports are there
  N7="$K61/bench"; mkdir -p "$N7"; cp -r "$B7/src" "$B7/test" "$B7/pending" "$B7/foundry.toml" "$N7/"; printf 'a bench (selftest)\n' > "$N7/.gauntlet-bench"
  "$HERE/battery.sh" "$N7" > "$TMP/o6111" 2>&1; check "battery.sh in a bench (no .gauntlet/): the flag with no header is not checked - it runs" 0 $? "$TMP/o6111"
  k5_has "$TMP/o6111" "... and says so, before the run and in the summary" "battery: bits not checked: no .gauntlet/ beside the suites" "bits      not checked: no .gauntlet/ beside the suites"
  "$HERE/battery.sh" "$N7" > "$TMP/o6112" 2>&1; check "... again, its .gauntlet/ holding the reports alone: a bench still, not checked" 0 $? "$TMP/o6112"
  k5_has "$TMP/o6112" "... said" "bits      not checked: a bench (scripts/bench.sh's marker in $(cd "$N7" && pwd -P)) whose .gauntlet/ holds only reports/"
else
  echo "  SKIP  the bits record's key and the bits rule against forge (no forge)"; skipped=1
fi
# ---- the texts: the harness's line (the finding's own setUp, the order), the order everywhere, NEXT.md, the minutes
K61_V4H="$HERE/../foundry-kit/v4/src/V4Harness.sol"
k42_has "V4Harness's bits refusal: the finding's own setUp sets the flag, a test function of its own calls the check, then the suites, then the battery" "$K61_V4H" \
  ' pending/<id>.t.sol - its own setUp sets _skipPermissionCheck = true, then a test function of its own calls' \
  ' in STATE.md; then put _skipPermissionCheck = true and a header line // _skipPermissionCheck: <id> open in the suites'
k42_has "doctrine/EVIDENCE.md section 2: the order, and the record's narrower key" "$HERE/../doctrine/EVIDENCE.md" 'The path, in this order.' \
  'its own `setUp` sets' 'Then the flag in the suites' 'Then the battery. That record stays current while `src/` is what its `anchor:` line says'
k42_has "the v4 README: the order" "$HERE/../foundry-kit/v4/README.md" 'v0.4.2), in this order: first the bits finding'"'"'s own test' 'then the battery. That record stays current while'
k42_has "QUICKSTART 7b: the order" "$HERE/../QUICKSTART.md" 'its path goes in this order' 'then the battery, which ends `green UNDER open permission-bits'
k42_has "the battery skill: the order" "$HERE/../skills/hook-gauntlet-battery/SKILL.md" "the finding's red recorded, then the flag and header in the suites, then the battery"
k42_has "NEXT.md: the selftest's FIRST line goes to stdout, the fill ones and the refusals to stderr" "$HERE/../doctrine/NEXT.md" \
  'A refusal goes to stderr (`next: REFUSED - ...`, exit 2), and so do the two `FIRST - fill` lines;' 'and so does the selftest'"'"'s `FIRST - prove the kit` line (exit 0)'
k61_min="$(sed -n 's/^SELFTEST_MINUTES=\([0-9][0-9]*\)$/\1/p' "$NX")"
[ -n "$k61_min" ] && [ "$k61_min" -ge 8 ] && echo "  ok    next.sh's FIRST line says about $k61_min minutes (measured 371-457 s at 1636 cases: 8)" \
  || { echo "  FAIL  SELFTEST_MINUTES is ${k61_min:-unset}: the selftest measured 371-457 s (8 minutes)"; fails=$((fails + 1)); }
# ---- setup-deps.sh: a user's fail_on_revert = false in [invariant] beside the long profile's true - said
mkdir -p "$W60/own2"; printf '%s\n' '[profile.default]' 'src = "src"' '' '[invariant]' 'runs = 500' 'depth = 20' 'fail_on_revert = false' > "$W60/own2/foundry.toml"
k42_run "$TMP/o6120" "$SD" "$W60/own2"; check "setup-deps.sh on a project whose [invariant] says fail_on_revert = false" 0 $? "$TMP/o6120"
k42_has "... its line says the long profile's fail_on_revert = true judges differently" "$TMP/o6120" \
  'yours to decide; and the [profile.long.invariant] this script writes says fail_on_revert = true, so the long campaign (scripts/fuzz-long.sh) judges differently from this everyday one'
# --- end K61 ---
# --- K62 ---
# ================================================================= v0.4.2 (K62): what V60c found. A case of this file
# raced: `sed ... | grep -q` under pipefail - grep leaves at its match, sed's next write dies of SIGPIPE, the pipeline is
# 141 and the case said FAIL with the text there (about 1 run in 100, measured). And the bits finding's test was said as
# "a test of its own asserts this refusal", which a Foundry reader writes as vm.expectRevert(): that test passes, and
# pending-red.sh refuses it as no finding's test. The finding's test calls the check and lets its revert fail it. No
# forge needed: this file's own lines and the texts.
echo "== v0.4.2 (K62): no pipeline into grep -q here; the bits finding's test said as what it does - a direct call, no vm.expectRevert =="
k62_pq="$(grep -nE '(^|[^|])\|[[:space:]]*(LC_ALL=C )?grep[[:space:]]+-[A-Za-z]*q' "$HERE/selftest.sh" | grep -vE '^[0-9]+:[[:space:]]*#')"
[ -z "$k62_pq" ] && echo "  ok    no case of this selftest pipes into grep -q: each captures, then matches (pipefail and grep's early exit)" \
  || { echo "  FAIL  a pipeline into grep -q (under pipefail the writer's SIGPIPE reads as 'not there'):"; printf '%s\n' "$k62_pq" | sed "s/^/        | /"; fails=$((fails + 1)); }
K62_V4H="$HERE/../foundry-kit/v4/src/V4Harness.sol"
k62_sig="$(sed -n 's/^[[:space:]]*\(function _checkHookPermissions([^)]*) internal\).*/\1/p' "$K62_V4H")"   # the definition's line
[ "$k62_sig" = 'function _checkHookPermissions(address hook) internal' ] \
  && echo "  ok    the signature the words quote is the harness's own: $k62_sig" \
  || { echo "  FAIL  the harness's _checkHookPermissions is not 'function _checkHookPermissions(address hook) internal': '${k62_sig:-none}'"; fails=$((fails + 1)); }
k42_has "V4Harness's bits refusal: the finding's test calls _checkHookPermissions directly, with no vm.expectRevert, its signature quoted" "$K62_V4H" \
  ' pending/<id>.t.sol - its own setUp sets _skipPermissionCheck = true, then a test function of its own calls' \
  ' _checkHookPermissions(address(hook)) directly (V4Harness: function _checkHookPermissions(address hook) internal), with' \
  ' no vm.expectRevert, so this revert fails that test - record that red with scripts/pending-red.sh <proj> pending/<id>.t.sol, count it'
k42_has "test/HookPermissions.t.sol holds the same words" "$HERE/../foundry-kit/v4/test/HookPermissions.t.sol" \
  ' pending/<id>.t.sol - its own setUp sets _skipPermissionCheck = true, then a test function of its own calls' \
  ' _checkHookPermissions(address(hook)) directly (V4Harness: function _checkHookPermissions(address hook) internal), with' \
  ' no vm.expectRevert, so this revert fails that test - record that red with scripts/pending-red.sh <proj> pending/<id>.t.sol, count it'
k42_has "battery.sh's bits refusal: the same act and signature" "$HERE/battery.sh" \
  'sets _skipPermissionCheck = true in its setUp, then a test function of its own calls _checkHookPermissions(address(hook)); directly (V4Harness: function _checkHookPermissions(address hook) internal), with no vm.expectRevert, so the harness'"'"'s revert fails that test'
k42_has "EVIDENCE.md section 2: a direct call, no vm.expectRevert, the signature" "$HERE/../doctrine/EVIDENCE.md" \
  'test function of its own calls `_checkHookPermissions(address(hook));` directly, with no `vm.expectRevert`' '`function _checkHookPermissions(address hook) internal`'
k42_has "the v4 README: the same, in the quoted line and in the route's path" "$HERE/../foundry-kit/v4/README.md" \
  '= true, then a test function of its own calls _checkHookPermissions(address(hook)) directly (V4Harness: function' \
  '`_skipPermissionCheck = true`, then a test function of its own calls `_checkHookPermissions(address(hook));` directly'
k42_has "QUICKSTART 7b: the same" "$HERE/../QUICKSTART.md" 'a test function of its own calls `_checkHookPermissions(address(hook))` directly, with'
for k62_f in foundry-kit/v4/src/V4Harness.sol foundry-kit/v4/test/HookPermissions.t.sol scripts/battery.sh doctrine/EVIDENCE.md \
  foundry-kit/v4/README.md QUICKSTART.md; do
  if grep -qE "asserts (this|the|the harness's) refusal" "$HERE/../$k62_f"; then
    echo "  FAIL  $k62_f still says 'asserts ... refusal' (read as vm.expectRevert):"; grep -nE "asserts (this|the|the harness's) refusal" "$HERE/../$k62_f" | sed "s/^/        | /"; fails=$((fails + 1))
  else echo "  ok    $k62_f no longer says 'asserts this/the/the harness's refusal'"; fi
done
# --- end K62 ---

# ================================================================= v0.5: static-triage.sh - the static analysers this
# machine has, on the project's src/ only, into .gauntlet/reports/05-static.txt; a missing tool is said, never fetched.
# Slither and Aderyn are FAKES here (stubs on the PATH): Slither's prints a real Slither 0.11.6 checklist of the kit's own
# sources (scripts/test/fixtures/slither-real-checklist.txt, its one `(wd: ...)` path replaced) and its real last line;
# Aderyn's writes a report of the shape the script ASSUMES (aderyn-assumed-report.md: no Aderyn has been run here). The
# real ones on this machine, if any, are taken off the PATH for every case. forge lint is the real one: forge needed.
echo "== v0.5: static-triage.sh - what is installed runs, on src/; a missing tool is said, never fetched; counts read, not guessed =="
if command -v forge > /dev/null 2>&1; then
  ST="$TMP/st"; STP="$ST/proj"; mkdir -p "$STP/src" "$STP/.gauntlet" "$ST/forge"
  ln -s "$(command -v forge)" "$ST/forge/forge"
  printf '[profile.default]\nsrc = "src"\nout = "out"\nlibs = ["lib"]\n' > "$STP/foundry.toml"
  printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n\ncontract T {\n    address public immutable owner;\n\n    constructor() {\n        owner = msg.sender;\n    }\n\n    function isOwner() external view returns (bool) {\n        if (msg.sender == tx.origin) {\n            return msg.sender == owner;\n        }\n        return false;\n    }\n}\n' > "$STP/src/T.sol"
  # the PATH with no slither and no aderyn in it: every directory of this one that holds either is left out
  st_path="$ST/forge"; IFS=: read -r -a st_dirs <<< "$PATH"
  for d in "${st_dirs[@]}"; do [ -n "$d" ] || continue; { [ -x "$d/slither" ] || [ -x "$d/aderyn" ]; } && continue; st_path="$st_path:$d"; done
  st_run() { # st_run <out> <dirs before the clean PATH, or ""> [<proj>]: the script on the fixture project
    local o="$1" pre="$2" p="${3:-$STP}"
    rm -rf "$p/.gauntlet/reports"
    env PATH="${pre:+$pre:}$st_path" "$HERE/static-triage.sh" "$p" > "$o" 2>&1
  }
  st_report() { printf '%s' "$STP/.gauntlet/reports/05-static.txt"; }
  # st_slither <dir> <the total its last line says> <its exit code>: a fake Slither that logs its arguments, deletes
  # cache/invariant/ and cache/fuzz/ as the real one's `forge build --force` does (measured: forge's two persisted-failure
  # directories), prints the real checklist and its last line
  st_slither() {
    mkdir -p "$1"
    printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && { echo 0.11.6; exit 0; }\nprintf "%%s\\n" "$*" >> "%s/slither-args"\nrm -rf cache/invariant cache/fuzz\ncat "%s"\necho "INFO:Slither:. analyzed (29 contracts with 102 detectors), %s result(s) found" >&2\nexit %s\n' \
      "$ST" "$FIX/slither-real-checklist.txt" "$2" "$3" > "$1/slither"
    chmod +x "$1/slither"
  }
  st_slither "$ST/sl" 43 0; st_slither "$ST/sl-nm" 44 0; st_slither "$ST/sl-fail" 43 1
  mkdir -p "$ST/ad"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && { echo "aderyn 0.6.5"; exit 0; }\nprintf "%%s\\n" "$*" >> "%s/aderyn-args"\nwhile [ $# -gt 0 ]; do [ "$1" = --output ] && { cp "%s" "$2"; exit 0; }; shift; done\nexit 3\n' \
    "$ST" "$FIX/aderyn-assumed-report.md" > "$ST/ad/aderyn"; chmod +x "$ST/ad/aderyn"
  st_files() { (cd "$STP" && find . -path ./.gauntlet/reports -prune -o -type f -print | LC_ALL=C sort); }
  st_before="$(st_files)"

  # 1. no analyser installed: forge lint only, the report written, the STATE line printed
  st_run "$TMP/o7010" ""; check "static-triage: no Slither, no Aderyn - forge lint only" 0 $? "$TMP/o7010"
  if [ -f "$(st_report)" ] && grep -qx '# slither:    not installed' "$(st_report)" && grep -qx '# aderyn:     not installed' "$(st_report)" \
    && grep -qE '^# forge lint: forge [0-9.]+ - ran$' "$(st_report)" && grep -qE '^forge lint: [1-9][0-9]* lints - ' "$(st_report)" \
    && grep -qF 'warning[tx-origin]' "$(st_report)" && grep -qF 'note[screaming-snake-case-immutable]' "$(st_report)" && grep -qE '^forge lint by severity: high [0-9]+, med [0-9]+, low [0-9]+, info [0-9]+, gas [0-9]+, code-size [0-9]+$' "$(st_report)"; then
    echo "  ok    and .gauntlet/reports/05-static.txt has the header (both analysers 'not installed', forge lint ran), the lint findings (a warning and a note) and their counts by level and by severity"
  else echo "  FAIL  the report is missing, or its header, findings or counts are not as documented:"; sed -n '1,8p;/^== counts ==/,$p' "$(st_report)" 2> /dev/null | sed "s/^/        | /"; fails=$((fails + 1)); fi
  st_last="$(tail -n 1 "$TMP/o7010")"
  if grep -qx 'static triage: forge lint only, Slither not installed' "$TMP/o7010" \
    && [[ $st_last == *"the findings are yours to triage, not verdicts - each one goes to pending/"* ]] \
    && [[ $st_last == *"or DECISIONS.md (by design, accepted, a false positive) like any finding"* ]]; then
    echo "  ok    and it prints the STATE line 'static triage: forge lint only, Slither not installed', and its last line says the findings go to pending/ or DECISIONS.md"
  else echo "  FAIL  the STATE line or the last line is not as documented:"; tail -n 4 "$TMP/o7010" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  if [ "$(st_files)" = "$st_before" ] && ! grep -qiE 'install(ing|ed) (slither|aderyn)|pipx|cargo|curl ' "$TMP/o7010"; then
    echo "  ok    and nothing else was written in the project (forge lint does not build), and nothing was fetched"
  else echo "  FAIL  the project changed outside .gauntlet/reports, or an install was attempted"; diff <(printf '%s\n' "$st_before") <(st_files) | sed "s/^/        | /"; fails=$((fails + 1)); fi

  # 2. the STATE line's other form: the owner's last answer to question 17b in DECISIONS.md is "no"
  printf '# DECISIONS\n\n## D-01 · 2026-10-06 · Q17b static analyzers: no\n\n**Decision:** the kit may not install Slither or Aderyn here.\nsource: owner\n' > "$STP/.gauntlet/DECISIONS.md"
  st_run "$TMP/o7011" ""; check "static-triage: no analyser, and the owner declined the install (DECISIONS.md, Q17b: no)" 0 $? "$TMP/o7011"
  if grep -qx 'static triage: forge lint only - the owner declined the install' "$TMP/o7011" && grep -qx 'static triage: forge lint only - the owner declined the install' "$(st_report)"; then
    echo "  ok    and the STATE line is 'static triage: forge lint only - the owner declined the install', in the report too"
  else echo "  FAIL  the declined form of the STATE line was not printed:"; grep '^static triage' "$TMP/o7011" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  printf '\n## D-02 · 2026-10-07 · Q17b static analyzers: yes\n\nsource: owner\n' >> "$STP/.gauntlet/DECISIONS.md"
  st_run "$TMP/o7012" ""; check "static-triage: a later answer, yes, replaces the no" 0 $? "$TMP/o7012"
  grep -qx 'static triage: forge lint only, Slither not installed' "$TMP/o7012" \
    && echo "  ok    and the line is back to 'forge lint only, Slither not installed' (the last answer counts; nothing installed either way)" \
    || { echo "  FAIL  the last answer to Q17b was not the one read:"; grep '^static triage' "$TMP/o7012" | sed "s/^/        | /"; fails=$((fails + 1)); }
  rm -f "$STP/.gauntlet/DECISIONS.md"

  # 3. a (fake) Slither on the PATH: run on src/ only, its checklist read and counted against its own total
  mkdir -p "$STP/cache/invariant/failures/S" "$STP/cache/fuzz"; echo kept > "$STP/cache/invariant/failures/S/t"; rm -f "$ST/slither-args"
  printf 'a persisted fuzz failure\n' > "$STP/cache/fuzz/failures"; touch -d @1700000000 "$STP/cache/fuzz/failures" "$STP/cache/invariant/failures/S/t"
  st_persist() { (cd "$STP" && find cache/invariant cache/fuzz 2> /dev/null | LC_ALL=C sort | while IFS= read -r f; do echo "$f"; [ ! -f "$f" ] || cat "$f"; done) | cksum; }
  st_persist_before="$(st_persist)"
  st_run "$TMP/o7013" "$ST/sl"; check "static-triage: a Slither on the PATH (fake: a real 0.11.6 checklist)" 0 $? "$TMP/o7013"
  st_inc="^$(cd "$STP" && pwd -P | sed 's/[][\.^$*+?(){}|]/\\&/g')/src/[^/]"
  if grep -qxF "slither 0.11.6: 43 findings - High 2, Medium 0, Low 8, Informational 29, Optimization 4" "$(st_report)" \
    && grep -qx '# slither:    slither 0.11.6 - ran' "$(st_report)" && grep -qx 'static triage: slither 0.11.6, forge lint' "$TMP/o7013"; then
    echo "  ok    and the report counts 43 findings by impact (High 2, Low 8, Informational 29, Optimization 4), equal to Slither's own total; the STATE line names it"
  else echo "  FAIL  Slither's checklist was not counted as documented:"; grep -E '^(# slither|slither|static triage)' "$(st_report)" "$TMP/o7013" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  if [ "$(cat "$ST/slither-args" 2> /dev/null)" = ". --include-paths $st_inc --checklist --fail-none --skip-clean" ]; then
    echo "  ok    and Slither was given the project's own src/, resolved, as an include regex - not --filter-paths lib (which drops a result when ANY element's absolute path matches)"
  else echo "  FAIL  Slither's arguments: '$(cat "$ST/slither-args" 2> /dev/null)', expected '. --include-paths $st_inc --checklist --fail-none --skip-clean'"; fails=$((fails + 1)); fi
  if [ "$(st_persist)" = "$st_persist_before" ] && [ -f "$STP/cache/fuzz/failures" ] && [ "$(cat "$STP/cache/invariant/failures/S/t" 2> /dev/null)" = kept ] \
    && grep -qF 'cache/invariant/ was changed or deleted by Slither' "$TMP/o7013" && grep -qF 'cache/fuzz/ was changed or deleted by Slither' "$TMP/o7013" \
    && grep -qF 'note: cache/fuzz/ was changed or deleted by Slither' "$(st_report)"; then
    echo "  ok    and cache/invariant/ and cache/fuzz/ (forge's persisted failures), both deleted by Slither's build, are put back byte for byte, and said - on stdout and in the report's note"
  else echo "  FAIL  forge's persisted failures were not both put back after Slither deleted them:"; (cd "$STP" && find cache 2> /dev/null) | sed "s/^/        | /"; grep -E 'cache/(invariant|fuzz)' "$TMP/o7013" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -rf "$STP/cache"
  # the project's own fuzz.failure_persist_dir (forge config --json): that directory is the one kept, and named
  cp "$STP/foundry.toml" "$ST/foundry.toml.kept"; printf '[fuzz]\nfailure_persist_dir = "persist/fuzz"\n' >> "$STP/foundry.toml"
  mkdir -p "$STP/persist/fuzz"; printf 'a persisted fuzz failure\n' > "$STP/persist/fuzz/failures"
  st_run "$TMP/o7013b" "$ST/sl"; check "static-triage: a project whose fuzz.failure_persist_dir is persist/fuzz" 0 $? "$TMP/o7013b"
  if grep -qxF 'static-triage: persist/fuzz/ as it was' "$TMP/o7013b" && [ "$(cat "$STP/persist/fuzz/failures" 2> /dev/null)" = "a persisted fuzz failure" ]; then
    echo "  ok    and the directory kept is the one forge config gives (persist/fuzz/), not the default, and it is named"
  else echo "  FAIL  the project's own failure_persist_dir was not the one kept:"; grep -E 'persist|cache/' "$TMP/o7013b" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  cp "$ST/foundry.toml.kept" "$STP/foundry.toml"; rm -rf "$STP/persist" "$STP/cache"

  # 4. its Summary does not add up to its own total: kept, said "not read", not counted - and forge lint still ran (exit 0)
  st_run "$TMP/o7014" "$ST/sl-nm"; check "static-triage: a Slither whose Summary (43) is not its own total (44)" 0 $? "$TMP/o7014"
  if grep -q '^NOT COUNTED: its checklist.s Summary adds up to 43 (11 rows) and its own last line says 44' "$(st_report)" \
    && grep -qx 'slither 0.11.6: not read - not counted' "$(st_report)" && grep -qx 'static triage: forge lint only - slither 0.11.6 not read: see 05-static.txt' "$TMP/o7014"; then
    echo "  ok    and it is said 'not read', its output kept, nothing counted; the STATE line says so"
  else echo "  FAIL  a Summary that does not add up was counted, or not said:"; grep -E '^(NOT COUNTED|slither|static triage)' "$(st_report)" "$TMP/o7014" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  st_run "$TMP/o7015" "$ST/sl-fail"; check "static-triage: a Slither that exits 1 (a failed build)" 0 $? "$TMP/o7015"
  grep -qx 'static triage: forge lint only - slither 0.11.6 failed: see 05-static.txt' "$TMP/o7015" && grep -q '^NOT COUNTED: slither exited 1' "$(st_report)" \
    && echo "  ok    and it is said 'failed', with its exit code, not counted" \
    || { echo "  FAIL  a failed Slither was not said as failed:"; grep -E '^(NOT COUNTED|static triage)' "$(st_report)" "$TMP/o7015" | sed "s/^/        | /"; fails=$((fails + 1)); }

  # 5. a (fake) Aderyn beside it: its report copied in and counted; nothing left in the project
  rm -f "$ST/aderyn-args"
  st_run "$TMP/o7016" "$ST/sl:$ST/ad"; check "static-triage: Slither and Aderyn (fakes) on the PATH" 0 $? "$TMP/o7016"
  if grep -qxF 'aderyn 0.6.5: 3 issues - High 1, Medium 0, Low 2' "$(st_report)" && grep -qx 'static triage: slither 0.11.6, aderyn 0.6.5, forge lint' "$TMP/o7016" \
    && grep -q -- '--skip-update-check' "$ST/aderyn-args" && [ "$(st_files)" = "$st_before" ]; then
    echo "  ok    and Aderyn's report is counted (High 1, Low 2, against its headings), it was told not to check for updates, and no report.md is left in the project"
  else echo "  FAIL  Aderyn was not run or counted as documented:"; grep -E '^(aderyn|static triage)' "$(st_report)" "$TMP/o7016" | sed "s/^/        | /"; fails=$((fails + 1)); fi

  # 6. the project's own slither.config.json: its filters are the project's, no include regex of ours
  printf '{ "filter_paths": "lib" }\n' > "$STP/slither.config.json"; rm -f "$ST/slither-args"
  st_run "$TMP/o7017" "$ST/sl"; check "static-triage: a project with its own slither.config.json" 0 $? "$TMP/o7017"
  [ "$(cat "$ST/slither-args" 2> /dev/null)" = ". --checklist --fail-none --skip-clean" ] && grep -qF "(the project's slither.config.json: its own filters)" "$(st_report)" \
    && echo "  ok    and Slither runs with the project's config (no path flag of ours), and the report says whose filters they are" \
    || { echo "  FAIL  the project's config was not left to Slither: '$(cat "$ST/slither-args" 2> /dev/null)'"; fails=$((fails + 1)); }
  rm -f "$STP/slither.config.json"

  # 7. refusals: nothing run, nothing written
  mkdir -p "$ST/nosrc/.gauntlet"; rm -f "$ST/slither-args"
  st_run "$TMP/o7018" "$ST/sl" "$ST/nosrc"; check "static-triage: a project with no src/ is refused" 2 $? "$TMP/o7018"
  if grep -q '^static-triage: REFUSED - .* has no src/' "$TMP/o7018" && grep -qx 'static-triage: nothing run, nothing written.' "$TMP/o7018" \
    && [ ! -e "$ST/nosrc/.gauntlet/reports" ] && [ ! -e "$ST/slither-args" ]; then
    echo "  ok    and it says why, runs nothing (no Slither call) and writes nothing"
  else echo "  FAIL  the no-src/ refusal ran or wrote something"; fails=$((fails + 1)); fi
  mkdir -p "$ST/nosol/src" "$ST/nosol/.gauntlet"; echo x > "$ST/nosol/src/README.md"
  st_run "$TMP/o7019" "" "$ST/nosol"; check "static-triage: a src/ with no .sol file is refused" 2 $? "$TMP/o7019"
  mkdir -p "$ST/noconv/src"; cp "$STP/src/T.sol" "$ST/noconv/src/"
  st_run "$TMP/o7020" "" "$ST/noconv"; check "static-triage: a tree with no .gauntlet/ (someone else's) is refused before anything runs" 2 $? "$TMP/o7020"
  [ ! -e "$ST/noconv/.gauntlet" ] && echo "  ok    and no .gauntlet/ was made in it" || { echo "  FAIL  .gauntlet/ was made in a tree without the convention"; fails=$((fails + 1)); }
  "$HERE/static-triage.sh" > "$TMP/o7021" 2>&1; check "static-triage: no argument is refused" 2 $? "$TMP/o7021"
else
  echo "  SKIPPED - no forge here: static-triage.sh (forge lint) is NOT proven on this machine"; skipped=1
fi

# ================================================================= v0.5: threat-diff.sh - the independent threat model
# against the walker's own list, by id (briefs/threat-model.md, scripts/lib/threats.sh). A fresh agent's list,
# .gauntlet/THREATS-independent.md, and the walker's, .gauntlet/THREATS.md (its matching lines `matches: T-<n>` / `new`);
# each independent threat matched, new to the walker's list and now an invariant (`/// @custom:threat T-<n>` in a test), refused
# in DECISIONS.md in one line, or unmatched - and then refused. next.sh refuses phase 3's close with `threat_model: not
# yet`, and a `diffed (...)` the files do not bear out. And the kit's example is still known by its values with the new
# flag in it. No forge needed.
echo "== v0.5: threat-diff.sh - the independent threat model against the walker's list; next.sh refuses phase 3's close without it =="
TD="$TMP/td"; TDP="$TD/proj"
td_proj() { # td_proj: a fresh project with the two fixture lists (2 independent threats, 3 of the walker's: W-3 its own)
  rm -rf "$TDP"; mkdir -p "$TDP/.gauntlet" "$TDP/test"
  cp "$FIX/threats-independent.md" "$TDP/.gauntlet/THREATS-independent.md"; cp "$FIX/threats-walker.md" "$TDP/.gauntlet/THREATS.md"
  printf 'contract Inv { function invariant_fixture() public {} }\n' > "$TDP/test/Inv.t.sol"
}
td_run() { "$HERE/threat-diff.sh" "$@"; }
td_has() { # td_has <output file> <fixed string>: one ok or one FAIL
  if grep -qF -- "$2" "$1"; then echo "  ok    and it says: ${2:0:150}"; else
    echo "  FAIL  it does not say '${2:0:150}':"; sed "s/^/        | /" "$1"; fails=$((fails + 1)); fi
}
td_last() { # td_last <output file> <the exact last line>
  if [ "$(tail -n 1 "$1")" = "$2" ]; then echo "  ok    its last line: $2"; else
    echo "  FAIL  its last line is not '$2':"; sed "s/^/        | /" "$1"; fails=$((fails + 1)); fi
}
td_norep() { # td_norep <label>: no report written
  if [ ! -e "$TDP/.gauntlet/reports/06-threats.txt" ]; then echo "  ok    and nothing written ($1)"; else
    echo "  FAIL  a report was written ($1)"; fails=$((fails + 1)); fi
}
# ---- the lists missing: not yet, nothing written
rm -rf "$TDP"; mkdir -p "$TDP/.gauntlet"
td_run "$TDP" > "$TMP/o7101" 2>&1; check "threat-diff: no THREATS-independent.md - not yet" 1 $? "$TMP/o7101"
td_last "$TMP/o7101" "threat_model: not yet - there is no .gauntlet/THREATS-independent.md - a fresh agent writes it from briefs/threat-model.md (the owner's spec, the hook's public interface and the economic model, nothing of the route's)"
td_norep "no list"
cp "$FIX/threats-independent.md" "$TDP/.gauntlet/THREATS-independent.md"
td_run "$TDP" > "$TMP/o7102" 2>&1; check "threat-diff: the independent list and no THREATS.md of the walker's - not yet" 1 $? "$TMP/o7102"
td_has "$TMP/o7102" "threat_model: not yet - there is no .gauntlet/THREATS.md - the walker's own list, written in phase 2 from doctrine/HOOK-ATTACKS.md and the spec"
td_norep "no walker's list"
# ---- all matched
td_proj; td_run "$TDP" > "$TMP/o7103" 2>&1; check "threat-diff: every independent threat matched by the walker's list" 0 $? "$TMP/o7103"
td_last "$TMP/o7103" "threat_model: diffed (2 matched, 0 new, 0 refused, 0 handed)"
TDR="$TDP/.gauntlet/reports/06-threats.txt"
if [ -f "$TDR" ] && [ "$(head -1 "$TDR")" = "threat-diff: diffed - every independent threat is matched, an invariant, refused in writing, or handed on by name" ] \
  && grep -qF 'T-1  matched by W-1  | a stranger / the fees another pool earned / ' "$TDR" && grep -qF 'T-2  matched by W-2  | ' "$TDR" \
  && grep -qF "W-3  the walker's own (new)  | the owner's key / every LP's fees / setFee above the cap, then a swap  (from: SPEC.md section 3 row 2)" "$TDR" \
  && grep -qF 'model: fixture/none (the selftest'"'"'s own, no model); received: ' "$TDR" && grep -qxF 'the line for STATE.md: threat_model: diffed (2 matched, 0 new, 0 refused, 0 handed)' "$TDR"; then
  echo "  ok    the report: its verdict, each independent threat with what matched it, the walker's own, the model, the STATE.md line"; else
  echo "  FAIL  the report is not what was diffed:"; sed "s/^/        | /" "$TDR" 2> /dev/null; fails=$((fails + 1)); fi
td_sha() { if command -v sha256sum > /dev/null 2>&1; then sha256sum < "$1" | cut -d' ' -f1; else shasum -a 256 < "$1" | cut -d' ' -f1; fi; }
grep -qxF "sha256 .gauntlet/THREATS-independent.md: $(td_sha "$TDP/.gauntlet/THREATS-independent.md")" "$TDR" 2> /dev/null \
  && grep -qxF "sha256 .gauntlet/THREATS.md: $(td_sha "$TDP/.gauntlet/THREATS.md")" "$TDR" \
  && echo "  ok    and both lists' full sha256, one line each (next.sh reads a diffed line against them: the lists are frozen after the diff)" \
  || { echo "  FAIL  the report does not keep both lists' sha256 in the form sha256 <file>: <hex>:"; sed "s/^/        | /" "$TDR" 2> /dev/null; fails=$((fails + 1)); }
# ---- one new threat the walker's list does not have: refused, naming it
printf 'T-3: a JIT provider / the passive LPs'"'"' share of a rebate / add liquidity around the price, swap, remove it\n' >> "$TDP/.gauntlet/THREATS-independent.md"
td_run "$TDP" > "$TMP/o7104" 2>&1; check "threat-diff: an independent threat neither matched, an invariant nor refused - refused" 1 $? "$TMP/o7104"
td_has "$TMP/o7104" "threat-diff: REFUSED - 1 of 3 independent threats neither matched by the walker's list (matches: in .gauntlet/THREATS.md), turned into an invariant (/// @custom:threat T-<n> in a test) nor refused in DECISIONS.md (## <id> · <date> · threat T-<n> refused: <why>) nor handed on by name (T-<n>: handed: round | audit in .gauntlet/THREATS.md): T-3 (a JIT provider / the passive LPs' share of a rebate / add liquidity around the price, swap, remove it)"
td_last "$TMP/o7104" "threat-diff: the line for STATE.md stays 'threat_model: not yet' - phase 3 does not close (doctrine/NEXT.md row 4b)"
grep -qF 'T-3  UNMATCHED  | a JIT provider' "$TDR" && grep -qxF 'the line for STATE.md stays: threat_model: not yet' "$TDR" \
  && echo "  ok    and the report says T-3 is UNMATCHED and the line stays not yet" || { echo "  FAIL  the report does not say so:"; sed "s/^/        | /" "$TDR"; fails=$((fails + 1)); }
# ---- a heading that names it in another shape: still unmatched, and the heading pointed out
printf '# DECISIONS - SomeHook\n\n## D-09 · 2026-10-06 · threat T-3: not a threat here\n' > "$TDP/.gauntlet/DECISIONS.md"
td_run "$TDP" > "$TMP/o7105" 2>&1; check "threat-diff: a DECISIONS.md heading naming T-3 in another shape is not a refusal" 1 $? "$TMP/o7105"
td_has "$TMP/o7105" "remove it) - DECISIONS.md: line 3 names it, not in the form ## <id> · <date> · threat T-<n> refused: <why>"
printf '# DECISIONS - SomeHook\n\n## D-09 · 2026-10-06 · threat T-3 refused: TBD\n' > "$TDP/.gauntlet/DECISIONS.md"
td_run "$TDP" > "$TMP/o7106" 2>&1; check "threat-diff: a refusal whose reason is a placeholder (TBD) is not a refusal" 1 $? "$TMP/o7106"
td_has "$TMP/o7106" "DECISIONS.md: its refusal on line 3 gives no reason (\"TBD\")"
# ---- refused in DECISIONS.md, in the form: passes
printf '# DECISIONS - SomeHook\n\n## D-09 · 2026-10-06 · threat T-3 refused: the hook pays no rebate to whoever is in range (SPEC.md section 7)\n\n**Reason:** ...\n' > "$TDP/.gauntlet/DECISIONS.md"
td_run "$TDP" > "$TMP/o7107" 2>&1; check "threat-diff: the new threat refused in DECISIONS.md in one line - diffed" 0 $? "$TMP/o7107"
td_last "$TMP/o7107" "threat_model: diffed (2 matched, 0 new, 1 refused, 0 handed)"
grep -qF 'T-3  refused - DECISIONS.md line 3: the hook pays no rebate to whoever is in range (SPEC.md section 7)  | ' "$TDR" \
  && echo "  ok    and the report gives the refusal's line and reason" || { echo "  FAIL  the report does not give the refusal:"; sed "s/^/        | /" "$TDR"; fails=$((fails + 1)); }
cp "$TDP/.gauntlet/DECISIONS.md" "$TMP/td-dec.md"; printf '## D-10 · 2026-10-06 · threat T-1, T-3 refused: listed together\n' >> "$TDP/.gauntlet/DECISIONS.md"
td_run "$TDP" > "$TMP/o7108" 2>&1; check "threat-diff: a refusal naming two ids, one matched already - the matched one stays matched" 0 $? "$TMP/o7108"
td_last "$TMP/o7108" "threat_model: diffed (2 matched, 0 new, 1 refused, 0 handed)"
# ---- (v0.5) a refusal heading is read only in the documented form - an id, a real date, ` · ` between them: a near miss
# is not a refusal, and the diff names its line and what is wrong with it
td_near() { # td_near <n> <label> <the heading> <what is wrong, as it says it>
  printf '# DECISIONS - SomeHook\n\n%s\n' "$3" > "$TDP/.gauntlet/DECISIONS.md"
  td_run "$TDP" > "$TMP/o$1" 2>&1; check "threat-diff: $2 - not a refusal: T-3 unmatched" 1 $? "$TMP/o$1"
  td_has "$TMP/o$1" "remove it) - DECISIONS.md: line 3 refuses it in another form than ## <id> · <YYYY-MM-DD> · threat T-<n> refused: <why> ($4), and is not read as a refusal"
}
td_near 7180 "a refusal heading with no id and no date" '## threat T-3 refused: the hook pays no rebate to whoever is in range' \
  "there is no id and no date before 'threat'"
td_near 7181 "a refusal heading with hyphens for the middle dots" '## D-23 - 2026-10-06 - threat T-3 refused: the hook pays no rebate to whoever is in range' \
  "the separators are not ' · ' (a middle dot between spaces)"
td_near 7182 "a refusal heading whose date is not a real one (2026-13-45)" '## D-23 · 2026-13-45 · threat T-3 refused: the hook pays no rebate to whoever is in range' \
  "'2026-13-45' is not a real date (YYYY-MM-DD)"
td_near 7183 "a refusal heading with an id and no date" '## D-23 · threat T-3 refused: the hook pays no rebate to whoever is in range' \
  "not <id> · <YYYY-MM-DD> before 'threat'"
# ---- turned into an invariant instead: new, not refused
rm -f "$TDP/.gauntlet/DECISIONS.md"
printf 'contract JitInv {\n    /// @custom:threat T-3\n    function invariant_T3_nobody_is_paid_for_a_rebate_it_was_not_in_range_for() public {}\n}\n' > "$TDP/test/Jit.t.sol"
td_run "$TDP" > "$TMP/o7109" 2>&1; check "threat-diff: the new threat turned into an invariant (/// @custom:threat T-3 in a test) - diffed" 0 $? "$TMP/o7109"
td_last "$TMP/o7109" "threat_model: diffed (2 matched, 1 new, 0 refused, 0 handed)"
grep -qF 'T-3  new - an invariant: test/Jit.t.sol:2 invariant_T3_nobody_is_paid_for_a_rebate_it_was_not_in_range_for()  | ' "$TDR" && echo "  ok    and the report names the test and its line" || { echo "  FAIL  the report does not name the test:"; sed "s/^/        | /" "$TDR"; fails=$((fails + 1)); }
# the same, with CRLF line ends in every file read: the same line
for f in "$TDP/.gauntlet/THREATS-independent.md" "$TDP/.gauntlet/THREATS.md" "$TDP/test/Jit.t.sol"; do sed 's/$/\r/' "$f" > "$f.crlf" && mv "$f.crlf" "$f"; done
td_run "$TDP" > "$TMP/o7110" 2>&1; check "threat-diff: the same files with CRLF line ends" 0 $? "$TMP/o7110"
td_last "$TMP/o7110" "threat_model: diffed (2 matched, 1 new, 0 refused, 0 handed)"
# ---- the forms: each near miss refused with its file and line, nothing written
td_bad() { # td_bad <n> <label> <the file under the project> <sed script on the fixture's own copy> <the words it must say>
  local n="$1" label="$2" f="$3" sc="$4" want="$5"
  td_proj; printf 'T-3: a JIT provider / the passive LPs'"'"' rebate / add, swap, remove\n' >> "$TDP/.gauntlet/THREATS-independent.md"
  printf 'contract JitInv {\n    /// @custom:threat T-3\n    function invariant_T3_jit() public {}\n}\n' > "$TDP/test/Jit.t.sol"
  sed "$sc" "$TDP/$f" > "$TDP/$f.new" && mv "$TDP/$f.new" "$TDP/$f"
  td_run "$TDP" > "$TMP/o$n" 2>&1; check "threat-diff: $label - refused" 2 $? "$TMP/o$n"
  td_has "$TMP/o$n" "$want"; td_norep "$label"
}
td_bad 7111 "a threat line written as a list item (- T-1: ...)" .gauntlet/THREATS-independent.md 's/^T-1: /- T-1: /' \
  "threat-diff: REFUSED - .gauntlet/THREATS-independent.md line 6: this line starts with a threat id and is not a threat line"
td_bad 7112 "a threat with two fields, not three" .gauntlet/THREATS-independent.md 's#^T-2: .*#T-2: a router / the refund#' \
  ".gauntlet/THREATS-independent.md line 7: T-2 has fewer than three fields: <who acts> / <what is lost> / <the call sequence>"
td_bad 7113 "a placeholder field (<who>)" .gauntlet/THREATS-independent.md 's#^T-2: a router#T-2: <who>#' \
  ".gauntlet/THREATS-independent.md line 7: T-2: who acts is empty or a placeholder (\"<who>\")"
td_bad 7114 "an id given twice" .gauntlet/THREATS-independent.md 's#^T-2: #T-1: #' \
  ".gauntlet/THREATS-independent.md line 7: T-1 is given twice (lines 6 and 7)"
td_bad 7115 "a walker's id in the independent list" .gauntlet/THREATS-independent.md 's#^T-2: #W-2: #' \
  "a walker's id (W-2) in the independent list"
td_bad 7116 "no model: line" .gauntlet/THREATS-independent.md '/^model:/d' \
  "threat-diff: REFUSED - .gauntlet/THREATS-independent.md: there is no model: line (the model that wrote this list)"
td_bad 7117 "a leading zero in an id (T-01)" .gauntlet/THREATS-independent.md 's#^T-1: #T-01: #' \
  ".gauntlet/THREATS-independent.md line 6: this line starts with a threat id and is not a threat line"
td_bad 7118 "a walker's threat with no matching line" .gauntlet/THREATS.md '/^matches: T-1$/d' \
  ".gauntlet/THREATS.md line 5: W-1 has no matching line: matches: T-<n>[, T-<n>...] or matches: new, right under it"
td_bad 7119 "a matching line in another shape (match: T-1)" .gauntlet/THREATS.md 's#^matches: T-1$#match: T-1#' \
  ".gauntlet/THREATS.md line 7: \"match: T-1\" is not a matching line: matches: T-<n>[, T-<n>...] or matches: new"
td_bad 7120 "a matching line outside a threat's block (after a blank line)" .gauntlet/THREATS.md 's#^matches: T-1$##; s#^from: doctrine/HOOK-ATTACKS.md class 3$#from: doctrine/HOOK-ATTACKS.md class 3\nnew\n\nmatches: T-1#' \
  "matches: outside a threat's block (a W- line and the lines right under it; a blank line ends it)"
td_bad 7121 "matches naming an id the independent list does not have" .gauntlet/THREATS.md 's#^matches: T-1$#matches: T-9#' \
  "threat-diff: REFUSED - .gauntlet/THREATS.md: W-1 matches T-9, and THREATS-independent.md has no T-9"
td_bad 7122 "a block with no from: line" .gauntlet/THREATS.md '/^from: doctrine\/HOOK-ATTACKS.md class 3$/d' \
  ".gauntlet/THREATS.md line 5: W-1 has no from: line"
td_bad 7123 "an independent id in the walker's list" .gauntlet/THREATS.md 's#^W-3: #T-3: #' \
  "an independent id (T-3) in the walker's list"
td_bad 7124 "@custom:threat in a // comment, not ///" test/Jit.t.sol 's#/// @custom:threat#// @custom:threat#' \
  "threat-diff: REFUSED - test/Jit.t.sol:2: @custom:threat is not on a line of its own of the form /// @custom:threat T-<n>[, T-<n>...]"
td_bad 7125 "a tag naming an id the independent list does not have" test/Jit.t.sol 's#@custom:threat T-3#@custom:threat T-9#; s#invariant_T3_jit#invariant_T9_jit#' \
  "threat-diff: REFUSED - test/Jit.t.sol:2 names T-9 (/// @custom:threat above invariant_T9_jit()), and THREATS-independent.md has no T-9"
td_bad 7126 "a tag in a file with no test or invariant function" test/Jit.t.sol 's#function invariant_T3_jit#function helper_jit#' \
  "threat-diff: REFUSED - test/Jit.t.sol:2: the tag is above helper_jit(), which is not a test or invariant function"
td_bad 7147 "the tag in the form solc does not build (/// @threat, not /// @custom:threat)" test/Jit.t.sol 's#/// @custom:threat#/// @threat#' \
  "threat-diff: REFUSED - test/Jit.t.sol:2: /// @threat does not compile (solc: \"Documentation tag @threat not valid for functions\" - a tag of your own is @custom:<name>): write /// @custom:threat T-<n>[, T-<n>...]"
td_proj; printf '## D-09 · 2026-10-06 · threat T-7 refused: no such threat\n' > "$TDP/.gauntlet/DECISIONS.md"
td_run "$TDP" > "$TMP/o7127" 2>&1; check "threat-diff: a refusal of an id the independent list does not have - refused" 2 $? "$TMP/o7127"
td_has "$TMP/o7127" "threat-diff: REFUSED - DECISIONS.md line 1 refuses T-7, and THREATS-independent.md has no T-7"
td_run > "$TMP/o7128" 2>&1; check "threat-diff: no argument - refused" 2 $? "$TMP/o7128"
td_run "$TD/nothing-here" > "$TMP/o7129" 2>&1; check "threat-diff: a directory that does not exist - refused" 2 $? "$TMP/o7129"
if [ -x "$HERE/threat-diff.sh" ] && [ "$(head -1 "$HERE/threat-diff.sh")" = '#!/usr/bin/env bash' ]; then echo "  ok    threat-diff.sh is executable, with its shebang"; else
  echo "  FAIL  threat-diff.sh is not executable or has no shebang"; fails=$((fails + 1)); fi
# ---- (v0.5) the tag as the brief writes it BUILDS where it goes: on its own line right above the test function. solc reads
# every `///` line as NatSpec and takes no tag of a project's own but @custom:<name> - `/// @threat` there breaks the build
# ("Documentation tag @threat not valid for functions", forge 1.8.1, solc 0.8.26). The form is the brief's own, read from it
TDTAG="$(grep -m 1 -oE '/// @[a-z:-]*threat T-<n>' "$HERE/../briefs/threat-model.md")"
if [ -z "$TDTAG" ]; then echo "  FAIL  briefs/threat-model.md gives no tag of the form /// @<tag> T-<n>"; fails=$((fails + 1))
elif command -v forge > /dev/null 2>&1; then
  td_proj; rm -f "$TDP/test/Inv.t.sol"; mkdir -p "$TDP/src"
  printf 'T-3: a JIT provider / the passive LPs'"'"' rebate / add, swap, remove\n' >> "$TDP/.gauntlet/THREATS-independent.md"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nout = "out"\nlibs = []\n' > "$TDP/foundry.toml"
  printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.26;\ncontract A { uint256 public x; }\n' > "$TDP/src/A.sol"
  td_sol() { printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.26;\ncontract JitInv {\n    %s\n    function invariant_T3_nobody_is_paid_for_a_rebate_it_was_not_in_range_for() public pure {}\n}\n' "$1" > "$TDP/test/Jit.t.sol"; }
  td_sol "${TDTAG/T-<n>/T-3}"
  (cd "$TDP" && forge build > "$TMP/o7184" 2>&1); check "forge builds a test whose invariant function carries the brief's tag right above it ($TDTAG)" 0 $? "$TMP/o7184"
  td_run "$TDP" > "$TMP/o7185" 2>&1; check "threat-diff: and reads that tag - T-3 new, an invariant" 0 $? "$TMP/o7185"
  td_last "$TMP/o7185" "threat_model: diffed (2 matched, 1 new, 0 refused, 0 handed)"
  td_sol '/// @threat T-3'; rm -rf "$TDP/out" "$TDP/cache"
  (cd "$TDP" && forge build > "$TMP/o7186" 2>&1); rc=$?
  if [ "$rc" != 0 ] && grep -qF 'Documentation tag @threat not valid for functions' "$TMP/o7186"; then
    echo "  ok    forge does not build /// @threat above the function (rc=$rc: Documentation tag @threat not valid for functions) - the form threat-diff.sh refuses"; else
    echo "  FAIL  forge built /// @threat above the function, or failed for another reason (rc=$rc):"; sed "s/^/        | /" "$TMP/o7186"; fails=$((fails + 1)); fi
  rm -rf "$TDP"
else
  echo "  SKIPPED - no forge here: the brief's tag is NOT proven to build on this machine"; skipped=1
fi
# ---- next.sh: phase 3's close (NEXT.md row 4b). A project whose phase 3 records are all there (the build, the tests,
# the census, an invariant suite, the fork note): only threat_model differs between the cases
td_proj; mkdir -p "$TDP/.gauntlet/reports"
cp "$FIX/build-real-compiled.txt" "$TDP/.gauntlet/reports/01-build.txt"; cp "$FIX/summary-real-many-suites.txt" "$TDP/.gauntlet/reports/02-test.txt"
printf 'the everyday campaign'"'"'s census\n' > "$TDP/.gauntlet/reports/06-census.txt"
td_state() { # td_state <sed script>: the fixture of row 14 (phase 4, the loop over), changed, as the project's STATE.md
  sed "$1" "$FIX/state-row-14.md" > "$TDP/.gauntlet/STATE.md"
}
TDJ="5=false,8=false,10=false,11b=false"
td_state 's/^threat_model: .*/threat_model:              not yet/'
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7130" 2>&1; check "next.sh: phase 4 with threat_model: not yet - refused (phase 3 is not closed)" 2 $? "$TMP/o7130"
TDPA="$(cd "$TDP" && pwd)"; TDK="$(cd "$HERE/.." && pwd)"
td_has "$TMP/o7130" "next: REFUSED - phase 4 claims phase 3 closed and the independent threat model is not diffed (threat_model: not yet): a fresh agent writes $TDPA/.gauntlet/THREATS-independent.md from $TDK/briefs/threat-model.md, then $TDK/scripts/threat-diff.sh $TDPA - or write the phase that is open"
td_state 's/^threat_model: .*/threat_model:              diffed (2 matched, 0 new, 0 refused, 0 handed)/'
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7131" 2>&1; check "next.sh: phase 4, the line these files give, and threat-diff.sh never ran (no report) - refused" 2 $? "$TMP/o7131"
td_has "$TMP/o7131" "next: REFUSED - phase 4 claims phase 3 closed, threat_model is diffed (2 matched, 0 new, 0 refused, 0 handed) and there is no .gauntlet/reports/06-threats.txt"
"$HERE/threat-diff.sh" "$TDP" > "$TMP/o7132" 2>&1
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7187" 2>&1; check "next.sh: phase 4, threat_model the line threat-diff.sh printed for these files - the row" 0 $? "$TMP/o7187"
[ "$(nx_rows "$TMP/o7187")" = "14,18" ] && echo "  ok    rows 14,18, as the fixture's" || { echo "  FAIL  not rows 14,18: $(nx_rows "$TMP/o7187")"; fails=$((fails + 1)); }
td_state "s/^threat_model: .*/$(tail -n 1 "$TMP/o7132")/"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7133" 2>&1; check "next.sh: the line threat-diff.sh printed, pasted as it is (one space after the colon) - the row" 0 $? "$TMP/o7133"
td_state 's/^threat_model: .*/threat_model:              diffed (2 matched, 1 new, 0 refused, 0 handed)/'
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7134" 2>&1; check "next.sh: diffed with counts the files do not give - refused" 2 $? "$TMP/o7134"
td_has "$TMP/o7134" "next: REFUSED - phase 4 claims phase 3 closed, threat_model is diffed (2 matched, 1 new, 0 refused, 0 handed) and the files give diffed (2 matched, 0 new, 0 refused, 0 handed): $TDK/scripts/threat-diff.sh $TDPA, then write the line it prints"
printf 'T-3: a JIT provider / the passive LPs'"'"' rebate / add, swap, remove\n' >> "$TDP/.gauntlet/THREATS-independent.md"
td_state 's/^threat_model: .*/threat_model:              diffed (2 matched, 0 new, 0 refused, 0 handed)/'
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7135" 2>&1; check "next.sh: phase 4, diffed, and an independent threat added since that nothing answers - refused, naming it" 2 $? "$TMP/o7135"
td_has "$TMP/o7135" "and 1 of 3 independent threats neither matched by the walker's list (matches: in .gauntlet/THREATS.md), turned into an invariant (/// @custom:threat T-<n> in a test) nor refused in DECISIONS.md (## <id> · <date> · threat T-<n> refused: <why>) nor handed on by name (T-<n>: handed: round | audit in .gauntlet/THREATS.md): T-3 (a JIT provider / the passive LPs' rebate / add, swap, remove)"
sed 's/^phase: .*/phase:                     3/' "$TDP/.gauntlet/STATE.md" > "$TDP/s" && mv "$TDP/s" "$TDP/.gauntlet/STATE.md"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7136" 2>&1; check "next.sh: phase 3, a diffed line the files do not bear out (T-3 unanswered) - refused too" 2 $? "$TMP/o7136"
td_has "$TMP/o7136" "next: REFUSED - threat_model is diffed (2 matched, 0 new, 0 refused, 0 handed) and 1 of 3 independent threats neither matched"
sed 's/^threat_model: .*/threat_model:              not yet/' "$TDP/.gauntlet/STATE.md" > "$TDP/s" && mv "$TDP/s" "$TDP/.gauntlet/STATE.md"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7137" 2>&1; check "next.sh: phase 3 with threat_model: not yet - row 4b, not a refusal" 0 $? "$TMP/o7137"
grep -q '^next: row 4b - ' "$TMP/o7137" && grep -qF 'scripts/threat-diff.sh <proj>' "$TMP/o7137" \
  && echo "  ok    row 4b, and its action names threat-diff.sh" || { echo "  FAIL  not row 4b naming threat-diff.sh:"; sed "s/^/        | /" "$TMP/o7137"; fails=$((fails + 1)); }
printf '## D-09 · 2026-10-06 · threat T-3 refused: the hook pays no rebate to whoever is in range\n' > "$TDP/.gauntlet/DECISIONS.md"
td_state 's/^threat_model: .*/threat_model:              diffed (2 matched, 0 new, 1 refused, 0 handed)/'
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7188" 2>&1; check "next.sh: phase 4, T-3 refused, diffed (2, 0, 1), the report of the diff before T-3 was added - refused: re-run" 2 $? "$TMP/o7188"
td_has "$TMP/o7188" "and .gauntlet/THREATS-independent.md is not the file threat-diff.sh diffed"
"$HERE/threat-diff.sh" "$TDP" > "$TMP/o7189" 2>&1; check "threat-diff.sh run again: T-3 refused in DECISIONS.md" 0 $? "$TMP/o7189"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7138" 2>&1; check "next.sh: phase 4, T-3 refused in the DECISIONS.md beside STATE.md, diffed (2, 0, 1), the diff re-run - the row" 0 $? "$TMP/o7138"
# (v0.5) the lists are frozen after the diff: an edit that leaves the counts as they were is still refused until the diff
# is run again - a walker's threat written after reading the other list, an independent threat reworded
cp "$TDP/.gauntlet/THREATS.md" "$TMP/td-w.md"; cp "$TDP/.gauntlet/THREATS-independent.md" "$TMP/td-i.md"
printf '\nW-9: a keeper / the last claimer'"'"'s fees / claim twice in one block\nfrom: SPEC.md section 3 row 4\nnew\n' >> "$TDP/.gauntlet/THREATS.md"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7190" 2>&1; check "next.sh: phase 4, diffed, a walker's threat added after the diff (the counts unchanged) - refused" 2 $? "$TMP/o7190"
td_has "$TMP/o7190" "next: REFUSED - phase 4 claims phase 3 closed, threat_model is diffed (2 matched, 0 new, 1 refused, 0 handed) and .gauntlet/THREATS.md is not the file threat-diff.sh diffed (sha256 "
td_has "$TMP/o7190" "the lists are frozen after the diff: re-run $TDK/scripts/threat-diff.sh $TDPA, then write the line it prints"
cp "$TMP/td-w.md" "$TDP/.gauntlet/THREATS.md"; sed 's/^T-1: a stranger /T-1: any stranger /' "$TMP/td-i.md" > "$TDP/.gauntlet/THREATS-independent.md"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7191" 2>&1; check "next.sh: phase 4, diffed, an independent threat reworded after the diff - refused" 2 $? "$TMP/o7191"
td_has "$TMP/o7191" "and .gauntlet/THREATS-independent.md is not the file threat-diff.sh diffed (sha256 "
cp "$TMP/td-i.md" "$TDP/.gauntlet/THREATS-independent.md"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7192" 2>&1; check "next.sh: the two lists as they were diffed - the row again" 0 $? "$TMP/o7192"
mv "$TDP/.gauntlet/reports/06-threats.txt" "$TMP/td-rep.txt"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7193" 2>&1; check "next.sh: phase 4, diffed, the diff's report gone - refused" 2 $? "$TMP/o7193"
td_has "$TMP/o7193" "and there is no .gauntlet/reports/06-threats.txt (the report threat-diff.sh writes, with the sha256 of the two lists it diffed): re-run $TDK/scripts/threat-diff.sh $TDPA"
grep -v '^the line for STATE.md' "$TMP/td-rep.txt" > "$TDP/.gauntlet/reports/06-threats.txt"; printf 'the line for STATE.md: threat_model: diffed (2 matched, 0 new, 0 refused, 0 handed)\n' >> "$TDP/.gauntlet/reports/06-threats.txt"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7194" 2>&1; check "next.sh: phase 4, a report whose line is not the STATE.md one - refused" 2 $? "$TMP/o7194"
td_has "$TMP/o7194" "and .gauntlet/reports/06-threats.txt does not give it (the line it gives: threat_model: diffed (2 matched, 0 new, 0 refused, 0 handed))"
mv "$TMP/td-rep.txt" "$TDP/.gauntlet/reports/06-threats.txt"
mv "$TDP/.gauntlet/THREATS.md" "$TDP/.gauntlet/THREATS.off"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7139" 2>&1; check "next.sh: phase 4, diffed, the walker's THREATS.md gone - refused" 2 $? "$TMP/o7139"
td_has "$TMP/o7139" "and there is no .gauntlet/THREATS.md - the walker's own list"
mv "$TDP/.gauntlet/THREATS.off" "$TDP/.gauntlet/THREATS.md"; sed -i.bak 's/^model:.*/model:/' "$TDP/.gauntlet/THREATS-independent.md"; rm -f "$TDP/.gauntlet/THREATS-independent.md.bak"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7140" 2>&1; check "next.sh: phase 4, diffed, the independent list not of its form (an empty model:) - refused, naming the line" 2 $? "$TMP/o7140"
td_has "$TMP/o7140" ".gauntlet/THREATS-independent.md line 3: model: is empty or a placeholder"
# the flag's own forms
td_tm() { # td_tm <n> <label> <the threat_model value> <the words of the refusal>
  td_state "s/^threat_model: .*/threat_model:              $3/"
  nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o$1" 2>&1; check "next.sh: $2 - refused" 2 $? "$TMP/o$1"
  td_has "$TMP/o$1" "$4"
}
td_tm 7141 "threat_model: done (not a value of the flag)" "done" "next: REFUSED - threat_model: 'done' is not one of: not yet | diffed (<n> matched, <m> new, <k> refused, <h> handed) - the line scripts/threat-diff.sh prints."
td_tm 7142 "threat_model: diffed with no counts" "diffed" "threat_model: 'diffed' is not one of: not yet | diffed (<n> matched"
td_tm 7143 "threat_model: diffed with the counts in another order" "diffed (0 new, 2 matched, 1 refused)" "threat_model: 'diffed (0 new, 2 matched, 1 refused)' is not one of"
td_tm 7144 "threat_model: diffed with words after it" "diffed (2 matched, 0 new, 1 refused, 0 handed) by the walker" "is not one of: not yet | diffed"
sed '/^threat_model:/d' "$FIX/state-row-14.md" > "$TDP/.gauntlet/STATE.md"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7145" 2>&1; check "next.sh: no threat_model: line - refused (a flag missing)" 2 $? "$TMP/o7145"
td_has "$TMP/o7145" "next: REFUSED - flag 'threat_model' is missing from the flag block (a STATE.md written before v0.5): add the line \"threat_model: not yet\" to the flag block"
td_state 's/^threat_model: .*/threat_model:              not yet (the independent agent is still writing)/'; sed -i.bak 's/^phase: .*/phase:                     3/' "$TDP/.gauntlet/STATE.md"; rm -f "$TDP/.gauntlet/STATE.md.bak"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7146" 2>&1; check "next.sh: phase 3, threat_model: not yet with a comment in parentheses - row 4b" 0 $? "$TMP/o7146"
grep -q '^next: row 4b - ' "$TMP/o7146" || { echo "  FAIL  not row 4b:"; sed "s/^/        | /" "$TMP/o7146"; fails=$((fails + 1)); }
# ---- the kit's example with the new flag in it: still known by its values; the flag counts among the non-generic lines
TDX="$HERE/../state/STATE.md"
grep -q '^threat_model:  *diffed (' "$TDX" && echo "  ok    the kit's example STATE.md carries a threat_model: diffed (...) line" || { echo "  FAIL  the kit's example has no threat_model line"; fails=$((fails + 1)); }
TDXF="next: FIRST - fill STATE.md: its values are still the kit's example's ($(LC_ALL=C awk '/^```/ { f = !f; next } f' "$TDX" | grep -m 1 '^bytecode_changed_since:'))"
rm -rf "$TD/x"; mkdir -p "$TD/x/.gauntlet"; sed '/Example file. The project is fictional/d; 1s/BlockCapHook/VolumeRewardsHook/' "$TDX" > "$TD/x/.gauntlet/STATE.md"
nx "$NX" "$TD/x/.gauntlet/STATE.md" > "$TMP/o7150" 2>&1; check "next.sh: the example unmarked and retitled, with its threat_model line - refused by its values" 2 $? "$TMP/o7150"
[ "$(cat "$TMP/o7150")" = "$TDXF" ] && echo "  ok    one line: ${TDXF:0:150}" || { echo "  FAIL  not the one line:"; sed "s/^/        | /" "$TMP/o7150"; fails=$((fails + 1)); }
td_with() { # td_with <flag> ...: a new project's STATE.md with those flags' lines the kit's example's, byte for byte
  local f l; rm -rf "$TD/x"; mkdir -p "$TD/x/.gauntlet"; cp "$FIX/state-new-project.md" "$TD/x/.gauntlet/STATE.md"
  for f in "$@"; do
    l="$(LC_ALL=C awk '/^```/ { b = !b; next } b' "$TDX" | grep -m 1 "^$f:")"
    LC_ALL=C awk -v f="$f" -v l="$l" 'index($0, f ":") == 1 { print l; next } { print }' "$TD/x/.gauntlet/STATE.md" > "$TD/x/s" && mv "$TD/x/s" "$TD/x/.gauntlet/STATE.md"
  done
}
td_with threat_model
nx "$NX" "$TD/x/.gauntlet/STATE.md" > "$TMP/o7151" 2>&1; check "next.sh: a new project sharing two of the example's non-generic lines (last_other_round: none, its threat_model) - not refused as the example" 2 $? "$TMP/o7151"
grep -q "values are still the kit's example's" "$TMP/o7151" && { echo "  FAIL  refused as the example with two lines shared:"; sed "s/^/        | /" "$TMP/o7151"; fails=$((fails + 1)); } \
  || echo "  ok    (refused for its own reason - a diffed line with no lists - not as the example)"
td_with threat_model notes
nx "$NX" "$TD/x/.gauntlet/STATE.md" > "$TMP/o7152" 2>&1; check "next.sh: three shared, the example's threat_model one of them - refused as the example" 2 $? "$TMP/o7152"
[ "$(cat "$TMP/o7152")" = "next: FIRST - fill STATE.md: its values are still the kit's example's ($(grep -m 1 '^last_other_round:' "$TDX"))" ] \
  && echo "  ok    the FIRST line, naming the first line shared" || { echo "  FAIL  not the FIRST line:"; sed "s/^/        | /" "$TMP/o7152"; fails=$((fails + 1)); }
grep -q "^## D-[0-9][0-9]* · [0-9-]* · threat T-[0-9][0-9]* refused: " "$HERE/../state/DECISIONS.md" \
  && echo "  ok    the kit's example DECISIONS.md shows a threat refused in the one-line form" || { echo "  FAIL  the example DECISIONS.md has no threat refused in the form"; fails=$((fails + 1)); }
# ---- the starting values carry it, and the doctrine names it
grep -q '^threat_model:  *not yet$' "$HERE/../state/README.md" && echo "  ok    state/README.md's starting values say threat_model: not yet" || { echo "  FAIL  state/README.md's starting values have no threat_model: not yet"; fails=$((fails + 1)); }
rm -rf "$TD/init"; mkdir -p "$TD/init"; "$HERE/init-state.sh" "$TD/init" > "$TMP/o7153" 2>&1; check "init-state.sh writes a new project's state" 0 $? "$TMP/o7153"
grep -q '^threat_model:  *not yet$' "$TD/init/.gauntlet/STATE.md" && echo "  ok    and its STATE.md says threat_model: not yet" || { echo "  FAIL  init-state's STATE.md has no threat_model: not yet"; fails=$((fails + 1)); }
grep -qF 'or the independent threat model not diffed (`threat_model: not yet`' "$NXT" && grep -q '^threat_model:  *not yet | diffed (<n> matched, <m> new, <k> refused, <h> handed)' "$NXT" \
  && echo "  ok    NEXT.md: row 4b names the threat model, and the flag block lists threat_model" || { echo "  FAIL  NEXT.md does not name it in row 4b and the flag block"; fails=$((fails + 1)); }
grep -qF 'T-<n>: <who acts> / <what is lost, and by whom> / <the call sequence>' "$HERE/../briefs/threat-model.md" && grep -qF '/// @custom:threat T-<n>' "$HERE/../briefs/threat-model.md" \
  && grep -qF 'threat T-<n>[, T-<n>...] refused: <why' "$HERE/../briefs/threat-model.md" \
  && echo "  ok    briefs/threat-model.md gives the three one-line forms the script reads" || { echo "  FAIL  briefs/threat-model.md does not give the forms"; fails=$((fails + 1)); }
# (v0.5) the battery skill, cut to stay under skills-check's size, still names MUTATION-TESTED's three conditions (row 6b)
grep -qF "three conditions make it MUTATION-TESTED: a FIX variant green in TWO" "$HERE/../skills/hook-gauntlet-battery/SKILL.md" \
  && echo "  ok    the battery skill names MUTATION-TESTED's three conditions, pointing at EVIDENCE.md section 2" || { echo "  FAIL  the battery skill does not name MUTATION-TESTED's three conditions"; fails=$((fails + 1)); }
# the independent agent's ROUND line records its model: round.sh knows the type
printf '# LOG - SomeHook\n' > "$TD/LOG.md"
"$HERE/round.sh" "$TD/LOG.md" --id tm1 --phase 3 --type threat-model --model "vendor-b/large" --bench /tmp/tm1 --dates 2026-10-06 \
  --high 0 --medium 0 --low 0 --info 0 --reasoned 0 --gate pass --report .gauntlet/THREATS-independent.md > "$TMP/o7154" 2>&1
check "round.sh writes a ROUND line of --type threat-model (the independent list's model on the record)" 0 $? "$TMP/o7154"
grep -q '^ROUND tm1 | phase 3 | threat-model | vendor-b/large | ' "$TD/LOG.md" && "$HERE/round.sh" --json "$TD/LOG.md" > "$TMP/o7155" 2>&1 \
  && echo "  ok    and --json reads it back" || { echo "  FAIL  the ROUND line is not there or not read back:"; sed "s/^/        | /" "$TD/LOG.md" "$TMP/o7155"; fails=$((fails + 1)); }
rm -rf "$TD"


# ================================================================= v0.5.1: what the first owner-present case taught the
# kit. (1) an independent threat the owner leaves undecided is handed on by name - `T-<n>: handed: round` (a target the
# round's brief lists) or `handed: audit` (untested) - counted by the diff, and after a round each `handed: round` is the
# finding it produced (`became:`) or `handed: audit`: next.sh refuses phase 4 while one is neither, never asking for a
# phase write-back; (2) a `@custom:threat` tag counts only above a test or invariant whose name carries the id, and the
# diff shows each pair; (3) mutate.sh says why a test failed - assertion, revert or setup - from real forge output (an
# expected revert that did not come, or came with another error, is an assertion); (4) the census gate keeps its attempts
# and says what was dropped or lowered since the first; (5) the owner's environment divergences reach the dossier rows'
# note; (6) `told: <date> <id>` quiets row 1 with the owner present; (7) a shallow depth is said; (8) `matches: new`.
echo "== v0.5.1: handed threats, the tag's fit shown, a kill's reason, the census gate's attempts, the owner's divergences, told: =="
TD="$TMP/tdh"; TDP="$TD/proj"; S51="$TMP/v51"; rm -rf "$TD" "$S51"; mkdir -p "$TD" "$S51"
TDR="$TDP/.gauntlet/reports/06-threats.txt"
v51_not() { # v51_not <file> <fixed string>: it must NOT say it
  if grep -qF -- "$2" "$1"; then echo "  FAIL  it says '${2:0:150}':"; sed "s/^/        | /" "$1"; fails=$((fails + 1)); else echo "  ok    and it does not say: ${2:0:150}"; fi
}
T3TXT="a JIT provider / the passive LPs' rebate / add, swap, remove"
v51_proj() { td_proj; printf 'T-3: %s\n' "$T3TXT" >> "$TDP/.gauntlet/THREATS-independent.md"; }   # T-3: nobody answers it yet
v51_after() { # v51_after <the line> <the line after it> <file>: the second line comes right after the first
  if awk -v a="$1" -v b="$2" 'p && $0 == b { ok = 1 } { p = ($0 == a) } END { exit !ok }' "$3"; then echo "  ok    and under '${1:0:80}': ${2:0:100}"; else
    echo "  FAIL  '${2:0:100}' is not right under '${1:0:80}':"; sed "s/^/        | /" "$3"; fails=$((fails + 1)); fi
}
# ---- (1) handed to the model round: diffed, counted, the target listed for the round's brief
v51_proj; printf '\nT-3: handed: round   (the owner left it undecided, 2026-10-07)\n' >> "$TDP/.gauntlet/THREATS.md"
td_run "$TDP" > "$TMP/o7501" 2>&1; check "threat-diff: an independent threat the owner left undecided, handed to the model round by name - diffed" 0 $? "$TMP/o7501"
td_last "$TMP/o7501" "threat_model: diffed (2 matched, 0 new, 0 refused, 1 handed)"
td_has "$TMP/o7501" "threat-diff: handed to the model round, its answer still to write after it (became: <finding id>, or handed: audit): T-3"
td_has "$TDR" "T-3  handed: round - a target of the model round, by name; after the round: became: <the finding's id> under it, or handed: audit  | $T3TXT"
v51_after "handed to the model round, by name - the round's brief lists each as a target (briefs/audit-round.md):" "  T-3: $T3TXT" "$TDR"
td_has "$TDR" "counts: 2 matched, 0 new (not in the walker's list, now an invariant), 0 refused, 1 handed, 0 unmatched - of 3"
# next.sh: phase 4, a round has run (the loop-over fixture), T-3 handed to it and not answered - refused, naming both answers
mkdir -p "$TDP/.gauntlet/reports"; cp "$FIX/build-real-compiled.txt" "$TDP/.gauntlet/reports/01-build.txt"; cp "$FIX/summary-real-many-suites.txt" "$TDP/.gauntlet/reports/02-test.txt"
printf 'the everyday campaign'"'"'s census\n' > "$TDP/.gauntlet/reports/06-census.txt"
TDPA="$(cd "$TDP" && pwd)"; TDK="$(cd "$HERE/.." && pwd)"; TDJ="5=false,8=false,10=false,11b=false"
td_state 's/^threat_model: .*/threat_model:              diffed (2 matched, 0 new, 0 refused, 1 handed)/'
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7502" 2>&1; check "next.sh: phase 4, round r04 has run, T-3 handed to it with no answer - refused" 2 $? "$TMP/o7502"
td_has "$TMP/o7502" "next: REFUSED - phase 4, round r04 has run, and the independent threat(s) handed to it have no answer: T-3 (T-<n>: handed: round in .gauntlet/THREATS.md). Under each handed line write became: <the finding's id> - the finding the round produced from it - or change it to handed: audit"
v51_not "$TMP/o7502" "write the phase that is open"
td_state 's/^threat_model: .*/threat_model:              diffed (2 matched, 0 new, 0 refused, 1 handed)/; s/^last_audit_round: .*/last_audit_round:          none/'
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7503" 2>&1; rc=$?
if [ "$rc" != 2 ] && ! grep -q 'have no answer' "$TMP/o7503"; then echo "  ok    next.sh: phase 4 with T-3 handed and no round run yet - not refused (rc=$rc): phase 3 closes with a handed threat"; else
  echo "  FAIL  next.sh refused phase 4 with T-3 handed before any round (rc=$rc):"; sed "s/^/        | /" "$TMP/o7503"; fails=$((fails + 1)); fi
# after the round: became: F-9 under it - the list changed, so the diff is run again; then the row
td_state 's/^threat_model: .*/threat_model:              diffed (2 matched, 0 new, 0 refused, 1 handed)/'
printf 'became: F-9   (the round turned it into a finding)\n' >> "$TDP/.gauntlet/THREATS.md"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7504" 2>&1; check "next.sh: became: F-9 written after the diff - refused until the diff runs again (the lists are frozen)" 2 $? "$TMP/o7504"
td_has "$TMP/o7504" "and .gauntlet/THREATS.md is not the file threat-diff.sh diffed"
td_run "$TDP" > "$TMP/o7505" 2>&1; check "threat-diff: T-3 handed to the round, became F-9 - diffed, the same counts" 0 $? "$TMP/o7505"
td_last "$TMP/o7505" "threat_model: diffed (2 matched, 0 new, 0 refused, 1 handed)"
td_has "$TDR" "T-3  handed: round - became F-9  | $T3TXT"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7506" 2>&1; check "next.sh: phase 4, T-3 became F-9, the diff re-run - the row, with no phase written back" 0 $? "$TMP/o7506"
[ "$(nx_rows "$TMP/o7506")" = "14,18" ] && echo "  ok    rows 14,18, as the fixture's" || { echo "  FAIL  not rows 14,18: $(nx_rows "$TMP/o7506")"; fails=$((fails + 1)); }
# handed to the human audit: diffed, untested, listed - and no became: owed after the round
cp "$FIX/threats-walker.md" "$TDP/.gauntlet/THREATS.md"; printf '\nT-3: handed: audit\n' >> "$TDP/.gauntlet/THREATS.md"
td_run "$TDP" > "$TMP/o7507" 2>&1; check "threat-diff: T-3 handed to the human audit by name - diffed" 0 $? "$TMP/o7507"
td_last "$TMP/o7507" "threat_model: diffed (2 matched, 0 new, 0 refused, 1 handed)"
td_has "$TDR" "T-3  handed: audit - to the human audit, by name: untested  | $T3TXT"
v51_after "handed to the human audit, by name - untested (the dossier's 5b and section 9 list each):" "  T-3: $T3TXT" "$TDR"
nx "$NX" "$TDP/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7508" 2>&1; check "next.sh: phase 4, a round has run, T-3 handed to the audit - the row (nothing owed)" 0 $? "$TMP/o7508"
# the forms: each near miss refused, naming it, nothing written
v51_bad() { # v51_bad <n> <label> <appended to THREATS.md, printf %b> <the words it must say>
  v51_proj; printf '%b' "$3" >> "$TDP/.gauntlet/THREATS.md"
  td_run "$TDP" > "$TMP/o$1" 2>&1; check "threat-diff: $2 - refused" 2 $? "$TMP/o$1"; td_has "$TMP/o$1" "$4"; td_norep "$2"
}
v51_bad 7510 "a handed line in another shape (handed: later)" '\nT-3: handed: later\n' \
  "an independent id (T-3) in the walker's list: the walker's ids are W-<n>, an independent threat is named in a matches: line - or, one the owner leaves undecided, on a line of its own: T-3: handed: round (aimed at the model round) or T-3: handed: audit (to the human audit, by name)"
v51_bad 7511 "became: under handed: audit" '\nT-3: handed: audit\nbecame: F-9\n' "T-3 is handed: audit, and has a became: line"
v51_bad 7512 "became: a placeholder (TBD)" '\nT-3: handed: round\nbecame: TBD\n' "T-3: became: \"TBD\" is not a finding's id"
v51_bad 7513 "a threat handed twice" '\nT-3: handed: round\n\nT-3: handed: audit\n' "T-3 is handed twice (lines 17 and 19)"
v51_bad 7514 "a matched threat handed too (T-1, matched by W-1)" '\nT-1: handed: round\n' "T-1 is handed (T-1: handed: round) and matched by W-1: one answer per threat"
v51_bad 7516 "handed: written inside a walker's block" 'handed: round\n' "W-3: \"handed: round\" - a walker's threat is matched or new (matches: T-<n>, or matches: new)"
v51_bad 7517 "a handed id the independent list does not have" '\nT-7: handed: audit\n' "T-7 is handed (T-7: handed: audit), and THREATS-independent.md has no T-7"
v51_bad 7518 "became: outside a handed threat's block" '\nbecame: F-2\n' "became: outside a handed threat's block"
v51_proj; printf '\nT-3: handed: round\n' >> "$TDP/.gauntlet/THREATS.md"; printf '## D-09 · 2026-10-06 · threat T-3 refused: the hook pays no rebate\n' > "$TDP/.gauntlet/DECISIONS.md"
td_run "$TDP" > "$TMP/o7515" 2>&1; check "threat-diff: a threat handed and refused in DECISIONS.md - refused" 2 $? "$TMP/o7515"
td_has "$TMP/o7515" "T-3 is handed (T-3: handed: round) and refused (DECISIONS.md line 1): one answer per threat"
# ---- (8) `matches: new` reads as bare `new`, and the brief shows it
td_proj; sed 's/^new$/matches: new/' "$FIX/threats-walker.md" > "$TDP/.gauntlet/THREATS.md"
td_run "$TDP" > "$TMP/o7519" 2>&1; check "threat-diff: matches: new, as the walker read the brief - the walker's own threat" 0 $? "$TMP/o7519"
td_last "$TMP/o7519" "threat_model: diffed (2 matched, 0 new, 0 refused, 0 handed)"
td_has "$TDR" "W-3  the walker's own (new)  | the owner's key / every LP's fees / setFee above the cap, then a swap"
td_has "$HERE/../briefs/threat-model.md" "matches: new"
# ---- (2) the tag's fit: only above a test or invariant whose name carries the id; each pair shown
v51_tag() { # v51_tag <n> <label> <rc> <the tag line> <the line under it> <words>
  v51_proj; printf 'contract JitInv {\n    %s\n    %b\n}\n' "$4" "$5" > "$TDP/test/Jit.t.sol"
  td_run "$TDP" > "$TMP/o$1" 2>&1; check "threat-diff: $2" "$3" $? "$TMP/o$1"; td_has "$TMP/o$1" "$6"
}
v51_tag 7520 "a tag above an invariant whose name does not carry the id - refused" 2 '/// @custom:threat T-3' 'function invariant_jit() public {}' \
  "threat-diff: REFUSED - test/Jit.t.sol:2: invariant_jit() names T-3 in its tag and does not carry T3 in its name: a tag is accepted only on a test or invariant whose name carries the id - invariant_T3_<what it keeps>"
v51_tag 7521 "a tag above invariant_T3_jit() - diffed, the pair shown" 0 '/// @custom:threat T-3' 'function invariant_T3_jit() public {}' \
  "threat-diff: pair T-3: $T3TXT <- invariant_T3_jit() - test/Jit.t.sol:2"
td_last "$TMP/o7521" "threat_model: diffed (2 matched, 1 new, 0 refused, 0 handed)"
v51_after "the pairs - each independent threat a test names, beside that test (a script cannot judge the fit; a reader can):" "  T-3: $T3TXT <- invariant_T3_jit() - test/Jit.t.sol:2" "$TDR"
v51_tag 7522 "a tag naming two ids above a name that carries one - refused" 2 '/// @custom:threat T-1, T-3' 'function invariant_T3_jit() public {}' \
  "invariant_T3_jit() names T-1 in its tag and does not carry T1 in its name"
v51_tag 7523 "a tag above a state variable, not a function - refused" 2 '/// @custom:threat T-3' 'uint256 internal jit;' \
  "threat-diff: REFUSED - test/Jit.t.sol:2: the tag is not right above a function"
v51_tag 7524 "a name with T30, not T3 - refused" 2 '/// @custom:threat T-3' 'function test_T30_jit() public {}' "test_T30_jit() names T-3 in its tag and does not carry T3 in its name"
v51_tag 7525 "a tag, another NatSpec line and a blank line, then test_jit_T3() - diffed" 0 '/// @custom:threat T-3' '/// @notice the rebate goes to those in range\n\n    function test_jit_T3() public {}' \
  "threat-diff: pair T-3: $T3TXT <- test_jit_T3() - test/Jit.t.sol:2"
td_has "$HERE/../briefs/handoff-dossier.md" "the pairs"
# ---- (3) a kill's reason, from real forge 1.8.1 output: assertion (the two expected-revert forms too), revert, setup
v51_kr() { # v51_kr <n> <fixture> <the reasons, one word per failing test in forge's order>
  local got; got="$(kill_reasons "$FIX/$2" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
  if [ "$got" = "$3" ]; then echo "  ok    kill_reasons $2: $got"; else echo "  FAIL  kill_reasons $2: '$got', not '$3':"; kill_reasons "$FIX/$2" | sed "s/^/        | /"; fails=$((fails + 1)); fi
}
v51_kr 7530 kill-real-assertion.txt "assertion assertion assertion assertion assertion assertion assertion"
kill_reasons "$FIX/kill-real-assertion.txt" > "$TMP/o7531" 2>&1
td_has "$TMP/o7531" "$(printf 'assertion\ttest_expectRevert_not_met()\tnext call did not revert as expected')"
td_has "$TMP/o7531" "$(printf 'assertion\ttest_expectRevert_wrong_error()\tError != expected error: the pool is locked != CurrencyNotSettled()')"
td_has "$TMP/o7531" "$(printf 'assertion\tinvariant_x_is_odd_or_zero()\tx is odd or zero')"
v51_kr 7532 kill-real-revert.txt "revert revert revert revert revert revert"
kill_reasons "$FIX/kill-real-revert.txt" > "$TMP/o7533" 2>&1
td_has "$TMP/o7533" "$(printf 'revert\ttest_custom_error()\tCurrencyNotSettled()')"
td_has "$TMP/o7533" "$(printf 'revert\tinvariant_no_unexplained_reverts()\tthe handler met a failure it did not predict')"
td_has "$TMP/o7533" "$(printf 'revert\tinvariant_settles()\tCurrencyNotSettled()')"
v51_kr 7534 kill-real-setup.txt "setup"
kill_reasons "$FIX/summary-real-many-suites.txt" > "$TMP/o7535" 2>&1; check "kill_reasons: a log with no failing test reads nothing" 1 $? "$TMP/o7535"
if command -v forge > /dev/null 2>&1 && [ -e "$HERE/../foundry-kit/lib" ]; then
  MKR="$S51/mk"; mkdir -p "$MKR/src" "$MKR/test" "$MKR/.gauntlet"; ln -s "$(cd "$HERE/../foundry-kit/lib" && pwd -P)" "$MKR/lib"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n' > "$MKR/foundry.toml"
  printf 'pragma solidity ^0.8.26;\ncontract B { uint256 public x; function set() external { x = 1; } }\n' > "$MKR/src/B.sol"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/B.sol";\ncontract BUnit is Test { B b; function setUp() public { b = new B(); } function test_set() public { b.set(); assertEq(b.x(), 1); } }\n' > "$MKR/test/B.t.sol"
  LABEL=kra OUT_DIR="$S51/mut" "$HERE/mutate.sh" "$MKR" src/B.sol "x = 1;" "x = 2;" > "$TMP/o7536" 2>&1; check "mutate.sh: a mutant the test's assertEq kills - KILLED" 0 $? "$TMP/o7536"
  td_has "$TMP/o7536" 'kill: assertion - test_set() ("assertion failed: 2 != 1")'
  td_has "$S51/mut/kra.txt" "kill reasons: 1 assertion, 0 revert, 0 setup"
  LABEL=krr OUT_DIR="$S51/mut" "$HERE/mutate.sh" "$MKR" src/B.sol "x = 1;" "revert();" > "$TMP/o7537" 2>&1; check "mutate.sh: a mutant that makes the code revert - KILLED (revert), exit 0 still" 0 $? "$TMP/o7537"
  td_has "$TMP/o7537" "KILLED (revert) - 1 test(s) went red on the mutant"
  td_has "$TMP/o7537" "This kill does not count toward MUTATION-TESTED (doctrine/EVIDENCE.md section 2)"
  td_has "$S51/mut/krr.txt" 'kill: revert - test_set() ("EvmError: Revert")'
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/B.sol";\ncontract SetUpDep is Test { B b; function setUp() public { b = new B(); b.set(); require(b.x() == 1, "setUp depends on set"); } function test_x() public { assertEq(b.x(), 1); } }\n' > "$MKR/test/SetUpDep.t.sol"
  LABEL=krs OUT_DIR="$S51/mut" "$HERE/mutate.sh" "$MKR" src/B.sol "x = 1;" "x = 3;" > "$TMP/o7538" 2>&1; check "mutate.sh: a mutant that breaks setUp() - NOTHING PROVEN, its reason said" 2 $? "$TMP/o7538"
  td_has "$TMP/o7538" 'kill: setup - setUp() ("setUp depends on set")'
else
  echo "  SKIPPED - no forge or no kit lib/ here: mutate.sh's kill lines are NOT proven on this machine"; skipped=1
fi
td_has "$HERE/../doctrine/EVIDENCE.md" "KILLED (revert)"
td_has "$HERE/../briefs/handoff-dossier.md" "KILLED (revert)"
# ---- (4) the census gate remembers its attempts, and says what was dropped or lowered since the first
CN="$S51/cen"; mkdir -p "$CN/.gauntlet" "$CN/census"
for i in 1 2 3 4; do printf 'Inv\tU=0\tA:swap=3/2\tB:fee at the cap=1\tB:a later swap paid a fee=1\n'; done > "$CN/census/long.tsv"
CA="$CN/.gauntlet/reports/03-census-attempts.txt"; CG="$CN/.gauntlet/reports/06-census-gate.txt"
CORE="swap" REACH="fee at the cap;a later swap paid a fee" MIN_PCT=25 "$HERE/census.sh" --aggregate "$CN/census/long.tsv" "$CN" > "$TMP/o7540" 2>&1
check "census gate: a first attempt - PASSED" 0 $? "$TMP/o7540"
td_has "$TMP/o7540" "attempts: the first attempt of this gate"
[ "$(grep -vc '^#' "$CA" 2> /dev/null)" = 1 ] && grep -qF "$(printf '\tMIN_PCT=25\tCORE=swap\tREACH=fee at the cap;a later swap paid a fee\tresult=PASSED\tcensus=')" "$CA" \
  && echo "  ok    03-census-attempts.txt: one attempt, with its date, MIN_PCT, CORE, REACH and result" || { echo "  FAIL  03-census-attempts.txt is not one attempt of that form:"; sed "s/^/        | /" "$CA" 2> /dev/null; fails=$((fails + 1)); }
CORE="swap" REACH="fee at the cap" MIN_PCT=20 "$HERE/census.sh" --aggregate "$CN/census/long.tsv" "$CN" > "$TMP/o7541" 2>&1
check "census gate: a second attempt, a REACH boundary dropped and the floor lowered - PASSED, and said" 0 $? "$TMP/o7541"
td_has "$CG" "attempts: this is attempt 2 of this gate (03-census-attempts.txt; the first: "
td_has "$CG" "dropped or lowered: REACH \"a later swap paid a fee\" dropped; MIN_PCT lowered 25 -> 20"
td_has "$TMP/o7541" "REACH \"a later swap paid a fee\" dropped"
REACH="fee at the cap" MIN_PCT=25 "$HERE/census.sh" --aggregate "$CN/census/long.tsv" "$CN" > "$TMP/o7542" 2>&1
check "census gate: a third attempt, the CORE action gone too" 0 $? "$TMP/o7542"
td_has "$CG" "dropped or lowered: CORE \"swap\" dropped; REACH \"a later swap paid a fee\" dropped"
[ "$(grep -vc '^#' "$CA")" = 3 ] && echo "  ok    and three attempts kept" || { echo "  FAIL  not three attempts kept:"; sed "s/^/        | /" "$CA"; fails=$((fails + 1)); }
td_has "$HERE/../briefs/handoff-dossier.md" "03-census-attempts.txt"
# ---- (5) the owner's environment divergences: asked in the interview, carried to the dossier rows' note
td_has "$HERE/../briefs/owner-interview.md" "17c. Is anything in this project's environment not as it ships: pinned dependencies swapped, remappings, a renamed type?"
td_has "$HERE/../briefs/owner-interview.md" "divergence: <what>"
td_has "$HERE/../briefs/handoff-dossier.md" "environment divergences stated by the owner"
DV="$S51/dv"; mkdir -p "$DV"; cp -r "$NXFIX/.gauntlet" "$NXFIX/test" "$DV/"; cp "$FIX/state-row-18.md" "$DV/.gauntlet/STATE.md"
nx "$NX" "$DV/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7550" 2>&1; check "next.sh: row 18 (the dossier), no divergence in DECISIONS.md" 0 $? "$TMP/o7550"
td_has "$TMP/o7550" 'next: note - environment divergences stated by the owner (DECISIONS.md, ## <id> · <date> · divergence: <what>): none stated - the dossier'"'"'s section 8 row "environment divergences stated by the owner" says "none stated"'
printf '# DECISIONS - SomeHook\n\n## D-12 · 2026-10-07 · divergence: v4-core pinned at another commit than the one the project ships with\n\nsource: owner\n\n## D-13 - 2026-10-07 - divergence: a renamed type\n' > "$DV/.gauntlet/DECISIONS.md"
nx "$NX" "$DV/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7551" 2>&1; check "next.sh: row 18, a divergence the owner stated - in the note" 0 $? "$TMP/o7551"
td_has "$TMP/o7551" "): D-12 (2026-10-07): v4-core pinned at another commit than the one the project ships with - the dossier's section 8 row"
td_has "$TMP/o7551" "next: note - DECISIONS.md line(s) 7 name a divergence in another shape than ## <id> · <YYYY-MM-DD> · divergence: <what>, and are not read"
[ "$(nx_rows "$TMP/o7551")" = "14,18" ] && echo "  ok    rows 14,18, as the fixture's" || { echo "  FAIL  not rows 14,18: $(nx_rows "$TMP/o7551")"; fails=$((fails + 1)); }
sed 's/^phase: .*/phase:                     3/' "$FIX/state-row-18.md" > "$DV/.gauntlet/STATE.md"
nx "$NX" "$DV/.gauntlet/STATE.md" --judge "$TDJ" > "$TMP/o7552" 2>&1
v51_not "$TMP/o7552" "environment divergences stated by the owner"
# ---- (6) told: <date> <id> quiets row 1, the owner present (the variants beside the fixtures' records, in $NXFIX)
v51_nx() { # v51_nx <n> <label> <fixture> <sed script> <judge|-> <rc> <rows>: nx_variant's case, written in $NXFIX
  local n="$1" label="$2" fx="$3" sc="$4" j="$5" wrc="$6" want="$7"; local -a a=()
  sed "$sc" "$NXFIX/$fx" > "$NXFIX/state-v51-$n.md"; [ "$j" = "-" ] || a=(--judge "$j")
  nx "$NX" "$NXFIX/state-v51-$n.md" "${a[@]}" > "$TMP/o$n" 2>&1; check "next.sh: $label" "$wrc" $? "$TMP/o$n"
  [ "$(nx_rows "$TMP/o$n")" = "$want" ] || { echo "  FAIL  and it named rows '$(nx_rows "$TMP/o$n")', not '$want'"; sed "s/^/        | /" "$TMP/o$n"; fails=$((fails + 1)); }
  rm -f "$NXFIX/state-v51-$n.md"
}
v51_nx 7560 "a note told: 2026-10-07 F-1 quiets row 1, the owner present: row 9" state-row-1.md \
  's/^notes: .*/notes: fork: n\/a - no chain yet; told: 2026-10-07 F-1 - with its test, in the chat/' 5=false,8=false,9=true 0 9
td_has "$TMP/o7560" "row 1 is quiet: the 1 high open is told to the owner (notes: told: F-1 on 2026-10-07)"
v51_nx 7561 "a told: note on an indented line, as a list item - read the same" state-row-1.md \
  's/^notes: .*/notes: fork: n\/a - no chain yet\n  - told: 2026-10-07 F-1/' 5=false,8=false,9=true 0 9
v51_nx 7562 "told: with a date that is not one (2026-02-30) - refused" state-row-1.md 's/^notes: .*/notes: told: 2026-02-30 F-1/' 5=false,8=false,9=true 2 ""
td_has "$TMP/o7562" "2026-02-30 is not a real date (told: <YYYY-MM-DD> <id>[, <id>...]"
v51_nx 7563 "told: naming a finding that is not an open high - refused" state-row-1.md 's/^notes: .*/notes: told: 2026-10-07 F-9/' 5=false,8=false,9=true 2 ""
td_has "$TMP/o7563" "notes: told: 2026-10-07 'F-9' - it is not an open high in open_findings"
v51_nx 7564 "told: with a date and no id - refused" state-row-1.md 's/^notes: .*/notes: told: 2026-10-07 by mail/' 5=false,8=false,9=true 2 ""
td_has "$TMP/o7564" "names no finding id after its date"
td_has "$HERE/../state/README.md" "told: <YYYY-MM-DD> <id>[, <id>...]"
# ---- (7) a shallow depth is said, with the number - never changed
k42_kit "$S51/sd/lib/hook-gauntlet"; mkdir -p "$S51/sd/own"; printf '%s\n' '[profile.default]' 'src = "src"' '' '[invariant]' 'runs = 64' 'depth = 8' 'fail_on_revert = true' > "$S51/sd/own/foundry.toml"
k42_run "$TMP/o7570" "$SD" --dry-run "$S51/sd/own"; check "setup-deps.sh --dry-run on an everyday depth of 8" 0 $? "$TMP/o7570"
td_has "$TMP/o7570" "setup-deps: WARNING - your [invariant] depth is 8, below the kit's default 64 (QUICKSTART.md 7b, the everyday campaign): call sequences longer than 8 are never tried - left as it is, yours to raise; the [profile.long.invariant] written here keeps it (depth = 8, below the kit's long default 128)"
if command -v forge > /dev/null 2>&1; then
  FLD="$S51/fl"; mkdir -p "$FLD/src" "$FLD/.gauntlet"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\n[invariant]\nruns = 4\ndepth = 4\n[profile.long.invariant]\nruns = 64\ndepth = 8\n' > "$FLD/foundry.toml"
  ESTIMATE_ONLY=1 "$HERE/fuzz-long.sh" "$FLD" > "$TMP/o7571" 2>&1; check "fuzz-long.sh ESTIMATE_ONLY=1 on a long depth of 8" 0 $? "$TMP/o7571"
  td_has "$TMP/o7571" "fuzz-long: WARNING - this campaign's depth is 8, below the kit's default 128 for the long campaign (the everyday one here: 4)"
fi
rm -rf "$TD" "$S51"

echo
echo "selftest ran in $((SECONDS - started)) s"
if [ "$fails" -eq 0 ] && [ "$skipped" -eq 1 ]; then
  echo "SELFTEST INCOMPLETE: what ran behaved, but a section was SKIPPED. Install forge and the kit's lib/, and run it again."
  exit 3
fi
if [ "$fails" -eq 0 ]; then
  # K31: the marker next.sh reads before any row - written only here, for the scripts this run proved, and seen honoured
  # by next.sh as a user runs it (no NEXT_SELFTEST: the start of this run removed it, and nx sets it per call only)
  selftest_hash1="$(kit_scripts_sha256 "$SELFTEST_KIT")"
  if [ "$selftest_hash1" != "$selftest_hash0" ]; then
    echo "SELFTEST FAILED: the kit's scripts changed while it ran (sha256 $selftest_hash0 at the start, $selftest_hash1 at the end): what passed is not what is there. No marker written."
    exit 1
  fi
  if ! selftest_marker_write "$SELFTEST_KIT" "$selftest_hash1"; then
    rm -f "$SELFTEST_MARKER"
    echo "SELFTEST FAILED: every case behaved, and the marker $SELFTEST_MARKER could not be written (or no machine identity, or no forge version, to write in it): next.sh will not name a row."
    exit 1
  fi
  "$HERE/next.sh" "$FIX/state-new-project.md" > "$TMP/o-marker" 2>&1; rc=$?
  if [ "$rc" != 0 ] || ! grep -q '^next: row 4 - ' "$TMP/o-marker" || grep -qE 'FIRST|NEXT_SELFTEST' "$TMP/o-marker"; then
    rm -f "$SELFTEST_MARKER"
    echo "SELFTEST FAILED: every case behaved, and next.sh did not honour the marker written for these scripts (rc=$rc; marker removed):"
    sed "s/^/          | /" "$TMP/o-marker"
    exit 1
  fi
  echo "selftest: marker written - $SELFTEST_MARKER: scripts sha256 $selftest_hash1, machine $(sed -n 's/^machine_sha256: //p' "$SELFTEST_MARKER"), $(sed -n 's/^date: //p' "$SELFTEST_MARKER"), $(sed -n 's/^forge: //p' "$SELFTEST_MARKER")"
  echo "selftest: next.sh honours it - on a new project's STATE.md it names $(awk -F' - ' '/^next: row / { sub(/^next: /, "", $1); print $1; exit }' "$TMP/o-marker"), not FIRST"
  echo "SELFTEST PASSED: every guard went red exactly where it was supposed to."
  exit 0
fi
echo "SELFTEST FAILED: $fails case(s) did not behave as declared."
exit 1
