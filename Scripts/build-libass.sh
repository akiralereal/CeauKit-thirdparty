#!/bin/bash
# Builds libass, which draws subtitles that are text, for the Apple platforms
# CeauKit runs on, and packs the result for the Swift package:
#
#   Vendor/Libass.xcframework   one dynamic framework per platform
#   Vendor/CAss/                the C target CeauCore imports (headers + shim)
#
# libass needs three libraries, and they go into the same framework: FreeType
# opens fonts and makes outlines of their glyphs, HarfBuzz chooses and places
# the glyphs of a line, FriBidi puts text that runs both ways in order. The
# fonts of the system are found through Core Text. Nothing else outside the
# platform SDK is linked in.
#
# Licences: libass ISC, HarfBuzz MIT, FreeType its own (the FTL, which asks
# for a mention in the documentation), FriBidi LGPL 2.1 or later. FriBidi is
# why this is a dynamic framework of its own, as FFmpeg is: it can be replaced
# without relinking the app.
#
# Each framework carries the four licences and a privacy manifest
# (Scripts/privacy-manifest.sh), written from what the finished binary calls.
#
# Each slice also has a dSYM, made from the linked binary before the strip
# takes its local names away, and packed into the xcframework beside it.
# Xcode copies it into the archive of an app that embeds the framework, so a
# crash inside any of the four can be read; none of it ships in the app. The
# compiler writes this repository's folder as `.` in what it records, so a
# dSYM names no folder of the Mac it was built on.
#
#   Scripts/build-libass.sh                    every platform
#   Scripts/build-libass.sh macos ios          only these (the others are kept
#                                              from earlier runs, if built)
#
# Platforms: macos ios ios-simulator tvos tvos-simulator xros xros-simulator
set -euo pipefail

LIBASS=0.17.5
LIBASS_SHA256=2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc
FREETYPE=2.15.0
FREETYPE_SHA256=93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5
HARFBUZZ=15.1.0
HARFBUZZ_SHA256=0fc7c565443a5f4be7da65ac5ee5bd737d9b158dc908708b7689a0a5796b0c8d
FRIBIDI=1.0.18
FRIBIDI_SHA256=1de5e8073d035388b71d0b2d452b1da1f8caeea8a7702997b401fe1b6250727f
ALL_PLATFORMS=(macos ios ios-simulator tvos tvos-simulator xros xros-simulator)
BUNDLE_ID=com.ceaule.ceaukit.libass

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$ROOT/Vendor/build/src"
WORK="$ROOT/Vendor/build/libass"
# Every core, unless told to leave some for whatever else the Mac is doing.
JOBS="${CEAUKIT_JOBS:-$(sysctl -n hw.ncpu)}"
# Debug information for the dSYM (-g changes no code), and where the compiler
# records that the sources were: in this repository, wherever it is.
DEBUG_FLAGS="-g -fdebug-prefix-map=$ROOT=."
# A change to this script, or to the patches, is a change to what it builds.
SCRIPT_ID="$({ cat "$ROOT/Scripts/build-libass.sh" "$ROOT"/Patches/{libass,freetype,harfbuzz,fribidi}/*.patch 2>/dev/null || true; } | shasum -a 256 | cut -c1-16)"

# Keep Homebrew and friends out of a build that must only see the SDK.
unset CPATH C_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH CFLAGS LDFLAGS CPPFLAGS CXXFLAGS

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# shellcheck source=Scripts/privacy-manifest.sh
source "$ROOT/Scripts/privacy-manifest.sh"

