# shellcheck shell=bash
#
# forge-env.sh - the environment forge runs under in the kit's four judging scripts (battery.sh, fuzz-long.sh, census.sh
# in run mode, mutate.sh): by an ALLOWLIST, never by a list of the dangerous names.
#
# The problem it solves: forge takes its configuration from the ENVIRONMENT as well as from foundry.toml - every key, under
# FOUNDRY_ and under dapptools' DAPP_, in any case (`foundry_match_contract` works, and so does a dotted
# `FOUNDRY_FUZZ.RUNS`) - and some of its flags under FORGE_ (`FORGE_ALLOW_FAILURE`: forge exits 0 over a failed test). A
# variable exported for another command narrows or weakens the run, and the verdict says nothing. Measured (forge 1.8.1,
# 2026-09-27, the root kit's 107 tests): BATTERY PASSED on 5 tests (`foundry_match_contract`, `DAPP_MATCH_CONTRACT`), on 21
# (`FOUNDRY_TEST`, `FOUNDRY_CONFIG`), on 86 (`FOUNDRY_SKIP`), with invariants that ran no sequence
# (`FOUNDRY_INVARIANT_RUNS=0`), and on "passed 107, failed 1" (`FORGE_ALLOW_FAILURE=true`). A list of six names was the
# first fix, and it missed every one of those. So every variable whose name, upper-cased, starts with FOUNDRY_, FORGE_ or
# DAPP_ is removed, except the names the calling script allows (exact spelling: `foundry_profile` is removed, forge reads
# it too); each removed one is named in a line - the NAME, never the value - and each allowed one that is set is named
# with its value (FORGE_FLAGS through forge_flags_shown: never the value of a flag that carries an endpoint or a key).
# What a script sets itself (the corpus directory for V4_MANAGER, the long profile's budget) it sets after this, so it
# is its own and never inherited.
#
# Left alone, because they select no test and fail none (measured the same day): ETH_RPC_URL (`forge test` does not fork
# on it - FOUNDRY_ETH_RPC_URL does, and is removed), ETH_FROM, ETHERSCAN_API_KEY, ETH_RPC_TIMEOUT, NO_COLOR, RUST_LOG (more
# lines in the log, not other results). Not the environment, and not removable from here - so named, below: a `.env`
# where forge runs (forge loads it: forge_dotenv_check), ~/.foundry/foundry.toml, forge's global configuration, which
# forge merges with the project's (forge_global_config), a build cache written at another path (forge_cache_elsewhere),
# and a source changed where forge's incremental build does not follow it (forge_sources_stale: the kit's own record).

# forge_env_clean <tag> "<allowed names, space separated>" <script> [the script's arguments...]
#   removes the variables above and RE-RUNS the script without them (exec: the same process, the same id). A re-run,
#   not `unset`: bash cannot unset a name that is not a shell identifier (`FOUNDRY_FUZZ.RUNS`), and forge reads it.
#   Returns only when nothing is left to remove. Call it before the script changes directory or writes anything.
forge_env_clean() {
  local tag="$1" allowed=" $2 " script="$3" kv name n
  local -a drop=() args=()
  shift 3
  case "$allowed" in *" FORGE_FLAGS "*) forge_flags_one_line "$tag" || exit 2 ;; esac
  if env -0 > /dev/null 2>&1; then
    while IFS= read -r -d '' kv; do
      name="${kv%%=*}"
      case "$name" in [Ff][Oo][Uu][Nn][Dd][Rr][Yy]_* | [Ff][Oo][Rr][Gg][Ee]_* | [Dd][Aa][Pp][Pp]_*) ;; *) continue ;; esac
      case "$allowed" in *" $name "*) continue ;; esac
      drop+=("$name")
    done < <(env -0)
  else
    # an `env` without -0: the shell's own list, which cannot show a name that is not an identifier - said, not hidden
    echo "$tag: this system's env cannot list the environment (no -0): only variables with shell names are checked"
    while IFS= read -r name; do
      case "$name" in [Ff][Oo][Uu][Nn][Dd][Rr][Yy]_* | [Ff][Oo][Rr][Gg][Ee]_* | [Dd][Aa][Pp][Pp]_*) ;; *) continue ;; esac
      case "$allowed" in *" $name "*) continue ;; esac
      drop+=("$name")
    done < <(compgen -e)
  fi
  if [ "${#drop[@]}" -gt 0 ]; then
    if [ "${_GAUNTLET_ENV_PID:-}" = "$$" ]; then
      echo "$tag: ${drop[*]} still in the environment after the re-run that removed it. NOTHING RUN."; exit 2
    fi
    for n in "${drop[@]}"; do printf '%s: ignoring %s from the environment\n' "$tag" "$n"; args+=(-u "$n"); done
    exec env "${args[@]}" _GAUNTLET_ENV_PID="$$" "$BASH" "$script" "$@"
  fi
  for n in $allowed; do
    if [ -n "${!n:-}" ]; then printf '%s: %s=%s from the environment (allowed)\n' "$tag" "$n" "$(forge_flags_shown "${!n}")"; fi
  done
  return 0
}

