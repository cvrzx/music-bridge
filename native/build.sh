#!/bin/bash
# Compile legacy MicFX 4.7 (all existing effects and recorder) with optional APO v5 App Group reader.
# This output is UNSIGNED and must be signed with an authorized app/extension profile.
set -euo pipefail
cd "$(dirname "$0")"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p ../build/native
COMMON=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0 -O2 -fPIC -fvisibility=hidden)
xcrun --sdk iphoneos clang "${COMMON[@]}" -std=c11 -Wall -Wextra -c MicFX.c -o ../build/native/MicFX.o
xcrun --sdk iphoneos clang "${COMMON[@]}" -fobjc-arc -fblocks -Wall -Wextra -c MicRecorder.m -o ../build/native/MicRecorder.o
xcrun --sdk iphoneos clang++ "${COMMON[@]}" -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -c APOGroup.mm -o ../build/native/APOGroup.o
xcrun --sdk iphoneos clang++ "${COMMON[@]}" -dynamiclib ../build/native/MicFX.o ../build/native/MicRecorder.o ../build/native/APOGroup.o -framework UIKit -framework QuickLook -framework Foundation -framework AVFoundation -framework AudioToolbox -Wl,-install_name,@rpath/MicFX.dylib -o ../MicFX.dylib
file ../MicFX.dylib
xcrun lipo ../MicFX.dylib -verify_arch arm64
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  rec_test_dir=$(mktemp -d)
  trap 'rm -rf "$rec_test_dir"' EXIT
  xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" tests/record_mp4.c -framework AudioToolbox -framework CoreFoundation -o "$rec_test_dir/test_record"
  "$rec_test_dir/test_record" "$rec_test_dir/MicFX-test.mp4"
fi
