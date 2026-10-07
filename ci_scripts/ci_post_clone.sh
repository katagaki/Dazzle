#!/bin/sh
set -e

# Xcode ships the Metal toolchain as a separate component, which Xcode Cloud
# images don't always include; the app's shaders need it to compile.
xcodebuild -downloadComponent MetalToolchain
