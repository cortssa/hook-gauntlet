# shellcheck shell=bash
#
# kit-proof.sh - the kit's own tools proven on this machine: the marker scripts/selftest.sh leaves when it PASSES, and
# the check scripts/next.sh makes against it before it names any row (K31, K31b).
#
# The problem it solves: the route leans on the kit's scripts - the battery's verdict, next.sh's rows, the census gate -
# and a script is only as good as the guards the selftest has seen go red ON THIS MACHINE (another bash, another sed,
# another forge). A round-3 walker ran the selftest; the round before did not, and nothing noticed. So the selftest,
# when it ends PASSED, writes <kit>/.gauntlet/selftest-passed (git-ignored): the SHA-256 of the kit's scripts, a hash of
# this machine's identity, the date and the first line of `forge --version`; any other ending leaves no marker.
# next.sh compares three of them with what it is run from and on - the scripts, the machine, forge - and names no row
# until all three are recorded and match: an edited script, a fresh clone, a kit copied to another machine (another
# machine-id, or another hostname where no machine-id is readable - a clone that kept both is not seen) with its
# .gauntlet/ (or a project copied with the kit in lib/hook-gauntlet), another forge - each starts with the selftest. It
# is a property of the machine and the kit, not of the hook: it is not a STATE.md flag. The date is written, not read.
#
# The scripts hashed: scripts/*.sh, scripts/lib/*.sh, scripts/*.py and scripts/lib/*.py of the kit, in the C locale's
# order of their paths relative to the kit. The hash is the SHA-256 of the lines "<sha256 of the file>  <path>", one
# per file, so a file renamed, added or removed changes it as surely as a byte changed inside one.
# The machine: /etc/machine-id when it is readable and not empty, else the hostname - never written as it is: the marker
# holds the SHA-256 of "hook-gauntlet selftest marker, <source>: <id>" (nothing secret leaves the machine in it).
# Forge: the first line of `forge --version` from the PATH next.sh runs with; none on the PATH is not the forge recorded.
#
# Source it:  . "$HERE/lib/kit-proof.sh"

# where the machine's identity is read; a plain assignment, never read from the environment (the selftest reassigns it
# in a subshell of its own to see the hostname fallback and another machine)
_kit_machine_id_file=/etc/machine-id

_kit_sha256() { # _kit_sha256 [<file>]: the SHA-256 of the file (stdin without one), hex only
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$@" | cut -d' ' -f1
  else shasum -a 256 "$@" | cut -d' ' -f1; fi
}

