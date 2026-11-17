#!/bin/bash
# Lays this repository's upstream archives out as the Android build reads
# them, so that the libraries Ceau for Android ships can be built again from
# what is here and nothing else:
#
#   android/Scripts/prepare-sources.sh
#   CEAUKIT="$PWD/android/work/CeauKit" android/Scripts/build-engine-libs.sh arm64-v8a armeabi-v7a x86_64
#
# (CEAUKIT is an absolute path: the build changes directory as it goes.)
#
# The Android build (build-engine-libs.sh, a copy of the script the app is
# built with) starts from CeauKit's sources: the upstream archives unpacked,
# with the patches CeauKit applies on Apple's systems already in them, as
# CeauKit's own scripts leave them in CeauKit/Vendor/build/src. This makes
# that place in android/work/CeauKit from dist/ and Patches/ (the same
# archives and patches as the Apple builds), stamps FFmpeg as CeauKit's script
# stamps it, and puts OpenSSL's archive where the Android build looks for it.
# The Android build then applies android/Patches on copies of those sources
# and builds each ABI's shared libraries into android/build/android/<abi>.
#
# Needed for the build: the Android NDK (ANDROID_NDK_HOME, or the place the
# script names), python3, and nasm for x86_64.
set -euo pipefail

ANDROID_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ANDROID_DIR/.." && pwd)"
WORK="$ANDROID_DIR/work/CeauKit"
SOURCES="$WORK/Vendor/build/src"

die() { printf 'error: %s\n' "$*" >&2; exit 2; }

(cd "$REPO/dist" && shasum -a 256 -c ../SHA256SUMS --quiet) || die "an archive in dist/ does not match SHA256SUMS"

rm -rf "$WORK"
mkdir -p "$SOURCES" "$WORK/Patches"
cp -R "$REPO/Patches/ffmpeg" "$WORK/Patches/ffmpeg"

for library in ffmpeg freetype fribidi harfbuzz libass; do
    archive="$(ls "$REPO"/dist/"$library"-*.tar.xz)"
    tar -xf "$archive" -C "$SOURCES"
done

apply() {
    local patches="$1" source="$2" patch
    for patch in "$patches"/*.patch; do
        [[ -f "$patch" ]] || continue
        echo "applying $(basename "$patches")/$(basename "$patch")"
        patch -d "$source" -p1 --no-backup-if-mismatch < "$patch" > /dev/null \
            || die "$(basename "$patch") does not apply to $(basename "$source")"
    done
}
apply "$REPO/Patches/ffmpeg" "$(ls -d "$SOURCES"/ffmpeg-*/)"
apply "$REPO/Patches/freetype" "$(ls -d "$SOURCES"/freetype-*/)"
apply "$REPO/Patches/libass" "$(ls -d "$SOURCES"/libass-*/)"

# What CeauKit's build-ffmpeg.sh writes, and the Android build checks: the
# FFmpeg patches the source carries.
cat "$REPO"/Patches/ffmpeg/*.patch | shasum -a 256 | cut -c1-16 > "$(ls -d "$SOURCES"/ffmpeg-*/).ceaukit-patches"

mkdir -p "$ANDROID_DIR/build/downloads"
cp "$REPO"/dist/openssl-*.tar.gz "$ANDROID_DIR/build/downloads/"

echo "sources ready in ${WORK#"$REPO"/}; now:"
echo "  CEAUKIT=\"$WORK\" android/Scripts/build-engine-libs.sh arm64-v8a armeabi-v7a x86_64"
