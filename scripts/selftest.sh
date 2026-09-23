#!/usr/bin/env bash
#
# selftest.sh - prove that every guard that can be exercised offline fails when it should.
#
# The problem it solves: a guard that has never been seen to go red is not a guard, it is a decoration. Both
# of the checks in this kit are the kind that sit silently green for months, which is exactly the kind that
# rots. Each case below is run twice: once where it must pass, and once where it must fail, with the exit
# code printed either way.
#
# What it does NOT exercise, because it needs the network: a SUCCESSFUL fetch-bytecode.sh (an RPC endpoint) and a
# successful install-v4.sh (GitHub). Their refusals are here; their success is the CI's `battery` job, which runs
# install-v4.sh on every push, and the fetch is run by hand (foundry-kit/v4/README.md).
#
# Usage:   scripts/selftest.sh
# Exit:    0 every case behaved as declared; 1 a case did not; 3 INCOMPLETE - a section was skipped (no forge, or no
#          foundry-kit/lib), so the scripts in it are NOT proven on this machine. A skipped section is not a pass.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || { echo "selftest: $HERE/lib/parse.sh is missing"; exit 1; }
FIX="$HERE/test/fixtures"
started=$SECONDS
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
skipped=0
check() { # check <label> <expected-rc> <actual-rc>
  if [ "$2" = "$3" ]; then
    echo "  ok    $1 (rc=$3, expected $2)"
  else
    echo "  FAIL  $1 (rc=$3, expected $2)"
    # the end of what the case printed (its newest output file), so that a failure here can be read without a rerun
    last="$(ls -t "$TMP"/o[0-9]* 2> /dev/null | head -1)"
    [ -n "$last" ] && tail -n 6 "$last" | sed "s/^/          | /"
    fails=$((fails + 1))
  fi
}

if command -v sha256sum > /dev/null 2>&1; then
  hash_of() { sha256sum "$1" | cut -d' ' -f1; }
else
  hash_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

# ================================================================= release-guard.sh
echo "== release-guard.sh =="
W="$TMP/work"; P="$TMP/published"
mkdir -p "$W" "$P"
printf 'contract A {}\n' > "$W/A.sol"
printf 'contract B {}\n' > "$W/B.sol"
cp "$W/A.sol" "$W/B.sol" "$P/"
{ printf '%s  A.sol\n' "$(hash_of "$P/A.sol")"; printf '%s  B.sol\n' "$(hash_of "$P/B.sol")"; } > "$P/MANIFEST.sha256"

"$HERE/release-guard.sh" "$W" "$P" > "$TMP/o1" 2>&1; check "identical trees, complete manifest" 0 $?

printf 'contract A { uint256 x; }\n' > "$W/A.sol"
"$HERE/release-guard.sh" "$W" "$P" > "$TMP/o2" 2>&1; check "only the working tree was edited" 1 $?
cp "$P/A.sol" "$W/A.sol"

printf 'contract C {}\n' > "$W/C.sol"; cp "$W/C.sol" "$P/C.sol"
"$HERE/release-guard.sh" "$W" "$P" > "$TMP/o3" 2>&1; check "a file added to BOTH trees with no hash" 2 $?
rm -f "$W/C.sol" "$P/C.sol"

printf 'contract A { uint256 x; }\n' > "$W/A.sol"; cp "$W/A.sol" "$P/A.sol"
"$HERE/release-guard.sh" "$W" "$P" > "$TMP/o4" 2>&1; check "BOTH trees edited together, stale hash" 3 $?

printf '%s  A.sol\n' "$(hash_of "$P/A.sol")" > "$P/MANIFEST.sha256"
printf '%s  B.sol\n' "$(hash_of "$P/B.sol")" >> "$P/MANIFEST.sha256"
"$HERE/release-guard.sh" "$W" "$P" > "$TMP/o5" 2>&1; check "manifest refreshed on purpose" 0 $?

before="$(hash_of "$P/MANIFEST.sha256")"
"$HERE/release-guard.sh" "$W" "$P" > /dev/null 2>&1
after="$(hash_of "$P/MANIFEST.sha256")"
if [ "$before" = "$after" ]; then echo "  ok    the guard never writes into the published copy"; else
  echo "  FAIL  the guard modified the published copy"; fails=$((fails + 1)); fi

"$HERE/release-guard.sh" "$W" > /dev/null 2>&1; check "missing argument" 4 $?

# ================================================================= assert-fresh-build.sh
# File times are SET, not waited for: `sleep 1` between writes made this section flaky on a loaded machine.
echo "== assert-fresh-build.sh =="
J="$TMP/project"
mkdir -p "$J/src"
T=1700000000
stamp() { T=$((T + 10)); touch -d "@$T" "$@"; }
printf 'contract A {}
' > "$J/src/A.sol"
printf '[profile.default]
' > "$J/foundry.toml"
stamp "$J/src/A.sol" "$J/foundry.toml"

"$HERE/assert-fresh-build.sh" "$J" > "$TMP/o6" 2>&1; check "nothing built yet" 2 $?

mkdir -p "$J/out/A.sol"
printf '{}
' > "$J/out/A.sol/A.json"; stamp "$J/out/A.sol/A.json"
"$HERE/assert-fresh-build.sh" "$J" > "$TMP/o7" 2>&1; check "artifacts newer than sources" 0 $?

printf 'contract A { uint256 x; }
' > "$J/src/A.sol"; stamp "$J/src/A.sol"
"$HERE/assert-fresh-build.sh" "$J" > "$TMP/o8" 2>&1; check "source edited after the build" 1 $?

printf '{}
' > "$J/out/A.sol/A.json"; stamp "$J/out/A.sol/A.json"
"$HERE/assert-fresh-build.sh" "$J" > "$TMP/o9" 2>&1; check "rebuilt" 0 $?

printf 'optimizer = true
' >> "$J/foundry.toml"; stamp "$J/foundry.toml"
"$HERE/assert-fresh-build.sh" "$J" > "$TMP/o10" 2>&1; check "the config counts as a source too" 1 $?

# forge rewrites its cache on every build even when it recompiles nothing, so the cache is the honest marker
mkdir -p "$J/cache"
printf '{}
' > "$J/cache/solidity-files-cache.json"; stamp "$J/cache/solidity-files-cache.json"
"$HERE/assert-fresh-build.sh" "$J" > "$TMP/o11" 2>&1; check "a build that recompiled nothing still counts" 0 $?

# ================================================================= fetch-bytecode.sh (the refusals; no network is used)
echo "== fetch-bytecode.sh =="
( unset RPC_URL ETH_RPC_URL; "$HERE/fetch-bytecode.sh" 0x000000000000000000000000000000000000dEaD "$TMP/x.hex" > "$TMP/o21" 2>&1 )
check "no RPC_URL in the environment: refuses, and says where the endpoint goes" 1 $?
RPC_URL="http://127.0.0.1:9" "$HERE/fetch-bytecode.sh" "https://example.invalid/v2/SECRET" "$TMP/x.hex" > "$TMP/o22" 2>&1
check "an endpoint passed where the address goes is refused" 1 $?
if grep -q "SECRET" "$TMP/o22"; then echo "  FAIL  the refused endpoint was echoed back"; fails=$((fails + 1)); else
  echo "  ok    the refused endpoint is not echoed back"; fi
RPC_URL="http://127.0.0.1:9" "$HERE/fetch-bytecode.sh" 0x1234 "$TMP/x.hex" > "$TMP/o23" 2>&1
check "a short address is refused" 1 $?
if [ -e "$TMP/x.hex" ]; then echo "  FAIL  a fixture was written by a refused call"; fails=$((fails + 1)); else
  echo "  ok    no fixture is written by a refused call"; fi

RPC_URL="http://127.0.0.1:9" "$HERE/fetch-bytecode.sh" "0x12345678901234567890123456789012345678zz" "$TMP/x.hex" > "$TMP/o95" 2>&1
check "an address of the right LENGTH with non-hex digits is refused" 1 $?
if grep -q "not an 0x address" "$TMP/o95"; then echo "  ok    and it is refused as an address, before any endpoint is tried"; else
  echo "  FAIL  the non-hex address got past the address check: $(tail -1 "$TMP/o95")"; fails=$((fails + 1)); fi
if [ -e "$TMP/x.hex" ]; then echo "  FAIL  a fixture was written by a refused call"; fails=$((fails + 1)); fi

# ================================================================= install-v4.sh (the refusals; no network is used)
# git is replaced by a shim that records every call and fails: a refusal must come BEFORE git is touched and before
# anything is created, so the log of git calls must stay empty and the project must stay as it was.
echo "== install-v4.sh =="
IV="$TMP/iv"; mkdir -p "$IV/scripts/lib" "$IV/proj" "$IV/gitshim"
cp "$HERE/install-v4.sh" "$IV/scripts/"; cp "$HERE/lib/parse.sh" "$IV/scripts/lib/"
printf '#!/usr/bin/env bash\necho "git $*" >> "%s/git-calls"\nexit 1\n' "$IV" > "$IV/gitshim/git"; chmod +x "$IV/gitshim/git"
sed -i.bak 's/^V4_CORE_PIN="[0-9a-f]*"/V4_CORE_PIN="main"/' "$IV/scripts/install-v4.sh"
if grep -q '^V4_CORE_PIN="main"' "$IV/scripts/install-v4.sh"; then
  PATH="$IV/gitshim:$PATH" "$IV/scripts/install-v4.sh" "$IV/proj" > "$TMP/o96" 2>&1
  check "a pin that is a branch name, not a commit hash, is refused" 1 $?
  if [ ! -e "$IV/git-calls" ] && [ ! -e "$IV/proj/lib" ] && grep -q "not a full commit hash" "$TMP/o96"; then
    echo "  ok    and it was refused before git was called or lib/ was created"; else
    echo "  FAIL  install-v4.sh went on with a bad pin: $(head -2 "$IV/git-calls" 2> /dev/null)"; fails=$((fails + 1)); fi
else
  echo "  FAIL  could not plant a bad pin in a copy of install-v4.sh (the pin line changed shape?)"; fails=$((fails + 1))
