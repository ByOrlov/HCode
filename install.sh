#!/usr/bin/env bash
# HCode installer — macOS / Linux.
# Usage:  curl -fsSL https://raw.githubusercontent.com/ByOrlov/HCode/master/install.sh | bash
set -euo pipefail

REPO="ByOrlov/HCode"
INSTALL_DIR="${HCODE_INSTALL_DIR:-$HOME/.hcode/bin}"
BIN_NAME="hcode"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
err()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; }

# --- Detect OS + arch ---------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Darwin) os=darwin ;;
  Linux)  os=linux ;;
  *) err "Unsupported OS: $OS (this installer covers macOS and Linux)"; exit 1 ;;
esac
case "$ARCH" in
  x86_64|amd64)  arch=x86_64 ;;
  aarch64|arm64) arch=aarch64 ;;
  *) err "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# aarch64-linux is built via QEMU; verify it exists before assuming.
ASSET="hcode-${arch}-${os}.tar.gz"
URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"

bold "Installing HCode for ${arch}-${os}…"
info "Release asset: ${ASSET}"
info "Install dir:   ${INSTALL_DIR}"

# --- Download -----------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info "Downloading ${URL}…"
if ! curl -fSL --retry 3 -o "${TMP}/${ASSET}" "$URL"; then
  err "Download failed."
  err "If you're on ${arch}-${os}, the asset may not be published yet."
  err "Check available assets at: https://github.com/${REPO}/releases/latest"
  exit 1
fi

# --- Verify + extract ---------------------------------------------------------
info "Extracting…"
tar -xzf "${TMP}/${ASSET}" -C "$TMP"

# --- Runtime dependencies -----------------------------------------------------
# HCode links dynamically against OpenSSL (libssl/libcrypto), libyaml and pcre2.
# They are part of Crystal's stdlib runtime and not declared in shard.yml, so we
# make sure they are present via the platform package manager.
ensure_macos_deps() {
  command -v brew >/dev/null 2>&1 || {
    err "Homebrew not found. Install it from https://brew.sh, then:"
    err "  brew install openssl@3 libyaml pcre2"
    return 0
  }
  local missing=()
  for pkg in openssl@3 libyaml pcre2; do
    brew list "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    info "All runtime dependencies present (Homebrew)."
    return 0
  fi
  info "Installing missing Homebrew packages: ${missing[*]}"
  brew install "${missing[@]}"
}

ensure_linux_deps() {
  # Each entry: "lib<ldconfig-name>|<apt pkgs>|<dnf pkgs>|<pacman pkgs>"
  # ldconfig-name is used to detect presence without the package manager.
  local -a rows=(
    "libssl.so.3|libssl3 libssl3t64|openssl-libs|openssl"
    "libcrypto.so.3|libssl3 libssl3t64|openssl-libs|openssl"
    "libyaml-0.so.2|libyaml-0-2|libyaml|libyaml"
    "libpcre2-8.so.0|libpcre2-8-0|pcre2|pcre2"
  )
  local missing_libs=()
  for row in "${rows[@]}"; do
    local lib="${row%%|*}"
    { ldconfig -p 2>/dev/null || true; } | grep -q "$lib" || missing_libs+=("$row")
  done
  if [ "${#missing_libs[@]}" -eq 0 ]; then
    info "All runtime dependencies present."
    return 0
  fi

  local sudo=""
  if [ "$(id -u)" -ne 0 ]; then
    sudo="sudo"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    local pkgs=()
    for row in "${missing_libs[@]}"; do pkgs+=($(echo "$row" | cut -d'|' -f2)); done
    info "Installing missing packages via apt-get: ${pkgs[*]}"
    $sudo apt-get update -qq
    # shellcheck disable=SC2086
    $sudo apt-get install -y $pkgs
  elif command -v dnf >/dev/null 2>&1; then
    local pkgs=()
    for row in "${missing_libs[@]}"; do pkgs+=($(echo "$row" | cut -d'|' -f3)); done
    info "Installing missing packages via dnf: ${pkgs[*]}"
    # shellcheck disable=SC2086
    $sudo dnf install -y $pkgs
  elif command -v yum >/dev/null 2>&1; then
    local pkgs=()
    for row in "${missing_libs[@]}"; do pkgs+=($(echo "$row" | cut -d'|' -f3)); done
    info "Installing missing packages via yum: ${pkgs[*]}"
    # shellcheck disable=SC2086
    $sudo yum install -y $pkgs
  elif command -v pacman >/dev/null 2>&1; then
    local pkgs=()
    for row in "${missing_libs[@]}"; do pkgs+=($(echo "$row" | cut -d'|' -f4)); done
    info "Installing missing packages via pacman: ${pkgs[*]}"
    # shellcheck disable=SC2086
    $sudo pacman -S --noconfirm --needed $pkgs
  else
    err "Could not detect a supported package manager."
    err "Please install OpenSSL, libyaml and pcre2 manually:"
    err "  ${missing_libs[*]}"
  fi
}

case "$os" in
  darwin) ensure_macos_deps ;;
  linux)  ensure_linux_deps ;;
esac

# --- Install ------------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
mv -f "${TMP}/${BIN_NAME}" "${INSTALL_DIR}/${BIN_NAME}"
chmod +x "${INSTALL_DIR}/${BIN_NAME}"
info "Installed ${INSTALL_DIR}/${BIN_NAME}"

# --- PATH ---------------------------------------------------------------------
case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) : already on PATH ;;
  *)
    # Pick the most relevant profile file based on the user's default login
    # shell ($SHELL), NOT on the interpreter running this script — when invoked
    # as `curl ... | bash` the interpreter is always bash, so checking
    # $BASH_VERSION would always select .bashrc even for zsh users (the macOS
    # default), and the line would never be sourced.
    case "${SHELL:-}" in
      */zsh)  PROFILE="$HOME/.zshrc" ;;
      */bash) PROFILE="$HOME/.bashrc" ;;
      */fish) PROFILE="$HOME/.config/fish/config.fish" ;;
      *)      PROFILE="$HOME/.profile" ;;
    esac

    case "${SHELL:-}" in
      */fish) LINE="set -gx PATH \$PATH ${INSTALL_DIR}" ;;
      *)      LINE="export PATH=\"\$PATH:${INSTALL_DIR}\"" ;;
    esac
    if [ -f "$PROFILE" ] && grep -qF "$INSTALL_DIR" "$PROFILE" 2>/dev/null; then
      : already added
    else
      mkdir -p "$(dirname "$PROFILE")"
      printf '\n# Added by HCode installer\n%s\n' "$LINE" >> "$PROFILE"
      info "Added ${INSTALL_DIR} to PATH in ${PROFILE}"
      info "Restart your shell or run:  source ${PROFILE}"
    fi
    ;;
esac

# --- Done ---------------------------------------------------------------------
bold "✓ HCode installed."
info "Version: $(${INSTALL_DIR}/${BIN_NAME} --version 2>/dev/null || echo 'unknown')"
info "Run 'hcode' to start. Use '/upgrade' inside the TUI to update later."
