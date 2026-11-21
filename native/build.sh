#!/bin/bash
# GitHub macOS runner / Xcode: build original MicFX with optional APO App Group
# reader. Compatible with the verified Discord 344.1 ARM64 executable only.
set -euo pipefail
cd "$(dirname "$0")"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p ../build/native
COMMON=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0 -O2 -fPIC -fvisibility=hidden)
xcrun --sdk iphoneos clang "${COMMON[@]}" -std=c11 -Wall -Wextra   -c MicFX.c -o ../build/native/MicFX.o
xcrun --sdk iphoneos clang++ "${COMMON[@]}" -std=c++17 -fobjc-arc -fblocks -Wall -Wextra   -c APOGroup.mm -o ../build/native/APOGroup.o
xcrun --sdk iphoneos clang++ "${COMMON[@]}" -std=c++17 -fobjc-arc -Wall -Wextra -c StereoRoute.mm -o ../build/native/StereoRoute.o
xcrun --sdk iphoneos clang++ "${COMMON[@]}" -dynamiclib   ../build/native/MicFX.o ../build/native/APOGroup.o ../build/native/StereoRoute.o   -framework Foundation -framework AVFoundation -framework AudioToolbox   -Wl,-install_name,@rpath/MicFX.dylib -o ../MicFX.dylib
file ../MicFX.dylib
xcrun lipo ../MicFX.dylib -verify_arch arm64
