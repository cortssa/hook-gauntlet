#!/usr/bin/env bash
#
# install-v4.sh - put the Uniswap v4 sources the v4 module needs into <project>/lib, at pinned commits.
#
# The problem it solves: the v4 module cannot ship Uniswap's source. `PoolManager` is BUSL-1.1, and a kit that
# vendors somebody else's licensed code hands its users a licence question they did not ask for. So the module
# ships the harness and this script fetches the dependency.
#
# The second problem it solves is worse: "install the latest" is not a dependency, it is a moving target. The
# v4 API has moved under people's feet (the swap and liquidity parameter structs left `IPoolManager` for
# `types/PoolOperation.sol`), so a harness that compiled last month fails today for reasons that have nothing
# to do with the hook under test. Everything below is pinned to a commit hash, the hashes are printed on every
# run, and changing one is a decision somebody makes on purpose.
#
# Usage:   scripts/install-v4.sh [project-dir]        (default: foundry-kit/v4 relative to this script)
# Env:     V4_WITH_PERIPHERY=1  also install v4-periphery (not needed by the harness; useful if YOUR hook
#                               imports the position manager, the quoter or the routers)
#          V4_FORCE=1           re-clone even if the pin already matches
# Exit:    0 everything present at the pinned commits, 1 otherwise.
#
# Nothing else is installed: no npm, no pip, no foundryup. If `git` and `forge` are not already on the
# machine, this script is not the place to fix that.

set -uo pipefail

# ---------------------------------------------------------------------------- the pins
# v4-core at the commit that Uniswap's own v4-periphery pins as its submodule, so a project that later adds
# the periphery gets one v4-core and not two.
V4_CORE_REPO="https://github.com/Uniswap/v4-core"
V4_CORE_PIN="59d3ecf53afa9264a16bba0e38f4c5d2231f80bc"

# v4-periphery main as of 2026-09-21. It has no release tags.
V4_PERIPHERY_REPO="https://github.com/Uniswap/v4-periphery"
V4_PERIPHERY_PIN="9969eec44cfdf07e24b41de47f40276a58401976"

# v4-core's own submodules, needed because its sources import them:
#   solmate      -> ProtocolFees imports Owned              (needed to compile PoolManager)
#   forge-std    -> the harness and v4-core's test helpers  (needed)
#   openzeppelin -> only v4-core's own src/test/MockContract (skipped unless you ask for it)
V4_CORE_SUBMODULES="${V4_CORE_SUBMODULES:-lib/forge-std lib/solmate}"

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || { echo "install-v4: $HERE/lib/parse.sh is missing"; exit 1; }

# Checked before anything is created or fetched: a pin that is not a full commit hash (a branch, a tag, a short sha, a
# typo) is a moving target under a pinned name, and the fetch below would happily follow it.
for pin_name in V4_CORE_PIN V4_PERIPHERY_PIN; do
  if ! is_git_sha "${!pin_name}"; then
    echo "install-v4: $pin_name='${!pin_name}' is not a full commit hash (40 lower-case hex digits). Nothing fetched."
    exit 1
  fi
done

PROJECT="${1:-$HERE/../foundry-kit/v4}"
[ -d "$PROJECT" ] || { echo "install-v4: no such project directory: $PROJECT"; exit 1; }
PROJECT="$(cd "$PROJECT" && pwd)"
LIB="$PROJECT/lib"
mkdir -p "$LIB" || exit 1

command -v git > /dev/null 2>&1 || { echo "install-v4: git not found"; exit 1; }

# ---------------------------------------------------------------------------- one repo, one pin
# Fetches exactly the pinned commit (depth 1) rather than cloning a history nobody reads. If the server
# refuses to serve a bare sha (some mirrors do), it falls back to a full clone and checks the sha out.
fetch_pinned() {
  name="$1"; repo="$2"; pin="$3"; dest="$LIB/$1"

  if [ -d "$dest/.git" ] && [ "${V4_FORCE:-0}" != "1" ]; then
    have="$(git -C "$dest" rev-parse HEAD 2>/dev/null)"
    if [ "$have" = "$pin" ]; then
      echo "install-v4: $name already at $pin"
      return 0
    fi
    echo "install-v4: $name is at ${have:-unknown}, wanted $pin - refetching"
  fi

  rm -rf "$dest" || return 1
  git init -q "$dest" || return 1
  git -C "$dest" remote add origin "$repo" || return 1
  if ! git -C "$dest" fetch -q --depth 1 origin "$pin"; then
    echo "install-v4: shallow fetch of $pin refused, falling back to a full clone of $name"
    git -C "$dest" fetch -q origin || { echo "install-v4: cannot fetch $name from $repo"; return 1; }
  fi
  # check out the PIN by name: after a full fetch FETCH_HEAD is the tip of the default branch, not the pin
  git -C "$dest" checkout -q "$pin" 2> /dev/null || git -C "$dest" checkout -q FETCH_HEAD || return 1

  got="$(git -C "$dest" rev-parse HEAD)"
  [ "$got" = "$pin" ] || { echo "install-v4: $name checked out $got, expected $pin"; return 1; }
  echo "install-v4: $name at $got"
}

