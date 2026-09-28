#!/usr/bin/env bash
#
# backtest.sh - "what would THIS hook have done, in this window of real swaps on this pool?" A sandbox report for the
# dossier (section 6, the sandbox row; section 9, what it cannot say). NOT a proof: doctrine/SIMULATE.md, "Backtests".
#
# What it does, in two steps:
#  1. THE FIXTURE. The pool's `Swap` events of blocks <from>+1 .. <to>, read from the chain's v4 PoolManager (`cast logs`,
#     the endpoint in RPC_URL), written as <project>/.gauntlet/backtests/<id8>-<from>-<to>.tsv - one swap per line: block,
#     timestamp, tx index, log index, sender, amount0, amount1, sqrtPriceX96, liquidity, tick, fee - and a .json sidecar:
#     the pool's key, the window, the number of swaps, the SHA-256 of the .tsv, the hash of block <to>, when it was fetched
#     and how many calls it took. A fixture that exists is REUSED (the events are not fetched again): its sidecar must be
#     there and agree with it (window, pool, count, hash), and the hash of block <to> is re-checked against the chain when
#     RPC_URL is set (one request) - never otherwise, and the report says which. The fetch goes into YOUR project: into
#     the kit's own module (foundry-kit/v4, whose .gauntlet/backtests/ git keeps) only with --allow-kit-fixtures.
#     Then, fetched or reused, it prints the window's swap count and the pool's in-range liquidity at the end of <from>
#     (one request, with RPC_URL). A window with NO swap is said and never replayed: "no swap in this window: pick
#     another", with how many swaps the pool had in the 1 000 blocks before <from> (with RPC_URL: eth_getLogs in the same
#     chunks as the fetch); --fetch-only then says FIXTURE READY (0 swaps). A liquidity THIN for the window - below 200 x
#     its largest swap in liquidity units (amount0 x sqrtP, amount1 / sqrtP: the liquidity under which that one swap
#     moves a full-range position about 1 % of the price) - is a WARNING line, never a refusal.
#  2. THE REPLAY. `forge test` in <project>, on a fork AT block <from>: every contract whose name ends in `Backtest` (or
#     exactly `<Contract>Backtest` with --hook) - each one a `BacktestBase` (foundry-kit/v4/src/BacktestBase.sol) that
#     deploys a hook, seeds a NEW pool of the same currencies, fee and spacing at the real pool's price with one full-range
#     position of its in-range liquidity, and drives every swap of the fixture through it, then through a control pool
#     with no hook. The report goes to <OUT_DIR>/07-backtest-<id8>-<from>-<to>-<Hook>.txt (<Hook> is --hook's value, or
#     `all`): one report per pool, window and hook, never overwritten by another's; forge's own log next to it (the same
#     name, ending -forge.txt). The replay's own requests to the endpoint are forge's: nothing counts them here.
#
# The window: the state is the pool's at the END of block <from> (a fork at <from> reads exactly that), the swaps are
# those of the <to> - <from> blocks after it. The key: the one the chain's PositionManager records for the pool
# (`poolKeys`, one call at block <to>), or --key; either way it must hash to the pool id, or nothing is written.
#
# Usage:   RPC_URL=... scripts/backtest.sh <project-dir> --pool <poolId> --from <block> --to <block> [--hook <Contract>]
#                                          [--key <currency0>,<currency1>,<fee>,<tickSpacing>,<hooks>] [--fetch-only]
#                                          [--allow-kit-fixtures]
# Env:     RPC_URL      the endpoint: to fetch, to re-check block <to>, and for the replay's fork (an ARCHIVE endpoint:
#                       the fork reads state at <from>). Never an argument, never printed; an error's text is scrubbed of
#                       anything shaped like a URL before it is shown (fetch-bytecode.sh, "THE KEY RULE")
#          OUT_DIR      where the report goes (default: <project>/.gauntlet/reports; a relative one is under <project>).
#                       Inside a project with no .gauntlet/ (someone else's tree) it refuses before anything is written
#                       (scripts/lib/owner-tree.sh), and so does the fixture's directory
#          BACKTEST_LOGS_CHUNK  blocks per eth_getLogs request (default 10: a free tier measured on 2026-09-28 refuses
#                       more than 10 blocks per request). A larger chunk is fewer requests where the endpoint allows it
#          FOUNDRY_PROFILE  the profile of the replay (default: `fork` when the project's foundry.toml has one, else
#                       forge's default). Every other FOUNDRY_ / FORGE_ / DAPP_ variable is removed (scripts/lib/forge-env.sh)
#          BACKTEST_FIXTURE  NOT read from the environment: the script sets it for forge (the fixture of THIS window)
# Rate:    an HTTP 429 (the endpoint's rate limit) is waited out ONCE, 2 s, and the call retried; a second one stops the
#          fetch and nothing is written. Every call counts in the sidecar's `castCalls`, retries included.
# Exit:    0 the report was written and every replay contract passed (or, with --fetch-only, the fixture is there and
#          checked - 0 swaps included); 1 refused or failed - the reason printed, and with a refused fetch nothing written
#          (a window with no swap: the fixture kept, the replay refused); 2 nothing run
#          (OUT_DIR or the fixture's directory refused, or the environment could not be cleaned)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || { echo "backtest: $HERE/lib/parse.sh is missing"; exit 1; }
# shellcheck source=lib/forge-env.sh
. "$HERE/lib/forge-env.sh" || { echo "backtest: $HERE/lib/forge-env.sh is missing"; exit 1; }
# shellcheck source=lib/owner-tree.sh
. "$HERE/lib/owner-tree.sh" || { echo "backtest: $HERE/lib/owner-tree.sh is missing"; exit 1; }
# forge's environment by allowlist: may re-run this script, once, without what it removed
forge_env_clean backtest "FOUNDRY_PROFILE" "$0" "$@"
unset BACKTEST_FIXTURE

