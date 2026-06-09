#!/usr/bin/env sh
# install_act.sh — Download a pinned version of nektos/act into BIN_DIR.
#
# Mirrors the pattern in lefthook/bootstrap_lefthook.sh: pin a known-good
# version centrally, let repos curl this script down (SHA-pinned) so the
# whole fleet stays on the same act build.
#
# Usage (from inside a repo):
#   bash ./scripts/install_act.sh          # installs .bin/act
#   ACT_VERSION=0.2.88 bash ./scripts/install_act.sh
#   BIN_DIR=~/.local/bin bash ./scripts/install_act.sh
#
# After install, add BIN_DIR to PATH (or invoke ./.bin/act directly).
# Requires Docker daemon to actually *run* act, but install itself does not.

set -eu

ACT_VERSION="${ACT_VERSION:-0.2.88}"
BIN_DIR="${BIN_DIR:-.bin}"
BIN="$BIN_DIR/act"

mkdir -p "$BIN_DIR"

# Skip download if the pinned version is already present.
if [ -x "$BIN" ]; then
  INSTALLED=$("$BIN" --version 2>/dev/null | awk '{print $3}' | sed 's/^v//' || true)
  if [ "$INSTALLED" = "$ACT_VERSION" ]; then
    echo "act $ACT_VERSION already installed at $BIN"
    exit 0
  fi
  echo "Replacing act $INSTALLED at $BIN with $ACT_VERSION"
fi

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Linux)  os_tag=Linux ;;
  Darwin) os_tag=Darwin ;;
  *) echo "Unsupported OS: $OS" >&2; exit 2 ;;
esac

case "$ARCH" in
  x86_64|amd64)  arch_tag=x86_64 ;;
  aarch64|arm64) arch_tag=arm64 ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 2 ;;
esac

URL="https://github.com/nektos/act/releases/download/v${ACT_VERSION}/act_${os_tag}_${arch_tag}.tar.gz"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading act v$ACT_VERSION ($os_tag/$arch_tag) ..."
curl --fail --show-error --silent --location \
  --proto '=https' --tlsv1.2 \
  "$URL" -o "$TMP/act.tar.gz"

tar -xzf "$TMP/act.tar.gz" -C "$TMP" act
mv "$TMP/act" "$BIN"
chmod +x "$BIN"

echo "act v$ACT_VERSION installed at $BIN"

# Soft Docker check — act needs it at runtime, not install time.
if ! command -v docker >/dev/null 2>&1; then
  echo "warning: docker not found on PATH. Install Docker before running act." >&2
elif ! docker info >/dev/null 2>&1; then
  echo "warning: docker daemon not reachable. Start Docker before running act." >&2
fi
