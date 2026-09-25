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
check() { # check <label> <expected-rc> <actual-rc> [<the case's own output file>]
  if [ "$2" = "$3" ]; then
    echo "  ok    $1 (rc=$3, expected $2)"
  else
    echo "  FAIL  $1 (rc=$3, expected $2)"
    # the end of what THIS case printed, so that a failure can be read without a rerun. Every case that writes an output
    # file names it as the fourth argument: the newest o* file by mtime is only a fallback for a case that names none,
    # because it is often ANOTHER case's file (2026-09-23: a red "battery on a small green project" pasted the tail of the
    # symlink case, and the diagnosis started from the wrong log).
    if [ -n "${4:-}" ]; then
      if [ -f "$4" ]; then echo "          | tail of $(basename "$4"):"; tail -n 6 "$4" | sed "s/^/          | /"
      else echo "          | (this case's output file $(basename "$4") does not exist)"; fi
    else
      last="$(ls -t "$TMP"/o[0-9]* 2> /dev/null | head -1)"
      [ -n "$last" ] && { echo "          | no output file named; the NEWEST one, $(basename "$last"), which may be another case's:"; tail -n 6 "$last" | sed "s/^/          | /"; }
    fi
    fails=$((fails + 1))
  fi
}

if command -v sha256sum > /dev/null 2>&1; then
  hash_of() { sha256sum "$1" | cut -d' ' -f1; }
else
  hash_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

