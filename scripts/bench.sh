#!/usr/bin/env bash
#
# bench.sh - give an agent its own copy of the project to work in.
#
# The problem it solves: two agents, one build directory. Foundry writes into `out/` and `cache/`, so two
# runs in the same tree corrupt each other's artifacts and produce failures that belong to neither of them.
# Worse, they are not reproducible, so the time goes into chasing a ghost. One bench per agent, named after
# the agent, costs a copy and removes the whole class.
#
# It also does the other kind of isolation: a blackbox reviewer is supposed to attack the promises without
# reading the code, and the strongest way to arrange that is not to ask nicely, it is to hand over a bench
# that does not contain the code. BENCH_EXCLUDE="src" does that.
#
# Usage:   scripts/bench.sh <name> [project-dir]
# Env:     BENCH_ROOT     where benches live (default: $HOME/.gauntlet/bench)
#          BENCH_EXCLUDE  extra paths to leave out, space separated (e.g. "src script")
#          LINK_LIB       1 to symlink the project's lib/ instead of copying it (default: 1)
#          BENCH_ARTIFACTS  contract names whose COMPILED artifact is copied into <bench>/artifacts/ (e.g. "MyHook").
#                         A blackbox bench has no src/, so without this it could not deploy the thing it attacks.
#                         The artifact is ABI + bytecode, which any integrator can get; it is refused if it embeds
#                         literal source. Build the project first. In the bench, tests deploy it with
#                         deployCode("artifacts/MyHook.sol/MyHook.json", args) and foundry.toml needs
#                         fs_permissions = [{ access = "read", path = "./artifacts" }].
# Output:  the absolute path of the bench, on stdout, as the last line.
# Exit:    0 created or refreshed, 1 usage or copy failure.

set -uo pipefail

NAME="${1:-}"
PROJECT="${2:-.}"
if [ -z "$NAME" ] || [ "$NAME" != "${NAME##*/}" ] || [ "$NAME" = "." ] || [ "$NAME" = ".." ]; then
  echo "usage: bench.sh <name> [project-dir]   (name must not contain a slash, and '.' and '..' are not names)"
  exit 1
fi

BENCH_ROOT="${BENCH_ROOT:-$HOME/.gauntlet/bench}"
BENCH_EXCLUDE="${BENCH_EXCLUDE:-}"
LINK_LIB="${LINK_LIB:-1}"

SRC="$(cd "$PROJECT" && pwd)" || { echo "bench: cannot enter $PROJECT"; exit 1; }

