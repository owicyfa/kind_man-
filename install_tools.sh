#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# install_tools.sh
# Improved, safer, idempotent installation script for common discovery tools
# Writes PATH/GOPATH entries to the user's shell rc only if missing.

echo "[+] Starting installation of discovery tools..."

# Determine sudo usage
SUDO=""
if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO=sudo
  else
    echo "[!] This script needs root privileges for package installation. Please run as root or install sudo." >&2
    exit 1
  fi
fi

# Update package lists
echo "[+] Updating package lists..."
$SUDO apt-get update -y

# Install essential system tools and build deps
echo "[+] Installing essential system packages..."
$SUDO apt-get install -y --no-install-recommends \
  ca-certificates curl wget git unzip jq nmap python3 python3-pip build-essential libssl-dev libffi-dev whois dnsutils

# Install Go (if not present or different version)
echo "[+] Installing Go (latest stable)..."
# Get the latest Go version string from go.dev
GO_VERSION=""
if command -v curl >/dev/null 2>&1; then
  GO_VERSION=$(curl -fsSL https://go.dev/VERSION?m=text || true)
fi
if [ -z "$GO_VERSION" ]; then
  # fallback to a reasonable default if the lookup fails
  GO_VERSION="go1.19.15"
  echo "[!] Failed to query latest Go version; falling back to $GO_VERSION"
fi
ARCH="linux-amd64"
TARBALL_URL="https://go.dev/dl/${GO_VERSION}.${ARCH}.tar.gz"
TMP_TAR="/tmp/${GO_VERSION}.${ARCH}.tar.gz"

# Only install/replace Go if different or not present
CURRENT_GO=""
if command -v go >/dev/null 2>&1; then
  CURRENT_GO=$(go version | awk '{print $3}') || true
fi
if [ "$CURRENT_GO" != "$GO_VERSION" ]; then
  echo "[+] Fetching $TARBALL_URL"
  curl -fSL "$TARBALL_URL" -o "$TMP_TAR"
  $SUDO rm -rf /usr/local/go
  $SUDO tar -C /usr/local -xzf "$TMP_TAR"
  rm -f "$TMP_TAR"
else
  echo "[+] Go already at $CURRENT_GO; skipping install"
fi

# Ensure GOPATH and PATH are set for current session and future shells
GOPATH="$HOME/go"
export GOPATH="$GOPATH"
export PATH="$PATH:/usr/local/go/bin:$GOPATH/bin"

append_to_rc() {
  local line="$1"
  local rcfile="$HOME/.bashrc"
  # Use .profile for compatibility with non-interactive login shells if desired
  if ! grep -Fxq "$line" "$rcfile" 2>/dev/null; then
    printf "\n# Added by install_tools.sh\n%s\n" "$line" >> "$rcfile"
    echo "[+] Appended to $rcfile: $line"
  fi
}

append_to_rc "export GOPATH=\$HOME/go"
append_to_rc "export PATH=\$PATH:/usr/local/go/bin:\$GOPATH/bin"

# Install Go-based tools (using go install -> $GOPATH/bin)
echo "[+] Installing Go-based tools into $GOPATH/bin"
# Ensure go is available in PATH for this script
if ! command -v go >/dev/null 2>&1; then
  echo "[!] go command not found after install; aborting Go tool installation" >&2
else
  # subfinder
  echo "[+] Installing subfinder..."
  env GOBIN="$GOPATH/bin" go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest || echo "[!] subfinder install failed"

  # ffuf
  echo "[+] Installing ffuf..."
  env GOBIN="$GOPATH/bin" go install github.com/ffuf/ffuf/v2@latest || echo "[!] ffuf install failed"
fi

# Install SQLMap
echo "[+] Installing sqlmap (git clone)..."
if [ -d "$HOME/sqlmap" ]; then
  echo "[+] sqlmap already cloned; pulling latest..."
  git -C "$HOME/sqlmap" pull --ff-only || true
else
  git clone --depth 1 https://github.com/sqlmapproject/sqlmap.git "$HOME/sqlmap"
fi
# Install Python requirements for sqlmap (user install to avoid sudo pip)
if [ -f "$HOME/sqlmap/requirements.txt" ]; then
  echo "[+] Installing sqlmap Python requirements (user)"
  python3 -m pip install --user -r "$HOME/sqlmap/requirements.txt" || echo "[!] pip requirements install for sqlmap failed"
fi
# Create a symlink wrapper so sqlmap can be invoked as `sqlmap`
if [ -f "$HOME/sqlmap/sqlmap.py" ]; then
  echo "[+] Installing sqlmap wrapper to /usr/local/bin/sqlmap"
  $SUDO ln -sf "$HOME/sqlmap/sqlmap.py" /usr/local/bin/sqlmap
  $SUDO chmod +x /usr/local/bin/sqlmap
fi

# Install Nikto and Hydra (apt packages)
echo "[+] Installing nikto and hydra (apt)"
$SUDO apt-get install -y nikto hydra || echo "[!] apt install nikto/hydra may have failed"

# Install Arjun via pip (user install)
echo "[+] Installing arjun (pip user install)"
python3 -m pip install --user arjun || echo "[!] pip install arjun failed"

# Install additional useful tools (whois/dnsutils already installed above)
# Download wordlists
echo "[+] Downloading wordlists to $HOME/wordlists"
mkdir -p "$HOME/wordlists"
# Use curl -fSL and fallback to wget if curl unavailable
download() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" "$url"
  else
    echo "[!] No curl or wget available to download $url" >&2
    return 1
  fi
}

# SecLists raw URLs (file names kept short)
download "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/Web-Content/common.txt" "$HOME/wordlists/common.txt" || true
download "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/Web-Content/directory-list-2.3-medium.txt" "$HOME/wordlists/directories.txt" || true
download "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Passwords/Common-Credentials/10-million-password-list-10000.txt" "$HOME/wordlists/passwords.txt" || true

# Create results directory structure
echo "[+] Creating results directory structure..."
mkdir -p "$HOME/results/{domains,subdomains,admin_panels,vulnerabilities,auth_bypass,config_files}"

# Reload shell rc for current session (source .bashrc)
# We don't force a full login shell; just notify the user to reload if needed.
if [ -n "${BASH_VERSION:-}" ]; then
  # shell is bash
  # shellcheck disable=SC1090
  source "$HOME/.bashrc" || true
fi

# Verification checks
echo "[+] Verifying installations..."
check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    echo "[✓] $1 installed: $(command -v $1)"
  else
    echo "[✗] $1 not found in PATH"
  fi
}

check_cmd subfinder
check_cmd ffuf
if [ -f "$HOME/sqlmap/sqlmap.py" ]; then
  echo "[✓] sqlmap clone found at $HOME/sqlmap/sqlmap.py"
else
  echo "[✗] sqlmap not found at $HOME/sqlmap/sqlmap.py"
fi
check_cmd nikto
check_cmd hydra
# arjun installs to ${HOME}/.local/bin
if [ -f "$HOME/.local/bin/arjun" ] || command -v arjun >/dev/null 2>&1; then
  echo "[✓] arjun installed"
else
  echo "[✗] arjun not found in PATH (check ~/.local/bin is in PATH)"
fi

echo "[+] Installation script finished. If any tools are reported missing, check the messages above."