# forge_flags_one_line <tag>
#   FORGE_FLAGS with a line break (LF, or a CR) is refused: forge gets every line (a line break splits flags like a
#   space), and whatever prints the value - a verdict, a log's header - showed its first line only, so a filter on the
#   second narrowed the run unseen (V25, 2026-09-27: `--offline` + newline + `--match-test <one invariant>` -> fuzz-long.sh
#   "long fuzz passed (...; FORGE_FLAGS: --offline)" over 1 invariant of 6). No flag needs one. One line names the
#   variable, never its value; returns 1, and the caller exits 2. Every script that reads FORGE_FLAGS calls it first.
forge_flags_one_line() {
  case "${FORGE_FLAGS:-}" in
    *$'\n'* | *$'\r'*)
      echo "$1: FORGE_FLAGS holds a line break - forge would get every line, a printed line would show the first only, and no flag needs one: refused (the value is not printed). NOTHING RUN."
      return 1 ;;
  esac
  return 0
}

# forge_flags_shown <flags>: the flags as they are printed - in the lines above, in a verdict, in a log's header, in a
#   forge command line a script echoes. A value is hidden by its SHAPE, not by the spelling of the flag before it: forge
#   (clap) takes grouped short flags (`-vr <url>`, `-sr <url>`, `-vr<url>` are all `--rpc-url`), and a list of flag names
#   missed them (V25, 2026-09-27). Printed as <set>: every word that holds `://` (an endpoint carries its key in the URL),
#   every word that is 0x and 64 hex digits (a private key's shape), the word after --fork-url, --rpc-url,
#   --etherscan-api-key or --private-key, and the value of a short-flag group that holds an r - the word after it when
#   the r ends the group (`-r`, `-vr`, `-vvvr`), the rest of the group when it does not (`-vrmainnet` -> `-vr<set>`). A
#   `--flag=value` keeps its flag name. Everything else is printed as it is: a filter in FORGE_FLAGS narrows the run, and
#   has to be seen. Words are split on spaces, tabs and line breaks, as forge gets them.
forge_flags_shown() {
  local w v out="" hide=0 grp
  local -a words=()
  read -r -d '' -a words <<< "$1" || :
  for w in ${words[@]+"${words[@]}"}; do
    if [ "$hide" = 1 ]; then out="$out <set>"; hide=0; continue; fi
    case "$w" in
      --fork-url=* | --rpc-url=* | --etherscan-api-key=* | --private-key=*) w="${w%%=*}=<set>" ;;
      --fork-url | --rpc-url | --etherscan-api-key | --private-key) hide=1 ;;
      --*=*)
        v="${w#*=}"
        case "$v" in *://*) w="${w%%=*}=<set>" ;; esac
        [[ "$v" =~ ^0[xX][0-9a-fA-F]{64}$ ]] && w="${w%%=*}=<set>" ;;
      --*) ;;
      -*r*)
        grp="${w#-}"
        if [ -z "${grp#*r}" ]; then hide=1; else w="-${grp%%r*}r<set>"; fi ;;
    esac
    case "$w" in *://*) w="<set>" ;; esac
    [[ "$w" =~ ^0[xX][0-9a-fA-F]{64}$ ]] && w="<set>"
    out="$out $w"
  done
  printf '%s\n' "${out# }"
}

# forge_dotenv_check <tag> <dir>
#   forge loads <dir>/.env into its own environment at start (its project root's and its working directory's; the kit's
#   scripts run forge where foundry.toml is, so both are <dir>), without overriding what is already set, and a FOUNDRY_,
#   FORGE_ or DAPP_ name there acts like one exported: measured (forge 1.8.1), FOUNDRY_MATCH_CONTRACT in it ran 5 tests of
#   107, FORGE_ALLOW_FAILURE=true exited 0 over a failed test. It is the project's file, never edited from here: each such
#   name is named (never its value), and the caller refuses to run. Returns 1 when there is one.
#   Keys are read the way forge reads them, not the way a strict parser would: a UTF-8 byte-order mark before the first
#   one (what Notepad and other Windows editors write) is stripped, and so are CR line ends, a leading `export ` and the
#   space around `=`; the prefix is compared in any case. The mark was missed once, and forge read the key behind it
#   (V24b, 2026-09-27: `.env` = BOM + FOUNDRY_MATCH_CONTRACT, BATTERY PASSED on 5 tests of 107).
forge_dotenv_check() {
  local tag="$1" f="$2/.env" names n bom
  [ -f "$f" ] || return 0
  bom="$(printf '\357\273\277')"
  names="$(LC_ALL=C tr -d '\r' < "$f" | LC_ALL=C sed -e "1s/^$bom//" \
    | LC_ALL=C sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_.]*)[[:space:]]*=.*/\2/p' \
    | grep -iE '^(foundry|forge|dapp)_' | sort -u)"
  [ -n "$names" ] || return 0
  while IFS= read -r n; do
    echo "$tag: $f sets $n, which forge loads as if it were in the environment - and it cannot be removed from here"
  done <<< "$names"
  echo "$tag: take it out of .env (an allowed one, FOUNDRY_PROFILE, goes in the environment, where this script names it)"
  return 1
}