fi
cp "$HERE/install-v4.sh" "$IV/scripts/"; rm -rf "$IV/git-calls" "$IV/proj/lib"
sed -i.bak 's/^V4_CORE_PIN="\([0-9a-f]*\)"/V4_CORE_PIN="\1a"/' "$IV/scripts/install-v4.sh"
PATH="$IV/gitshim:$PATH" "$IV/scripts/install-v4.sh" "$IV/proj" > "$TMP/o97" 2>&1
check "a pin one hex digit too long is refused" 1 $?
if [ ! -e "$IV/git-calls" ]; then echo "  ok    and git was never called for it"; else
  echo "  FAIL  install-v4.sh called git with a 41-digit pin"; fails=$((fails + 1)); fi
cp "$HERE/install-v4.sh" "$IV/scripts/"; rm -rf "$IV/git-calls" "$IV/proj/lib"
PATH="$IV/gitshim:$PATH" "$IV/scripts/install-v4.sh" "$IV/no-such-project" > "$TMP/o98" 2>&1
check "a destination that does not exist is refused" 1 $?
if [ ! -e "$IV/git-calls" ] && [ ! -e "$IV/no-such-project" ]; then echo "  ok    and nothing was created for it, and git was never called"; else
  echo "  FAIL  install-v4.sh created the missing destination or called git"; fails=$((fails + 1)); fi
PATH="$IV/gitshim:$PATH" "$IV/scripts/install-v4.sh" "$IV/proj" > "$TMP/o99" 2>&1
check "control: good pins and a real destination reach git (the shim fails it)" 1 $?
if [ -s "$IV/git-calls" ]; then echo "  ok    and git WAS called: the refusals above are the guards, not a broken copy"; else
  echo "  FAIL  the control never reached git: the refusals above prove nothing"; fails=$((fails + 1)); fi
# the OFFLINE path (V4_LOCAL_SRC): a fake local clone at a commit that is not the pin must be refused before anything is
# copied, and nothing may be fetched. This one needs a real git (to make the clone); the shim is kept out of it.
if command -v git > /dev/null 2>&1; then
  LS="$TMP/localsrc"; mkdir -p "$LS/v4-core"; rm -rf "$IV/proj/lib"
  (cd "$LS/v4-core" && git init -q && printf 'x\n' > f && git add f \
    && git -c user.name=selftest -c user.email=selftest@invalid -c commit.gpgsign=false commit -q -m fake) > /dev/null 2>&1
  # GIT_ALLOW_PROTOCOL=file: whatever the script does, git itself refuses to reach the network from this case
  GIT_ALLOW_PROTOCOL=file V4_LOCAL_SRC="$LS" "$IV/scripts/install-v4.sh" "$IV/proj" > "$TMP/o114" 2>&1
  check "offline install from a local clone at the WRONG pin is refused" 1 $?
  if grep -q "is at $(git -C "$LS/v4-core" rev-parse HEAD), the pin is" "$TMP/o114" && [ ! -e "$IV/proj/lib/v4-core" ]; then
    echo "  ok    and it names both commits, and nothing was copied into the project"; else
    echo "  FAIL  the wrong-pin clone was not refused by name, or it was copied: $(grep install-v4 "$TMP/o114" | head -2)"; fails=$((fails + 1)); fi
  GIT_ALLOW_PROTOCOL=file V4_LOCAL_SRC="$TMP/no-such-dir" "$IV/scripts/install-v4.sh" "$IV/proj" > "$TMP/o115" 2>&1
  check "offline install from a directory with no v4-core clone is refused" 1 $?

  # A GOOD local clone, made here: a fake v4-core with the two submodules (lib/forge-std, lib/solmate) as real gitlinks,
  # and a copy of install-v4.sh whose V4_CORE_PIN is that fake's HEAD. Nothing about Uniswap is needed to test the copy.
  gc() { git -c user.name=selftest -c user.email=selftest@invalid -c commit.gpgsign=false -c advice.addEmbeddedRepo=false "$@"; }
  G="$TMP/goodsrc"; GV="$G/v4-core"; mkdir -p "$GV/src" "$GV/lib/forge-std/src" "$GV/lib/solmate/src"
  printf 'contract PoolManager {}\n' > "$GV/src/PoolManager.sol"
  printf 'contract Test {}\n' > "$GV/lib/forge-std/src/Test.sol"; printf 'contract Owned {}\n' > "$GV/lib/solmate/src/Owned.sol"
  for sm in forge-std solmate; do (cd "$GV/lib/$sm" && git init -q && git add -A && gc commit -q -m "$sm") > /dev/null 2>&1; done
  printf '[submodule "lib/forge-std"]\n\tpath = lib/forge-std\n\turl = https://example.invalid/forge-std\n[submodule "lib/solmate"]\n\tpath = lib/solmate\n\turl = https://example.invalid/solmate\n' > "$GV/.gitmodules"
  (cd "$GV" && git init -q && gc add .gitmodules src lib/forge-std lib/solmate && gc commit -q -m fake-v4-core) > /dev/null 2>&1
  PINNED="$TMP/ivpinned"; mkdir -p "$PINNED/scripts/lib"; cp "$HERE/lib/parse.sh" "$PINNED/scripts/lib/"
  sed "s/^V4_CORE_PIN=\"[0-9a-f]*\"/V4_CORE_PIN=\"$(git -C "$GV" rev-parse HEAD)\"/" "$HERE/install-v4.sh" > "$PINNED/scripts/install-v4.sh"
  chmod +x "$PINNED/scripts/install-v4.sh"
  inst() { GIT_ALLOW_PROTOCOL=file "$PINNED/scripts/install-v4.sh" "$@"; }
  if [ "$(git -C "$GV" ls-tree HEAD lib/solmate | awk '{print $2}')" = "commit" ] && grep -q "^V4_CORE_PIN=\"$(git -C "$GV" rev-parse HEAD)\"" "$PINNED/scripts/install-v4.sh"; then
    mkdir -p "$IV/p1" "$IV/p2" "$IV/p3" "$IV/p4"
    V4_LOCAL_SRC="$G" inst "$IV/p1" > "$TMP/o120" 2>&1; check "control: offline install from a GOOD local clone" 0 $?
    V4_FORCE=1 V4_LOCAL_SRC="$G" inst "$IV/p1" > "$TMP/o121" 2>&1; check "the same, again, with V4_FORCE=1 (it used to fail with a false 'forge-std missing')" 0 $?
    # a clone whose solmate submodule is not checked out: refused, and it must leave nothing behind
    B="$TMP/badsrc"; mkdir -p "$B"; cp -a "$GV" "$B/v4-core"; rm -rf "$B/v4-core/lib/solmate"; mkdir "$B/v4-core/lib/solmate"
    V4_LOCAL_SRC="$B" inst "$IV/p2" > "$TMP/o122" 2>&1; check "offline install from a clone with a submodule missing is refused" 1 $?
    if [ ! -e "$IV/p2/lib" ]; then echo "  ok    and the refusal left no lib/ in a project that had none"; else
      echo "  FAIL  the refused install left a partial lib/: $(cd "$IV/p2" && find lib -maxdepth 2 | head -4 | tr '\n' ' ')"; fails=$((fails + 1)); fi
    V4_LOCAL_SRC="$G" inst "$IV/p2" > "$TMP/o123" 2>&1; check "the next attempt with a GOOD clone, no V4_FORCE, installs (the refusal did not poison it)" 0 $?
    # a refused V4_FORCE over a good install leaves that install as it was
    V4_FORCE=1 V4_LOCAL_SRC="$B" inst "$IV/p1" > "$TMP/o124" 2>&1; check "V4_FORCE=1 from the broken clone over a good install is refused" 1 $?
    if [ -f "$IV/p1/lib/v4-core/lib/solmate/src/Owned.sol" ] && [ -z "$(find "$IV/p1/lib" -maxdepth 1 -name '.install-v4-*')" ]; then
      echo "  ok    and the good install is intact, with no staging directory left behind"; else
      echo "  FAIL  a refused V4_FORCE damaged the install it was refused over"; fails=$((fails + 1)); fi
    # a lib/v4-core that is ALREADY broken (as a refused run of an older install-v4.sh left it): refused without FORCE, and
    # the message says FORCE is the way out; with FORCE it is replaced
    mkdir -p "$IV/p3/lib"; cp -a "$B/v4-core" "$IV/p3/lib/v4-core"
    V4_LOCAL_SRC="$G" inst "$IV/p3" > "$TMP/o125" 2>&1; check "an installed lib/v4-core with a submodule missing is refused without V4_FORCE" 1 $?
    if grep -q "V4_FORCE=1" "$TMP/o125"; then echo "  ok    and the refusal names V4_FORCE=1 as the way out"; else
      echo "  FAIL  the refusal does not say how to recover"; fails=$((fails + 1)); fi
    V4_FORCE=1 V4_LOCAL_SRC="$G" inst "$IV/p3" > "$TMP/o126" 2>&1; check "V4_FORCE=1 with a good clone recovers it" 0 $?
    [ -f "$IV/p3/lib/v4-core/lib/solmate/src/Owned.sol" ] || { echo "  FAIL  V4_FORCE said OK but solmate is not there"; fails=$((fails + 1)); }
    # untracked files in the clone: an untracked .sol under src/ (of the clone or of a submodule) is refused; anything
    # else untracked is copied, as the header says
    U="$TMP/untrsrc"; mkdir -p "$U"; cp -a "$GV" "$U/v4-core"; printf 'contract Extra {}\n' > "$U/v4-core/src/Extra.sol"
    V4_LOCAL_SRC="$U" inst "$IV/p4" > "$TMP/o127" 2>&1; check "a clone with an UNTRACKED .sol under src/ is refused" 1 $?
    if grep -q "src/Extra.sol" "$TMP/o127" && [ ! -e "$IV/p4/lib" ]; then echo "  ok    and it names the file, and nothing was copied"; else
      echo "  FAIL  the untracked .sol was not named, or something was copied"; fails=$((fails + 1)); fi
    V4_ALLOW_UNTRACKED=1 V4_LOCAL_SRC="$U" inst "$IV/p4" > "$TMP/o128" 2>&1; check "the same clone with V4_ALLOW_UNTRACKED=1" 0 $?
    if [ -f "$IV/p4/lib/v4-core/src/Extra.sol" ] && grep -q "src/Extra.sol" "$TMP/o128"; then echo "  ok    and the file was copied AND listed"; else
      echo "  FAIL  V4_ALLOW_UNTRACKED=1 did not copy and list the file"; fails=$((fails + 1)); fi
    rm -f "$U/v4-core/src/Extra.sol"; printf 'contract Evil {}\n' > "$U/v4-core/lib/forge-std/src/Evil.sol"; rm -rf "$IV/p4/lib"
    V4_LOCAL_SRC="$U" inst "$IV/p4" > "$TMP/o129" 2>&1; check "an untracked .sol under a SUBMODULE's src/ is refused too" 1 $?
    if grep -q "lib/forge-std/src/Evil.sol" "$TMP/o129"; then echo "  ok    and it is refused BY NAME (not as some other local change)"; else
      echo "  FAIL  the submodule's untracked .sol was not named"; fails=$((fails + 1)); fi
    rm -f "$U/v4-core/lib/forge-std/src/Evil.sol"; printf 'contract Test { uint256 x; }\n' > "$U/v4-core/lib/forge-std/src/Test.sol"
    V4_LOCAL_SRC="$U" inst "$IV/p4" > "$TMP/o134" 2>&1; check "a changed TRACKED file in a submodule is still a local change, refused" 1 $?
    grep -q "LOCAL CHANGES" "$TMP/o134" || { echo "  FAIL  the changed submodule file was not refused as a local change"; fails=$((fails + 1)); }
    (cd "$U/v4-core/lib/forge-std" && git checkout -q -- src/Test.sol)
    # a submodule holding only untracked files is treated like the clone itself: a .txt in it is copied, not refused
    printf 'notes\n' > "$U/v4-core/src/NOTES.txt"; printf 'notes\n' > "$U/v4-core/lib/forge-std/NOTES.txt"
    V4_LOCAL_SRC="$U" inst "$IV/p4" > "$TMP/o130" 2>&1; check "an untracked file that is not a .sol is copied (the documented limit)" 0 $?
  else
    echo "  FAIL  could not build the fake good clone, or plant its pin (git or the pin line changed shape?)"; fails=$((fails + 1))
  fi
