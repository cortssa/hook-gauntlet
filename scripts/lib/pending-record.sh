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
# Each part of the key is also hashed alone and written in the record, its `keyed:` line (v0.4.2): when a record is no
# longer current, the reader says WHICH part changed since it was made (src/, test/, pending/, the file itself,
# foundry.toml, remappings.txt) instead of only "not current".
# One kind of record stays current under a narrower key (v0.4.2, decided after V60): a record whose failures include the
# v4 harness's permission-bits refusal (its `permission-bits:` line - a test that holds the hook to the harness's
# check). Its red comes from the harness and src/, not from the test helpers: it stays current while src/ is what the
# record's `anchor:` line says it was (the hash of src/ written there) and the finding's own file is unchanged (its
# hash on the `keyed:` line) - an edit elsewhere in test/ or pending/ (the everyday suite gaining the flag and the
# header, a phase-3 test added) does not stale it. Every other record keeps the full key above.
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

# pending_key_part <proj> <part>: one part of the key, hashed alone (64 hex): a directory (src, test, pending) the same way
# as the key (its file list and contents; the hash of nothing when it is absent), a file (foundry.toml, remappings.txt,
# or a pending/ file) its own SHA-256, `none` when it is absent. src's is the anchor of src/ (scripts/lib/src-anchor.sh).
pending_key_part() {
  local proj="$1" part="${2%/}" f
  if [ -f "$proj/$part" ]; then _pr_sha256 "$proj/$part"; return 0; fi
  case "$part" in src | test | pending) ;; *) echo none; return 0 ;; esac
  {
    # every command here ends true: the callers run under pipefail
    if [ -d "$proj/$part" ]; then
      (cd "$proj" && { find -L "$part" -type f -print0 2> /dev/null || :; } | LC_ALL=C sort -z) \
        | while IFS= read -r -d '' f; do printf '%s  %s\n' "$(_pr_sha256 "$proj/$f")" "$f"; done
    fi
  } | _pr_sha256
}

# pending_record_keyed <proj> <pending/...sol>: the record's `keyed:` line - each part of the key hashed alone, and the
# file itself: `keyed: src/ <h> test/ <h> pending/ <h> foundry.toml <h> remappings.txt <h> file <h>`
pending_record_keyed() {
  local proj="$1" rel="$2" out="keyed:" d f
  # shellcheck disable=SC2086   # the lists are words, on purpose
  for d in $PENDING_KEY_DIRS; do out="$out $d/ $(pending_key_part "$proj" "$d")"; done
  # shellcheck disable=SC2086
  for f in $PENDING_KEY_FILES; do out="$out $f $(pending_key_part "$proj" "$f")"; done
  printf '%s file %s\n' "$out" "$(pending_key_part "$proj" "$rel")"
}

# pending_record_current <proj> <pending/...sol>: is there a CURRENT red record of that file? 0 yes - PR_REC its path,
# PR_HOW `key` (the full key) or `bits` (a permission-bits record under its narrower key: src/ and its own file as
# recorded); 1 no - PR_STATE `none` (no record of it), `stale` (one made on another key) or `unreadable` (one with the
# current key's name whose first line is not the record's), and PR_WHY the words: which part of the key changed since
# the record was made, as far as the record says (its `keyed:` and `anchor:` lines).
# shellcheck disable=SC2034   # PR_REC, PR_HOW, PR_STATE and PR_WHY: read by the scripts that source this
PR_REC="" PR_HOW="" PR_STATE="" PR_WHY=""
# shellcheck disable=SC2034
pending_record_current() {
  local proj="$1" rel="$2" rec dir base c k kd line date srcnow filenow src_was file_was why part was now parts i
  PR_REC="" PR_HOW="" PR_STATE="none" PR_WHY="no red record of it in .gauntlet/pending-red/"
  rec="$(pending_record_path "$proj" "$rel")" || { PR_WHY="it does not exist"; return 1; }
  if [ -e "$rec" ]; then
    if pending_record_ok "$rec" "$rel" "${rec##*.}"; then PR_REC="$rec" PR_HOW="key"; return 0; fi
    PR_STATE="unreadable" PR_WHY="its record ($rec) is unreadable: an empty or handwritten file"; return 1
  fi
  # a record made on another key: the newest readable one says what it was made on
  dir="$(dirname "$rec")"; base="$(basename "${rel#pending/}")"
  c=""
  while IFS= read -r k; do
    kd="${k##*.}"; [[ $kd =~ ^[0-9a-f]{64}$ ]] || continue
    pending_record_ok "$k" "$rel" "$kd" || continue
    if [ -z "$c" ] || [ "$k" -nt "$c" ]; then c="$k"; fi
  done < <(find "$dir" -maxdepth 1 -type f -name "$base.*" ! -name "$base.log" ! -name '*.tmp' 2> /dev/null)
  [ -n "$c" ] || return 1
  IFS= read -r line < "$c"; date="${line##* }"
  srcnow="$(pending_key_part "$proj" src)"; filenow="$(pending_key_part "$proj" "$rel")"
  src_was="$(sed -nE 's/^anchor: .* - src\/ sha256 ([0-9a-f]{64})$/\1/p' "$c" | head -1)"
  file_was="$(sed -nE 's/^keyed: .* file ([0-9a-f]{64})$/\1/p' "$c" | head -1)"
  # the permission-bits record: current while src/ and the finding's own file are as it says
  if grep -q '^permission-bits: ' "$c" && [ -n "$src_was" ] && [ -n "$file_was" ]; then
    if [ "$src_was" = "$srcnow" ] && [ "$file_was" = "$filenow" ]; then PR_REC="$c" PR_HOW="bits" PR_STATE=""; PR_WHY=""; return 0; fi
    why=""
    [ "$file_was" = "$filenow" ] || why="$rel itself"
    [ "$src_was" = "$srcnow" ] || why="${why:+$why and }src/"
    PR_STATE="stale" PR_WHY="its red record of $date is stale - $why changed since (a permission-bits record stays current while src/ and its own file are as recorded)"
    return 1
  fi
  PR_STATE="stale"
  line="$(sed -n '/^keyed: /{p;q;}' "$c")"
  if [ -z "$line" ]; then
    PR_WHY="its red record of $date is stale - one of $PENDING_KEY_SAYS changed since; that record does not say which"
    return 1
  fi
  read -ra parts <<< "${line#keyed: }"
  why=""
  for ((i = 0; i + 1 < ${#parts[@]}; i += 2)); do
    part="${parts[i]}" was="${parts[i + 1]}"
    case "$part" in
      file) now="$filenow"; [ "$was" = "$now" ] || why="${why:+$why, }$rel itself" ;;
      pending/) now="$(pending_key_part "$proj" pending)"; [ "$was" = "$now" ] || [ "$file_was" != "$filenow" ] || why="${why:+$why, }pending/ (another file there)" ;;
      *) now="$(pending_key_part "$proj" "$part")"; [ "$was" = "$now" ] || why="${why:+$why, }$part" ;;
    esac
  done
  PR_WHY="its red record of $date is stale - ${why:-one of $PENDING_KEY_SAYS} changed since"
  return 1
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