# Ethereum mainnet's v4 PoolManager and PositionManager (foundry-kit/v4/README.md: "How we know the address is the v4
# PoolManager", "Which periphery, on which manager"). The replay's harness knows mainnet only (V4Harness, ForkNotMainnet).
POOL_MANAGER=0x000000000004444c5dc75cB358380D2e3dE08A90
POSITION_MANAGER=0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e
# SWAP_TOPIC is keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"): IPoolManager.Swap
SWAP_TOPIC=0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f

usage() {
  echo "usage: RPC_URL=... backtest.sh <project-dir> --pool <poolId> --from <block> --to <block> [--hook <Contract>]"
  echo "                               [--key <currency0>,<currency1>,<fee>,<tickSpacing>,<hooks>] [--fetch-only]"
  echo "                               [--allow-kit-fixtures]"
  exit 1
}

PROJ=""; POOL=""; FROM=""; TO=""; HOOK=""; KEY=""; FETCH_ONLY=0; ALLOW_KIT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pool) [ "$#" -ge 2 ] || usage; POOL="$2"; shift 2 ;;
    --from) [ "$#" -ge 2 ] || usage; FROM="$2"; shift 2 ;;
    --to) [ "$#" -ge 2 ] || usage; TO="$2"; shift 2 ;;
    --hook) [ "$#" -ge 2 ] || usage; HOOK="$2"; shift 2 ;;
    --key) [ "$#" -ge 2 ] || usage; KEY="$2"; shift 2 ;;
    --fetch-only) FETCH_ONLY=1; shift ;;
    --allow-kit-fixtures) ALLOW_KIT=1; shift ;;
    -*) echo "backtest: unknown option (${#1} characters; not repeated here)"; usage ;;
    *) [ -z "$PROJ" ] || usage; PROJ="$1"; shift ;;
  esac
done
[ -n "$PROJ" ] && [ -n "$POOL" ] && [ -n "$FROM" ] && [ -n "$TO" ] || usage

# an endpoint pasted in the wrong place is refused FIRST and never echoed back (fetch-bytecode.sh does the same)
for v in "$PROJ" "$POOL" "$FROM" "$TO" "$HOOK" "$KEY"; do
  case "$v" in *://*) echo "backtest: an argument is an endpoint. The endpoint goes in RPC_URL, never on the command line."; exit 1 ;; esac
done
# a block NUMBER, in decimal: no tag, no hex, no sign, no leading zero; and the window goes forward
for b in from to; do
  if [ "$b" = from ]; then v="$FROM"; else v="$TO"; fi
  case "$v" in
    ''|0?*|*[!0-9]*) echo "backtest: --$b takes a block number in decimal (what came after it is not one, and is not repeated here: ${#v} characters)"; exit 1 ;;
  esac
done
if [ "${#FROM}" -gt 12 ] || [ "${#TO}" -gt 12 ]; then echo "backtest: a block number of more than 12 digits is not one"; exit 1; fi
if [ "$TO" -le "$FROM" ]; then echo "backtest: --to ($TO) must be after --from ($FROM): the window is the blocks after --from, up to --to"; exit 1; fi
case "$POOL" in
  0x*) ;;
  *) echo "backtest: --pool takes a v4 pool id: 0x and 64 hex digits (this is ${#POOL} characters)"; exit 1 ;;
