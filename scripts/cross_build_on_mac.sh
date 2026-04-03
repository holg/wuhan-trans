#!/bin/bash
# Cross-compile vtranslate-relay for Linux on macOS
set -e

TARGET_TRIPLE="${1:-x86_64-unknown-linux-gnu}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../relay-server"

if ! rustup target list | grep -q "^$TARGET_TRIPLE (installed)"; then
    echo "Installing target $TARGET_TRIPLE..."
    rustup target add "$TARGET_TRIPLE"
fi

echo "Building vtranslate-relay for $TARGET_TRIPLE..."

case "$TARGET_TRIPLE" in
    x86_64-unknown-linux-gnu)
        if ! command -v x86_64-unknown-linux-gnu-gcc >/dev/null 2>&1; then
            echo "Error: x86_64-unknown-linux-gnu-gcc not found!" >&2
            echo "Install with: brew tap messense/macos-cross-toolchains && brew install x86_64-unknown-linux-gnu" >&2
            exit 1
        fi
        export CC_x86_64_unknown_linux_gnu="x86_64-unknown-linux-gnu-gcc"
        export AR_x86_64_unknown_linux_gnu="x86_64-unknown-linux-gnu-ar"
        export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="x86_64-unknown-linux-gnu-gcc"
        ;;
    aarch64-unknown-linux-gnu)
        if ! command -v aarch64-unknown-linux-gnu-gcc >/dev/null 2>&1; then
            echo "Error: aarch64-unknown-linux-gnu-gcc not found!" >&2
            echo "Install with: brew tap messense/macos-cross-toolchains && brew install aarch64-unknown-linux-gnu" >&2
            exit 1
        fi
        export CC_aarch64_unknown_linux_gnu="aarch64-unknown-linux-gnu-gcc"
        export AR_aarch64_unknown_linux_gnu="aarch64-unknown-linux-gnu-ar"
        export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="aarch64-unknown-linux-gnu-gcc"
        ;;
    *)
        echo "Error: Unsupported target: $TARGET_TRIPLE" >&2
        exit 1
        ;;
esac

unset CC
unset MACOSX_DEPLOYMENT_TARGET
export RUSTFLAGS="-C opt-level=3 -C strip=symbols"

cargo build --release --target "$TARGET_TRIPLE"

BINARY="target/$TARGET_TRIPLE/release/vtranslate-relay"
if [ -f "$BINARY" ]; then
    echo "✓ Built: $BINARY ($(du -h "$BINARY" | cut -f1))"
else
    echo "✗ Build failed"
    exit 1
fi