# forge_global_config <tag> [<dir>]
#   in <dir> (default: here), where forge runs, under the profile in force. forge merges ~/.foundry/foundry.toml, the
#   machine's own configuration, into every project's, and it cannot be removed from here: measured (forge 1.8.1, 2026-09-27, a temporary
#   HOME), `skip = [...]` in it made the root kit's battery PASS on 86 tests of 107 with "filter: none", `match_test` made
#   fuzz-long.sh say "long fuzz passed" over 1 invariant of 6 and mutate.sh "VARIANT PASSED 1 test(s)" over a variant that
#   breaks 8. What it CHANGES is measured, not guessed from its text: `forge config` with it and with an empty HOME, and the
#   keys that differ - so a key the project sets itself (the project wins) is not named, and one forge does not know is
#   not either (forge ignores it too). Names only, never a value (an [etherscan] key, an [rpc_endpoints] URL). Sets
#   FORGE_GLOBAL_FILE, FORGE_GLOBAL_KEYS (every changed key, as <section>.<key>) and FORGE_GLOBAL_NARROW (those that choose
#   which tests run: a profile's match_* / no_match_*, skip, test), and prints one line when there is any. Cost: nothing
#   without the file, two `forge config` (about 10-20 ms each) with it.
forge_global_config() {
  local tag="$1" dir="${2:-.}" g="${HOME:-}/.foundry/foundry.toml" empty with without rc1 rc2 keys
  # shellcheck disable=SC2034   # read by the scripts that call this
  FORGE_GLOBAL_FILE="$g"; FORGE_GLOBAL_KEYS=""; FORGE_GLOBAL_NARROW=""
  { [ -n "${HOME:-}" ] && [ -f "$g" ]; } || return 0
  empty="$(mktemp -d 2> /dev/null)" || { echo "$tag: $g exists, and no temporary directory could be made to read forge's configuration without it: what it changes is NOT known"; return 0; }
  with="$(cd "$dir" && forge config 2> /dev/null)"; rc1=$?
  without="$(cd "$dir" && HOME="$empty" forge config 2> /dev/null)"; rc2=$?
  rm -rf "$empty"
  if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ]; then
    echo "$tag: $g exists, and forge config failed (rc $rc1 with it, $rc2 without it): what it changes is NOT known"; return 0
  fi
  keys="$(LC_ALL=C comm -3 <(_forge_config_keys <<< "$with") <(_forge_config_keys <<< "$without") | awk -F '\t' '{ print ($1 == "" ? $2 : $1) }' | LC_ALL=C sort -u)"
  [ -n "$keys" ] || return 0
  FORGE_GLOBAL_KEYS="$(printf '%s\n' "$keys" | paste -sd ' ' -)"
  # shellcheck disable=SC2034   # read by the scripts that call this
  FORGE_GLOBAL_NARROW="$(printf '%s\n' "$keys" | grep -E '^profile\.[^.]+\.((no_)?match_(test|contract|path)|skip|test)$' | paste -sd ' ' -)"
  echo "$tag: $g, forge's configuration for every project on this machine, changes this run's: $FORGE_GLOBAL_KEYS (key names; the values are not printed)"
}
_forge_config_keys() { # `forge config` (TOML) on stdin -> "<section>.<key><TAB><line>", sorted; a multi-line value's lines
  # count under their key. Sections only the formatter, the linter and the doc generator read are left out.
  awk '/^\[/ { sec = $0; gsub(/^\[+|\]+[[:space:]]*$/, "", sec); k = ""; next }
    /^[A-Za-z0-9_.-]+ = / { k = $1 }
    k != "" && sec !~ /^(fmt|doc|lint)($|\.)/ { print sec "." k "\t" $0 }' | LC_ALL=C sort -u
}

