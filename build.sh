#!/usr/bin/env bash
# Builds build/Morph.app (the app plus its Finder extension) with swiftc, no Xcode project.
#
#   ./build.sh            build
#   ./build.sh install    build, copy to /Applications, register and enable the Finder extension
#
# Signs with $SIGN_IDENTITY when it's set (an "Apple Development" or "Developer ID Application"
# identity), ad hoc otherwise, which runs on this Mac only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SIGN="${SIGN_IDENTITY:--}"
APP="$ROOT/build/Morph.app"
APPEX="$APP/Contents/PlugIns/MorphFinder.appex"
FLAGS=(-swift-version 5 -O -sdk "$SDK")

rm -rf "$ROOT/build/Morph.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"

for arch in arm64 x86_64; do
  swiftc "${FLAGS[@]}" -target "$arch-apple-macos15.0" -module-name Morph \
    "$ROOT"/Sources/Shared/*.swift "$ROOT"/Sources/App/*.swift -o "$ROOT/build/Morph-$arch"
  swiftc "${FLAGS[@]}" -target "$arch-apple-macos15.0" -module-name MorphFinder -parse-as-library -application-extension \
    "$ROOT"/Sources/Shared/*.swift "$ROOT"/Sources/Extension/*.swift \
    -Xlinker -e -Xlinker _NSExtensionMain -o "$ROOT/build/MorphFinder-$arch"
done
lipo -create "$ROOT"/build/Morph-{arm64,x86_64} -output "$APP/Contents/MacOS/Morph"
lipo -create "$ROOT"/build/MorphFinder-{arm64,x86_64} -output "$APPEX/Contents/MacOS/MorphFinder"
rm -f "$ROOT"/build/Morph-{arm64,x86_64} "$ROOT"/build/MorphFinder-{arm64,x86_64}

sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/App-Info.plist" > "$APP/Contents/Info.plist"
sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/Extension-Info.plist" > "$APPEX/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# The extension first: signing the app seals what's inside it.
codesign --force --sign "$SIGN" --options runtime --entitlements "$ROOT/Resources/Extension.entitlements" "$APPEX"
codesign --force --sign "$SIGN" --options runtime "$APP"
echo "built $APP ($VERSION)"

if [ "${1:-}" = install ]; then
  DEST=/Applications/Morph.app
  [ -w /Applications ] || DEST="$HOME/Applications/Morph.app"
  mkdir -p "$(dirname "$DEST")"
  pkill -x Morph 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  pluginkit -a "$DEST/Contents/PlugIns/MorphFinder.appex"
  pluginkit -e use -i com.biye.Morph.Finder
  echo "installed $DEST"
fi
