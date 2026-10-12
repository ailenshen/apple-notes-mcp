#!/bin/sh
# Builds dist/AppleNotesMCP.app: a universal (arm64 + x86_64) release binary, Info.plist,
# icon and signature.
#
# Signing: the identity "Apple Notes MCP Signing" (a long-lived self-signed certificate) gives
# every build the same designated requirement, so permissions granted to one version carry over
# to the next. Without it the build is ad-hoc signed, and macOS treats every rebuild as a new app.
# 当有 Apple 开发者账号时，改用 Developer ID 签名并公证，同时保持 bundle id 不变。
#
# Two `--triple` builds plus lipo, because `swift build --arch arm64 --arch x86_64` needs Xcode.
# 当只用 Command Line Tools 也能直接构建通用二进制时，简化为一次构建。
set -eu
cd "$(dirname "$0")/.."

VERSION=${VERSION:-$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' npm/package.json 2>/dev/null | head -1)}
VERSION=${VERSION:-2.0.0-dev}
BUILD_NUMBER=$(printf '%s' "$VERSION" | sed 's/-.*//')
IDENTITY=${SIGNING_IDENTITY:-Apple Notes MCP Signing}
OUT=${OUT:-dist}
APP="$OUT/AppleNotesMCP.app"

binary() {  # builds one architecture in its own scratch path and prints the binary path
  swift build -c release --triple "$1-apple-macosx26.0" --scratch-path ".build/$1" --product AppleNotesMCP >&2
  echo "$(swift build -c release --triple "$1-apple-macosx26.0" --scratch-path ".build/$1" --show-bin-path)/AppleNotesMCP"
}
ARM=$(binary arm64)
X86=$(binary x86_64)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$ARM" "$X86" -output "$APP/Contents/MacOS/AppleNotesMCP"
awk -v v="$VERSION" -v b="$BUILD_NUMBER" '
      /CFBundleVersion/ { print; getline; sub(/>[^<]*</, ">" b "<"); print; next }
      { gsub(/__VERSION__/, v); print }' Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier com.ailenshen.apple-notes-mcp --timestamp=none "$APP"
else
  echo "warning: signing identity \"$IDENTITY\" not found; ad-hoc signing." >&2
  echo "         macOS will ask for permissions again after every rebuild." >&2
  codesign --force --sign - --identifier com.ailenshen.apple-notes-mcp "$APP"
fi
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /designated requirement: /p'
lipo -archs "$APP/Contents/MacOS/AppleNotesMCP" | sed 's/^/architectures: /'
echo "built $APP ($VERSION)"