esac
if [ "${#POOL}" -ne 66 ] || [[ ! "${POOL#0x}" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "backtest: --pool takes a v4 pool id: 0x and 64 hex digits (this is ${#POOL} characters)"; exit 1
fi
POOL="$(printf '%s' "$POOL" | tr 'A-F' 'a-f')"
if [ -n "$HOOK" ] && [[ ! "$HOOK" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "backtest: --hook takes a contract name (letters, digits, _): the replay runs the contract <name>Backtest"; exit 1
fi
CHUNK="${BACKTEST_LOGS_CHUNK:-10}"
case "$CHUNK" in ''|0*|*[!0-9]*) echo "backtest: BACKTEST_LOGS_CHUNK must be a whole number of blocks, 1 or more"; exit 1 ;; esac
if [ -n "$KEY" ]; then
  IFS=, read -r K_C0 K_C1 K_FEE K_TS K_HOOKS K_EXTRA <<< "$KEY"
  if [ -n "${K_EXTRA:-}" ] || ! is_evm_address "${K_C0:-}" || ! is_evm_address "${K_C1:-}" || ! is_evm_address "${K_HOOKS:-}" \
    || [[ ! "${K_FEE:-}" =~ ^(0|[1-9][0-9]{0,7})$ ]] || [[ ! "${K_TS:-}" =~ ^[1-9][0-9]{0,4}$ ]]; then
    echo "backtest: --key takes <currency0>,<currency1>,<fee>,<tickSpacing>,<hooks>: three 0x addresses, the fee and the spacing in decimal"; exit 1
  fi
fi

[ -d "$PROJ" ] || { echo "backtest: $PROJ is not a directory"; exit 1; }
PROJ_ABS="$(cd "$PROJ" && pwd -P)"
[ -f "$PROJ_ABS/foundry.toml" ] || { echo "backtest: $PROJ_ABS has no foundry.toml: the replay is a forge test in the project"; exit 1; }
# the kit's own v4 module: its .gauntlet/backtests/ is COMMITTED (the kit's window). A fixture of another window fetched
# there would be picked up by git - so a fetch into it is refused unless --allow-kit-fixtures; reusing one is not
KIT_V4="$(cd "$HERE/../foundry-kit/v4" 2> /dev/null && pwd -P)"
IS_KIT=0; if [ -n "$KIT_V4" ] && [ "$PROJ_ABS" = "$KIT_V4" ]; then IS_KIT=1; fi
FIX_REL=".gauntlet/backtests"
OUT_DIR="${OUT_DIR:-.gauntlet/reports}"
report_dir_allowed backtest "$PROJ_ABS" "$FIX_REL" || { echo "backtest: nothing run."; exit 2; }
report_dir_allowed backtest "$PROJ_ABS" "$OUT_DIR" || { echo "backtest: nothing run."; exit 2; }
case "$OUT_DIR" in /*) OUT_ABS="$OUT_DIR" ;; *) OUT_ABS="$PROJ_ABS/$OUT_DIR" ;; esac

NAME="${POOL:2:8}-$FROM-$TO"
TSV_REL="$FIX_REL/$NAME.tsv"
TSV="$PROJ_ABS/$TSV_REL"
SIDE="$PROJ_ABS/$FIX_REL/$NAME.json"

# anything of the shape scheme://... is replaced before a byte of a tool's error output is shown (fetch-bytecode.sh)
scrub() { sed -e 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]*#<RPC_URL>#g'; }
ERRF="$(mktemp)"; WORK="$(mktemp -d)"
trap 'rm -rf "$ERRF" "$WORK"' EXIT
CALLS=0
# net <out-file> <cast args...>: one call to the endpoint through cast (which reads ETH_RPC_URL: never --rpc-url, which
# would put the endpoint in the process list). An HTTP 429 is waited out once and the call retried; each try counts.
net() {
  local out="$1"; shift
  CALLS=$((CALLS + 1))
  if cast "$@" > "$out" 2> "$ERRF"; then return 0; fi
  if grep -Eqi 'error 429|too many requests' "$ERRF"; then
    echo "backtest: HTTP 429 from the endpoint (rate limit) on cast $1: waiting 2 s and retrying once"
    sleep 2
    CALLS=$((CALLS + 1))
    if cast "$@" > "$out" 2> "$ERRF"; then return 0; fi
  fi
  return 1
}
fail_net() { echo "backtest: $1. Scrubbed error:"; scrub < "$ERRF" | head -5; echo "backtest: nothing written."; exit 1; }
json_field() { # json_field <file> <name>: the value of "name": in the sidecar this script writes (one field per line)
  sed -n "s/^  \"$2\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" "$1" | head -1
}
sha_of() { local h; h="$(printf '%s\n' "$1" | sha256_of | cut -f1)"; [ -n "$h" ] || return 1; printf '%s\n' "$h"; }
count_swaps() { awk 'NR > 2 && length($0) > 0 { n++ } END { print n + 0 }' "$1"; }
plural() { if [ "$1" = 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi; } # plural <n> <noun>

if [ -n "${RPC_URL:-}" ]; then
  command -v cast > /dev/null 2>&1 || { echo "backtest: cast not found (install Foundry)"; exit 1; }
  export ETH_RPC_URL="$RPC_URL"
fi

echo "== backtest =="
echo "project   $PROJ_ABS"
echo "pool      $POOL"
echo "window    the state at the end of block $FROM, the swaps of blocks $((FROM + 1)) .. $TO ($((TO - FROM)) blocks)"
FETCHED_NOW=0; RECHECK="not re-checked (RPC_URL not set)"

if [ -e "$TSV" ] || [ -e "$SIDE" ]; then
  # ---------------------------------------------------------------- an existing fixture: reused, and checked first
  [ -f "$TSV" ] || { echo "backtest: $SIDE is there but its fixture $TSV is not: restore it, or remove the sidecar to fetch again. Nothing run."; exit 1; }
  [ -f "$SIDE" ] || { echo "backtest: $TSV is there but its sidecar $SIDE is not: a fixture without its sidecar is not read (its window, key and hash are in it). Nothing run."; exit 1; }
  bad=""
  [ "$(json_field "$SIDE" format)" = "1" ] || bad="$bad format"
  [ "$(json_field "$SIDE" poolId)" = "$POOL" ] || bad="$bad poolId"
  [ "$(json_field "$SIDE" from)" = "$FROM" ] || bad="$bad from"
  [ "$(json_field "$SIDE" to)" = "$TO" ] || bad="$bad to"
  side_sha="$(json_field "$SIDE" tsvSha256)"
  tsv_sha="$(sha_of "$TSV")" || { echo "backtest: cannot hash $TSV (no sha256sum, shasum or openssl). Nothing run."; exit 1; }
  [ "$side_sha" = "0x$tsv_sha" ] || bad="$bad tsvSha256"
  [ "$(json_field "$SIDE" swaps)" = "$(count_swaps "$TSV")" ] || bad="$bad swaps"
  if [ -n "$bad" ]; then
    echo "backtest: the fixture and its sidecar disagree on:$bad - an edited, truncated or mismatched pair is not replayed."
    echo "backtest: fetch it again (remove both files), or restore both. Nothing run."
    exit 1
  fi
  if [ -n "${RPC_URL:-}" ]; then
    net "$WORK/hash" block "$TO" --field hash || fail_net "the endpoint did not answer for block $TO"
    if [ "$(tr -d '[:space:]' < "$WORK/hash")" != "$(json_field "$SIDE" toBlockHash)" ]; then
      echo "backtest: block $TO on this endpoint is not the block the fixture was fetched at (another chain, or a reorg): refused. Nothing run."
      exit 1
    fi
    RECHECK="re-checked: block $TO has the hash the sidecar names (1 request)"
  fi
  echo "fixture   $TSV_REL - reused, $(count_swaps "$TSV") swaps, sidecar agrees; block $TO $RECHECK"
else
  # ---------------------------------------------------------------- no fixture: fetch it
  if [ "$IS_KIT" = 1 ] && [ "$ALLOW_KIT" != 1 ]; then
    cat <<EOF
backtest: $PROJ_ABS is the kit's own v4 module, and it has no fixture for this window. A fixture you fetch goes under
          YOUR project's .gauntlet/backtests/ - run this on your project, with a <YourHook>Backtest in it
          (foundry-kit/v4/README.md, "Your hook, your pool") - never into the kit's, which git keeps (its committed window).
          To replay the kit's own examples on another window anyway, add --allow-kit-fixtures: the fixture then lands in
          foundry-kit/v4/.gauntlet/backtests/ - do not commit it. Nothing asked of the chain, nothing written.
EOF
    exit 1
  fi
  if [ -z "${RPC_URL:-}" ]; then
    cat <<EOF
backtest: no fixture at $TSV_REL and RPC_URL is not set: nothing to replay.

  Set it in YOUR OWN terminal and run this script again (fetch-bytecode.sh, "THE KEY RULE"):

      export RPC_URL='https://<an archive endpoint>'

  Never on the command line, never pasted into a chat.
EOF
    exit 1
  fi
  mkdir -p "$PROJ_ABS/$FIX_REL" || { echo "backtest: cannot create $PROJ_ABS/$FIX_REL"; exit 1; }
  net "$WORK/chain" chain-id || fail_net "the endpoint in RPC_URL did not answer eth_chainId"
  chain="$(tr -d '[:space:]' < "$WORK/chain")"
  [ "$chain" = "1" ] || { echo "backtest: the endpoint is chain ${chain:-?}, not Ethereum mainnet (1): the replay's harness knows mainnet's addresses only. Nothing written."; exit 1; }
  net "$WORK/hash" block "$TO" --field hash || fail_net "chain 1 has no block $TO here (in the future, or pruned)"
  TO_HASH="$(tr -d '[:space:]' < "$WORK/hash")"
  case "$TO_HASH" in 0x[0-9a-fA-F]*) ;; *) fail_net "block $TO has no hash here" ;; esac
  if [ -n "$KEY" ]; then
    KEY_FROM="--key"
  else
    net "$WORK/key" call --block "$TO" "$POSITION_MANAGER" "poolKeys(bytes25)(address,address,uint24,int24,address)" "${POOL:0:52}" \
      || fail_net "the PositionManager did not answer poolKeys"
    { read -r K_C0; read -r K_C1; read -r K_FEE; read -r K_TS; read -r K_HOOKS; } < "$WORK/key"
    K_C0="${K_C0%% *}"; K_C1="${K_C1%% *}"; K_FEE="${K_FEE%% *}"; K_TS="${K_TS%% *}"; K_HOOKS="${K_HOOKS%% *}"
    if [ "$K_C0$K_C1" = "0x00000000000000000000000000000000000000000x0000000000000000000000000000000000000000" ] || ! is_evm_address "${K_C1:-}"; then
      echo "backtest: the chain's PositionManager does not know pool $POOL (never used through it): give its key with --key. Nothing written."
      exit 1
    fi
    KEY_FROM="PositionManager.poolKeys at block $TO"
  fi
  enc="$(cast abi-encode "f(address,address,uint24,int24,address)" "$K_C0" "$K_C1" "$K_FEE" "$K_TS" "$K_HOOKS" 2> "$ERRF")" \
    || fail_net "the key does not encode"
  kh="$(cast keccak "$enc" 2> "$ERRF" | tr 'A-F' 'a-f')"
  if [ "$kh" != "$POOL" ]; then
    echo "backtest: the key ($KEY_FROM: $K_C0, $K_C1, fee $K_FEE, spacing $K_TS, hooks $K_HOOKS) hashes to $kh, not to $POOL. Nothing written."
    exit 1
  fi
  echo "key       $K_C0 / $K_C1, fee $K_FEE, spacing $K_TS, hooks $K_HOOKS ($KEY_FROM; hashes to the pool id)"

  # the events, BACKTEST_LOGS_CHUNK blocks per request, in order
  : > "$WORK/records"
  a=$((FROM + 1))
  while [ "$a" -le "$TO" ]; do
    b=$((a + CHUNK - 1)); [ "$b" -le "$TO" ] || b="$TO"
    net "$WORK/chunk" logs --json --from-block "$a" --to-block "$b" --address "$POOL_MANAGER" "$SWAP_TOPIC" "$POOL" \
      || fail_net "eth_getLogs for blocks $a .. $b failed (a range limit? BACKTEST_LOGS_CHUNK=$CHUNK)"
    # one object per line: the objects hold no brace of their own
    tr -d '\n' < "$WORK/chunk" | sed -e 's/^\[//' -e 's/\]$//' | tr '}' '\n' | grep '"blockNumber"' >> "$WORK/records"
    a=$((b + 1))
  done
  printf '# hook-gauntlet backtest fixture 1: the Swap events of v4 pool %s on chain 1, blocks %s .. %s (the replay starts from the state at the end of block %s). Written by scripts/backtest.sh; public event data.\n' \
    "$POOL" "$((FROM + 1))" "$TO" "$FROM" > "$WORK/out.tsv"
  printf 'block\ttimestamp\ttxIndex\tlogIndex\tsender\tamount0\tamount1\tsqrtPriceX96\tliquidity\ttick\tfee\n' >> "$WORK/out.tsv"
  declare -A TS=()
  n=0; ts_calls=0
  while IFS= read -r rec; do
    field() { [[ "$rec" =~ \"$1\":\"(0x[0-9a-fA-F]*)\" ]] && printf '%s' "${BASH_REMATCH[1]}"; }
    [[ "$rec" =~ \"removed\":true ]] && { echo "backtest: the endpoint returned a REMOVED log (a reorg while fetching): fetch again. Nothing written."; exit 1; }
    bn="$(field blockNumber)"; ti="$(field transactionIndex)"; li="$(field logIndex)"; data="$(field data)"; bt="$(field blockTimestamp)"
    [[ "$rec" =~ \"topics\":\[\"(0x[0-9a-fA-F]{64})\",\"(0x[0-9a-fA-F]{64})\",\"0x[0]{24}([0-9a-fA-F]{40})\"\] ]] \
      || { echo "backtest: a log without the Swap event's three topics: not read. Nothing written."; exit 1; }
    t0="${BASH_REMATCH[1]}"; t1="$(printf '%s' "${BASH_REMATCH[2]}" | tr 'A-F' 'a-f')"; sender="0x${BASH_REMATCH[3]}"
    addr=""; [[ "$rec" =~ \"address\":\"(0x[0-9a-fA-F]{40})\" ]] && addr="$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-F' 'a-f')"
    if [ "$t0" != "$SWAP_TOPIC" ] || [ "$t1" != "$POOL" ] || [ "$addr" != "$(printf '%s' "$POOL_MANAGER" | tr 'A-F' 'a-f')" ]; then
      echo "backtest: a log that is not this pool's Swap on the PoolManager came back: not read. Nothing written."; exit 1
    fi
    [ -n "$bn" ] && [ -n "$ti" ] && [ -n "$li" ] && [ "${#data}" -eq 386 ] || { echo "backtest: a Swap log without its block, indices or six data words. Nothing written."; exit 1; }
    bnd=$((16#${bn#0x})); tid=$((16#${ti#0x})); lid=$((16#${li#0x}))
    if [ -n "$bt" ]; then TS[$bnd]=$((16#${bt#0x})); fi
    if [ -z "${TS[$bnd]:-}" ]; then
      net "$WORK/ts" block "$bnd" --field timestamp || fail_net "the timestamp of block $bnd"
      ts_calls=$((ts_calls + 1)); TS[$bnd]="$(tr -d '[:space:]' < "$WORK/ts")"
    fi
    dec="$(cast abi-decode --input "f(int128,int128,uint160,uint128,int24,uint24)" "$data" 2> "$ERRF" | awk '{ print $1 }' | paste -sd '\t' -)"
    if [[ ! "$dec" =~ ^-?[0-9]+$'\t'-?[0-9]+$'\t'[0-9]+$'\t'[0-9]+$'\t'-?[0-9]+$'\t'[0-9]+$ ]]; then
      echo "backtest: a Swap's data did not decode into six numbers. Nothing written."; exit 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$bnd" "${TS[$bnd]}" "$tid" "$lid" "$sender" "$dec" >> "$WORK/out.tsv"
    n=$((n + 1))
  done < "$WORK/records"
  tsv_sha="$(sha_of "$WORK/out.tsv")" || { echo "backtest: cannot hash the fixture (no sha256sum, shasum or openssl). Nothing written."; exit 1; }
  ts_from="the logs' blockTimestamp"; [ "$ts_calls" -eq 0 ] || ts_from="eth_getBlockByNumber, one per block ($ts_calls)"
  cat > "$WORK/out.json" <<EOF
{
  "format": 1,
  "chainId": 1,
  "poolManager": "$POOL_MANAGER",
  "poolId": "$POOL",
  "currency0": "$K_C0",
  "currency1": "$K_C1",
  "fee": $K_FEE,
  "tickSpacing": $K_TS,
  "hooks": "$K_HOOKS",
  "keyFrom": "$KEY_FROM",
  "from": $FROM,
  "to": $TO,
  "toBlockHash": "$TO_HASH",
  "swaps": $n,
  "tsvSha256": "0x$tsv_sha",
  "fetchedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "fetchedWith": "$(cast --version 2> /dev/null | head -1 | tr -d '"\\')",
  "logsChunk": $CHUNK,
  "timestampsFrom": "$ts_from",
  "castCalls": $CALLS
}
EOF
  mv "$WORK/out.tsv" "$TSV" && mv "$WORK/out.json" "$SIDE" || { echo "backtest: cannot write $TSV"; exit 1; }
  FETCHED_NOW=1
  echo "fixture   $TSV_REL - fetched now: $(plural "$n" swap), $(plural "$CALLS" call) to the endpoint (chunks of $CHUNK blocks; timestamps from $ts_from)"
fi

# ---------------------------------------------------------------- what the window holds: its swaps, and the pool's liquidity at <from>
SWAPS="$(count_swaps "$TSV")"
echo "swaps     $(plural "$SWAPS" swap) in blocks $((FROM + 1)) .. $TO"
LIQ=""; SQRTP=""; THIN=""
LIQ_LINE="not read (RPC_URL not set)"
if [ -n "${RPC_URL:-}" ]; then
  # StateLibrary: the pool's state is at keccak256(poolId . 6) (POOLS_SLOT), slot0 first (sqrtPriceX96 in its low 160
  # bits), the in-range liquidity 3 slots on (its low 128 bits); one extsload of 4 slots, at block <from>
  slot="$(cast index bytes32 "$POOL" 6 2> "$ERRF")"
  if [[ ! "$slot" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    LIQ_LINE="not read (cast index did not give the pool's state slot)"
  elif ! net "$WORK/state" call --block "$FROM" "$POOL_MANAGER" "extsload(bytes32,uint256)(bytes32[])" "$slot" 4; then
    LIQ_LINE="not read: the endpoint did not answer ($(scrub < "$ERRF" | head -1 | cut -c1-160))"
  else
    words="$(tr -d '[] \n' < "$WORK/state" | tr ',' '\n')"
    w0="$(printf '%s\n' "$words" | sed -n 1p)"; w3="$(printf '%s\n' "$words" | sed -n 4p)"
    if [[ "$w0" =~ ^0x[0-9a-fA-F]{64}$ ]] && [[ "$w3" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
      SQRTP="$(cast to-dec "0x${w0: -40}" 2> /dev/null)"; LIQ="$(cast to-dec "0x${w3: -32}" 2> /dev/null)"
    fi
    if [[ ! "$SQRTP" =~ ^[0-9]+$ ]] || [[ ! "$LIQ" =~ ^[0-9]+$ ]]; then
      SQRTP=""; LIQ=""; LIQ_LINE="not read (the manager's answer was not four 32-byte words)"
    elif [ "$LIQ" = 0 ] || [ "$SQRTP" = 0 ]; then
      LIQ_LINE="$LIQ at the end of block $FROM"
      THIN="WARNING: the pool has NO liquidity in range at the end of block $FROM (or is not initialised): the replay's seed will stop at RealPoolEmptyAtFrom"
    elif [ "$SWAPS" -eq 0 ]; then
      LIQ_LINE="$LIQ at the end of block $FROM (no swap in the window: nothing to measure it against)"
    else
      # the liquidity under which the window's largest swap alone moves a full-range position of it by about 1 % of the
      # price: token0 in, a x sqrtP x 198.5; token1 in, a / sqrtP x 200.5 (sqrtP = sqrtPriceX96 / 2^96; the fee aside)
      LMIN="$(awk -F'\t' -v p="$SQRTP" 'NR > 2 && NF == 11 { s = p / 79228162514264337593543950336; a = 0
          if ($6 + 0 < 0) a = -$6 * s; else if ($7 + 0 < 0) a = -$7 / s; if (a > m) m = a }
        END { printf "%.0f", 200 * m }' "$TSV")"
      LIQ_LINE="$LIQ at the end of block $FROM (thin below $LMIN: 200 x the window's largest swap in liquidity units)"
      if awk -v l="$LIQ" -v t="$LMIN" 'BEGIN { exit !(l + 0 < t + 0) }'; then
        THIN="WARNING: thin for this window - $LIQ in range at block $FROM is below $LMIN: the window's largest swap alone moves a full-range position of it by more than about 1 % of the price, so the replay's one position stands in for ranges the real price crossed. Read the control's drift before the hook's numbers (a warning, not a refusal)"
      fi
    fi
  fi
fi
echo "liquidity $LIQ_LINE"
[ -z "$THIN" ] || echo "backtest: $THIN"

if [ "$SWAPS" -eq 0 ]; then
  # nothing to replay: said, with where the swaps were - the 1 000 blocks before <from>, in the fetch's chunks
  hint="how many swaps it had in the 1 000 blocks before $FROM was not counted (RPC_URL not set)"
  if [ -n "${RPC_URL:-}" ]; then
    lb_from=$((FROM - 1000)); [ "$lb_from" -ge 0 ] || lb_from=0
    lb_to=$((FROM - 1)); before=0; lb_ok=1; a="$lb_from"; b="$lb_to"
    while [ "$a" -le "$lb_to" ]; do
      b=$((a + CHUNK - 1)); [ "$b" -le "$lb_to" ] || b="$lb_to"
      if ! net "$WORK/chunk" logs --json --from-block "$a" --to-block "$b" --address "$POOL_MANAGER" "$SWAP_TOPIC" "$POOL"; then
        lb_ok=0; break
      fi
      k="$(tr -d '\n' < "$WORK/chunk" | tr '}' '\n' | grep -c '"blockNumber"')"
      before=$((before + k)); a=$((b + 1))
    done
    if [ "$lb_to" -lt "$lb_from" ]; then
      hint="there is no block before $FROM to count"
    elif [ "$lb_ok" = 1 ]; then
      hint="the pool had $(plural "$before" swap) in the 1 000 blocks before $FROM (blocks $lb_from .. $lb_to)"
    else
      hint="how many swaps it had in the 1 000 blocks before $FROM could not be counted (eth_getLogs for blocks $a .. $b: $(scrub < "$ERRF" | head -1 | cut -c1-160))"
    fi
  fi
  echo "backtest: no swap in this window: pick another; $hint"
  if [ "$FETCH_ONLY" = 1 ]; then
    echo "backtest: FIXTURE READY (0 swaps) - $TSV_REL (--fetch-only: no replay)"
    exit 0
  fi
  echo "backtest: the replay is refused: a window with no swap replays nothing (the fixture is kept: $TSV_REL). Nothing run."
  exit 1
fi

if [ "$FETCH_ONLY" = 1 ]; then
  echo "backtest: FIXTURE READY - $TSV_REL ($(plural "$SWAPS" swap); --fetch-only: no replay)"
  exit 0
fi

# ---------------------------------------------------------------- the replay
if [ -z "${RPC_URL:-}" ]; then
  echo "backtest: the fixture is ready ($TSV_REL, reused next time without fetching), but the replay forks the chain at block"
  echo "          $FROM and RPC_URL is not set: export it (an archive endpoint) in your own shell and run this again. Nothing replayed."
  exit 1
fi
cd "$PROJ_ABS" || exit 1
if ! forge_dotenv_check backtest "$PROJ_ABS"; then echo "backtest: FAILED - nothing replayed"; exit 1; fi
PROFILE="${FOUNDRY_PROFILE:-}"
if [ -z "$PROFILE" ] && grep -q '^\[profile\.fork\]' foundry.toml; then PROFILE=fork; fi
if [ -n "$HOOK" ]; then MATCH="^${HOOK}Backtest\$"; else MATCH="Backtest\$"; fi
mkdir -p "$OUT_ABS"
# one report per pool, window and hook: another run's report is never overwritten by this one
RUN_NAME="07-backtest-$NAME-${HOOK:-all}"
FORGE_LOG="$OUT_ABS/$RUN_NAME-forge.txt"
REPORT="$OUT_ABS/$RUN_NAME.txt"
echo "replay    forge test --match-contract '$MATCH' -vv, profile ${PROFILE:-default}, V4_MANAGER=fork, forked at block $FROM"
echo "report    $REPORT"
started=$SECONDS
if [ -n "$PROFILE" ]; then export FOUNDRY_PROFILE="$PROFILE"; else unset FOUNDRY_PROFILE; fi
V4_MANAGER=fork BACKTEST_FIXTURE="$TSV_REL" forge test --match-contract "$MATCH" -vv 2>&1 | scrub > "$FORGE_LOG"
rc_forge=${PIPESTATUS[0]}
wall=$((SECONDS - started))
summary="$(parse_test_summary "$FORGE_LOG")"; rc_sum=$?
passed="?"; failed="?"; skipped="?"
if [ "$rc_sum" -eq 0 ]; then read -r passed failed skipped _ <<< "$summary"; fi

# ---------------------------------------------------------------- the report, from the replay's BT| lines
grep -a '^  BT|' "$FORGE_LOG" | sed 's/^  //' > "$WORK/bt"
{
  echo "== backtest report =="
  echo "project      $PROJ_ABS"
  echo "pool         $POOL (chain 1): $(json_field "$SIDE" currency0) / $(json_field "$SIDE" currency1), fee $(json_field "$SIDE" fee), spacing $(json_field "$SIDE" tickSpacing), hooks $(json_field "$SIDE" hooks) (key from $(json_field "$SIDE" keyFrom))"
  echo "window       the state at the end of block $FROM; the swaps of blocks $((FROM + 1)) .. $TO ($((TO - FROM)) blocks)"
  echo "fixture      $TSV_REL: $(plural "$(json_field "$SIDE" swaps)" swap), sha256 $(json_field "$SIDE" tsvSha256), fetched $(json_field "$SIDE" fetchedAt) with $(json_field "$SIDE" fetchedWith)"
  if [ "$FETCHED_NOW" = 1 ]; then echo "             fetched in this run"; else echo "             reused (not fetched again); block $TO $RECHECK"; fi
  echo "replay       forge test --match-contract '$MATCH', profile ${PROFILE:-default}, V4_MANAGER=fork, a fork at block $FROM; $wall s"
  echo "forge        rc $rc_forge; passed $passed, failed $failed, skipped $skipped (log: $FORGE_LOG)"
  echo "liquidity    in range: $LIQ_LINE"
  [ -z "$THIN" ] || echo "             $THIN"
  echo "rpc          fetch: $(plural "$(json_field "$SIDE" castCalls)" call) to the endpoint when the fixture was fetched (sidecar castCalls: one"
  echo "             per cast call, retries included; chunks of $(json_field "$SIDE" logsChunk) blocks; timestamps from $(json_field "$SIDE" timestampsFrom))"
  if [ "$FETCHED_NOW" = 1 ]; then what="the fetch, and the liquidity at block $FROM"; else what="the re-check of block $TO and the liquidity at block $FROM; the fixture was reused"; fi
  echo "             this run, this script: $(plural "$CALLS" call) ($what)"
  echo "             the replay: forge's own requests (its fork at block $FROM), and UNCOUNTED - neither this script nor forge counts"
  echo "             them (foundry-kit/v4/README.md, \"What it cost\": the kit's window, counted through a relay)"
  # the protocol fee is two 12-bit values in one word: zeroForOne in the low bits, oneForZero in the high ones (v4-core)
  awk -F'|' '$2 == "seed" { printf "seed         the real pool at the end of block %s: sqrtPriceX96 %s, tick %s, in-range liquidity %s, lp fee %s, protocol fee %d / %d pips (0 to 1 / 1 to 0)\n", FROM, $3, $4, $5, $6, $7 % 4096, int($7 / 4096); exit }' FROM="$FROM" "$WORK/bt"
  echo
  echo "== what this replay is not (the substitutions) =="
  echo "- the liquidity: ONE full-range position of the real pool's in-range liquidity at block $FROM, in a NEW pool (a hook is part"
  echo "  of a pool's key: it cannot be attached to the pool that exists). The real pool's ranges, and every add and remove of"
  echo "  the window, are absent: deviations grow wherever the real price crossed a tick where liquidity changed."
  echo "- the swaps: every one EXACT-IN of what the real swapper paid in, in the real direction, with no price limit, through the"
  echo "  kit's MinimalRouter, by one trader. Exact-out swaps, limits, multi-hop routes, the real routers and senders are not."
  echo "- the reactions: the order is the chain's, but the swaps were placed against the REAL pool's price. A hook that changes"
  echo "  what a swap pays moves this pool's price under later swaps that were never placed against it; arbitrage, MEV and"
  echo "  the hook's own effect on who trades are not modelled."
  echo "- the fees: the hook pool's key has the real fee unless the hook needs another (a dynamic-fee hook sets its own, and"
  echo "  its runs line shows the flag, 8388608); the protocol fee is whatever the chain's controller gives a NEW pool on the"
  echo "  fork (the runs table), which need not be the real pool's (the seed line) - the swapper's output moves by the difference."
  echo "- the control: the same replay, in a test of its own, on a pool with NO hook (same currencies and fee; tick spacing"
  echo "  doubled, the real key being taken), one per hook contract - control(<hook>). Its deviations are the replay's own;"
  echo "  the hook's effect is the difference from ITS control (the gas of two controls can differ by a few units: the test"
  echo "  contracts' own code differs)."
  echo
  echo "== runs =="
  echo "run hook fee spacing protocolFee(0to1/1to0) liquidity"
  awk -F'|' '$2 == "run" { print $3, $4, $5, $6, ($7 % 4096) "/" int($7 / 4096), $8 }' "$WORK/bt" | sort -u
  echo
  echo "== totals per run =="
  echo "run swaps replayed refused unreplayable took0 took1 returned0 returned1 donated0 donated1 lpFees0 lpFees1 swapFeeMin swapFeeMax gasAvg gasMax booksOpen maxAbsDevPpm"
  awk -F'|' '$2 == "total" { s = $3; for (i = 4; i <= NF; i++) s = s " " $i; print s }' "$WORK/bt" | sort -u
  echo
  echo "(took = the hook's delta, positive, summed: what it took from swappers; returned = its negative delta: what it paid"
  echo " them; donated = Donate events on its pool; lpFees = what the one position earned as LP fees; the currencies are the"
  echo " key's 0 and 1, in their smallest units; swapFee is the manager's, protocol fee included; gas is the router call's,"
  echo " one test transaction per run; booksOpen = swaps where swapper + hook + manager != 0; maxAbsDevPpm = the largest"
  echo " distance of this pool's post-swap price from the real pool's, in parts per million of the price)"
  echo
  echo "== refusals =="
  awk -F'|' '$2 == "swap" && $8 == "refused" { if (!(($3 " " $9) in c)) k[++n] = $3 " " $9; c[$3 " " $9]++ }
    END { for (i = 1; i <= n; i++) print k[i], c[k[i]]; if (n == 0) print "none" }' "$WORK/bt"
  echo
  echo "== the ten largest deviations from the real pool's post-swap price, per run (ppm of price) =="
  echo "run swap block direction amountIn devPpm outDevPpm"
  # the controls of several hook contracts replay the same swaps on the same pool: their deviations are listed once
  awk -F'|' '$2 == "swap" && $8 == "replayed" { d = $16 < 0 ? -$16 : $16; n = $3; if (n ~ /^control\(/) n = "control"
    print d, n, $4, $5, $6, $7, $16, $17 }' "$WORK/bt" \
    | sort -u | sort -k2,2 -k1,1nr | awk '{ if (++n[$2] <= 10) print $2, $3, $4, $5, $6, $7, $8 }'
  echo
  echo "== the hooks' own ledgers =="
  awk -F'|' '$2 == "note" { print $3 ": " $4 }' "$WORK/bt" | sort -u
  echo
  echo "== each hook minus its control, per total (what the hook changed; the replay's own drift is in both) =="
  echo "run swaps replayed refused unreplayable took0 took1 returned0 returned1 donated0 donated1 lpFees0 lpFees1 swapFeeMin swapFeeMax gasAvg gasMax booksOpen maxAbsDevPpm"
  # exact: whole numbers of any length, digit by digit (an amount in wei does not fit a double)
  awk -F'|' '
    function norm(x) { sub(/^0+/, "", x); return x == "" ? "0" : x }
    function cmp(a, b) { a = norm(a); b = norm(b); if (length(a) != length(b)) return length(a) < length(b) ? -1 : 1
      return ("x" a) < ("x" b) ? -1 : (("x" a) > ("x" b) ? 1 : 0) }
    function bsub(a, b,   neg, t, r, i, d, borrow, la, lb) {
      if (a !~ /^[0-9]+$/ || b !~ /^[0-9]+$/) return "?"
      a = norm(a); b = norm(b); neg = 0
      if (cmp(a, b) < 0) { t = a; a = b; b = t; neg = 1 }
      r = ""; borrow = 0; la = length(a); lb = length(b)
      for (i = 0; i < la; i++) {
        d = substr(a, la - i, 1) - borrow - (i < lb ? substr(b, lb - i, 1) : 0)
        if (d < 0) { d += 10; borrow = 1 } else borrow = 0
        r = d r
      }
      r = norm(r); return (neg && r != "0" ? "-" : "") r }
    $2 == "total" && !($3 in row) { row[$3] = $0; if ($3 !~ /^control\(/) hooks[++n] = $3 }
    END {
      for (i = 1; i <= n; i++) {
        h = hooks[i]; c = "control(" h ")"
        if (!(c in row)) { print h ": no " c " row - not computed"; continue }
        split(row[h], x, "|"); split(row[c], y, "|"); s = h
        for (j = 4; j <= 21; j++) s = s " " bsub(x[j], y[j])
        print s
      }
      if (n == 0) print "none (no hook run in the log)"
    }' "$WORK/bt"
  echo
  echo "== the control's fidelity (what its _checkControl held on THIS window) =="
  awk -F'|' '$2 == "fidelity" { t = $4; for (i = 5; i <= NF; i++) t = t "|" $i; f[$3] = t }
    $2 == "total" && $3 ~ /^control\(/ && !($3 in seen) { seen[$3] = 1; c[++n] = $3 }
    END { for (i = 1; i <= n; i++) print c[i] ": " (c[i] in f ? f[c[i]] : "no line - its _checkControl printed none (BacktestBase._fidelity says what one held)")
      if (n == 0) print "none (no control run in the log)" }' "$WORK/bt"
} > "$REPORT"

verdict=0
if ! rows="$(parse_backtest_totals "$REPORT")"; then
  echo "backtest: the report's totals table did not parse (scripts/lib/parse.sh, parse_backtest_totals): refused, not read."
  verdict=1
elif [ "$rc_sum" -ne 0 ] || [ "$passed" = "0" ] || [ "$failed" != "0" ] || [ "$skipped" != "0" ] || [ "$rc_forge" -ne 0 ]; then
  verdict=1
elif [ "$(printf '%s\n' "$rows" | grep -vc '^control(')" -eq 0 ]; then
  echo "backtest: no hook's replay in the report (only the control, or nothing)."
  verdict=1
elif [ "$(printf '%s\n' "$rows" | grep -c '^control(')" -eq 0 ]; then
  echo "backtest: no control in the report: a hook's numbers without the replay's own are not read (doctrine/SIMULATE.md, section 6)."
  verdict=1
fi
if [ "$verdict" -eq 0 ]; then
  echo "backtest: REPORT WRITTEN - $REPORT ($(printf '%s\n' "$rows" | grep -v '^control(' | awk '{ printf "%s%s", (n++ ? ", " : ""), $1 }'); passed $passed)" | tee -a "$REPORT"
  exit 0
fi
first="$(first_error_line "$FORGE_LOG" 2> /dev/null)"
echo "backtest: FAILED - forge rc $rc_forge, passed $passed, failed $failed, skipped $skipped${first:+; $first} (report: $REPORT, log: $FORGE_LOG)" | tee -a "$REPORT"
exit 1
