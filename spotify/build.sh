#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 -fobjc-arc -fblocks -dynamiclib -O2 SpotifyBridge.m -framework UIKit -framework Foundation -framework AVFoundation -framework CoreMedia -framework AudioToolbox -Wl,-install_name,@rpath/SpotifyBridge.dylib -o SpotifyBridge.dylib
xcrun lipo SpotifyBridge.dylib -verify_arch arm64
