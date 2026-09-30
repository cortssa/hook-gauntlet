# shellcheck shell=bash
#
# pending-record.sh - the record that a test in pending/ was seen RED on src/ as it stands: where it lives, what it is
# keyed by and what its first line must say. Written by scripts/pending-red.sh, read by scripts/next.sh (K41, K48).
#
# The problem it solves: "red on the code" was a sentence anyone could write. A walker of the route (the local-model walk, judged 2026-09-30) wrote
# DECISIONS.md entries citing red tests in pending/ that did not exist, and the one that did exist did not compile -
# mended, it PASSED on the planted code. So the red is a file the route can read: <proj>/.gauntlet/pending-red/<the
# file's path below pending/>.<key>. The key is the SHA-256 of the lines "<sha256 of the file>  <path>", one per file
# of what the pending profile builds from the project's own tree: every file below src/, test/ and pending/ (followed
# through symlinks) and the project's foundry.toml and remappings.txt, in the C locale's order of their paths - the
# file list and the contents. Edit the test, a helper it imports from test/ or pending/, a file under src/, the
# remappings or foundry.toml, add or remove a file there, and the key changes: the record is no longer the current
# one, and the test must be seen red again (K48: a helper in test/ edited after the red kept the old record current,
# and forge's incremental build ran the old helper - V40). What is NOT in the key: the libraries (lib/, or wherever the
# remappings point) and the compiler - pending-red.sh builds from nothing on every run, so its verdict is never the
# old code's, but a record is not staled by a library changing under it (said where it is read).
# The record's first line is `pending-red: red <pending/file> key=<key> <YYYY-MM-DD>`; then the failing tests and the
# last 20 lines of forge's output. next.sh takes a record only when its first line has that shape, names the file,
# and carries the key its name carries: an empty or handwritten file is "unreadable".
#
# Source it:  . "$HERE/lib/pending-record.sh"

_pr_sha256() { # _pr_sha256 [<file>]: the SHA-256 of the file (stdin without one), hex only
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$@" | cut -d' ' -f1
  else shasum -a 256 "$@" | cut -d' ' -f1; fi
}

# what the key covers, below the project: the three directories, then the two files (said by the docs)
PENDING_KEY_DIRS="src test pending"
PENDING_KEY_FILES="foundry.toml remappings.txt"
# shellcheck disable=SC2034   # read by pending-red.sh, which sources this
PENDING_KEY_SAYS="src/, test/, pending/, foundry.toml and remappings.txt"

# pending_record_key <proj> <pending/...sol>: the key above (64 hex); exit 1 and nothing printed when the file is missing
pending_record_key() {
  local proj="$1" rel="$2" f d
  [ -f "$proj/$rel" ] || return 1
  {
    # shellcheck disable=SC2086   # the lists are words, on purpose
    # every command here ends true: the callers run under pipefail, and a missing directory or file is no error
    (cd "$proj" && { for d in $PENDING_KEY_DIRS; do if [ -d "$d" ]; then find -L "$d" -type f -print0 2> /dev/null || :; fi; done
                     for f in $PENDING_KEY_FILES; do if [ -f "$f" ]; then printf '%s\0' "$f"; fi; done; } | LC_ALL=C sort -z) \
      | while IFS= read -r -d '' f; do printf '%s  %s\n' "$(_pr_sha256 "$proj/$f")" "$f"; done
  } | _pr_sha256
}

# pending_record_dir <proj>: where the records live
pending_record_dir() { printf '%s/.gauntlet/pending-red\n' "$1"; }

# pending_record_path <proj> <pending/...sol>: the path of the CURRENT record for that file (it may not exist)
pending_record_path() {
  local k
  k="$(pending_record_key "$1" "$2")" || return 1
  printf '%s/%s.%s\n' "$(pending_record_dir "$1")" "${2#pending/}" "$k"
}

# pending_record_head <pending/...sol> <key>: the first line a record must have (today's date)
pending_record_head() { printf 'pending-red: red %s key=%s %s\n' "$1" "$2" "$(date +%F)"; }

# pending_record_ok <record> <pending/...sol> <key>: 0 when the record's first line is `pending-red: red <file>
# key=<key> <YYYY-MM-DD>` for that file and that key; 1 otherwise (empty, handwritten, another file's, another key's)
pending_record_ok() {
  local first
  [ -f "$1" ] && [ -s "$1" ] || return 1
  IFS= read -r first < "$1" 2> /dev/null || return 1
  first="${first%$'\r'}"
  [[ $first =~ ^pending-red:\ red\ ([^ ]+)\ key=([0-9a-f]{64})\ [0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  [ "${BASH_REMATCH[1]}" = "$2" ] && [ "${BASH_REMATCH[2]}" = "$3" ]
}

# pending_files <proj>: every .sol file below <proj>/pending (subdirectories and hidden files too - row 6b's profile
# compiles and runs them all), as pending/<path>, one per line, sorted; nothing without a pending/
pending_files() {
  local f
  [ -d "$1/pending" ] || return 0
  while IFS= read -r -d '' f; do printf 'pending/%s\n' "${f#"$1"/pending/}"; done \
    < <(find -L "$1/pending" -name '*.sol' -type f -print0 2> /dev/null | LC_ALL=C sort -z)
}

# pending_sol_dirs <proj>: every DIRECTORY below <proj>/pending named *.sol, as pending/<path>, one per line (K48: a
# directory passed both the walk, which saw files only, and the cited-file check, which asked only "exists")
pending_sol_dirs() {
  local f
  [ -d "$1/pending" ] || return 0
  while IFS= read -r -d '' f; do printf 'pending/%s\n' "${f#"$1"/pending/}"; done \
    < <(find -L "$1/pending" -mindepth 1 -name '*.sol' -type d -print0 2> /dev/null | LC_ALL=C sort -z)
}
