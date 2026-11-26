#!/bin/bash
# Builds what the engine (CeauKit's CeauCore) links on Android: FFmpeg, and
# libass with the three libraries it draws text with.
#
#   Scripts/build-engine-libs.sh              arm64-v8a
#   Scripts/build-engine-libs.sh x86_64       another ABI (arm64-v8a, armeabi-v7a, x86_64)
#   Scripts/build-engine-libs.sh arm64-v8a armeabi-v7a x86_64     several, one after the other
#
# x86_64 needs nasm (FFmpeg's x86 assembly; Homebrew's, `brew install nasm`):
# without it the build stops rather than configure FFmpeg without assembly.
# armeabi-v7a is built for ARMv7-A with NEON and Thumb-2, the baseline of
# every 32-bit Android that runs API 28 and later.
#
# The sources are the ones CeauKit's own scripts fetched and patched, in
# ../CeauKit/Vendor/build/src: run its Scripts/build-ffmpeg.sh and
# Scripts/build-libass.sh on this Mac once first. They are read and never
# written here; every build is made out of their tree, in build/. FFmpeg's
# is copied to build/src first, and the patches only Android needs
# (Patches/ffmpeg-android) are applied to the copy, so that CeauKit's own
# tree, and its builds for Apple's systems, are left as they were.
#
# What comes out, for each ABI, in build/android/<abi>/install:
#
#   lib/libavutil.so libswresample.so libswscale.so libavcodec.so
#       libavformat.so libavfilter.so      FFmpeg, LGPL, a library each, so
#                                           that it can be replaced on its own;
#                                           OpenSSL is linked into libavformat
#   lib/libass.so                          libass, with FreeType and HarfBuzz
#                                           (FTL and MIT, not LGPL) linked into it,
#                                           and a font provider of Android's
#   lib/libceau_fribidi.so                      FriBidi, LGPL 2.1, a library of its
#                                           own that libass.so names as NEEDED,
#                                           so that it can be replaced
#   include/                               their headers
#
# FFmpeg is configured as CeauKit configures it for Apple's systems, less what
# only Apple has (VideoToolbox, AudioToolbox, Secure Transport) and less what
# the engine only uses on them (dav1d, libxml2 for DASH). With MediaCodec's
# decoders, which the engine reaches by their names. libass knows no font
# service Android has (Core Text, fontconfig, DirectWrite): the app names
# the font a line falls back on itself, and Patches/libass-android gives
# libass a provider that asks Android, through the NDK's AFontMatcher, for a
# font for each letter that one lacks (Arabic, Hebrew, Thai, the scripts of
# India). AFontMatcher came with Android 10: on Android 9 the provider reads
# the system's own list of its fonts instead. It is applied to a copy of
# CeauKit's libass, as FFmpeg's are.
#
# https goes through OpenSSL in place of Secure Transport, built here from
# its release (fetched once into build/downloads, held to the SHA-256 below).
# OpenSSL 3 keeps FFmpeg under the LGPL 2.1 as it is: FFmpeg's configure
# asks for --enable-version3 with it only in a GPL build. mbedTLS would make
# FFmpeg LGPL 3. Which roots are trusted is the app's to say: it writes
# Android's own (the system's and the ones the user added) to a file and
# names it in SSL_CERT_FILE before anything plays (TrustAnchors.kt), and
# Patches/ffmpeg-android/0003 has every connection that names no file of
# its own take that one. That reaches every connection FFmpeg makes, the
# ones a playlist leads to among them, which an option given with the media
# does not: FFmpeg's HLS reader hands no TLS option on to them.
#
# Needed: the Android NDK. It is looked for where CeauKit's
# Scripts/check-android.sh looks (~/Library/Developer/CeauKitAndroidCheck),
# or ANDROID_NDK_HOME says. ANDROID_API is the oldest Android the libraries
# run on (28, Android 9, the app's minimum, if not said); JOBS the compile
# jobs at a time.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CEAUKIT="${CEAUKIT:-$(cd "$ROOT/../CeauKit" 2>/dev/null && pwd || true)}"
TOOLS="${CEAUKIT_ANDROID_TOOLS:-$HOME/Library/Developer/CeauKitAndroidCheck}"
API="${ANDROID_API:-28}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

