#!/bin/bash
# Builds FFmpeg for the Apple platforms CeauKit runs on and packs the result
# for the Swift package:
#
#   Vendor/FFmpeg.xcframework   one dynamic framework per platform
#   Vendor/CFFmpeg/             the C target CeauKit imports (headers + shim)
#
# The build is LGPL: no --enable-gpl, no --enable-nonfree, and FFmpeg stays in
# its own dynamic framework so it can be replaced without relinking the app.
#
# One library from outside the platform SDK is linked in: dav1d, which decodes
# AV1 on the chips that have no AV1 decoder of their own (every Apple TV, and
# iPhones, iPads and Macs before the A17 Pro and the M3). It is built here
# from its pinned release, and goes into the framework statically, which its
# licence (BSD, two clauses) allows. Its build system is Meson, which this
# script installs, with Ninja, into a Python environment of its own under
# Vendor/build; nothing is installed on the Mac.
#
# Needed on the Mac beside Xcode: python3, for that environment, and nasm
# (`brew install nasm`) for the hand-written code of the Intel half of the
# macOS slice. Without nasm that half is built in plain C, and says so.
#
# Each framework carries the licences of what is in it and a privacy manifest
# (Scripts/privacy-manifest.sh), written from what the finished binary calls.
#
#   Scripts/build-ffmpeg.sh                    every platform
#   Scripts/build-ffmpeg.sh macos ios          only these (the others are kept
#                                              from earlier runs, if built)
#
# Platforms: macos ios ios-simulator tvos tvos-simulator xros xros-simulator
set -euo pipefail

VERSION=9.0.2
SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
DAV1D=1.5.4
DAV1D_SHA256=686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5
# The tools that build dav1d, as the wheels PyPI serves for a Mac.
MESON=1.12.1
MESON_SHA256=930bc7542cbd9f57009e182fd014eba48cf1a0180a7b9006d2d32d8f168d8b02
NINJA=1.13.2
NINJA_SHA256=fd82e26c0706ad4ab88e5fdd26f3fab0a987a90f810160f6c322e752c6af298b
ALL_PLATFORMS=(macos ios ios-simulator tvos tvos-simulator xros xros-simulator)
BUNDLE_ID=com.ceaule.ceaukit.ffmpeg

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/Vendor/build"
SOURCE="$WORK/src/ffmpeg-$VERSION"
DAV1D_SOURCE="$WORK/src/dav1d-$DAV1D"
TOOLS="$WORK/tools"
# Every core, unless told to leave some for whatever else the Mac is doing.
JOBS="${CEAUKIT_JOBS:-$(sysctl -n hw.ncpu)}"

# Keep Homebrew and friends out of a build that must only see the SDK.
unset CPATH C_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH CFLAGS LDFLAGS CPPFLAGS

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# shellcheck source=Scripts/privacy-manifest.sh
source "$ROOT/Scripts/privacy-manifest.sh"

