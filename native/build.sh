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
# Keep Shine's LGPL-2.0 source in vendor/shine for redistribution and relinking.
SHINE_OBJECTS=()
for source in vendor/shine/*.c; do
  obj="../build/native/shine_$(basename "${source%.c}").o"
  xcrun --sdk iphoneos clang "${COMMON[@]}" -std=c11 -Wall -Wextra -Ivendor/shine -c "$source" -o "$obj"
  SHINE_OBJECTS+=("$obj")
done
xcrun --sdk iphoneos clang++ "${COMMON[@]}" -dynamiclib ../build/native/MicFX.o ../build/native/MicRecorder.o ../build/native/APOGroup.o "${SHINE_OBJECTS[@]}" -framework UIKit -framework QuickLook -framework Foundation -framework AVFoundation -framework AudioToolbox -Wl,-install_name,@rpath/MicFX.dylib -o ../MicFX.dylib
file ../MicFX.dylib
xcrun lipo ../MicFX.dylib -verify_arch arm64
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  rec_test_dir=$(mktemp -d)
  trap 'rm -rf "$rec_test_dir"' EXIT
  xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" tests/record_mp4.c -framework AudioToolbox -framework CoreFoundation -o "$rec_test_dir/test_record"
  "$rec_test_dir/test_record" "$rec_test_dir/MicFX-test.mp4"
  xcrun --sdk macosx clang -std=c11 -O2 -Ivendor/shine tests/mp3_encode.c vendor/shine/*.c -lm -o "$rec_test_dir/test_mp3"
  "$rec_test_dir/test_mp3" "$rec_test_dir/MicFX-test.mp3"
  test -s "$rec_test_dir/MicFX-test.mp3"
  echo "MP3 header: $(od -An -tx1 -N4 "$rec_test_dir/MicFX-test.mp3")"
  if command -v afinfo >/dev/null; then afinfo "$rec_test_dir/MicFX-test.mp3" >/dev/null; fi
fi
