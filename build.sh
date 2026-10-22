#!/bin/zsh
# Builds build/MyLoom.app with the Command Line Tools' swiftc and clang++. No Xcode project.
# Echo cancellation links WebRTC's audio processing from Vendor/; scripts/build-webrtc.sh makes it once.
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID=local.myloom
APP=build/MyLoom.app
WEBRTC=Vendor/webrtc-audio-processing

if [[ ! -f $WEBRTC/lib/libwebrtc-audio-processing-2.a ]]; then
  echo "WebRTC audio processing isn't built yet. Run ./scripts/build-webrtc.sh first (needs: brew install meson ninja)." >&2
  exit 1
fi

# iCloud-synced folders such as the Desktop keep adding Finder attributes to bundles, and
# codesign refuses those. So the app is put together and signed in a temporary folder, then copied in.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STAGED=$WORK/MyLoom.app
mkdir -p "$STAGED/Contents/MacOS" "$STAGED/Contents/Resources" build/obj
cp Info.plist "$STAGED/Contents/Info.plist"
# The Supabase setup SQL, for Sharing Setup's Copy Setup SQL button.
cp supabase/setup.sql "$STAGED/Contents/Resources/setup.sql"

# The C interface to WebRTC's echo canceller.
clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=14.0 $(cat $WEBRTC/cflags.txt) \
  -I$WEBRTC/include/webrtc-audio-processing-2 -I$WEBRTC/include \
  -c Native/EchoCanceller.cpp -o build/obj/EchoCanceller.o

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -import-objc-header Native/EchoCanceller.h \
  Sources/*.swift build/obj/EchoCanceller.o $WEBRTC/lib/*.a -lc++ \
  -o "$STAGED/Contents/MacOS/MyLoom"

xattr -cr "$STAGED"

# Ad-hoc signature with an identifier-only designated requirement, so macOS privacy grants
# (Screen Recording, Camera, Microphone) are tied to the bundle ID rather than to this exact build.
codesign --force --sign - --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" "$STAGED"

rm -rf "$APP"
ditto "$STAGED" "$APP"

echo "Built $PWD/$APP"
