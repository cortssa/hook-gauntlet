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
#          BENCH_EXCLUDE  extra paths to leave out, space separated (e.g. "src script", or "*.hex *.json"). Two meanings,
#                         told apart per path on every refresh: a matching path that the PROJECT also has is withheld -
#                         never copied, and a stale copy of it left in the bench is removed; a matching path only the
#                         BENCH has (a fixture fetched into it) is the bench's own and is kept. The bench itself is never
#                         deleted. The unit is the MATCHING PATH: a pattern that names a DIRECTORY the project also has
#                         (BENCH_EXCLUDE="fixtures") withholds the whole directory, so a file that only the bench has
#                         INSIDE it (fixtures/Fetched.hex) is deleted with it on every refresh. To keep fetched files, name
#                         them by a file pattern ("*.hex"), not by their directory. Every run that withholds such a
#                         directory says so in one line: "bench: WARNING - ...: <dir> <dir>".
#          LINK_LIB       1 to symlink the project's dependency directories instead of copying them (default: 1). They are
#                         `lib/` at the root and `<dir>/lib/` beside every nested foundry.toml (a module such as v4/) -
#                         and nothing else called lib: `scripts/lib/` is source and is copied like the rest. A dependency
#                         directory the project does not have is left as the bench has it (installed into the bench?).
#          LINK_FROM      a directory to use as the bench's `lib/` when the PROJECT HAS NO `lib/` of its own (forge-std installed
#                         somewhere else, e.g. LINK_FROM=$HOME/deps/lib, a directory holding forge-std/). Linked under LINK_LIB=1,
#                         copied through its links otherwise (a bench that withholds holds no symlink; a LINK_FROM inside the
#                         project is then refused). The root `lib/` only. Ignored, with a note, when the project has a `lib/`;
#                         not applied over a `lib/` DIRECTORY the bench already has (installed into it). Without LINK_FROM, a
#                         project with no `lib/` gets nothing linked, and the run says so in one line - advising LINK_FROM,
#                         unless foundry.toml already names dependencies outside the project (an absolute or `../` `libs`
#                         entry, a remapping to an absolute path) or remappings.txt does (a line with an absolute
#                         target): then "nothing to link". A lib/ LINK an earlier
#                         LINK_FROM left in the bench is kept, and the run names it as that, with its target.
#          BENCH_KEEP     paths, relative to the bench, that a refresh never deletes (space separated, e.g. "corpus census"):
#                         what the bench has there survives `rsync --delete` even when the project has no such path, and
#                         what the PROJECT has there is merged in - added or updated, never deleting the bench's own files.
#                         scripts/fuzz-long.sh sets it for the campaign's corpus/ and census/, which live in the bench.
#          BENCH_ARTIFACTS  contract names whose COMPILED artifact is copied into <bench>/artifacts/ (e.g. "MyHook").
#                         A blackbox bench has no src/, so without this it could not deploy the thing it attacks.
#                         The artifact is ABI + bytecode, which any integrator can get; it is refused if it embeds
#                         literal source. Build the project first. In the bench, tests deploy it with
#                         deployCode("artifacts/MyHook.sol/MyHook.json", args) and foundry.toml needs
#                         fs_permissions = [{ access = "read", path = "./artifacts" }].
# Marker:  every bench this script makes holds a file `.gauntlet-bench` (never copied from the project, never deleted by
#          a refresh). A directory that EXISTS under the bench's name WITHOUT that marker is refused, in one line, before
#          anything is written: a refresh deletes whatever the project does not have, and a name reused for somebody's
#          working copy once let it wipe one. The refusal is never bypassed here: pick a name that does not exist.
#          (Benches made before the marker existed are refused too; remove one by hand, once, after reading it.)
# Output:  the absolute path of the bench, on stdout, as the last line.
# Exit:    0 created or refreshed, 1 usage or copy failure, or a directory under that name that is not a bench.

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

BENCH_KEEP="${BENCH_KEEP:-}"
LINK_FROM="${LINK_FROM:-}"
LINK_FROM_REAL=""
if [ -n "$LINK_FROM" ]; then
  LINK_FROM_REAL="$(cd "$LINK_FROM" 2> /dev/null && pwd -P)" || { echo "bench: LINK_FROM ($LINK_FROM) is not a directory. Refusing."; exit 1; }