else
  echo "  SKIPPED - no git here: the offline install refusals are NOT proven on this machine"; skipped=1
fi

# ================================================================= parse.sh, on fixtures (real forge 1.8.1 output + near misses)
# scripts/test/fixtures: `*-real-*` captured from forge 1.8.1 on the kit's own projects (2026-09-23); `*-nm-*` near
# misses written by hand - the shapes an inline `grep | sed` misread in silence. A CRLF copy is made here, not stored:
# .gitattributes normalises line ends, and a stored CRLF fixture would silently become an LF one.
echo "== parse.sh =="
expect_out() { # expect_out <label> <expected stdout> <expected rc> <command...>
  local label="$1" want="$2" want_rc="$3" got rc; shift 3
  got="$("$@" 2> /dev/null)"; rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = "$want_rc" ]; then echo "  ok    $label (rc=$rc)"; else
    echo "  FAIL  $label: got \"$got\" rc=$rc, expected \"$want\" rc=$want_rc"; fails=$((fails + 1)); fi
}
first_row() { parse_sizes "$1" | grep "^$2 "; }
count_kept() { sim_ledger_filter "$1" | wc -l | tr -d ' '; }
expect_out "summary, real, 6 suites" "103 0 0 103" 0 parse_test_summary "$FIX/summary-real-many-suites.txt"
expect_out "summary, real, 1 suite ('test suite', singular)" "1 0 0 1" 0 parse_test_summary "$FIX/summary-real-one-suite.txt"
expect_out "summary, real, a failure and a skip" "1 1 1 3" 0 parse_test_summary "$FIX/summary-real-failed-and-skipped.txt"
sed 's/$/\r/' "$FIX/summary-real-one-suite.txt" > "$TMP/summary-crlf.txt"
expect_out "summary, the same with CRLF line ends" "1 0 0 1" 0 parse_test_summary "$TMP/summary-crlf.txt"
expect_out "summary, real, no test matched: there is none" "" 1 parse_test_summary "$FIX/summary-real-no-tests.txt"
expect_out "summary printed only by a test's console: there is none" "" 1 parse_test_summary "$FIX/summary-nm-console-only.txt"
expect_out "summary with no 'skipped' field: refused" "" 2 parse_test_summary "$FIX/summary-nm-no-skipped-field.txt"
expect_out "summary whose numbers do not add up: refused" "" 2 parse_test_summary "$FIX/summary-nm-total-mismatch.txt"
expect_out "campaigns, real, grouped (one line for 6 invariants)" "1 4096 4096" 0 parse_invariant_runs "$FIX/summary-real-many-suites.txt"
expect_out "campaigns, real, two, one printing a fake campaign line in its logs" "2 32 16" 0 parse_invariant_runs "$FIX/invariant-real-pass-with-logs.txt"
expect_out "campaigns, real, a failing one (forge prints it twice)" "1 1 1" 0 parse_invariant_runs "$FIX/invariant-real-fail.txt"
expect_out "campaign lines only inside a test's logs: none ran" "0 0 0" 0 parse_invariant_runs "$FIX/invariant-nm-console-only.txt"
expect_out "suites by directory, real" "test=4 test/examples=2" 0 parse_suites_by_dir "$FIX/summary-real-many-suites.txt"
expect_out "sizes, real: ToyVault's runtime" "ToyVault 1672" 0 first_row "$FIX/sizes-real.txt" ToyVault
expect_out "sizes, columns in another order: still the RUNTIME column" "ToyVault 1672" 0 first_row "$FIX/sizes-nm-columns-swapped.txt" ToyVault
expect_out "sizes, no header: refused" "" 2 parse_sizes "$FIX/sizes-nm-no-header.txt"
expect_out "sizes, the runtime column renamed: refused" "" 2 parse_sizes "$FIX/sizes-nm-renamed-header.txt"
expect_out "ledger: the 2 well-formed lines are kept" "2" 0 count_kept "$FIX/sim-nm-nonnumeric.tsv"
expect_out "ledger: '12a', '-' and an empty field make 3 malformed lines" "3" 0 sim_ledger_malformed "$FIX/sim-nm-nonnumeric.tsv"
expect_out "address: 0x and 40 hex digits" "" 0 is_evm_address 0x000000000000000000000000000000000000dEaD
expect_out "address: 39 hex digits and a z" "" 1 is_evm_address 0x000000000000000000000000000000000000dEaz
expect_out "address: 41 hex digits" "" 1 is_evm_address 0x000000000000000000000000000000000000dEaD0
expect_out "pin: a full lower-case sha" "" 0 is_git_sha 59d3ecf53afa9264a16bba0e38f4c5d2231f80bc
expect_out "pin: a short sha" "" 1 is_git_sha 59d3ecf
expect_out "pin: upper case (not what git prints)" "" 1 is_git_sha 59D3ECF53AFA9264A16BBA0E38F4C5D2231F80BC
first_row_both() { parse_sizes_both "$1" | grep "^$2 "; }
expect_out "sizes, both columns, real: ToyVault's runtime AND initcode" "ToyVault 1672 1811" 0 first_row_both "$FIX/sizes-real.txt" ToyVault
expect_out "sizes, both columns, in another order: still read by header" "ToyVault 1672 1811" 0 first_row_both "$FIX/sizes-nm-columns-swapped.txt" ToyVault
expect_out "sizes, a table without the Initcode column: refused (never initcode 0)" "" 2 parse_sizes_both "$FIX/sizes-nm-no-initcode.txt"
first_err_is() { first_error_line "$1" | cut -c1-60; }
expect_out "first error, real (v4 module copied without its parent): the unresolved import, not the warnings" \
  'Error (6275): Source "../src/HostileERC20.sol" not found: Fi' 0 first_err_is "$FIX/build-real-v4-without-copy-root.txt"
expect_out "first error, when the log ENDS in warnings" 'Error (6275): Source "../src/InvariantBase.sol" not found: F' 0 \
  first_err_is "$FIX/build-nm-error-then-warnings.txt"
expect_out "first error, in a log with none: refused" "" 1 first_error_line "$FIX/summary-real-one-suite.txt"

# ---- the scripts that read those shapes, fed them through a forge SHIM (no compiler runs): the parser is only half of
# the guard, the other half is the script acting on its refusal
FS="$TMP/fshim"; FP="$TMP/fproj"; mkdir -p "$FS" "$FP/src" "$FP/out/A.sol" "$FP/cache"
printf 'contract A {}\n' > "$FP/src/A.sol"; printf '[profile.default]\n' > "$FP/foundry.toml"
printf '{}\n' > "$FP/out/A.sol/A.json"; printf '{}\n' > "$FP/cache/solidity-files-cache.json"
touch -d "@1700000000" "$FP/src/A.sol" "$FP/foundry.toml"; touch -d "@1700000100" "$FP/out/A.sol/A.json" "$FP/cache/solidity-files-cache.json"
# the shim answers `forge build --sizes` with $SHIM_SIZES and `forge test` with $SHIM_TEST, and any other build with success
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" --sizes "*) cat "$SHIM_SIZES" ;;\n  " test "*) cat "$SHIM_TEST" ;;\n  *) echo "Compiler run successful!" ;;\nesac\nexit 0\n' > "$FS/forge"; chmod +x "$FS/forge"
export SHIM_SIZES="$FIX/sizes-real.txt" SHIM_TEST="$FIX/summary-real-one-suite.txt"
PATH="$FS:$PATH" OUT_DIR="$TMP/fb" "$HERE/battery.sh" "$FP" > "$TMP/o100" 2>&1; check "battery through the shim on a real green summary (the control)" 0 $?
SHIM_TEST="$FIX/summary-nm-console-only.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fb" "$HERE/battery.sh" "$FP" > "$TMP/o101" 2>&1
check "battery: a summary printed only by a test's console is NO summary" 1 $?
SHIM_TEST="$FIX/summary-nm-no-skipped-field.txt" ALLOW_SKIPS=1 PATH="$FS:$PATH" OUT_DIR="$TMP/fb" "$HERE/battery.sh" "$FP" > "$TMP/o102" 2>&1
check "battery: a summary of another shape is refused, even with ALLOW_SKIPS=1" 1 $?
SHIM_SIZES="$FIX/sizes-nm-columns-swapped.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o103" 2>&1
check "size.sh on a table with its columns in another order" 0 $?
if grep -Eq '^ToyVault +1672 +22904' "$TMP/o103"; then echo "  ok    and it read the RUNTIME column by its header (1672, not the initcode 1811)"; else
  echo "  FAIL  size.sh read the wrong column: $(grep ToyVault "$TMP/o103")"; fails=$((fails + 1)); fi