# Submodules are pinned by the parent's tree, so the sha comes from git, not from this file. Printed anyway,
# because "pinned" that nobody can read is not pinned.
fetch_submodules() {
  parent="$LIB/$1"; shift
  for sub in "$@"; do
    want="$(git -C "$parent" ls-tree HEAD "$sub" | awk '{print $3}')"
    [ -n "$want" ] || { echo "install-v4: $parent has no submodule $sub"; return 1; }
    url="$(git -C "$parent" config -f .gitmodules --get "submodule.$sub.url" 2>/dev/null)"
    [ -n "$url" ] || { echo "install-v4: no url for $sub in $parent/.gitmodules"; return 1; }

    if [ -d "$parent/$sub/.git" ] && [ "${V4_FORCE:-0}" != "1" ]; then
      have="$(git -C "$parent/$sub" rev-parse HEAD 2>/dev/null)"
      [ "$have" = "$want" ] && { echo "install-v4:   $sub already at $want"; continue; }
    fi

    rm -rf "${parent:?}/$sub"
    git init -q "$parent/$sub" || return 1
    git -C "$parent/$sub" remote add origin "$url" || return 1
    if ! git -C "$parent/$sub" fetch -q --depth 1 origin "$want"; then
      git -C "$parent/$sub" fetch -q origin || { echo "install-v4: cannot fetch $sub"; return 1; }
    fi
    git -C "$parent/$sub" checkout -q "$want" 2> /dev/null || git -C "$parent/$sub" checkout -q FETCH_HEAD || return 1
    got_sub="$(git -C "$parent/$sub" rev-parse HEAD)"
    [ "$got_sub" = "$want" ] || { echo "install-v4: $sub checked out $got_sub, the parent pins $want"; return 1; }
    echo "install-v4:   $sub at $(git -C "$parent/$sub" rev-parse HEAD)"
  done
}

# ---------------------------------------------------------------------------- do it
rc=0
fetch_pinned v4-core "$V4_CORE_REPO" "$V4_CORE_PIN" || rc=1
[ "$rc" -eq 0 ] && { fetch_submodules v4-core $V4_CORE_SUBMODULES || rc=1; }

if [ "${V4_WITH_PERIPHERY:-0}" = "1" ] && [ "$rc" -eq 0 ]; then
  fetch_pinned v4-periphery "$V4_PERIPHERY_REPO" "$V4_PERIPHERY_PIN" || rc=1
  # the periphery's own v4-core submodule is left uninitialised on purpose: the project remaps v4-core to
  # lib/v4-core, and a second copy of the same sources is how you get two PoolManagers in one build.
  [ "$rc" -eq 0 ] && echo "install-v4: v4-periphery installed; its lib/v4-core submodule is deliberately NOT initialised"
fi

# ---------------------------------------------------------------------------- report
echo
echo "== install-v4 summary =="
echo "project        $PROJECT"
echo "v4-core        $V4_CORE_PIN"
for sub in $V4_CORE_SUBMODULES; do
  if [ -d "$LIB/v4-core/$sub/.git" ]; then
    echo "  $sub  $(git -C "$LIB/v4-core/$sub" rev-parse HEAD)"
  else
    echo "  $sub  MISSING"; rc=1
  fi
done
if [ "${V4_WITH_PERIPHERY:-0}" = "1" ]; then
  echo "v4-periphery   $V4_PERIPHERY_PIN"
fi
echo
echo "Uniswap's PoolManager is BUSL-1.1. It lives under lib/, which is git-ignored, and it is never committed"
echo "into this repository. Re-run this script on a fresh checkout instead of vendoring it."

if [ "$rc" -ne 0 ]; then
  echo "INSTALL-V4 FAILED"
  exit 1
fi
echo "INSTALL-V4 OK"
