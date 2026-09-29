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
# Env:     BENCH_ROOT     where benches live (default: <project>/.gauntlet/bench - inside the project, in the one directory
#                         no copy ever enters: `.gauntlet` is left out of every bench, so a bench never holds a bench;
#                         never $HOME, which is shared by every project and every agent on the machine). The project's
#                         `.gauntlet/.gitignore` (state/.gitignore, installed with the state files) keeps it out of git.
#                         The default applies only where the kit's convention is installed - `<project>/.gauntlet/` already
#                         exists: in a tree without it (someone else's hook, doctrine/RETROFIT.md: a bench of your own,
#                         never their working tree) the run is REFUSED before anything is written, and asks for a
#                         BENCH_ROOT outside the project. A root inside the project anywhere but under a `.gauntlet/` is
#                         refused (a refresh would copy the bench into itself), and so is one that contains the project.
#                         A bench that withholds the SOURCE (a BENCH_EXCLUDE pattern whose last component matches `src`:
#                         "src", "src script", "v4/src") is refused anywhere inside the project, `.gauntlet/` included:
#                         what it withholds is what it HOLDS, and from <project>/.gauntlet/bench/<name> `../../..` is the
#                         project, source and all. Set BENCH_ROOT to a directory outside the project (briefs/black-box.md).
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
#                         unless foundry.toml already names dependencies outside the project (an absolute `libs` entry, a
#                         remapping to an absolute path) or remappings.txt does (a line with an absolute target): then
#                         "nothing to link"; or unless they reach out of it by a RELATIVE path (`../`, below): then what
#                         `../` reaches is put beside the project's copy, and LINK_FROM is not advised. A lib/ LINK an earlier
#                         LINK_FROM left in the bench is kept, and the run names it as that, with its target.
# Reaching out: a project whose foundry.toml or remappings.txt names a path that leaves it by `../` - the kit vendored
#          BESIDE it (`../lib/hook-gauntlet/foundry-kit/...` as a remapping, in `allow_paths`, in a compilation restriction),
#          a `libs = ["../deps"]` - cannot compile from a copy of itself alone: `../` from the bench is whatever lies beside
#          the bench. So the bench holds the project as many levels down as its deepest `../`, at <bench>/<its folder>
#          (two levels: <bench>/<parent's folder>/<its folder>), and each place a `../` reaches - the first directory on
#          the way that does not hold the project: `lib` for `../lib/hook-gauntlet/...` - is linked at its own relative
#          place in the bench (copied through its links in a bench that withholds, as lib/ is; synced with LINK_LIB=0),
#          one line each: "bench: ../lib -> <where it is>: linked at <bench>/lib". What is named comes WHOLE: `../lib`
#          for `../lib/hook-gauntlet/...` is all of `../lib`, whatever else lies in it (another project, the owner's notes)
#          - in a bench that withholds, where it is copied, one line says so and names what it holds: "bench: WARNING -
#          ../lib is copied WHOLE into a bench that withholds: everything in <where it is>, not only what the project
#          names in it: <its entries>". Look at them before handing the bench over. A sibling nobody names (a log
#          directory beside the project) is not copied. A path that comes back INTO the
#          project (`../proj/src`) is the copy itself; one that does not exist is named in one line, and nothing is linked
#          for it; one that HOLDS the project (`../` alone, `../..`) cannot be put beside it and is refused before anything
#          is written, and so is one that RESOLVES into the project or to a directory holding it (a link: `../projlink/`,
#          projlink -> the project). A `.` or `..` after a name (`../a/../b`) is not followed, and says so.
#          The bench is ONE place: on a refresh, what an earlier layout left at its root is removed before the copy (a
#          project copied at <bench>/ before it reached `../`, at <bench>/<its folder> after - the old <bench>/src would
#          be `../src` from the place to work), in one line naming it; and a bench that withholds is checked over all of
#          it, not only the project's copy (below).
#          BENCH_KEEP     paths that a refresh in the same layout never deletes (space separated, e.g. "corpus census"):
#                         what the bench has there survives `rsync --delete` even when the project has no such path, and
#                         what the PROJECT has there is merged in - added or updated, never deleting the bench's own files.
#                         scripts/fuzz-long.sh sets it for the campaign's corpus/ and census/, which live in the bench.
#                         Relative to the project's copy, and kept while the copy stays where it is. A change of layout
#                         ("Reaching out": the copy moves between <bench>/ and <bench>/<its folder>) DOES delete them: what
#                         the earlier layout left at the bench's root goes, a kept path in the old copy with it, named in
#                         the "removed ... left by an earlier layout" line (a corpus/ kept in a flat bench is gone once the
#                         project reaches `../`). Move what you want to keep out of the bench before the layout changes.
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
#          In a bench that withholds (BENCH_EXCLUDE set) the marker names the project by a hash of its path (cksum), not
#          by the path - a black-box reader must not be handed the way to the source. It is rewritten on every run, so a
#          marker an earlier version wrote with the path does not survive a refresh, and its line `place: <folder>` (`.`:
#          the bench itself) says where the project's copy is - what the next refresh reads to find an earlier layout's
#          leftovers ("Reaching out"). A marker without that line was written when every copy was at <bench>/ itself.
# Isolation: a bench that withholds is checked, after the copy, over the WHOLE bench: an excluded path the project has
#          in its copy, a match outside the copy and outside what `../` reaches (an earlier layout's leftover that could
#          not be removed), or any symlink - and the run is refused (rc 1), never "isolation verified".
# Output:  the absolute path of the project's copy in the bench, on stdout, as the last line: the bench itself, or
#          <bench>/<its folder> for a project that reaches out by `../` (above) - where to work.
# Exit:    0 created or refreshed, 1 usage or copy failure, or a directory under that name that is not a bench.

