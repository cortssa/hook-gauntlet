#!/usr/bin/env bash
#
# doctor.sh - what this machine has, against QUICKSTART.md section 0; for everything missing, the command that installs it.
#
# It CHECKS. It never runs an installer, never uses the network (no fetch, no clone, no RPC call) and never prints the
# value of an environment variable: RPC_URL is reported as set or not set, nothing else. The commands it prints are for
# the owner to read and run - an agent shows them to the owner and installs only on the owner's yes.
#
# Usage:   scripts/doctor.sh
# Output:  one line per requirement - `ok <name> <version>`, `missing <name> - <why>` or `optional-missing <name> - <why>` -
#          each missing item followed by indented lines with the command for THIS system: Linux (apt), macOS (brew), or
#          Windows outside WSL (Git Bash / MSYS / Cygwin): the WSL steps first, then the Linux commands, run inside WSL.
#          The last line is exactly `doctor: ready` or `doctor: missing: a, b` (required items only).
# Exit:    0 ready; 1 something required is missing.
#
# Written for bash 3.2 too (macOS's /bin/bash): it has to be able to say that bash is too old instead of failing on it.

set -u

# the versions the kit's gates run on (foundry-kit/README.md, "Supported versions"; .github/workflows/gates.yml). The
# selftest checks that these are gates.yml's, so a pin changed in one place only is seen.
FORGE_PIN="1.8.1"
FORGE_ALSO="1.8.3"
FORGE_STD_PIN="1.16.2"
REPORTLAB_PIN="4.4.9"
PYPDF_PIN="6.9.1"

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
missing_list=""

ver_of() { # the first x.y or x.y.z in $1
  local re='([0-9]+\.[0-9]+(\.[0-9]+)?)'
  if [[ $1 =~ $re ]]; then echo "${BASH_REMATCH[1]}"; fi
}
have() { command -v "$1" > /dev/null 2>&1; }
need() { # need <name> <why>: a required item is missing
  echo "missing $1 - $2"
  missing_list="${missing_list:+$missing_list, }$1"
}
want() { echo "optional-missing $1 - $2"; }   # want <name> <why>: an optional item is missing
cmd() { # cmd <the Linux command (apt)> [<the macOS command (brew)>]: the install line for this system
  case "$sys" in
    macos) echo "  install: ${2:-$1}" ;;
    windows) echo "  install, inside WSL: $1" ;;
    other) echo "  install: $1   (Debian/Ubuntu shown; use your system's package manager)" ;;
    *) echo "  install: $1" ;;
  esac
}

# ---------------------------------------------------------------------------- the platform
os="$(uname -s 2> /dev/null)"
case "$os" in
  Linux) sys=linux; grep -qi microsoft /proc/version 2> /dev/null && sys=wsl ;;
  Darwin) sys=macos ;;
  MINGW* | MSYS* | CYGWIN*) sys=windows ;;
  *) sys=other ;;
