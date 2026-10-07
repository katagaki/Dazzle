#!/bin/sh
set -e

# Xcode ships the Metal toolchain as a separate component, which Xcode Cloud
# images don't always include; the app's shaders need it to compile.
if xcrun metal --version >/dev/null 2>&1; then
    exit 0
fi

# Some images already hold a downloaded toolchain bundle that isn't installed,
# so downloading fails with "already imported"; import that bundle instead.
if ! xcodebuild -downloadComponent MetalToolchain; then
    for bundle in "$HOME"/Library/Developer/DVTDownloads/Assets/MetalToolchain/*.exportedBundle; do
        [ -e "$bundle" ] && xcodebuild -importComponent MetalToolchain -importPath "$bundle" || true
    done
fi

xcrun metal --version