# ================================================================= the scripts themselves: bash -n, shellcheck
# CI's `shellcheck` job runs, from the checkout's root, exactly (a comment that STARTS with the tool's name is read by it
# as a directive, hence the "$"):
#   $ shellcheck --external-sources --source-path=SCRIPTDIR --severity=warning scripts/*.sh scripts/lib/*.sh
# and a finding at severity warning or error fails that job (style and info notes are not gated). The same command runs
# here, from the same directory, so a local selftest refuses what CI would refuse. With no shellcheck on this machine it
# is NOT run and the run says so; that is not counted as INCOMPLETE (it proves no guard, and CI runs it on every push).
echo "== the scripts themselves: bash -n, shellcheck =="
lint_scripts() { # lint_scripts <a scripts/ directory>: 0 clean, 1 a syntax error or a shellcheck finding
  local d f bad=0 files=()
  d="$(basename "$1")"
  for f in "$1"/*.sh "$1"/lib/*.sh; do [ -f "$f" ] && files+=("$d/${f#"$1"/}"); done
  [ "${#files[@]}" -gt 0 ] || { echo "no script under $1"; return 1; }
  for f in "${files[@]}"; do (cd "$1/.." && bash -n "$f") || { echo "bash -n: $f"; bad=1; }; done
  if command -v shellcheck > /dev/null 2>&1; then
    (cd "$1/.." && shellcheck --external-sources --source-path=SCRIPTDIR --severity=warning "${files[@]}") || bad=1
  fi
  return "$bad"
}
lint_scripts "$HERE" > "$TMP/o198" 2>&1; check "bash -n and shellcheck (CI's command) over scripts/*.sh and scripts/lib/*.sh" 0 $? "$TMP/o198"
LB="$TMP/lintbad/scripts"; mkdir -p "$LB/lib"
printf '#!/usr/bin/env bash\necho ok\n' > "$LB/lib/ok.sh"
printf '#!/usr/bin/env bash\nif then\n' > "$LB/bad.sh"
lint_scripts "$LB" > "$TMP/o199" 2>&1; check "a script with a syntax error is refused (bash -n)" 1 $? "$TMP/o199"
if command -v shellcheck > /dev/null 2>&1; then
  # SC2164 (cd without a fallback) is a WARNING: bash -n passes it, CI's shellcheck job fails on it
  printf '#!/usr/bin/env bash\ncd "$1"\necho "in $PWD"\n' > "$LB/bad.sh"
  lint_scripts "$LB" > "$TMP/o200" 2>&1; check "a script with a shellcheck warning is refused, as CI's job refuses it" 1 $? "$TMP/o200"
  if grep -q 'SC2164' "$TMP/o200"; then echo "  ok    and the refusal names the finding (SC2164)"; else
    echo "  FAIL  the refusal does not name SC2164"; fails=$((fails + 1)); fi
else
  echo "  --    shellcheck is not installed here: NOT run on this machine (CI's shellcheck job runs it on every push)"
fi

# ================================================================= doctor.sh (it checks; it never installs, never uses the network)
# doctor.sh runs here on a FAKE machine: a kit tree of its own (forge-std's package.json, and a v4-core that is a real git
# checkout whose HEAD is planted as the pin in a copy of install-v4.sh, as the install-v4 cases below do), an empty HOME,
# and a PATH of stubs - forge and cast that print the version a case names, a uname that says which system this is, and
# every installer and network tool (curl, wget, foundryup, apt-get, brew, pip, pipx, sudo, wsl...) as a stub that only
# writes its name to a log. That log must stay empty: a doctor that installs or fetches is seen doing it.
echo "== doctor.sh =="
DR="$TMP/doctor"; DK="$DR/kit"; DB="$DR/base"; DH="$DR/home"
mkdir -p "$DK/scripts/lib" "$DK/foundry-kit/lib/forge-std" "$DK/foundry-kit/v4/lib/v4-core/src" "$DK/foundry-kit/v4/lib/v4-core/lib/forge-std/src" \
  "$DK/foundry-kit/v4/lib/v4-core/lib/solmate/src" "$DB" "$DH"
cp "$HERE/doctor.sh" "$DK/scripts/" 2> /dev/null
cp "$HERE/lib/parse.sh" "$DK/scripts/lib/"
printf '{\n  "name": "forge-std",\n  "version": "1.16.2",\n  "license": "(Apache-2.0 OR MIT)"\n}\n' > "$DK/foundry-kit/lib/forge-std/package.json"
dstub() { mkdir -p "$1"; printf '#!/bin/sh\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }   # dstub <dir> <name> <body>
for t in env bash sed grep head tail tr cat dirname basename cut awk; do p="$(command -v "$t")" && ln -s "$p" "$DB/$t"; done
for t in curl wget foundryup apt apt-get brew pip pip3 pipx sudo wsl winget choco npm; do
  dstub "$DR/trap" "$t" "echo \"$t \$*\" >> \"$DR/installer-calls\"; exit 1"; done
dstub "$DR/linux" uname 'case "$1" in -s) echo Linux ;; -r) echo 6.1.0-generic ;; *) echo Linux ;; esac'
dstub "$DR/mac" uname 'case "$1" in -s) echo Darwin ;; -r) echo 23.6.0 ;; *) echo Darwin ;; esac'
dstub "$DR/win" uname 'case "$1" in -s) echo MINGW64_NT-10.0-19045 ;; -r) echo 3.5.4-0bc1222b.x86_64 ;; *) echo MINGW64_NT-10.0-19045 ;; esac'
for v in 1.8.1 1.8.3 1.9.0; do
  dstub "$DR/f$v" forge "printf 'forge Version: $v\nCommit SHA: 0000000\n'"; dstub "$DR/f$v" cast "printf 'cast Version: $v\n'"; done
dstub "$DR/tools" rsync "echo 'rsync  version 3.2.7  protocol version 31'"
dstub "$DR/oldbash" bash "echo 'GNU bash, version 3.2.57(1)-release (arm64-apple-darwin23)'"
if command -v git > /dev/null 2>&1 && [ -f "$DK/scripts/doctor.sh" ]; then
  ln -s "$(command -v git)" "$DR/tools/git"; mkdir -p "$DR/gitonly"; ln -s "$(command -v git)" "$DR/gitonly/git"
  DV="$DK/foundry-kit/v4/lib/v4-core"
  printf 'contract PoolManager {}\n' > "$DV/src/PoolManager.sol"; printf 'contract Test {}\n' > "$DV/lib/forge-std/src/Test.sol"
  printf 'contract Owned {}\n' > "$DV/lib/solmate/src/Owned.sol"
  (cd "$DV" && git init -q && git add -A && git -c user.name=selftest -c user.email=selftest@invalid -c commit.gpgsign=false commit -q -m fake) > /dev/null 2>&1
  sed "s/^V4_CORE_PIN=\"[0-9a-f]*\"/V4_CORE_PIN=\"$(git -C "$DV" rev-parse HEAD)\"/" "$HERE/install-v4.sh" > "$DK/scripts/install-v4.sh"
  # doc <out> <dirs before the base, colon-separated> [VAR=value...]: the doctor on the fake machine, RPC_URL unset unless given
  doc() { local o="$1" p="$2"; shift 2; env -u RPC_URL -u ETH_RPC_URL HOME="$DH" PATH="$p:$DR/trap:$DB" "$@" "$BASH" "$DK/scripts/doctor.sh" > "$o" 2>&1; }
  # every line is `ok|missing|optional-missing <name> ...`, an indented line (a command, a step), or the last line
  doc_shape() { ! grep -vE '^(ok|missing|optional-missing) [A-Za-z0-9_.-]+( |$)|^  |^doctor: (ready|missing: .+)$' "$1"; }
  expect_line() { # expect_line <label> <file> <grep -E pattern>...: every pattern is found
    local label="$1" f="$2" pat miss=""; shift 2
    for pat in "$@"; do grep -qE -- "$pat" "$f" || miss="$miss [$pat]"; done
    if [ -z "$miss" ]; then echo "  ok    $label"; else echo "  FAIL  $label: not found:$miss"; sed "s/^/        | /" "$f"; fails=$((fails + 1)); fi
  }
  L="$DR/f1.8.1:$DR/tools:$DR/linux"
  doc "$TMP/o220" "$L"; check "doctor: everything required is there, forge at the pin" 0 $? "$TMP/o220"
  expect_line "and it says ready on its last line, forge 1.8.1 ok, RPC_URL optional and not set" "$TMP/o220" \
    '^ok forge 1\.8\.1' '^ok forge-std 1\.16\.2' '^ok v4-core ' '^ok bash 5' '^optional-missing RPC_URL' '^optional-missing python3'
  if [ "$(tail -n 1 "$TMP/o220")" = "doctor: ready" ] && doc_shape "$TMP/o220"; then echo "  ok    the last line is exactly 'doctor: ready', and every line has the documented shape"; else
    echo "  FAIL  the last line is not 'doctor: ready', or a line has another shape"; sed "s/^/        | /" "$TMP/o220"; fails=$((fails + 1)); fi
  doc "$TMP/o221" "$DR/tools:$DR/linux"; check "doctor: no forge on the PATH" 1 $? "$TMP/o221"
  expect_line "and it names forge and cast, with the Linux install commands, and lists them on the last line" "$TMP/o221" \
    '^missing forge' '^missing cast' 'curl -L https://foundry\.paradigm\.xyz \| bash' 'foundryup --install 1\.8\.1' '^doctor: missing: forge, cast$'
  mkdir -p "$DH/.foundry/bin"; cp "$DR/f1.8.1/forge" "$DR/f1.8.1/cast" "$DH/.foundry/bin/"
  doc "$TMP/o222" "$DR/tools:$DR/linux"; check "doctor: forge installed in ~/.foundry/bin but not on the PATH" 1 $? "$TMP/o222"
  expect_line "and it says to put ~/.foundry/bin on the PATH, not to install again" "$TMP/o222" 'export PATH="\$HOME/\.foundry/bin:\$PATH"'
  rm -rf "$DH/.foundry"
  doc "$TMP/o223" "$DR/f1.9.0:$DR/tools:$DR/linux"; check "doctor: a forge of another version (1.9.0)" 1 $? "$TMP/o223"
  expect_line "and it names the version found, the supported ones and the command for the pinned one" "$TMP/o223" \
    '^missing forge .*1\.9\.0' '1\.8\.1' 'foundryup --install 1\.8\.1' '^doctor: missing: forge'
  doc "$TMP/o224" "$DR/f1.8.3:$DR/tools:$DR/linux"; check "doctor: forge 1.8.3, the second supported version" 0 $? "$TMP/o224"
  expect_line "and it is ok, named as supported beside the pin" "$TMP/o224" '^ok forge 1\.8\.3'
  doc "$TMP/o225" "$L" RPC_URL="https://k20-sentinel.example.invalid/v2/SENTINEL0KEY" ETH_RPC_URL="https://k20-sentinel.example.invalid/v2/SENTINEL0KEY"
  check "doctor: RPC_URL set" 0 $? "$TMP/o225"
  expect_line "and it says set" "$TMP/o225" '^ok RPC_URL set'
  if ! grep -qiE 'SENTINEL0KEY|k20-sentinel|example\.invalid' "$TMP/o225"; then echo "  ok    and no part of the value appears in the output"; else
    echo "  FAIL  the RPC_URL value (or part of it) was printed"; fails=$((fails + 1)); fi
  doc "$TMP/o226" "$DR/f1.8.1:$DR/tools:$DR/win"; check "doctor: Windows outside WSL (Git Bash / MSYS uname)" 1 $? "$TMP/o226"
  expect_line "and it gives the WSL steps: admin PowerShell wsl --install, reboot, install inside WSL, the project on the Linux side" "$TMP/o226" \
    '^missing platform' 'administrator.*wsl --install|wsl --install.*administrator' '[Rr]eboot' 'inside WSL' 'Linux side' '^doctor: missing: platform$'
  doc "$TMP/o227" "$DR/f1.8.1:$DR/gitonly:$DR/mac"; check "doctor: macOS with no rsync" 1 $? "$TMP/o227"
  expect_line "and the command is brew's" "$TMP/o227" '^missing rsync' 'brew install rsync' '^doctor: missing: rsync$'
  doc "$TMP/o228" "$DR/f1.8.1:$DR/gitonly:$DR/linux"; check "doctor: Linux with no rsync" 1 $? "$TMP/o228"
  expect_line "and the command is apt's" "$TMP/o228" '^missing rsync' 'sudo apt-get install -y rsync'
  doc "$TMP/o229" "$DR/oldbash:$L"; check "doctor: the bash on the PATH is 3.2 (macOS's own)" 1 $? "$TMP/o229"
  expect_line "and it names the version found" "$TMP/o229" '^missing bash .*3\.2' '^doctor: missing: bash$'
  mv "$DK/foundry-kit/lib/forge-std" "$DR/forge-std.away"
  doc "$TMP/o230" "$L"; check "doctor: foundry-kit/lib/forge-std absent" 1 $? "$TMP/o230"
  expect_line "and it gives the pinned clone command" "$TMP/o230" '^missing forge-std' 'git clone --quiet --depth 1 --branch v1\.16\.2 https://github\.com/foundry-rs/forge-std foundry-kit/lib/forge-std'
  mv "$DR/forge-std.away" "$DK/foundry-kit/lib/forge-std"
  cp "$DK/scripts/install-v4.sh" "$DR/install-v4.keep"
  sed -i.bak 's/^V4_CORE_PIN="[0-9a-f]*"/V4_CORE_PIN="0000000000000000000000000000000000000000"/' "$DK/scripts/install-v4.sh"
  doc "$TMP/o231" "$L"; check "doctor: foundry-kit/v4/lib/v4-core at another commit than the pin" 1 $? "$TMP/o231"
  expect_line "and it gives install-v4.sh with V4_FORCE=1" "$TMP/o231" '^missing v4-core' 'V4_FORCE=1 scripts/install-v4.sh foundry-kit/v4'
  cp "$DR/install-v4.keep" "$DK/scripts/install-v4.sh"; mv "$DV" "$DR/v4-core.away"
  doc "$TMP/o232" "$L"; check "doctor: foundry-kit/v4/lib/v4-core not installed" 1 $? "$TMP/o232"
  expect_line "and it gives install-v4.sh" "$TMP/o232" '^missing v4-core' 'scripts/install-v4.sh foundry-kit/v4'
  mv "$DR/v4-core.away" "$DV"
  if [ ! -e "$DR/installer-calls" ]; then echo "  ok    no installer and no network tool was called by any doctor run above"; else
    echo "  FAIL  the doctor called an installer or a network tool:"; sed "s/^/        | /" "$DR/installer-calls"; fails=$((fails + 1)); fi
  # the versions the doctor calls supported are the ones CI runs: a pin changed in one place only is seen here
  dpins="$(sed -n 's/^FORGE_PIN="\(.*\)"$/\1 /p; s/^FORGE_ALSO="\(.*\)"$/\1 /p; s/^FORGE_STD_PIN="\(.*\)"$/\1 /p; s/^REPORTLAB_PIN="\(.*\)"$/\1 /p; s/^PYPDF_PIN="\(.*\)"$/\1/p' "$HERE/doctor.sh" | tr -d '\n')"
  gpins="$(sed -n 's/^  FOUNDRY_VERSION: v\(.*\)$/\1 /p; s/^  FOUNDRY_VERSION_2: v\(.*\)$/\1 /p; s/^  FORGE_STD_TAG: v\(.*\)$/\1 /p; s/^  REPORTLAB_VERSION: "\(.*\)"$/\1 /p; s/^  PYPDF_VERSION: "\(.*\)"$/\1/p' "$HERE/../.github/workflows/gates.yml" | tr -d '\n')"
  if [ -n "$dpins" ] && [ "$dpins" = "$gpins" ]; then echo "  ok    doctor.sh's pins ($dpins) are gates.yml's"; else
    echo "  FAIL  doctor.sh's pins ($dpins) are not gates.yml's ($gpins)"; fails=$((fails + 1)); fi
  # and on this machine, for real: whatever it finds, its last line and its exit code agree
  "$HERE/doctor.sh" > "$TMP/o233" 2>&1; rc233=$?
  case "$rc233:$(tail -n 1 "$TMP/o233")" in
    "0:doctor: ready" | "1:doctor: missing: "?*) echo "  ok    doctor.sh on this machine: $(tail -n 1 "$TMP/o233") (rc=$rc233)" ;;
    *) echo "  FAIL  doctor.sh on this machine: rc=$rc233 and last line '$(tail -n 1 "$TMP/o233")' do not agree"; fails=$((fails + 1)) ;;
  esac
else
  echo "  FAIL  doctor.sh is missing, or there is no git to build its fake v4-core with"; fails=$((fails + 1))
fi

# ================================================================= release-guard.sh
echo "== release-guard.sh =="
W="$TMP/work"; P="$TMP/published"
mkdir -p "$W" "$P"
printf 'contract A {}\n' > "$W/A.sol"
printf 'contract B {}\n' > "$W/B.sol"
cp "$W/A.sol" "$W/B.sol" "$P/"
{ printf '%s  A.sol\n' "$(hash_of "$P/A.sol")"; printf '%s  B.sol\n' "$(hash_of "$P/B.sol")"; } > "$P/MANIFEST.sha256"

"$HERE/release-guard.sh" "$W" "$P" > "$TMP/o1" 2>&1; check "identical trees, complete manifest" 0 $? "$TMP/o1"

printf 'contract A { uint256 x; }\n' > "$W/A.sol"
"$HERE/release-guard.sh" "$W" "$P" > "$TMP/o2" 2>&1; check "only the working tree was edited" 1 $? "$TMP/o2"
cp "$P/A.sol" "$W/A.sol"

printf 'contract C {}\n' > "$W/C.sol"; cp "$W/C.sol" "$P/C.sol"
"$HERE/release-guard.sh" "$W" "$P" > "$TMP/o3" 2>&1; check "a file added to BOTH trees with no hash" 2 $? "$TMP/o3"
rm -f "$W/C.sol" "$P/C.sol"

printf 'contract A { uint256 x; }\n' > "$W/A.sol"; cp "$W/A.sol" "$P/A.sol"
"$HERE/release-guard.sh" "$W" "$P" > "$TMP/o4" 2>&1; check "BOTH trees edited together, stale hash" 3 $? "$TMP/o4"

printf '%s  A.sol\n' "$(hash_of "$P/A.sol")" > "$P/MANIFEST.sha256"
printf '%s  B.sol\n' "$(hash_of "$P/B.sol")" >> "$P/MANIFEST.sha256"
"$HERE/release-guard.sh" "$W" "$P" > "$TMP/o5" 2>&1; check "manifest refreshed on purpose" 0 $? "$TMP/o5"

before="$(hash_of "$P/MANIFEST.sha256")"
"$HERE/release-guard.sh" "$W" "$P" > /dev/null 2>&1
after="$(hash_of "$P/MANIFEST.sha256")"
if [ "$before" = "$after" ]; then echo "  ok    the guard never writes into the published copy"; else
  echo "  FAIL  the guard modified the published copy"; fails=$((fails + 1)); fi

"$HERE/release-guard.sh" "$W" > "$TMP/o138" 2>&1; check "missing argument" 4 $? "$TMP/o138"

# ================================================================= assert-fresh-build.sh
# The VERDICT is forge's: the guard runs `forge build` and reads its answer ("No files changed, compilation skipped" =
# FRESH; a compilation = STALE, rebuilt; a failed build = nothing decided). Here, with no compiler, forge is a STUB that
# gives the answer each case names (FAKE_BUILD) - what forge 1.8.1 answered in the same situation on a real project
# (the real answers are cases o165-o167, o174 and o207-o212 in the forge section below). What this section tests is
# the rest: the guard's reading of each answer, and the EVIDENCE it prints before the verdict - the content of every
# source compared with forge's own record of what it compiled (cache/solidity-files-cache.json: one contentHash each).
# The fixture is a small project BUILT BY FORGE 1.8.1 - its sources in fixtures/fresh-project/, forge's cache of that
# build in fixtures/fresh-project.cache.json (the hashes are forge's, not this kit's; only the cache's library path was
# made relative). Its five sources fall in five size classes of the hash, so a hasher that disagrees with forge on any of
# them names a source that did not change. File times are SET, not waited for, and set on PURPOSE against the content:
# an edit dated before the build, a copy dated after it - the time must not decide either way.
echo "== assert-fresh-build.sh =="
FF="$TMP/fforge"; mkdir -p "$FF"
cat > "$FF/forge" <<'STUB'
#!/usr/bin/env bash
# a stub forge: answers `forge build` the way $FAKE_BUILD says, and refuses a repeated --offline as forge 1.8.1 does
n=0; for a in "$@"; do [ "$a" = "--offline" ] && n=$((n + 1)); done
if [ "$n" -gt 1 ]; then echo "error: the argument '--offline' cannot be used multiple times"; exit 2; fi
case "${FAKE_BUILD:-}" in
  skipped) echo "No files changed, compilation skipped" ;;
  compiled) printf 'Compiling 3 files with Solc 0.8.26\nSolc 0.8.26 finished in 1.00ms\nCompiler run successful!\n' ;;
  failed) printf 'Compiling 1 files with Solc 0.8.26\nError: Compiler run failed:\nError (2314): Expected identifier\n --> src/B.sol:4:10:\n'; exit 1 ;;
  *) echo "a line forge never printed" ;;
esac
exit 0
STUB
chmod +x "$FF/forge"
fresh() { PATH="$FF:$PATH" "$HERE/assert-fresh-build.sh" "$@"; }
J="$TMP/project"
cp -R "$FIX/fresh-project" "$J"
printf '[profile.default]\n' > "$J/foundry.toml"
T=1700000000
stamp() { T=$((T + 10)); touch -d "@$T" "$@"; }
stamp "$J/src/A.sol" "$J/src/B.sol" "$J/src/C.sol" "$J/test/D.t.sol" "$J/script/E.s.sol" "$J/foundry.toml"
before_build=$T
no_change_named() { ! grep -q '^evidence: .* changed after the last build' "$1" && ! grep -q '^evidence: .* is not in the cache' "$1"; }

FAKE_BUILD=compiled fresh "$J" > "$TMP/o6" 2>&1; check "nothing built yet (no out/): nothing decided, and no build run" 2 $? "$TMP/o6"

mkdir -p "$J/out/C.sol"
printf '{}\n' > "$J/out/C.sol/C.json"; stamp "$J/out/C.sol/C.json"
FAKE_BUILD=compiled fresh "$J" > "$TMP/o7" 2>&1; check "artifacts but no forge cache: nothing to compare against" 2 $? "$TMP/o7"

mkdir -p "$J/cache"; cp "$FIX/fresh-project.cache.json" "$J/cache/solidity-files-cache.json"; stamp "$J/cache/solidity-files-cache.json"
FAKE_BUILD=skipped fresh "$J" > "$TMP/o157" 2>&1; check "forge compiled nothing: FRESH" 0 $? "$TMP/o157"
if no_change_named "$TMP/o157" && grep -q '^evidence: 5 sources' "$TMP/o157"; then echo "  ok    and the evidence finds every source's content the one forge compiled (five size classes of its hash)"; else
  echo "  FAIL  the evidence names a source whose content is the one forge compiled (the hasher disagrees with forge?)"; fails=$((fails + 1)); fi

# forge's answer decides, whatever the evidence: every source is what forge compiled and forge compiled anyway (the
# settings changed, an artifact went missing...) - STALE, and it says the sources are not what changed
FAKE_BUILD=compiled fresh "$J" > "$TMP/o201" 2>&1; check "every source's content unchanged, and forge compiled: STALE (forge decides, not the hash)" 1 $? "$TMP/o201"
if grep -q '^STALE BUILD: forge compiled' "$TMP/o201" && grep -q 'not a source' "$TMP/o201"; then echo "  ok    and it says the sources are not what changed"; else
  echo "  FAIL  a STALE with unchanged sources does not say what else changes a build"; fails=$((fails + 1)); fi
FAKE_BUILD=failed fresh "$J" > "$TMP/o202" 2>&1; check "a build that fails decides nothing" 2 $? "$TMP/o202"
if grep -q 'Error (2314)' "$TMP/o202"; then echo "  ok    and it prints forge's error"; else
  echo "  FAIL  a failed build is not shown with its error"; fails=$((fails + 1)); fi
FAKE_BUILD=odd fresh "$J" > "$TMP/o203" 2>&1; check "an answer from forge this guard does not know decides nothing (never read as FRESH)" 2 $? "$TMP/o203"
FORGE_FLAGS="--offline" FAKE_BUILD=skipped fresh "$J" > "$TMP/o204" 2>&1; check "FORGE_FLAGS=--offline (the battery's) is not passed twice" 0 $? "$TMP/o204"
FORGE_FLAGS="--force" FAKE_BUILD=compiled fresh "$J" > "$TMP/o205" 2>&1; check "FORGE_FLAGS with --force (always compiles) is refused: nothing decided" 2 $? "$TMP/o205"

# (b) the case that used to flip: the same bytes copied in again AFTER the build (new mtime, same content)
cp "$FIX/fresh-project/src/C.sol" "$J/src/C.sol"; cp "$FIX/fresh-project/test/D.t.sol" "$J/test/D.t.sol"; stamp "$J/src/C.sol" "$J/test/D.t.sol"
FAKE_BUILD=skipped fresh "$J" > "$TMP/o158" 2>&1; check "sources copied in after the build, same content (new mtime): FRESH" 0 $? "$TMP/o158"
if grep -q 'newer than the cache with the same content' "$TMP/o158" && no_change_named "$TMP/o158"; then echo "  ok    and the newer times are printed as evidence, not as a change"; else
  echo "  FAIL  the copied sources' newer times are not reported as evidence, or are reported as a change"; fails=$((fails + 1)); fi

# (a) an edit that was not built - dated BEFORE the build, so that only its content can give it away
printf '// edited, not built\n' >> "$J/src/B.sol"; touch -d "@$before_build" "$J/src/B.sol"
FAKE_BUILD=compiled fresh "$J" > "$TMP/o159" 2>&1; check "a source edited without a build (dated before the build): STALE" 1 $? "$TMP/o159"
if grep -q '^evidence: src/B.sol changed after the last build' "$TMP/o159"; then echo "  ok    and the evidence names the edited source"; else
  echo "  FAIL  the evidence does not name src/B.sol"; fails=$((fails + 1)); fi
cp "$FIX/fresh-project/src/B.sol" "$J/src/B.sol"; stamp "$J/src/B.sol"
FAKE_BUILD=skipped fresh "$J" > "$TMP/o160" 2>&1; check "the edit undone (the compiled content again, a new mtime): FRESH" 0 $? "$TMP/o160"
if no_change_named "$TMP/o160"; then echo "  ok    and the evidence names no source"; else echo "  FAIL  the evidence names a source after the edit was undone"; fails=$((fails + 1)); fi

# (c) a new source, never built - also dated before the build
printf '// a new file\n' > "$J/src/F.sol"; touch -d "@$before_build" "$J/src/F.sol"
FAKE_BUILD=compiled fresh "$J" > "$TMP/o161" 2>&1; check "a new source that was never built: STALE" 1 $? "$TMP/o161"
if grep -q '^evidence: src/F.sol is not in the cache' "$TMP/o161"; then echo "  ok    and the evidence says the new source is not in the cache"; else
  echo "  FAIL  the evidence does not say src/F.sol is missing from the cache"; fails=$((fails + 1)); fi
rm -f "$J/src/F.sol"

# the config is not in forge's cache, so the evidence cannot compare its content - but forge's own build sees it: a changed
# optimizer recompiles (measured, forge 1.8.1: the stub answers what forge answered), so this is STALE now, not a note
printf 'optimizer = true\n' >> "$J/foundry.toml"; stamp "$J/foundry.toml"
FAKE_BUILD=compiled fresh "$J" > "$TMP/o162" 2>&1; check "a config changed after the build, no source changed: STALE (forge sees the settings)" 1 $? "$TMP/o162"
if grep -q '^evidence: foundry.toml is newer than the cache' "$TMP/o162"; then echo "  ok    and the evidence names foundry.toml as newer than the cache"; else
  echo "  FAIL  no evidence line about the config"; fails=$((fails + 1)); fi
printf '[profile.default]\n' > "$J/foundry.toml"; touch -d "@$before_build" "$J/foundry.toml"

# a cache the evidence cannot read (another forge's shape), or no interpreter to hash with: no evidence, and it says so -
# forge's answer still decides (these two were "nothing decided" while the hash was the verdict)
cp "$J/cache/solidity-files-cache.json" "$TMP/cache.keep"; printf '{"_format": "", "files": {"src/A.sol": {"sourceName": "src/A.sol"}}}\n' > "$J/cache/solidity-files-cache.json"
FAKE_BUILD=skipped fresh "$J" > "$TMP/o163" 2>&1; check "a cache with no contentHash: no evidence, forge's answer decides" 0 $? "$TMP/o163"
if grep -q '^evidence: none' "$TMP/o163"; then echo "  ok    and it says there is no evidence"; else echo "  FAIL  it does not say the evidence is missing"; fails=$((fails + 1)); fi
cp "$TMP/cache.keep" "$J/cache/solidity-files-cache.json"
HASH_PYTHON="$TMP/no-such-python" FAKE_BUILD=skipped fresh "$J" > "$TMP/o164" 2>&1; check "no interpreter to hash with: no evidence, forge's answer decides" 0 $? "$TMP/o164"
if grep -q '^evidence: none' "$TMP/o164"; then echo "  ok    and it says there is no evidence"; else echo "  FAIL  it does not say the evidence is missing"; fails=$((fails + 1)); fi
no_forge_path=""
while IFS= read -r -d ':' d; do [ -x "$d/forge" ] || no_forge_path="$no_forge_path$d:"; done <<< "$PATH:"
PATH="${no_forge_path%:}" "$HERE/assert-fresh-build.sh" "$J" > "$TMP/o206" 2>&1; check "no forge on the PATH decides nothing" 2 $? "$TMP/o206"

# line ends: forge 1.8.1 hashes the text with every CR LF turned into LF, in one pass, and nothing else - a lone CR, a CR CR LF,
# a missing last newline stay as they are (measured on eight fixtures against its own cache, 2026-09-23). A checkout with
# CRLF is therefore the text forge compiled, and the evidence used to name it as changed on a fresh build. The two cases
# after it pin the rule from the other side: a hasher that dropped EVERY CR, or turned a lone CR into LF, would not name them.
for f in src/A.sol src/B.sol src/C.sol test/D.t.sol script/E.s.sol; do
  sed 's/$/\r/' "$FIX/fresh-project/$f" > "$J/$f"; touch -d "@$before_build" "$J/$f"
done
FAKE_BUILD=skipped fresh "$J" > "$TMP/o171" 2>&1; check "the five sources with CRLF line ends (forge compiles nothing)" 0 $? "$TMP/o171"
if no_change_named "$TMP/o171"; then echo "  ok    and the evidence names no source: CRLF is the text forge compiled"; else
  echo "  FAIL  the evidence names a CRLF source as changed"; fails=$((fails + 1)); fi
for f in src/A.sol src/B.sol src/C.sol test/D.t.sol script/E.s.sol; do cp "$FIX/fresh-project/$f" "$J/$f"; touch -d "@$before_build" "$J/$f"; done
awk 'NR == 1 { printf "%s\r\r\n", $0; next } { print }' "$FIX/fresh-project/src/B.sol" > "$J/src/B.sol"; touch -d "@$before_build" "$J/src/B.sol"
FAKE_BUILD=compiled fresh "$J" > "$TMP/o172" 2>&1; check "a line ending CR CR LF (forge compiles)" 1 $? "$TMP/o172"
if grep -q '^evidence: src/B.sol changed after the last build' "$TMP/o172"; then echo "  ok    and the evidence names it: forge folds CR LF once"; else
  echo "  FAIL  the evidence does not name a CR CR LF source"; fails=$((fails + 1)); fi
awk 'NR == 1 { printf "%s\r", $0; next } { print }' "$FIX/fresh-project/src/B.sol" > "$J/src/B.sol"; touch -d "@$before_build" "$J/src/B.sol"
FAKE_BUILD=compiled fresh "$J" > "$TMP/o173" 2>&1; check "a lone CR where an LF was (forge compiles)" 1 $? "$TMP/o173"
if grep -q '^evidence: src/B.sol changed after the last build' "$TMP/o173"; then echo "  ok    and the evidence names it: forge keeps a lone CR"; else
  echo "  FAIL  the evidence does not name a lone-CR source"; fails=$((fails + 1)); fi
cp "$FIX/fresh-project/src/B.sol" "$J/src/B.sol"; touch -d "@$before_build" "$J/src/B.sol"

# ================================================================= fetch-bytecode.sh (the refusals; no network is used)
echo "== fetch-bytecode.sh =="
( unset RPC_URL ETH_RPC_URL; "$HERE/fetch-bytecode.sh" 0x000000000000000000000000000000000000dEaD "$TMP/x.hex" > "$TMP/o21" 2>&1 )
check "no RPC_URL in the environment: refuses, and says where the endpoint goes" 1 $? "$TMP/o21"
RPC_URL="http://127.0.0.1:9" "$HERE/fetch-bytecode.sh" "https://example.invalid/v2/SECRET" "$TMP/x.hex" > "$TMP/o22" 2>&1
check "an endpoint passed where the address goes is refused" 1 $? "$TMP/o22"
if grep -q "SECRET" "$TMP/o22"; then echo "  FAIL  the refused endpoint was echoed back"; fails=$((fails + 1)); else
  echo "  ok    the refused endpoint is not echoed back"; fi
RPC_URL="http://127.0.0.1:9" "$HERE/fetch-bytecode.sh" 0x1234 "$TMP/x.hex" > "$TMP/o23" 2>&1
check "a short address is refused" 1 $? "$TMP/o23"
if [ -e "$TMP/x.hex" ]; then echo "  FAIL  a fixture was written by a refused call"; fails=$((fails + 1)); else
  echo "  ok    no fixture is written by a refused call"; fi

RPC_URL="http://127.0.0.1:9" "$HERE/fetch-bytecode.sh" "0x12345678901234567890123456789012345678zz" "$TMP/x.hex" > "$TMP/o95" 2>&1
check "an address of the right LENGTH with non-hex digits is refused" 1 $? "$TMP/o95"
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
  check "a pin that is a branch name, not a commit hash, is refused" 1 $? "$TMP/o96"
  if [ ! -e "$IV/git-calls" ] && [ ! -e "$IV/proj/lib" ] && grep -q "not a full commit hash" "$TMP/o96"; then
    echo "  ok    and it was refused before git was called or lib/ was created"; else
    echo "  FAIL  install-v4.sh went on with a bad pin: $(head -2 "$IV/git-calls" 2> /dev/null)"; fails=$((fails + 1)); fi
else
  echo "  FAIL  could not plant a bad pin in a copy of install-v4.sh (the pin line changed shape?)"; fails=$((fails + 1))
fi
cp "$HERE/install-v4.sh" "$IV/scripts/"; rm -rf "$IV/git-calls" "$IV/proj/lib"
sed -i.bak 's/^V4_CORE_PIN="\([0-9a-f]*\)"/V4_CORE_PIN="\1a"/' "$IV/scripts/install-v4.sh"
PATH="$IV/gitshim:$PATH" "$IV/scripts/install-v4.sh" "$IV/proj" > "$TMP/o97" 2>&1
check "a pin one hex digit too long is refused" 1 $? "$TMP/o97"
if [ ! -e "$IV/git-calls" ]; then echo "  ok    and git was never called for it"; else
  echo "  FAIL  install-v4.sh called git with a 41-digit pin"; fails=$((fails + 1)); fi
cp "$HERE/install-v4.sh" "$IV/scripts/"; rm -rf "$IV/git-calls" "$IV/proj/lib"
PATH="$IV/gitshim:$PATH" "$IV/scripts/install-v4.sh" "$IV/no-such-project" > "$TMP/o98" 2>&1
check "a destination that does not exist is refused" 1 $? "$TMP/o98"
if [ ! -e "$IV/git-calls" ] && [ ! -e "$IV/no-such-project" ]; then echo "  ok    and nothing was created for it, and git was never called"; else
  echo "  FAIL  install-v4.sh created the missing destination or called git"; fails=$((fails + 1)); fi
PATH="$IV/gitshim:$PATH" "$IV/scripts/install-v4.sh" "$IV/proj" > "$TMP/o99" 2>&1
check "control: good pins and a real destination reach git (the shim fails it)" 1 $? "$TMP/o99"
if [ -s "$IV/git-calls" ]; then echo "  ok    and git WAS called: the refusals above are the guards, not a broken copy"; else
  echo "  FAIL  the control never reached git: the refusals above prove nothing"; fails=$((fails + 1)); fi
# the OFFLINE path (V4_LOCAL_SRC): a fake local clone at a commit that is not the pin must be refused before anything is
# copied, and nothing may be fetched. This one needs a real git (to make the clone); the shim is kept out of it.
if command -v git > /dev/null 2>&1; then
  LS="$TMP/localsrc"; mkdir -p "$LS/v4-core"; rm -rf "$IV/proj/lib"
  (cd "$LS/v4-core" && git init -q && printf 'x\n' > f && git add f \
    && git -c user.name=selftest -c user.email=selftest@invalid -c commit.gpgsign=false commit -q -m fake) > /dev/null 2>&1
  # GIT_ALLOW_PROTOCOL=file: whatever the script does, git itself refuses to reach the network from this case
  GIT_ALLOW_PROTOCOL="file" V4_LOCAL_SRC="$LS" "$IV/scripts/install-v4.sh" "$IV/proj" > "$TMP/o114" 2>&1
  check "offline install from a local clone at the WRONG pin is refused" 1 $? "$TMP/o114"
  if grep -q "is at $(git -C "$LS/v4-core" rev-parse HEAD), the pin is" "$TMP/o114" && [ ! -e "$IV/proj/lib/v4-core" ]; then
    echo "  ok    and it names both commits, and nothing was copied into the project"; else
    echo "  FAIL  the wrong-pin clone was not refused by name, or it was copied: $(grep install-v4 "$TMP/o114" | head -2)"; fails=$((fails + 1)); fi
  GIT_ALLOW_PROTOCOL="file" V4_LOCAL_SRC="$TMP/no-such-dir" "$IV/scripts/install-v4.sh" "$IV/proj" > "$TMP/o115" 2>&1
  check "offline install from a directory with no v4-core clone is refused" 1 $? "$TMP/o115"

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
  inst() { GIT_ALLOW_PROTOCOL="file" "$PINNED/scripts/install-v4.sh" "$@"; }   # quoted: shellcheck reads a bare file as the file command (SC2209)
  if [ "$(git -C "$GV" ls-tree HEAD lib/solmate | awk '{print $2}')" = "commit" ] && grep -q "^V4_CORE_PIN=\"$(git -C "$GV" rev-parse HEAD)\"" "$PINNED/scripts/install-v4.sh"; then
    mkdir -p "$IV/p1" "$IV/p2" "$IV/p3" "$IV/p4"
    V4_LOCAL_SRC="$G" inst "$IV/p1" > "$TMP/o120" 2>&1; check "control: offline install from a GOOD local clone" 0 $? "$TMP/o120"
    V4_FORCE=1 V4_LOCAL_SRC="$G" inst "$IV/p1" > "$TMP/o121" 2>&1; check "the same, again, with V4_FORCE=1 (it used to fail with a false 'forge-std missing')" 0 $? "$TMP/o121"
    # a clone whose solmate submodule is not checked out: refused, and it must leave nothing behind
    B="$TMP/badsrc"; mkdir -p "$B"; cp -a "$GV" "$B/v4-core"; rm -rf "$B/v4-core/lib/solmate"; mkdir "$B/v4-core/lib/solmate"
    V4_LOCAL_SRC="$B" inst "$IV/p2" > "$TMP/o122" 2>&1; check "offline install from a clone with a submodule missing is refused" 1 $? "$TMP/o122"
    if [ ! -e "$IV/p2/lib" ]; then echo "  ok    and the refusal left no lib/ in a project that had none"; else
      echo "  FAIL  the refused install left a partial lib/: $(cd "$IV/p2" && find lib -maxdepth 2 | head -4 | tr '\n' ' ')"; fails=$((fails + 1)); fi
    V4_LOCAL_SRC="$G" inst "$IV/p2" > "$TMP/o123" 2>&1; check "the next attempt with a GOOD clone, no V4_FORCE, installs (the refusal did not poison it)" 0 $? "$TMP/o123"
    # a refused V4_FORCE over a good install leaves that install as it was
    V4_FORCE=1 V4_LOCAL_SRC="$B" inst "$IV/p1" > "$TMP/o124" 2>&1; check "V4_FORCE=1 from the broken clone over a good install is refused" 1 $? "$TMP/o124"
    if [ -f "$IV/p1/lib/v4-core/lib/solmate/src/Owned.sol" ] && [ -z "$(find "$IV/p1/lib" -maxdepth 1 -name '.install-v4-*')" ]; then
      echo "  ok    and the good install is intact, with no staging directory left behind"; else
      echo "  FAIL  a refused V4_FORCE damaged the install it was refused over"; fails=$((fails + 1)); fi
    # a lib/v4-core that is ALREADY broken (as a refused run of an older install-v4.sh left it): refused without FORCE, and
    # the message says FORCE is the way out; with FORCE it is replaced
    mkdir -p "$IV/p3/lib"; cp -a "$B/v4-core" "$IV/p3/lib/v4-core"
    V4_LOCAL_SRC="$G" inst "$IV/p3" > "$TMP/o125" 2>&1; check "an installed lib/v4-core with a submodule missing is refused without V4_FORCE" 1 $? "$TMP/o125"
    if grep -q "V4_FORCE=1" "$TMP/o125"; then echo "  ok    and the refusal names V4_FORCE=1 as the way out"; else
      echo "  FAIL  the refusal does not say how to recover"; fails=$((fails + 1)); fi
    V4_FORCE=1 V4_LOCAL_SRC="$G" inst "$IV/p3" > "$TMP/o126" 2>&1; check "V4_FORCE=1 with a good clone recovers it" 0 $? "$TMP/o126"
    [ -f "$IV/p3/lib/v4-core/lib/solmate/src/Owned.sol" ] || { echo "  FAIL  V4_FORCE said OK but solmate is not there"; fails=$((fails + 1)); }
    # untracked files in the clone: an untracked .sol under src/ (of the clone or of a submodule) is refused; anything
    # else untracked is copied, as the header says
    U="$TMP/untrsrc"; mkdir -p "$U"; cp -a "$GV" "$U/v4-core"; printf 'contract Extra {}\n' > "$U/v4-core/src/Extra.sol"
    V4_LOCAL_SRC="$U" inst "$IV/p4" > "$TMP/o127" 2>&1; check "a clone with an UNTRACKED .sol under src/ is refused" 1 $? "$TMP/o127"
    if grep -q "src/Extra.sol" "$TMP/o127" && [ ! -e "$IV/p4/lib" ]; then echo "  ok    and it names the file, and nothing was copied"; else
      echo "  FAIL  the untracked .sol was not named, or something was copied"; fails=$((fails + 1)); fi
    V4_ALLOW_UNTRACKED=1 V4_LOCAL_SRC="$U" inst "$IV/p4" > "$TMP/o128" 2>&1; check "the same clone with V4_ALLOW_UNTRACKED=1" 0 $? "$TMP/o128"
    if [ -f "$IV/p4/lib/v4-core/src/Extra.sol" ] && grep -q "src/Extra.sol" "$TMP/o128"; then echo "  ok    and the file was copied AND listed"; else
      echo "  FAIL  V4_ALLOW_UNTRACKED=1 did not copy and list the file"; fails=$((fails + 1)); fi
    rm -f "$U/v4-core/src/Extra.sol"; printf 'contract Evil {}\n' > "$U/v4-core/lib/forge-std/src/Evil.sol"; rm -rf "$IV/p4/lib"
    V4_LOCAL_SRC="$U" inst "$IV/p4" > "$TMP/o129" 2>&1; check "an untracked .sol under a SUBMODULE's src/ is refused too" 1 $? "$TMP/o129"
    if grep -q "lib/forge-std/src/Evil.sol" "$TMP/o129"; then echo "  ok    and it is refused BY NAME (not as some other local change)"; else
      echo "  FAIL  the submodule's untracked .sol was not named"; fails=$((fails + 1)); fi
    rm -f "$U/v4-core/lib/forge-std/src/Evil.sol"; printf 'contract Test { uint256 x; }\n' > "$U/v4-core/lib/forge-std/src/Test.sol"
    V4_LOCAL_SRC="$U" inst "$IV/p4" > "$TMP/o134" 2>&1; check "a changed TRACKED file in a submodule is still a local change, refused" 1 $? "$TMP/o134"
    grep -q "LOCAL CHANGES" "$TMP/o134" || { echo "  FAIL  the changed submodule file was not refused as a local change"; fails=$((fails + 1)); }
    (cd "$U/v4-core/lib/forge-std" && git checkout -q -- src/Test.sol)
    # a submodule holding only untracked files is treated like the clone itself: a .txt in it is copied, not refused
    printf 'notes\n' > "$U/v4-core/src/NOTES.txt"; printf 'notes\n' > "$U/v4-core/lib/forge-std/NOTES.txt"
    V4_LOCAL_SRC="$U" inst "$IV/p4" > "$TMP/o130" 2>&1; check "an untracked file that is not a .sol is copied (the documented limit)" 0 $? "$TMP/o130"
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
expect_out "build verdict, real: nothing compiled" "skipped" 0 parse_build_verdict "$FIX/build-real-noop.txt"
expect_out "build verdict, real: compiled (the lint notes after it are not read)" "compiled" 0 parse_build_verdict "$FIX/build-real-compiled.txt"
expect_out "build verdict, a log with neither line: refused (never read as nothing compiled)" "" 1 parse_build_verdict "$FIX/build-nm-neither.txt"

# ---- the scripts that read those shapes, fed them through a forge SHIM (no compiler runs): the parser is only half of
# the guard, the other half is the script acting on its refusal
FS="$TMP/fshim"; FP="$TMP/fproj"; mkdir -p "$FS" "$FP/src" "$FP/out/A.sol" "$FP/cache"
# its sources and cache are the forge-built freshness fixture, so the battery's freshness step reads a real cache
cp -R "$FIX/fresh-project/." "$FP/"; printf '[profile.default]\n' > "$FP/foundry.toml"
printf '{}\n' > "$FP/out/A.sol/A.json"; cp "$FIX/fresh-project.cache.json" "$FP/cache/solidity-files-cache.json"
touch -d "@1700000000" "$FP/src/A.sol" "$FP/foundry.toml"; touch -d "@1700000100" "$FP/out/A.sol/A.json" "$FP/cache/solidity-files-cache.json"
# the shim answers `forge build --sizes` with $SHIM_SIZES and `forge test` with $SHIM_TEST, and any other build with forge's
# "nothing to compile" (the freshness step builds too, and reads that answer as FRESH)
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" --sizes "*) cat "$SHIM_SIZES" ;;\n  " test "*) cat "$SHIM_TEST" ;;\n  *) echo "No files changed, compilation skipped" ;;\nesac\nexit 0\n' > "$FS/forge"; chmod +x "$FS/forge"
export SHIM_SIZES="$FIX/sizes-real.txt" SHIM_TEST="$FIX/summary-real-one-suite.txt"
PATH="$FS:$PATH" OUT_DIR="$TMP/fb" "$HERE/battery.sh" "$FP" > "$TMP/o100" 2>&1; check "battery through the shim on a real green summary (the control)" 0 $? "$TMP/o100"
SHIM_TEST="$FIX/summary-nm-console-only.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fb" "$HERE/battery.sh" "$FP" > "$TMP/o101" 2>&1
check "battery: a summary printed only by a test's console is NO summary" 1 $? "$TMP/o101"
SHIM_TEST="$FIX/summary-nm-no-skipped-field.txt" ALLOW_SKIPS=1 PATH="$FS:$PATH" OUT_DIR="$TMP/fb" "$HERE/battery.sh" "$FP" > "$TMP/o102" 2>&1
check "battery: a summary of another shape is refused, even with ALLOW_SKIPS=1" 1 $? "$TMP/o102"
SHIM_SIZES="$FIX/sizes-nm-columns-swapped.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o103" 2>&1
check "size.sh on a table with its columns in another order" 0 $? "$TMP/o103"
if grep -Eq '^ToyVault +1672 +22904' "$TMP/o103"; then echo "  ok    and it read the RUNTIME column by its header (1672, not the initcode 1811)"; else
  echo "  FAIL  size.sh read the wrong column: $(grep ToyVault "$TMP/o103")"; fails=$((fails + 1)); fi
SHIM_SIZES="$FIX/sizes-real.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o110" 2>&1
check "size.sh on the real table" 0 $? "$TMP/o110"
if grep -Eq '^ToyVault +1672 +22904 +1811 +47341 ' "$TMP/o110"; then echo "  ok    and it reports the INITCODE and its margin to 49 152 next to the runtime (1811, 47341)"; else
  echo "  FAIL  size.sh does not report the initcode size and margin: $(grep ToyVault "$TMP/o110")"; fails=$((fails + 1)); fi
SHIM_SIZES="$FIX/sizes-real.txt" MIN_INIT_MARGIN=48000 PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o111" 2>&1
check "size.sh: an initcode margin below MIN_INIT_MARGIN fails" 1 $? "$TMP/o111"
SHIM_SIZES="$FIX/sizes-nm-no-initcode.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o112" 2>&1
check "size.sh on a table with no Initcode column measures nothing (the phase-2 gate needs both)" 2 $? "$TMP/o112"
SHIM_SIZES="$FIX/sizes-nm-renamed-header.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o104" 2>&1
check "size.sh on a table whose runtime column is not called Runtime Size measures nothing" 2 $? "$TMP/o104"
SHIM_SIZES="$FIX/sizes-nm-no-header.txt" PATH="$FS:$PATH" OUT_DIR="$TMP/fs" "$HERE/size.sh" "$FP" ToyVault > "$TMP/o105" 2>&1
check "size.sh on a table with no header measures nothing" 2 $? "$TMP/o105"
unset SHIM_SIZES SHIM_TEST
# mutate.sh's baseline build fails; the shim prints a log whose END is warnings. The cause must be on the screen.
FS2="$TMP/fshim2"; mkdir -p "$FS2"
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" build "*) cat "%s"; exit 1 ;;\nesac\necho "Compiler run successful!"; exit 0\n' "$FIX/build-nm-error-then-warnings.txt" > "$FS2/forge"; chmod +x "$FS2/forge"
printf 'contract A { uint256 x; }\n' > "$FP/src/A.sol"
PATH="$FS2:$PATH" LABEL=m17 OUT_DIR="$TMP/mut0" "$HERE/mutate.sh" "$FP" src/A.sol "uint256 x;" "uint256 y;" > "$TMP/o113" 2>&1
check "mutate.sh on a copy that does not build: nothing proven" 2 $? "$TMP/o113"
if grep -q 'first error: Error (6275): Source "../src/InvariantBase.sol" not found' "$TMP/o113"; then
  echo "  ok    and it names the FIRST error, though the log ends in warnings"; else
  echo "  FAIL  mutate.sh did not show the error that stopped the build:"; sed "s/^/        | /" "$TMP/o113" | head -8; fails=$((fails + 1)); fi
# Where the throwaway copy goes. With a BENCH_ROOT (or TMPDIR) that did not exist, `mktemp -d -p` failed, the copy's path
# was EMPTY, and the script ran `cp -a <project>/. /` - "cannot create directory '/./src': Permission denied" for a fresh
# reader, and the project copied into the file system's root for anyone running as root (FR8). A BENCH_ROOT that does not
# exist is created; a place the copy cannot be made is refused in one line, rc 2, naming the variable and the path. The
# shim above fails the baseline build, so "does not compile BEFORE" is the proof the copy was made and used.
PATH="$FS2:$PATH" KEEP=1 BENCH_ROOT="$TMP/mr-new/deep/root" LABEL=m18 OUT_DIR="$TMP/mut0" "$HERE/mutate.sh" "$FP" src/A.sol "uint256 x;" "uint256 y;" > "$TMP/o193" 2>&1
check "mutate.sh with a BENCH_ROOT that does not exist yet: it is created and used" 2 $? "$TMP/o193"
kept193="$(sed -n 's/^copy kept at //p' "$TMP/o193")"
case "$kept193" in "$TMP/mr-new/deep/root/mutate."*) under193=1 ;; *) under193=0 ;; esac
if [ "$under193" -eq 1 ] && [ -f "$kept193/src/A.sol" ] && grep -q "does not compile BEFORE" "$TMP/o193" && ! grep -q "'/\./" "$TMP/o193" && ! grep -q "Permission denied" "$TMP/o193"; then
  echo "  ok    and the copy landed under the created root, not at /"; else
  echo "  FAIL  the copy did not land under the BENCH_ROOT it was given (kept at: ${kept193:-nothing}):"; sed "s/^/        | /" "$TMP/o193" | head -8; fails=$((fails + 1)); fi
[ -n "$kept193" ] && [ "$under193" -eq 1 ] && rm -rf "$kept193"
PATH="$FS2:$PATH" TMPDIR="$TMP/no-such-tmp" LABEL=m19 OUT_DIR="$TMP/mut0" env -u BENCH_ROOT "$HERE/mutate.sh" "$FP" src/A.sol "uint256 x;" "uint256 y;" > "$TMP/o194" 2>&1
check "mutate.sh with no BENCH_ROOT and a TMPDIR that does not exist is refused" 2 $? "$TMP/o194"
if [ "$(grep -cF "mutate: cannot make the throwaway copy under TMPDIR=$TMP/no-such-tmp" "$TMP/o194")" = "1" ] && ! grep -q "^cp: \|resolves to \|does not compile" "$TMP/o194"; then
  echo "  ok    and the refusal is one line naming TMPDIR and its path, before anything is copied"; else
  echo "  FAIL  the refusal for a missing TMPDIR:"; sed "s/^/        | /" "$TMP/o194" | head -8; fails=$((fails + 1)); fi
printf 'not a directory\n' > "$TMP/afile"
PATH="$FS2:$PATH" BENCH_ROOT="$TMP/afile/root" LABEL=m20 OUT_DIR="$TMP/mut0" "$HERE/mutate.sh" "$FP" src/A.sol "uint256 x;" "uint256 y;" > "$TMP/o195" 2>&1
check "mutate.sh with a BENCH_ROOT that cannot be created is refused" 2 $? "$TMP/o195"
if [ "$(grep -cF "mutate: cannot make the throwaway copy under BENCH_ROOT=$TMP/afile/root" "$TMP/o195")" = "1" ] && ! grep -q "^cp: \|resolves to \|does not compile" "$TMP/o195"; then
  echo "  ok    and the refusal is one line naming BENCH_ROOT and its path, before anything is copied"; else
  echo "  FAIL  the refusal for a BENCH_ROOT that cannot be made:"; sed "s/^/        | /" "$TMP/o195" | head -8; fails=$((fails + 1)); fi
# a file that is a RELATIVE link leaving the project: in the copy it points at nothing, and the refusal used to read
# "src/L.sol resolves to , which is OUTSIDE the throwaway copy" - an empty path and the wrong cause (a symlinked lib/?)
mkdir -p "$TMP/relout"; printf 'contract L { uint256 x; }\n' > "$TMP/relout/L.sol"; ln -s ../../relout/L.sol "$FP/src/L.sol"
PATH="$FS2:$PATH" BENCH_ROOT="$TMP/mr-new/deep/root" LABEL=m21 OUT_DIR="$TMP/mut0" "$HERE/mutate.sh" "$FP" src/L.sol "uint256 x;" "uint256 y;" > "$TMP/o196" 2>&1
check "mutate.sh on a relative link whose target is not in the copy: nothing proven" 2 $? "$TMP/o196"
if ! grep -q "resolves to ," "$TMP/o196" && grep -qF "src/L.sol does not resolve inside the throwaway copy" "$TMP/o196" && grep -qF -- "-> ../../relout/L.sol" "$TMP/o196" && ! grep -q "symlinked lib" "$TMP/o196"; then
  echo "  ok    and the refusal names the real cause: a link whose target the copy does not hold"; else
  echo "  FAIL  the refusal for a link that points outside the copy:"; sed "s/^/        | /" "$TMP/o196" | head -8; fails=$((fails + 1)); fi
rm -f "$FP/src/L.sol"
# a copy that fails half-way (an unreadable file) must be refused, not built from what arrived. Root reads anything.
if [ "$(id -u)" != "0" ]; then
  printf 'secret\n' > "$FP/src/Unreadable.txt"; chmod 000 "$FP/src/Unreadable.txt"
  PATH="$FS2:$PATH" BENCH_ROOT="$TMP/mr-new/deep/root" LABEL=m22 OUT_DIR="$TMP/mut0" "$HERE/mutate.sh" "$FP" src/A.sol "uint256 x;" "uint256 y;" > "$TMP/o197" 2>&1
  check "mutate.sh when the copy of the project fails half-way is refused" 2 $? "$TMP/o197"
  if grep -qF "mutate: the copy of $FP into $TMP/mr-new/deep/root/mutate." "$TMP/o197" && ! grep -q "does not compile" "$TMP/o197"; then
    echo "  ok    and it says the copy failed, before building anything"; else
    echo "  FAIL  a failed copy was not refused:"; sed "s/^/        | /" "$TMP/o197" | head -8; fails=$((fails + 1)); fi
  chmod 600 "$FP/src/Unreadable.txt"; rm -f "$FP/src/Unreadable.txt"
fi
if [ -z "$(ls -A "$TMP/mr-new/deep/root" 2> /dev/null)" ]; then echo "  ok    and no copy was left behind under the root"; else
  echo "  FAIL  copies were left under the root: $(ls "$TMP/mr-new/deep/root")"; fails=$((fails + 1)); fi
"$HERE/sim-report.sh" "$FIX/sim-nm-nonnumeric.tsv" > "$TMP/o106" 2>&1; check "sim-report over a ledger with three malformed lines" 0 $? "$TMP/o106"
if grep -Eq '^nm +honest +2 +40\.0 +39\.0 +1\.0 ' "$TMP/o106" && grep -q "3 line(s) ignored (malformed" "$TMP/o106"; then
  echo "  ok    and the malformed lines are counted out loud, not added up as numbers"; else
  echo "  FAIL  sim-report added up a field that is not a number:"; sed "s/^/        | /" "$TMP/o106"; fails=$((fails + 1)); fi
printf 'x\ty\t1\t2\n' > "$TMP/allbad.tsv"; "$HERE/sim-report.sh" "$TMP/allbad.tsv" > "$TMP/o107" 2>&1
check "sim-report over a ledger with no well-formed line measured nothing" 2 $? "$TMP/o107"

# ================================================================= bench.sh refreshes (no forge needed)
echo "== bench.sh (refresh, dependency directories) =="
BP="$TMP/bproj"; mkdir -p "$BP/src" "$BP/fixtures" "$BP/lib/dep" "$BP/v4/src" "$BP/v4/lib/dep2" "$BP/scripts/lib"
printf '[profile.default]\n' > "$BP/foundry.toml"; printf '[profile.default]\n' > "$BP/v4/foundry.toml"
printf 'contract S {}\n' > "$BP/src/S.sol"; printf 'contract V {}\n' > "$BP/v4/src/V.sol"
printf 'contract D {}\n' > "$BP/lib/dep/D.sol"; printf 'contract D2 {}\n' > "$BP/v4/lib/dep2/D2.sol"
printf 'echo parse\n' > "$BP/scripts/lib/parse.sh"; printf '# fixtures\n' > "$BP/fixtures/README.md"
BENCH_ROOT="$TMP/bb2" "$HERE/bench.sh" two "$BP" > "$TMP/o116" 2>&1; check "a bench of a project with a nested foundry project" 0 $? "$TMP/o116"
if [ -L "$TMP/bb2/two/lib" ] && [ -L "$TMP/bb2/two/v4/lib" ] && [ "$(readlink "$TMP/bb2/two/v4/lib")" = "$BP/v4/lib" ] \
  && [ -f "$TMP/bb2/two/scripts/lib/parse.sh" ] && [ ! -L "$TMP/bb2/two/scripts/lib" ]; then
  echo "  ok    lib/ and v4/lib/ are LINKED, and scripts/lib/ (source, not a dependency) is copied"; else
  echo "  FAIL  LINK_LIB: root lib $(readlink "$TMP/bb2/two/lib" 2> /dev/null || echo none), v4/lib $(readlink "$TMP/bb2/two/v4/lib" 2> /dev/null || echo none), scripts/lib/parse.sh $([ -f "$TMP/bb2/two/scripts/lib/parse.sh" ] && echo present || echo MISSING)"; fails=$((fails + 1)); fi
# the v4 README's flow: a bench that keeps what was fetched INTO it. The project has no fixtures/*.hex and no v4/lib of
# its own here, so the bench's are its own; a refresh must keep both, and the bench itself must never be deleted.
rm -rf "$BP/v4/lib"
BENCH_ROOT="$TMP/bb2" BENCH_EXCLUDE="*.hex *.json" "$HERE/bench.sh" keep "$BP" > "$TMP/o117" 2>&1; check "a bench that excludes the fetched fixtures" 0 $? "$TMP/o117"
printf '0x6080\n' > "$TMP/bb2/keep/fixtures/PROBE.hex"; printf '{}\n' > "$TMP/bb2/keep/fixtures/PROBE.json"
mkdir -p "$TMP/bb2/keep/v4/lib/v4-core"; printf 'installed into the bench\n' > "$TMP/bb2/keep/v4/lib/v4-core/INSTALLED"
printf 'contract S { uint256 x; }\n' > "$BP/src/S.sol"
BENCH_ROOT="$TMP/bb2" BENCH_EXCLUDE="*.hex *.json" "$HERE/bench.sh" keep "$BP" > "$TMP/o118" 2>&1; check "the same bench, refreshed" 0 $? "$TMP/o118"
if [ -f "$TMP/bb2/keep/fixtures/PROBE.hex" ] && [ -f "$TMP/bb2/keep/fixtures/PROBE.json" ] && [ -f "$TMP/bb2/keep/v4/lib/v4-core/INSTALLED" ] \
  && grep -q "uint256 x" "$TMP/bb2/keep/src/S.sol"; then
  echo "  ok    the fetched fixtures and the bench's own v4/lib survived the refresh, and the source was refreshed"; else
  echo "  FAIL  the refresh deleted what it was asked to keep: PROBE.hex $([ -f "$TMP/bb2/keep/fixtures/PROBE.hex" ] && echo kept || echo GONE), v4/lib $([ -f "$TMP/bb2/keep/v4/lib/v4-core/INSTALLED" ] && echo kept || echo GONE)"; fails=$((fails + 1)); fi
# ... and a path the PROJECT has that matches the exclude is still withheld: a stale copy of it is removed, by name
printf '0xdead\n' > "$BP/fixtures/Project.hex"; printf '0xdead\n' > "$TMP/bb2/keep/fixtures/Project.hex"
BENCH_ROOT="$TMP/bb2" BENCH_EXCLUDE="*.hex *.json" "$HERE/bench.sh" keep "$BP" > "$TMP/o119" 2>&1; check "a refresh over a stale copy of a withheld file" 0 $? "$TMP/o119"
if [ ! -e "$TMP/bb2/keep/fixtures/Project.hex" ] && [ -f "$TMP/bb2/keep/fixtures/PROBE.hex" ]; then
  echo "  ok    the project's own .hex is withheld (the stale copy is gone), the bench's own PROBE.hex is kept"; else
  echo "  FAIL  withheld and kept are mixed up: Project.hex $([ -e "$TMP/bb2/keep/fixtures/Project.hex" ] && echo PRESENT || echo gone)"; fails=$((fails + 1)); fi
rm -f "$BP/fixtures/Project.hex"
# an exclude that names a DIRECTORY the project also has: the whole directory is withheld, so a file only the bench has
# inside it goes too on the next refresh. That is documented, and it is announced on every run, by name.
BENCH_ROOT="$TMP/bb2" BENCH_EXCLUDE="fixtures" "$HERE/bench.sh" wdir "$BP" > "$TMP/o131" 2>&1; check "a bench that excludes a directory the project has" 0 $? "$TMP/o131"
if grep -Eq '^bench: WARNING .*: fixtures$' "$TMP/o131"; then echo "  ok    and it warns, in one line, naming the directory"; else
  echo "  FAIL  no one-line warning naming the withheld directory:"; grep -i warn "$TMP/o131" | sed "s/^/        | /"; fails=$((fails + 1)); fi
mkdir -p "$TMP/bb2/wdir/fixtures"; printf '0x6080\n' > "$TMP/bb2/wdir/fixtures/BENCHONLY.hex"
BENCH_ROOT="$TMP/bb2" BENCH_EXCLUDE="fixtures" "$HERE/bench.sh" wdir "$BP" > "$TMP/o132" 2>&1; check "the same bench, refreshed" 0 $? "$TMP/o132"
if [ ! -e "$TMP/bb2/wdir/fixtures" ]; then echo "  ok    and the bench-only file inside it went with the directory, as the warning says"; else
  echo "  FAIL  the behaviour the warning describes did not happen (the header is now wrong)"; fails=$((fails + 1)); fi
if grep -q "WARNING" "$TMP/o117"; then echo "  FAIL  an exclude of file patterns only (*.hex *.json) warned about a directory"; fails=$((fails + 1)); else
  echo "  ok    an exclude of file patterns only does not warn"; fi
# BENCH_KEEP: a path the bench keeps across refreshes (the long fuzz's corpus/ and census/). Without it, a refresh with
# `rsync --delete` removes a directory the project does not have; with it, the bench's files survive and the project's
# own files under that path are MERGED in (added, never deleting the bench's).
mkdir -p "$TMP/bb2/two/corpus/invariant" "$TMP/bb2/two/census"
printf 'seq\n' > "$TMP/bb2/two/corpus/invariant/BENCH1.json"; printf 'run\t1\n' > "$TMP/bb2/two/census/earlier.tsv"
BENCH_ROOT="$TMP/bb2" "$HERE/bench.sh" two "$BP" > "$TMP/o150" 2>&1; check "a refresh without BENCH_KEEP" 0 $? "$TMP/o150"
if [ ! -e "$TMP/bb2/two/corpus" ]; then echo "  ok    and without BENCH_KEEP a directory only the bench has is deleted (the default, as documented)"; else
  echo "  FAIL  a bench-only corpus/ survived a refresh without BENCH_KEEP: the header's default is wrong"; fails=$((fails + 1)); fi
mkdir -p "$TMP/bb2/two/corpus/invariant" "$TMP/bb2/two/census" "$BP/corpus/invariant"
printf 'seq\n' > "$TMP/bb2/two/corpus/invariant/BENCH1.json"; printf 'run\t1\n' > "$TMP/bb2/two/census/earlier.tsv"
printf 'seq-from-project\n' > "$BP/corpus/invariant/PROJECT1.json"
BENCH_ROOT="$TMP/bb2" BENCH_KEEP="corpus census" "$HERE/bench.sh" two "$BP" > "$TMP/o151" 2>&1; check "a refresh with BENCH_KEEP=\"corpus census\"" 0 $? "$TMP/o151"
if [ -f "$TMP/bb2/two/corpus/invariant/BENCH1.json" ] && [ -f "$TMP/bb2/two/census/earlier.tsv" ] && [ -f "$TMP/bb2/two/corpus/invariant/PROJECT1.json" ]; then
  echo "  ok    the bench's corpus and census survived, and the project's corpus file was merged in"; else
  echo "  FAIL  BENCH_KEEP: BENCH1 $([ -f "$TMP/bb2/two/corpus/invariant/BENCH1.json" ] && echo kept || echo GONE), census $([ -f "$TMP/bb2/two/census/earlier.tsv" ] && echo kept || echo GONE), PROJECT1 $([ -f "$TMP/bb2/two/corpus/invariant/PROJECT1.json" ] && echo merged || echo MISSING)"; fails=$((fails + 1)); fi
rm -rf "$BP/corpus" "$TMP/bb2/two/corpus" "$TMP/bb2/two/census"

# LINK_FROM: a project with no lib/ of its own (forge-std installed elsewhere). Without LINK_FROM nothing is linked, and
# the script says so in one line; with it, <dir> becomes the bench's lib/.
NL="$TMP/nolibproj"; mkdir -p "$NL/src" "$TMP/fstd/forge-std/src"
printf '[profile.default]\n' > "$NL/foundry.toml"; printf 'contract N {}\n' > "$NL/src/N.sol"; printf '// std\n' > "$TMP/fstd/forge-std/src/Test.sol"
BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nl "$NL" > "$TMP/o152" 2>&1; check "a bench of a project with no lib/, no LINK_FROM" 0 $? "$TMP/o152"
if [ "$(grep -cF 'the project has no lib/: nothing linked; set LINK_FROM=<dir with forge-std>' "$TMP/o152")" = "1" ] && [ ! -e "$TMP/bb3/nl/lib" ]; then
  echo "  ok    and it says, in one line, that nothing was linked and how to link"; else
  echo "  FAIL  no one-line note about the missing lib/ (or a lib/ appeared):"; grep -i lib "$TMP/o152" | sed "s/^/        | /"; fails=$((fails + 1)); fi
LINK_FROM="$TMP/fstd" BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nl "$NL" > "$TMP/o153" 2>&1; check "the same bench with LINK_FROM=<dir with forge-std>" 0 $? "$TMP/o153"
if [ -L "$TMP/bb3/nl/lib" ] && [ "$(readlink "$TMP/bb3/nl/lib")" = "$(cd "$TMP/fstd" && pwd -P)" ] && [ -f "$TMP/bb3/nl/lib/forge-std/src/Test.sol" ] && [ ! -e "$NL/lib" ]; then
  echo "  ok    and <dir> is the bench's lib/ (a link), and the project is untouched"; else
  echo "  FAIL  LINK_FROM: bench lib $(readlink "$TMP/bb3/nl/lib" 2> /dev/null || echo none), project lib $([ -e "$NL/lib" ] && echo CREATED || echo absent)"; fails=$((fails + 1)); fi
LINK_FROM="$TMP/no-such-dir" BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nl2 "$NL" > "$TMP/o154" 2>&1; check "LINK_FROM naming a directory that does not exist is refused" 1 $? "$TMP/o154"
LINK_FROM="$TMP/fstd" BENCH_ROOT="$TMP/bb3" BENCH_EXCLUDE="src" "$HERE/bench.sh" nlbb "$NL" > "$TMP/o155" 2>&1; check "LINK_FROM on a bench that withholds src/" 0 $? "$TMP/o155"
if [ -d "$TMP/bb3/nlbb/lib" ] && [ ! -L "$TMP/bb3/nlbb/lib" ] && [ -f "$TMP/bb3/nlbb/lib/forge-std/src/Test.sol" ] && grep -q "isolation verified" "$TMP/o155"; then
  echo "  ok    and there <dir> is COPIED, not linked (a withholding bench holds no symlink)"; else
  echo "  FAIL  LINK_FROM on a withholding bench: lib $([ -L "$TMP/bb3/nlbb/lib" ] && echo LINK || { [ -d "$TMP/bb3/nlbb/lib" ] && echo dir || echo none; })"; fails=$((fails + 1)); fi
# the same no-lib/ bench refreshed WITHOUT LINK_FROM: its lib/ is the link the earlier LINK_FROM left, and the run must say
# so - not call it "the bench's own"
BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nl "$NL" > "$TMP/o170" 2>&1; check "a refresh without LINK_FROM of a bench an earlier LINK_FROM linked" 0 $? "$TMP/o170"
if grep -qF "bench: lib/ is a link left by an earlier LINK_FROM: $(cd "$TMP/fstd" && pwd -P)" "$TMP/o170" && ! grep -q "the bench's own" "$TMP/o170" && [ -L "$TMP/bb3/nl/lib" ]; then
  echo "  ok    and it says the lib/ is a link left by an earlier LINK_FROM, naming the target (kept)"; else
  echo "  FAIL  the leftover LINK_FROM link is not reported as such:"; grep -i 'lib/' "$TMP/o170" | sed "s/^/        | /"; fails=$((fails + 1)); fi
# no lib/, but foundry.toml already says where the dependencies are: an absolute (or ../) `libs` entry, or a remapping to
# an absolute path. Then there is nothing to link, and advising LINK_FROM sent a fresh reader looking for a directory it
# did not need (FR7: the toy on forge's defaults, forge-std through an absolute libs, the kit through a remapping).
NR="$TMP/nolib-deps"; mkdir -p "$NR/abslibs/src" "$NR/remap/src" "$NR/uplibs/src" "$NR/multiline/src" "$NR/inside/src"
printf '[profile.default]\nlibs = ["%s"]\n' "$(cd "$TMP/fstd" && pwd -P)" > "$NR/abslibs/foundry.toml"
printf '[profile.default]\nremappings = ["forge-std/=%s/forge-std/src/"]\n' "$(cd "$TMP/fstd" && pwd -P)" > "$NR/remap/foundry.toml"
printf '[profile.default]\nlibs = ["../deps"]\n' > "$NR/uplibs/foundry.toml"
printf '[profile.default]\nremappings = [\n  "a/=src/",\n  "forge-std/=%s/forge-std/src/",\n]\n' "$(cd "$TMP/fstd" && pwd -P)" > "$NR/multiline/foundry.toml"
printf '[profile.default]\nlibs = ["lib"]\nremappings = ["a/=src/"]\n' > "$NR/inside/foundry.toml"
for p in abslibs remap uplibs multiline; do
  BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" "nr-$p" "$NR/$p" > "$TMP/o181-$p" 2>&1; check "a bench of a project with no lib/ whose foundry.toml names its dependencies ($p)" 0 $? "$TMP/o181-$p"
  if [ "$(grep -cxF 'bench: no lib/; dependencies come from foundry.toml (libs / remappings): nothing to link' "$TMP/o181-$p")" = "1" ] && ! grep -q "LINK_FROM" "$TMP/o181-$p" && [ ! -e "$TMP/bb3/nr-$p/lib" ]; then
    echo "  ok    and it says the dependencies come from foundry.toml, without advising LINK_FROM"; else
    echo "  FAIL  the no-lib/ note on a project whose foundry.toml names its dependencies ($p):"; grep -i lib "$TMP/o181-$p" | sed "s/^/        | /"; fails=$((fails + 1)); fi
done
BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nr-inside "$NR/inside" > "$TMP/o182" 2>&1; check "a bench of a project with no lib/ whose libs and remappings stay inside it" 0 $? "$TMP/o182"
if grep -qF 'the project has no lib/: nothing linked; set LINK_FROM=<dir with forge-std>' "$TMP/o182" && ! grep -q "dependencies come from foundry.toml" "$TMP/o182"; then
  echo "  ok    and there it still advises LINK_FROM (nothing in foundry.toml reaches outside)"; else
  echo "  FAIL  the no-lib/ note on a project whose foundry.toml stays inside:"; grep -i lib "$TMP/o182" | sed "s/^/        | /"; fails=$((fails + 1)); fi
# ... and remappings.txt, which forge reads as well: a project whose ONLY absolute remapping is there (FR8) got the
# LINK_FROM advice. With CRLF line ends and a context-scoped line too; relative targets there still advise LINK_FROM.
mkdir -p "$NR/remaptxt/src" "$NR/remaptxt-inside/src"
printf '[profile.default]\n' > "$NR/remaptxt/foundry.toml"; printf '[profile.default]\n' > "$NR/remaptxt-inside/foundry.toml"
printf 'a/=src/\r\nsrc/:forge-std/=%s/forge-std/src/\r\n' "$(cd "$TMP/fstd" && pwd -P)" > "$NR/remaptxt/remappings.txt"
printf 'a/=src/\nb/=../b/\n' > "$NR/remaptxt-inside/remappings.txt"
BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nr-remaptxt "$NR/remaptxt" > "$TMP/o183" 2>&1; check "a bench of a project with no lib/ whose remappings.txt names an absolute target" 0 $? "$TMP/o183"
if [ "$(grep -cxF 'bench: no lib/; dependencies come from remappings.txt (an absolute remapping): nothing to link' "$TMP/o183")" = "1" ] && ! grep -q "LINK_FROM" "$TMP/o183" && [ ! -e "$TMP/bb3/nr-remaptxt/lib" ]; then
  echo "  ok    and it says the dependencies come from remappings.txt, without advising LINK_FROM"; else
  echo "  FAIL  the no-lib/ note on a project whose remappings.txt names its dependencies:"; grep -i lib "$TMP/o183" | sed "s/^/        | /"; fails=$((fails + 1)); fi
BENCH_ROOT="$TMP/bb3" "$HERE/bench.sh" nr-remaptxt-inside "$NR/remaptxt-inside" > "$TMP/o184" 2>&1; check "a bench of a project with no lib/ whose remappings.txt stays relative" 0 $? "$TMP/o184"
if grep -qF 'the project has no lib/: nothing linked; set LINK_FROM=<dir with forge-std>' "$TMP/o184" && ! grep -q "nothing to link" "$TMP/o184"; then
  echo "  ok    and there it still advises LINK_FROM (no absolute target in remappings.txt)"; else
  echo "  FAIL  the no-lib/ note on a project whose remappings.txt is relative:"; grep -i lib "$TMP/o184" | sed "s/^/        | /"; fails=$((fails + 1)); fi

# the marker: every bench this script makes holds .gauntlet-bench, a refresh keeps it, and a directory that exists
# WITHOUT it is refused - rc 1, one line, nothing touched (a reused name once let a refresh with --delete wipe a working copy)
if [ -f "$TMP/bb3/nl/.gauntlet-bench" ] && [ -f "$TMP/bb2/two/.gauntlet-bench" ] && [ -f "$TMP/bb3/nlbb/.gauntlet-bench" ]; then
  echo "  ok    every bench made above holds the .gauntlet-bench marker, after its refreshes too"; else
  echo "  FAIL  a bench has no .gauntlet-bench marker: nl $([ -f "$TMP/bb3/nl/.gauntlet-bench" ] && echo yes || echo NO), two $([ -f "$TMP/bb2/two/.gauntlet-bench" ] && echo yes || echo NO), nlbb $([ -f "$TMP/bb3/nlbb/.gauntlet-bench" ] && echo yes || echo NO)"; fails=$((fails + 1)); fi
if [ -e "$NL/.gauntlet-bench" ]; then echo "  FAIL  the marker was written into the PROJECT"; fails=$((fails + 1)); else echo "  ok    and the project holds no marker"; fi
mkdir -p "$TMP/bb4/wc/src"; printf 'work in progress\n' > "$TMP/bb4/wc/NOTES.txt"; printf 'contract W {}\n' > "$TMP/bb4/wc/src/W.sol"
BENCH_ROOT="$TMP/bb4" "$HERE/bench.sh" wc "$NL" > "$TMP/o168" 2>&1; check "a directory that exists without the marker is refused" 1 $? "$TMP/o168"
if [ "$(wc -l < "$TMP/o168" | tr -d ' ')" = "1" ] && grep -q 'gauntlet-bench' "$TMP/o168" && [ -f "$TMP/bb4/wc/NOTES.txt" ] && [ -f "$TMP/bb4/wc/src/W.sol" ] \
  && [ ! -e "$TMP/bb4/wc/.gauntlet-bench" ] && [ ! -e "$TMP/bb4/wc/src/N.sol" ]; then
  echo "  ok    in one line naming the marker, and the directory is untouched (its files kept, nothing copied, no marker written)"; else
  echo "  FAIL  the refusal is not one line, or the directory was touched:"; sed "s/^/        | /" "$TMP/o168"; ls -A "$TMP/bb4/wc" | sed "s/^/        | ls: /"; fails=$((fails + 1)); fi
BENCH_ROOT="$TMP/bb4" "$HERE/bench.sh" fresh "$NL" > "$TMP/o169" 2>&1; check "a bench under a name that did not exist" 0 $? "$TMP/o169"
if [ -f "$TMP/bb4/fresh/.gauntlet-bench" ] && [ -f "$TMP/bb4/fresh/src/N.sol" ]; then echo "  ok    and it holds the marker"; else
  echo "  FAIL  a new bench has no marker"; fails=$((fails + 1)); fi

# ================================================================= round.sh (the ROUND line, written and read back; no forge needed)
echo "== round.sh =="
RL="$TMP/round-LOG.md"; printf '# LOG\n\n## 2026-03-13 - r05 closed\n' > "$RL"
# rround [--field value]... [-- extra...]: round.sh on $RL with one good round's arguments, some of them overridden
rround() {
  local -a a=(--id r05 --phase 4 --type regression --model "vendor-a/large (1M)" --bench benches/hg-a05 --dates 2026-03-09..2026-03-12
    --high 0 --medium 1 --low 4 --info 7 --reasoned 0 --gate pass --tokens 230k --minutes 95 --files-read 41 --tests-written 6
    --report reports/r05.md --conf 0.7)
  local i
  while [ $# -ge 2 ] && [ "$1" != "--" ]; do
    for i in "${!a[@]}"; do if [ "${a[$i]}" = "$1" ]; then a[i+1]="$2"; fi; done
    shift 2
  done
  [ "${1:-}" = "--" ] && shift
  "$HERE/round.sh" "$RL" "${a[@]}" "$@"
}
want_line='ROUND r05 | phase 4 | regression | vendor-a/large (1M) | bench benches/hg-a05 | 2026-03-09..2026-03-12 | 0H 1M 4L 7I reasoned 0 | gate pass | 230k tokens, 95 min, 41 files read, 6 tests written | reports/r05.md | conf 0.7'
want_json='{"id":"r05","phase":4,"type":"regression","model":"vendor-a/large (1M)","bench":"benches/hg-a05","dates":{"start":"2026-03-09","end":"2026-03-12"},"findings":{"high":0,"medium":1,"low":4,"info":7,"reasoned_high_medium":0},"gate":"pass","cost":{"tokens":230000,"minutes":95,"files_read":41,"tests_written":6},"report":"reports/r05.md","raw_confidence":0.7}'
rround > "$TMP/o140" 2>&1; check "round.sh: a well-formed round is appended (the control)" 0 $? "$TMP/o140"
if [ "$(grep -c '^ROUND ' "$RL")" = "1" ] && [ "$(grep '^ROUND ' "$RL")" = "$want_line" ]; then echo "  ok    and LOG.md holds exactly that line"; else
  echo "  FAIL  the ROUND line in LOG.md is not the one asked for: $(grep '^ROUND ' "$RL")"; fails=$((fails + 1)); fi
"$HERE/round.sh" --json "$RL" > "$TMP/o141" 2>&1; check "round.sh --json reads it back" 0 $? "$TMP/o141"
if [ "$(cat "$TMP/o141")" = "$want_json" ]; then echo "  ok    and every field read back equals the argument it was written from"; else
  echo "  FAIL  the round trip changed a field:"; sed "s/^/        | /" "$TMP/o141"; fails=$((fails + 1)); fi
rl_hash="$(hash_of "$RL")"; rn=150
# refused <label> <the words the refusal must say> <override...>: exit 2, THAT refusal (not some other one: each case
# gets a fresh id, or every case would be refused as a duplicate of r05 and prove nothing about its own guard - a
# sabotage run of each guard found exactly that), and LOG.md byte for byte as it was
refused() {
  local label="$1" says="$2"; shift 2; rn=$((rn + 1))
  rround --id "x$rn" "$@" > "$TMP/o$rn" 2>&1; check "round.sh refuses $label" 2 $? "$TMP/o$rn"
  grep -qF -- "$says" "$TMP/o$rn" || { echo "  FAIL  and it was refused for another reason than \"$says\": $(head -1 "$TMP/o$rn")"; fails=$((fails + 1)); }
  [ "$(hash_of "$RL")" = "$rl_hash" ] || { echo "  FAIL  and yet LOG.md changed"; fails=$((fails + 1)); }
}
refused "a type that is not on the fixed list" "is not on the fixed list" --type audit
refused "a count that is not a whole number" "--medium is a whole number" --medium 1-2
refused "a negative count" "--low is a whole number" --low -1
refused "a date in the short form (not ISO in full)" "both in full" --dates 2026-03-09..03-12
refused "a day that is not in the calendar" "a real day (got '2026-02-30')" --dates 2026-02-30
refused "dates that end before they start" "ends before it starts" --dates 2026-03-12..2026-03-09
refused "a phase outside 0-8" "--phase is a whole number from 0 to 8" --phase 9
refused "a gate that is neither pass nor fail" "--gate is pass or fail" --gate green
refused "a confidence above 1" "--conf is a number from 0 to 1" --conf 1.5
refused "tokens that are not a number" "--tokens is a whole number" --tokens lots
refused "a text field with the separator in it" "--model contains '|'" --model "a | b"
refused "a text field with a newline in it" "--report contains a newline" --report "$(printf 'a\nb')"
refused "an id already in LOG.md" "already has a ROUND line for 'r05'" --id r05
refused "a required field left empty" "--model is required" --model ""
refused "an argument it does not know" "unknown argument '--frobnicate'" -- --frobnicate 1
"$HERE/round.sh" "$RL" --id r06 --phase 4 --type regression --model m --bench b --dates 2026-03-09 --gate pass --report r.md > "$TMP/o143" 2>&1
check "round.sh refuses a round with the findings left out" 2 $? "$TMP/o143"
grep -qF -- "--high is a whole number of findings, required" "$TMP/o143" || { echo "  FAIL  and not for the missing findings: $(head -1 "$TMP/o143")"; fails=$((fails + 1)); }
"$HERE/round.sh" "$TMP/no-such-LOG.md" --id r01 > "$TMP/o145" 2>&1; check "round.sh refuses a LOG.md that does not exist" 2 $? "$TMP/o145"
[ ! -e "$TMP/no-such-LOG.md" ] || { echo "  FAIL  round.sh created the missing LOG.md"; fails=$((fails + 1)); }
if [ "$(hash_of "$RL")" = "$rl_hash" ]; then echo "  ok    and after every refusal LOG.md is byte for byte what the control left"; else
  echo "  FAIL  a refusal wrote into LOG.md"; fails=$((fails + 1)); fi
rround --id r06 --conf "" --tokens "" --minutes "" --files-read "" --tests-written "" -- --dry-run > "$TMP/o146" 2>&1
check "round.sh with every optional field left out, --dry-run" 0 $? "$TMP/o146"
if grep -q '^ROUND r06 .* | gate pass | cost not measured | reports/r05.md$' "$TMP/o146" && [ "$(hash_of "$RL")" = "$rl_hash" ]; then
  echo "  ok    and it says 'cost not measured' (never a guessed zero), and --dry-run wrote nothing"; else
  echo "  FAIL  a round without cost fields was written wrongly, or --dry-run wrote:"; sed "s/^/        | /" "$TMP/o146"; fails=$((fails + 1)); fi
printf 'ROUND r09 | phase 4 | audit | m | bench b | 2026-03-09 | 0H 0M 0L 0I reasoned 0 | gate pass | cost not measured | r.md\n' >> "$RL"
"$HERE/round.sh" --json "$RL" > "$TMP/o147" 2> "$TMP/o147e"; check "round.sh --json over a ROUND line typed by hand with a bad type" 1 $? "$TMP/o147e"
if grep -q "line $(grep -n '^ROUND r09' "$RL" | cut -d: -f1) is not a ROUND line of the fixed shape (type)" "$TMP/o147e" && [ "$(cat "$TMP/o147")" = "$want_json" ]; then
  echo "  ok    and it names that line and the field, and still prints the good one"; else
  echo "  FAIL  --json did not name the bad line, or dropped the good one:"; sed "s/^/        | /" "$TMP/o147e"; fails=$((fails + 1)); fi
"$HERE/round.sh" --json "$HERE/../state/LOG.md" > "$TMP/o148" 2>&1; check "round.sh --json reads the ROUND line of the kit's example LOG.md" 0 $? "$TMP/o148"
"$HERE/round.sh" --json "$HERE/../state/README.md" > "$TMP/o149" 2>&1; check "round.sh --json reads the ROUND line documented in state/README.md" 0 $? "$TMP/o149"
if [ "$(wc -l < "$TMP/o148" | tr -d ' ')" = "1" ] && [ "$(wc -l < "$TMP/o149" | tr -d ' ')" = "1" ]; then echo "  ok    one JSON line from each"; else
  echo "  FAIL  the example files did not give one JSON line each"; fails=$((fails + 1)); fi

# ================================================================= dossier-pdf.py (the dossier's reading copy; no forge needed)
# The PDF is the auditor's reading copy of DOSSIER.md; the Markdown stays the record. What a PDF must never do is lose a
# line on the way to paper, so the check below reads the text back out of the PDF (pypdf) and looks for every line of
# the Markdown in it. The rendering needs the reportlab package and the read-back needs pypdf: the kit installs neither
# locally. Without them those cases are NOT run and the run says so, like shellcheck above: not counted as INCOMPLETE
# (the PDF is optional, the Markdown is what is handed over either way), and CI's selftest job installs both and checks
# that they ran.
echo "== dossier-pdf.py =="
DPY="$HERE/dossier-pdf.py"; DTPL="$HERE/../briefs/handoff-dossier.md"; DFIX="$FIX/dossier-wide-table.md"
DFIX_PAGES=2   # measured once (reportlab 4.4.9, 2026-09-24); a change of more than one page is a layout change to look at
lines_in_pdf() { # lines_in_pdf <md> <pdf>: 0 every line of the Markdown is in the PDF's text; 1 names the ones that are not
  python3 - "$1" "$2" << 'PY'
import re, sys
from pypdf import PdfReader
md, pdf = sys.argv[1], sys.argv[2]
# markup the renderer turns into layout, removed from both sides; letters, digits and every other sign must survive
def norm(s):
    return re.sub(r"[\s`|\\\[\]()]", "", s.replace("**", ""))
text = []
for page in PdfReader(pdf).pages:   # the footer ("... the Markdown is the record", "page N") is not the dossier's text
    text += [l for l in page.extract_text().split("\n")
             if "the Markdown is the record" not in l and not re.fullmatch(r"\s*page \d+\s*", l)]
text = norm("".join(text))
lost, fence = [], None
for n, line in enumerate(open(md, encoding="utf-8").read().replace("\r\n", "\n").split("\n"), 1):
    s = line
    m = re.match(r"^\s*(```+|~~~+)(.*)$", s)
    if m and (fence is None or m.group(1).startswith(fence)):
        fence = m.group(1) if fence is None else None
        s = m.group(2) if fence else ""        # the opening fence's language tag is text; the fences are not
    elif fence is None:
        if re.match(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$", s) or s.strip() == "---":
            continue                            # a table's separator row, a horizontal rule
        s = re.sub(r"^#+ ", "", s)
        s = re.sub(r"^\s*[-*] ", "", s)
    if norm(s) and norm(s) not in text:
        lost.append(n)
if lost:
    print("lost on the way to paper: line(s) %s of %s" % (", ".join(map(str, lost[:20])), md))
    sys.exit(1)
print("every line of %s is in the PDF's text" % md)
PY
}
if ! command -v python3 > /dev/null 2>&1; then
  echo "  --    python3 is not installed here: dossier-pdf.py NOT run on this machine (CI's selftest job runs it)"
else
  printf 'Notes with no title line.\n\n## A section\n\nSome text.\n' > "$TMP/notitle.md"
  python3 "$DPY" "$TMP/notitle.md" "$TMP/notitle.pdf" > "$TMP/o213" 2>&1; check "dossier-pdf.py: a file with no '# ' title line is not a dossier" 1 $? "$TMP/o213"
  if [ ! -e "$TMP/notitle.pdf" ]; then echo "  ok    and nothing was written"; else echo "  FAIL  a PDF was written for a file that is not a dossier"; fails=$((fails + 1)); fi
  # reportlab hidden, even where it is installed: a package of the same name first on PYTHONPATH that refuses to import
  mkdir -p "$TMP/no-reportlab/reportlab"
  printf 'raise ImportError("reportlab hidden by scripts/selftest.sh")\n' > "$TMP/no-reportlab/reportlab/__init__.py"
  PYTHONPATH="$TMP/no-reportlab" python3 "$DPY" "$DTPL" "$TMP/norl.pdf" > "$TMP/o214" 2>&1
  check "dossier-pdf.py: reportlab missing" 2 $? "$TMP/o214"
  if [ ! -e "$TMP/norl.pdf" ] && [ "$(wc -l < "$TMP/o214" | tr -d ' ')" = "1" ] && grep -q 'reportlab' "$TMP/o214"; then
    echo "  ok    one line that names reportlab, and nothing written"; else
    echo "  FAIL  not one line naming reportlab with nothing written:"; sed "s/^/        | /" "$TMP/o214"; fails=$((fails + 1)); fi
  if python3 -c 'import reportlab' > /dev/null 2>&1; then
    python3 "$DPY" "$DTPL" "$TMP/template.pdf" > "$TMP/o215" 2>&1; check "dossier-pdf.py renders the template, briefs/handoff-dossier.md" 0 $? "$TMP/o215"
    if [ -s "$TMP/template.pdf" ] && [ "$(head -c 5 "$TMP/template.pdf")" = "%PDF-" ]; then echo "  ok    and the PDF exists and is not empty"; else
      echo "  FAIL  no PDF, or an empty one, for the template"; fails=$((fails + 1)); fi
    python3 "$DPY" "$DFIX" "$TMP/fixture.pdf" > "$TMP/o216" 2>&1
    check "dossier-pdf.py renders a dossier with a wide table of long cells, code, nested lists, an HTML-comment preamble" 0 $? "$TMP/o216"
    pg216="$(sed -n 's/.* (\([0-9]*\) pages*, .*/\1/p' "$TMP/o216")"
    if [ -n "$pg216" ] && [ "$pg216" -ge $((DFIX_PAGES - 1)) ] && [ "$pg216" -le $((DFIX_PAGES + 1)) ]; then
      echo "  ok    in $pg216 page(s), $DFIX_PAGES expected (plus or minus one)"; else
      echo "  FAIL  in ${pg216:-an unstated number of} page(s), $DFIX_PAGES expected (plus or minus one)"; fails=$((fails + 1)); fi
    if python3 -c 'import pypdf' > /dev/null 2>&1; then
      lines_in_pdf "$DFIX" "$TMP/fixture.pdf" > "$TMP/o217" 2>&1; check "no line of the fixture is lost on the way to paper (read back with pypdf)" 0 $? "$TMP/o217"
      lines_in_pdf "$DTPL" "$TMP/template.pdf" > "$TMP/o218" 2>&1; check "no line of the template is lost on the way to paper" 0 $? "$TMP/o218"
      # the entry page: the dossier as an author copies it (the template from its '# {{PROJECT}}' line on) opens on "Start
      # here" and nothing else - section 0 first appears on page 2, which it can only do if "Start here" fitted on page 1
      sed -n '/^# {{PROJECT}}/,$p' "$DTPL" > "$TMP/entry.md"
      python3 "$DPY" "$TMP/entry.md" "$TMP/entry.pdf" > "$TMP/o234" 2>&1; check "dossier-pdf.py renders the template's dossier as an author copies it" 0 $? "$TMP/o234"
      python3 - "$TMP/entry.pdf" > "$TMP/o235" 2>&1 << 'PY'
import sys
from pypdf import PdfReader
pages = [pg.extract_text() for pg in PdfReader(sys.argv[1]).pages]
first = next((k for k, t in enumerate(pages) if "0. Executive summary" in t), None)
print("pages: %d; 'Start here' on page 1: %s; section 0 first on page: %s" % (len(pages), "Start here" in pages[0], None if first is None else first + 1))
sys.exit(0 if "Start here" in pages[0] and first == 1 else 1)
PY
      check "the PDF opens on the 'Start here' page: all of it on page 1, section 0 from page 2" 0 $? "$TMP/o235"
      lines_in_pdf "$TMP/entry.md" "$TMP/entry.pdf" > "$TMP/o236" 2>&1; check "and no line of it is lost on the way to paper" 0 $? "$TMP/o236"
      # the read-back seen red: the fixture with one table row taken out, rendered, is checked against the whole fixture
      grep -v '^| coverage |' "$DFIX" > "$TMP/fixture-short.md"
      python3 "$DPY" "$TMP/fixture-short.md" "$TMP/fixture-short.pdf" > /dev/null 2>&1
      lines_in_pdf "$DFIX" "$TMP/fixture-short.pdf" > "$TMP/o219" 2>&1; check "the read-back goes red on a PDF that lost a table row" 1 $? "$TMP/o219"
      if grep -q "line(s) $(grep -n '^| coverage |' "$DFIX" | cut -d: -f1) of" "$TMP/o219"; then echo "  ok    and it names that line"; else
        echo "  FAIL  it does not name the lost line:"; sed "s/^/        | /" "$TMP/o219"; fails=$((fails + 1)); fi
    else
      echo "  --    pypdf is not installed here: the no-line-lost read-back NOT run on this machine (CI's selftest job runs it)"
    fi
  else
    echo "  --    reportlab is not installed here: rendering the template and the wide-table fixture, and the no-line-lost"
    echo "        read-back, NOT run on this machine (CI's selftest job installs reportlab and pypdf and runs them)"
  fi
fi

# ================================================================= mutate.sh and size.sh (need forge and a project)
echo "== mutate.sh / size.sh =="
KIT="${KIT_PROJECT:-$HERE/../foundry-kit}"
if command -v forge > /dev/null 2>&1 && [ -e "$KIT/lib" ]; then
  export OUT_DIR="$TMP/mut"
  V="src/examples/ToyVault.sol"

  LABEL=m1 "$HERE/mutate.sh" "$KIT" "$V" "credited = post - pre;" "credited = amount;" > "$TMP/o12" 2>&1
  check "a mutant that credits the requested amount is KILLED" 0 $? "$TMP/o12"

  LABEL=m2 "$HERE/mutate.sh" "$KIT" "$V" "the sum of every credit." "the SUM of every credit." > "$TMP/o13" 2>&1
  check "a change in a comment SURVIVES, and is reported as surviving" 1 $? "$TMP/o13"

  LABEL=m3 "$HERE/mutate.sh" "$KIT" "$V" "nonReentrant" "nonReentrantX" > "$TMP/o14" 2>&1
  check "a string that matches more than once proves nothing" 2 $? "$TMP/o14"

  LABEL="m4" "$HERE/mutate.sh" "$KIT" "$V" "credited = post - pre;" "credited = post - ;" > "$TMP/o15" 2>&1   # quoted: shellcheck reads a bare m4 as the m4 command (SC2209)
  check "a mutant that does not compile proves nothing" 2 $? "$TMP/o15"

  LABEL=m5 EXPECT=green "$HERE/mutate.sh" "$KIT" "$V" "the sum of every credit." "the SUM of every credit." > "$TMP/o16" 2>&1
  check "a harmless variant PASSES under EXPECT=green" 0 $? "$TMP/o16"
  if grep -q '^ToyVault ' "$TMP/mut/m5-sizes.txt" 2> /dev/null; then echo "  ok    the variant's sizes were measured"; else
    echo "  FAIL  the variant's sizes were not measured"; fails=$((fails + 1)); fi

  LABEL=m6 EXPECT=green "$HERE/mutate.sh" "$KIT" "$V" "credited = post - pre;" "credited = amount;" > "$TMP/o17" 2>&1
  check "a broken variant FAILS under EXPECT=green" 1 $? "$TMP/o17"

  if grep -q "credited = post - pre;" "$KIT/$V"; then echo "  ok    the original was never touched"; else
    echo "  FAIL  the original was modified"; fails=$((fails + 1)); fi

  OUT_DIR="$TMP/sz" LABEL=base "$HERE/size.sh" "$KIT" ToyVault > "$TMP/o18" 2>&1; check "size of one named contract" 0 $? "$TMP/o18"
  OUT_DIR="$TMP/sz" LABEL=tight MIN_MARGIN=24576 "$HERE/size.sh" "$KIT" ToyVault > "$TMP/o19" 2>&1
  check "a margin below MIN_MARGIN fails" 1 $? "$TMP/o19"
  OUT_DIR="$TMP/sz" LABEL=ghost "$HERE/size.sh" "$KIT" NoSuchContract > "$TMP/o20" 2>&1
  check "a contract that does not exist measures nothing" 2 $? "$TMP/o20"
  unset OUT_DIR

  LABEL=m7 OUT_DIR="$TMP/mut" TEST_FLAGS="--match-contrct Typo" "$HERE/mutate.sh" "$KIT" "$V" "the sum of every credit." "the SUM of every credit." > "$TMP/o24" 2>&1
  check "a bad TEST_FLAGS makes the BASELINE red: nothing proven, never KILLED" 2 $? "$TMP/o24"
  LABEL=m8 OUT_DIR="$TMP/mut" EXPECT=green TEST_FLAGS="--match-contract NoSuchContractAnywhere" "$HERE/mutate.sh" "$KIT" "$V" "credited = post - pre;" "credited = amount;" > "$TMP/o25" 2>&1
  check "a filter that matches nothing proves nothing about a broken variant" 2 $? "$TMP/o25"

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
  check "a mutant that bricks setUp() proves nothing, and is never KILLED" 2 $? "$TMP/o35"
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
  check "a FILE whose real path leaves the copy (symlinked lib/) is refused: nothing proven" 2 $? "$TMP/o94"
  if [ "$(hash_of "$SH/X.sol")" = "$sh_before" ] && [ ! -e "$SH/X.sol.mutated" ]; then echo "  ok    and the original behind the link is unchanged (sha256 before = after)"; else
    echo "  FAIL  mutate.sh WROTE THROUGH the symlink into the original"; fails=$((fails + 1)); fi
  if grep -q "NOTHING PROVEN" "$TMP/o94" && grep -qF "$(cd -P "$SH" && pwd -P)/X.sol" "$TMP/o94"; then echo "  ok    and the refusal names the resolved path"; else
    echo "  FAIL  the refusal does not name the resolved path"; fails=$((fails + 1)); fi

  "$HERE/battery.sh" "$M" > "$TMP/o26" 2>&1; check "battery on a small green project" 0 $? "$TMP/o26"
  # the guard against the REAL forge, on the project the battery just built. The stranger's case: the sources copied in
  # again after the build (new mtime, same bytes) are FRESH. An edit is STALE - and the guard's own build has now compiled
  # it, so the edit UNDONE is a change too: STALE again (it was FRESH while the hash decided and nothing was rebuilt)
  CB="$TMP/copyback"; mkdir -p "$CB"
  cp -R "$M/src" "$M/test" "$CB/" && rm -rf "$M/src" "$M/test" && cp -R "$CB/src" "$CB/test" "$M/" && touch "$M/src/A.sol" "$M/test/A.t.sol"
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o165" 2>&1; check "freshness after the sources were copied in again (real forge): FRESH" 0 $? "$TMP/o165"
  cp "$M/src/A.sol" "$TMP/A.sol.keep"; printf '// edited after the build\n' >> "$M/src/A.sol"
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o166" 2>&1; check "freshness after an edit with no build (real forge): STALE" 1 $? "$TMP/o166"
  if grep -q '^evidence: src/A.sol changed after the last build' "$TMP/o166"; then echo "  ok    and the evidence names the edited source"; else
    echo "  FAIL  the evidence does not name src/A.sol"; fails=$((fails + 1)); fi
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o207" 2>&1; check "the guard rebuilt what it called STALE: the next run is FRESH" 0 $? "$TMP/o207"
  cp "$TMP/A.sol.keep" "$M/src/A.sol"
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o167" 2>&1; check "the edit undone after the guard rebuilt it: a change again, STALE (real forge)" 1 $? "$TMP/o167"
  # the case the content hash could not see: only the SETTINGS changed, no source touched. forge 1.8.1 recompiles on a new
  # optimizer or evm_version (measured on a toy: the runtime went from 690 to 388 bytes with the optimizer on)
  cp "$M/foundry.toml" "$TMP/mini.toml.keep"
  sed -i 's/^libs = \["lib"\]$/&\noptimizer = true/' "$M/foundry.toml"
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o208" 2>&1; check "only the optimizer turned on in foundry.toml, no source changed: STALE (real forge)" 1 $? "$TMP/o208"
  if grep -q 'not a source' "$TMP/o208"; then echo "  ok    and it says no source changed: the settings, the compiler or an artifact did"; else
    echo "  FAIL  a settings-only STALE does not say that no source changed"; fails=$((fails + 1)); fi
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o209" 2>&1; check "and rebuilt: the next run is FRESH" 0 $? "$TMP/o209"
  sed -i 's/^optimizer = true$/&\nevm_version = "shanghai"/' "$M/foundry.toml"
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o210" 2>&1; check "only evm_version changed: STALE (real forge)" 1 $? "$TMP/o210"
  cp "$TMP/mini.toml.keep" "$M/foundry.toml"
  # a build that fails, and no build at all: nothing decided
  printf 'contract {\n' >> "$M/src/A.sol"
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o211" 2>&1; check "a source that does not compile: nothing decided (real forge)" 2 $? "$TMP/o211"
  if grep -q 'Error (' "$TMP/o211"; then echo "  ok    and it prints solc's error"; else echo "  FAIL  the failed build's error is not printed"; fails=$((fails + 1)); fi
  cp "$TMP/A.sol.keep" "$M/src/A.sol"
  rm -rf "$M/out" "$M/cache"
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o212" 2>&1; check "no build at all (no out/, no cache): nothing decided, nothing built" 2 $? "$TMP/o212"
  if [ ! -e "$M/out" ]; then echo "  ok    and it did not build"; else echo "  FAIL  the guard built a project that had no build"; fails=$((fails + 1)); fi
  (cd "$M" && forge build > "$TMP/o212.build" 2>&1)
  # the fresh reader's case: a CRLF checkout, built, checked at once - forge hashed the LF text, the guard must too
  cp "$M/test/A.t.sol" "$TMP/At.sol.keep"; sed -i 's/$/\r/' "$M/src/A.sol" "$M/test/A.t.sol"
  (cd "$M" && forge build > "$TMP/o174.build" 2>&1)
  "$HERE/assert-fresh-build.sh" "$M" > "$TMP/o174" 2>&1; check "a fresh build of sources with CRLF line ends (forge's own cache): FRESH" 0 $? "$TMP/o174"
  cp "$TMP/A.sol.keep" "$M/src/A.sol"; cp "$TMP/At.sol.keep" "$M/test/A.t.sol"
  TEST_FLAGS="--match-contract NoSuchContractAnywhere" "$HERE/battery.sh" "$M" > "$TMP/o27" 2>&1
  check "battery with a filter that matches NOTHING is not a pass" 1 $? "$TMP/o27"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\ncontract Skipper is Test { function test_skipped() public { vm.skip(true); } }\n' > "$M/test/Skip.t.sol"
  "$HERE/battery.sh" "$M" > "$TMP/o28" 2>&1; check "battery with a SKIPPED test is not a pass" 1 $? "$TMP/o28"
  ALLOW_SKIPS=1 "$HERE/battery.sh" "$M" > "$TMP/o29" 2>&1; check "unless the skip is accepted on purpose" 0 $? "$TMP/o29"
  rm -f "$M/test/Skip.t.sol"

  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o30" 2>&1; check "long fuzz on a project that has the profile and a campaign" 0 $? "$TMP/o30"
  USE_BENCH=0 FOUNDRY_PROFILE=nosuchprofile "$HERE/fuzz-long.sh" "$M" > "$TMP/o31" 2>&1
  check "a profile that does not exist proves nothing" 2 $? "$TMP/o31"
  USE_BENCH=0 MATCH="--match-contract NoSuchContractAnywhere" "$HERE/fuzz-long.sh" "$M" > "$TMP/o32" 2>&1
  check "a long fuzz in which no campaign ran proves nothing" 2 $? "$TMP/o32"
  # forge FAILS and no campaign ran: a build error is not a counterexample
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../nowhere/Missing.sol";\ncontract Broken is Test { function test_b() public {} }\n' > "$M/test/Broken.t.sol"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o135" 2>&1
  check "a long fuzz whose build fails proves nothing (never a counterexample)" 2 $? "$TMP/o135"
  if grep -q "NOTHING PROVEN" "$TMP/o135" && grep -q 'first error: .*nowhere/Missing.sol' "$TMP/o135" && ! grep -q "counterexample and the seed" "$TMP/o135"; then
    echo "  ok    and it names the compile error, and says nothing about a counterexample"; else
    echo "  FAIL  fuzz-long.sh reported a build failure as something else:"; grep -E "fuzz-long|LONG FUZZ|first error" "$TMP/o135" | head -4 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -f "$M/test/Broken.t.sol"
  # USE_BENCH=1 on a project that imports from its PARENT (the v4 module's shape): the bench must hold the parent
  TL="$TMP/twolevel"; mkdir -p "$TL/src" "$TL/child/src" "$TL/child/test"
  ln -s "$(cd "$KIT/lib" && pwd -P)" "$TL/lib"; ln -s "$(cd "$KIT/lib" && pwd -P)" "$TL/child/lib"
  printf '[profile.default]\n' > "$TL/foundry.toml"
  printf 'pragma solidity ^0.8.26;\ncontract Base { uint256 public x; function inc() external { x++; } }\n' > "$TL/src/Base.sol"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\nallow_paths = ["../src"]\nremappings = ["parent/=../src/"]\n[invariant]\nruns = 4\ndepth = 4\nfail_on_revert = true\n[profile.long.invariant]\nruns = 8\ndepth = 8\nfail_on_revert = true\n' > "$TL/child/foundry.toml"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "parent/Base.sol";\ncontract ChildInvariant is Test { Base b; function setUp() public { b = new Base(); targetContract(address(b)); } function invariant_x() public view { assertGe(b.x(), 0); } }\n' > "$TL/child/test/C.t.sol"
  BENCH_ROOT="$TMP/fzb" "$HERE/fuzz-long.sh" "$TL/child" > "$TMP/o136" 2>&1
  check "USE_BENCH=1 on a project that imports from its parent: the bench holds the parent, and the campaign runs" 0 $? "$TMP/o136"
  if grep -q "the bench is of $TL" "$TMP/o136"; then echo "  ok    and it says which directory it benched"; else
    echo "  FAIL  fuzz-long.sh did not bench the parent: $(grep -E 'fuzz-long|in /' "$TMP/o136" | head -2)"; fails=$((fails + 1)); fi
  mkdir -p "$TMP/deep/a/b/c"; printf '[profile.default]\nallow_paths = ["../../../x"]\n' > "$TMP/deep/a/b/c/foundry.toml"
  BENCH_ROOT="$TMP/fzb" "$HERE/fuzz-long.sh" "$TMP/deep/a/b/c" > "$TMP/o137" 2>&1
  check "USE_BENCH=1 on a project that reaches three levels up is refused, in one line" 2 $? "$TMP/o137"
  if [ "$(grep -c "refused" "$TMP/o137")" = "1" ] && [ -z "$(find "$TMP/fzb" -maxdepth 1 -name 'fuzz-long-c-*' -print -quit 2> /dev/null)" ]; then
    echo "  ok    and no bench was made for it"; else echo "  FAIL  the deep project was benched, or refused unclearly"; fails=$((fails + 1)); fi
  # the long fuzz's corpus and census live in the BENCH: the next run's refresh must keep them (they used to be deleted by
  # `rsync --delete`, so every long run with a bench started cold), and a corpus the project has of its own is merged in
  FZ="$(find "$TMP/fzb" -maxdepth 1 -name 'fuzz-long-child-*' -print -quit 2> /dev/null)"
  if [ -n "$FZ" ] && [ -d "$FZ/child" ]; then
    mkdir -p "$FZ/child/corpus/invariant" "$FZ/child/census" "$TL/child/corpus/invariant"
    printf 'seq\n' > "$FZ/child/corpus/invariant/PLANTED.json"; printf 'run\t1\n' > "$FZ/child/census/earlier-run.tsv"
    printf 'seq-from-project\n' > "$TL/child/corpus/invariant/FROMPROJECT.json"
    BENCH_ROOT="$TMP/fzb" "$HERE/fuzz-long.sh" "$TL/child" > "$TMP/o156" 2>&1
    check "a second long fuzz in the same bench" 0 $? "$TMP/o156"
    if [ -f "$FZ/child/corpus/invariant/PLANTED.json" ] && [ -f "$FZ/child/census/earlier-run.tsv" ] && [ -f "$FZ/child/corpus/invariant/FROMPROJECT.json" ]; then
      echo "  ok    and the bench's corpus and census survived the refresh, and the project's corpus file was merged in"; else
      echo "  FAIL  fuzz-long.sh's refresh: PLANTED $([ -f "$FZ/child/corpus/invariant/PLANTED.json" ] && echo kept || echo GONE), census $([ -f "$FZ/child/census/earlier-run.tsv" ] && echo kept || echo GONE), FROMPROJECT $([ -f "$FZ/child/corpus/invariant/FROMPROJECT.json" ] && echo merged || echo MISSING)"; fails=$((fails + 1)); fi
    rm -rf "$TL/child/corpus"
  else
    echo "  FAIL  the bench of the two-level project is not where the case above left it ($TMP/fzb/fuzz-long-child-*)"; fails=$((fails + 1))
  fi

  BENCH_ROOT="$TMP/benches" "$HERE/bench.sh" bb "$M" > "$TMP/o33" 2>&1; check "an ordinary bench" 0 $? "$TMP/o33"
  BENCH_ROOT="$TMP/benches" BENCH_EXCLUDE="src" "$HERE/bench.sh" bb "$M" > "$TMP/o34" 2>&1
  check "a black-box bench over a bench of the same name" 0 $? "$TMP/o34"
  if [ ! -e "$TMP/benches/bb/src" ] && [ -z "$(find "$TMP/benches/bb" -type l -print -quit)" ]; then
    echo "  ok    the withheld directory is really gone, and nothing in the bench links out of it"
  else
    echo "  FAIL  the black-box bench still holds src/ or a symlink"; fails=$((fails + 1))
  fi

  # ---- bench.sh must never delete what it was asked to copy. Each case counts the project's files afterwards.
  WS="$TMP/ws"; mkdir -p "$WS/myhook/src" "$WS/myhook/script"
  printf 'contract H {}\n' > "$WS/myhook/src/H.sol"; printf '// deploy\n' > "$WS/myhook/script/D.sol"; printf '[profile.default]\n' > "$WS/myhook/foundry.toml"
  BENCH_ROOT="$WS" BENCH_EXCLUDE="script" "$HERE/bench.sh" myhook "$WS/myhook" > "$TMP/o40" 2>&1
  check "a bench that IS the project is refused" 1 $? "$TMP/o40"
  BENCH_ROOT="$WS/myhook/benches" BENCH_EXCLUDE="script" "$HERE/bench.sh" inner "$WS/myhook" > "$TMP/o41" 2>&1
  check "a bench INSIDE the project is refused" 1 $? "$TMP/o41"
  mkdir -p "$WS/outer/proj/src"; printf 'contract P {}\n' > "$WS/outer/proj/src/P.sol"
  BENCH_ROOT="$WS" BENCH_EXCLUDE="script" "$HERE/bench.sh" outer "$WS/outer/proj" > "$TMP/o42" 2>&1
  check "a bench that CONTAINS the project is refused" 1 $? "$TMP/o42"
  BENCH_ROOT="$WS/benches" "$HERE/bench.sh" . "$WS/myhook" > "$TMP/o43" 2>&1; check "'.' is not a bench name" 1 $? "$TMP/o43"
  BENCH_ROOT="$WS/benches" "$HERE/bench.sh" .. "$WS/myhook" > "$TMP/o44" 2>&1; check "'..' is not a bench name" 1 $? "$TMP/o44"
  # the same refusals by the routes a path can be DISGUISED: a `..` after a component that does not exist yet (the guard
  # used to compare it as text, then mkdir made it real, and src/ was overwritten), a RELATIVE root that does not exist
  # yet (it lost a slash and compared "<cwd>benches"), a root reached through a symlink, and a bench NAME that is
  # itself a link to the project.
  BENCH_ROOT="$WS/ghost/../myhook" BENCH_EXCLUDE="script" "$HERE/bench.sh" src "$WS/myhook" > "$TMP/o70" 2>&1
  check "a BENCH_ROOT with '..' in it is refused" 1 $? "$TMP/o70"
  (cd "$WS/myhook" && BENCH_ROOT="benchesrel" BENCH_EXCLUDE="script" "$HERE/bench.sh" c3 . > "$TMP/o71" 2>&1)
  check "a RELATIVE bench root inside the project is refused the FIRST time too" 1 $? "$TMP/o71"
  ln -s "$WS/myhook" "$WS/alias"
  BENCH_ROOT="$WS/alias/benches2" BENCH_EXCLUDE="script" "$HERE/bench.sh" viaLink "$WS/myhook" > "$TMP/o72" 2>&1
  check "a bench root that reaches the project through a symlink is refused" 1 $? "$TMP/o72"
  mkdir -p "$WS/benches"; ln -s "$WS/myhook" "$WS/benches/namelink"
  BENCH_ROOT="$WS/benches" BENCH_EXCLUDE="script" "$HERE/bench.sh" namelink "$WS/myhook" > "$TMP/o73" 2>&1
  check "a bench NAME that is a link to the project is refused" 1 $? "$TMP/o73"
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
  check "a black-box bench whose lib/ links back into the project is refused" 1 $? "$TMP/o45"
  if [ -z "$(find "$WS/benches" -name Secret.sol -print -quit 2> /dev/null)" ]; then echo "  ok    and the withheld file is nowhere in the benches"; else
    echo "  FAIL  the withheld file reached a bench through lib/"; fails=$((fails + 1)); fi

  # ... and the FINAL verification has to be seen refusing too: a link anywhere else in the project survives the copy
  mkdir -p "$WS/linky/src" "$WS/elsewhere"; printf 'contract L {}\n' > "$WS/linky/src/L.sol"
  printf '[profile.default]\n' > "$WS/linky/foundry.toml"; ln -s "$WS/elsewhere" "$WS/linky/shortcut"
  BENCH_ROOT="$WS/benches" BENCH_EXCLUDE="src" "$HERE/bench.sh" linky "$WS/linky" > "$TMP/o39" 2>&1
  check "a black-box bench that still holds a symlink is not handed over" 1 $? "$TMP/o39"

  # ---- mutate.sh: the two halves of "KILLED means a test went red BECAUSE of the mutant", each seen red alone
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\ncontract AlwaysRed is Test { function test_red() public pure { assertEq(uint256(1), 2); } }\n' > "$M/test/Red.t.sol"
  # the change is harmless AND compiles (A.sol is one line: a trailing `//` comment would swallow the rest of it, the
  # mutant would not build, and this case would answer 2 for that reason instead - it did, and a sabotage run caught it)
  LABEL=m9 OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$M" src/A.sol "uint256 public x;" "uint256 public x; uint256 public y;" > "$TMP/o46" 2>&1
  check "a baseline with a red test: nothing proven, never KILLED" 2 $? "$TMP/o46"
  if grep -q "UNCHANGED code does not pass" "$TMP/o46"; then echo "  ok    and it is the BASELINE that was refused, not the mutant"; else
    echo "  FAIL  the case answered 2 for some other reason: $(tail -1 "$TMP/o46")"; fails=$((fails + 1)); fi
  LABEL=m10 OUT_DIR="$TMP/mut" EXPECT=green BASELINE_MAY_BE_RED=1 \
    "$HERE/mutate.sh" "$M" test/Red.t.sol "assertEq(uint256(1), 2);" "assertEq(uint256(2), 2);" > "$TMP/o47" 2>&1
  check "regression test first: a red baseline is accepted on request, and the fix must be all green" 0 $? "$TMP/o47"
  LABEL=m11 OUT_DIR="$TMP/mut" EXPECT=green BASELINE_MAY_BE_RED=1 \
    "$HERE/mutate.sh" "$M" test/Red.t.sol "assertEq(uint256(1), 2);" "assertEq(uint256(1), 3);" > "$TMP/o48" 2>&1
  check "and a 'fix' that leaves it red FAILS" 1 $? "$TMP/o48"
  # the exception has TWO conditions, and each has to be seen refusing alone: without the variable a red baseline proves
  # nothing under EXPECT=green, and WITH it a mutant (EXPECT=red) over a red baseline must never come out KILLED
  LABEL=m14 OUT_DIR="$TMP/mut" EXPECT=green \
    "$HERE/mutate.sh" "$M" test/Red.t.sol "assertEq(uint256(1), 2);" "assertEq(uint256(2), 2);" > "$TMP/o74" 2>&1
  check "EXPECT=green over a red baseline WITHOUT the variable proves nothing" 2 $? "$TMP/o74"
  LABEL=m15 OUT_DIR="$TMP/mut" BASELINE_MAY_BE_RED=1 \
    "$HERE/mutate.sh" "$M" src/A.sol "x++;" "x += 2;" > "$TMP/o75" 2>&1
  check "BASELINE_MAY_BE_RED does not apply to a mutant: red baseline, nothing proven, never KILLED" 2 $? "$TMP/o75"
  rm -f "$M/test/Red.t.sol"

  LABEL=m12 OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$M" src/A.sol "x++;" "x += 2;" > "$TMP/o49" 2>&1
  check "a real mutant on the small project is KILLED" 0 $? "$TMP/o49"
  if grep -q "KILLED - 1 test(s) went red" "$TMP/o49"; then echo "  ok    and ONE failing test is counted as one (forge prints it twice)"; else
    echo "  FAIL  the number of failing tests is wrong: $(grep KILLED "$TMP/o49" | head -1)"; fails=$((fails + 1)); fi

  # a forge that dies on the MUTANT without any test failing (a crash, not a verdict). The shim lets the two baseline
  # commands and the mutant's build through, and kills the second `forge test`.
  SHIM="$TMP/shim"; mkdir -p "$SHIM"; REAL_FORGE="$(command -v forge)"
  printf '#!/usr/bin/env bash\nif [ "$1" = "test" ]; then n=$(cat "%s/n" 2> /dev/null || echo 0); n=$((n + 1)); echo "$n" > "%s/n"; if [ "$n" -ge 2 ]; then echo "forge: simulated crash"; exit 1; fi; fi\nexec "%s" "$@"\n' "$SHIM" "$SHIM" "$REAL_FORGE" > "$SHIM/forge"
  chmod +x "$SHIM/forge"
  PATH="$SHIM:$PATH" LABEL=m13 OUT_DIR="$TMP/mut" "$HERE/mutate.sh" "$M" src/A.sol "x++;" "x += 2;" > "$TMP/o50" 2>&1
  check "forge failing on the mutant with NO failing test is not a kill" 2 $? "$TMP/o50"

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
  check "a 'long' profile with no invariant budget of its own proves nothing" 2 $? "$TMP/o51"
  cp "$TMP/toml.keep" "$M/foundry.toml"
  USE_BENCH=0 RUNS=1 DEPTH=1 "$HERE/fuzz-long.sh" "$M" > "$TMP/o52" 2>&1
  check "RUNS and DEPTH cannot shrink the long fuzz below the everyday budget" 2 $? "$TMP/o52"
  # both refusals are ACTIONABLE: they print the everyday budget they measured and a block to paste computed from it
  # (runs = 4 x the everyday runs, at least 1000; depth = the everyday depth). $M's everyday budget is 4 x 4.
  if grep -qF "which here is" "$TMP/o31" && grep -qF "4 x 4 = 16 calls" "$TMP/o31" && grep -qx '\[profile.nosuchprofile.invariant\]' "$TMP/o31" \
    && grep -qx 'runs = 1000' "$TMP/o31" && grep -qx 'depth = 4' "$TMP/o31" && grep -qx 'corpus_dir = "corpus/long"' "$TMP/o31"; then
    echo "  ok    the missing-profile refusal prints the everyday budget and the block to paste"; else
    echo "  FAIL  the missing-profile refusal is not actionable:"; grep -A8 "does not exist" "$TMP/o31" | head -10 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  if grep -qF "4 x 4 = 16 calls" "$TMP/o52" && grep -qx '\[profile.long.invariant\]' "$TMP/o52" && grep -qx 'runs = 1000' "$TMP/o52" \
    && grep -qx 'depth = 4' "$TMP/o52" && grep -qx 'fail_on_revert = true' "$TMP/o52" && grep -qF "must be LARGER than YOUR everyday one" "$TMP/o52"; then
    echo "  ok    the budget refusal prints the everyday budget, the rule and the block to paste"; else
    echo "  FAIL  the budget refusal is not actionable:"; grep -A8 "not larger" "$TMP/o52" | head -10 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # forge's DEFAULT everyday budget (no [invariant] section: 256 x 500 = 128 000) against the kit's 1000 x 128: refused,
  # and the block says 1024 x 500 - the fresh reader's case, where no document said what to pick
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n[profile.long.invariant]\nruns = 1000\ndepth = 128\nfail_on_revert = true\n' > "$M/foundry.toml"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o176" 2>&1
  check "forge's default everyday budget (256 x 500) against a long profile of 1000 x 128: refused" 2 $? "$TMP/o176"
  if grep -qF "256 x 500 = 128000 calls" "$TMP/o176" && grep -qx 'runs = 1024' "$TMP/o176" && grep -qx 'depth = 500' "$TMP/o176" && ! grep -q "Ran [0-9]* test" "$TMP/o176"; then
    echo "  ok    and the block it prints is 1024 x 500, computed from forge's defaults, before any campaign ran"; else
    echo "  FAIL  the refusal on forge's defaults does not print 1024 x 500:"; grep -A8 "not larger" "$TMP/o176" | head -10 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # the block, pasted as printed into a project with no long profile, gives a long fuzz that runs and passes
  printf '[profile.default]\nsrc = "src"\ntest = "test"\nlibs = ["lib"]\n[invariant]\nruns = 4\ndepth = 4\nfail_on_revert = true\n' > "$M/foundry.toml"
  sed -n '/^\[profile\.nosuchprofile\.invariant\]$/,/^corpus_dir = /p' "$TMP/o31" | sed 's/nosuchprofile/long/' >> "$M/foundry.toml"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o177" 2>&1
  check "the printed block, pasted as is: the long fuzz runs and passes" 0 $? "$TMP/o177"
  if grep -qF "4000 under 'long', 16 under the default profile" "$TMP/o177"; then echo "  ok    and the budget it ran under is the block's (1000 x 4)"; else
    echo "  FAIL  the pasted block was not the budget that ran: $(grep 'invariant budget' "$TMP/o177")"; fails=$((fails + 1)); fi
  cp "$TMP/toml.keep" "$M/foundry.toml"; rm -rf "$M/corpus"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\ncontract SkippedInvariant is Test { function setUp() public { vm.skip(true); } function invariant_never_runs() public pure { assertTrue(true); } }\n' > "$M/test/SkipInv.t.sol"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o53" 2>&1
  check "a campaign that SKIPPED itself next to one that ran is not a pass" 2 $? "$TMP/o53"
  rm -f "$M/test/SkipInv.t.sol"
  # the budget that was READ is not the budget that RAN when a test carries its own inline configuration
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/A.sol";\ncontract InlineInvariant is Test { A a; function setUp() public { a = new A(); targetContract(address(a)); }\n/// forge-config: long.invariant.runs = 1\n/// forge-config: long.invariant.depth = 1\nfunction invariant_inline() public view { assertGe(a.x(), 0); } }\n' > "$M/test/Inline.t.sol"
  USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o76" 2>&1
  check "a campaign that RAN less than the long budget (inline config) is not a long fuzz" 2 $? "$TMP/o76"
  rm -f "$M/test/Inline.t.sol"
  V4_MANAGER=source USE_BENCH=0 "$HERE/fuzz-long.sh" "$M" > "$TMP/o77" 2>&1; check "long fuzz with V4_MANAGER set" 0 $? "$TMP/o77"
  if [ -d "$M/corpus/invariant-source" ]; then echo "  ok    and forge really wrote the corpus into the manager's own directory"; else
    echo "  FAIL  fuzz-long.sh: V4_MANAGER did not move the corpus"; fails=$((fails + 1)); fi
  # cases share $M: leave no fuzz state behind for the next one to inherit
  rm -rf "$M/corpus" "$M/cache/invariant" "$M/census"

  # ---- battery.sh: one corpus per manager
  V4_MANAGER=fixture "$HERE/battery.sh" "$M" > "$TMP/o54" 2>&1; check "battery with V4_MANAGER set" 0 $? "$TMP/o54"
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
  "$HERE/sim-report.sh" "$SR" > "$TMP/o90" 2>&1; check "sim-report over two runs and a broken line" 0 $? "$TMP/o90"
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
  "$HERE/sim-report.sh" "$SG" > "$TMP/o92" 2>&1; check "sim-report over priced and mixed runs" 0 $? "$TMP/o92"
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
  "$HERE/sim-report.sh" "$SQ" > "$TMP/o93" 2>&1; check "sim-report over runs with and without refusals at quote" 0 $? "$TMP/o93"
  if grep -Eq '^atq +arb +2 +40\.0 +30\.0 +2\.0 +4 +1 +3 +9000 +-6 +2 +30 +-36 +2 +6\.0$' "$TMP/o93" && grep -Eq '^atqmix +arb +2 +40\.0 +30\.0 +2\.0 +4 +1 +3 +9000 +-6 +2 +30 +-36 +1 +8\.0$' "$TMP/o93" && grep -q "atqmix arb: atQuote/run is over 1 runs of 2" "$TMP/o93" && grep -q "1 line(s) from a ledger without the atQuote column" "$TMP/o93" && ! grep -q "atq arb: atQuote/run is over" "$TMP/o93"; then
    echo "  ok    and the refused-at-quote mean, its run count and the mixed-group note are right"
  else
    echo "  FAIL  sim-report refused-at-quote arithmetic is wrong:"; sed "s/^/        | /" "$TMP/o93"; fails=$((fails + 1))
  fi
  : > "$TMP/empty.tsv"; "$HERE/sim-report.sh" "$TMP/empty.tsv" > "$TMP/o91" 2>&1; check "an empty ledger measured nothing" 2 $? "$TMP/o91"

  # ---- census.sh: the arithmetic on a file written by hand, then end to end on the kit's own example
  C="$TMP/census.tsv"
  printf 'Toy\tU=0\tA:deposit=5/4\tA:withdraw=3/0\tB:whole credit=1\n' > "$C"
  printf 'Toy\tU=0\tA:deposit=6/6\tA:withdraw=2/1\n' >> "$C"
  printf 'Toy\tU=0\tA:deposit=1/0\tA:set=x=1/1\tB:whole credit=2\n' >> "$C"
  OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C" > "$TMP/o55" 2>&1; check "census of three hand-written runs with no floor named is NOTHING JUDGED, not a pass" 2 $? "$TMP/o55"
  if grep -q '^census gate: NOTHING JUDGED - CORE and REACH are both empty' "$TMP/o55"; then
    echo "  ok    and the last line says so"
  else
    echo "  FAIL  the empty-floor gate did not say NOTHING JUDGED"; fails=$((fails+1)); sed 's/^/          | /' "$TMP/o55" | tail -n 4
  fi
  if grep -Eq '^withdraw +5 +1 +1 +2$' "$TMP/o55" && grep -Eq '^deposit +12 +10 +2 +1$' "$TMP/o55" \
    && grep -Eq '^whole credit +2 +3$' "$TMP/o55" && grep -Eq '^set=x +1 +1 +1 +2$' "$TMP/o55"; then
    echo "  ok    and the sums are right (an action missing from a run counts as zero successes in it)"
  else
    echo "  FAIL  the census arithmetic is wrong:"; sed "s/^/        | /" "$TMP/o55"; fails=$((fails + 1))
  fi
  CORE="withdraw" MIN_PCT=50 OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C" > "$TMP/o56" 2>&1; check "a CORE action that worked in 1 run of 3 is below a floor of 50" 1 $? "$TMP/o56"
  CORE="deposit" MIN_PCT=50 OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C" > "$TMP/o57" 2>&1; check "a CORE action that worked in 2 runs of 3 is above it" 0 $? "$TMP/o57"
  CORE="withdraw" OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C" > "$TMP/o57b" 2>&1; check "and the default floor (25) lets 1 run of 3 through" 0 $? "$TMP/o57b"
  CORE="nosuchaction" OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C" > "$TMP/o58" 2>&1; check "a CORE action that never ran at all" 1 $? "$TMP/o58"
  printf 'Toy\tU=2\tA:deposit=1/1\n' >> "$C"
  OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C" > "$TMP/o59" 2>&1; check "a run with an unexplained revert fails the census" 1 $? "$TMP/o59"
  : > "$TMP/empty.tsv"; OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$TMP/empty.tsv" > "$TMP/o60" 2>&1; check "an empty census measured nothing" 2 $? "$TMP/o60"

  # CORE is judged PER SUITE: an action that is dead in one suite must not be rescued by a namesake in another
  C2="$TMP/census2.tsv"
  printf 'Vault\tU=0\tA:deposit=2/2\tB:whole credit=1\nVault\tU=0\tA:deposit=3/3\n' > "$C2"
  printf 'Hook\tU=0\tA:deposit=4/0\nHook\tU=0\tA:deposit=1/0\nHook\tU=0\tA:deposit=2/0\n' >> "$C2"
  CORE="deposit" OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o79" 2>&1; check "a CORE action dead in ONE suite fails, whatever its namesake did" 1 $? "$TMP/o79"
  CORE="deposit" MIN_PCT=lots OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o80" 2>&1; check "a floor that is not a number is refused" 2 $? "$TMP/o80"
  CORE="deposit" MIN_PCT=0 OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o81" 2>&1; check "a floor of zero is refused: it would pass an action that never worked" 2 $? "$TMP/o81"
  REACH="whole credit" MIN_PCT=50 OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o82" 2>&1; check "a REACH boundary met in 1 run of 2 is at a floor of 50" 0 $? "$TMP/o82"
  REACH="whole credit" MIN_PCT=51 OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o83" 2>&1; check "and below a floor of 51" 1 $? "$TMP/o83"
  REACH="the cap" OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o84" 2>&1; check "a REACH boundary that is in no suite at all" 1 $? "$TMP/o84"
  printf 'Vault\tU=0\tA:broken\tfield=3/1\tA:deposit=1/1\n' >> "$C2"
  OUT_DIR="$TMP/gate" "$HERE/census.sh" --aggregate "$C2" > "$TMP/o85" 2>&1
  if grep -q "2 field(s) ignored" "$TMP/o85"; then echo "  ok    a field the census cannot read is counted out loud, not dropped"; else
    echo "  FAIL  malformed census fields were ignored in silence"; fails=$((fails + 1)); fi
  # ---- the GATE (--aggregate) leaves a record and says its verdict: <OUT_DIR>/06-census-gate.txt holds the table and the
  # verdict, and the last line printed is that verdict. It used to write nothing and print nothing on a pass (rc 0 only).
  gate_last() { tail -n 1 "$1" | tr -d '\r'; }
  gate_ok() { # gate_ok <label> <output> <record>: the record exists, holds the table, and ends in the same verdict as the output
    if [ -f "$3" ] && grep -Eq '^== campaign census: ' "$3" && [ "$(gate_last "$3")" = "$(gate_last "$2")" ]; then
      echo "  ok    $1: the record holds the table and ends in the verdict printed"; else
      echo "  FAIL  $1: record $([ -f "$3" ] && echo "ends in '$(gate_last "$3")'" || echo MISSING), output ends in '$(gate_last "$2")'"; fails=$((fails + 1)); fi
  }
  C3="$TMP/census3.tsv"
  printf 'Toy\tU=0\tA:deposit=5/4\tA:withdraw=3/0\tB:whole credit=1\nToy\tU=0\tA:deposit=6/6\tA:withdraw=2/1\nToy\tU=0\tA:deposit=1/0\tB:whole credit=2\n' > "$C3"
  CORE="deposit withdraw" REACH="whole credit" MIN_PCT=30 OUT_DIR="$TMP/g183" "$HERE/census.sh" --aggregate "$C3" > "$TMP/o183" 2>&1
  check "the gate passes: 2 CORE actions and 1 REACH boundary at or above 30%" 0 $? "$TMP/o183"
  if [ "$(gate_last "$TMP/o183")" = "census gate: PASSED - 2 CORE actions and 1 REACH boundaries at or above 30%" ]; then
    echo "  ok    and its last line says so"; else echo "  FAIL  the passing gate's last line: '$(gate_last "$TMP/o183")'"; fails=$((fails + 1)); fi
  gate_ok "a passing gate" "$TMP/o183" "$TMP/g183/06-census-gate.txt"
  CORE="deposit withdraw" MIN_PCT=50 OUT_DIR="$TMP/g184" "$HERE/census.sh" --aggregate "$C3" > "$TMP/o184" 2>&1
  check "the gate fails: a CORE action below a floor of 50" 1 $? "$TMP/o184"
  l184="$(gate_last "$TMP/o184")"
  case "$l184" in "census gate: FAILED - "*'"withdraw"'*"50%"*) echo "  ok    and its last line names the action and the floor";; *)
    echo "  FAIL  the failing gate's last line does not name the action and the floor: '$l184'"; fails=$((fails + 1));; esac
  case "$l184" in *'"deposit"'*) echo "  FAIL  and it names deposit, which met the floor: '$l184'"; fails=$((fails + 1));; esac
  gate_ok "a gate failed on a CORE floor" "$TMP/o184" "$TMP/g184/06-census-gate.txt"
  REACH="whole credit" MIN_PCT=70 OUT_DIR="$TMP/g185" "$HERE/census.sh" --aggregate "$C3" > "$TMP/o185" 2>&1
  check "the gate fails: a REACH boundary below a floor of 70" 1 $? "$TMP/o185"
  case "$(gate_last "$TMP/o185")" in "census gate: FAILED - "*'"whole credit"'*"70%"*) echo "  ok    and its last line names the boundary and the floor";; *)
    echo "  FAIL  the failing gate's last line does not name the boundary and the floor: '$(gate_last "$TMP/o185")'"; fails=$((fails + 1));; esac
  gate_ok "a gate failed on a REACH floor" "$TMP/o185" "$TMP/g185/06-census-gate.txt"
  { cat "$C3"; printf 'Toy\tU=2\tA:deposit=1/1\n'; } > "$TMP/census3u.tsv"
  CORE="deposit" OUT_DIR="$TMP/g186" "$HERE/census.sh" --aggregate "$TMP/census3u.tsv" > "$TMP/o186" 2>&1
  check "the gate fails: a run met an unexplained revert" 1 $? "$TMP/o186"
  case "$(gate_last "$TMP/o186")" in "census gate: FAILED - "*"UNEXPLAINED"*) echo "  ok    and its last line says why";; *)
    echo "  FAIL  the gate failed on an unexplained revert says: '$(gate_last "$TMP/o186")'"; fails=$((fails + 1));; esac
  OUT_DIR="$TMP/g187" "$HERE/census.sh" --aggregate "$TMP/empty.tsv" > "$TMP/o187" 2>&1
  check "the gate over an empty census: nothing measured" 2 $? "$TMP/o187"
  if [ "$(gate_last "$TMP/o187")" = "census gate: FAILED - NOTHING MEASURED: $TMP/empty.tsv is empty or missing" ] \
    && [ "$(gate_last "$TMP/g187/06-census-gate.txt" 2> /dev/null)" = "$(gate_last "$TMP/o187")" ]; then
    echo "  ok    and its last line and its record say NOTHING MEASURED"; else
    echo "  FAIL  the gate over an empty census: output '$(gate_last "$TMP/o187")', record '$(gate_last "$TMP/g187/06-census-gate.txt" 2> /dev/null)'"; fails=$((fails + 1)); fi
  if [ "$(gate_last "$TMP/o80")" = "census gate: FAILED - MIN_PCT must be a whole number from 1 to 100 (got 'lots'). NOTHING MEASURED." ]; then
    echo "  ok    a floor the gate refuses is its verdict too"; else echo "  FAIL  the refused floor's last line: '$(gate_last "$TMP/o80")'"; fails=$((fails + 1)); fi
  # where the record goes, resolved as run mode resolves it: OUT_DIR (relative to the project), else <project>/.gauntlet/
  # reports - and with no project given the project is the directory it ran from, which is NOT the bench the tsv is in,
  # so the gate says where it wrote
  mkdir -p "$TMP/gbench/census" "$TMP/gcwd" "$TMP/gproj"; cp "$C3" "$TMP/gbench/census/long.tsv"
  (cd "$TMP/gcwd" && env -u OUT_DIR CORE="deposit" "$HERE/census.sh" --aggregate "$TMP/gbench/census/long.tsv") > "$TMP/o188" 2>&1
  check "the gate with no project and no OUT_DIR, the tsv in another directory" 0 $? "$TMP/o188"
  g188="$(cd "$TMP/gcwd" && pwd -P)/.gauntlet/reports/06-census-gate.txt"
  if grep -qxF "census gate: record written to $g188 (the census is in $(cd "$TMP/gbench/census" && pwd -P); give the project as the third argument to write it there)" "$TMP/o188"; then
    echo "  ok    and it says where it wrote, and that the census lives elsewhere"; else
    echo "  FAIL  the gate does not say where it wrote:"; grep -a "census gate" "$TMP/o188" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  gate_ok "the record of a gate run with no project" "$TMP/o188" "$g188"
  env -u OUT_DIR CORE="deposit" "$HERE/census.sh" --aggregate "$TMP/gbench/census/long.tsv" "$TMP/gproj" > "$TMP/o189" 2>&1
  check "the gate with the project given as the third argument" 0 $? "$TMP/o189"
  gate_ok "the record in the project given" "$TMP/o189" "$TMP/gproj/.gauntlet/reports/06-census-gate.txt"
  CORE="deposit" OUT_DIR="rel-reports" "$HERE/census.sh" --aggregate "$TMP/gbench/census/long.tsv" "$TMP/gproj" > "$TMP/o190" 2>&1
  check "the gate with a relative OUT_DIR and a project" 0 $? "$TMP/o190"
  gate_ok "a relative OUT_DIR is under the project, as in run mode" "$TMP/o190" "$TMP/gproj/rel-reports/06-census-gate.txt"
  "$HERE/census.sh" "$M" > "$TMP/o61" 2>&1; check "a suite that never calls writeCensus measured nothing" 2 $? "$TMP/o61"

  K="$TMP/kitcopy"; mkdir -p "$K"; cp -R "$KIT/src" "$KIT/test" "$KIT/foundry.toml" "$K/"; ln -s "$(cd "$KIT/lib" && pwd -P)" "$K/lib"
  # a census file left over from an EARLIER campaign, with a surprise in it: the script has to start from an empty file
  mkdir -p "$K/census"; printf 'ToyVault\tU=5\tA:deposit=1/1\n' > "$K/census/runs.tsv"; cp "$K/census/runs.tsv" "$K/census/long.tsv"
  # This case proves the PLUMBING, not the vault, so a fuzz draw must not be able to fail it: the seed is pinned, and the
  # floor sits far below the measured range (withdraw succeeded in 35 % of runs on 2026-09-23 with forge 1.8.1; a floor
  # of 25 failed on the CI runner by luck - the very gate census.sh's own header warns against). On failure the table is
  # pasted, so the next red is readable without the file.
  MATCH="--match-contract ToyVaultInvariants" CORE="deposit withdraw" MIN_PCT=10 FOUNDRY_FUZZ_SEED=0x6b6974 "$HERE/census.sh" "$K" > "$TMP/o62" 2>&1; rc62=$?
  check "end to end: the kit's own vault campaign writes a census, and its core actions are above the floor" 0 $rc62 "$TMP/o62"
  if [ "$rc62" -ne 0 ]; then grep -E "^==|^deposit|^withdraw|floor|FAILED|measured" "$TMP/o62" | head -12 | sed "s/^/        | /"; fi
  if grep -Eq '^== campaign census: ToyVault - [0-9]+ runs ==$' "$TMP/o62"; then echo "  ok    one line per run reached the file"; else
    echo "  FAIL  no census table came out of the kit's own campaign"; tail -5 "$TMP/o62" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # run mode is the smoke check, not the gate: it keeps its 06-census.txt and writes no gate record, prints no gate verdict
  if [ -s "$K/.gauntlet/reports/06-census.txt" ] && [ ! -e "$K/.gauntlet/reports/06-census-gate.txt" ] && ! grep -aq '^census gate:' "$TMP/o62"; then
    echo "  ok    and run mode keeps 06-census.txt, with no gate record and no gate verdict"; else
    echo "  FAIL  run mode's report: 06-census.txt $([ -s "$K/.gauntlet/reports/06-census.txt" ] && echo there || echo MISSING), gate record $([ -e "$K/.gauntlet/reports/06-census-gate.txt" ] && echo WRITTEN || echo absent), verdict line $(grep -ac '^census gate:' "$TMP/o62")"; fails=$((fails + 1)); fi
  # ... and a SECOND draw, with a different pinned seed, over the same floor: one seed that clears the floor could be the
  # lucky one; two different draws that both clear it are the guard against that. The two tables must differ, or the
  # seed was not what chose the draw.
  MATCH="--match-contract ToyVaultInvariants" CORE="deposit withdraw" MIN_PCT=10 FOUNDRY_FUZZ_SEED=0x4b33 "$HERE/census.sh" "$K" > "$TMP/o133" 2>&1; rc133=$?
  check "end to end, a second draw (another pinned seed): the core actions are above the floor too" 0 $rc133 "$TMP/o133"
  if [ "$rc133" -ne 0 ]; then grep -E "^==|^deposit|^withdraw|floor|FAILED|measured" "$TMP/o133" | head -12 | sed "s/^/        | /"; fi
  w62="$(grep -E '^withdraw ' "$TMP/o62")"; w133="$(grep -E '^withdraw ' "$TMP/o133")"
  echo "          withdraw, seed 0x6b6974: ${w62:-none}"; echo "          withdraw, seed 0x4b33  : ${w133:-none}"
  if [ -n "$w62" ] && [ -n "$w133" ] && ! cmp -s <(grep -E '^(deposit|withdraw) ' "$TMP/o62") <(grep -E '^(deposit|withdraw) ' "$TMP/o133"); then
    echo "  ok    and the two draws are different draws (their tables differ)"; else
    echo "  FAIL  the two seeds gave the same table, or no table: the second run is not a second draw"; fails=$((fails + 1)); fi
  # the long fuzz starts from an empty census too (65 x 64 is just above the everyday 64 x 64, so it counts as "long")
  USE_BENCH=0 RUNS=65 DEPTH=64 MATCH="--match-contract ToyVaultInvariants" "$HERE/fuzz-long.sh" "$K" > "$TMP/o86" 2>&1
  check "long fuzz on the kit's vault, over a stale census file" 0 $? "$TMP/o86"
  if grep -q "UNEXPLAINED revert: 0" "$TMP/o86"; then echo "  ok    and the stale line did not reach its table"; else
    echo "  FAIL  fuzz-long.sh added an old campaign's lines to the new one"; fails=$((fails + 1)); fi
  # the census path, in one line to paste into the gate (QUICKSTART: "the path fuzz-long.sh printed"); and fuzz-long's
  # own table is not the gate: no gate verdict, no gate record
  if grep -qxF "census: $(cd "$K" && pwd -P)/census/long.tsv" "$TMP/o86" && [ -s "$K/census/long.tsv" ]; then
    echo "  ok    and it prints the census path, absolute, in one line"; else
    echo "  FAIL  fuzz-long.sh does not print the census path: $(grep -a '^census' "$TMP/o86" | head -2 | tr '\n' ' ')"; fails=$((fails + 1)); fi
  if ! grep -aq '^census gate:' "$TMP/o86" && [ ! -e "$K/.gauntlet/reports/06-census-gate.txt" ]; then
    echo "  ok    and its own census table carries no gate verdict and writes no gate record"; else
    echo "  FAIL  fuzz-long.sh's census printed a gate verdict or wrote a gate record"; fails=$((fails + 1)); fi
  # a campaign that is RED next to one that wrote a census: the census must not turn the failure into a pass
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\ncontract T87 { uint256 public n; function poke() external { n++; } }\ncontract RedOnPurposeInvariants is Test { T87 t; function setUp() public { t = new T87(); targetContract(address(t)); }\nfunction invariant_red_on_purpose() public view { assertEq(t.n(), type(uint256).max, "red on purpose"); } }\n' > "$K/test/RedOnPurpose.t.sol"
  MATCH="--match-contract (ToyVaultInvariants|RedOnPurposeInvariants)" MIN_PCT=25 "$HERE/census.sh" "$K" > "$TMP/o87" 2>&1; rc87=$?
  if [ "$rc87" -ne 0 ] && [ "$rc87" -ne 2 ] && grep -q "campaign itself FAILED" "$TMP/o87"; then echo "  ok    a red campaign fails census.sh even when the census table is clean (rc=$rc87)"; else
    echo "  FAIL  census.sh answered $rc87 over a red campaign"; fails=$((fails + 1)); fi
  # a red campaign has NO census (K12): forge calls afterInvariant on every shrink replay, so the file holds a line per
  # replay (measured on a stranger's v4 hook: 198 991 lines for 53 runs). Renamed runs.FAILED.tsv, no table printed.
  if [ ! -e "$K/census/runs.tsv" ] && [ -s "$K/census/runs.FAILED.tsv" ] && ! grep -aq '^== campaign census:' "$TMP/o87" \
    && grep -aqF "$(cd "$K" && pwd -P)/census/runs.FAILED.tsv" "$TMP/o87"; then
    echo "  ok    and it prints no census table: the file is renamed runs.FAILED.tsv, and named"; else
    echo "  FAIL  a red campaign's census: runs.tsv $([ -e "$K/census/runs.tsv" ] && echo KEPT || echo gone), runs.FAILED.tsv $([ -s "$K/census/runs.FAILED.tsv" ] && echo there || echo MISSING), tables $(grep -ac '^== campaign census:' "$TMP/o87")"; fails=$((fails + 1)); fi
  # ... and the long fuzz of that red campaign, in a bench: it FAILS, prints no census path (a red campaign has no census:
  # it was printed until K12, and the gate read 198 991 "runs" of a 53-run campaign), renames the bench's census/long.tsv
  # to long.FAILED.tsv and names it; the gate refuses that file in one line
  BENCH_ROOT="$TMP/fzk" RUNS=65 DEPTH=64 MATCH="--match-contract (ToyVaultInvariants|RedOnPurposeInvariants)" "$HERE/fuzz-long.sh" "$K" > "$TMP/o191" 2>&1; rc191=$?
  FZK="$(find "$TMP/fzk" -maxdepth 1 -name 'fuzz-long-kitcopy-*' -print -quit 2> /dev/null)"
  p191="${FZK:+$(cd "$FZK" && pwd -P)/census/long.FAILED.tsv}"
  if [ "$rc191" -ne 0 ] && [ "$rc191" -ne 2 ] && grep -q "LONG FUZZ FAILED" "$TMP/o191" && [ -n "$FZK" ] \
    && [ "$(grep -ac '^census: ' "$TMP/o191")" = "0" ] && [ ! -e "$FZK/census/long.tsv" ] && [ -s "$p191" ] \
    && grep -aq "the campaign FAILED, so it has NO census" "$TMP/o191" && grep -aqF "$p191" "$TMP/o191"; then
    echo "  ok    a long fuzz that FAILED in a bench prints no census path: it renames the census long.FAILED.tsv and names it (rc=$rc191)"; else
    echo "  FAIL  the failed long fuzz (rc=$rc191) and its census: long.tsv $([ -e "$FZK/census/long.tsv" ] && echo KEPT || echo gone), '$p191' $([ -s "$p191" ] && echo there || echo MISSING)"; grep -a -e 'LONG FUZZ' -e '^census' -e 'NO census' "$TMP/o191" | head -4 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  CORE="deposit" MIN_PCT=1 OUT_DIR="$TMP/g191" "$HERE/census.sh" --aggregate "$p191" > "$TMP/o192" 2>&1
  check "the gate over a FAILED campaign's census refuses it: nothing measured" 2 $? "$TMP/o192"
  if [ "$(wc -l < "$TMP/o192" | tr -d ' ')" = "1" ] && grep -aq '^census gate: FAILED - .*FAILED campaign' "$TMP/o192" && [ ! -e "$TMP/g191/06-census-gate.txt" ]; then
    echo "  ok    in one line, the verdict, and no record"; else
    echo "  FAIL  the refusal of a FAILED census: $(wc -l < "$TMP/o192" | tr -d ' ') line(s), record $([ -e "$TMP/g191/06-census-gate.txt" ] && echo WRITTEN || echo absent)"; sed "s/^/        | /" "$TMP/o192" | head -4; fails=$((fails + 1)); fi
  # a handler with NO targetSelector: the fuzzer calls every non-view function it has, HandlerBase's `writeCensus(string)`
  # included, with labels of its own making. The fuzzer's calls arrive as their own transactions (msg.sender == tx.origin)
  # and `writeCensus` ignores those, so the census holds one line per run, all under the suite's own label - it used to
  # hold the fuzzer's labels too (bytes nobody can read) and extra lines under the real one.
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/InvariantBase.sol";\ncontract NSHandler is HandlerBase { uint256 public n; constructor() { _addActor(address(0xA1)); } function poke(uint256) external countedSetter("poke") { n++; } }\ncontract NoSelectorInvariants is Test { NSHandler h; function setUp() public { h = new NSHandler(); targetContract(address(h)); }\nfunction invariant_n() public view { assertGe(h.n(), 0); }\nfunction afterInvariant() public { h.writeCensus("NoSelector"); } }\n' > "$K/test/NoSelector.t.sol"
  MATCH="--match-contract NoSelectorInvariants" CORE="poke" FOUNDRY_FUZZ_SEED=0x6b37 "$HERE/census.sh" "$K" > "$TMP/o175" 2>&1
  check "a handler without targetSelector: the census is still the suite's own" 0 $? "$TMP/o175"
  # 65, not 64: forge 1.8.1 calls afterInvariant once more than `runs` (measured on a toy, 64 runs: 65 lines with a
  # targetSelector and 65 without, two seeds each); the fuzzer's own writes used to add dozens more, under every label
  if [ "$(grep -ac '^== campaign census:' "$TMP/o175")" = "1" ] && grep -aEq '^== campaign census: NoSelector - 6[45] runs ==$' "$TMP/o175"; then
    echo "  ok    and it holds one label, one line per run: nothing the fuzzer wrote"; else
    echo "  FAIL  the fuzzer's own calls reached the census:"; grep -a '^== campaign census:' "$TMP/o175" | head -5 | cat -v | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # ... but the calls are SPENT, so they are counted and shown: a boundary row in the table, and one line under it
  if grep -aEq '^handler unrestricted: bookkeeping selectors were fuzzed +[1-9][0-9]* +[1-9][0-9]*$' "$TMP/o175" \
    && grep -aqxF "the fuzzer reached HandlerBase's own functions: restrict the handler with targetSelector (doctrine/INVARIANTS.md)" "$TMP/o175"; then
    echo "  ok    and the unrestricted handler is flagged: a boundary row, and the line under the table"; else
    echo "  FAIL  the unrestricted handler is not flagged in the census:"; grep -a -A8 '^== campaign census:' "$TMP/o175" | head -10 | cat -v | sed "s/^/        | /"; fails=$((fails + 1)); fi
  if ! grep -aq "handler unrestricted\|the fuzzer reached HandlerBase" "$TMP/o62" "$TMP/o133"; then
    echo "  ok    and the kit's own vault suite (restricted with targetSelector) is not flagged"; else
    echo "  FAIL  a restricted handler was flagged as unrestricted:"; grep -a "handler unrestricted\|the fuzzer reached" "$TMP/o62" "$TMP/o133" | head -3 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # an ENVIRONMENT failure (no fs_permissions for ./census) is persisted by forge under cache/invariant/failures/<suite>/
  # and replayed first on the next run, silently (measured: one extra census line per run for as long as it stays).
  # The fix hint has to name that directory, exactly, and it has to be one that exists.
  cp "$K/foundry.toml" "$TMP/kit-toml.keep"; grep -v '^fs_permissions' "$TMP/kit-toml.keep" > "$K/foundry.toml"
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/InvariantBase.sol";\ncontract EnvHandler is HandlerBase { uint256 public n; constructor() { _addActor(address(0xA1)); } function poke(uint256) external countedSetter("poke") { n++; } }\ncontract EnvFailInvariants is Test { EnvHandler h; function setUp() public { h = new EnvHandler(); targetContract(address(h)); bytes4[] memory s = new bytes4[](1); s[0] = EnvHandler.poke.selector; targetSelector(FuzzSelector({addr: address(h), selectors: s})); }\nfunction invariant_n() public view { assertGe(h.n(), 0); }\nfunction afterInvariant() public { h.writeCensus("EnvFail"); } }\n' > "$K/test/EnvFail.t.sol"
  rm -rf "$K/cache/invariant/failures/EnvFailInvariants"
  MATCH="--match-contract EnvFailInvariants" "$HERE/census.sh" "$K" > "$TMP/o178" 2>&1; rc178=$?
  if [ "$rc178" -ne 0 ] && [ "$rc178" -ne 1 ]; then echo "  ok    a campaign that cannot write its census fails census.sh (rc=$rc178)"; else
    echo "  FAIL  census.sh answered $rc178 on a campaign with no fs_permissions"; fails=$((fails + 1)); fi
  persisted="$(cd "$K" && pwd -P)/cache/invariant/failures/EnvFailInvariants"
  if [ -d "$persisted" ] && grep -aqF "rm -rf $persisted" "$TMP/o178"; then
    echo "  ok    and the hint names forge's record of the failure, the exact directory, which exists"; else
    echo "  FAIL  the hint does not name the persisted failure ($([ -d "$persisted" ] && echo exists || echo 'not there')):"; grep -a -A4 "no census line" "$TMP/o178" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  cp "$TMP/kit-toml.keep" "$K/foundry.toml"; rm -rf "$persisted"
  MATCH="--match-contract EnvFailInvariants" "$HERE/census.sh" "$K" > "$TMP/o179" 2>&1
  check "the config fixed and the directory deleted as the hint says: the census passes" 0 $? "$TMP/o179"
  # ---- K12: a persisted failure replays FIRST on the next run and writes a census line like a run (measured on a stranger's
  # v4 hook: 1 011 lines for 1 000 runs, ten persisted failures). forge exposes nothing that tells the replay from a run,
  # so census.sh says it under the table: `runs: <n> (<dir>/failures holds <k> persisted failures of <suites>: ...)`.
  mkdir -p "$TMP/pbench/census" "$TMP/pbench/cache/invariant/failures/SomeInvariants/invariants"
  cp "$C3" "$TMP/pbench/census/long.tsv"
  printf 'seq\n' > "$TMP/pbench/cache/invariant/failures/SomeInvariants/invariants/invariant_a"
  printf 'seq\n' > "$TMP/pbench/cache/invariant/failures/SomeInvariants/invariants/invariant_b"
  CORE="deposit" OUT_DIR="$TMP/g193" "$HERE/census.sh" --aggregate "$TMP/pbench/census/long.tsv" "$TMP/gproj" > "$TMP/o193" 2>&1
  check "the gate over a census next to two persisted failures" 0 $? "$TMP/o193"
  l193="runs: 3 (cache/invariant/failures holds 2 persisted failures of SomeInvariants: they replay first and count)"
  if grep -aqxF "$l193" "$TMP/o193" && grep -aqxF "$l193" "$TMP/g193/06-census-gate.txt" 2> /dev/null \
    && case "$(gate_last "$TMP/o193")" in "census gate: PASSED - "*) true ;; *) false ;; esac; then
    echo "  ok    and it says, under the table and in the record, that they replay first and count; the verdict is still last"; else
    echo "  FAIL  the persisted failures are not named under the census:"; grep -a -e '^runs:' -e '^census gate:' "$TMP/o193" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  if ! grep -aq '^runs: ' "$TMP/o189" "$TMP/o62"; then echo "  ok    and with no persisted failure there is no such line"; else
    echo "  FAIL  a 'runs:' line with no persisted failure:"; grep -a '^runs: ' "$TMP/o189" "$TMP/o62" | head -2 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  # a persisted failure of ANOTHER suite is not replayed by this campaign, and it must not be told it was
  mkdir -p "$K/cache/invariant/failures/OtherInvariants/invariants"; printf 'seq\n' > "$K/cache/invariant/failures/OtherInvariants/invariants/invariant_x"
  MATCH="--match-contract NoSelectorInvariants" FOUNDRY_FUZZ_SEED=0x6b37 "$HERE/census.sh" "$K" > "$TMP/o194" 2>&1
  if grep -aq '^== campaign census: NoSelector' "$TMP/o194" && ! grep -aq '^runs: ' "$TMP/o194"; then
    echo "  ok    and a suite's persisted failures are not counted against another suite's campaign"; else
    echo "  FAIL  persisted failures of a suite that did not run:"; grep -a -e '^runs:' -e '^== campaign' "$TMP/o194" | head -3 | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -rf "$K/cache/invariant/failures/OtherInvariants"
  CENSUS_TABLE_ONLY=1 "$HERE/census.sh" --aggregate "$p191" > "$TMP/o195" 2>&1
  check "the table-only mode refuses a FAILED campaign's census too" 2 $? "$TMP/o195"
  if [ "$(wc -l < "$TMP/o195" | tr -d ' ')" = "1" ] && grep -aq 'FAILED campaign' "$TMP/o195" && ! grep -aq '^== campaign census:' "$TMP/o195"; then echo "  ok    in one line, with no table"; else
    echo "  FAIL  the table-only refusal printed $(wc -l < "$TMP/o195" | tr -d ' ') line(s)"; fails=$((fails + 1)); fi
  # end to end: a long campaign red on purpose persists its failure in the bench; the next, green, replays it first
  printf 'pragma solidity ^0.8.26;\nimport "forge-std/Test.sol";\nimport "../src/InvariantBase.sol";\ncontract FlipHandler is HandlerBase { uint256 public n; constructor() { _addActor(address(0xA1)); } function poke(uint256) external countedSetter("poke") { n++; } }\ncontract FlipInvariants is Test { FlipHandler h; function setUp() public { h = new FlipHandler(); targetContract(address(h)); bytes4[] memory s = new bytes4[](1); s[0] = FlipHandler.poke.selector; targetSelector(FuzzSelector({addr: address(h), selectors: s})); }\nfunction invariant_flip() public view { if (vm.envOr("K12_FLIP_RED", false)) assertEq(h.n(), 0, "red on purpose"); }\nfunction afterInvariant() public { h.writeCensus("Flip"); } }\n' > "$K/test/Flip.t.sol"
  K12_FLIP_RED=true BENCH_ROOT="$TMP/fzflip" RUNS=65 DEPTH=64 MATCH="--match-contract FlipInvariants" "$HERE/fuzz-long.sh" "$K" > "$TMP/o196" 2>&1; rc196=$?
  FZF="$(find "$TMP/fzflip" -maxdepth 1 -name 'fuzz-long-kitcopy-*' -print -quit 2> /dev/null)"
  BENCH_ROOT="$TMP/fzflip" RUNS=65 DEPTH=64 MATCH="--match-contract FlipInvariants" "$HERE/fuzz-long.sh" "$K" > "$TMP/o197" 2>&1
  check "the same long campaign, green, in the bench where it failed" 0 $? "$TMP/o197"
  n197="$(awk 'END { print NR }' "$FZF/census/long.tsv" 2> /dev/null)"
  if [ "$rc196" -ne 0 ] && [ "$rc196" -ne 2 ] && [ -d "$FZF/cache/invariant/failures/FlipInvariants" ] && [ "${n197:-0}" = "67" ] \
    && grep -aqxF "runs: 67 (cache/invariant/failures holds 1 persisted failures of FlipInvariants: they replay first and count)" "$TMP/o197"; then
    echo "  ok    the persisted failure replayed first and counted: 67 lines for 65 runs (N + 1 + 1), and the line under the table says so"; else
    echo "  FAIL  the red run (rc=$rc196), then the green: ${n197:-no} census lines for 65 runs, persisted $([ -d "$FZF/cache/invariant/failures/FlipInvariants" ] && echo there || echo MISSING)"; grep -a -e '^runs:' -e '^== campaign' "$TMP/o197" | sed "s/^/        | /"; fails=$((fails + 1)); fi
  rm -f "$K/test/NoSelector.t.sol" "$K/test/EnvFail.t.sol" "$K/test/Flip.t.sol"
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
