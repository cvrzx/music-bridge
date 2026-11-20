#!/bin/bash
# Build unsigned arm64 native MicFX for injection and signing by Feather.
set -euo pipefail
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0 -std=c11 -O2 -Wall -Wextra -fvisibility=hidden -dynamiclib MicFX.c -framework Foundation -framework AVFoundation -framework AudioToolbox -Wl,-install_name,@rpath/MicFX.dylib -o ../MicFX.dylib
file ../MicFX.dylib
