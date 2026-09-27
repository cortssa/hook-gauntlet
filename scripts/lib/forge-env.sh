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
# forge merges with the project's (forge_global_config), and a build cache written at another path (forge_cache_elsewhere).

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

# forge_cache_rehome <tag> [<cache file>]
#   forge_cache_elsewhere, and on a hit the next build is from NOTHING: forge's build record (the cache file) is removed
#   and one line says so. Not `forge build --force`: it also deletes cache/invariant and cache/fuzz (the failures forge
#   persisted, which replay first - a counterexample), cache/test-failures and the corpus directory (measured, forge
#   1.8.1), and nothing here deletes those. Without its record forge compiles every source (measured: 27 files of 27 on
#   the root kit, 2.5 s against 0.14 s for a no-op build) and writes the paths of this place.
#   Returns 0 when it removed the record, 1 when there was nothing to do, 2 when the record could not be removed (said).
forge_cache_rehome() {
  local tag="$1" cache="${2:-}" elsewhere
  [ -n "$cache" ] || cache="$(_forge_cache_file)"
  elsewhere="$(forge_cache_elsewhere "$cache")" || return 1
  if ! rm -f -- "$cache" 2> /dev/null || [ -e "$cache" ]; then
    echo "$tag: forge's cache was written at another path ($elsewhere), and its record $cache cannot be removed: an incremental build here would run the old code in tests. Remove it, or run forge build --force."
    return 2
  fi
  echo "$tag: forge's cache was written at another path ($elsewhere): its record $cache is removed, so this build is from nothing (an incremental one leaves tests running the old code)"
  return 0
}