# The bench and the project must be two different places, and neither may contain the other. Everything below deletes
# inside DEST (rm -rf, rsync --delete): with BENCH_ROOT set to the project's parent and NAME to the project's own folder
# this script used to DELETE THE PROJECT, exit 0 and print "isolation verified".
#
# The check is made TWICE, because the first version of it was beaten twice. Before anything exists, on a path made
# absolute and free of `..` (a relative root that did not exist yet lost a slash and compared "<cwd>benches"; a `..` after
# a component that did not exist yet was compared as text, then `mkdir -p` made it real and DEST was somewhere else). And
# again AFTER `mkdir -p`, on the path the file system itself resolves - the one that is about to be deleted into. Nothing
# is removed before the second check has passed.
case "$BENCH_ROOT" in /*) ;; *) BENCH_ROOT="$PWD/$BENCH_ROOT" ;; esac
case "/$BENCH_ROOT/" in
  */../*) echo "bench: BENCH_ROOT ($BENCH_ROOT) contains '..'. Give the place itself, not a route to it: a '..' after a"
          echo "       directory that does not exist yet cannot be checked before it is created. Refusing."; exit 1 ;;
esac
DEST="$BENCH_ROOT/$NAME"
SRC_REAL="$(cd "$SRC" && pwd -P)"

refuse_overlap() { # refuse_overlap <resolved path of the bench>
  case "$1/" in "$SRC_REAL"/*) ;; *) case "$SRC_REAL/" in "$1"/*) ;; *) return 0 ;; esac ;; esac
  echo "bench: the bench ($1) and the project ($SRC_REAL) overlap. A bench is rebuilt by DELETING what is in it:"
  echo "       refusing. Pick a BENCH_ROOT outside the project, and a name that is not the project's own folder."
  return 1
}

probe="$BENCH_ROOT"
while [ ! -d "$probe" ]; do probe="$(dirname "$probe")"; done
refuse_overlap "$(cd "$probe" && pwd -P)${BENCH_ROOT#"$probe"}/$NAME" || exit 1

made=0; [ -e "$DEST" ] || made=1
mkdir -p "$DEST" || exit 1
if ! refuse_overlap "$(cd "$DEST" && pwd -P)"; then
  [ "$made" -eq 1 ] && rmdir "$DEST" 2> /dev/null
  exit 1
fi

# A bench that EXCLUDES something (a black-box bench) is rebuilt from nothing: rsync --delete does not remove paths it
# was told to exclude, so re-using a bench name used to leave the old src/ in place under a message saying it was gone.
if [ -n "$BENCH_EXCLUDE" ]; then rm -rf "${DEST:?}"; mkdir -p "$DEST" || exit 1; fi

# ... and it never gets a symlinked lib/: lib -> <project>/lib means lib/../src IS the source it was built to withhold.
if [ -n "$BENCH_EXCLUDE" ] && [ "$LINK_LIB" = "1" ]; then
  echo "bench: BENCH_EXCLUDE is set, so lib/ is COPIED, not linked (a link into the project leads straight back to its source)"
  LINK_LIB=0
fi

# out/ and cache/ are never copied: a bench that starts with somebody else's artifacts is the problem this
# script exists to avoid, and a stale artifact is worse than no artifact.
EXCLUDES="out cache .git .gauntlet $BENCH_EXCLUDE"
[ "$LINK_LIB" = "1" ] && EXCLUDES="$EXCLUDES lib"

set -f   # the patterns below may be globs (*.hex): they must reach rsync as written, not expanded against the cwd
if command -v rsync > /dev/null 2>&1; then
  args=()
  for e in $EXCLUDES; do args+=("--exclude=$e"); done
  rsync -a --delete ${args[@]+"${args[@]}"} "$SRC/" "$DEST/" || { echo "bench: rsync failed"; exit 1; }
else
  echo "bench: rsync not found, falling back to a full copy (slower, and it does not prune deletions)"
  for e in $EXCLUDES; do rm -rf "${DEST:?}/$e"; done
  (cd "$SRC" && tar --exclude='./out' --exclude='./cache' --exclude='./.git' -cf - .) \
    | (cd "$DEST" && tar -xf -) || { echo "bench: copy failed"; exit 1; }
  for e in $EXCLUDES; do rm -rf "${DEST:?}/$e"; done
fi

set +f

if [ "$LINK_LIB" = "1" ] && [ -e "$SRC/lib" ]; then
  rm -rf "$DEST/lib"
  ln -s "$SRC/lib" "$DEST/lib"
fi

if [ -n "$BENCH_EXCLUDE" ]; then
  # the project's lib/ may itself be a link to a shared directory: copy what it POINTS AT, so nothing in the bench
  # leads outside the bench
  if [ -e "$SRC/lib" ]; then
    # ... but `cp -RL` follows EVERY link under lib/, and a monorepo's `lib/core -> ../src` would carry the withheld
    # source into the bench under a directory the check below does not look inside (libraries have a src/ of their
    # own). So: a link under lib/ that resolves into the project, and outside lib/, is refused before anything is copied.
    # Only links physically under lib/ are examined; a chain that leaves lib/ and comes back by a second link is not.
    LIB_REAL="$(cd "$SRC/lib" && pwd -P)"
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      if [ -d "$l" ]; then
        t="$(cd "$l" && pwd -P)"
      else
        tgt="$(readlink "$l")"
        case "$tgt" in /*) ;; *) tgt="$(dirname "$l")/$tgt" ;; esac
        t="$(cd "$(dirname "$tgt")" 2> /dev/null && pwd -P)/$(basename "$tgt")"
      fi
      case "$t/" in "$LIB_REAL"/*) continue ;; esac
      case "$t/" in "$SRC_REAL"/*)
        echo "bench: lib/ holds a link into the project itself: $l -> $t"
        echo "       Copying it would bring withheld files into a bench that exists to withhold them. Refusing."
        exit 1 ;;
      esac
    done < <(find "$SRC/lib/" -type l 2> /dev/null)
    # ... and that is a limit the person RECEIVING the bench has to be told about, not only the person reading this file
    outward="$(find "$SRC/lib/" -type l 2> /dev/null | wc -l | tr -d ' ')"
    [ -L "$SRC/lib" ] && outward=$((outward + 1))
    rm -rf "$DEST/lib"; cp -RL "$SRC/lib" "$DEST/lib" || { echo "bench: cannot copy lib/"; exit 1; }
  fi
  # verify, do not trust: every excluded path must be absent, and no symlink may remain
  bad=0
  set -f
  for e in $BENCH_EXCLUDE; do
    set +f
    if [ -n "$(find "$DEST" -mindepth 1 \( -path "$DEST/$e" -o -name "$e" \) -not -path "$DEST/lib/*" -print -quit)" ]; then
      echo "bench: EXCLUDED path '$e' is present in the bench"; bad=1
    fi
    set -f
  done
  set +f
  if [ -n "$(find "$DEST" -type l -print -quit)" ]; then
    echo "bench: a symlink remains in a bench that withholds files:"; find "$DEST" -type l | head -5; bad=1
  fi
  [ "$bad" -eq 0 ] || { echo "bench: the bench is NOT isolated. Refusing to hand it over."; exit 1; }
  echo "bench: isolation verified - excluded paths absent, no symlinks"
  if [ "${outward:-0}" -gt 0 ]; then
    echo "bench: NOTE - lib/ was copied THROUGH $outward symbolic link(s). Each was checked not to point into the project; what"
    echo "       lies behind them (a second link that comes back?) was NOT examined. Look inside lib/ before trusting the isolation."
  fi
fi

BENCH_ARTIFACTS="${BENCH_ARTIFACTS:-}"
if [ -n "$BENCH_ARTIFACTS" ]; then
  rm -rf "$DEST/artifacts"
  for c in $BENCH_ARTIFACTS; do
    a="$SRC/out/$c.sol/$c.json"
    [ -f "$a" ] || { echo "bench: no artifact for $c at out/$c.sol/$c.json - build the project first"; exit 1; }
    if grep -q '"content"[[:space:]]*:' "$a"; then
      echo "bench: the artifact of $c embeds literal source (metadata.useLiteralContent?) - refusing to hand it to a blackbox bench"; exit 1
    fi
    mkdir -p "$DEST/artifacts/$c.sol" && cp "$a" "$DEST/artifacts/$c.sol/$c.json" || exit 1
  done
  echo "bench: artifacts copied for:$BENCH_ARTIFACTS"
fi

echo "bench '$NAME' ready, excluding:$EXCLUDES"
echo "$DEST"