last_of() {
    local path found=""
    for path in "$@"; do
        [[ -e "$path" ]] && found="$path"
    done
    printf '%s' "$found"
}

# MARK: Sources

[[ -n "$CEAUKIT" && -d "$CEAUKIT/Vendor/build/src" ]] \
    || die "no CeauKit beside this checkout with its sources fetched (../CeauKit/Vendor/build/src); set CEAUKIT"
SOURCES="$CEAUKIT/Vendor/build/src"
FFMPEG_SOURCE="$(last_of "$SOURCES"/ffmpeg-*/configure)"
FREETYPE_SOURCE="$(last_of "$SOURCES"/freetype-*/configure)"
FRIBIDI_SOURCE="$(last_of "$SOURCES"/fribidi-*/lib/fribidi.c)"
HARFBUZZ_SOURCE="$(last_of "$SOURCES"/harfbuzz-*/src/harfbuzz.cc)"
LIBASS_SOURCE="$(last_of "$SOURCES"/libass-*/configure)"
[[ -n "$FFMPEG_SOURCE" && -n "$FREETYPE_SOURCE" && -n "$FRIBIDI_SOURCE" && -n "$HARFBUZZ_SOURCE" && -n "$LIBASS_SOURCE" ]] \
    || die "CeauKit's sources are not all there: run its Scripts/build-ffmpeg.sh and Scripts/build-libass.sh once"
FFMPEG_SOURCE="$(dirname "$FFMPEG_SOURCE")"
FREETYPE_SOURCE="$(dirname "$FREETYPE_SOURCE")"
FRIBIDI_SOURCE="$(dirname "$(dirname "$FRIBIDI_SOURCE")")"
HARFBUZZ_SOURCE="$(dirname "$(dirname "$HARFBUZZ_SOURCE")")"
LIBASS_SOURCE="$(dirname "$LIBASS_SOURCE")"

# The engine leans on CeauKit's patches to FFmpeg, so a source that does not
# carry the ones CeauKit has now would build an FFmpeg the engine was not
# written for. CeauKit's script stamps the source with what it applied.
patches_id="$(cat "$CEAUKIT"/Patches/ffmpeg/*.patch 2>/dev/null | shasum -a 256 | cut -c1-16)"
[[ "$(cat "$FFMPEG_SOURCE/.ceaukit-patches" 2>/dev/null)" == "$patches_id" ]] \
    || die "$FFMPEG_SOURCE does not carry CeauKit's current patches: run CeauKit's Scripts/build-ffmpeg.sh"

