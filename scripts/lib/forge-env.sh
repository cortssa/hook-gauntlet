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
# with its value. What a script sets itself (the corpus directory for V4_MANAGER, the long profile's budget) it sets
# after this, so it is its own and never inherited.
#
# Left alone, because they select no test and fail none (measured the same day): ETH_RPC_URL (`forge test` does not fork
# on it - FOUNDRY_ETH_RPC_URL does, and is removed), ETH_FROM, ETHERSCAN_API_KEY, ETH_RPC_TIMEOUT, NO_COLOR, RUST_LOG (more
# lines in the log, not other results). Not the environment, and not removable from here: a `.env` where forge runs
# (forge loads it: forge_dotenv_check below), and ~/.foundry/foundry.toml, forge's global configuration, which
# `forge config` merges with the project's (battery.sh names a filter it finds there).

# forge_env_clean <tag> "<allowed names, space separated>" <script> [the script's arguments...]
#   removes the variables above and RE-RUNS the script without them (exec: the same process, the same id). A re-run,
#   not `unset`: bash cannot unset a name that is not a shell identifier (`FOUNDRY_FUZZ.RUNS`), and forge reads it.
#   Returns only when nothing is left to remove. Call it before the script changes directory or writes anything.
forge_env_clean() {
  local tag="$1" allowed=" $2 " script="$3" kv name n
  local -a drop=() args=()
  shift 3
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
    if [ -n "${!n:-}" ]; then printf '%s: %s=%s from the environment (allowed)\n' "$tag" "$n" "${!n}"; fi
  done
  return 0
}

# forge_dotenv_check <tag> <dir>
#   forge loads <dir>/.env into its own environment at start (its project root's and its working directory's; the kit's
#   scripts run forge where foundry.toml is, so both are <dir>), without overriding what is already set, and a FOUNDRY_,
#   FORGE_ or DAPP_ name there acts like one exported: measured (forge 1.8.1), FOUNDRY_MATCH_CONTRACT in it ran 5 tests of
#   107, FORGE_ALLOW_FAILURE=true exited 0 over a failed test. It is the project's file, never edited from here: each such
#   name is named (never its value), and the caller refuses to run. Returns 1 when there is one.
forge_dotenv_check() {
  local tag="$1" f="$2/.env" names n
  [ -f "$f" ] || return 0
  names="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_.]*)[[:space:]]*=.*/\2/p' "$f" \
    | grep -iE '^(foundry|forge|dapp)_' | sort -u)"
  [ -n "$names" ] || return 0
  while IFS= read -r n; do
    echo "$tag: $f sets $n, which forge loads as if it were in the environment - and it cannot be removed from here"
  done <<< "$names"
  echo "$tag: take it out of .env (an allowed one, FOUNDRY_PROFILE, goes in the environment, where this script names it)"
  return 1
}