set -uo pipefail

NAME="${1:-}"
PROJECT="${2:-.}"
if [ -z "$NAME" ] || [ "$NAME" != "${NAME##*/}" ] || [ "$NAME" = "." ] || [ "$NAME" = ".." ]; then
  echo "usage: bench.sh <name> [project-dir]   (name must not contain a slash, and '.' and '..' are not names)"
  exit 1
fi

BENCH_EXCLUDE="${BENCH_EXCLUDE:-}"
LINK_LIB="${LINK_LIB:-1}"

SRC="$(cd "$PROJECT" && pwd)" || { echo "bench: cannot enter $PROJECT"; exit 1; }
ROOT_DEFAULT=0; [ -n "${BENCH_ROOT:-}" ] || ROOT_DEFAULT=1
BENCH_ROOT="${BENCH_ROOT:-$SRC/.gauntlet/bench}"

# a bench that withholds the source: a BENCH_EXCLUDE pattern whose last path component matches `src` (as a glob: "src",
# "/src/", "v4/src", "s*" - the patterns the copy below leaves out by name, at any depth)
WITHHOLDS_SRC=0
set -f
for e in $BENCH_EXCLUDE; do
  b="${e%/}"; b="${b##*/}"
  # shellcheck disable=SC2194,SC2254   # a constant word against a pattern: the pattern is meant to match as a glob
  case src in $b) WITHHOLDS_SRC=1 ;; esac
done
set +f

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

