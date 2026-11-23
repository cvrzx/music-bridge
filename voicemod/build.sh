#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 -fobjc-arc -fblocks -dynamiclib -O2 \
  VoicemodBridge.m -framework UIKit -framework Foundation -framework AVFoundation \
  -framework CoreMedia -framework AudioToolbox -Wl,-install_name,@rpath/VoicemodBridge.dylib \
  -o ../VoicemodBridge.dylib
xcrun lipo ../VoicemodBridge.dylib -verify_arch arm64
