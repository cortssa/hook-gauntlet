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
#          V4_FORCE=1           re-clone (or, with V4_LOCAL_SRC, re-copy) even if the pin already matches. It is also
#                               the way out of a lib/v4-core that is at the pin but broken (a submodule missing).
#          V4_LOCAL_SRC=<dir>   OFFLINE: copy from local clones instead of fetching - <dir>/v4-core (with its
#                               submodules lib/forge-std and lib/solmate checked out) and, with V4_WITH_PERIPHERY=1,
#                               <dir>/v4-periphery. Nothing is fetched. Each clone must be AT THE PIN and clean: the
#                               source is checked before anything is copied, the copy is made into a staging directory
#                               under lib/ and checked there exactly as a fetched one is (HEAD == pin, each submodule ==
#                               what the parent's tree pins), and only a copy that passed replaces lib/<name>. A clone at
#                               another commit, with local changes, or without a submodule is refused, and a refusal
#                               leaves lib/ as it was (an earlier install intact; no lib/ at all if there was none).
#                               Any earlier install of the project, e.g. `<other project>/lib`, is a valid source.
#                               UNTRACKED FILES ARE COPIED: "clean" means no change to a tracked file (in the clone or a
#                               submodule), and a file git does not track, in either, is carried into the project as it
#                               is. The one kind refused is an untracked (or git-ignored) `.sol` under `src/` of the clone
#                               or of one of its submodules - the build would compile it as if it were Uniswap's - unless
#          V4_ALLOW_UNTRACKED=1 is set, which copies it and lists it. Anything else untracked (notes, build output, a
#                               `.sol` outside src/) is copied without a word: look in the clone if that matters to you.
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

V4_LOCAL_SRC="${V4_LOCAL_SRC:-}"
V4_ALLOW_UNTRACKED="${V4_ALLOW_UNTRACKED:-0}"
if [ -n "$V4_LOCAL_SRC" ]; then
  [ -d "$V4_LOCAL_SRC/v4-core" ] || { echo "install-v4: V4_LOCAL_SRC=$V4_LOCAL_SRC has no v4-core/ clone. Nothing copied."; exit 1; }
  V4_LOCAL_SRC="$(cd "$V4_LOCAL_SRC" && pwd)"
fi

PROJECT="${1:-$HERE/../foundry-kit/v4}"
[ -d "$PROJECT" ] || { echo "install-v4: no such project directory: $PROJECT"; exit 1; }
PROJECT="$(cd "$PROJECT" && pwd)"
LIB="$PROJECT/lib"
made_lib=0; [ -e "$LIB" ] || made_lib=1
mkdir -p "$LIB" || exit 1

# The offline copy is staged under lib/ (the same file system, so putting it in place is a rename) and never left
# behind: a refused copy used to stay in lib/v4-core, "at the pin", and the next run - even with a good source - took it
# for an install and refused again on its missing submodule.
STAGE=""
cleanup() {
  [ -n "$STAGE" ] && rm -rf "$STAGE" "$STAGE.old"
  # a project that had no lib/ is left without one when nothing was installed (rmdir: only an EMPTY lib/ goes)
  [ "$made_lib" -eq 1 ] && rmdir "$LIB" 2> /dev/null
  return 0
}
trap cleanup EXIT

command -v git > /dev/null 2>&1 || { echo "install-v4: git not found"; exit 1; }

# ---------------------------------------------------------------------------- one repo, one pin
# Fetches exactly the pinned commit (depth 1) rather than cloning a history nobody reads. If the server
# refuses to serve a bare sha (some mirrors do), it falls back to a full clone and checks the sha out.
# untracked_sol <clone> - the untracked or git-ignored .sol files under the clone's src/, one per line
untracked_sol() { git -C "$1" ls-files --others -- src 2> /dev/null | grep '\.sol$'; }

# check_subs <dir> <submodule...> - each submodule is present in <dir> and at the commit <dir>'s own tree pins
check_subs() {
  local dir="$1" sub want have; shift
  for sub in "$@"; do
    want="$(git -C "$dir" ls-tree HEAD "$sub" | awk '{print $3}')"
    [ -n "$want" ] || { echo "install-v4:   the clone has no submodule $sub. Refused."; return 1; }
    have=""
    [ -e "$dir/$sub/.git" ] && have="$(git -C "$dir/$sub" rev-parse HEAD 2> /dev/null)"
    if [ "$have" != "$want" ]; then
      echo "install-v4:   $sub is missing or not at $want in the local clone's copy (offline: nothing to fetch). Refused."
      return 1
    fi
  done
}