# forge_cache_elsewhere [<cache file>]
#   in the directory forge runs in. Prints the first path forge's build cache recorded that is NOT exactly this
#   directory + that file's key in the cache's "files", and returns 0: the cache - and out/ with it - was written
#   somewhere else and copied here (`cp -a` of a built project, a moved directory). Returns 1 when there is no cache, or
#   every path it recorded is here. "Exactly", not "under": a project built in N/inner and copied up into N records
#   N/inner/test/B.t.sol, which is under N, and passed as here (V25, 2026-09-27: BATTERY PASSED, freshness rc 0, over a
#   broken source). Both sides are canonical (forge records the real path, measured through a symlink; this compares
#   with `pwd -P`), so a project reached through a symlink is here. The array is read as JSON strings, so a `,` or a `]`
#   in a path does not split it (it did: a directory named `x,y]z` was "elsewhere" on every run).
#   Why it matters: forge 1.8.1 records most sources by relative path, but the test files that hold a contract derived from
#   a source (its "mocks") by ABSOLUTE path, and an incremental build recompiles a changed source without them when they
#   are not where it recorded them. Measured (2026-09-27): the root kit copied with its build to another path, a mutant
#   planted in ToyVault.sol - forge compiled "1 files", the 3 suites of the invariant handler ran the OLD vault, fuzz-long.sh
#   said "long fuzz passed" with 6 of 6 invariants, census.sh tabled it, the battery's freshness check said rc 0; a
#   two-file toy (`contract AMock is A {}` in the test) passed its unit test over the broken A. Cost: one grep over the
#   cache, one more per recorded path (and one `forge config` for its place when none is given). A project whose tests
#   hold no such contract records no such path, and is not affected. Only this forge's cache shape is read: another
#   forge's may record other paths.
forge_cache_elsewhere() {
  local cache="${1:-}" root arr s p pre='"mocks":['
  root="$(pwd -P)"
  [ -n "$cache" ] || cache="$(_forge_cache_file)"
  [ -f "$cache" ] || return 1
  # each "mocks" array, whole (its strings may hold `,` and `]`); split on `","` (the strings are left JSON-escaped, as
  # the keys they are compared with are)
  while IFS= read -r arr; do
    s="${arr#"$pre"}"; s="${s%]}"; s="${s#\"}"; s="${s%\"}"
    while [ -n "$s" ]; do
      p="${s%%\",\"*}"
      case "$p" in
        /*) case "$p" in "$root"/*) grep -qF -- "\"${p#"$root"/}\":{" "$cache" || { printf '%s\n' "$p"; return 0; } ;;
                         *) printf '%s\n' "$p"; return 0 ;; esac ;;
      esac
      [ "$p" != "$s" ] || break
      s="${s#*\",\"}"
    done
  done < <(grep -oE '"mocks":\[("([^"\\]|\\.)*"(,"([^"\\]|\\.)*")*)?\]' "$cache")
  return 1
}
_forge_cache_file() { # forge's build record in the directory forge runs in: <cache_path>/solidity-files-cache.json
  local dir
  dir="$(forge config 2> /dev/null | awk '$1 == "cache_path" { gsub(/"/, "", $3); print $3; exit }')"
  printf '%s\n' "${dir:-cache}/solidity-files-cache.json"
}

# ---- what the build READ: the kit's own record (K27)
#
# The problem it solves: forge 1.8.1 links tests to the project's sources dynamically (`dynamic_test_linking`, on by
# default): after a change to a source that leaves its interface alone, it recompiles that source and NOT the tests that
# use it, trusting that a test deploys the source's new artifact. That holds for a file under the project's `src`
# directory that a test imports by its path. It does not hold for the rest, and there the tests run the OLD code, forge
# says nothing, and its next build says "No files changed". Measured (2026-09-27, toys, raw forge, a pure-function
# change that the test asserts): stale for a file in a directory reached through a remapping - outside the project
# (the v4 module's `gauntlet-kit/=../src/`), inside it (`vendor/`), even `src/` itself imported as `app/B.sol` - for a
# file under a `lib/` that is a symlink, for `src/` reached through a symlink (V25b), and for a file in `src/` new'd by
# a contract outside it; honest for a file in `src/` imported by path from a test, from a helper under `test/`, or
# through another file in `src/`, and for any change to a file under `test/` or `script/` (forge recompiles the file that
# changed), and for a contract a test DERIVES from (forge recompiles the deriving test - its "mocks"). That last one is
# why the v4 module itself was judged right (K27): its suites derive from V4Harness and HandlerBase, and two root-kit
# mutants (HostileERC20, HandlerBase) failed the same tests incrementally as from nothing. The root kit with `src/` a
# symlink was not: BATTERY PASSED 107 over a mutant that fails 3 suites.
# forge's own cache cannot tell: it records the new content of the file it recompiled. So the kit keeps its own record,
# next to forge's (<cache_path>/gauntlet-sources.tsv, as git-ignored as forge's cache): the content (SHA-256, sha256_of
# below) of every source the build read that is not under the test or script directory - src, lib, remapped and linked
# files alike - written after a build the kit trusts, from the contents as they were when that build started. SHA-256,
# not a CRC: the first record was POSIX cksum (CRC-32 and size, v0.2), and a mutant planted with twelve chosen
# characters in a revert string and the bytes given back from indentation inside function bodies had the original's
# cksum - BATTERY PASSED 107 over code that fails 3 suites from nothing (V28, 2026-09-27, the root kit with src/ a
# symlink). A record in any other format than this kit writes - that one included - is read as no record: one build
# from nothing, and one line says why. Before judging, the
# battery, fuzz-long.sh, census.sh and assert-fresh-build.sh compare it with the files as they are: a file that changed
# is left to forge's incremental build only when forge is measured right for it (a plain file under `src`, in a project
# where no remapping reaches into `src` and no source outside it imports one); any other change, or no record at all,
# makes the build one from nothing (forge_cache_rehome), and one line says which file and why.
# lib/ is NOT left out: a pinned dependency does not change between two runs, and hashing it costs milliseconds; one that
# does change (an install at another pin, a lib that is a symlink) goes stale like any other file outside `src`
# (measured: a lib behind a symlink, raw forge, the old code ran).
# Cost (v4 module, 102 recorded files: 74 under lib/, 26 under src/, 2 of the root kit): the check 60 ms, a battery with
# nothing changed 12 s, a hook edited under src/ incremental as before (103 s); a root-kit edit is a build from nothing
# (243 s, where forge's incremental build took 71 s and was right, above) - and so is the first run with no record.

# _forge_layout: FORGE_SRC_DIR, FORGE_TEST_DIR, FORGE_SCRIPT_DIR as forge config gives them here (relative, no ./ or /)
_forge_layout() {
  local cfg
  cfg="$(forge config 2> /dev/null)"
  FORGE_SRC_DIR="$(_forge_rel "$(awk '$1 == "src" && $2 == "=" { gsub(/"/, "", $3); print $3; exit }' <<< "$cfg")" src)"
  FORGE_TEST_DIR="$(_forge_rel "$(awk '$1 == "test" && $2 == "=" { gsub(/"/, "", $3); print $3; exit }' <<< "$cfg")" test)"
  FORGE_SCRIPT_DIR="$(_forge_rel "$(awk '$1 == "script" && $2 == "=" { gsub(/"/, "", $3); print $3; exit }' <<< "$cfg")" script)"
}
_forge_rel() { # _forge_rel <dir> <default>: relative to here, without ./ and a trailing /
  local d="${1:-$2}" root
  root="$(pwd -P)"
  case "$d" in "$root"/*) d="${d#"$root"/}" ;; esac
  d="${d#./}"; d="${d%/}"
  printf '%s\n' "${d:-$2}"
}

# _forge_sources_keys <cache>: every source forge's cache records ("files", as the keys are written: relative to here,
#   or absolute), but those under the test and script directories - one per line. Reads this forge's shape only.
_forge_sources_keys() {
  grep -oE '"([^"\\]|\\.)*":\{"lastModificationDate"' "$1" 2> /dev/null | sed 's/":{"lastModificationDate"$//; s/^"//' \
    | awk -v t="$FORGE_TEST_DIR/" -v p="$FORGE_SCRIPT_DIR/" 'index($0, t) != 1 && index($0, p) != 1' | LC_ALL=C sort -u
}
# _forge_sources_sums: keys on stdin -> "<sha256><TAB><key>" for each one that is a file here (missing: no line)
_forge_sources_sums() { sha256_of; }
_forge_sources_record_file() { printf '%s\n' "$(dirname "$1")/gauntlet-sources.tsv"; }
# the record's first line: it says what it is and how it hashes - a record whose first line is not this, or with a line
# that is not "<64 hex digits><TAB><file>", is not one this kit wrote (v0.2's cksum record included): read as none
FORGE_SOURCES_FORMAT="# hook-gauntlet sources record 2, sha256"
_forge_sources_record_ok() {
  local first
  IFS= read -r first < "$1" 2> /dev/null || return 1
  case "$first" in "$FORGE_SOURCES_FORMAT "*) ;; *) return 1 ;; esac
  ! grep -v '^#' "$1" | LC_ALL=C grep -qvE "^[0-9a-f]{64}$(printf '\t')."
}

# sha256_of: file names on stdin, one per line -> "<sha256><TAB><name>" for each that is a readable regular file, in
#   their order (a missing or unreadable one: no line). By the first of these that is here: sha256sum (GNU coreutils,
#   Linux), `shasum -a 256` (Perl's, macOS - which has no sha256sum), `openssl dgst -sha256`; FORGE_SHA256_TOOL says
#   which (the record's first line names it). None: returns 2 and one line on stderr naming the three - never a weaker
#   hash in its place. The files are hashed in one call (xargs) and paired with the answers by order; when the count of
#   answers is not the count of files (one vanished between the two), each is hashed alone.
FORGE_SHA256_TOOL=""
_sha256_tool() {
  if command -v sha256sum > /dev/null 2>&1; then FORGE_SHA256_TOOL=sha256sum
  elif command -v shasum > /dev/null 2>&1; then FORGE_SHA256_TOOL="shasum -a 256"
  elif command -v openssl > /dev/null 2>&1; then FORGE_SHA256_TOOL="openssl dgst -sha256"
  else FORGE_SHA256_TOOL=""; return 1; fi
}
FORGE_SHA256_MISSING="none of sha256sum, shasum or openssl is on this PATH: the kit hashes what a build read with SHA-256 (scripts/lib/forge-env.sh, sha256_of) and has nothing to hash with, so it cannot tell a build that runs old code - install one (coreutils' sha256sum, Perl's shasum, or openssl)"
_sha256_hex() { # the tool's answers on stdin -> the hex digest alone, one per line (GNU's "\<hex>  <name>" for an escaped name too)
  case "$FORGE_SHA256_TOOL" in
    openssl*) LC_ALL=C sed -nE 's/^.*= ([0-9a-f]{64})$/\1/p' ;;
    *) LC_ALL=C sed -nE 's/^\\?([0-9a-f]{64}) .*$/\1/p' ;;
  esac
}
sha256_of() {
  local f h n=0 hexes
  local -a files=() args=()
  _sha256_tool || { echo "$FORGE_SHA256_MISSING" >&2; return 2; }
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] || continue
    files+=("$f"); case "$f" in -*) args+=("./$f") ;; *) args+=("$f") ;; esac   # a name the tool would read as a flag
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  # shellcheck disable=SC2086   # FORGE_SHA256_TOOL is a command and its flags, on purpose
  hexes="$(printf '%s\0' "${args[@]}" | xargs -0 $FORGE_SHA256_TOOL 2> /dev/null | _sha256_hex)"
  if [ "$(printf '%s\n' "$hexes" | grep -c .)" -eq "${#files[@]}" ]; then
    while IFS= read -r h; do printf '%s\t%s\n' "$h" "${files[$n]}"; n=$((n + 1)); done <<< "$hexes"
    return 0
  fi
  for n in "${!files[@]}"; do
    # shellcheck disable=SC2086
    h="$($FORGE_SHA256_TOOL "${args[$n]}" 2> /dev/null | _sha256_hex)"
    [ -z "$h" ] || printf '%s\t%s\n' "$h" "${files[$n]}"
  done
}

# forge_sources_snapshot [<cache file>]: the sources as they are NOW (before a build), for forge_sources_record
forge_sources_snapshot() {
  local cache="${1:-}"
  [ -n "$cache" ] || cache="$(_forge_cache_file)"
  [ -f "$cache" ] || return 0
  _forge_layout
  _forge_sources_keys "$cache" | _forge_sources_sums
}

# forge_sources_record [<cache file>] [<snapshot>]: after a build the kit trusts, the record of what it read: the sources
#   forge's cache lists now, each with its content as the snapshot taken before the build saw it (a file edited while
#   forge built is then different next time - never recorded as read), or as it is now when the snapshot did not have it.
forge_sources_record() {
  local cache="${1:-}" pre="${2:-}" rec now
  [ -n "$cache" ] || cache="$(_forge_cache_file)"
  [ -f "$cache" ] || return 0
  rec="$(_forge_sources_record_file "$cache")"
  # nothing to hash with: no record (forge_sources_stale refuses on it, naming the three tools)
  _sha256_tool || { rm -f -- "$rec"; return 0; }
  _forge_layout
  now="$(_forge_sources_keys "$cache" | _forge_sources_sums)"
  # nothing readable (another forge's cache shape): no record, and forge_sources_stale says so on every run
  [ -n "$now" ] || { rm -f -- "$rec"; return 0; }
  {
    echo "$FORGE_SOURCES_FORMAT ($FORGE_SHA256_TOOL): the sources forge's build here read (not test/ or script/), and their content when it started."
    echo "# Written by the kit after a build it trusts (scripts/lib/forge-env.sh, forge_sources_record); compared before the next."
    if [ -n "$pre" ]; then
      awk -F '\t' 'NR == FNR { pre[$2] = $1; next } { print (($2 in pre) ? pre[$2] : $1) "\t" $2 }' <(printf '%s\n' "$pre") <(printf '%s\n' "$now")
    else
      printf '%s\n' "$now"
    fi
  } > "$rec.tmp" 2> /dev/null && mv -f "$rec.tmp" "$rec" 2> /dev/null
}

# forge_sources_stale [<cache file>] [--no-record-ok]: in the directory forge runs in. Returns 0 - and sets
#   FORGE_SOURCES_WHY, one phrase, and FORGE_SOURCES_SHORT - when the next build must be from nothing: a source changed
#   since the record was written that forge's incremental build is not measured right for (above), or forge's cache
#   exists and there is no record of what its build read (a build forge made alone, or one from before this record
#   existed). With --no-record-ok (assert-fresh-build.sh standalone: forge's answer decides, as it always has) no record
#   returns 1 and sets FORGE_SOURCES_NOTE instead. Returns 1 otherwise: no cache (nothing to distrust), nothing changed,
#   only plain files under `src` in a project where forge follows them - or a cache in a shape this forge (1.8.1) does not
#   write (FORGE_SOURCES_NOTE says so: nothing is recorded, nothing is seen). A record not in this kit's format (v0.2's
#   cksum one, or anything else: _forge_sources_record_ok) is no record, and FORGE_SOURCES_WHY says which it was. Returns
#   2 - FORGE_SOURCES_WHY naming the three tools - when there is nothing to hash with (sha256_of): refused, never a
#   weaker check. Cost: one `forge config`, one grep over the cache and one SHA-256 over the recorded files (plus one
#   `forge remappings` when only `src` changed).
# shellcheck disable=SC2034   # FORGE_SOURCES_NOTE is read by the scripts that call this
forge_sources_stale() {
  local cache="${1:-}" rec changed k first="" n=0 why="" root d tgt canon srcc m
  FORGE_SOURCES_WHY=""; FORGE_SOURCES_SHORT=""; FORGE_SOURCES_NOTE=""
  if ! _sha256_tool; then FORGE_SOURCES_WHY="$FORGE_SHA256_MISSING"; FORGE_SOURCES_SHORT="nothing to hash with"; return 2; fi
  [ -n "$cache" ] || cache="$(_forge_cache_file)"
  [ -f "$cache" ] || return 1
  rec="$(_forge_sources_record_file "$cache")"
  _forge_layout
  if ! grep -qE '"([^"\\]|\\.)*":\{"lastModificationDate"' "$cache" 2> /dev/null; then
    FORGE_SOURCES_NOTE="forge's cache $cache lists no source in the shape this kit reads (another forge version?): what its build read is not checked"
    return 1
  fi
  if [ ! -f "$rec" ] || ! _forge_sources_record_ok "$rec"; then
    FORGE_SOURCES_WHY="there is no record of what forge's last build here read ($rec, written by the kit after each build it trusts), so a source changed since then would not be seen"; FORGE_SOURCES_SHORT="no record of what the last build read"
    if [ -f "$rec" ]; then
      if head -n 2 "$rec" 2> /dev/null | grep -qF '(cksum)'; then
        FORGE_SOURCES_WHY="the record of what forge's last build here read ($rec) was written by an older kit with cksum, a CRC that a deliberate edit can match (V28: BATTERY PASSED over a forged mutant); this kit compares SHA-256 only, so it is read as no record, and a source changed since then would not be seen"
        FORGE_SOURCES_SHORT="the record of what the last build read is an older kit's (cksum), read as none"
      else
        FORGE_SOURCES_WHY="the record of what forge's last build here read ($rec) is not in the format this kit writes ('$FORGE_SOURCES_FORMAT ...', a SHA-256 per file), so it is read as no record, and a source changed since then would not be seen"
        FORGE_SOURCES_SHORT="the record of what the last build read is not this kit's format, read as none"
      fi
    fi
    if [ "${2:-}" = --no-record-ok ]; then
      FORGE_SOURCES_NOTE="$FORGE_SOURCES_WHY - a change outside src/ that forge's incremental build does not follow (scripts/lib/forge-env.sh) is not seen by this run; the battery records one"
      FORGE_SOURCES_WHY=""; FORGE_SOURCES_SHORT=""; return 1
    fi
    return 0
  fi
  # the recorded files whose content is not the recorded one, or that are gone (the first input is never empty: a
  # header line, so NR == FNR is the sums only)
  changed="$({ echo '#'; grep -v '^#' "$rec" | cut -f2 | _forge_sources_sums; } | awk -F '\t' 'NR == FNR { if (!/^#/) now[$2] = $1; next } !/^#/ && now[$2] != $1 { print $2 }' - "$rec")"
  [ -n "$changed" ] || return 1
  root="$(pwd -P)"
  while IFS= read -r k; do
    n=$((n + 1)); [ -n "$first" ] || first="$k"
    [ -n "$why" ] && continue
    case "$k" in
      "$FORGE_SRC_DIR"/*)
        # a plain file under src that is gone: forge drops it, and whatever imported it has changed too
        d="$(dirname "$k")"
        if [ -e "$k" ] && { [ -L "$k" ] || [ "$(cd "$d" 2> /dev/null && pwd -P)" != "$root/$d" ]; }; then why="it is reached through a symlink"; fi ;;
      /*) why="forge recorded it by an absolute path (outside this project, or through a symlink)" ;;
      ../*) why="it is outside this project" ;;
      *) why="it is outside $FORGE_SRC_DIR/" ;;
    esac
    [ -z "$why" ] || first="$k"
  done <<< "$changed"
  if [ -z "$why" ]; then
    # only plain files under src changed: forge is right for them unless a remapping reaches into src (a test that
    # imports app/B.sol for src/B.sol ran the old B), or a source outside src imports one (its artifact keeps the old)
    srcc="$root/$FORGE_SRC_DIR"
    while IFS= read -r m; do
      tgt="${m#*=}"; [ -n "$tgt" ] || continue
      case "$tgt" in /*) ;; *) tgt="$root/$tgt" ;; esac
      canon="$(cd "$tgt" 2> /dev/null && pwd -P)" || continue
      case "$canon/" in "$srcc"/* | "$srcc/") why="a remapping ($m) reaches into $FORGE_SRC_DIR/, and a test that imports through it runs the old code" ;; esac
      case "$srcc/" in "$canon"/*) why="a remapping ($m) reaches into $FORGE_SRC_DIR/, and a test that imports through it runs the old code" ;; esac
      [ -z "$why" ] || break
    done < <(forge remappings 2> /dev/null)
  fi
  if [ -z "$why" ]; then
    m="$(grep -oE '"([^"\\]|\\.)*":\{"lastModificationDate":[0-9]+,"contentHash":"[^"]*","interfaceReprHash":[^,]*,"sourceName":"([^"\\]|\\.)*","imports":\[[^]]*\]' "$cache" \
      | awk -v s="$FORGE_SRC_DIR/" -v t="$FORGE_TEST_DIR/" -v p="$FORGE_SCRIPT_DIR/" '{
          k = substr($0, 2, index($0, "\":{\"lastModificationDate\"") - 2)
          if (index(k, s) == 1 || index(k, t) == 1 || index(k, p) == 1) next
          i = substr($0, index($0, "\"imports\":[") + 11); if (index(i, "\"" s) > 0) { print k; exit } }')"
    [ -z "$m" ] || why="$m, outside $FORGE_SRC_DIR/, imports it"
  fi
  [ -n "$why" ] || return 1
  FORGE_SOURCES_WHY="$first changed since the last build the kit recorded$([ "$n" -gt 1 ] && echo " (and $((n - 1)) more)"), and $why: after such a change forge's incremental build can leave tests running the old code"
  FORGE_SOURCES_SHORT="$first changed, where forge's incremental build is not trusted"
  return 0
}

# forge_cache_rehome <tag> [<cache file>]
#   forge_cache_elsewhere, then forge_sources_stale; on either the next build is from NOTHING: forge's build record (the
#   cache file) is removed and one line says why (FORGE_REHOME_WHY: the short reason, for a summary). Not
#   `forge build --force`: it also deletes cache/invariant and cache/fuzz (the failures forge
#   persisted, which replay first - a counterexample), cache/test-failures and the corpus directory (measured, forge
#   1.8.1), and nothing here deletes those. Without its record forge compiles every source (measured: 27 files of 27 on
#   the root kit, 2.5 s against 0.14 s for a no-op build; 228 s on the v4 module) and writes the paths of this place.
#   Returns 0 when it removed the record, 1 when there was nothing to do, 2 when the record could not be removed, or
#   there is nothing to hash what the build reads with (sha256_of) - said, and the caller runs nothing.
forge_cache_rehome() {
  local tag="$1" cache="${2:-}" elsewhere rc
  FORGE_REHOME_WHY=""
  if ! _sha256_tool; then echo "$tag: $FORGE_SHA256_MISSING. Refused: nothing built."; return 2; fi
  [ -n "$cache" ] || cache="$(_forge_cache_file)"
  if elsewhere="$(forge_cache_elsewhere "$cache")"; then
    if ! rm -f -- "$cache" 2> /dev/null || [ -e "$cache" ]; then
      echo "$tag: forge's cache was written at another path ($elsewhere), and its record $cache cannot be removed: an incremental build here would run the old code in tests. Remove it, or run forge build --force."
      return 2
    fi
    FORGE_REHOME_WHY="written at another path"
    echo "$tag: forge's cache was written at another path ($elsewhere): its record $cache is removed, so this build is from nothing (an incremental one leaves tests running the old code)"
    return 0
  fi
  forge_sources_stale "$cache"; rc=$?
  if [ "$rc" -eq 2 ]; then echo "$tag: $FORGE_SOURCES_WHY. Refused: nothing built."; return 2; fi
  [ "$rc" -eq 0 ] || return 1
  if ! rm -f -- "$cache" 2> /dev/null || [ -e "$cache" ]; then
    echo "$tag: $FORGE_SOURCES_WHY - and forge's record $cache cannot be removed. Remove it, or run forge build --force."
    return 2
  fi
  # shellcheck disable=SC2034   # read by the scripts that call this
  FORGE_REHOME_WHY="$FORGE_SOURCES_SHORT"
  echo "$tag: $FORGE_SOURCES_WHY. Its record $cache is removed, so this build is from nothing."
  return 0
}