# kit_scripts_list <kit>: the kit's scripts that the marker covers, one path relative to the kit per line, sorted
kit_scripts_list() {
  (cd "$1" 2> /dev/null && for f in scripts/*.sh scripts/lib/*.sh scripts/*.py scripts/lib/*.py; do [ -f "$f" ] && printf '%s\n' "$f"; done) \
    | LC_ALL=C sort
}

# kit_scripts_sha256 <kit>: the one hash of the kit's scripts (above); exit 1 and nothing printed when there is none
kit_scripts_sha256() {
  local kit="$1" f list
  list="$(kit_scripts_list "$kit")"
  [ -n "$list" ] || return 1
  while IFS= read -r f; do printf '%s  %s\n' "$(_kit_sha256 "$kit/$f")" "$f"; done <<< "$list" | _kit_sha256
}

# kit_machine_source: where this machine's identity is read - "/etc/machine-id" or "the hostname"; exit 1 with neither
# kit_machine_sha256: the hash of this machine's identity (above), 64 hex; exit 1 and nothing printed without one
_kit_machine_id() { # prints "<source>|<id>"
  local id=""
  if [ -r "$_kit_machine_id_file" ]; then id="$(tr -d '[:space:]' < "$_kit_machine_id_file" 2> /dev/null)"; fi
  if [ -n "$id" ]; then printf '%s|%s\n' "$_kit_machine_id_file" "$id"; return 0; fi
  id="$(hostname 2> /dev/null || uname -n 2> /dev/null)"; id="$(printf '%s' "$id" | tr -d '[:space:]')"
  [ -n "$id" ] || return 1
  printf 'the hostname|%s\n' "$id"
}
kit_machine_source() { local m; m="$(_kit_machine_id)" || return 1; printf '%s\n' "${m%%|*}"; }
kit_machine_sha256() {
  local m; m="$(_kit_machine_id)" || return 1
  printf 'hook-gauntlet selftest marker, %s: %s' "${m%%|*}" "${m#*|}" | _kit_sha256
}

# kit_forge_version: the first line of `forge --version` on the PATH, trailing blanks removed; empty without forge
kit_forge_version() {
  forge --version 2> /dev/null | head -n 1 | tr -d '\r' | sed 's/[[:space:]]*$//'
}

# kit_marker <kit>: where the selftest leaves its marker
kit_marker() { printf '%s/.gauntlet/selftest-passed\n' "$1"; }

# kit_marker_sha <marker> <field>: the 64-hex value of the marker's first line "<field>: <64 hex>"; exit 1 without one
kit_marker_sha() {
  [ -f "$1" ] || return 1
  sed -nE "s/^$2: ([0-9a-f]{64})([[:space:]].*)?\$/\\1/p" "$1" | awk 'NR == 1 { print; ok = 1 } END { exit ok ? 0 : 1 }'
}
# kit_marker_hash <marker>: the scripts' hash the marker records (its line "scripts_sha256: <64 hex>"); exit 1 without one
kit_marker_hash() { kit_marker_sha "$1" scripts_sha256; }
# kit_marker_forge <marker>: the forge the marker records (its first line "forge: <forge --version's first line>");
# exit 1 without one, or with it empty
kit_marker_forge() {
  [ -f "$1" ] || return 1
  sed -n 's/^forge: //p' "$1" | tr -d '\r' | sed 's/[[:space:]]*$//' | awk 'NR == 1 { if ($0 != "") { print; ok = 1 } } END { exit ok ? 0 : 1 }'
}

_kit_words() { # _kit_words <word>...: "a", "a and b", "a, b and c"
  case $# in 1) printf '%s' "$1" ;; 2) printf '%s and %s' "$1" "$2" ;; *) printf '%s, %s and %s' "$1" "$2" "$3" ;; esac
}

# kit_proof_check <kit>: 0 and nothing printed when the marker is there and records the scripts, the machine and forge
# as they are now; else 1 and one phrase saying which, for next.sh's FIRST line: "the selftest has not passed here" (no
# marker), "its marker does not record <which>" (a field missing), "<which> changed since its selftest passed"
kit_proof_check() {
  local m want have out=""
  local -a missing=() changed=()
  m="$(kit_marker "$1")"
  if [ ! -f "$m" ]; then echo "the selftest has not passed here"; return 1; fi
  if want="$(kit_marker_sha "$m" scripts_sha256)"; then
    have="$(kit_scripts_sha256 "$1")" || have=""
    [ "$want" = "$have" ] || changed+=("the scripts")
  else missing+=("the scripts"); fi
  if want="$(kit_marker_sha "$m" machine_sha256)"; then
    have="$(kit_machine_sha256)" || have=""
    [ "$want" = "$have" ] || changed+=("the machine")
  else missing+=("the machine"); fi
  if want="$(kit_marker_forge "$m")"; then
    have="$(kit_forge_version)"
    [ "$want" = "$have" ] || changed+=("forge")
  else missing+=("forge"); fi
  [ ${#missing[@]} -eq 0 ] && [ ${#changed[@]} -eq 0 ] && return 0
  [ ${#missing[@]} -eq 0 ] || out="its marker does not record $(_kit_words "${missing[@]}")"
  if [ ${#changed[@]} -gt 0 ]; then
    [ -z "$out" ] || out="$out; "
    out="$out$(_kit_words "${changed[@]}") changed since its selftest passed"
  fi
  printf '%s\n' "$out"
  return 1
}

# kit_proven <kit>: 0 when kit_proof_check finds nothing to say
kit_proven() { kit_proof_check "$1" > /dev/null; }
