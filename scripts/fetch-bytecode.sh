#!/usr/bin/env bash
#
# fetch-bytecode.sh - read the runtime code of a deployed contract and write it out as a test fixture.
#
# What it is for: the manager your harness compiles from source is the manager you read about. The manager
# your hook will meet is the one that already exists on your chain, deployed from a commit you did not pick,
# with settings you did not choose. This script goes and gets that one, so the suite can be run against it
# (see foundry-kit/v4/README.md, "Get the manager that actually exists"). It is generic: the same command
# fetches any contract you want to etch into a test.
#
# Usage:   RPC_URL=... scripts/fetch-bytecode.sh [--block <n>] <address> <out.hex>
# Writes:  <out.hex>    0x-prefixed runtime code, one line
#          <out>.json   { address, chainId, block, blockHash, codeSize, codeHash } - the harness reads the address
#                       from here, because code etched at the wrong address is a different contract (immutables,
#                       and any address the code compares itself against)
# Block:   the code is read AT A BLOCK, always, and the block goes in the metadata. `--block <n>` (decimal) picks it;
#          without it the script asks for the latest block number FIRST and then reads the code at that number, so
#          the fixture still names the one block it came from. The harness refuses a fixture whose metadata names no
#          block, and `test/fork/FixtureBlock.t.sol` checks on a fork that the code at that block IS the fixture.
# Exit:    0 wrote both files, 1 anything else.
#
# THE KEY RULE. The endpoint is read from the environment variable RPC_URL and from nowhere else. It is not
# an argument, so it cannot end up in a shell history, a process list, a log or an agent transcript. It is
# never printed, and the error output of the underlying tool is scrubbed of anything that looks like a URL
# before it is shown.
#
# If you are an agent: do NOT ask the owner to paste an endpoint into the chat. Ask them to run
#   export RPC_URL=...
# in their own terminal, or to put it in a git-ignored .env, and then run this script. Stop until it works.
# For `eth_getCode` a public keyless endpoint is fine, and is the better choice.

set -uo pipefail

BLOCK=""
if [ "${1:-}" = "--block" ]; then
  BLOCK="${2:-}"
  # a block NUMBER, in decimal: no tag ("latest" is what the option exists to avoid), no hex, no sign, no leading zero
  case "$BLOCK" in
    ''|0?*|*[!0-9]*) echo "fetch-bytecode: --block takes a block number in decimal (what came after it is not one, and is not repeated here: ${#BLOCK} characters)"; exit 1 ;;
  esac
  shift 2
fi

ADDR="${1:-}"
OUT="${2:-}"

if [ -z "$ADDR" ] || [ -z "$OUT" ] || [ "$#" -gt 2 ]; then
  echo "usage: RPC_URL=... fetch-bytecode.sh [--block <n>] <address> <out.hex>"
  exit 1
fi

# checked FIRST, and the value is never echoed: somebody who pastes the endpoint in the wrong place must not get
# it printed back into a log or a transcript
case "$ADDR" in
  *://*|*http*) echo "fetch-bytecode: that is an endpoint, not an address. The endpoint goes in RPC_URL."; exit 1 ;;
esac

# exactly "0x" and 40 hex digits. The glob that stood here, 0x[0-9a-fA-F][0-9a-fA-F]*, checked the first hex digit
# only (a glob's `*` is any text), so "0x12..zz" of the right length went on to the network (an outside review, 2026-09-23).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || { echo "fetch-bytecode: $HERE/lib/parse.sh is missing"; exit 1; }
if ! is_evm_address "$ADDR"; then
  echo "fetch-bytecode: '$ADDR' is not an 0x address: an address is 0x and exactly 40 hex digits (this is ${#ADDR} characters)"
  exit 1
fi

if [ -z "${RPC_URL:-}" ]; then
  cat <<'EOF'
fetch-bytecode: RPC_URL is not set.

  Set it in YOUR OWN terminal and run this script again:

      export RPC_URL='https://<your endpoint>'
      scripts/fetch-bytecode.sh <address> <out.hex>

  Or put it in a git-ignored .env and source it. Do not pass it on the command line and do not paste it
  into a chat: this script never sees it as an argument and never prints it.
EOF
  exit 1
fi

command -v cast > /dev/null 2>&1 || { echo "fetch-bytecode: cast not found (install Foundry)"; exit 1; }

