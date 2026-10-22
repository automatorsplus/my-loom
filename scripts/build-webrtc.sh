#!/bin/zsh
# Builds WebRTC's audio processing library as static libraries in Vendor/webrtc-audio-processing,
# for build.sh to link. This is the freedesktop.org edition (the one PulseAudio and PipeWire use),
# which contains the same AEC3 echo canceller Loom ships.
#
# Needs meson and ninja (brew install meson ninja). Downloads the pinned source release, checks it
# against its published SHA-256, and builds abseil-cpp (which it depends on) into it through meson's
# wrap, so MyLoom needs nothing extra installed to run. Run it once; build.sh uses the result.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=2.1
SHA256=ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe
URL=https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-$VERSION.tar.xz
OUT=$PWD/Vendor/webrtc-audio-processing

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -fL --silent --show-error -o "$WORK/source.tar.xz" "$URL"
echo "$SHA256  $WORK/source.tar.xz" | shasum -a 256 -c -
tar -xJf "$WORK/source.tar.xz" -C "$WORK"
SOURCE=$WORK/webrtc-audio-processing-$VERSION

# Match MyLoom's minimum macOS (build.sh), or the linker warns about every object file.
export MACOSX_DEPLOYMENT_TARGET=14.0
meson setup "$WORK/build" "$SOURCE" --buildtype=release -Ddefault_library=static \
  --force-fallback-for=abseil-cpp --prefix="$WORK/install"
meson compile -C "$WORK/build"
meson install -C "$WORK/build" --quiet

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
cp -R "$WORK/install/include/." "$OUT/include/"
# WebRTC's headers include abseil's, so its headers come too.
ABSEIL=$(find "$SOURCE/subprojects" -maxdepth 1 -type d -name 'abseil-cpp-*' | head -1)
(cd "$ABSEIL" && find absl -name '*.h' -o -name '*.inc' | cpio -pdm --quiet "$OUT/include")
# The library and every abseil library it was built with.
find "$WORK/build" -name '*.a' -exec cp {} "$OUT/lib/" \;
# The compiler flags its headers expect, from its pkg-config file.
PC=$(find "$WORK/install" -name 'webrtc-audio-processing-*.pc' | head -1)
grep '^Cflags:' "$PC" | sed -e 's/^Cflags: *//' -e "s|-I[^ ]*||g" > "$OUT/cflags.txt"
echo "$VERSION" > "$OUT/VERSION"

echo "Built WebRTC audio processing $VERSION into $OUT"
ls "$OUT/lib"
