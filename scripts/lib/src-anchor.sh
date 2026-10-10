# shellcheck shell=bash
#
# src-anchor.sh - the anchor of src/: the code under audit is the owner's, as the spec is. Recorded by
# scripts/init-state.sh in <proj>/.gauntlet/src.sha256, compared by scripts/pending-red.sh and scripts/battery.sh on
# every run (v0.4.2). Source it:  . "$HERE/lib/src-anchor.sh"
#
# The problem it solves: a walker of the route met the harness's refusal of its hook's permission bits and "fixed" it in
# the hook it was auditing - `afterInitialize: false -> true` in src/, a function added before that so that its own test
# would compile - and nothing said so: pending-red.sh keys its record on src/ AS IT STANDS, so a red over an edited hook
# was a valid record, and the battery ran on it. The guard that existed (the spec's hash) lived in next.sh, which that
# walker had stopped running. So src/ is anchored like the spec, and checked where the evidence is made.
#
# The anchor: the SHA-256 of the lines "<sha256 of the file>  <path>", one per file below src/ (followed through
# symlinks), in the C locale's order of their paths - the file list and the contents (scripts/lib/pending-record.sh's
# key, for src/ alone). The record, <proj>/.gauntlet/src.sha256: line 1 `<sha256>  src/`; then one line per signed
# re-record, `re-recorded <date> by "<name>" <old8> -> <new8>` (init-state.sh --src --by, the owner's act).
# What it does not do: tell whose hands changed src/ (the kit cannot), anchor anything outside src/ (a library, a test).
#
# v0.5.3, silence is a refusal: a missing record is never a pass. From phase 2 (doctrine/NEXT.md row 4b: the hook
# compiles, the spec's phase is closed - before it a hook still to be written, or no spec yet, legitimately leaves
# init-state.sh nothing to record) a project of the route with no src.sha256 is REFUSED here, as one whose src/ changed:
# `REFUSED - anchor record missing: <proj>/.gauntlet/src.sha256; re-run scripts/init-state.sh <proj> --src --by <owner>`.
# And the reports a row of next.sh reads are sealed (report_seal, report_check below): `<report>.sha256` beside each,
#   line 1  `<sha256>  <the report's file name>` - the SHA-256 of the report's bytes followed by its line 2 and a newline
#   line 2  `src/ <the anchor of src/ when it was written, 64 hex>` (`none`: no src/)
#   line 3  `by <the script> (sha256 <12 hex> of the script)` - which script wrote it, and which version of it
# A report with no sidecar, a sidecar that does not match it, or one made on another src/ than the one there is now is
# not a record. What this proves is currency, not authorship: every input of the sidecar is public, and a fabricator who
# computes it gets past it - it turns a report typed by a model into a deliberate act; the verifier who reproduces, and
# the owner who reads LOG.md and the dossier, are the defence against that act (doctrine/EVIDENCE.md, "silence is a
# refusal").