esac
case "$sys" in
  linux) echo "ok platform Linux $(uname -r 2> /dev/null)" ;;
  wsl)
    echo "ok platform Linux-WSL $(uname -r 2> /dev/null)"
    case "$KIT" in
      /mnt/*)
        need linux-side "the kit is on the Windows side of WSL (under /mnt/): line ends and file watchers break across the boundary"
        echo "  install: inside WSL, in your Linux home: git clone <url-of-this-repository> ~/hook-gauntlet   (then run everything from there)" ;;
      *) echo "ok linux-side" ;;
    esac ;;
  macos) echo "ok platform macOS $(uname -r 2> /dev/null) (untested by the kit: its scripts are exercised on Linux)" ;;
  windows)
    need platform "Windows outside WSL ($os): the kit runs inside WSL, with the project on the Linux side"
    echo "  step 1: PowerShell as administrator: wsl --install"
    echo "  step 2: reboot"
    echo "  step 3: open WSL (the Ubuntu entry in the Start menu, or wsl in a terminal) and install inside WSL what the lines below name"
    echo "  step 4: put the project on the Linux side, inside WSL: git clone <url-of-this-repository> ~/hook-gauntlet   (not under /mnt/c: CRLF breaks a shell script silently)"
    echo "  step 5: run scripts/doctor.sh again, inside WSL, from there; the lines below are about THIS Windows shell" ;;
  *) echo "ok platform ${os:-unknown} (untested by the kit: its scripts are exercised on Linux)" ;;
esac

# ---------------------------------------------------------------------------- required tools
# bash: the one on the PATH, the one every script's `#!/usr/bin/env bash` runs - not necessarily the one running this
if have bash; then
  v="$(ver_of "$(bash --version 2> /dev/null | head -n 1)")"
  if [ -n "$v" ] && [ "${v%%.*}" -ge 5 ]; then echo "ok bash $v"; else
    need bash "found ${v:-a version it does not print} on the PATH; the scripts need 5 or later"
    cmd "sudo apt-get install -y bash" "brew install bash   (then open a new shell: brew's bash must come first on the PATH)"
  fi
else
  need bash "not on the PATH"; cmd "sudo apt-get install -y bash" "brew install bash"
fi

# forge and cast: the pinned version, or the second one CI runs; anything else is outside what the kit claims
foundry_hint() { # foundry_hint <name>: why it is missing and the commands, when it is not on the PATH
  if [ "$sys" != windows ] && [ -x "$HOME/.foundry/bin/$1" ]; then   # on Windows, the Foundry that counts is WSL's
    need "$1" "installed in ~/.foundry/bin but not on the PATH (a non-interactive shell does not read your profile)"
    echo '  install: nothing to install - export PATH="$HOME/.foundry/bin:$PATH"   (at the top of your script, or in the shell that runs the kit)'
  else
    need "$1" "not on the PATH"
    cmd "curl -L https://foundry.paradigm.xyz | bash   (installs foundryup)"
    cmd '$HOME/.foundry/bin/foundryup --install '"$FORGE_PIN"
  fi
}
if have forge; then
  v="$(ver_of "$(forge --version 2> /dev/null | head -n 1)")"
  case "$v" in
    "$FORGE_PIN") echo "ok forge $v (the pin)" ;;
    "$FORGE_ALSO") echo "ok forge $v (supported beside the pin, $FORGE_PIN: CI runs the batteries on it)" ;;
    *)
      need forge "found ${v:-a version it does not print}; supported: $FORGE_PIN (the pin), $FORGE_ALSO (foundry-kit/README.md)"
      cmd "foundryup --install $FORGE_PIN" ;;
  esac
else
  foundry_hint forge
fi
if have cast; then echo "ok cast $(ver_of "$(cast --version 2> /dev/null | head -n 1)")"; else foundry_hint cast; fi

if have git; then echo "ok git $(ver_of "$(git --version 2> /dev/null)")"; else
  need git "not on the PATH"; cmd "sudo apt-get install -y git" "brew install git"; fi
if have rsync; then echo "ok rsync $(ver_of "$(rsync --version 2> /dev/null | head -n 1)")"; else
  need rsync "not on the PATH (bench.sh copies with it)"; cmd "sudo apt-get install -y rsync" "brew install rsync"; fi

# ---------------------------------------------------------------------------- the kit's own dependencies
FS="$KIT/foundry-kit/lib/forge-std"
if [ -f "$FS/package.json" ] || [ -f "$FS/src/Test.sol" ]; then
  v="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$FS/package.json" 2> /dev/null | head -n 1)"
  if [ "$v" = "$FORGE_STD_PIN" ]; then echo "ok forge-std $v"; else
    echo "ok forge-std ${v:-unknown} (the pin is $FORGE_STD_PIN: nothing is claimed outside it)"; fi
else
  need forge-std "foundry-kit/lib/forge-std is not there (the root kit's one dependency)"
  cmd "git clone --quiet --depth 1 --branch v$FORGE_STD_PIN https://github.com/foundry-rs/forge-std foundry-kit/lib/forge-std   (from the kit's root; offline: copy any forge-std v$FORGE_STD_PIN checkout there)"
fi

V4="$KIT/foundry-kit/v4/lib/v4-core"
pin="$(sed -n 's/^V4_CORE_PIN="\([0-9a-f]*\)"$/\1/p' "$HERE/install-v4.sh" 2> /dev/null)"
v4_install() { cmd "${1}scripts/install-v4.sh foundry-kit/v4   (from the kit's root; network - offline: V4_LOCAL_SRC=<dir with the clones>, foundry-kit/v4/README.md)"; }
if [ ! -f "$V4/src/PoolManager.sol" ]; then
  need v4-core "foundry-kit/v4/lib/v4-core is not installed (Uniswap's sources for the v4 module, at a pinned commit)"; v4_install ""
elif [ ! -d "$V4/lib/forge-std/src" ] || [ ! -d "$V4/lib/solmate/src" ]; then
  need v4-core "foundry-kit/v4/lib/v4-core has a submodule missing (lib/forge-std or lib/solmate)"; v4_install "V4_FORCE=1 "
elif ! have git; then
  echo "ok v4-core present (its commit not checked: no git on the PATH)"
elif [ ! -e "$V4/.git" ]; then
  need v4-core "foundry-kit/v4/lib/v4-core is not a git checkout: its commit cannot be checked against the pin"; v4_install "V4_FORCE=1 "
else
  head="$(git -C "$V4" rev-parse HEAD 2> /dev/null)"
  if [ -n "$pin" ] && [ "$head" = "$pin" ]; then echo "ok v4-core $(printf '%s' "$head" | cut -c1-12) (the pin in scripts/install-v4.sh)"; else
    need v4-core "foundry-kit/v4/lib/v4-core is at ${head:-no commit}, the pin is ${pin:-unreadable}"; v4_install "V4_FORCE=1 "; fi
fi

# ---------------------------------------------------------------------------- optional
if have python3 && v="$(ver_of "$(python3 --version 2>&1)")" && [ -n "$v" ]; then
  echo "ok python3 $v"
  if v="$(python3 -c 'import reportlab; print(reportlab.Version)' 2> /dev/null)" && [ -n "$v" ]; then echo "ok reportlab $v"; else
    want reportlab "optional: only for the dossier's PDF copy (scripts/dossier-pdf.py; CI pins $REPORTLAB_PIN)"
    cmd "sudo apt-get install -y python3-reportlab" "python3 -m venv ~/.venvs/hook-gauntlet && ~/.venvs/hook-gauntlet/bin/pip install reportlab==$REPORTLAB_PIN pypdf==$PYPDF_PIN   (then put ~/.venvs/hook-gauntlet/bin first on the PATH)"
  fi
  if v="$(python3 -c 'import pypdf; print(pypdf.__version__)' 2> /dev/null)" && [ -n "$v" ]; then echo "ok pypdf $v"; else
    want pypdf "optional: only for the selftest's read-back of the dossier's PDF (CI pins $PYPDF_PIN)"
    cmd "sudo apt-get install -y python3-pypdf" "python3 -m venv ~/.venvs/hook-gauntlet && ~/.venvs/hook-gauntlet/bin/pip install reportlab==$REPORTLAB_PIN pypdf==$PYPDF_PIN   (then put ~/.venvs/hook-gauntlet/bin first on the PATH)"
  fi
else
  want python3 "optional: the evidence lines of assert-fresh-build.sh (the verdict is forge's either way) and the dossier's PDF"
  cmd "sudo apt-get install -y python3" "brew install python"
  want reportlab "optional, and needs python3 first: the dossier's PDF copy"
  want pypdf "optional, and needs python3 first: the selftest's read-back of that PDF"
fi
if have shellcheck; then echo "ok shellcheck $(ver_of "$(shellcheck --version 2> /dev/null)")"; else
  want shellcheck "optional locally: the selftest runs it when it is there and says when it is not; CI always runs it"
  cmd "sudo apt-get install -y shellcheck" "brew install shellcheck"
fi
if have slither; then echo "ok slither $(ver_of "$(slither --version 2> /dev/null)")"; else
  want slither "only for the static-analysis judge in full mode - an install your agent must ask you for"
  cmd "sudo apt-get install -y pipx && pipx install slither-analyzer" "brew install pipx && pipx install slither-analyzer"
fi
# RPC_URL: whether it is set, never what it holds - not its value, not its length, not its host
if [ -n "${RPC_URL:-}" ]; then echo "ok RPC_URL set (its value is never printed)"; else
  want RPC_URL "not set: needed only to fetch the real pool manager's bytecode (scripts/fetch-bytecode.sh) and for a fork"
  echo "  set: export RPC_URL=<a read-only endpoint>   (in the shell that runs the kit; never in a tracked file, never in a chat)"
fi

if [ -z "$missing_list" ]; then
  echo "doctor: ready"
  exit 0
fi
echo "doctor: missing: $missing_list"
exit 1
