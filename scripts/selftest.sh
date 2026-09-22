#!/usr/bin/env bash
#
# selftest.sh - prove that the guards fail when they should.
#
# The problem it solves: a guard that has never been seen to go red is not a guard, it is a decoration. Both
# of the checks in this kit are the kind that sit silently green for months, which is exactly the kind that
# rots. Each case below is run twice: once where it must pass, and once where it must fail, with the exit
# code printed either way.
#
# Usage:   scripts/selftest.sh
# Exit:    0 every case behaved as declared; 1 a case did not; 3 INCOMPLETE - a section was skipped (no forge, or no
#          foundry-kit/lib), so the scripts in it are NOT proven on this machine. A skipped section is not a pass.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
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

  LABEL=m4 "$HERE/mutate.sh" "$KIT" "$V" "credited = post - pre;" "credited = post - ;" > "$TMP/o15" 2>&1
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
  # the floor is set low on purpose: this case proves the PLUMBING, and a fuzz draw must not be able to make it flaky
  MATCH="--match-contract ToyVaultInvariants" CORE="deposit withdraw" MIN_PCT=25 "$HERE/census.sh" "$K" > "$TMP/o62" 2>&1
  check "end to end: the kit's own vault campaign writes a census, and its core actions are above the floor" 0 $?
  if grep -Eq '^== campaign census: ToyVault - [0-9]+ runs ==$' "$TMP/o62"; then echo "  ok    one line per run reached the file"; else
    echo "  FAIL  no census table came out of the kit's own campaign"; tail -5 "$TMP/o62" | sed "s/^/        | /"; fails=$((fails + 1)); fi
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