# Anything of the shape scheme://... is replaced before a single byte of the tool's error output is shown.
# The pattern does not contain the secret, so the scrubbing cannot leak it either.
scrub() {
  sed -e 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]*#<RPC_URL>#g'
}

ERRF="$(mktemp)"
trap 'rm -f "$ERRF"' EXIT

# cast reads ETH_RPC_URL from the environment. Passing --rpc-url would put the endpoint in the process list,
# where any other user of the machine can read it.
export ETH_RPC_URL="$RPC_URL"

CHAIN_ID="$(cast chain-id 2> "$ERRF")"
if [ -z "$CHAIN_ID" ]; then
  echo "fetch-bytecode: the endpoint in RPC_URL did not answer eth_chainId. Scrubbed error:"
  scrub < "$ERRF" | head -5
  exit 1
fi

# the block first: the code is read AT it, whichever way it was chosen
if [ -z "$BLOCK" ]; then
  BLOCK="$(cast block-number 2> "$ERRF")"
  case "$BLOCK" in
    ''|*[!0-9]*) echo "fetch-bytecode: the endpoint did not answer eth_blockNumber. Scrubbed error:"; scrub < "$ERRF" | head -5; exit 1 ;;
  esac
fi
BLOCK_HASH="$(cast block "$BLOCK" --field hash 2> "$ERRF")"
case "$BLOCK_HASH" in
  0x[0-9a-fA-F]*) ;;
  *) echo "fetch-bytecode: chain $CHAIN_ID has no block $BLOCK here (in the future, or pruned). Scrubbed error:"; scrub < "$ERRF" | head -5; exit 1 ;;
esac

CODE="$(cast code --block "$BLOCK" "$ADDR" 2> "$ERRF")"
if [ -z "$CODE" ]; then
  echo "fetch-bytecode: eth_getCode at block $BLOCK returned nothing (an endpoint without archive state?). Scrubbed error:"
  scrub < "$ERRF" | head -5
  exit 1
fi

# An empty answer is the failure this script exists to catch: it means the wrong chain, the wrong address, or
# an endpoint that is behind. Writing a zero-byte fixture and etching it produces a "manager" that accepts
# every call and answers nothing, and a whole suite passes against a contract that is not there.
case "$CODE" in
  0x|0X|"0x0") echo "fetch-bytecode: $ADDR has NO CODE on chain $CHAIN_ID at block $BLOCK. Wrong chain, wrong address, a block before the deployment, or a stale endpoint."; exit 1 ;;
esac

BYTES=$(( (${#CODE} - 2) / 2 ))
if [ "$BYTES" -lt 1 ]; then
  echo "fetch-bytecode: $ADDR has no code on chain $CHAIN_ID"
  exit 1
fi

CODEHASH="$(cast keccak "$CODE" 2> "$ERRF")"
if [ -z "$CODEHASH" ]; then
  echo "fetch-bytecode: could not hash the code. Scrubbed error:"
  scrub < "$ERRF" | head -5
  exit 1
fi

OUTDIR="$(dirname "$OUT")"
mkdir -p "$OUTDIR" || { echo "fetch-bytecode: cannot create $OUTDIR"; exit 1; }
printf '%s\n' "$CODE" > "$OUT" || { echo "fetch-bytecode: cannot write $OUT"; exit 1; }

META="${OUT%.hex}.json"
cat > "$META" <<EOF
{
  "address": "$ADDR",
  "chainId": $CHAIN_ID,
  "block": $BLOCK,
  "blockHash": "$BLOCK_HASH",
  "codeSize": $BYTES,
  "codeHash": "$CODEHASH"
}
EOF

echo "== fetch-bytecode =="
echo "address    $ADDR"
echo "chain id   $CHAIN_ID"
echo "block      $BLOCK  ($BLOCK_HASH)"
echo "code size  $BYTES bytes"
echo "keccak     $CODEHASH"
echo "hex        $OUT"
echo "meta       $META"
echo
echo "Check the chain id against the chain you are actually targeting, and the address against the official"
echo "deployments list - identify the contract BY ADDRESS, never by a name somebody typed. Fixtures are"
echo "git-ignored: they are somebody else's compiled code, and they belong in your bench, not in a commit."