fetch_source() {
    local archive="$WORK/src/ffmpeg-$VERSION.tar.xz"
    mkdir -p "$WORK/src"
    if [[ ! -f "$archive" ]]; then
        log "Downloading FFmpeg $VERSION"
        curl -fL --retry 3 -o "$archive" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
    fi
    local actual
    actual="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
    [[ "$actual" == "$SHA256" ]] || die "ffmpeg-$VERSION.tar.xz has SHA-256 $actual, expected $SHA256"

    # The source tree is the release plus Patches/ffmpeg, applied in name
    # order. It is unpacked afresh whenever the set of patches changes.
    PATCHES_ID="$(cat "$ROOT"/Patches/ffmpeg/*.patch 2>/dev/null | shasum -a 256 | cut -c1-16)"
    if [[ "$(cat "$SOURCE/.ceaukit-patches" 2>/dev/null)" != "$PATCHES_ID" ]]; then
        rm -rf "$SOURCE"
        tar -xf "$archive" -C "$WORK/src"
        local patch
        for patch in "$ROOT"/Patches/ffmpeg/*.patch; do
            [[ -f "$patch" ]] || continue
            log "Applying $(basename "$patch")"
            patch -d "$SOURCE" -p1 --no-backup-if-mismatch < "$patch" > /dev/null \
                || die "$(basename "$patch") does not apply to FFmpeg $VERSION"
        done
        echo "$PATCHES_ID" > "$SOURCE/.ceaukit-patches"
    fi
}

# dav1d, from VideoLAN's own release directory, with Patches/dav1d applied in
# name order should there ever be any.
fetch_dav1d() {
    local archive="$WORK/src/dav1d-$DAV1D.tar.xz" actual patch identity
    if [[ ! -f "$archive" ]]; then
        log "Downloading dav1d $DAV1D"
        curl -fL --retry 3 -o "$archive" "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D/dav1d-$DAV1D.tar.xz"
    fi
    actual="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
    [[ "$actual" == "$DAV1D_SHA256" ]] || die "dav1d-$DAV1D.tar.xz has SHA-256 $actual, expected $DAV1D_SHA256"

    DAV1D_PATCHES_ID="$({ cat "$ROOT"/Patches/dav1d/*.patch 2>/dev/null || true; } | shasum -a 256 | cut -c1-16)"
    identity="$DAV1D_SHA256 $DAV1D_PATCHES_ID"
    if [[ "$(cat "$DAV1D_SOURCE/.ceaukit-unpacked" 2>/dev/null)" != "$identity" ]]; then
        rm -rf "$DAV1D_SOURCE"
        tar -xf "$archive" -C "$WORK/src"
        for patch in "$ROOT"/Patches/dav1d/*.patch; do
            [[ -f "$patch" ]] || continue
            log "Applying $(basename "$patch")"
            patch -d "$DAV1D_SOURCE" -p1 --no-backup-if-mismatch < "$patch" > /dev/null \
                || die "$(basename "$patch") does not apply to dav1d $DAV1D"
        done
        echo "$identity" > "$DAV1D_SOURCE/.ceaukit-unpacked"
    fi
}

# Meson and Ninja, in a Python environment that belongs to this build. pip is
# given the hash of each wheel and takes nothing else.
install_build_tools() {
    local environment="$TOOLS/python" identity="meson $MESON $MESON_SHA256 ninja $NINJA $NINJA_SHA256"
    if [[ "$(cat "$environment/.ceaukit-tools" 2>/dev/null)" != "$identity" ]]; then
        command -v python3 >/dev/null || die "python3 not found; dav1d's build system needs it"
        log "Installing Meson $MESON and Ninja $NINJA into ${environment#"$ROOT"/}"
        rm -rf "$environment"
        mkdir -p "$TOOLS"
        python3 -m venv "$environment" || die "python3 -m venv failed"
        printf 'meson==%s --hash=sha256:%s\nninja==%s --hash=sha256:%s\n' \
            "$MESON" "$MESON_SHA256" "$NINJA" "$NINJA_SHA256" > "$TOOLS/requirements.txt"
        "$environment/bin/python3" -m pip install --quiet --disable-pip-version-check --no-deps \
            --only-binary=:all: --require-hashes -r "$TOOLS/requirements.txt" > "$TOOLS/pip.log" 2>&1 \
            || { tail -20 "$TOOLS/pip.log"; die "could not install Meson and Ninja"; }
        echo "$identity" > "$environment/.ceaukit-tools"
    fi
    MESON_BIN="$environment/bin/meson"
    export NINJA="$environment/bin/ninja"
}

# Sets SDK, OS, MIN_OS, SUFFIX, ARCHS and PLIST_PLATFORM for a platform.
describe_platform() {
    SUFFIX=""
    case "$1" in
        macos)          SDK=macosx;           OS=macos; MIN_OS=14.0; ARCHS="arm64 x86_64"; PLIST_PLATFORM=MacOSX ;;
        ios)            SDK=iphoneos;         OS=ios;   MIN_OS=17.0; ARCHS="arm64";        PLIST_PLATFORM=iPhoneOS ;;
        ios-simulator)  SDK=iphonesimulator;  OS=ios;   MIN_OS=17.0; ARCHS="arm64";        PLIST_PLATFORM=iPhoneSimulator; SUFFIX=-simulator ;;
        tvos)           SDK=appletvos;        OS=tvos;  MIN_OS=17.0; ARCHS="arm64";        PLIST_PLATFORM=AppleTVOS ;;
        tvos-simulator) SDK=appletvsimulator; OS=tvos;  MIN_OS=17.0; ARCHS="arm64";        PLIST_PLATFORM=AppleTVSimulator; SUFFIX=-simulator ;;
        xros)           SDK=xros;             OS=xros;  MIN_OS=1.0;  ARCHS="arm64";        PLIST_PLATFORM=XROS ;;
        xros-simulator) SDK=xrsimulator;      OS=xros;  MIN_OS=1.0;  ARCHS="arm64";        PLIST_PLATFORM=XRSimulator; SUFFIX=-simulator ;;
        *) die "unknown platform '$1' (known: ${ALL_PLATFORMS[*]})" ;;
    esac
}

# Compiles dav1d for one architecture into $1/dav1d/install. Its hand-written
# code for arm64 goes through the C compiler; for Intel it needs nasm, and is
# left out without it.
compile_dav1d() {
    local build_dir="$1" arch="$2" triple="$3" sdk_path="$4" cc="$5"
    local dir="$build_dir/dav1d" family=aarch64 assembly=true assembler=""
    if [[ "$arch" == x86_64 ]]; then
        family=x86_64
        if command -v nasm >/dev/null; then
            assembler="nasm = '$(command -v nasm)'"
        else
            assembly=false
        fi
    fi
    mkdir -p "$dir"
    # Meson is told about the machine the code is for in a file. Every Apple
    # system is "darwin" to it; the target triple says which one. Nothing it
    # builds here can be run on this Mac, and nothing needs to be.
    cat > "$dir/cross.ini" <<EOF
[binaries]
c = ['$cc', '-target', '$triple', '-isysroot', '$sdk_path']
ar = '$(xcrun -f ar)'
strip = '$(xcrun -f strip)'
$assembler

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'darwin'
cpu_family = '$family'
cpu = '$arch'
endian = 'little'
EOF
    "$MESON_BIN" setup "$dir/obj" "$DAV1D_SOURCE" --cross-file "$dir/cross.ini" \
        --prefix "$dir/install" --libdir lib --buildtype release --default-library static \
        -Denable_asm="$assembly" -Denable_tools=false -Denable_tests=false -Denable_examples=false \
        > "$dir/setup.log" 2>&1 || { tail -30 "$dir/setup.log"; die "dav1d: meson failed for $triple"; }
    if [[ "$assembly" == true ]]; then
        grep -q '^#define HAVE_ASM 1' "$dir/obj/config.h" || die "dav1d: no assembly for $triple"
    fi
    "$NINJA" -C "$dir/obj" -j "$JOBS" install > "$dir/build.log" 2>&1 \
        || { tail -40 "$dir/build.log"; die "dav1d: build failed for $triple"; }
    [[ -f "$dir/install/lib/libdav1d.a" ]] || die "dav1d: no library for $triple"
}

# FFmpeg looks for dav1d through pkg-config and no other way. This stands in
# for pkg-config and knows that one library, so nothing installed on this Mac
# can be found by mistake.
write_pkg_config() {
    local path="$1" prefix="$2"
    cat > "$path" <<EOF
#!/bin/sh
known="" answer=""
for argument; do
    case "\$argument" in
        --version) echo 0.29.2; exit 0 ;;
        --cflags) answer="-I$prefix/include" ;;
        --libs) answer="-L$prefix/lib -ldav1d" ;;
        --variable=includedir) answer="$prefix/include" ;;
        dav1d|dav1d\ *) known=yes ;;    # also "dav1d >= 1.0.0", as one word or three
        -*|">="|[0-9]*) ;;
        *) exit 1 ;;
    esac
done
[ -n "\$known" ] || exit 1
[ -z "\$answer" ] || echo "\$answer"
EOF
    chmod +x "$path"
}

# Compiles the static libraries for one architecture into $1/install.
compile() {
    local build_dir="$1" arch="$2" triple="$3" sdk_path="$4" cc="$5"
    local flags="-target $triple -isysroot $sdk_path"
    # The toolchain's clang has no default SDK, so the tools FFmpeg builds to
    # run on this Mac during the build need theirs spelled out too.
    local host_flags="-isysroot $(xcrun -sdk macosx --show-sdk-path)"
    local extra=()
    if [[ "$arch" == x86_64 ]] && ! command -v nasm >/dev/null; then
        # Hardware decoding is unaffected; software decoding on Intel Macs is
        # slower without the hand-written assembly. `brew install nasm` to get it.
        echo "note: nasm not found, building x86_64 without assembly"
        extra+=(--disable-x86asm)
    fi

    local options=(
        --prefix="$build_dir/install"
        --enable-cross-compile --target-os=darwin --arch="$arch"
        --cc="$cc" --host-cc="$(xcrun -sdk macosx -f clang)"
        --extra-cflags="$flags" --extra-ldflags="$flags"
        --host-cflags="$host_flags" --host-ldflags="$host_flags"
        --pkg-config="$build_dir/pkg-config"
        --enable-pic --enable-static --disable-shared
        --disable-programs --disable-doc --disable-debug
        --disable-avdevice --disable-encoders --disable-muxers
        --disable-autodetect --enable-pthreads
        --enable-videotoolbox --enable-audiotoolbox --enable-securetransport
        --enable-zlib --enable-bzlib --enable-iconv
        --enable-libdav1d
        --disable-filters
        --enable-filter=bwdif,yadif,scale,format,null,anull,aresample,aformat,volume,acompressor,dynaudnorm,loudnorm
        ${extra[@]+"${extra[@]}"}
    )

    # A finished compile is reused as long as it was configured the same way.
    local stamp="$build_dir/install/configured-with"
    local identity="$VERSION+$PATCHES_ID dav1d $DAV1D+$DAV1D_PATCHES_ID ${options[*]}"
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$identity" ]]; then
        echo "reusing the finished compile in ${build_dir#"$ROOT"/}"
        return
    fi

    rm -rf "$build_dir"
    mkdir -p "$build_dir/obj"
    compile_dav1d "$build_dir" "$arch" "$triple" "$sdk_path" "$cc"
    write_pkg_config "$build_dir/pkg-config" "$build_dir/dav1d/install"

    cd "$build_dir/obj"
    "$SOURCE/configure" "${options[@]}" > configure.log 2>&1 \
        || { tail -30 configure.log; die "configure failed for $triple"; }

    # FFmpeg keeps the command it was configured with, to show when asked
    # (`avformat_configuration`), and that command names folders of the Mac
    # it was built on. What ships says where in this repository things were,
    # not whose home the repository was in.
    sed -i '' "s|$ROOT/||g" config.h

    grep -q '^#define CONFIG_GPL 0' config.h && grep -q '^#define CONFIG_NONFREE 0' config.h \
        || die "$triple was configured with GPL or nonfree parts"
    grep -q '^#define CONFIG_LIBDAV1D_DECODER 1' config_components.h \
        || die "$triple was configured without dav1d"
    # The hand-written code is what makes software decoding quick enough to
    # watch. A build that was meant to have it and has not is not a build.
    if [[ "$arch" == arm64 ]]; then
        grep -q '^#define HAVE_NEON 1' config.h || die "$triple was configured without its assembly"
    elif [[ " ${options[*]} " != *" --disable-x86asm "* ]]; then
        grep -q '^#define HAVE_X86ASM 1' config.h || die "$triple was configured without its assembly"
    fi

    make -j"$JOBS" > make.log 2>&1 || { tail -40 make.log; die "make failed for $triple"; }
    make install > install.log 2>&1 || { tail -20 install.log; die "make install failed for $triple"; }
    echo "$identity" > "$stamp"
}

# Prints the system libraries and frameworks the static libraries ask for,
# each once, with "-framework X" kept together.
system_libraries() {
    local prefix="$1" seen=" " token pending=""
    for token in $(sed -n -e 's/^Libs: //p' -e 's/^Libs.private: //p' "$prefix"/lib/pkgconfig/*.pc); do
        if [[ -n "$pending" ]]; then
            token="$pending $token"
            pending=""
        elif [[ "$token" == -framework ]]; then
            pending="$token"
            continue
        fi
        case "$token" in
            -lav*|-lsw*) continue ;;   # FFmpeg's own libraries, linked whole below
            -ldav1d) continue ;;       # named by its file below
            -l*|-framework\ *|-pthread) ;;
            *) continue ;;
        esac
        if [[ "$seen" != *" $token "* ]]; then
            seen+="$token "
            printf '%s ' "$token"
        fi
    done
}

# Links one architecture's static libraries into a single dynamic library.
#
# The library exports FFmpeg's public API and nothing else. Every public symbol
# is named as a root, so the linker pulls in whatever it needs from the static
# libraries in the usual way. Loading the archives whole instead does not link:
# some objects are deliberately present in more than one of them. dav1d comes
# in as what FFmpeg's decoder for it calls, and none of it is exported.
link_dylib() {
    local build_dir="$1" triple="$2" sdk_path="$3" cc="$4" install_name="$5"
    local prefix="$build_dir/install" lib archives=()
    for lib in libavformat libavcodec libavfilter libswresample libswscale libavutil; do
        archives+=("$prefix/lib/$lib.a")
    done

    local exports="$build_dir/exports.txt" roots="$build_dir/roots.rsp"
    nm -gU "${archives[@]}" 2>/dev/null \
        | awk 'NF >= 3 { print $NF }' | grep -E '^_(av|sws|swr)' | sort -u > "$exports"
    sed 's/^/-Wl,-u,/' "$exports" > "$roots"

    # FFmpeg's .pc files leave iconv out although the code calls it.
    #
    # What nasm assembles does not say which system it is for. The linker
    # remarks on that for every such object and takes it to be for the system
    # it is linking for, which it is; the remarks are left out of the output.
    # shellcheck disable=SC2046
    "$cc" -dynamiclib -target "$triple" -isysroot "$sdk_path" \
        "@$roots" -Wl,-exported_symbols_list,"$exports" \
        "${archives[@]}" "$build_dir/dav1d/install/lib/libdav1d.a" \
        $(system_libraries "$prefix") -liconv \
        -install_name "$install_name" \
        -compatibility_version 1 -current_version "$VERSION" \
        -o "$build_dir/FFmpeg" 2> >(grep -v 'no platform load command found' >&2)
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
    <key>CFBundleExecutable</key><string>FFmpeg</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>FFmpeg</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$PLIST_PLATFORM</string></array>
    <key>$minimum_key</key><string>$MIN_OS</string>
</dict>
</plist>
EOF
}

build_platform() {
    local platform="$1" arch dylibs=()
    describe_platform "$platform"
    local sdk_path cc
    sdk_path="$(xcrun -sdk "$SDK" --show-sdk-path)"
    cc="$(xcrun -sdk "$SDK" -f clang)"

    # macOS frameworks are versioned bundles; the others are flat.
    local install_name="@rpath/FFmpeg.framework/FFmpeg"
    [[ "$OS" == macos ]] && install_name="@rpath/FFmpeg.framework/Versions/A/FFmpeg"

    for arch in $ARCHS; do
        local triple="$arch-apple-$OS$MIN_OS$SUFFIX" build_dir="$WORK/$platform/$arch"
        log "$platform: compiling $triple"
        compile "$build_dir" "$arch" "$triple" "$sdk_path" "$cc"
        link_dylib "$build_dir" "$triple" "$sdk_path" "$cc" "$install_name"
        dylibs+=("$build_dir/FFmpeg")
    done

    local framework="$WORK/$platform/FFmpeg.framework" content resources
    rm -rf "$framework"
    if [[ "$OS" == macos ]]; then
        content="$framework/Versions/A"
        resources="$content/Resources"
        mkdir -p "$resources"
        ln -s A "$framework/Versions/Current"
        ln -s Versions/Current/FFmpeg "$framework/FFmpeg"
        ln -s Versions/Current/Resources "$framework/Resources"
    else
        content="$framework"
        resources="$content"
        mkdir -p "$content"
    fi
    write_info_plist "$resources/Info.plist"
    # The licences travel with the binary.
    cp "$SOURCE/COPYING.LGPLv2.1" "$resources/"
    cp "$DAV1D_SOURCE/COPYING" "$resources/LICENSE-dav1d.txt"
    lipo -create "${dylibs[@]}" -output "$content/FFmpeg"
    strip -x "$content/FFmpeg" 2>/dev/null
    verify_binary "$content/FFmpeg" "$platform"
    # FFmpeg asks for a file's size and kind with stat, fstat and lstat: of
    # the media and subtitle files it is handed, which are in the app's own
    # container (C617.1) or were picked by the person using it (3B52.1). It
    # reads no dates. The manifest is written only for what this binary calls.
    printf '%s: ' "$platform"
    write_privacy_manifest "$content/FFmpeg" "$resources/PrivacyInfo.xcprivacy" FFmpeg \
        FileTimestamp=C617.1,3B52.1
    codesign --force --sign - "$framework"
}

# A symbol the SDK declares for a newer OS than the deployment target is
# linked weakly, and calling it on an older OS crashes. FFmpeg's configure
# cannot see that: it only asks whether the symbol links. So ask the binary.
verify_binary() {
    local binary="$1" platform="$2" weak
    weak="$(nm -m "$binary" 2>/dev/null | grep 'weak external' | grep -v 'weak external automatically hidden' || true)"
    if [[ -n "$weak" ]]; then
        echo "$weak" | sort -u | head -20
        die "$platform: FFmpeg calls APIs newer than its deployment target (listed above)"
    fi
    if strings -a "$binary" | grep -q -F -e "$ROOT" -e "$HOME"; then
        die "$platform: the binary names folders of the Mac it was built on"
    fi
    echo "$platform: $(lipo -archs "$binary"), $(($(stat -f%z "$binary") / 1048576)) MB, no weak system imports"
}

# The headers and the shim, as the C target the Swift package compiles.
install_c_target() {
    local platform arch prefix="" target="$ROOT/Vendor/CFFmpeg"
    for platform in "${ALL_PLATFORMS[@]}"; do
        for arch in arm64 x86_64; do
            if [[ -d "$WORK/$platform/$arch/install/include" ]]; then
                prefix="$WORK/$platform/$arch/install"
                break 2
            fi
        done
    done
    [[ -n "$prefix" ]] || die "no built headers found"

    rm -rf "$target"
    mkdir -p "$target/include"
    cp -R "$prefix/include/"* "$target/include/"
    # A link, not a copy: edits to the shim take effect without rebuilding FFmpeg.
    ln -s ../../../Sources/CFFmpeg/shim.h "$target/include/CFFmpeg.h"
    cat > "$target/include/module.modulemap" <<'EOF'
module CFFmpeg {
    header "CFFmpeg.h"
    export *
}
EOF
    cat > "$target/shim.c" <<'EOF'
// Everything lives in CFFmpeg.h as static inline functions. This file exists
// because a Swift package C target needs at least one source file.
#include "CFFmpeg.h"
EOF
}

assemble_xcframework() {
    local platform arguments=()
    for platform in "${ALL_PLATFORMS[@]}"; do
        if [[ -d "$WORK/$platform/FFmpeg.framework" ]]; then
            arguments+=(-framework "$WORK/$platform/FFmpeg.framework")
        fi
    done
    [[ ${#arguments[@]} -gt 0 ]] || die "nothing was built"
    rm -rf "$ROOT/Vendor/FFmpeg.xcframework"
    xcodebuild -create-xcframework "${arguments[@]}" -output "$ROOT/Vendor/FFmpeg.xcframework" > /dev/null
    {
        echo "FFmpeg $VERSION, source SHA-256 $SHA256"
        echo "Patches: $(cd "$ROOT/Patches/ffmpeg" 2>/dev/null && ls *.patch 2>/dev/null | tr '\n' ' ')"
        echo "License: LGPL version 2.1 or later (see COPYING.LGPLv2.1 inside each framework)"
        echo "dav1d $DAV1D, source SHA-256 $DAV1D_SHA256, linked in statically"
        echo "Patches: $(cd "$ROOT/Patches/dav1d" 2>/dev/null && ls *.patch 2>/dev/null | tr '\n' ' ')"
        echo "License: BSD 2-Clause (see LICENSE-dav1d.txt inside each framework)"
        echo "Assembler for x86_64: $(nasm --version 2>/dev/null || echo "none, so no x86 assembly")"
        echo "Built $(date -u +%Y-%m-%dT%H:%M:%SZ) with $(xcodebuild -version | tr '\n' ' ')"
        echo "Configure options: see Scripts/build-ffmpeg.sh at the commit that produced this"
    } > "$ROOT/Vendor/FFmpeg.xcframework/BUILD-INFO.txt"
}

PLATFORMS=("$@")
[[ ${#PLATFORMS[@]} -gt 0 ]] || PLATFORMS=("${ALL_PLATFORMS[@]}")
for platform in "${PLATFORMS[@]}"; do describe_platform "$platform"; done

fetch_source
fetch_dav1d
install_build_tools
for platform in "${PLATFORMS[@]}"; do build_platform "$platform"; done
install_c_target
assemble_xcframework

log "Done"
ls -d "$ROOT"/Vendor/FFmpeg.xcframework/*/ | sed "s|$ROOT/||"