# src_anchor_hash <proj>: the anchor of <proj>/src (64 hex); exit 1 and nothing printed when there is no src/
src_anchor_hash() {
  local proj="$1" f
  [ -d "$proj/src" ] || return 1
  {
    # every command here ends true: the callers run under pipefail
    (cd "$proj" && { find -L src -type f -print0 2> /dev/null || :; } | LC_ALL=C sort -z) \
      | while IFS= read -r -d '' f; do printf '%s  %s\n' "$(_sa_sha256 "$proj/$f")" "$f"; done
  } | _sa_sha256
}
_sa_sha256() { # _sa_sha256 [<file>]: hex only
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$@" | cut -d' ' -f1
  else shasum -a 256 "$@" | cut -d' ' -f1; fi
}
# src_anchor_key <proj>: the anchor of src/ as it stands (64 hex), or `none` when there is no src/
src_anchor_key() { local h; if h="$(src_anchor_hash "$1")" && [ -n "$h" ]; then printf '%s' "$h"; else printf none; fi; }
# src_anchor_phase <proj>: the phase its STATE.md's flag block says (.gauntlet/STATE.md, else STATE.md - next.sh's
# order), its first word; nothing printed and exit 1 when there is no STATE.md or no phase: line in a flag block (the
# flag block: the first fenced block with a phase: line, scripts/lib/state-example.sh's flag_block, read the same way)
src_anchor_phase() {
  local st
  if [ -f "$1/.gauntlet/STATE.md" ]; then st="$1/.gauntlet/STATE.md"; elif [ -f "$1/STATE.md" ]; then st="$1/STATE.md"; else return 1; fi
  LC_ALL=C awk '{ sub(/\r$/, "") }
    /^```/ { if (inb && has) exit; inb = !inb; has = 0; p = ""; next }
    inb && /^phase:/ { has = 1; v = $0; sub(/^phase:[ \t]*/, "", v); sub(/[ \t].*$/, "", v); p = v }
    END { if (p == "") exit 1; print p }' "$st"
}
# src_anchor_required <proj>: 0 when its phase is 2 or higher - from row 4b on the anchors are records the route must have
src_anchor_required() { local p; p="$(src_anchor_phase "$1")" || return 1; [[ $p =~ ^[0-9]+$ ]] && [ "$((10#$p))" -ge 2 ]; }

# ------------------------------------------------------------------------------------------------ the reports' seals
# report_seal <proj> <report> <script path>: writes <report>.sha256 (the header); 0, or 1 when it could not
report_seal() {
  local proj="$1" rep="$2" who="$3" key h v
  [ -f "$rep" ] || return 1
  key="$(src_anchor_key "$proj")"
  h="$( { cat "$rep"; printf 'src/ %s\n' "$key"; } | _sa_sha256)" || return 1
  v="$(_sa_sha256 "$who" 2> /dev/null)"; v="${v:0:12}"
  printf '%s  %s\nsrc/ %s\nby %s (sha256 %s of the script)\n' "$h" "$(basename "$rep")" "$key" "$(basename "$who")" "${v:-unknown}" \
    > "$rep.sha256.tmp" 2> /dev/null && mv "$rep.sha256.tmp" "$rep.sha256" 2> /dev/null
}
# report_check <report> <the anchor of src/ now, or -: the content only>: RA_STATE ok | missing | none | mismatch |
#   stale, and RA_WHY (`report <name>: no anchor ...`, `... mismatch ...`, `... stale ...`; empty when ok or missing);
#   0 when ok. `-`: a report cited from history is checked against its own seal only, never for currency
# shellcheck disable=SC2034   # RA_STATE and RA_WHY: read by the scripts that source this
report_check() {
  local rep="$1" now="$2" name l1 l2 want key got
  name="$(basename "$rep")"; RA_WHY=""
  if [ ! -f "$rep" ]; then RA_STATE=missing; return 1; fi
  if [ ! -f "$rep.sha256" ]; then
    RA_STATE=none; RA_WHY="report $name: no anchor (no $name.sha256 beside it - the script that writes the report writes it)"; return 1
  fi
  l1="$(sed -n '1{s/\r$//;p;}' "$rep.sha256")"; l2="$(sed -n '2{s/\r$//;p;}' "$rep.sha256")"
  if ! [[ $l1 =~ ^([0-9a-f]{64})\ \ (.+)$ ]] || [ "${BASH_REMATCH[2]}" != "$name" ]; then
    RA_STATE=mismatch; RA_WHY="report $name: mismatch (its $name.sha256 is not '<sha256>  $name')"; return 1
  fi
  want="${BASH_REMATCH[1]}"
  if ! [[ $l2 =~ ^src/\ ([0-9a-f]{64}|none)$ ]]; then
    RA_STATE=mismatch; RA_WHY="report $name: mismatch (its $name.sha256 has no 'src/ <anchor>' line 2)"; return 1
  fi
  key="${BASH_REMATCH[1]}"
  got="$( { cat "$rep"; printf 'src/ %s\n' "$key"; } | _sa_sha256)"
  if [ "$got" != "$want" ]; then
    RA_STATE=mismatch; RA_WHY="report $name: mismatch (it is not the report its $name.sha256 sealed: ${want:0:8} sealed, ${got:0:8} now)"; return 1
  fi
  if [ "$now" != "-" ] && [ "$key" != "$now" ]; then
    RA_STATE=stale; RA_WHY="report $name: stale (written on src/ ${key:0:8}, src/ is ${now:0:8} now)"; return 1
  fi
  RA_STATE=ok; return 0
}

# src_anchor_check <who> <proj>: one line in SRC_ANCHOR_LINE, always - what this run is comparing src/ with - and
#   0  src/ is as recorded; or there is no record before phase 2 (a project of the route with no record is told how one is made, once
#      per project - the first command to see it leaves .gauntlet/src-anchor-told, and the later ones print no line;
#      a tree that is not a project of the route - no STATE.md: the kit's own module, a bench, someone else's - is
#      named as not anchored);
#   2  REFUSED: src/ differs from the record, or is gone, or the record is not of its shape - SRC_ANCHOR_LINE is the
#      refusal, the spec's in next.sh for src/: no escape, and no command an agent could run; or (v0.5.3) there is no
#      record and the project's phase is 2 or higher - the refusal names the owner's signed re-record, `--by <owner>`.
#   SRC_ANCHOR_SHORT is the same in a few words, for a summary line or a record.
# shellcheck disable=SC2034   # read by the scripts that source this
SRC_ANCHOR_LINE="" SRC_ANCHOR_SHORT=""
# shellcheck disable=SC2034   # SRC_ANCHOR_LINE and SRC_ANCHOR_SHORT: read by the scripts that source this
src_anchor_check() {
  local who="$1" proj="$2" rec line want now rr last tail
  rec="$proj/.gauntlet/src.sha256"
  tail="the code under audit is the owner's. Undo the change (put the owner's code back) and write what you assumed in DECISIONS.md (source: assumed, owner absent): a finding's fix is the owner's decision (doctrine/NEXT.md row 6b), shown on a copy (scripts/mutate.sh), never written into src/. The owner, present, re-records a change of their own with scripts/init-state.sh, signed; an agent never does it. Nothing run."
  if [ ! -f "$rec" ]; then
    # v0.5.3: from phase 2 a missing record is a refusal, never a pass (the header)
    if src_anchor_required "$proj"; then
      SRC_ANCHOR_SHORT="REFUSED: anchor record missing (.gauntlet/src.sha256) at phase $(src_anchor_phase "$proj")"
      SRC_ANCHOR_LINE="$who: REFUSED - anchor record missing: $rec; re-run scripts/init-state.sh $proj --src --by <owner> - the owner's act, signed: from phase 2 (doctrine/NEXT.md row 4b) src/ is anchored, and this project is at phase $(src_anchor_phase "$proj"); the owner absent: --by walker, with the note 'owner absent: <why>' in STATE.md's notes (the record then says by: walker (owner absent), and the dossier's section 8 carries it). Nothing run."
      return 2
    fi
    if [ -f "$proj/.gauntlet/STATE.md" ] || [ -f "$proj/STATE.md" ]; then
      SRC_ANCHOR_SHORT="no anchor recorded (.gauntlet/src.sha256)"
      # told ONCE per project (v0.4.2, after V60: on every command it was noise): the first command to see it says how
      # one is made and leaves .gauntlet/src-anchor-told; after that the line is empty - the battery's summary and each
      # red record still say `no anchor recorded`
      if [ -f "$proj/.gauntlet/src-anchor-told" ]; then SRC_ANCHOR_LINE=""; return 0; fi
      SRC_ANCHOR_LINE="$who: src/ has no anchor (.gauntlet/src.sha256): nothing compared. scripts/init-state.sh records it when it writes a new project's state; on this project, which has its state, recording it is the owner's act, signed (--src --by; the header of scripts/init-state.sh says how). Said once: the next commands say it in their summary and records only."
      if [ -d "$proj/.gauntlet" ]; then
        printf '%s %s told: src/ has no anchor (.gauntlet/src.sha256) - said once, here; the summaries and records keep saying it\n' "$(date +%F)" "$who" > "$proj/.gauntlet/src-anchor-told" 2> /dev/null || :
      fi
    else
      SRC_ANCHOR_SHORT="not anchored here (no .gauntlet/src.sha256, no STATE.md)"
      SRC_ANCHOR_LINE="$who: src/ is not anchored here (no .gauntlet/src.sha256 and no STATE.md: not a project of the route) - nothing compared."
    fi
    return 0
  fi
  line="$(sed -n '1{s/\r$//;p;}' "$rec")"
  if ! [[ $line =~ ^([0-9a-f]{64})\ \ src/?$ ]]; then
    SRC_ANCHOR_SHORT="REFUSED: the record is not of its shape"
    SRC_ANCHOR_LINE="$who: REFUSED - $rec is not '<sha256>  src/' (scripts/init-state.sh writes it): the owner records it again, signed (scripts/init-state.sh --src). Nothing run."
    return 2
  fi
  want="${BASH_REMATCH[1]}"
  if ! now="$(src_anchor_hash "$proj")"; then
    SRC_ANCHOR_SHORT="REFUSED: src/ is missing since it was recorded (${want:0:8})"
    SRC_ANCHOR_LINE="$who: REFUSED - $proj/src is missing since init-state recorded it (.gauntlet/src.sha256 ${want:0:8}): $tail"
    return 2
  fi
  if [ "$now" != "$want" ]; then
    SRC_ANCHOR_SHORT="REFUSED: src/ changed since it was recorded (${want:0:8}, now ${now:0:8})"
    SRC_ANCHOR_LINE="$who: REFUSED - $proj/src changed since init-state recorded it (.gauntlet/src.sha256 ${want:0:8}, now ${now:0:8}): $tail"
    return 2
  fi
  rr="" last="$(grep '^re-recorded ' "$rec" 2> /dev/null | tail -n 1)"
  if [[ $last =~ ^re-recorded\ ([^\ ]+)\ by\ \"(.*)\"\ ([0-9a-f]{8}|none)\ -\>\ ([0-9a-f]{8})$ ]]; then
    rr="; re-recorded on ${BASH_REMATCH[1]}, signed by \"${BASH_REMATCH[2]}\" (${BASH_REMATCH[3]} -> ${BASH_REMATCH[4]}): the owner confirms that signature is theirs"
  fi
  SRC_ANCHOR_SHORT="as recorded (.gauntlet/src.sha256 ${want:0:8})"
  SRC_ANCHOR_LINE="$who: src/ is as recorded (.gauntlet/src.sha256 ${want:0:8})$rr."
  return 0
}