SHIM_SIZES="$FIX/sizes-real.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o110" 2>&1
check "size.sh on the real table" 0 $?
if grep -Eq '^ToyVault +1672 +22904 +1811 +47341 ' "$TMP/o110"; then echo "  ok    and it reports the INITCODE and its margin to 49 152 next to the runtime (1811, 47341)"; else
  echo "  FAIL  size.sh does not report the initcode size and margin: $(grep ToyVault "$TMP/o110")"; fails=$((fails + 1)); fi
SHIM_SIZES="$FIX/sizes-real.txt" MIN_INIT_MARGIN=48000 PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o111" 2>&1
check "size.sh: an initcode margin below MIN_INIT_MARGIN fails" 1 $?
SHIM_SIZES="$FIX/sizes-nm-no-initcode.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o112" 2>&1
check "size.sh on a table with no Initcode column measures nothing (the phase-2 gate needs both)" 2 $?
SHIM_SIZES="$FIX/sizes-nm-renamed-header.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o104" 2>&1
check "size.sh on a table whose runtime column is not called Runtime Size measures nothing" 2 $?
SHIM_SIZES="$FIX/sizes-nm-no-header.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o105" 2>&1
check "size.sh on a table with no header measures nothing" 2 $?
unset SHIM_SIZES SHIM_TEST
# mutate.sh's baseline build fails; the shim prints a log whose END is warnings. The cause must be on the screen.
FS2="$TMP/fshim2"; mkdir -p "$FS2"
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" build "*) cat "%s"; exit 1 ;;\nesac\necho "Compiler run successful!"; exit 0\n' "$FIX/build-nm-error-then-warnings.txt" > "$FS2/forge"; chmod +x "$FS2/forge"
printf 'contract A { uint256 x; }\n' > "$FP/src/A.sol"
PATH="$FS2:$PATH" LABEL=m17 OUT_DIR="$TMP/mut0" "$HERE/mutate.sh" "$FP" src/A.sol "uint256 x;" "uint256 y;" > "$TMP/o113" 2>&1
check "mutate.sh on a copy that does not build: nothing proven" 2 $?
if grep -q 'first error: Error (6275): Source "../src/InvariantBase.sol" not found' "$TMP/o113"; then
  echo "  ok    and it names the FIRST error, though the log ends in warnings"; else
  echo "  FAIL  mutate.sh did not show the error that stopped the build:"; sed "s/^/        | /" "$TMP/o113" | head -8; fails=$((fails + 1)); fi
"$HERE/sim-report.sh" "$FIX/sim-nm-nonnumeric.tsv" > "$TMP/o106" 2>&1; check "sim-report over a ledger with three malformed lines" 0 $?
if grep -Eq '^nm +honest +2 +40\.0 +39\.0 +1\.0 ' "$TMP/o106" && grep -q "3 line(s) ignored (malformed" "$TMP/o106"; then
  echo "  ok    and the malformed lines are counted out loud, not added up as numbers"; else
  echo "  FAIL  sim-report added up a field that is not a number:"; sed "s/^/        | /" "$TMP/o106"; fails=$((fails + 1)); fi
printf 'x\ty\t1\t2\n' > "$TMP/allbad.tsv"; "$HERE/sim-report.sh" "$TMP/allbad.tsv" > "$TMP/o107" 2>&1
check "sim-report over a ledger with no well-formed line measured nothing" 2 $?

# ================================================================= bench.sh refreshes (no forge needed)
echo "== bench.sh (refresh, dependency directories) =="
BP="$TMP/bproj"; mkdir -p "$BP/src" "$BP/fixtures" "$BP/lib/dep" "$BP/v4/src" "$BP/v4/lib/dep2" "$BP/scripts/lib"
printf '[profile.default]\n' > "$BP/foundry.toml"; printf '[profile.default]\n' > "$BP/v4/foundry.toml"
printf 'contract S {}\n' > "$BP/src/S.sol"; printf 'contract V {}\n' > "$BP/v4/src/V.sol"
printf 'contract D {}\n' > "$BP/lib/dep/D.sol"; printf 'contract D2 {}\n' > "$BP/v4/lib/dep2/D2.sol"
printf 'echo parse\n' > "$BP/scripts/lib/parse.sh"; printf '# fixtures\n' > "$BP/fixtures/README.md"
BENCH_ROOT="$TMP/bb2" "$HERE/bench.sh" two "$BP" > "$TMP/o116" 2>&1; check "a bench of a project with a nested foundry project" 0 $?
if [ -L "$TMP/bb2/two/lib" ] && [ -L "$TMP/bb2/two/v4/lib" ] && [ "$(readlink "$TMP/bb2/two/v4/lib")" = "$BP/v4/lib" ] \
  && [ -f "$TMP/bb2/two/scripts/lib/parse.sh" ] && [ ! -L "$TMP/bb2/two/scripts/lib" ]; then
  echo "  ok    lib/ and v4/lib/ are LINKED, and scripts/lib/ (source, not a dependency) is copied"; else
  echo "  FAIL  LINK_LIB: root lib $(readlink "$TMP/bb2/two/lib" 2> /dev/null || echo none), v4/lib $(readlink "$TMP/bb2/two/v4/lib" 2> /dev/null || echo none), scripts/lib/parse.sh $([ -f "$TMP/bb2/two/scripts/lib/parse.sh" ] && echo present || echo MISSING)"; fails=$((fails + 1)); fi
# the v4 README's flow: a bench that keeps what was fetched INTO it. The project has no fixtures/*.hex and no v4/lib of
# its own here, so the bench's are its own; a refresh must keep both, and the bench itself must never be deleted.
rm -rf "$BP/v4/lib"
BENCH_ROOT="$TMP/bb2" BENCH_EXCLUDE="*.hex *.json" "$HERE/bench.sh" keep "$BP" > "$TMP/o117" 2>&1; check "a bench that excludes the fetched fixtures" 0 $?
printf '0x6080\n' > "$TMP/bb2/keep/fixtures/PROBE.hex"; printf '{}\n' > "$TMP/bb2/keep/fixtures/PROBE.json"
mkdir -p "$TMP/bb2/keep/v4/lib/v4-core"; printf 'installed into the bench\n' > "$TMP/bb2/keep/v4/lib/v4-core/INSTALLED"
printf 'contract S { uint256 x; }\n' > "$BP/src/S.sol"
BENCH_ROOT="$TMP/bb2" BENCH_EXCLUDE="*.hex *.json" "$HERE/bench.sh" keep "$BP" > "$TMP/o118" 2>&1; check "the same bench, refreshed" 0 $?
if [ -f "$TMP/bb2/keep/fixtures/PROBE.hex" ] && [ -f "$TMP/bb2/keep/fixtures/PROBE.json" ] && [ -f "$TMP/bb2/keep/v4/lib/v4-core/INSTALLED" ] \
  && grep -q "uint256 x" "$TMP/bb2/keep/src/S.sol"; then
  echo "  ok    the fetched fixtures and the bench's own v4/lib survived the refresh, and the source was refreshed"; else
  echo "  FAIL  the refresh deleted what it was asked to keep: PROBE.hex $([ -f "$TMP/bb2/keep/fixtures/PROBE.hex" ] && echo kept || echo GONE), v4/lib $([ -f "$TMP/bb2/keep/v4/lib/v4-core/INSTALLED" ] && echo kept || echo GONE)"; fails=$((fails + 1)); fi
# ... and a path the PROJECT has that matches the exclude is still withheld: a stale copy of it is removed, by name
printf '0xdead\n' > "$BP/fixtures/Project.hex"; printf '0xdead\n' > "$TMP/bb2/keep/fixtures/Project.hex"
BENCH_ROOT="$TMP/bb2" BENCH_EXCLUDE="*.hex *.json" "$HERE/bench.sh" keep "$BP" > "$TMP/o119" 2>&1; check "a refresh over a stale copy of a withheld file" 0 $?
if [ ! -e "$TMP/bb2/keep/fixtures/Project.hex" ] && [ -f "$TMP/bb2/keep/fixtures/PROBE.hex" ]; then
  echo "  ok    the project's own .hex is withheld (the stale copy is gone), the bench's own PROBE.hex is kept"; else
  echo "  FAIL  withheld and kept are mixed up: Project.hex $([ -e "$TMP/bb2/keep/fixtures/Project.hex" ] && echo PRESENT || echo gone)"; fails=$((fails + 1)); fi
rm -f "$BP/fixtures/Project.hex"
# an exclude that names a DIRECTORY the project also has: the whole directory is withheld, so a file only the bench has
# inside it goes too on the next refresh. That is documented, and it is announced on every run, by name.
BENCH_ROOT="$TMP/bb2" BENCH_EXCLUDE="fixtures" "$HERE/bench.sh" wdir "$BP" > "$TMP/o131" 2>&1; check "a bench that excludes a directory the project has" 0 $?
if grep -Eq '^bench: WARNING .*: fixtures$' "$TMP/o131"; then echo "  ok    and it warns, in one line, naming the directory"; else
  echo "  FAIL  no one-line warning naming the withheld directory:"; grep -i warn "$TMP/o131" | sed "s/^/        | /"; fails=$((fails + 1)); fi
mkdir -p "$TMP/bb2/wdir/fixtures"; printf '0x6080\n' > "$TMP/bb2/wdir/fixtures/BENCHONLY.hex"
BENCH_ROOT="$TMP/bb2" BENCH_EXCLUDE="fixtures" "$HERE/bench.sh" wdir "$BP" > "$TMP/o132" 2>&1; check "the same bench, refreshed" 0 $?
if [ ! -e "$TMP/bb2/wdir/fixtures" ]; then echo "  ok    and the bench-only file inside it went with the directory, as the warning says"; else
  echo "  FAIL  the behaviour the warning describes did not happen (the header is now wrong)"; fails=$((fails + 1)); fi
if grep -q "WARNING" "$TMP/o117"; then echo "  FAIL  an exclude of file patterns only (*.hex *.json) warned about a directory"; fails=$((fails + 1)); else
  echo "  ok    an exclude of file patterns only does not warn"; fi