# Some of CeauKit's patches are made to Secure Transport, which Android has
# not: what a failed handshake says, and the certificate a caller trusts by
# itself and the one that was turned down. Patches/ffmpeg-android does the
# same to OpenSSL's side of FFmpeg, and has what MediaCodec's decoders need
# to be shown by a player: a call that returns from a decoder that has
# stalled, and one that hands a running decoder another surface. They go
# onto a copy of CeauKit's patched source, made afresh whenever either set of
# patches changes.
android_patches_id="$(cat "$ROOT"/Patches/ffmpeg-android/*.patch 2>/dev/null | shasum -a 256 | cut -c1-16)"
ANDROID_FFMPEG_SOURCE="$ROOT/build/src/$(basename "$FFMPEG_SOURCE")-android"
if [[ "$(cat "$ANDROID_FFMPEG_SOURCE/.ceau-android-patches" 2>/dev/null)" != "$patches_id $android_patches_id" ]]; then
    log "FFmpeg's source for Android, in ${ANDROID_FFMPEG_SOURCE#"$ROOT"/}"
    rm -rf "$ANDROID_FFMPEG_SOURCE" && mkdir -p "$(dirname "$ANDROID_FFMPEG_SOURCE")"
    cp -R "$FFMPEG_SOURCE" "$ANDROID_FFMPEG_SOURCE"
    for patch in "$ROOT"/Patches/ffmpeg-android/*.patch; do
        [[ -f "$patch" ]] || continue
        echo "applying $(basename "$patch")"
        patch -d "$ANDROID_FFMPEG_SOURCE" -p1 --no-backup-if-mismatch < "$patch" > /dev/null \
            || die "$(basename "$patch") does not apply to CeauKit's FFmpeg"
    done
    echo "$patches_id $android_patches_id" > "$ANDROID_FFMPEG_SOURCE/.ceau-android-patches"
fi

# libass's own patches for Android: the font provider above. They go onto a
# copy of CeauKit's libass made afresh whenever they change.
libass_android_patches_id="$(cat "$ROOT"/Patches/libass-android/*.patch 2>/dev/null | shasum -a 256 | cut -c1-16)"
ANDROID_LIBASS_SOURCE="$ROOT/build/src/$(basename "$LIBASS_SOURCE")-android"
if [[ "$(cat "$ANDROID_LIBASS_SOURCE/.ceau-android-patches" 2>/dev/null)" != "$libass_android_patches_id" ]]; then
    log "libass's source for Android, in ${ANDROID_LIBASS_SOURCE#"$ROOT"/}"
    rm -rf "$ANDROID_LIBASS_SOURCE" && mkdir -p "$(dirname "$ANDROID_LIBASS_SOURCE")"
    # With the files' times as they were: a copy stamps each file with the
    # moment it was copied, and when that put configure a second before
    # aclocal.m4, make set out to write configure again with an autoconf
    # this Mac does not have.
    cp -pR "$LIBASS_SOURCE" "$ANDROID_LIBASS_SOURCE"
    for patch in "$ROOT"/Patches/libass-android/*.patch; do
        [[ -f "$patch" ]] || continue
        echo "applying $(basename "$patch")"
        patch -d "$ANDROID_LIBASS_SOURCE" -p1 --no-backup-if-mismatch < "$patch" > /dev/null \
            || die "$(basename "$patch") does not apply to CeauKit's libass"
    done
    echo "$libass_android_patches_id" > "$ANDROID_LIBASS_SOURCE/.ceau-android-patches"
fi

# MARK: OpenSSL

# The release the build is held to, as its own page publishes it
# (https://github.com/openssl/openssl/releases). 3.5 is a release OpenSSL
# keeps up until April 2030. Fetched once; a file that does not match the
# SHA-256 is thrown away rather than built.
OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
OPENSSL_SOURCE="$ROOT/build/src/openssl-$OPENSSL_VERSION"
if [[ ! -f "$OPENSSL_SOURCE/.unpacked" ]]; then
    archive="$ROOT/build/downloads/openssl-$OPENSSL_VERSION.tar.gz"
    mkdir -p "$(dirname "$archive")"
    if [[ ! -f "$archive" ]]; then
        log "Fetching OpenSSL $OPENSSL_VERSION"
        curl -fL --retry 2 --progress-bar -o "$archive.part" "$OPENSSL_URL" || die "could not fetch $OPENSSL_URL"
        mv "$archive.part" "$archive"
    fi
    actual="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
    [[ "$actual" == "$OPENSSL_SHA256" ]] \
        || { rm -f "$archive"; die "openssl-$OPENSSL_VERSION.tar.gz is not the release: SHA-256 $actual"; }
    rm -rf "$OPENSSL_SOURCE" && mkdir -p "$(dirname "$OPENSSL_SOURCE")"
    tar -xzf "$archive" -C "$(dirname "$OPENSSL_SOURCE")"
    touch "$OPENSSL_SOURCE/.unpacked"
fi

# MARK: Tools

NDK="${ANDROID_NDK_HOME:-$(last_of "$TOOLS"/android-ndk-*)}"
[[ -n "$NDK" && -d "$NDK/toolchains/llvm/prebuilt" ]] || die "no Android NDK under $TOOLS: set ANDROID_NDK_HOME"
BIN="$(last_of "$NDK"/toolchains/llvm/prebuilt/*/bin)"
[[ -x "$BIN/clang" ]] || die "the NDK at $NDK has no clang"
HOST_CC="$(xcrun -sdk macosx -f clang) -isysroot $(xcrun -sdk macosx --show-sdk-path)"

# MARK: Building

