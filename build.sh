#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p dist
OUT="$(pwd)/dist"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
for role in sender receiver; do
  name="Bridge-${role}"
  temp=$(mktemp -d)
  app="$temp/Payload/$name.app"
  mkdir -p "$app"
  xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0 -fobjc-arc -fblocks -O2 Bridge.m -framework UIKit -framework Foundation -framework AVFoundation -o "$app/$name"
  python3 - "$app" "$name" "$role" <<'PY'
import plistlib, sys, os
app,name,role=sys.argv[1:]
p={'CFBundleExecutable':name,'CFBundleIdentifier':'com.micfx.bridgetest.'+role,'CFBundleName':name,'CFBundleDisplayName':'Bridge '+role.title(),'CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0','CFBundleVersion':'1','MinimumOSVersion':'16.0','UIDeviceFamily':[1],'LSRequiresIPhoneOS':True,'UILaunchScreen':{},'BridgeRole':role}
if role=='sender': p['UIBackgroundModes']=['audio']
with open(os.path.join(app,'Info.plist'),'wb') as f: plistlib.dump(p,f)
PY
  (cd "$temp" && zip -qry "$OUT/$name.ipa" Payload)
  rm -rf "$temp"
done