# ================================================================= mutate.sh and size.sh (need forge and a project)
echo "== mutate.sh / size.sh =="
KIT="${KIT_PROJECT:-$HERE/../foundry-kit}"
if command -v forge > /dev/null 2>&1 && [ -e "$KIT/lib" ]; then
  export OUT_DIR="$TMP/mut"
  V="src/examples/ToyVault.sol"

  LABEL=m1 "$HERE/mutate.sh" "$KIT" "$V" "credited = post - pre;" "credited = amount;" > "$TMP/o12" 2>&1
  check "a mutant that credits the requested amount is KILLED" 0 $?

  LABEL=m2 "$HERE/mutate.sh" "$KIT" "$V" "the sum of every credit." "the SUM of every credit." > "$TMP/o13" 2>&1
  check "a change in a comment SURVIVES, and is reported as surviving" 1 $?

  LABEL=m3 "$HERE/mutate.sh" "$KIT" "$V" "nonReentrant" "nonReentrantX" > "$TMP/o14" 2>&1
  check "a string that matches more than once proves nothing" 2 $?

  LABEL="m4" "$HERE/mutate.sh" "$KIT" "$V" "credited = post - pre;" "credited = post - ;" > "$TMP/o15" 2>&1   # quoted: shellcheck reads a bare m4 as the m4 command (SC2209)
  check "a mutant that does not compile proves nothing" 2 $?

  LABEL=m5 EXPECT=green "$HERE/mutate.sh" "$KIT" "$V" "the sum of every credit." "the SUM of every credit." > "$TMP/o16" 2>&1
  check "a harmless variant PASSES under EXPECT=green" 0 $?
  if grep -q '^ToyVault ' "$TMP/mut/m5-sizes.txt" 2> /dev/null; then echo "  ok    the variant's sizes were measured"; else
    echo "  FAIL  the variant's sizes were not measured"; fails=$((fails + 1)); fi

  LABEL=m6 EXPECT=green "$HERE/mutate.sh" "$KIT" "$V" "credited = post - pre;" "credited = amount;" > "$TMP/o17" 2>&1
  check "a broken variant FAILS under EXPECT=green" 1 $?

  if grep -q "credited = post - pre;" "$KIT/$V"; then echo "  ok    the original was never touched"; else
    echo "  FAIL  the original was modified"; fails=$((fails + 1)); fi

  OUT_DIR="$TMP/sz" LABEL=base "$HERE/size.sh" "$KIT" ToyVault > "$TMP/o18" 2>&1; check "size of one named contract" 0 $?
  OUT_DIR="$TMP/sz" LABEL=tight MIN_MARGIN=24576 "$HERE/size.sh" "$KIT" ToyVault > "$TMP/o19" 2>&1
  check "a margin below MIN_MARGIN fails" 1 $?
  OUT_DIR="$TMP/sz" LABEL=ghost "$HERE/size.sh" "$KIT" NoSuchContract > "$TMP/o20" 2>&1
  check "a contract that does not exist measures nothing" 2 $?
  unset OUT_DIR

  LABEL=m7 OUT_DIR="$TMP/mut" TEST_FLAGS="--match-contrct Typo" "$HERE/mutate.sh" "$KIT" "$V" "the sum of every credit." "the SUM of every credit." > "$TMP/o24" 2>&1
  check "a bad TEST_FLAGS makes the BASELINE red: nothing proven, never KILLED" 2 $?
  LABEL=m8 OUT_DIR="$TMP/mut" EXPECT=green TEST_FLAGS="--match-contract NoSuchContractAnywhere" "$HERE/mutate.sh" "$KIT" "$V" "credited = post - pre;" "credited = amount;" > "$TMP/o25" 2>&1
  check "a filter that matches nothing proves nothing about a broken variant" 2 $?

  # ================================================================= battery.sh, fuzz-long.sh, bench.sh
  echo "== battery.sh / fuzz-long.sh / bench.sh =="
  M="$TMP/mini"; mkdir -p "$M/src" "$M/test"; ln -s "$(cd "$KIT/lib" && pwd -P)" "$M/lib"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n[invariant]\nruns = 4\ndepth = 4\nfail_on_revert = true\n[profile.long.invariant]\nruns = 8\ndepth = 8\nfail_on_revert = true\n' > "$M/foundry.toml"
  printf 'pragma solidity ^0.8.26;\ncontract A { uint256 public x; function inc() external { x++; } }\n' > "$M/src/A.sol"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/A.sol";\ncontract AUnit is Test { function test_inc() public { A a = new A(); a.inc(); assertEq(a.x(), 1); } }\ncontract AInvariant is Test { A a; function setUp() public { a = new A(); targetContract(address(a)); } function invariant_never_decreases() public view { assertGe(a.x(), 0); } }\n' > "$M/test/A.t.sol"

  # ---- a mutant that bricks setUp() prints `[FAIL: ...] setUp()` and NO test ran. mutate.sh must say NOTHING PROVEN and
  # never KILLED: the test file below makes setUp depend on inc(), and the mutant turns inc() into an underflow.
  printf 'pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../src/A.sol";