build() {
    local abi="$1" triple ffmpeg_arch openssl_target extra=() autotools_host
    case "$abi" in
        arm64-v8a) triple=aarch64-linux-android; autotools_host=$triple; ffmpeg_arch=aarch64; openssl_target=android-arm64 ;;
        armeabi-v7a)
            # The NDK names its 32-bit ARM compilers armv7a-linux-androideabi,
            # while its sysroot and every autotools host say arm-linux-androideabi.
            triple=armv7a-linux-androideabi; autotools_host=arm-linux-androideabi
            ffmpeg_arch=arm; openssl_target=android-arm
            extra+=(--cpu=armv7-a --enable-neon --enable-thumb) ;;
        x86_64)    triple=x86_64-linux-android;  autotools_host=$triple; ffmpeg_arch=x86_64;  openssl_target=android-x86_64
                   command -v nasm >/dev/null || die "nasm is needed for FFmpeg's x86 assembly: brew install nasm"
                   extra+=(--x86asmexe="$(command -v nasm)") ;;
        *) die "$abi is not an ABI this knows: arm64-v8a, armeabi-v7a, x86_64" ;;
    esac
    local cc="$BIN/$triple$API-clang" cxx="$BIN/$triple$API-clang++"
    local out="$ROOT/build/android/$abi" prefix="$ROOT/build/android/$abi/install"
    # Pages of 16 KB, which Android 15 devices can have and Google Play asks for.
    local ldflags="-Wl,-z,max-page-size=16384"
    mkdir -p "$out" "$prefix/lib" "$prefix/include"

    log "OpenSSL $OPENSSL_VERSION for $abi"
    # Static libraries, linked into libavformat, whose list of exported
    # names (av* and avformat*) keeps OpenSSL's to itself. Without what
    # FFmpeg never asks of it: its programs and tests, engines and modules
    # loaded at run time, a configuration file read at start, compression,
    # QUIC, the parts of X.509 a client of a web server does not use
    # (OCSP, certificate transparency, CMS, CMP, time stamps), SSL 3, and
    # the old, rare and national algorithms no server offers alone (DSA,
    # ARIA, Camellia and the like, and the post-quantum signatures no
    # certificate is signed with yet; the post-quantum key exchange that
    # OpenSSL offers first is kept). That is 3.5 MB in libavformat in place
    # of 4.0. OPENSSLDIR is a place no Android has: the roots are the ones
    # the app names in SSL_CERT_FILE, or none.
    local ssl="$out/openssl/install"
    local ssl_options=(
        "$openssl_target" -D__ANDROID_API__="$API"
        --prefix="$ssl" --openssldir=/nonexistent/openssl --libdir=lib
        no-shared no-module no-dso no-engine no-legacy no-autoload-config
        no-apps no-tests no-docs no-ui-console no-comp no-zlib no-quic no-sctp
        no-ocsp no-ct no-cms no-cmp no-ts no-srp
        no-ssl3 no-weak-ssl-ciphers
        no-dsa no-aria no-camellia no-idea no-seed no-bf no-cast no-rc2 no-rc4 no-rc5
        no-md2 no-md4 no-mdc2 no-rmd160 no-whirlpool no-siphash no-siv no-ocb no-scrypt no-argon2
        no-gost no-sm2 no-sm3 no-sm4 no-ec2m no-slh-dsa no-ml-dsa
        -fPIC -g
    )
    local ssl_stamp="$ssl/built-with" ssl_identity="$OPENSSL_SHA256 ${ssl_options[*]}"
    if [[ -f "$ssl_stamp" && "$(cat "$ssl_stamp")" == "$ssl_identity" ]]; then
        echo "reusing the finished build in ${out#"$ROOT"/}/openssl"
    else
        rm -rf "$out/openssl" && mkdir -p "$out/openssl" && cd "$out/openssl"
        # OpenSSL finds the NDK's compilers on the PATH, by the API it is told.
        PATH="$BIN:$PATH" ANDROID_NDK_ROOT="$NDK" CC=clang "$OPENSSL_SOURCE/Configure" "${ssl_options[@]}" \
            > configure.log 2>&1 || { tail -30 configure.log; die "OpenSSL: Configure failed for $abi"; }
        PATH="$BIN:$PATH" ANDROID_NDK_ROOT="$NDK" make -j"$JOBS" build_libs > make.log 2>&1 \
            || { tail -40 make.log; die "OpenSSL: make failed for $abi"; }
        PATH="$BIN:$PATH" ANDROID_NDK_ROOT="$NDK" make install_dev > install.log 2>&1 \
            || { tail -20 install.log; die "OpenSSL: make install_dev failed for $abi"; }
        echo "$ssl_identity" > "$ssl_stamp"
    fi

    log "FFmpeg for $abi (Android $API)"
    local options=(
        --prefix="$prefix"
        --enable-cross-compile --target-os=android --arch="$ffmpeg_arch"
        --cc="$cc" --cxx="$cxx" --ar="$BIN/llvm-ar" --nm="$BIN/llvm-nm"
        --ranlib="$BIN/llvm-ranlib" --strip="$BIN/llvm-strip"
        --host-cc="$HOST_CC"
        --extra-cflags="-I$ssl/include"
        --extra-ldflags="$ldflags -L$ssl/lib"
        --pkg-config=false
        --enable-pic --enable-shared --disable-static
        --disable-programs --disable-doc --enable-debug
        # Installed with their symbols: Gradle strips what goes into an APK
        # and keeps the symbols for Play's crash reports (README, "Release
        # builds"). Stripped at install, they would be gone for good.
        --disable-stripping
        --disable-avdevice --disable-encoders --disable-muxers
        --disable-autodetect --enable-pthreads
        --enable-zlib --enable-iconv --enable-jni --enable-mediacodec
        --enable-openssl
        --disable-demuxer=aa
        --disable-filters
        --enable-filter=bwdif,yadif,scale,format,null,anull,aresample,aformat,volume,acompressor,dynaudnorm,loudnorm
        ${extra[@]+"${extra[@]}"}
    )
    local stamp="$prefix/ffmpeg-configured-with"
    local identity="$patches_id $android_patches_id $ssl_identity ${options[*]}"
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$identity" ]]; then
        echo "reusing the finished build in ${out#"$ROOT"/}/ffmpeg"
    else
        rm -rf "$out/ffmpeg" && mkdir -p "$out/ffmpeg" && cd "$out/ffmpeg"
        "$ANDROID_FFMPEG_SOURCE/configure" "${options[@]}" > configure.log 2>&1 \
            || { tail -30 configure.log; die "FFmpeg: configure failed for $abi"; }
        grep -qE '^#define CONFIG_(GPL|NONFREE|VERSION3) 1' config.h \
            && die "FFmpeg for $abi was configured with GPL, LGPL 3 or nonfree parts"
        grep -q '^#define FFMPEG_LICENSE "LGPL version 2.1 or later"' config.h \
            || die "FFmpeg for $abi is not under the LGPL 2.1"
        grep -q '^#define CONFIG_H264_MEDIACODEC_DECODER 1' config_components.h || die "FFmpeg for $abi has no MediaCodec decoder"
        grep -q '^#define CONFIG_HTTPS_PROTOCOL 1' config_components.h || die "FFmpeg for $abi has no https"
        make -j"$JOBS" > make.log 2>&1 || { tail -40 make.log; die "FFmpeg: make failed for $abi"; }
        make install > install.log 2>&1 || { tail -20 install.log; die "FFmpeg: make install failed for $abi"; }
        echo "$identity" > "$stamp"
    fi

    log "libass for $abi"
    local deps="$out/libass-deps"
    # What the libraries were made as: raised when the way they are split into
    # files changes, and with libass's patches, so that an older build is made
    # again.
    # The previous layout left its unprefixed library in the reusable install folder.
    rm -f "$prefix/lib/libfribidi.so"
    local layout="libass-fribidi-shared-2 android-patches-$libass_android_patches_id"
    if [[ -f "$prefix/lib/libass.so" && -f "$prefix/lib/libceau_fribidi.so" && "$(cat "$deps/done" 2>/dev/null)" == "$layout" ]]; then
        echo "reusing the finished build in ${out#"$ROOT"/}/libass-deps"
        return
    fi
    rm -rf "$deps" && mkdir -p "$deps/freetype" "$deps/harfbuzz" "$deps/fribidi" "$deps/libass" \
        "$deps/install/lib" "$deps/install/include/harfbuzz" "$deps/install/include/fribidi"
    local host="$autotools_host" flags="-O2 -fPIC -g"
    # The archiver and the rest of the NDK's, not the Mac's: a configure finds
    # the Mac's by itself, which makes archives the NDK's linker cannot read.
    local target_tools=(AR="$BIN/llvm-ar" RANLIB="$BIN/llvm-ranlib" NM="$BIN/llvm-nm" STRIP="$BIN/llvm-strip")

    # FreeType, as CeauKit builds it: told that mmap works, which its
    # configure would find out by running a program it cannot run here.
    cd "$deps/freetype"
    "$FREETYPE_SOURCE/configure" --host="$host" --prefix="$deps/install" \
        --enable-static --disable-shared --enable-freetype-config=no ac_cv_func_mmap_fixed_mapped=yes \
        --with-zlib=yes --with-bzip2=no --with-png=no --with-harfbuzz=no --with-brotli=no --with-librsvg=no \
        CC="$cc" CC_BUILD="$HOST_CC" CFLAGS="$flags" "${target_tools[@]}" \
        PKG_CONFIG=false ZLIB_CFLAGS=" " ZLIB_LIBS="-lz" \
        > configure.log 2>&1 || { tail -30 configure.log; die "FreeType: configure failed for $abi"; }
    make -j"$JOBS" > make.log 2>&1 || { tail -40 make.log; die "FreeType: make failed for $abi"; }
    make install > install.log 2>&1 || { tail -20 install.log; die "FreeType: make install failed for $abi"; }

    # HarfBuzz as one source file, with no exceptions or run-time types, so
    # that it needs nothing of the C++ library when it runs.
    # shellcheck disable=SC2086
    $cxx $flags -std=c++17 -fno-exceptions -fno-rtti -fno-threadsafe-statics -fvisibility-inlines-hidden \
        -DHAVE_PTHREAD=1 -DHB_NO_PRAGMA_GCC_DIAGNOSTIC_ERROR \
        -c "$HARFBUZZ_SOURCE/src/harfbuzz.cc" -o "$deps/harfbuzz/harfbuzz.o" > "$deps/harfbuzz/compile.log" 2>&1 \
        || { tail -30 "$deps/harfbuzz/compile.log"; die "HarfBuzz: compile failed for $abi"; }
    "$BIN/llvm-ar" rcs "$deps/install/lib/libharfbuzz.a" "$deps/harfbuzz/harfbuzz.o"
    cp "$HARFBUZZ_SOURCE"/src/hb*.h "$deps/install/include/harfbuzz/"

    # FriBidi's files as they are, with its tables ready made.
    local version file objects=()
    version="$(basename "$FRIBIDI_SOURCE")" && version="${version#fribidi-}"
    local major="${version%%.*}" rest="${version#*.}"
    sed -e "s/@PACKAGE@/fribidi/" -e "s/@PACKAGE_NAME@/GNU FriBidi/" -e "s/@PACKAGE_BUGREPORT@//" \
        -e "s/@FRIBIDI_VERSION@/$version/" -e "s/@FRIBIDI_MAJOR_VERSION@/$major/" \
        -e "s/@FRIBIDI_MINOR_VERSION@/${rest%%.*}/" -e "s/@FRIBIDI_MICRO_VERSION@/${rest#*.}/" \
        -e "s/@FRIBIDI_INTERFACE_VERSION@/4/g" -e "s/@SIZEOF_INT@/4/" \
        -e "s/@FRIBIDI_MSVC_BUILD_PLACEHOLDER@//" -e "s/@configure_input@/made by build-engine-libs.sh/" \
        "$FRIBIDI_SOURCE/lib/fribidi-config.h.in" > "$deps/install/include/fribidi/fribidi-config.h"
    cp "$FRIBIDI_SOURCE"/lib/fribidi*.h "$deps/install/include/fribidi/"
    for file in "$FRIBIDI_SOURCE"/lib/*.c; do
        local object="$deps/fribidi/$(basename "${file%.c}").o"
        # shellcheck disable=SC2086
        $cc $flags -I"$deps/install/include/fribidi" -I"$FRIBIDI_SOURCE/lib" \
            -DHAVE_STDLIB_H=1 -DHAVE_STRING_H=1 -DHAVE_STRINGS_H=1 -DHAVE_STRINGIZE=1 -DSTDC_HEADERS=1 \
            -c "$file" -o "$object" >> "$deps/fribidi/compile.log" 2>&1 \
            || { tail -30 "$deps/fribidi/compile.log"; die "FriBidi: compile failed for $abi"; }
        objects+=("$object")
    done
    # A shared library of its own: FriBidi is LGPL 2.1, and a user can only
    # replace it as the licence asks if it is not part of another file. The
    # one in install/lib is what libass's configure and link find; the
    # private SONAME keeps the loader from reusing an older FriBidi supplied by a TV vendor.
    "$cc" -shared -o "$deps/install/lib/libceau_fribidi.so" -Wl,-soname,libceau_fribidi.so $ldflags \
        -Wl,--no-undefined "${objects[@]}" > "$deps/fribidi/link.log" 2>&1 \
        || { tail -30 "$deps/fribidi/link.log"; die "FriBidi: link failed for $abi"; }
    cp "$deps/install/lib/libceau_fribidi.so" "$prefix/lib/libceau_fribidi.so"

    # libass, with none of the font providers its configure knows: Android's
    # is compiled on its own below, since libass's Makefile.in does not know
    # the file.
    cd "$deps/libass"
    "$ANDROID_LIBASS_SOURCE/configure" --host="$host" --prefix="$deps/install" \
        --enable-static --disable-shared \
        --disable-fontconfig --disable-directwrite --disable-libunibreak --disable-coretext \
        --disable-require-system-font-provider \
        CC="$cc" CFLAGS="$flags" "${target_tools[@]}" PKG_CONFIG=false \
        FREETYPE_CFLAGS="-I$deps/install/include/freetype2" FREETYPE_LIBS="-L$deps/install/lib -lfreetype -lz" \
        FRIBIDI_CFLAGS="-I$deps/install/include/fribidi" FRIBIDI_LIBS="-L$deps/install/lib -lceau_fribidi" \
        HARFBUZZ_CFLAGS="-I$deps/install/include/harfbuzz" HARFBUZZ_LIBS="-L$deps/install/lib -lharfbuzz" \
        > configure.log 2>&1 || { tail -30 configure.log; die "libass: configure failed for $abi"; }
    make -j"$JOBS" > make.log 2>&1 || { tail -40 make.log; die "libass: make failed for $abi"; }
    make install > install.log 2>&1 || { tail -20 install.log; die "libass: make install failed for $abi"; }
    # The provider calls AFontMatcher, which Android has from 10 (API 29),
    # as weak references behind a check of the system's version: a call
    # with no check before it stops the build here, where it would otherwise
    # be a call of a null address on Android 9.
    local android_file
    : > "$deps/libass/android.log"
    for android_file in ass_android ass_android_fonts; do
        # shellcheck disable=SC2086
        $cc $flags -DHAVE_CONFIG_H -I"$deps/libass" -I"$ANDROID_LIBASS_SOURCE" -I"$ANDROID_LIBASS_SOURCE/libass" \
            -I"$deps/install/include/freetype2" -I"$deps/install/include/harfbuzz" -I"$deps/install/include/fribidi" \
            -Wall -Werror -Werror=unguarded-availability \
            -c "$ANDROID_LIBASS_SOURCE/libass/$android_file.c" -o "$deps/libass/$android_file.o" \
            >> "$deps/libass/android.log" 2>&1 || { tail -30 "$deps/libass/android.log"; die "libass: Android's font provider failed to compile for $abi"; }
    done

    # libass with FreeType, HarfBuzz and Android's font provider in it, and
    # FriBidi named, not in it. libandroid is the system's (AFontMatcher).
    "$cc" -shared -o "$prefix/lib/libass.so" -Wl,-soname,libass.so $ldflags \
        "$deps/libass/ass_android.o" "$deps/libass/ass_android_fonts.o" \
        -Wl,--whole-archive "$deps/install/lib/libass.a" -Wl,--no-whole-archive \
        "$deps/install/lib/libharfbuzz.a" "$deps/install/lib/libfreetype.a" \
        "$deps/install/lib/libceau_fribidi.so" -landroid -lz -lm > "$deps/link.log" 2>&1 || { tail -30 "$deps/link.log"; die "libass: link failed for $abi"; }
    rm -rf "$prefix/include/ass" && cp -R "$deps/install/include/ass" "$prefix/include/ass"
    echo "$layout" > "$deps/done"
}

ABIS=("$@")
[[ ${#ABIS[@]} -gt 0 ]] || ABIS=(arm64-v8a)
for abi in "${ABIS[@]}"; do
    build "$abi"
done
log "Built for ${ABIS[*]}: build/android/<abi>/install/lib"
ls -la "$ROOT/build/android/${ABIS[0]}/install/lib/"*.so