# Downloads an archive if it is not there, checks it, and unpacks it afresh
# whenever it or the patches for it change. The patches are those in
# Patches/<name without its version>, applied in name order.
fetch() {
    local name="$1" sha="$2" url="$3" archive="$SOURCES/$1.tar.xz" actual patch
    local patches="$ROOT/Patches/${1%%-*}" identity
    mkdir -p "$SOURCES"
    if [[ ! -f "$archive" ]]; then
        log "Downloading $name"
        curl -fL --retry 3 -o "$archive" "$url"
    fi
    actual="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
    [[ "$actual" == "$sha" ]] || die "$name.tar.xz has SHA-256 $actual, expected $sha"
    identity="$sha $({ cat "$patches"/*.patch 2>/dev/null || true; } | shasum -a 256 | cut -c1-16)"
    if [[ "$(cat "$SOURCES/$name/.ceaukit-unpacked" 2>/dev/null)" != "$identity" ]]; then
        rm -rf "${SOURCES:?}/$name"
        tar -xf "$archive" -C "$SOURCES"
        for patch in "$patches"/*.patch; do
            [[ -f "$patch" ]] || continue
            log "Applying $(basename "$patch")"
            patch -d "$SOURCES/$name" -p1 --no-backup-if-mismatch < "$patch" > /dev/null \
                || die "$(basename "$patch") does not apply to $name"
        done
        echo "$identity" > "$SOURCES/$name/.ceaukit-unpacked"
    fi
}

fetch_sources() {
    fetch "libass-$LIBASS" "$LIBASS_SHA256" "https://github.com/libass/libass/releases/download/$LIBASS/libass-$LIBASS.tar.xz"
    fetch "freetype-$FREETYPE" "$FREETYPE_SHA256" "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE.tar.xz"
    fetch "harfbuzz-$HARFBUZZ" "$HARFBUZZ_SHA256" "https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ/harfbuzz-$HARFBUZZ.tar.xz"
    fetch "fribidi-$FRIBIDI" "$FRIBIDI_SHA256" "https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI/fribidi-$FRIBIDI.tar.xz"
}

# Sets SDK, OS, MIN_OS, SUFFIX, ARCHS and PLIST_PLATFORM for a platform.
describe_platform() {
    SUFFIX=""
    case "$1" in
        macos)          SDK=macosx;           OS=macos; MIN_OS=15.0; ARCHS="arm64 x86_64"; PLIST_PLATFORM=MacOSX ;;
        ios)            SDK=iphoneos;         OS=ios;   MIN_OS=18.0; ARCHS="arm64";        PLIST_PLATFORM=iPhoneOS ;;
        ios-simulator)  SDK=iphonesimulator;  OS=ios;   MIN_OS=18.0; ARCHS="arm64";        PLIST_PLATFORM=iPhoneSimulator; SUFFIX=-simulator ;;
        tvos)           SDK=appletvos;        OS=tvos;  MIN_OS=18.0; ARCHS="arm64";        PLIST_PLATFORM=AppleTVOS ;;
        tvos-simulator) SDK=appletvsimulator; OS=tvos;  MIN_OS=18.0; ARCHS="arm64";        PLIST_PLATFORM=AppleTVSimulator; SUFFIX=-simulator ;;
        xros)           SDK=xros;             OS=xros;  MIN_OS=2.0;  ARCHS="arm64";        PLIST_PLATFORM=XROS ;;
        xros-simulator) SDK=xrsimulator;      OS=xros;  MIN_OS=2.0;  ARCHS="arm64";        PLIST_PLATFORM=XRSimulator; SUFFIX=-simulator ;;
        *) die "unknown platform '$1' (known: ${ALL_PLATFORMS[*]})" ;;
    esac
}

# FreeType, through its own configure. Fonts that are compressed use the
# SDK's zlib; nothing else it could link is asked for.
#
# Its configure finds Apple's HVF library in the SDK and builds the driver
# for it. The fonts the system draws Chinese with are in that format on the
# systems of 2025 and later, and FreeType cannot open them without it. The
# library is there from macOS 15.4, iOS 18.4, tvOS 18.4 and visionOS 2.4; the
# driver asks at run time before every call into it, and on an older system
# declines such a font. As FreeType comes it asks on macOS and iOS alone and
# calls straight through on the other two; the second patch in
# Patches/freetype has it ask on all of them, and verify_binary looks.
#
# It is told that mmap works, and so maps font files into memory. Its
# configure finds that out by running a test program, which it can do when
# building for the Mac it is on and cannot for a device: left to itself, the
# macOS slice mapped files and the other six read them through stdio. That
# costs time. A mapped file costs nothing until it is looked at; read through
# stdio, the tables FreeType wants are read into memory, and the file the
# system draws Chinese with is 78 MB: the first line that needs it took half
# a second on a Mac, nearly all of it in read(), where mapped it takes
# 0.03 s. Every slice maps now, whatever Mac builds it.
#
# To map a file FreeType asks its size with fstat, an API Apple wants a
# reason for, and has none that fits a font of the system. The patch in
# Patches/freetype takes the size with lseek instead, as stdio does, so no
# slice calls anything that needs a reason.
compile_freetype() {
    local build_dir="$1" host="$2" cc="$3" prefix="$1/install"
    mkdir -p "$build_dir/freetype"
    cd "$build_dir/freetype"
    "$SOURCES/freetype-$FREETYPE/configure" --host="$host" --prefix="$prefix" \
        --enable-static --disable-shared --enable-freetype-config=no ac_cv_func_mmap_fixed_mapped=yes \
        --with-zlib=yes --with-bzip2=no --with-png=no --with-harfbuzz=no --with-brotli=no --with-librsvg=no \
        --with-old-mac-fonts=no --with-fsspec=no --with-fsref=no \
        --with-quickdraw-toolbox=no --with-quickdraw-carbon=no --with-ats=no \
        CC="$cc" CC_BUILD="$(xcrun -sdk macosx -f clang) -isysroot $(xcrun -sdk macosx --show-sdk-path)" \
        CFLAGS="-O2 -fPIC $DEBUG_FLAGS" PKG_CONFIG=false ZLIB_CFLAGS=" " ZLIB_LIBS="-lz" > configure.log 2>&1 \
        || { tail -30 configure.log; die "FreeType: configure failed for $host"; }
    grep -q '^FTSYS_SRC = \$(PLATFORM_DIR)/ftsystem.c' unix-def.mk \
        || die "FreeType: configured to read font files through stdio for $host, not to map them"
    make -j"$JOBS" > make.log 2>&1 || { tail -40 make.log; die "FreeType: make failed for $host"; }
    make install > install.log 2>&1 || { tail -20 install.log; die "FreeType: make install failed for $host"; }
}

# HarfBuzz ships its whole library as one source file for builds like this
# one. Compiled without exceptions and run-time types, as its authors build
# it, it needs nothing of the C++ library when it runs.
compile_harfbuzz() {
    local build_dir="$1" cxx="$2" prefix="$1/install"
    mkdir -p "$build_dir/harfbuzz" "$prefix/include/harfbuzz" "$prefix/lib"
    # shellcheck disable=SC2086
    $cxx -O2 -fPIC $DEBUG_FLAGS -std=c++17 -fno-exceptions -fno-rtti -fno-threadsafe-statics -fvisibility-inlines-hidden \
        -DHAVE_PTHREAD=1 -DHB_NO_PRAGMA_GCC_DIAGNOSTIC_ERROR \
        -c "$SOURCES/harfbuzz-$HARFBUZZ/src/harfbuzz.cc" -o "$build_dir/harfbuzz/harfbuzz.o" > "$build_dir/harfbuzz/compile.log" 2>&1 \
        || { tail -30 "$build_dir/harfbuzz/compile.log"; die "HarfBuzz: compile failed"; }
    libtool -static -o "$prefix/lib/libharfbuzz.a" "$build_dir/harfbuzz/harfbuzz.o" 2> /dev/null
    cp "$SOURCES/harfbuzz-$HARFBUZZ"/src/hb*.h "$prefix/include/harfbuzz/"
}

# FriBidi is eighteen C files and tables that come ready made. Its build
# wants to run programs of its own to make those tables, which a build for
# another machine cannot, so the files are compiled as they are.
compile_fribidi() {
    local build_dir="$1" cc="$2" prefix="$1/install" source="$SOURCES/fribidi-$FRIBIDI" file objects=()
    mkdir -p "$build_dir/fribidi" "$prefix/include/fribidi" "$prefix/lib"
    local major="${FRIBIDI%%.*}" rest="${FRIBIDI#*.}"
    sed -e "s/@PACKAGE@/fribidi/" -e "s/@PACKAGE_NAME@/GNU FriBidi/" -e "s/@PACKAGE_BUGREPORT@//" \
        -e "s/@FRIBIDI_VERSION@/$FRIBIDI/" -e "s/@FRIBIDI_MAJOR_VERSION@/$major/" \
        -e "s/@FRIBIDI_MINOR_VERSION@/${rest%%.*}/" -e "s/@FRIBIDI_MICRO_VERSION@/${rest#*.}/" \
        -e "s/@FRIBIDI_INTERFACE_VERSION@/4/g" -e "s/@SIZEOF_INT@/4/" \
        -e "s/@FRIBIDI_MSVC_BUILD_PLACEHOLDER@//" -e "s/@configure_input@/made by build-libass.sh/" \
        "$source/lib/fribidi-config.h.in" > "$prefix/include/fribidi/fribidi-config.h"
    grep -q '@' "$prefix/include/fribidi/fribidi-config.h" && die "FriBidi: fribidi-config.h.in has a field this script does not fill"
    cp "$source"/lib/fribidi*.h "$prefix/include/fribidi/"
    for file in "$source"/lib/*.c; do
        local object="$build_dir/fribidi/$(basename "${file%.c}").o"
        # shellcheck disable=SC2086
        $cc -O2 -fPIC $DEBUG_FLAGS -I"$prefix/include/fribidi" -I"$source/lib" \
            -DHAVE_STDLIB_H=1 -DHAVE_STRING_H=1 -DHAVE_STRINGS_H=1 -DHAVE_STRINGIZE=1 -DSTDC_HEADERS=1 \
            -c "$file" -o "$object" >> "$build_dir/fribidi/compile.log" 2>&1 \
            || { tail -30 "$build_dir/fribidi/compile.log"; die "FriBidi: compile failed"; }
        objects+=("$object")
    done
    libtool -static -o "$prefix/lib/libfribidi.a" "${objects[@]}" 2> /dev/null
}

# libass itself, told where the three are. Its hand-written code for arm64
# goes through the C compiler; for Intel it needs nasm, and is left out
# without it.
compile_libass() {
    local build_dir="$1" host="$2" cc="$3" arch="$4" prefix="$1/install" extra=()
    if [[ "$arch" == x86_64 ]] && ! command -v nasm >/dev/null; then
        echo "note: nasm not found, building x86_64 without assembly"
        extra+=(--disable-asm)
    fi
    mkdir -p "$build_dir/libass"
    cd "$build_dir/libass"
    "$SOURCES/libass-$LIBASS/configure" --host="$host" --prefix="$prefix" \
        --enable-static --disable-shared \
        --disable-fontconfig --disable-directwrite --disable-libunibreak --enable-coretext \
        ${extra[@]+"${extra[@]}"} \
        CC="$cc" CFLAGS="-O2 -fPIC $DEBUG_FLAGS" PKG_CONFIG=false \
        FREETYPE_CFLAGS="-I$prefix/include/freetype2" FREETYPE_LIBS="-L$prefix/lib -lfreetype -lz" \
        FRIBIDI_CFLAGS="-I$prefix/include/fribidi" FRIBIDI_LIBS="-L$prefix/lib -lfribidi" \
        HARFBUZZ_CFLAGS="-I$prefix/include/harfbuzz" HARFBUZZ_LIBS="-L$prefix/lib -lharfbuzz" > configure.log 2>&1 \
        || { tail -30 configure.log; die "libass: configure failed for $host"; }
    grep -q '^#define CONFIG_CORETEXT 1' config.h || die "libass: Core Text was not found for $host"
    # A build that was meant to have the hand-written code and has not is
    # not a build.
    if [[ ${#extra[@]} -eq 0 ]]; then
        grep -q '^#define CONFIG_ASM 1' config.h || die "libass: configured without its assembly for $host"
    fi
    make -j"$JOBS" > make.log 2>&1 || { tail -40 make.log; die "libass: make failed for $host"; }
    make install > install.log 2>&1 || { tail -20 install.log; die "libass: make install failed for $host"; }
}

# Compiles the four static libraries for one architecture into $1/install.
compile() {
    local build_dir="$1" arch="$2" triple="$3" sdk_path="$4"
    # The target goes with the compiler, so that every test a configure
    # script makes and every link is for the right machine.
    local cc cxx host="$arch-apple-darwin"
    cc="$(xcrun -sdk "$SDK" -f clang) -target $triple -isysroot $sdk_path"
    cxx="$(xcrun -sdk "$SDK" -f clang++) -target $triple -isysroot $sdk_path"
    [[ "$arch" == arm64 ]] && host="aarch64-apple-darwin"

    # A finished compile is reused as long as it was made of the same things.
    local stamp="$build_dir/install/built-with"
    local identity="libass $LIBASS freetype $FREETYPE harfbuzz $HARFBUZZ fribidi $FRIBIDI $triple $SCRIPT_ID"
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$identity" ]]; then
        echo "reusing the finished compile in ${build_dir#"$ROOT"/}"
        return
    fi

    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    # HarfBuzz is one long compile that nothing else waits for until libass.
    compile_harfbuzz "$build_dir" "$cxx" &
    local harfbuzz=$!
    compile_freetype "$build_dir" "$host" "$cc"
    compile_fribidi "$build_dir" "$cc"
    wait "$harfbuzz" || die "HarfBuzz did not build for $triple"
    compile_libass "$build_dir" "$host" "$cc" "$arch"
    echo "$identity" > "$stamp"
}

# Links one architecture's static libraries into a single dynamic library,
# which exports libass's public functions and nothing else.
link_dylib() {
    local build_dir="$1" triple="$2" sdk_path="$3" install_name="$4"
    local prefix="$build_dir/install" exports="$build_dir/exports.txt" roots="$build_dir/roots.rsp"
    sed -e '/^[[:space:]]*$/d' -e 's/^/_/' "$SOURCES/libass-$LIBASS/libass/libass.sym" > "$exports"
    sed 's/^/-Wl,-u,/' "$exports" > "$roots"

    local frameworks="-framework CoreText -framework CoreFoundation"
    [[ "$OS" == macos ]] && frameworks="-framework ApplicationServices -framework CoreFoundation"
    # What nasm assembles does not say which system it is for. The linker
    # remarks on that for every such object and takes it to be for the system
    # it is linking for, which it is; the remarks are left out of the output.
    # Apple's HVF library, where FreeType was built to use it. Linked weakly:
    # a system older than the library still loads this one.
    grep -q -- '-lhvf' "$prefix/lib/pkgconfig/freetype2.pc" && frameworks+=" -weak-lhvf"
    # shellcheck disable=SC2086
    "$(xcrun -sdk "$SDK" -f clang++)" -dynamiclib -target "$triple" -isysroot "$sdk_path" \
        "@$roots" -Wl,-exported_symbols_list,"$exports" \
        "$prefix/lib/libass.a" "$prefix/lib/libharfbuzz.a" "$prefix/lib/libfribidi.a" "$prefix/lib/libfreetype.a" \
        -lz -liconv $frameworks \
        -install_name "$install_name" \
        -compatibility_version 1 -current_version "$LIBASS" \
        -o "$build_dir/Libass.dylib" 2> >(grep -v 'no platform load command found' >&2)
}

write_info_plist() {
    local path="$1" minimum_key
    [[ "$OS" == macos ]] && minimum_key=LSMinimumSystemVersion || minimum_key=MinimumOSVersion
    cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Libass</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Libass</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$LIBASS</string>
    <key>CFBundleVersion</key><string>$LIBASS</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$PLIST_PLATFORM</string></array>
    <key>$minimum_key</key><string>$MIN_OS</string>
</dict>
</plist>
EOF
}

# The four licences travel with the binary.
copy_licences() {
    local target="$1"
    cp "$SOURCES/libass-$LIBASS/COPYING" "$target/LICENSE-libass.txt"
    cp "$SOURCES/harfbuzz-$HARFBUZZ/COPYING" "$target/LICENSE-HarfBuzz.txt"
    cp "$SOURCES/freetype-$FREETYPE/docs/FTL.TXT" "$target/LICENSE-FreeType.txt"
    cp "$SOURCES/fribidi-$FRIBIDI/COPYING" "$target/LICENSE-FriBidi-LGPLv2.1.txt"
}

build_platform() {
    local platform="$1" arch dylibs=()
    describe_platform "$platform"
    local sdk_path
    sdk_path="$(xcrun -sdk "$SDK" --show-sdk-path)"

    # macOS frameworks are versioned bundles; the others are flat.
    local install_name="@rpath/Libass.framework/Libass"
    [[ "$OS" == macos ]] && install_name="@rpath/Libass.framework/Versions/A/Libass"

    for arch in $ARCHS; do
        local triple="$arch-apple-$OS$MIN_OS$SUFFIX" build_dir="$WORK/$platform/$arch"
        log "$platform: compiling $triple"
        compile "$build_dir" "$arch" "$triple" "$sdk_path"
        link_dylib "$build_dir" "$triple" "$sdk_path" "$install_name"
        dylibs+=("$build_dir/Libass.dylib")
    done

    local framework="$WORK/$platform/Libass.framework" content resources
    rm -rf "$framework"
    if [[ "$OS" == macos ]]; then
        content="$framework/Versions/A"
        resources="$content/Resources"
        mkdir -p "$resources"
        ln -s A "$framework/Versions/Current"
        ln -s Versions/Current/Libass "$framework/Libass"
        ln -s Versions/Current/Resources "$framework/Resources"
    else
        content="$framework"
        resources="$content"
        mkdir -p "$content"
    fi
    write_info_plist "$resources/Info.plist"
    copy_licences "$resources"
    lipo -create "${dylibs[@]}" -output "$content/Libass"
    # The dSYM is read from the objects the linked binary names, so it is
    # made before the strip takes those names away (-S) with the local ones (-x).
    make_dsym "$content/Libass" "$WORK/$platform/Libass.framework.dSYM" "$platform"
    strip -S -x "$content/Libass" 2>/dev/null
    verify_dsym "$content/Libass" "$WORK/$platform/Libass.framework.dSYM" "$platform"
    verify_binary "$content/Libass" "$platform"
    # Nothing in here calls an API Apple wants a reason for, FreeType having
    # been patched to size a font file without fstat. No reason is given, so
    # a call that turns up in a later release stops the build here.
    printf '%s: ' "$platform"
    write_privacy_manifest "$content/Libass" "$resources/PrivacyInfo.xcprivacy" libass
    codesign --force --sign - "$framework"
}

make_dsym() {
    local binary="$1" dsym="$2" platform="$3"
    rm -rf "$dsym"
    dsymutil "$binary" -o "$dsym" > "$dsym.log" 2>&1 \
        || { tail -20 "$dsym.log"; die "$platform: dsymutil failed"; }
}

# A dSYM is of use only for the binary whose UUIDs it carries, one for each
# architecture, and only if the compiler's debug information is in it.
verify_dsym() {
    local binary="$1" dsym="$2" platform="$3"
    [[ "$(dwarfdump --uuid "$binary" | awk '{ print $2, $3 }' | sort)" \
        == "$(dwarfdump --uuid "$dsym" | awk '{ print $2, $3 }' | sort)" ]] \
        || die "$platform: the dSYM is not that of the binary that ships"
    dwarfdump --show-section-sizes "$dsym" | grep '__debug_line' > /dev/null \
        || die "$platform: the dSYM holds no debug information"
    echo "$platform: dSYM for $(dwarfdump --uuid "$dsym" | awk '{ print $3 }' | tr -d '()' | tr '\n' ' ')($(du -sm "$dsym" | cut -f1) MB)"
}

# A symbol the SDK declares for a newer OS than the deployment target is
# linked weakly, and calling it on an older OS crashes. No configure script
# sees that: it only asks whether the symbol links. So ask the binary. The
# calls into Apple's HVF library are the exception: FreeType makes each of
# them behind a test of the system's version, and the function that test
# calls is itself linked weakly by the compiler. That the test is there is
# not taken on trust: see verify_hvf_asks_first.
verify_binary() {
    local binary="$1" platform="$2" weak
    weak="$(nm -m "$binary" 2>/dev/null | grep 'weak external' | grep -v 'weak external automatically hidden' \
        | grep -v -e ' _HVF_[a-z_]* (from libhvf)' -e ' __availability_version_check (from libSystem)' || true)"
    if [[ -n "$weak" ]]; then
        echo "$weak" | sort -u | head -20
        die "$platform: libass calls APIs newer than its deployment target (listed above)"
    fi
    # (Not `grep -q`: on a match it stops reading, strings is told so, the
    # pipe fails, and the test passes a binary it should have stopped.)
    if strings -a "$binary" | grep -F -e "$ROOT" -e "$HOME" > /dev/null; then
        die "$platform: the binary names folders of the Mac it was built on"
    fi
    local hvf="without Apple's HVF library"
    if nm -m "$binary" 2>/dev/null | grep -q ' _HVF_'; then
        verify_hvf_asks_first "$binary" "$platform"
        hvf="Apple's HVF library linked weakly and called only after the system's version is asked"
    fi
    echo "$platform: $(lipo -archs "$binary"), $(($(stat -f%z "$binary") / 1024)) KB, $hvf, no other weak system imports"
}

# Holds a binary that imports Apple's HVF library to asking the system's
# version before it calls into it. The compiler makes that test only for the
# systems `__builtin_available` names: for one it does not name there is no
# test at all, the call is made on a system that has no such library, and
# nothing at build time says so. FreeType 2.15.0 names macOS and iOS; tvOS
# and visionOS went through unasked until Patches/freetype/0002.
#
# Two things are looked at, for each architecture. The binary as it ships
# imports the function the test ends in. And in the library it was made of,
# which still has its functions' names and whose code is the same bytes,
# every function that calls into HVF calls the test first.
verify_hvf_asks_first() {
    local binary="$1" platform="$2" arch linked unasked
    for arch in $(lipo -archs "$binary"); do
        nm -m -arch "$arch" "$binary" 2>/dev/null | grep -q ' __availability_version_check (from libSystem)' \
            || die "$platform ($arch): libass calls Apple's HVF library and never asks the system's version"
        linked="$WORK/$platform/$arch/Libass.dylib"
        [[ -f "$linked" ]] || die "$platform ($arch): ${linked#"$ROOT"/} is not there to be looked at"
        [[ "$(otool -t -arch "$arch" "$binary" | tail -n +2 | shasum)" == "$(otool -t "$linked" | tail -n +2 | shasum)" ]] \
            || die "$platform ($arch): the code that ships is not the code of ${linked#"$ROOT"/}"
        # A line that ends in a colon names the function the lines after it
        # belong to. The test is a call to one of two functions of the
        # compiler's own, which are not counted as callers themselves.
        unasked="$(otool -tV "$linked" | awk '
            /^[^[:space:]0-9].*:$/ { name = $0; asked = 0; next }
            /___isPlatformVersionAtLeast|___isOSVersionAtLeast/ { asked = 1 }
            /_HVF_/ && !asked { print name }' | sort -u | tr '\n' ' ')"
        [[ -z "$unasked" ]] \
            || die "$platform ($arch): Apple's HVF library is called before the system's version is asked, in $unasked"
    done
}

# libass's two public headers and the shim, as the C target the Swift package compiles.
install_c_target() {
    local platform arch prefix="" target="$ROOT/Vendor/CAss"
    for platform in "${ALL_PLATFORMS[@]}"; do
        for arch in arm64 x86_64; do
            if [[ -f "$WORK/$platform/$arch/install/include/ass/ass.h" ]]; then
                prefix="$WORK/$platform/$arch/install"
                break 2
            fi
        done
    done
    [[ -n "$prefix" ]] || die "no built headers found"

    rm -rf "$target"
    mkdir -p "$target/include"
    cp -R "$prefix/include/ass" "$target/include/"
    # A link, not a copy: edits to the shim take effect without rebuilding libass.
    ln -s ../../../Sources/CAss/shim.h "$target/include/CAss.h"
    cat > "$target/include/module.modulemap" <<'EOF'
module CAss {
    header "CAss.h"
    export *
}
EOF
    cat > "$target/shim.c" <<'EOF'
// Everything lives in CAss.h as static inline functions. This file exists
// because a Swift package C target needs at least one source file. The
// library itself is in Libass.xcframework.
#include "CAss.h"
EOF
}

assemble_xcframework() {
    local platform arguments=()
    for platform in "${ALL_PLATFORMS[@]}"; do
        if [[ -d "$WORK/$platform/Libass.framework" ]]; then
            [[ -d "$WORK/$platform/Libass.framework.dSYM" ]] \
                || die "$platform was built without a dSYM; build it again (Scripts/build-libass.sh $platform)"
            arguments+=(-framework "$WORK/$platform/Libass.framework"
                -debug-symbols "$WORK/$platform/Libass.framework.dSYM")
        fi
    done
    [[ ${#arguments[@]} -gt 0 ]] || die "nothing was built"
    rm -rf "$ROOT/Vendor/Libass.xcframework"
    xcodebuild -create-xcframework "${arguments[@]}" -output "$ROOT/Vendor/Libass.xcframework" > /dev/null
    {
        echo "libass $LIBASS, source SHA-256 $LIBASS_SHA256"
        echo "FreeType $FREETYPE, source SHA-256 $FREETYPE_SHA256"
        echo "HarfBuzz $HARFBUZZ, source SHA-256 $HARFBUZZ_SHA256"
        echo "FriBidi $FRIBIDI, source SHA-256 $FRIBIDI_SHA256"
        echo "Patches: $(cd "$ROOT/Patches" && ls {libass,freetype,harfbuzz,fribidi}/*.patch 2>/dev/null | tr '\n' ' ')"
        echo "Licences: ISC, FTL, MIT, LGPL version 2.1 or later (see the LICENSE files inside each framework)"
        echo "Assembler for x86_64: $(nasm --version 2>/dev/null || echo "none, so no x86 assembly")"
        echo "Debug symbols: a dSYM for each slice, in the slice's dSYMs folder; the binaries are stripped"
        echo "Built $(date -u +%Y-%m-%dT%H:%M:%SZ) with $(xcodebuild -version | tr '\n' ' ')"
        echo "Options: see Scripts/build-libass.sh at the commit that produced this"
    } > "$ROOT/Vendor/Libass.xcframework/BUILD-INFO.txt"
}

PLATFORMS=("$@")
[[ ${#PLATFORMS[@]} -gt 0 ]] || PLATFORMS=("${ALL_PLATFORMS[@]}")
for platform in "${PLATFORMS[@]}"; do describe_platform "$platform"; done

fetch_sources
for platform in "${PLATFORMS[@]}"; do build_platform "$platform"; done
install_c_target
assemble_xcframework

log "Done"
ls -d "$ROOT"/Vendor/Libass.xcframework/*/ | sed "s|$ROOT/||"