contract SetUpDep is Test { A a; function setUp() public { a = new A(); a.inc(); require(a.x() == 1, "setUp depends on inc"); } function test_x() public { assertEq(a.x(), 1); } }
' > "$M/test/SetUpDep.t.sol"
  LABEL=m9s OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$M" "src/A.sol" "x++;" "x--;" > "$TMP/o35" 2>&1
  check "a mutant that bricks setUp() proves nothing, and is never KILLED" 2 $?
  if grep -q "setUp()" "$TMP/o35"; then echo "  ok    the refusal names setUp()"; else echo "  FAIL  the refusal does not name setUp()"; fails=$((fails + 1)); fi
  rm -f "$M/test/SetUpDep.t.sol"

  # ---- a FILE reached through a symlinked lib/ is the ORIGINAL, not the copy's: mutate.sh must refuse it, and the
  # original must be byte-for-byte what it was. (`cp -a` keeps the link; the mutation used to be written through it.)
  SH="$TMP/shared"; SL="$TMP/symlib"; mkdir -p "$SH" "$SL/src" "$SL/test"
  ln -s "$(cd "$KIT/lib/forge-std" && pwd -P)" "$SH/forge-std"
  printf 'pragma solidity ^0.8.26;\ncontract X { uint256 public x; function inc() external { x++; } }\n' > "$SH/X.sol"
  ln -s "$SH" "$SL/lib"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n' > "$SL/foundry.toml"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../lib/X.sol";\ncontract XUnit is Test { function test_inc() public { X a = new X(); a.inc(); assertEq(a.x(), 1); } }\n' > "$SL/test/X.t.sol"
  sh_before="$(hash_of "$SH/X.sol")"
  LABEL=m16 OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$SL" lib/X.sol "x++;" "x += 2;" > "$TMP/o94" 2>&1
  check "a FILE whose real path leaves the copy (symlinked lib/) is refused: nothing proven" 2 $?
  if [ "$(hash_of "$SH/X.sol")" = "$sh_before" ] && [ ! -e "$SH/X.sol.mutated" ]; then echo "  ok    and the original behind the link is unchanged (sha256 before = after)"; else
    echo "  FAIL  mutate.sh WROTE THROUGH the symlink into the original"; fails=$((fails + 1)); fi
  if grep -q "NOTHING PROVEN" "$TMP/o94" && grep -qF "$(cd -P "$SH" && pwd -P)/X.sol" "$TMP/o94"; then echo "  ok    and the refusal names the resolved path"; else
    echo "  FAIL  the refusal does not name the resolved path"; fails=$((fails + 1)); fi

  "$HERE/battery.sh" "$M" > "$TMP/o26" 2>&1; check "battery on a small green project" 0 $?
  TEST_FLAGS="--match-contract NoSuchContractAnywhere" "$HERE/battery.sh" "$M" > "$TMP/o27" 2>&1
  check "battery with a filter that matches NOTHING is not a pass" 1 $?
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\ncontract Skipper is Test { function test_skipped() public { vm.skip(true); } }\n' > "$M/test/Skip.t.sol"
  "$HERE/battery.sh" "$M" > "$TMP/o28" 2>&1; check "battery with a SKIPPED test is not a pass" 1 $?
  ALLOW_SKIPS=1 "$HERE/battery.sh" "$M" > "$TMP/o29" 2>&1; check "unless the skip is accepted on purpose" 0 $?
  rm -f "$M/test/Skip.t.sol"

  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o30" 2>&1; check "long fuzz on a project that has the profile and a campaign" 0 $?
  USE_BENCH=0 FOUNDRY_PROFILE=nosuchprofile "$HERE/fuzz-long.sh" "$M" > "$TMP/o31" 2>&1
  check "a profile that does not exist proves nothing" 2 $?
  USE_BENCH=0 MATCH="--match-contract NoSuchContractAnywhere" "$HERE/fuzz-long.sh" "$M" > "$TMP/o32" 2>&1
  check "a long fuzz in which no campaign ran proves nothing" 2 $?
  # forge FAILS and no campaign ran: a build error is not a counterexample
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../nowhere/Missing.sol";\ncontract Broken is Test { function test_b() public {} }\n' > "$M/test/Broken.t.sol"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o120" 2>&1
  check "a long fuzz whose build fails proves nothing (never a counterexample)" 2 $?
  if grep -q "NOTHING PROVEN" "$TMP/o120" && grep -q 'first error: .*nowhere/Missing.sol' "$TMP/o120" && ! grep -q "counterexample and the seed" "$TMP/o120"; then
    echo "  ok    and it names the compile error, and says nothing about a counterexample"; else
    echo "  FAIL  fuzz-long.sh reported a build failure as something else:"; grep -E "fuzz-long|LONG FUZZ|first error" "$TMP/o120" | head -4 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -f "$M/test/Broken.t.sol"
  # USE_BENCH=1 on a project that imports from its PARENT (the v4 module's shape): the bench must hold the parent
  TL="$TMP/twolevel"; mkdir -p "$TL/src" "$TL/child/src" "$TL/child/test"
  ln -s "$(cd "$KIT/lib" && pwd -P)" "$TL/lib"; ln -s "$(cd "$KIT/lib" && pwd -P)" "$TL/child/lib"
  printf '[profile.default]\n' > "$TL/foundry.toml"
  printf 'pragma solidity ^0.8.26;\ncontract Base { uint256 public x; function inc() external { x++; } }\n' > "$TL/src/Base.sol"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\nallow_paths = ["../src"]\nremappings = ["parent/=../src/"]\n[invariant]\nruns = 4\ndepth = 4\nfail_on_revert = true\n[profile.long.invariant]\nruns = 8\ndepth = 8\nfail_on_revert = true\n' > "$TL/child/foundry.toml"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "parent/Base.sol";\ncontract ChildInvariant is Test { Base b; function setUp() public { b = new Base(); targetContract(address(b)); } function invariant_x() public view { assertGe(b.x(), 0); } }\n' > "$TL/child/test/C.t.sol"
  BENCH_ROOT="$TMP/fzb" "$HERE/fuzz-long.sh" "$TL/child" > "$TMP/o121" 2>&1
  check "USE_BENCH=1 on a project that imports from its parent: the bench holds the parent, and the campaign runs" 0 $?
  if grep -q "the bench is of $TL" "$TMP/o121"; then echo "  ok    and it says which directory it benched"; else
    echo "  FAIL  fuzz-long.sh did not bench the parent: $(grep -E 'fuzz-long|in /' "$TMP/o121" | head -2)"; fails=$((fails + 1)); fi
  mkdir -p "$TMP/deep/a/b/c"; printf '[profile.default]\nallow_paths = ["../../../x"]\n' > "$TMP/deep/a/b/c/foundry.toml"
  BENCH_ROOT="$TMP/fzb" "$HERE/fuzz-long.sh" "$TMP/deep/a/b/c" > "$TMP/o122" 2>&1
  check "USE_BENCH=1 on a project that reaches three levels up is refused, in one line" 2 $?
  if [ "$(grep -c "refused" "$TMP/o122")" = "1" ] && [ -z "$(find "$TMP/fzb" -maxdepth 1 -name 'fuzz-long-c-*' -print -quit 2> /dev/null)" ]; then
    echo "  ok    and no bench was made for it"; else echo "  FAIL  the deep project was benched, or refused unclearly"; fails=$((fails + 1)); fi

  BENCH_ROOT="$TMP/benches" "$HERE/bench.sh" bb "$M" > "$TMP/o33" 2>&1; check "an ordinary bench" 0 $?
  BENCH_ROOT="$TMP/benches" BENCH_EXCLUDE="src" "$HERE/bench.sh" bb "$M" > "$TMP/o34" 2>&1
  check "a black-box bench over a bench of the same name" 0 $?
  if [ ! -e "$TMP/benches/bb/src" ] && [ -z "$(find "$TMP/benches/bb" -type l -print -quit)" ]; then
    echo "  ok    the withheld directory is really gone, and nothing in the bench links out of it"
  else
    echo "  FAIL  the black-box bench still holds src/ or a symlink"; fails=$((fails + 1))
  fi

  # ---- bench.sh must never delete what it was asked to copy. Each case counts the project's files afterwards.
  WS="$TMP/ws"; mkdir -p "$WS/myhook/src" "$WS/myhook/script"
  printf 'contract H {}\n' > "$WS/myhook/src/H.sol"; printf '// deploy\n' > "$WS/myhook/script/D.sol"; printf '[profile.default]\n' > "$WS/myhook/foundry.toml"
  BENCH_ROOT="$WS" BENCH_EXCLUDE="script" "$HERE/bench.sh" myhook "$WS/myhook" > "$TMP/o40" 2>&1
  check "a bench that IS the project is refused" 1 $?
  BENCH_ROOT="$WS/myhook/benches" BENCH_EXCLUDE="script" "$HERE/bench.sh" inner "$WS/myhook" > "$TMP/o41" 2>&1
  check "a bench INSIDE the project is refused" 1 $?
  mkdir -p "$WS/outer/proj/src"; printf 'contract P {}\n' > "$WS/outer/proj/src/P.sol"
  BENCH_ROOT="$WS" BENCH_EXCLUDE="script" "$HERE/bench.sh" outer "$WS/outer/proj" > "$TMP/o42" 2>&1
  check "a bench that CONTAINS the project is refused" 1 $?
  BENCH_ROOT="$WS/benches" "$HERE/bench.sh" . "$WS/myhook" > "$TMP/o43" 2>&1; check "'.' is not a bench name" 1 $?
  BENCH_ROOT="$WS/benches" "$HERE/bench.sh" .. "$WS/myhook" > "$TMP/o44" 2>&1; check "'..' is not a bench name" 1 $?
  # the same refusals by the routes a path can be DISGUISED: a `..` after a component that does not exist yet (the guard
  # used to compare it as text, then mkdir made it real, and src/ was overwritten), a RELATIVE root that does not exist
  # yet (it lost a slash and compared "<cwd>benches"), a root reached through a symlink, and a bench NAME that is
  # itself a link to the project.
  BENCH_ROOT="$WS/ghost/../myhook" BENCH_EXCLUDE="script" "$HERE/bench.sh" src "$WS/myhook" > "$TMP/o70" 2>&1
  check "a BENCH_ROOT with '..' in it is refused" 1 $?
  (cd "$WS/myhook" && BENCH_ROOT="benchesrel" BENCH_EXCLUDE="script" "$HERE/bench.sh" c3 . > "$TMP/o71" 2>&1)
  check "a RELATIVE bench root inside the project is refused the FIRST time too" 1 $?
  ln -s "$WS/myhook" "$WS/alias"
  BENCH_ROOT="$WS/alias/benches2" BENCH_EXCLUDE="script" "$HERE/bench.sh" viaLink "$WS/myhook" > "$TMP/o72" 2>&1
  check "a bench root that reaches the project through a symlink is refused" 1 $?
  mkdir -p "$WS/benches"; ln -s "$WS/myhook" "$WS/benches/namelink"
  BENCH_ROOT="$WS/benches" BENCH_EXCLUDE="script" "$HERE/bench.sh" namelink "$WS/myhook" > "$TMP/o73" 2>&1
  check "a bench NAME that is a link to the project is refused" 1 $?
  rm -f "$WS/alias" "$WS/benches/namelink"
  if [ -f "$WS/myhook/src/H.sol" ] && [ -f "$WS/myhook/script/D.sol" ] && [ -f "$WS/outer/proj/src/P.sol" ] \
    && [ "$(find "$WS/myhook" -type f | wc -l | tr -d ' ')" = "3" ] && [ ! -e "$WS/myhook/benchesrel/c3" ] && [ ! -e "$WS/myhook/benches2/viaLink" ]; then
    echo "  ok    and every project is still on disk, with nothing added to it, after the nine refusals"
  else
    echo "  FAIL  bench.sh DELETED project files, or built a bench inside the project"; fails=$((fails + 1))
  fi

  # ---- a link under lib/ that leads back into the project would carry the withheld source into the black-box bench
  mkdir -p "$WS/mono/src" "$WS/mono/lib/real"; printf 'contract Secret {}\n' > "$WS/mono/src/Secret.sol"
  printf '[profile.default]\n' > "$WS/mono/foundry.toml"; ln -s ../src "$WS/mono/lib/core"
  BENCH_ROOT="$WS/benches" BENCH_EXCLUDE="src" "$HERE/bench.sh" mono "$WS/mono" > "$TMP/o45" 2>&1
  check "a black-box bench whose lib/ links back into the project is refused" 1 $?
  if [ -z "$(find "$WS/benches" -name Secret.sol -print -quit 2> /dev/null)" ]; then echo "  ok    and the withheld file is nowhere in the benches"; else
    echo "  FAIL  the withheld file reached a bench through lib/"; fails=$((fails + 1)); fi

  # ... and the FINAL verification has to be seen refusing too: a link anywhere else in the project survives the copy
  mkdir -p "$WS/linky/src" "$WS/elsewhere"; printf 'contract L {}\n' > "$WS/linky/src/L.sol"
  printf '[profile.default]\n' > "$WS/linky/foundry.toml"; ln -s "$WS/elsewhere" "$WS/linky/shortcut"
  BENCH_ROOT="$WS/benches" BENCH_EXCLUDE="src" "$HERE/bench.sh" linky "$WS/linky" > "$TMP/o39" 2>&1
  check "a black-box bench that still holds a symlink is not handed over" 1 $?

  # ---- mutate.sh: the two halves of "KILLED means a test went red BECAUSE of the mutant", each seen red alone
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\ncontract AlwaysRed is Test { function test_red() public pure { assertEq(uint256(1), 2); } }\n' > "$M/test/Red.t.sol"
  # the change is harmless AND compiles (A.sol is one line: a trailing `//` comment would swallow the rest of it, the
  # mutant would not build, and this case would answer 2 for that reason instead - it did, and a sabotage run caught it)
  LABEL=m9 OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$M" src/A.sol "uint256 public x;" "uint256 public x; uint256 public y;" > "$TMP/o46" 2>&1
  check "a baseline with a red test: nothing proven, never KILLED" 2 $?
  if grep -q "UNCHANGED code does not pass" "$TMP/o46"; then echo "  ok    and it is the BASELINE that was refused, not the mutant"; else
    echo "  FAIL  the case answered 2 for some other reason: $(tail -1 "$TMP/o46")"; fails=$((fails + 1)); fi
  LABEL=m10 OUT_DIR="$TMP/mut" EXPECT=green BASELINE_MAY_BE_RED=1 \
    "$HERE/mutate.sh" "$M" test/Red.t.sol "assertEq(uint256(1), 2);" "assertEq(uint256(2), 2);" > "$TMP/o47" 2>&1
  check "regression test first: a red baseline is accepted on request, and the fix must be all green" 0 $?
  LABEL=m11 OUT_DIR="$TMP/mut" EXPECT=green BASELINE_MAY_BE_RED=1 \
    "$HERE/mutate.sh" "$M" test/Red.t.sol "assertEq(uint256(1), 2);" "assertEq(uint256(1), 3);" > "$TMP/o48" 2>&1
  check "and a 'fix' that leaves it red FAILS" 1 $?
  # the exception has TWO conditions, and each has to be seen refusing alone: without the variable a red baseline proves
  # nothing under EXPECT=green, and WITH it a mutant (EXPECT=red) over a red baseline must never come out KILLED
  LABEL=m14 OUT_DIR="$TMP/mut" EXPECT=green \
    "$HERE/mutate.sh" "$M" test/Red.t.sol "assertEq(uint256(1), 2);" "assertEq(uint256(2), 2);" > "$TMP/o74" 2>&1
  check "EXPECT=green over a red baseline WITHOUT the variable proves nothing" 2 $?
  LABEL=m15 OUT_DIR="$TMP/mut" BASELINE_MAY_BE_RED=1 \
    "$HERE/mutate.sh" "$M" src/A.sol "x++;" "x += 2;" > "$TMP/o75" 2>&1
  check "BASELINE_MAY_BE_RED does not apply to a mutant: red baseline, nothing proven, never KILLED" 2 $?
  rm -f "$M/test/Red.t.sol"

  LABEL=m12 OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$M" src/A.sol "x++;" "x += 2;" > "$TMP/o49" 2>&1
  check "a real mutant on the small project is KILLED" 0 $?
  if grep -q "KILLED - 1 test(s) went red" "$TMP/o49"; then echo "  ok    and ONE failing test is counted as one (forge prints it twice)"; else
    echo "  FAIL  the number of failing tests is wrong: $(grep KILLED "$TMP/o49" | head -1)"; fails=$((fails + 1)); fi

  # a forge that dies on the MUTANT without any test failing (a crash, not a verdict). The shim lets the two baseline
  # commands and the mutant's build through, and kills the second `forge test`.
  SHIM="$TMP/shim"; mkdir -p "$SHIM"; REAL_FORGE="$(command -v forge)"
  printf '#!/usr/bin/env bash\nif [ "$1" = "test" ]; then n=$(cat "%s/n" 2> /dev/null || echo 0); n=$((n + 1)); echo "$n" > "%s/n"; if [ "$n" -ge 2 ]; then echo "forge: simulated crash"; exit 1; fi; fi\nexec "%s" "$@"\n' "$SHIM" "$SHIM" "$REAL_FORGE" > "$SHIM/forge"
  chmod +x "$SHIM/forge"
  PATH="$SHIM:$PATH" LABEL=m13 OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$M" src/A.sol "x++;" "x += 2;" > "$TMP/o50" 2>&1
  check "forge failing on the mutant with NO failing test is not a kill" 2 $?

  # ---- fuzz-long.sh: the pre-check must fire BEFORE the campaign, a 'long' profile needs a long budget, a skip is not a pass
  # by ITS OWN message: the budget check further down also stops a missing profile (it falls back to the default
  # budget), so "exit 2 before the campaign" alone does not show that this check is alive
  if grep -q "does not exist in this project's foundry.toml" "$TMP/o31" && ! grep -q "Ran [0-9]* test" "$TMP/o31"; then
    echo "  ok    the missing profile was caught BEFORE any campaign ran"
  else
    echo "  FAIL  the missing profile was only noticed after the campaign had run"; fails=$((fails + 1))
  fi
  cp "$M/foundry.toml" "$TMP/toml.keep"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n[invariant]\nruns = 4\ndepth = 4\nfail_on_revert = true\n[profile.long.fuzz]\nruns = 500\n' > "$M/foundry.toml"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o51" 2>&1
  check "a 'long' profile with no invariant budget of its own proves nothing" 2 $?
  cp "$TMP/toml.keep" "$M/foundry.toml"
  USE_BENCH=0 RUNS=1 DEPTH=1 "$HERE/fuzz-long.sh" "$M" > "$TMP/o52" 2>&1
  check "RUNS and DEPTH cannot shrink the long fuzz below the everyday budget" 2 $?
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\ncontract SkippedInvariant is Test { function setUp() public { vm.skip(true); } function invariant_never_runs() public pure { assertTrue(true); } }\n' > "$M/test/SkipInv.t.sol"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o53" 2>&1
  check "a campaign that SKIPPED itself next to one that ran is not a pass" 2 $?
  rm -f "$M/test/SkipInv.t.sol"
  # the budget that was READ is not the budget that RAN when a test carries its own inline configuration
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/A.sol";\ncontract InlineInvariant is Test { A a; function setUp() public { a = new A(); targetContract(address(a)); }\n/// forge-config: long.invariant.runs = 1\n/// forge-config: long.invariant.depth = 1\nfunction invariant_inline() public view { assertGe(a.x(), 0); } }\n' > "$M/test/Inline.t.sol"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o76" 2>&1
  check "a campaign that RAN less than the long budget (inline config) is not a long fuzz" 2 $?
  rm -f "$M/test/Inline.t.sol"
  V4_MANAGER=source USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o77" 2>&1; check "long fuzz with V4_MANAGER set" 0 $?
  if [ -d "$M/corpus/invariant-source" ]; then echo "  ok    and forge really wrote the corpus into the manager's own directory"; else
    echo "  FAIL  fuzz-long.sh: V4_MANAGER did not move the corpus"; fails=$((fails + 1)); fi
  # cases share $M: leave no fuzz state behind for the next one to inherit
  rm -rf "$M/corpus" "$M/cache/invariant" "$M/census"

  # ---- battery.sh: one corpus per manager
  V4_MANAGER=fixture "$HERE/battery.sh" "$M" > "$TMP/o54" 2>&1; check "battery with V4_MANAGER set" 0 $?
  # the EFFECT, not the echo: the directory forge wrote to. (The first version of this case read the script's own
  # message, and a sabotage that kept the message and dropped the `export` left it green.)
  if [ -d "$M/corpus/invariant-fixture" ]; then echo "  ok    and forge really wrote the corpus into the manager's own directory"; else
    echo "  FAIL  V4_MANAGER did not select a corpus of its own"; fails=$((fails + 1)); fi
  V4_MANAGER=third "$HERE/census.sh" "$M" > "$TMP/o78" 2>&1
  if [ -d "$M/corpus/invariant-third" ]; then echo "  ok    census.sh keeps one corpus per manager too"; else
    echo "  FAIL  census.sh ran the campaigns on the shared corpus"; fails=$((fails + 1)); fi
  rm -rf "$M/corpus" "$M/cache/invariant" "$M/census"

  # ---- sim-report.sh: the arithmetic on a ledger written by hand
  SR="$TMP/sim.tsv"
  printf 'cal	honest	40	40	0	100	98	98	0	0	0	7000	-2
