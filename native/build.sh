#!/bin/bash
# Build unsigned arm64 native MicFX for injection and signing by Feather.
set -euo pipefail
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0 -std=c11 -O2 -Wall -Wextra -fvisibility=hidden -fobjc-arc -dynamiclib MicFX.c MicRecorder.m -framework UIKit -framework QuickLook -framework Foundation -framework AVFoundation -framework AudioToolbox -Wl,-install_name,@rpath/MicFX.dylib -o ../MicFX.dylib
file ../MicFX.dylib

if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  rec_test_dir=$(mktemp -d)
  trap 'rm -rf "$rec_test_dir"' EXIT
  xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" tests/record_mp4.c -framework AudioToolbox -framework CoreFoundation -o "$rec_test_dir/test_record"
  "$rec_test_dir/test_record" "$rec_test_dir/MicFX-test.mp4"
fi
