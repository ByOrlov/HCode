#!/usr/bin/env bash
# HCode installer — macOS / Linux.
# Usage:  curl -fsSL https://raw.githubusercontent.com/ByOrlov/HCode/main/install.sh | bash
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

# --- Install ------------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
mv -f "${TMP}/${BIN_NAME}" "${INSTALL_DIR}/${BIN_NAME}"
chmod +x "${INSTALL_DIR}/${BIN_NAME}"
info "Installed ${INSTALL_DIR}/${BIN_NAME}"

# --- PATH ---------------------------------------------------------------------
case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) : already on PATH ;;
  *)
    # Pick the most relevant profile file.
    if [ -n "${ZSH_VERSION:-}" ] || [ "$SHELL" = */zsh ]; then
      PROFILE="$HOME/.zshrc"
    elif [ -n "${BASH_VERSION:-}" ] || [ "$SHELL" = */bash ]; then
      PROFILE="$HOME/.bashrc"
    else
      PROFILE="$HOME/.profile"
    fi

    LINE="export PATH=\"\$PATH:${INSTALL_DIR}\""
    if [ -f "$PROFILE" ] && grep -qF "$INSTALL_DIR" "$PROFILE" 2>/dev/null; then
      : already added
    else
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
