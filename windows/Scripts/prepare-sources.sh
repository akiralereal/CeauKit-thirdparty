#!/bin/bash
# Lays this repository's upstream archives out as the Windows build reads
# them, so that the libraries Ceau for Windows ships can be built again from
# what is here and nothing else:
#
#   windows/Scripts/prepare-sources.sh
#   CEAUKIT_DIR="$PWD/windows/work/CeauKit" windows/Scripts/build-engine-libs.sh x86_64 aarch64
#
# (CEAUKIT_DIR is an absolute path: the build changes directory as it goes.)
#
# The Windows build (build-engine-libs.sh, a copy of the script the app is
# built with) starts from CeauKit's sources: the upstream archives unpacked,
# with the patches CeauKit applies on Apple's systems already in them, as
# CeauKit's own scripts leave them in CeauKit/Vendor/build/src. This makes
# that place in windows/work/CeauKit from dist/ and Patches/ (the same
# archives and patches as the Apple builds), stamps each source as CeauKit's
# scripts stamp it, writes libxml2's licence beside its source as
# build-ffmpeg.sh does, and puts the archives of zlib and win-iconv, the two
# sources that are not CeauKit's, where the Windows build looks for them. The
# Windows build then applies windows/Patches on copies of those sources and
# builds each architecture's DLLs into windows/build/windows/<arch>.
#
# Needed for the build, on a Mac: swift.org's toolchain for the Mac
# (CEAU_WINDOWS_TOOLCHAIN, its usr/bin), Microsoft's C runtime and Windows
# SDK as xwin lays them out (CEAU_WINDOWS_SYSROOT), nasm, meson, ninja and
# pkg-config, and Xcode's command line tools.
set -euo pipefail

WINDOWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$WINDOWS_DIR/.." && pwd)"
WORK="$WINDOWS_DIR/work/CeauKit"
SOURCES="$WORK/Vendor/build/src"

die() { printf 'error: %s\n' "$*" >&2; exit 2; }

# FFmpeg's configure and make take their paths apart at spaces.
[[ "$REPO" != *" "* ]] || die "this checkout is in a folder with a space in its name, which FFmpeg's build cannot work in"

(cd "$REPO/dist" && shasum -a 256 -c ../SHA256SUMS --quiet) || die "an archive in dist/ does not match SHA256SUMS"

rm -rf "$WORK"
mkdir -p "$SOURCES" "$WORK/Patches"
cp -R "$REPO/Patches/ffmpeg" "$WORK/Patches/ffmpeg"

# What the patches of a library come to, as CeauKit's scripts reckon it.
patches_id() {
    { cat "$REPO/Patches/$1"/*.patch 2>/dev/null || true; } | shasum -a 256 | cut -c1-16
}

# Unpacks a library's archive and applies Patches/<library> to it, in name
# order, as CeauKit's scripts do. Sets SOURCE to the unpacked source and SHA
# to the archive's SHA-256.
unpack() {
    local library="$1" archive patch
    archive="$(ls "$REPO"/dist/"$library"-*.tar.xz)"
    SHA="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
    SOURCE="$SOURCES/$(basename "$archive" .tar.xz)"
    tar -xf "$archive" -C "$SOURCES"
    [[ -d "$SOURCE" ]] || die "$(basename "$archive") did not unpack to $(basename "$SOURCE")"
    for patch in "$REPO/Patches/$library"/*.patch; do
        [[ -f "$patch" ]] || continue
        echo "applying $library/$(basename "$patch")"
        patch -d "$SOURCE" -p1 --no-backup-if-mismatch < "$patch" > /dev/null \
            || die "$(basename "$patch") does not apply to $(basename "$SOURCE")"
    done
}

# FFmpeg is stamped with its patches (build-ffmpeg.sh's .ceaukit-patches),
# which the Windows build checks; every other source with its archive and its
# patches (.ceaukit-unpacked), which the Windows build needs to find.
unpack ffmpeg
patches_id ffmpeg > "$SOURCE/.ceaukit-patches"
for library in dav1d libxml2 freetype harfbuzz fribidi libass; do
    unpack "$library"
    echo "$SHA $(patches_id "$library")" > "$SOURCE/.ceaukit-unpacked"
    if [[ "$library" == libxml2 ]]; then LIBXML2_SOURCE="$SOURCE"; fi
done

# libxml2's licence as build-ffmpeg.sh writes it beside the source, and the
# Windows build copies it from there: the file Copyright, and the notices of
# dict.c and list.c, two of its files that have notices of their own.
{
    cat "$LIBXML2_SOURCE/Copyright"
    for file in dict.c list.c; do
        printf '\n%s:\n\n' "$file"
        sed -n '/^ \* Copyright/,/CONCEIVABLE MANNER/p' "$LIBXML2_SOURCE/$file" | sed -e 's/^ \* \{0,1\}//' -e 's/^ \*$//'
    done
} > "$LIBXML2_SOURCE/LICENSE-libxml2.txt"
cmp -s "$LIBXML2_SOURCE/LICENSE-libxml2.txt" "$REPO/LICENSES/libxml2.txt" \
    || die "libxml2's licence, written from its source, is not LICENSES/libxml2.txt"

# zlib and win-iconv, where the Windows build would otherwise fetch them to.
mkdir -p "$WINDOWS_DIR/build/downloads"
cp "$REPO"/dist/zlib-*.tar.gz "$REPO"/dist/win-iconv-*.tar.gz "$WINDOWS_DIR/build/downloads/"

echo "sources ready in ${WORK#"$REPO"/}; now:"
echo "  CEAUKIT_DIR=\"$WORK\" windows/Scripts/build-engine-libs.sh x86_64 aarch64"