fi
set -f
for k in $BENCH_KEEP; do
  case "/$k/" in
    //* | */../* | */./*) echo "bench: BENCH_KEEP path '$k' must be relative to the bench, with no '.' or '..' in it. Refusing."; exit 1 ;;
  esac
done
set +f

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

MARKER=".gauntlet-bench"
if { [ -e "$DEST" ] || [ -L "$DEST" ]; } && [ ! -f "$DEST/$MARKER" ]; then
  echo "bench: $DEST exists and holds no $MARKER marker (it is not a bench this script made): refusing to refresh it, a refresh deletes what the project does not have - pick a name that does not exist."
  exit 1
fi

made=0; [ -e "$DEST" ] || made=1
mkdir -p "$DEST" || exit 1
if ! refuse_overlap "$(cd "$DEST" && pwd -P)"; then
  [ "$made" -eq 1 ] && rmdir "$DEST" 2> /dev/null
  exit 1
fi
[ -f "$DEST/$MARKER" ] || printf 'a bench made by hook-gauntlet scripts/bench.sh (name %s, from %s). A refresh deletes what the project does not have.\n' \
  "$NAME" "$SRC_REAL" > "$DEST/$MARKER" || { echo "bench: cannot write the $MARKER marker into $DEST"; exit 1; }

# ... and it never gets a symlinked lib/: lib -> <project>/lib means lib/../src IS the source it was built to withhold.
if [ -n "$BENCH_EXCLUDE" ] && [ "$LINK_LIB" = "1" ]; then
  echo "bench: BENCH_EXCLUDE is set, so lib/ is COPIED, not linked (a link into the project leads straight back to its source)"
  LINK_LIB=0
fi

# The project's DEPENDENCY directories: `lib` at the root, and `<dir>/lib` beside every nested foundry.toml. Found, not
# guessed by name: an rsync `--exclude=lib` matches at ANY depth, and it used to drop `scripts/lib/` (the kit's own
# parser, source) and `v4/lib/` (a module's dependencies) alike - the second then had no link either, so every bench of
# a v4 project needed a network install again. Each is excluded ANCHORED from the copy below and handled on its own.
LIBS="lib"
while IFS= read -r t; do
  d="${t#./}"; d="${d%/foundry.toml}"
  [ "$d" = "foundry.toml" ] || [ -z "$d" ] || LIBS="$LIBS $d/lib"
done < <(cd "$SRC" && find . \( -name lib -o -name .git -o -name out -o -name cache -o -name node_modules -o -name .gauntlet \) -prune \
  -o -name foundry.toml -print 2> /dev/null | sort)