# Reaching out (header, K32 - FR16: the kit vendored beside the project, `../lib/hook-gauntlet/...` in remappings.txt;
# the bench's `../lib` resolved to nothing, and the run advised LINK_FROM, which fills the bench's OWN lib/). Every `../`
# path of foundry.toml and remappings.txt (comments skipped) is walked from the directory it goes up to, one name at a
# time, to the first directory that does not hold the project: that is what the bench needs beside the project's copy.
# Read, and a `../` that holds the project refused, before anything is written.
outward_refs() {
  local f
  for f in "$SRC/foundry.toml" "$SRC/remappings.txt"; do
    [ -f "$f" ] || continue
    # comment lines, and a comment after a value, are not paths; `..` counts only as a path of its own - followed by `/`,
    # a quote, a comma, a space or the end, never the ellipsis of a sentence ("...with")
    tr -d '\r' < "$f" | grep -v '^[[:space:]]*#' | sed 's/[[:space:]]#.*$//' \
      | grep -oE "(^|[^A-Za-z0-9_.@/-])\.\.(/[^\"'[:space:],]*|[\"',[:space:]]|\$)" | sed -E "s/^[^.]//; s/[\"',[:space:]]\$//"
  done | sort -u
}
OUT_UPS=0; declare -a OUT_TGTS=(); declare -A OUT_LAB=()
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  r="${ref%/}"; k=0
  while [ "${r#../}" != "$r" ]; do r="${r#../}"; k=$((k + 1)); done
  if [ "$r" = ".." ]; then r=""; k=$((k + 1)); fi
  case "/$r/" in */../* | */./*) echo "bench: $ref: a '.' or '..' after a name is not followed - read that path yourself"; continue ;; esac
  base="$SRC_REAL"; lab=""
  for _ in $(seq 1 "$k"); do base="$(dirname "$base")"; lab="${lab:+$lab/}.."; done
  [ "$k" -gt "$OUT_UPS" ] && OUT_UPS="$k"
  cur="$base"; rest="$r"; tgt=""
  while :; do
    [ "$cur" = "$SRC_REAL" ] && break                                # back INTO the project: the copy itself
    case "$SRC_REAL/" in "${cur%/}"/*) ;; *) tgt="$cur"; break ;; esac  # the first directory that does not hold it
    if [ -z "$rest" ]; then
      echo "bench: $ref (in $SRC's foundry.toml or remappings.txt) reaches $cur, the directory that holds the project: it cannot be"
      echo "       put beside the project's copy without being the project. Refusing, nothing written: bench that directory"
      echo "       instead (scripts/bench.sh <name> $cur) and work at the project's place inside it."
      exit 1
    fi
    c="${rest%%/*}"; if [ "$c" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    [ -n "$c" ] || continue
    cur="${cur%/}/$c"; lab="$lab/$c"
  done
  [ -n "$tgt" ] || continue
  # ... and a target that is a LINK back into the project (`../projlink/...`, projlink -> the project) is the project, source
  # and all, under another name: the walk above compares names, so the place it resolves to is compared too (V32)
  if [ -e "$tgt" ]; then
    if [ -d "$tgt" ]; then tr="$(cd "$tgt" && pwd -P)"
    else
      tr="$tgt"; [ -L "$tr" ] && { tg="$(readlink "$tr")"; case "$tg" in /*) tr="$tg" ;; *) tr="$(dirname "$tr")/$tg" ;; esac; }
      tr="$(cd "$(dirname "$tr")" 2> /dev/null && pwd -P)/$(basename "$tr")"
    fi
    what=""
    case "$SRC_REAL/" in "${tr%/}"/*) what="resolves to $tr, which holds the project" ;; esac
    case "$tr/" in "$SRC_REAL"/*) what="resolves into the project ($tr)" ;; esac
    if [ -n "$what" ]; then
      echo "bench: $lab -> $tgt $what: a link. Put beside the project's copy it would BE the"
      echo "       project - what the bench withholds included. Refusing, nothing written: name the path inside the project instead."
      exit 1
    fi
  fi
  if [ -z "${OUT_LAB[$tgt]+x}" ]; then OUT_TGTS+=("$tgt"); OUT_LAB[$tgt]="$lab"; fi
done < <(outward_refs)
# the project's place in the bench: as many levels down as the deepest `../`, named as its own folders are
NEST=""; OUT_TOP="$SRC_REAL"
for _ in $(seq 1 "$OUT_UPS"); do
  [ "$OUT_TOP" != "/" ] || { echo "bench: $SRC reaches more levels up (../) than it has directories above it. Refusing."; exit 1; }
  NEST="$(basename "$OUT_TOP")${NEST:+/$NEST}"; OUT_TOP="$(dirname "$OUT_TOP")"
done
PDEST="$DEST${NEST:+/$NEST}"

refuse_overlap() { # refuse_overlap <resolved path of the bench>
  # a source-free bench inside the project is not source-free: `../../..` from <project>/.gauntlet/bench/<name> is the
  # project (V26: "isolation verified", and `ls ../../../src` listed the source). Anywhere inside it, `.gauntlet/` included.
  if [ "$WITHHOLDS_SRC" = 1 ]; then
    case "$1/" in "$SRC_REAL"/*)
      echo "bench: a bench that withholds the source (BENCH_EXCLUDE=\"$BENCH_EXCLUDE\") would be inside the project ($1): from there"
      echo "       ../ leads back to $SRC_REAL and its source, so it withholds nothing. Refusing: set BENCH_ROOT=<a directory outside the project>."
      return 1 ;;
    esac
  fi
  # ... with ONE place inside the project allowed: strictly under a `.gauntlet` directory (the default root is
  # <project>/.gauntlet/bench). No copy below enters a `.gauntlet` (rsync and tar exclude the name at any depth, the
  # searches prune it), so the bench is never copied into itself and nothing in it is the project's.
  case "$1/" in
    "$SRC_REAL"/*) case "/${1#"$SRC_REAL"/}/" in */.gauntlet/?*/*) return 0 ;; esac ;;
    *) case "$SRC_REAL/" in "$1"/*) ;; *) return 0 ;; esac ;;
  esac
  echo "bench: the bench ($1) and the project ($SRC_REAL) overlap. A bench is rebuilt by DELETING what is in it:"
  echo "       refusing. Leave BENCH_ROOT unset (<project>/.gauntlet/bench), or pick one outside the project, and a name that is not the project's own folder."
  return 1
}

probe="$BENCH_ROOT"
while [ ! -d "$probe" ]; do probe="$(dirname "$probe")"; done
refuse_overlap "$(cd "$probe" && pwd -P)${BENCH_ROOT#"$probe"}/$NAME" || exit 1
# the default root is inside the project: only where the kit's convention is installed (<project>/.gauntlet/ exists). In
# a tree without it - an existing hook, someone else's working tree (doctrine/RETROFIT.md) - nothing is written into it.
if [ "$ROOT_DEFAULT" = 1 ] && [ ! -d "$SRC/.gauntlet" ]; then
  echo "bench: BENCH_ROOT is not set, and $SRC has no .gauntlet/ (the kit's convention is not installed there): the default"
  echo "       bench would be written into that tree - doctrine/RETROFIT.md: a bench of your own, never their working tree."
  echo "       Refusing, nothing written: set BENCH_ROOT=<a directory outside the project>."
  exit 1
fi

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
# where the project's copy was in this bench before this run (header, Marker: the `place:` line; none = <bench>/ itself)
OLD_PLACE="."
if [ -f "$DEST/$MARKER" ]; then
  OLD_PLACE="$(sed -n 's/^place: //p' "$DEST/$MARKER" | head -1)"; [ -n "$OLD_PLACE" ] || OLD_PLACE="."
fi
if [ -n "$BENCH_EXCLUDE" ]; then
  # a bench that withholds: the project by a hash of its path, not the path (the reader of this bench is not to be
  # pointed at the source); rewritten every run, so an older marker with the path does not survive a refresh
  printf 'a bench made by hook-gauntlet scripts/bench.sh (name %s, withholding: %s; from a project whose path has cksum %s). A refresh deletes what the project does not have.\nplace: %s\n' \
    "$NAME" "$BENCH_EXCLUDE" "$(printf '%s' "$SRC_REAL" | cksum | cut -d ' ' -f 1)" "${NEST:-.}" > "$DEST/$MARKER" \
    || { echo "bench: cannot write the $MARKER marker into $DEST"; exit 1; }
else
  printf 'a bench made by hook-gauntlet scripts/bench.sh (name %s, from %s). A refresh deletes what the project does not have.\nplace: %s\n' \
    "$NAME" "$SRC_REAL" "${NEST:-.}" > "$DEST/$MARKER" || { echo "bench: cannot write the $MARKER marker into $DEST"; exit 1; }
fi

# What an EARLIER LAYOUT left at the bench's root goes before the new copy (V32: the project copied at <bench>/ before it
# reached ../, at <bench>/proj after - the old <bench>/src stayed, `../src` from the place to work, and the run said
# "isolation verified"). A project that reaches out by `../` owns nothing at the root: every name there that is not on the
# way to its copy or to a place `../` reaches (the marker aside) is removed. A project copied at <bench>/ itself, where the
# marker says the copy was at <bench>/<folder> before: everything at the root but the marker was put there by that
# layout, and is removed - the bench's own files in the old copy with it (the layout moved them anyway).
PLACES=()
if [ -n "$NEST" ]; then
  PLACES+=("$NEST")
  for tgt in ${OUT_TGTS[@]+"${OUT_TGTS[@]}"}; do { [ -e "$tgt" ] || [ -L "$tgt" ]; } && PLACES+=("${tgt#"$OUT_TOP"/}"); done
fi
removed=""; not_removed=""
prune_level() { # prune_level <path relative to the bench, empty for its root>: remove what is not on the way to a place
  local d="$DEST${1:+/$1}" e n p a keep
  for e in "$d"/* "$d"/.[!.]* "$d"/..?*; do
    { [ -e "$e" ] || [ -L "$e" ]; } || continue
    n="${e##*/}"; p="${1:+$1/}$n"
    [ -z "$1" ] && [ "$n" = "$MARKER" ] && continue
    keep=0
    for a in ${PLACES[@]+"${PLACES[@]}"}; do
      [ "$p" = "$a" ] && { keep=1; break; }
      case "$a/" in "$p"/*) keep=2 ;; esac
    done
    [ "$keep" = 1 ] && continue
    if [ "$keep" = 2 ] && [ -d "$e" ] && [ ! -L "$e" ]; then prune_level "$p"; continue; fi
    rm -rf "${e:?}" 2> /dev/null
    if [ -e "$e" ] || [ -L "$e" ]; then not_removed="$not_removed $p"; else removed="$removed $p"; fi
  done
}
if [ -n "$NEST" ] || [ "$OLD_PLACE" != "." ]; then prune_level ""; fi
[ -n "$removed" ] && echo "bench: removed from the bench's root, left by an earlier layout:$removed"
[ -n "$not_removed" ] && echo "bench: could NOT remove, left by an earlier layout (the check below decides):$not_removed"

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
  # into the project's place: the bench itself, or <bench>/<its folder> for a project that reaches out by `../` (header)
  mkdir -p "$PDEST" || exit 1
  rsync -a --delete ${args[@]+"${args[@]}"} "$SRC/" "$PDEST/" || { echo "bench: rsync failed"; exit 1; }
else
  echo "bench: rsync not found, falling back to a full copy (slower, and it does not prune deletions)"
  targs=()
  for e in $EXCLUDES; do case "$e" in /*) targs+=("--exclude=.$e") ;; *) targs+=("--exclude=$e") ;; esac; done
  mkdir -p "$PDEST" || exit 1
  (cd "$SRC" && tar ${targs[@]+"${targs[@]}"} -cf - .) | (cd "$PDEST" && tar -xf -) || { echo "bench: copy failed"; exit 1; }
fi
set +f

# a path is under one of the dependency directories (they are checked and copied on their own terms)
under_lib() { local l; for l in $LIBS; do case "$1/" in "$PDEST/$l"/*) return 0 ;; esac; done; return 1; }

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
      rel="${m#"$PDEST"/}"
      if [ -e "$SRC/$rel" ] || [ -L "$SRC/$rel" ]; then
        rm -rf "${PDEST:?}/$rel"
      else
        kept_own="$kept_own $rel"
      fi
    done < <(find "$PDEST" -mindepth 1 \( -path "$PDEST/$e" -o -name "$e" \) -prune -print 2> /dev/null)
    set -f
  done
  set +f
fi

# deps_from_toml <foundry.toml>: true when it already says where the dependencies live OUTSIDE the project - a `libs`
# entry that is absolute or goes up (`/...`, `~/...`, `C:/...`, `../...`; one that goes up is taken first, "Reaching
# out" in the header, and this is not asked), or a remapping whose target is absolute. Read
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

# place_dep <from> <to> <name>: one dependency directory into the bench - linked (LINK_LIB=1), copied through its links
# (a bench that withholds), or synced as it is (LINK_LIB=0). <to> is absolute, in the bench; <name> is what a refusal calls it.
outward=0
place_dep() {
  local from="$1" to="$2" name="$3" lib_real k t tg n
  if [ "$LINK_LIB" = "1" ]; then
    rm -rf "${to:?}"; mkdir -p "$(dirname "$to")"
    ln -s "$from" "$to"
  elif [ -n "$BENCH_EXCLUDE" ]; then
    # the project's lib/ may itself be a link to a shared directory: copy what it POINTS AT, so nothing in the bench
    # leads outside the bench ... but `cp -RL` follows EVERY link under it, and a monorepo's `lib/core -> ../src` would
    # carry the withheld source into the bench under a directory the check below does not look inside (libraries have
    # a src/ of their own). So: a link under it that resolves into the project, and outside it, is refused before
    # anything is copied. Only links physically under it are examined; a chain that leaves it and comes back by a
    # second link is not.
    lib_real="$(cd "$from" && pwd -P)"
    if [ "$from" = "$LINK_FROM_REAL" ]; then
      case "$lib_real/" in "$SRC_REAL"/*)
        echo "bench: LINK_FROM ($lib_real) is inside the project: copying it would bring project files into a bench that withholds. Refusing."
        exit 1 ;;
      esac
    fi
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      if [ -d "$k" ]; then
        t="$(cd "$k" && pwd -P)"
      else
        tg="$(readlink "$k")"
        case "$tg" in /*) ;; *) tg="$(dirname "$k")/$tg" ;; esac
        t="$(cd "$(dirname "$tg")" 2> /dev/null && pwd -P)/$(basename "$tg")"
      fi
      case "$t/" in "$lib_real"/*) continue ;; esac
      case "$t/" in "$SRC_REAL"/*)
        echo "bench: $name holds a link into the project itself: $k -> $t"
        echo "       Copying it would bring withheld files into a bench that exists to withhold them. Refusing."
        exit 1 ;;
      esac
    done < <(find "$from/" -type l 2> /dev/null)
    # ... and that is a limit the person RECEIVING the bench has to be told about, not only the person reading this file
    n="$(find "$from/" -type l 2> /dev/null | wc -l | tr -d ' ')"
    [ -L "$from" ] && n=$((n + 1))
    outward=$((outward + n))
    rm -rf "${to:?}"; mkdir -p "$(dirname "$to")"
    cp -RL "$from" "$to" || { echo "bench: cannot copy $name"; exit 1; }
  else
    # a link left by an earlier LINK_LIB=1 bench leads into the project: syncing INTO it would write the project's lib/
    [ -L "$to" ] && rm -f "$to"
    mkdir -p "$to"
    rsync -a --delete "$from/" "$to/" 2> /dev/null || { rm -rf "${to:?}"; cp -R "$from" "$to"; } \
      || { echo "bench: cannot copy $name"; exit 1; }
  fi
}

# the dependency directories, one by one (place_dep); one the project does not have is the bench's own and is left alone
for l in $LIBS; do
  from="$SRC/$l"
  if [ "$l" = "lib" ] && [ -n "$LINK_FROM" ] && [ -e "$SRC/lib" ]; then
    echo "bench: LINK_FROM ignored: the project has a lib/ of its own"
  fi
  if [ ! -e "$SRC/$l" ]; then
    # a project with no root lib/ (forge-std installed elsewhere): LINK_FROM names the directory to use instead - but
    # never over a lib/ DIRECTORY the bench already has (installed into it: deleting it would cost a reinstall)
    if [ "$l" = "lib" ] && [ -n "$LINK_FROM" ] && { [ -L "$PDEST/lib" ] || [ ! -e "$PDEST/lib" ]; }; then
      from="$LINK_FROM_REAL"
      echo "bench: the project has no lib/: the bench's lib/ is LINK_FROM ($from)"
    else
      if [ "$l" = "lib" ] && [ -L "$PDEST/lib" ]; then
        # a LINK is not "the bench's own": an earlier run made it - to LINK_FROM, or to the lib/ the project had then
        t="$(readlink "$PDEST/lib")"
        if [ "$t" = "$SRC/lib" ]; then
          echo "bench: lib/ is a link left by an earlier run, to the project's lib/ that no longer exists: $t (kept; set LINK_FROM to replace it)"
        else
          echo "bench: lib/ is a link left by an earlier LINK_FROM: $t (kept; set LINK_FROM to change it)"
        fi
      elif [ -e "$PDEST/$l" ]; then
        echo "bench: $l/ is the bench's own (the project has none): kept as it is"
        [ "$l" = "lib" ] && [ -n "$LINK_FROM" ] && echo "bench: LINK_FROM not applied: the bench's lib/ is a directory of its own (remove it to link)"
      elif [ "$l" = "lib" ] && [ "$OUT_UPS" -gt 0 ]; then
        # the kit vendored beside the project, `../lib/hook-gauntlet/...` (FR16): LINK_FROM would fill the bench's OWN
        # lib/, which nothing names - what `../` reaches is put beside the project's copy, below
        echo "bench: no lib/; dependencies come from outside the project by a relative path (../): put beside the project's copy, below"
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
  place_dep "$from" "$PDEST/$l" "$l/"
done

# what `../` reaches (header, "Reaching out"): at its own relative place in the bench, beside the project's copy - so that
# the project's `../lib/...` resolves from <bench>/<its folder> as it does from the project
for tgt in ${OUT_TGTS[@]+"${OUT_TGTS[@]}"}; do
  lab="${OUT_LAB[$tgt]}"; to="$DEST/${tgt#"$OUT_TOP"/}"
  if [ ! -e "$tgt" ]; then echo "bench: $lab -> $tgt: does not exist - nothing linked for it"; continue; fi
  if [ -d "$tgt" ]; then
    place_dep "$tgt" "$to" "$lab"
  else
    rm -rf "${to:?}"; mkdir -p "$(dirname "$to")"
    if [ "$LINK_LIB" = "1" ]; then ln -s "$tgt" "$to"; else cp -L "$tgt" "$to" || { echo "bench: cannot copy $lab"; exit 1; }; fi
  fi
  if [ "$LINK_LIB" = "1" ]; then echo "bench: $lab -> $tgt: linked at $to"; else echo "bench: $lab -> $tgt: copied at $to"; fi
  # what the project names is a directory, and ALL of it comes (V32: `../lib` for the kit brought lib/owner-private/ with it
  # into a black-box bench): said with its contents, where it matters - a bench that withholds
  if [ -n "$BENCH_EXCLUDE" ] && [ -d "$tgt" ]; then
    all="$(cd "$tgt" && LC_ALL=C ls -A | wc -l | tr -d ' ')"
    names="$(cd "$tgt" && LC_ALL=C ls -A | head -20 | tr '\n' ' ')"; names="${names% }"
    [ "$all" -gt 20 ] && names="$names ... ($all in all)"
    echo "bench: WARNING - $lab is copied WHOLE into a bench that withholds: everything in $tgt, not only what the project names in it: $names"
  fi
done
[ -n "$NEST" ] && echo "bench: the project reaches outside itself by ../, so its copy is at $PDEST (work there), with what it reaches beside it"

# a path is under a place `../` reaches (a dependency, copied whole: said above)
under_out() { local t; for t in ${OUT_TGTS[@]+"${OUT_TGTS[@]}"}; do case "$1/" in "$DEST/${t#"$OUT_TOP"/}"/*) return 0 ;; esac; done; return 1; }

if [ -n "$BENCH_EXCLUDE" ]; then
  # verify, do not trust: no excluded path the PROJECT has may be in the bench, and no symlink may remain. Over the WHOLE
  # bench, not the project's copy alone (V32): a match outside the copy and outside what `../` reaches is nobody's own - a
  # layout's leftover, `../src` from the place to work - and fails the bench
  bad=0
  set -f
  for e in $BENCH_EXCLUDE; do
    set +f
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      under_lib "$m" && continue
      under_out "$m" && continue
      case "$m/" in
        "$PDEST"/*)
          rel="${m#"$PDEST"/}"
          if [ -e "$SRC/$rel" ] || [ -L "$SRC/$rel" ]; then echo "bench: EXCLUDED path '$rel' is present in the bench"; bad=1; fi ;;
        *) echo "bench: EXCLUDED path '${m#"$DEST"/}' is present in the bench, outside the project's copy (left by an earlier layout?)"; bad=1 ;;
      esac
    done < <(find "$DEST" -mindepth 1 \( -path "$PDEST/$e" -o -path "$DEST/$e" -o -name "$e" \) -prune -print 2> /dev/null)
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
    echo "bench: NOTE - the dependencies were copied THROUGH $outward symbolic link(s). Each was checked not to point into the project; what"
    echo "       lies behind them (a second link that comes back?) was NOT examined. Look inside them before trusting the isolation."
  fi
fi

BENCH_ARTIFACTS="${BENCH_ARTIFACTS:-}"
if [ -n "$BENCH_ARTIFACTS" ]; then
  rm -rf "$PDEST/artifacts"
  for c in $BENCH_ARTIFACTS; do
    a="$SRC/out/$c.sol/$c.json"
    [ -f "$a" ] || { echo "bench: no artifact for $c at out/$c.sol/$c.json - build the project first"; exit 1; }
    if grep -q '"content"[ 	]*:' "$a"; then
      echo "bench: the artifact of $c embeds literal source (metadata.useLiteralContent?) - refusing to hand it to a blackbox bench"; exit 1
    fi
    mkdir -p "$PDEST/artifacts/$c.sol" && cp "$a" "$PDEST/artifacts/$c.sol/$c.json" || exit 1
  done
  echo "bench: artifacts copied for:$BENCH_ARTIFACTS"
fi

echo "bench '$NAME' ready, excluding:$EXCLUDES"
echo "$PDEST"
