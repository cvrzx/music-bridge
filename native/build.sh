#!/bin/bash
# Run on macOS with Xcode and the iOS SDK installed.
set -euo pipefail
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0 -std=c11 -O2 -Wall -Wextra -fvisibility=hidden -dynamiclib MicFX.c -framework Foundation -framework AudioToolbox -Wl,-install_name,@rpath/MicFX.dylib -o ../MicFX.dylib
file ../MicFX.dylib
# The IPA installer must sign the dylib with the app. Do not install an unsigned dylib on its own.