# An exclude that matches a DIRECTORY the project has withholds all of it: whatever the bench later puts inside it is
# removed with it on the next refresh (below, by name). Said out loud on every run, so it is read before it costs a file.
if [ -n "$BENCH_EXCLUDE" ]; then
  wdirs=""
  set -f
  for e in $BENCH_EXCLUDE; do
    set +f
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      rel="${m#"$SRC"/}"; skip=0
      for l in $LIBS; do case "$rel/" in "$l"/*) skip=1 ;; esac; done
      [ "$skip" -eq 0 ] && wdirs="$wdirs $rel"
    done < <(find "$SRC" -mindepth 1 \( -name .git -o -name out -o -name cache -o -name .gauntlet \) -prune \
      -o \( -path "$SRC/$e" -o -name "$e" \) -type d -prune -print 2> /dev/null)
    set -f
  done
  set +f
  [ -n "$wdirs" ] && echo "bench: WARNING - BENCH_EXCLUDE withholds whole directories the project has; a file only the bench has inside one is DELETED on every refresh:$wdirs"
fi

# out/ and cache/ are never copied: a bench that starts with somebody else's artifacts is the problem this
# script exists to avoid, and a stale artifact is worse than no artifact.
# the marker is the bench's own: excluded, so a refresh neither copies the project's (a bench of a bench) nor deletes it
EXCLUDES="out cache .git .gauntlet /$MARKER${BENCH_EXCLUDE:+ $BENCH_EXCLUDE}"
for l in $LIBS; do EXCLUDES="$EXCLUDES /$l"; done

set -f   # the patterns below may be globs (*.hex): they must reach rsync as written, not expanded against the cwd
if command -v rsync > /dev/null 2>&1; then
  args=()
  # BENCH_KEEP: protected from --delete (the path and everything under it), still sent to: the project's files there are
  # merged in and the bench's own stay. Before the excludes, so that the first matching rule for a kept path is this one.
  for k in $BENCH_KEEP; do args+=("--filter=P /$k" "--filter=P /$k/**"); done
  for e in $EXCLUDES; do args+=("--exclude=$e"); done
  # --delete does not remove an EXCLUDED path from the bench: that is what keeps a fixture fetched into the bench, and a
  # dependency directory installed into it, alive across a refresh. Withheld content is removed below, by name.
  rsync -a --delete ${args[@]+"${args[@]}"} "$SRC/" "$DEST/" || { echo "bench: rsync failed"; exit 1; }
else
  echo "bench: rsync not found, falling back to a full copy (slower, and it does not prune deletions)"
  targs=()
  for e in $EXCLUDES; do case "$e" in /*) targs+=("--exclude=.$e") ;; *) targs+=("--exclude=$e") ;; esac; done
  (cd "$SRC" && tar ${targs[@]+"${targs[@]}"} -cf - .) | (cd "$DEST" && tar -xf -) || { echo "bench: copy failed"; exit 1; }
fi
set +f

# a path is under one of the dependency directories (they are checked and copied on their own terms)
under_lib() { local l; for l in $LIBS; do case "$1/" in "$DEST/$l"/*) return 0 ;; esac; done; return 1; }

# Withheld content: a path in the bench that matches an exclude pattern AND exists in the project is a copy of what the
# bench must not hold (a bench of the same name made earlier without the exclude) - removed, by name. A match that exists
# only in the bench is the bench's own (a fixture fetched into it) - kept. The bench directory itself is never removed:
# it used to be (`rm -rf "$DEST"`), and that deleted the fetched fixtures the v4 README says this keeps, and lib/ with them.
kept_own=""
if [ -n "$BENCH_EXCLUDE" ]; then
  set -f
  for e in $BENCH_EXCLUDE; do
    set +f
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      under_lib "$m" && continue
      rel="${m#"$DEST"/}"
      if [ -e "$SRC/$rel" ] || [ -L "$SRC/$rel" ]; then
        rm -rf "${DEST:?}/$rel"
      else
        kept_own="$kept_own $rel"
      fi
    done < <(find "$DEST" -mindepth 1 \( -path "$DEST/$e" -o -name "$e" \) -prune -print 2> /dev/null)
    set -f
  done
  set +f
fi

# deps_from_toml <foundry.toml>: true when it already says where the dependencies live OUTSIDE the project - a `libs`
# entry that is absolute or goes up (`/...`, `~/...`, `C:/...`, `../...`), or a remapping whose target is absolute. Read
# from every `libs = [...]` and `remappings = [...]` in the file, one line or several; comments are skipped.
deps_from_toml() {
  [ -f "$1" ] || return 1
  awk -v sq="'" '
    function outside_lib(p) { return p ~ /^(\/|~|[A-Za-z]:[\/\\]|\.\.([\/\\]|$))/ }
    function outside_remap(r,  t) { t = r; sub(/^[^=]*=/, "", t); return t ~ /^(\/|~|[A-Za-z]:[\/\\])/ }
    function scan(s, kind,  q) {
      while (match(s, "\"[^\"]*\"|" sq "[^" sq "]*" sq)) {
        q = substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH)
        if (kind == "libs" && outside_lib(q)) found = 1
        if (kind == "remappings" && outside_remap(q)) found = 1
      }
    }
    { sub(/\r$/, "") }
    /^[ 	]*#/ { next }
    !kind && match($0, /^[ 	]*(libs|remappings)[ 	]*=/) {
      kind = $0; sub(/^[ 	]*/, "", kind); sub(/[ 	]*=.*/, "", kind)
      rest = substr($0, RSTART + RLENGTH)
      scan(rest, kind)
      if (rest ~ /\]/) kind = ""
      next
    }
    kind { scan($0, kind); if ($0 ~ /\]/) kind = "" }
    END { exit found ? 0 : 1 }' "$1"
}