fetch_pinned() { # fetch_pinned <name> <repo> <pin> [submodule...]   (offline, the submodules are checked in the staged copy)
  name="$1"; repo="$2"; pin="$3"; dest="$LIB/$1"; shift 3

  if [ -e "$dest/.git" ] && [ "${V4_FORCE:-0}" != "1" ]; then
    have="$(git -C "$dest" rev-parse HEAD 2>/dev/null)"
    if [ "$have" = "$pin" ]; then
      echo "install-v4: $name already at $pin"
      return 0
    fi
    echo "install-v4: $name is at ${have:-unknown}, wanted $pin - refetching"
  fi

  if [ -n "$V4_LOCAL_SRC" ]; then
    # OFFLINE: the local clone is checked BEFORE anything in the project is touched, then copied, then checked again
    # below by the same line that checks a fetched one
    local_src="$V4_LOCAL_SRC/$name"
    [ -e "$local_src/.git" ] || { echo "install-v4: $local_src is not a git clone. Nothing copied."; return 1; }
    have_src="$(git -C "$local_src" rev-parse HEAD 2> /dev/null)"
    if [ "$have_src" != "$pin" ]; then
      echo "install-v4: the local clone $local_src is at ${have_src:-unknown}, the pin is $pin. Refused: nothing copied."
      return 1
    fi
    # `untracked`, not `none`: a submodule that only holds untracked files is treated like the clone itself (copied, except a
    # .sol under src/, below); a changed TRACKED file or another commit in a submodule is still a local change
    if [ -n "$(git -C "$local_src" status --porcelain --untracked-files=no --ignore-submodules=untracked 2> /dev/null)" ]; then
      echo "install-v4: the local clone $local_src is at the pin but has LOCAL CHANGES. Refused: nothing copied."
      return 1
    fi
    extra="$(untracked_sol "$local_src" | sed 's|^|./|')"
    for sub in "$@"; do
      [ -e "$local_src/$sub/.git" ] || continue
      extra="$extra
$(untracked_sol "$local_src/$sub" | sed "s|^|$sub/|")"
    done
    extra="$(printf '%s\n' "$extra" | grep -v '^$')"
    if [ -n "$extra" ]; then
      if [ "$V4_ALLOW_UNTRACKED" != "1" ]; then
        echo "install-v4: the local clone $local_src has UNTRACKED .sol files under src/ - the build would compile them as"
        echo "            if they were Uniswap's. Refused: nothing copied. Remove them, or set V4_ALLOW_UNTRACKED=1 to copy them:"
        printf '%s\n' "$extra" | sed 's/^/              /'
        return 1
      fi
      echo "install-v4: V4_ALLOW_UNTRACKED=1 - these untracked .sol files are copied with the clone:"
      printf '%s\n' "$extra" | sed 's/^/              /'
    fi
    STAGE="$(mktemp -d "$LIB/.install-v4-$name.XXXXXX")" || return 1
    { rmdir "$STAGE" && cp -a "$local_src" "$STAGE"; } || { echo "install-v4: cannot copy $local_src"; return 1; }
    got="$(git -C "$STAGE" rev-parse HEAD 2> /dev/null)"
    [ "$got" = "$pin" ] || { echo "install-v4: the copy of $name is at ${got:-unknown}, expected $pin. Refused."; return 1; }
    check_subs "$STAGE" "$@" || { echo "install-v4: nothing was installed: lib/ is as it was before this run."; return 1; }
    # only a copy that passed replaces what was there
    if [ -e "$dest" ]; then mv "$dest" "$STAGE.old" || return 1; fi
    if ! mv "$STAGE" "$dest"; then
      [ -e "$STAGE.old" ] && mv "$STAGE.old" "$dest"
      echo "install-v4: cannot move the copy of $name into place"; return 1
    fi
    rm -rf "$STAGE.old"; STAGE=""
    echo "install-v4: $name copied from the local clone $local_src (offline)"
  else
    rm -rf "$dest" || return 1
    git init -q "$dest" || return 1
    git -C "$dest" remote add origin "$repo" || return 1
    if ! git -C "$dest" fetch -q --depth 1 origin "$pin"; then
      echo "install-v4: shallow fetch of $pin refused, falling back to a full clone of $name"
      git -C "$dest" fetch -q origin || { echo "install-v4: cannot fetch $name from $repo"; return 1; }
    fi
    # check out the PIN by name: after a full fetch FETCH_HEAD is the tip of the default branch, not the pin
    git -C "$dest" checkout -q "$pin" 2> /dev/null || git -C "$dest" checkout -q FETCH_HEAD || return 1
  fi

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

    # `-e`, not `-d`: a submodule checked out by `git submodule update` has a .git FILE pointing into its parent
    if [ -n "$V4_LOCAL_SRC" ]; then
      # offline, a submodule comes inside the copied clone or not at all: there is nowhere to fetch it from. V4_FORCE is
      # no reason to skip looking: FORCE re-copied the parent, submodules included, just above - and skipping this look
      # under FORCE is why V4_FORCE=1 with V4_LOCAL_SRC used to fail every time with a false "missing".
      have=""
      [ -e "$parent/$sub/.git" ] && have="$(git -C "$parent/$sub" rev-parse HEAD 2> /dev/null)"
      [ "$have" = "$want" ] && { echo "install-v4:   $sub at $want"; continue; }
      echo "install-v4:   $sub is missing or not at $want in $parent, which was already installed (offline: nothing"
      echo "install-v4:   to fetch). Refused. V4_FORCE=1 replaces lib/v4-core with a checked copy of the local clone."
      return 1
    fi
    if [ -e "$parent/$sub/.git" ] && [ "${V4_FORCE:-0}" != "1" ]; then
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
# shellcheck disable=SC2086 # the submodule list is split into words on purpose
fetch_pinned v4-core "$V4_CORE_REPO" "$V4_CORE_PIN" $V4_CORE_SUBMODULES || rc=1
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
[ -n "$V4_LOCAL_SRC" ] && echo "source         local clones in $V4_LOCAL_SRC (offline), verified against the pins below"
echo "v4-core        $V4_CORE_PIN"
for sub in $V4_CORE_SUBMODULES; do
  if [ -e "$LIB/v4-core/$sub/.git" ]; then
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
