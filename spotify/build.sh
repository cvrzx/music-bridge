#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 -fobjc-arc -fblocks -dynamiclib -O2 SpotifyProbe.m -framework UIKit -framework Foundation -framework AVFoundation -framework CoreMedia -framework AudioToolbox -Wl,-install_name,@rpath/SpotifyProbe.dylib -o SpotifyProbe.dylib
xcrun lipo SpotifyProbe.dylib -verify_arch arm64