# deps_from_remappings_txt <remappings.txt>: true when a line of it (`[context:]prefix=target`, forge reads the file as
# well as foundry.toml) has an ABSOLUTE target (`/...`, `~/...`, `C:/...`). CRLF, blank lines and `#` lines are skipped.
deps_from_remappings_txt() {
  [ -f "$1" ] || return 1
  awk '
    { sub(/\r$/, "") }
    /^[ 	]*#/ || /^[ 	]*$/ { next }
    { t = $0; sub(/^[ 	]*/, "", t); if (t !~ /=/) next; sub(/^[^=]*=[ 	]*/, "", t); if (t ~ /^(\/|~|[A-Za-z]:[\/\\])/) found = 1 }
    END { exit found ? 0 : 1 }' "$1"
}

# the dependency directories, one by one: linked (LINK_LIB=1), copied through their links (a bench that withholds), or
# synced as they are (LINK_LIB=0); one the project does not have is the bench's own and is left alone
outward=0
for l in $LIBS; do
  from="$SRC/$l"
  if [ "$l" = "lib" ] && [ -n "$LINK_FROM" ] && [ -e "$SRC/lib" ]; then
    echo "bench: LINK_FROM ignored: the project has a lib/ of its own"
  fi
  if [ ! -e "$SRC/$l" ]; then
    # a project with no root lib/ (forge-std installed elsewhere): LINK_FROM names the directory to use instead - but
    # never over a lib/ DIRECTORY the bench already has (installed into it: deleting it would cost a reinstall)
    if [ "$l" = "lib" ] && [ -n "$LINK_FROM" ] && { [ -L "$DEST/lib" ] || [ ! -e "$DEST/lib" ]; }; then
      from="$LINK_FROM_REAL"
      echo "bench: the project has no lib/: the bench's lib/ is LINK_FROM ($from)"
    else
      if [ "$l" = "lib" ] && [ -L "$DEST/lib" ]; then
        # a LINK is not "the bench's own": an earlier run made it - to LINK_FROM, or to the lib/ the project had then
        t="$(readlink "$DEST/lib")"
        if [ "$t" = "$SRC/lib" ]; then
          echo "bench: lib/ is a link left by an earlier run, to the project's lib/ that no longer exists: $t (kept; set LINK_FROM to replace it)"
        else
          echo "bench: lib/ is a link left by an earlier LINK_FROM: $t (kept; set LINK_FROM to change it)"
        fi
      elif [ -e "$DEST/$l" ]; then
        echo "bench: $l/ is the bench's own (the project has none): kept as it is"
        [ "$l" = "lib" ] && [ -n "$LINK_FROM" ] && echo "bench: LINK_FROM not applied: the bench's lib/ is a directory of its own (remove it to link)"
      elif [ "$l" = "lib" ] && deps_from_toml "$SRC/foundry.toml"; then
        # forge-std through an absolute `libs`, the kit through a remapping to its path (FR7's toy): the bench compiles
        # as it is, and advising LINK_FROM sent a fresh reader looking for a directory nobody needed
        echo "bench: no lib/; dependencies come from foundry.toml (libs / remappings): nothing to link"
      elif [ "$l" = "lib" ] && deps_from_remappings_txt "$SRC/remappings.txt"; then
        # the same, with the absolute remapping in remappings.txt: foundry.toml alone was read, and advised LINK_FROM (FR8)
        echo "bench: no lib/; dependencies come from remappings.txt (an absolute remapping): nothing to link"
      elif [ "$l" = "lib" ]; then
        echo "bench: the project has no lib/: nothing linked; set LINK_FROM=<dir with forge-std>"
      fi
      continue
    fi
  fi
  if [ "$LINK_LIB" = "1" ]; then
    rm -rf "${DEST:?}/$l"; mkdir -p "$(dirname "$DEST/$l")"
    ln -s "$from" "$DEST/$l"
  elif [ -n "$BENCH_EXCLUDE" ]; then
    # the project's lib/ may itself be a link to a shared directory: copy what it POINTS AT, so nothing in the bench
    # leads outside the bench ... but `cp -RL` follows EVERY link under it, and a monorepo's `lib/core -> ../src` would
    # carry the withheld source into the bench under a directory the check below does not look inside (libraries have
    # a src/ of their own). So: a link under it that resolves into the project, and outside it, is refused before
    # anything is copied. Only links physically under it are examined; a chain that leaves it and comes back by a
    # second link is not.
    LIB_REAL="$(cd "$from" && pwd -P)"
    if [ "$from" = "$LINK_FROM_REAL" ]; then
      case "$LIB_REAL/" in "$SRC_REAL"/*)
        echo "bench: LINK_FROM ($LIB_REAL) is inside the project: copying it would bring project files into a bench that withholds. Refusing."
        exit 1 ;;
      esac
    fi
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      if [ -d "$k" ]; then
        t="$(cd "$k" && pwd -P)"
      else
        tgt="$(readlink "$k")"
        case "$tgt" in /*) ;; *) tgt="$(dirname "$k")/$tgt" ;; esac
        t="$(cd "$(dirname "$tgt")" 2> /dev/null && pwd -P)/$(basename "$tgt")"
      fi
      case "$t/" in "$LIB_REAL"/*) continue ;; esac
      case "$t/" in "$SRC_REAL"/*)
        echo "bench: $l/ holds a link into the project itself: $k -> $t"
        echo "       Copying it would bring withheld files into a bench that exists to withhold them. Refusing."
        exit 1 ;;
      esac
    done < <(find "$from/" -type l 2> /dev/null)
    # ... and that is a limit the person RECEIVING the bench has to be told about, not only the person reading this file
    n="$(find "$from/" -type l 2> /dev/null | wc -l | tr -d ' ')"
    [ -L "$from" ] && n=$((n + 1))
    outward=$((outward + n))
    rm -rf "${DEST:?}/$l"; mkdir -p "$(dirname "$DEST/$l")"
    cp -RL "$from" "$DEST/$l" || { echo "bench: cannot copy $l/"; exit 1; }
  else
    # a link left by an earlier LINK_LIB=1 bench leads into the project: syncing INTO it would write the project's lib/
    [ -L "$DEST/$l" ] && rm -f "$DEST/$l"
    mkdir -p "$DEST/$l"
    rsync -a --delete "$from/" "$DEST/$l/" 2> /dev/null || { rm -rf "${DEST:?}/$l"; cp -R "$from" "$DEST/$l"; } \
      || { echo "bench: cannot copy $l/"; exit 1; }
  fi
done

if [ -n "$BENCH_EXCLUDE" ]; then
  # verify, do not trust: no excluded path the PROJECT has may be in the bench, and no symlink may remain
  bad=0
  set -f
  for e in $BENCH_EXCLUDE; do
    set +f
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      under_lib "$m" && continue
      rel="${m#"$DEST"/}"
      if [ -e "$SRC/$rel" ] || [ -L "$SRC/$rel" ]; then echo "bench: EXCLUDED path '$rel' is present in the bench"; bad=1; fi
    done < <(find "$DEST" -mindepth 1 \( -path "$DEST/$e" -o -name "$e" \) -prune -print 2> /dev/null)
    set -f
  done
  set +f
  if [ -n "$(find "$DEST" -type l -print -quit)" ]; then
    echo "bench: a symlink remains in a bench that withholds files:"; find "$DEST" -type l | head -5; bad=1
  fi
  [ "$bad" -eq 0 ] || { echo "bench: the bench is NOT isolated. Refusing to hand it over."; exit 1; }
  echo "bench: isolation verified - excluded paths absent, no symlinks"
  [ -n "$kept_own" ] && echo "bench: kept, the bench's own (matching an exclude, absent from the project):$kept_own"
  if [ "$outward" -gt 0 ]; then
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
    if grep -q '"content"[ 	]*:' "$a"; then
      echo "bench: the artifact of $c embeds literal source (metadata.useLiteralContent?) - refusing to hand it to a blackbox bench"; exit 1
    fi
    mkdir -p "$DEST/artifacts/$c.sol" && cp "$a" "$DEST/artifacts/$c.sol/$c.json" || exit 1
  done
  echo "bench: artifacts copied for:$BENCH_ARTIFACTS"
fi

echo "bench '$NAME' ready, excluding:$EXCLUDES"
echo "$DEST"