' > "$SR"
  printf 'cal	honest	40	38	2	100	96	99	4	3	1	9000	-6
' >> "$SR"
  printf 'cal	broken line with five fields	1	2	3
' >> "$SR"
  "$HERE/sim-report.sh" "$SR" > "$TMP/o90" 2>&1; check "sim-report over two runs and a broken line" 0 $?
  # 13-field lines are from a ledger that did not price gas: 0 priced runs, and "-" for gasCost and net, never 0
  if grep -Eq '^cal +honest +2 +40\.0 +39\.0 +1\.0 +2 +0 +3 +8000 +-4 +0 +- +- +0 +-$' "$TMP/o90" && grep -q "1 line(s) ignored" "$TMP/o90"; then
    echo "  ok    and the means, the worst-ever and the ignored line are right"
  else
    echo "  FAIL  sim-report arithmetic is wrong:"; sed "s/^/        | /" "$TMP/o90"; fails=$((fails + 1))
  fi
  # 15-field lines carry gasCost and pnlNet: their means are over the priced runs, and a group that mixes priced and
  # unpriced lines is named, because there pnl/run - net/run is not gasCost/run
  SG="$TMP/simgas.tsv"
  printf 'gas\thonest\t40\t40\t0\t100\t98\t98\t0\t0\t0\t7000\t-2\t10\t-12\n' > "$SG"
  printf 'gas\thonest\t40\t38\t2\t100\t96\t99\t4\t3\t1\t9000\t-6\t30\t-36\n' >> "$SG"
  printf 'mix\thonest\t40\t40\t0\t100\t98\t98\t0\t0\t0\t7000\t-2\t10\t-12\n' >> "$SG"
  printf 'mix\thonest\t40\t38\t2\t100\t96\t99\t4\t3\t1\t9000\t-6\n' >> "$SG"
  "$HERE/sim-report.sh" "$SG" > "$TMP/o92" 2>&1; check "sim-report over priced and mixed runs" 0 $?
  if grep -Eq '^gas +honest +2 +40\.0 +39\.0 +1\.0 +2 +0 +3 +8000 +-4 +2 +20 +-24 +0 +-$' "$TMP/o92" \
    && grep -Eq '^mix +honest +2 +40\.0 +39\.0 +1\.0 +2 +0 +3 +8000 +-4 +1 +10 +-12 +0 +-$' "$TMP/o92" \
    && grep -q "mix honest: pnl/run is over 2 runs, gasCost/run and net/run over 1" "$TMP/o92" \
    && ! grep -q "gas honest: pnl/run is over" "$TMP/o92"; then
    echo "  ok    and the gas cost, the net P&L, the priced count and the mixed-group note are right"
  else
    echo "  FAIL  sim-report gas arithmetic is wrong:"; sed "s/^/        | /" "$TMP/o92"; fails=$((fails + 1))
  fi
  # 16-field lines carry atQuote: swaps the engine never sent because their own quote was 0. Its mean is over the lines
  # that carry it (never over the older ones, which would dilute it), and a group mixing the two is named
  SQ="$TMP/simatq.tsv"
  printf 'atq\tarb\t40\t30\t2\t100\t96\t99\t4\t3\t1\t9000\t-6\t30\t-36\t8\n' > "$SQ"
  printf 'atq\tarb\t40\t30\t2\t100\t96\t99\t4\t3\t1\t9000\t-6\t30\t-36\t4\n' >> "$SQ"
  printf 'atqmix\tarb\t40\t30\t2\t100\t96\t99\t4\t3\t1\t9000\t-6\t30\t-36\t8\n' >> "$SQ"
  printf 'atqmix\tarb\t40\t30\t2\t100\t96\t99\t4\t3\t1\t9000\t-6\t30\t-36\n' >> "$SQ"
  "$HERE/sim-report.sh" "$SQ" > "$TMP/o93" 2>&1; check "sim-report over runs with and without refusals at quote" 0 $?
  if grep -Eq '^atq +arb +2 +40\.0 +30\.0 +2\.0 +4 +1 +3 +9000 +-6 +2 +30 +-36 +2 +6\.0$' "$TMP/o93" && grep -Eq '^atqmix +arb +2 +40\.0 +30\.0 +2\.0 +4 +1 +3 +9000 +-6 +2 +30 +-36 +1 +8\.0$' "$TMP/o93" && grep -q "atqmix arb: atQuote/run is over 1 runs of 2" "$TMP/o93" && grep -q "1 line(s) from a ledger without the atQuote column" "$TMP/o93" && ! grep -q "atq arb: atQuote/run is over" "$TMP/o93"; then
    echo "  ok    and the refused-at-quote mean, its run count and the mixed-group note are right"
  else
    echo "  FAIL  sim-report refused-at-quote arithmetic is wrong:"; sed "s/^/        | /" "$TMP/o93"; fails=$((fails + 1))
  fi
  : > "$TMP/empty.tsv"; "$HERE/sim-report.sh" "$TMP/empty.tsv" > "$TMP/o91" 2>&1; check "an empty ledger measured nothing" 2 $?

  # ---- census.sh: the arithmetic on a file written by hand, then end to end on the kit's own example
  C="$TMP/census.tsv"
  printf 'Toy\tU=0\tA:deposit=5/4\tA:withdraw=3/0\tB:whole credit=1\n' > "$C"
  printf 'Toy\tU=0\tA:deposit=6/6\tA:withdraw=2/1\n' >> "$C"
  printf 'Toy\tU=0\tA:deposit=1/0\tA:set=x=1/1\tB:whole credit=2\n' >> "$C"
  "$HERE/census.sh" --aggregate "$C" > "$TMP/o55" 2>&1; check "census of three hand-written runs" 0 $?
  if grep -Eq '^withdraw +5 +1 +1 +2$' "$TMP/o55" && grep -Eq '^deposit +12 +10 +2 +1$' "$TMP/o55" \
    && grep -Eq '^whole credit +2 +3$' "$TMP/o55" && grep -Eq '^set=x +1 +1 +1 +2$' "$TMP/o55"; then
    echo "  ok    and the sums are right (an action missing from a run counts as zero successes in it)"
  else
    echo "  FAIL  the census arithmetic is wrong:"; sed "s/^/        | /" "$TMP/o55"; fails=$((fails + 1))
  fi
  CORE="withdraw" MIN_PCT=50 "$HERE/census.sh" --aggregate "$C" > "$TMP/o56" 2>&1; check "a CORE action that worked in 1 run of 3 is below a floor of 50" 1 $?
  CORE="deposit" MIN_PCT=50 "$HERE/census.sh" --aggregate "$C" > "$TMP/o57" 2>&1; check "a CORE action that worked in 2 runs of 3 is above it" 0 $?
  CORE="withdraw" "$HERE/census.sh" --aggregate "$C" > "$TMP/o57b" 2>&1; check "and the default floor (25) lets 1 run of 3 through" 0 $?
  CORE="nosuchaction" "$HERE/census.sh" --aggregate "$C" > "$TMP/o58" 2>&1; check "a CORE action that never ran at all" 1 $?
  printf 'Toy\tU=2\tA:deposit=1/1\n' >> "$C"
  "$HERE/census.sh" --aggregate "$C" > "$TMP/o59" 2>&1; check "a run with an unexplained revert fails the census" 1 $?
  : > "$TMP/empty.tsv"; "$HERE/census.sh" --aggregate "$TMP/empty.tsv" > "$TMP/o60" 2>&1; check "an empty census measured nothing" 2 $?

  # CORE is judged PER SUITE: an action that is dead in one suite must not be rescued by a namesake in another
  C2="$TMP/census2.tsv"
  printf 'Vault\tU=0\tA:deposit=2/2\tB:whole credit=1\nVault\tU=0\tA:deposit=3/3\n' > "$C2"
  printf 'Hook\tU=0\tA:deposit=4/0\nHook\tU=0\tA:deposit=1/0\nHook\tU=0\tA:deposit=2/0\n' >> "$C2"
  CORE="deposit" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o79" 2>&1; check "a CORE action dead in ONE suite fails, whatever its namesake did" 1 $?
  CORE="deposit" MIN_PCT=lots "$HERE/census.sh" --aggregate "$C2" > "$TMP/o80" 2>&1; check "a floor that is not a number is refused" 2 $?
  CORE="deposit" MIN_PCT=0 "$HERE/census.sh" --aggregate "$C2" > "$TMP/o81" 2>&1; check "a floor of zero is refused: it would pass an action that never worked" 2 $?
  REACH="whole credit" MIN_PCT=50 "$HERE/census.sh" --aggregate "$C2" > "$TMP/o82" 2>&1; check "a REACH boundary met in 1 run of 2 is at a floor of 50" 0 $?
  REACH="whole credit" MIN_PCT=51 "$HERE/census.sh" --aggregate "$C2" > "$TMP/o83" 2>&1; check "and below a floor of 51" 1 $?
  REACH="the cap" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o84" 2>&1; check "a REACH boundary that is in no suite at all" 1 $?
  printf 'Vault\tU=0\tA:broken\tfield=3/1\tA:deposit=1/1\n' >> "$C2"
  "$HERE/census.sh" --aggregate "$C2" > "$TMP/o85" 2>&1
  if grep -q "2 field(s) ignored" "$TMP/o85"; then echo "  ok    a field the census cannot read is counted out loud, not dropped"; else
    echo "  FAIL  malformed census fields were ignored in silence"; fails=$((fails + 1)); fi
  "$HERE/census.sh" "$M" > "$TMP/o61" 2>&1; check "a suite that never calls writeCensus measured nothing" 2 $?

  K="$TMP/kitcopy"; mkdir -p "$K"; cp -R "$KIT/src" "$KIT/test" "$KIT/foundry.toml" "$K/"; ln -s "$(cd "$KIT/lib" && pwd -P)" "$K/lib"
  # a census file left over from an EARLIER campaign, with a surprise in it: the script has to start from an empty file
  mkdir -p "$K/census"; printf 'ToyVault\tU=5\tA:deposit=1/1\n' > "$K/census/runs.tsv"; cp "$K/census/runs.tsv" "$K/census/long.tsv"
  # This case proves the PLUMBING, not the vault, so a fuzz draw must not be able to fail it: the seed is pinned, and the
  # floor sits far below the measured range (withdraw succeeded in 35 % of runs on 2026-09-23 with forge 1.8.1; a floor
  # of 25 failed on the CI runner by luck - the very gate census.sh's own header warns against). On failure the table is
  # pasted, so the next red is readable without the file.
  MATCH="--match-contract ToyVaultInvariants" CORE="deposit withdraw" MIN_PCT=10 FOUNDRY_FUZZ_SEED=0x6b6974 "$HERE/census.sh" "$K" > "$TMP/o62" 2>&1; rc62=$?
  check "end to end: the kit's own vault campaign writes a census, and its core actions are above the floor" 0 $rc62
  if [ "$rc62" -ne 0 ]; then grep -E "^==|^deposit|^withdraw|floor|FAILED|measured" "$TMP/o62" | head -12 | sed "s/^/        | /"; fi
  if grep -Eq '^== campaign census: ToyVault - [0-9]+ runs ==$' "$TMP/o62"; then echo "  ok    one line per run reached the file"; else
    echo "  FAIL  no census table came out of the kit's own campaign"; tail -5 "$TMP/o62" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # ... and a SECOND draw, with a different pinned seed, over the same floor: one seed that clears the floor could be the
  # lucky one; two different draws that both clear it are the guard against that. The two tables must differ, or the
  # seed was not what chose the draw.
  MATCH="--match-contract ToyVaultInvariants" CORE="deposit withdraw" MIN_PCT=10 FOUNDRY_FUZZ_SEED=0x4b33 "$HERE/census.sh" "$K" > "$TMP/o133" 2>&1; rc133=$?
  check "end to end, a second draw (another pinned seed): the core actions are above the floor too" 0 $rc133
  if [ "$rc133" -ne 0 ]; then grep -E "^==|^deposit|^withdraw|floor|FAILED|measured" "$TMP/o133" | head -12 | sed "s/^/        | /"; fi
  w62="$(grep -E '^withdraw ' "$TMP/o62")"; w133="$(grep -E '^withdraw ' "$TMP/o133")"
  echo "          withdraw, seed 0x6b6974: ${w62:-none}"; echo "          withdraw, seed 0x4b33  : ${w133:-none}"
  if [ -n "$w62" ] && [ -n "$w133" ] && ! cmp -s <(grep -E '^(deposit|withdraw) ' "$TMP/o62") <(grep -E '^(deposit|withdraw) ' "$TMP/o133"); then
    echo "  ok    and the two draws are different draws (their tables differ)"; else
    echo "  FAIL  the two seeds gave the same table, or no table: the second run is not a second draw"; fails=$((fails + 1)); fi
  # the long fuzz starts from an empty census too (65 x 64 is just above the everyday 64 x 64, so it counts as "long")
  USE_BENCH=0 RUNS=65 DEPTH=64 MATCH="--match-contract ToyVaultInvariants" "$HERE/fuzz-long.sh" "$K" > "$TMP/o86" 2>&1
  check "long fuzz on the kit's vault, over a stale census file" 0 $?
  if grep -q "UNEXPLAINED revert: 0" "$TMP/o86"; then echo "  ok    and the stale line did not reach its table"; else
    echo "  FAIL  fuzz-long.sh added an old campaign's lines to the new one"; fails=$((fails + 1)); fi
  # a campaign that is RED next to one that wrote a census: the census must not turn the failure into a pass
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\ncontract T87 { uint256 public n; function poke() external { n++; } }\ncontract RedOnPurposeInvariants is Test { T87 t; function setUp() public { t = new T87(); targetContract(address(t)); }\nfunction invariant_red_on_purpose() public view { assertEq(t.n(), type(uint256).max, "red on purpose"); } }\n' > "$K/test/RedOnPurpose.t.sol"
  MATCH="--match-contract (ToyVaultInvariants|RedOnPurposeInvariants)" MIN_PCT=25 "$HERE/census.sh" "$K" > "$TMP/o87" 2>&1; rc87=$?
  if [ "$rc87" -ne 0 ] && [ "$rc87" -ne 2 ] && grep -q "campaign itself FAILED" "$TMP/o87"; then echo "  ok    a red campaign fails census.sh even when the census table is clean (rc=$rc87)"; else
    echo "  FAIL  census.sh answered $rc87 over a red campaign"; fails=$((fails + 1)); fi
else
  echo "  SKIPPED - forge, or $KIT/lib, is not available here. mutate.sh, size.sh, battery.sh, fuzz-long.sh and the"
  echo "            black-box mode of bench.sh are NOT proven on this machine."
  skipped=1
fi

echo
echo "selftest ran in $((SECONDS - started)) s"
if [ "$fails" -eq 0 ] && [ "$skipped" -eq 1 ]; then
  echo "SELFTEST INCOMPLETE: what ran behaved, but a section was SKIPPED. Install forge and the kit's lib/, and run it again."
  exit 3
fi
if [ "$fails" -eq 0 ]; then
  echo "SELFTEST PASSED: every guard went red exactly where it was supposed to."
  exit 0
fi
echo "SELFTEST FAILED: $fails case(s) did not behave as declared."
exit 1
