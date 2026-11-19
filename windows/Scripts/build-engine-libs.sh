#!/bin/bash
# Builds what the engine (CeauKit's CeauCore) links on Windows: FFmpeg, and
# libass with the three libraries it draws text with. On a Mac, for Windows:
# nothing this makes can run here.
#
#   Scripts/build-engine-libs.sh              x86_64 and aarch64
#   Scripts/build-engine-libs.sh x86_64       only this one
#
# The sources are the ones CeauKit's own scripts fetched and patched, in
# ../CeauKit/Vendor/build/src: run its Scripts/build-ffmpeg.sh and
# Scripts/build-libass.sh on this Mac once first. They are read and never
# written: each is copied to build/src, and the patches only Windows needs
# (Patches/<library>-windows: FFmpeg's and FreeType's) are applied to the copy,
# so that CeauKit's own tree, and its builds for Apple's systems, are left
# as they were. Two sources are not CeauKit's: zlib and an iconv, which
# Apple's systems and Android bring themselves and Windows does not. Each is
# fetched once from its own site (zlib.net, and win-iconv's page on GitHub),
# into build/downloads, and held to the SHA-256 below.
#
# What comes out, for each architecture, in build/windows/<arch>/install:
#
#   bin/avutil-NN.dll swresample-N.dll swscale-NN.dll avcodec-NN.dll
#       avformat-NN.dll avfilter-NN.dll    FFmpeg, LGPL, a library each, so
#                                           that it can be replaced on its own;
#                                           dav1d is linked into avcodec,
#                                           libxml2 into avformat, zlib and
#                                           win-iconv into both
#   bin/ass.dll                            libass, with FreeType, HarfBuzz
#                                           and zlib (FTL, MIT and zlib's own,
#                                           none of them LGPL) linked into it;
#                                           the fonts of the system through
#                                           DirectWrite
#   bin/fribidi-0.dll                      FriBidi, LGPL 2.1, a library of its
#                                           own that ass.dll imports, so that
#                                           it can be replaced
#   bin/*.pdb                              the symbols of each, which do not
#                                           ship: they are what a crash inside
#                                           one of them is read with
#   lib/*.lib                              the import libraries to link with
#   lib/*.def                              what each DLL exports, from which
#                                           an import library can be made again
#   include/                               their headers
#
# The ABI is Microsoft's (x86_64-pc-windows-msvc, aarch64-pc-windows-msvc),
# which is what the Swift SDK for Windows links. No MinGW is involved, at
# build time or after.
#
# FFmpeg is configured as CeauKit configures it for Apple's systems
# (CeauKit's Scripts/build-ffmpeg.sh), less what only Apple has
# (VideoToolbox, AudioToolbox, Secure Transport, POSIX threads) and less
# bzip2, which Windows has no library for and Android's build leaves out
# too; with the threads of Windows, the D3D11VA hardware decoders, and
# SChannel, the TLS of Windows, in place of Secure Transport. Its iconv is
# win-iconv, which answers with the conversions Windows has. dav1d is in,
# as on Apple's systems and for the same reason: FFmpeg's own AV1 decoder
# only drives hardware, and many PCs in use have no AV1 hardware decoder.
# libxml2 is in for the DASH reader, with the parts CeauKit builds it with.
# Patches/ffmpeg-windows has SChannel say why a handshake failed and take a
# certificate the caller trusts, as CeauKit's patches have Secure Transport.
#
# The C runtime is the one every Windows 10 and later has (the Universal
# CRT, api-ms-win-crt-*.dll), and the part of it that belongs to Visual C
# (vcruntime) is linked into each DLL. So no DLL here needs the Visual C++
# redistributable, and they all share one heap and one table of files.
#
# Needed, beside Xcode's command line tools (make, the host compiler):
#
#   - swift.org's toolchain for the Mac, for clang-cl, lld-link, llvm-ar
#     (which is llvm-lib when called by that name) and llvm-nm. Found where
#     CeauKit's Scripts/check-windows.sh finds it; CEAU_WINDOWS_TOOLCHAIN
#     says its usr/bin outright.
#   - Microsoft's C runtime and Windows SDK as xwin lays them out
#     (CeauKit's Scripts/check-windows.sh says how), in
#     ~/Library/Developer/CeauKitWindowsCheck/winsysroot, or where
#     CEAU_WINDOWS_SYSROOT says.
#   - nasm (FFmpeg's, dav1d's and libass's x86 assembly), meson and ninja
#     (dav1d, libxml2, FreeType, libass), pkg-config (what meson finds
#     FreeType, HarfBuzz and FriBidi with): `brew install nasm meson ninja
#     pkg-config`.
#
# CEAUKIT_DIR says where CeauKit is when it is not beside this checkout;
# JOBS the compile jobs at a time (every core if not said).
set -euo pipefail

ALL_ARCHITECTURES=(x86_64 aarch64)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CEAUKIT="${CEAUKIT_DIR:-$(cd "$ROOT/../CeauKit" 2>/dev/null && pwd || true)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

# Keep Homebrew and friends out of a build that must only see the sysroot.
unset CPATH C_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CFLAGS LDFLAGS CPPFLAGS CXXFLAGS CC CXX AR NM
# Nothing is written into a source tree, a compiled Python file included.
export PYTHONDONTWRITEBYTECODE=1

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

# The last of the paths a pattern matches, or nothing.
last_of() {
    local path found=""
    for path in "$@"; do
        [[ -e "$path" ]] && found="$path"
    done
    printf '%s' "$found"
}

# The version in the name of a source's folder: 1.2.3 of name-1.2.3-windows.
version_of() {
    local name
    name="$(basename "$1")"
    name="${name%-windows}"
    printf '%s' "${name#*-}"
}

# Writes what a DLL exports as a module definition file ($2), from which an
# import library for it can be made again.
write_def() {
    {
        echo EXPORTS
        "$TOOLCHAIN/llvm-objdump" -p "$1" | awk '
            /^Export Table:/ { table = 1; next }
            table && /Ordinal +RVA +Name/ { names = 1; next }
            table && names && NF == 0 { exit }
            table && names && NF == 3 { print "    " $3 }' | sort
    } > "$2"
}

# FFmpeg's configure and make take their paths apart at spaces.
[[ "$ROOT" != *" "* ]] || die "this checkout is in a folder with a space in its name, which FFmpeg's build cannot work in"

ARCHITECTURES=("$@")
[[ ${#ARCHITECTURES[@]} -gt 0 ]] || ARCHITECTURES=("${ALL_ARCHITECTURES[@]}")
for arch in "${ARCHITECTURES[@]}"; do
    case " ${ALL_ARCHITECTURES[*]} " in
        *" $arch "*) ;;
        *) die "$arch is not an architecture this knows: ${ALL_ARCHITECTURES[*]}" ;;
    esac
done

# MARK: Tools

TOOLCHAIN="${CEAU_WINDOWS_TOOLCHAIN:-}"
[[ -n "$TOOLCHAIN" ]] || TOOLCHAIN="$(last_of "$HOME"/Library/Developer/CeauKitWindowsCheck/toolchain-pkg/*/Payload/usr/bin)"
[[ -n "$TOOLCHAIN" ]] || TOOLCHAIN="$(last_of "$HOME"/Library/Developer/CeauKitAndroidCheck/toolchain-pkg/*/Payload/usr/bin)"
[[ -n "$TOOLCHAIN" ]] || TOOLCHAIN="$(last_of "$HOME"/Library/Developer/Toolchains/swift-*-RELEASE.xctoolchain/usr/bin)"
for tool in clang-cl lld-link llvm-ar llvm-nm llvm-objdump; do
    [[ -n "$TOOLCHAIN" && -x "$TOOLCHAIN/$tool" ]] \
        || die "no swift.org toolchain with $tool where CeauKit's Scripts/check-windows.sh looks: set CEAU_WINDOWS_TOOLCHAIN to its usr/bin"
done
TOOLCHAIN="$(cd "$TOOLCHAIN" && pwd -P)"

SYSROOT="${CEAU_WINDOWS_SYSROOT:-$HOME/Library/Developer/CeauKitWindowsCheck/winsysroot}"
WINDOWS_SDK="$SYSROOT/Windows Kits/10"
WINDOWS_SDK_VERSION="$(last_of "$WINDOWS_SDK/Lib"/10.*)"
WINDOWS_SDK_VERSION="${WINDOWS_SDK_VERSION##*/}"
VISUAL_C="$(last_of "$SYSROOT"/VC/Tools/MSVC/*)"
[[ -n "$WINDOWS_SDK_VERSION" && -n "$VISUAL_C" ]] \
    || die "no C runtime and Windows SDK laid out by xwin at $SYSROOT: CeauKit's Scripts/check-windows.sh says how to fetch them"
SYSROOT="$(cd "$SYSROOT" && pwd -P)"
WINDOWS_SDK="$SYSROOT/Windows Kits/10"
VISUAL_C="$SYSROOT/VC/Tools/MSVC/${VISUAL_C##*/}"

for tool in nasm meson ninja pkg-config make; do
    command -v "$tool" > /dev/null || die "$tool is needed: brew install nasm meson ninja pkg-config"
done
NASM="$(command -v nasm)"
MESON="$(command -v meson)"
NINJA="$(command -v ninja)"
PKG_CONFIG="$(command -v pkg-config)"
HOST_CC="$(xcrun -sdk macosx -f clang) -isysroot $(xcrun -sdk macosx --show-sdk-path)"

# The swift.org toolchain has no llvm-lib. Its llvm-ar is one: LLVM's
# archiver is a librarian of Microsoft's kind when called by that name.
SHARED_TOOLS="$ROOT/build/tools"
mkdir -p "$SHARED_TOOLS"
ln -sfn "$TOOLCHAIN/llvm-ar" "$SHARED_TOOLS/llvm-lib"
LLVM_LIB="$SHARED_TOOLS/llvm-lib"

# The Windows the libraries are for: 10, as it first shipped. The SDK's
# headers declare what a later Windows added only to code that says it is
# for that later one, so that nothing here comes to need a function the
# first Windows 10 has not. (FFmpeg left to itself says Vista.)
WINDOWS_VERSION="-D_WIN32_WINNT=0x0A00 -DNTDDI_VERSION=0x0A000000"

# MARK: Sources

[[ -n "$CEAUKIT" && -d "$CEAUKIT/Vendor/build/src" ]] \
    || die "no CeauKit beside this checkout with its sources fetched (../CeauKit/Vendor/build/src); set CEAUKIT_DIR"
SOURCES="$CEAUKIT/Vendor/build/src"

# The engine leans on CeauKit's patches to FFmpeg, so a source that does not
# carry the ones CeauKit has now would build an FFmpeg the engine was not
# written for. CeauKit's script stamps the source with what it applied.
ceaukit_ffmpeg="$(last_of "$SOURCES"/ffmpeg-*/configure)"
[[ -n "$ceaukit_ffmpeg" ]] || die "CeauKit's sources have no FFmpeg: run its Scripts/build-ffmpeg.sh once"
ceaukit_ffmpeg="$(dirname "$ceaukit_ffmpeg")"
patches_id="$(cat "$CEAUKIT"/Patches/ffmpeg/*.patch 2>/dev/null | shasum -a 256 | cut -c1-16)"
[[ "$(cat "$ceaukit_ffmpeg/.ceaukit-patches" 2>/dev/null)" == "$patches_id" ]] \
    || die "$ceaukit_ffmpeg does not carry CeauKit's current patches: run CeauKit's Scripts/build-ffmpeg.sh"

# Copies one of CeauKit's sources to build/src/<name>-windows and applies
# Patches/<patches>-windows to the copy, afresh whenever CeauKit's source or
# those patches change. $1 is a file the source is known by, $2 the stamp
# CeauKit's scripts left in it, $3 the name of the patches. Sets COPY to the
# copy and COPY_ID to what it was made of.
copy_source() {
    local marker="$1" stamp="$2" patches="$3" found source patch
    found="$(last_of "$SOURCES"/$marker)"
    [[ -n "$found" ]] || die "CeauKit's sources have no ${marker%%-*}: run its Scripts/build-ffmpeg.sh and Scripts/build-libass.sh once"
    source="${found%/"${marker#*/}"}"
    [[ -f "$source/$stamp" ]] || die "$source was not unpacked by CeauKit's scripts: run them once"
    COPY="$ROOT/build/src/$(basename "$source")-windows"
    COPY_ID="$(cat "$source/$stamp") $({ cat "$ROOT/Patches/$patches-windows"/*.patch 2>/dev/null || true; } | shasum -a 256 | cut -c1-16)"
    [[ "$(cat "$COPY/.ceau-windows-source" 2>/dev/null)" != "$COPY_ID" ]] || return 0
    log "$(basename "$source") for Windows, in ${COPY#"$ROOT"/}"
    rm -rf "$COPY" && mkdir -p "$(dirname "$COPY")"
    # A clone where the disk can make one, which takes no room.
    cp -cR "$source" "$COPY" 2>/dev/null || { rm -rf "$COPY"; cp -R "$source" "$COPY"; }
    for patch in "$ROOT/Patches/$patches-windows"/*.patch; do
        [[ -f "$patch" ]] || continue
        echo "applying $(basename "$patch")"
        patch -d "$COPY" -p1 --no-backup-if-mismatch < "$patch" > /dev/null \
            || die "$(basename "$patch") does not apply to CeauKit's $(basename "$source")"
    done
    echo "$COPY_ID" > "$COPY/.ceau-windows-source"
}

copy_source 'ffmpeg-*/configure' .ceaukit-patches ffmpeg;        FFMPEG_SOURCE="$COPY";   FFMPEG_ID="$COPY_ID"
copy_source 'dav1d-*/meson.build' .ceaukit-unpacked dav1d;       DAV1D_SOURCE="$COPY";    DAV1D_ID="$COPY_ID"
copy_source 'libxml2-*/meson.build' .ceaukit-unpacked libxml2;   LIBXML2_SOURCE="$COPY";  LIBXML2_ID="$COPY_ID"
copy_source 'freetype-*/meson.build' .ceaukit-unpacked freetype; FREETYPE_SOURCE="$COPY"; FREETYPE_ID="$COPY_ID"
copy_source 'harfbuzz-*/src/harfbuzz.cc' .ceaukit-unpacked harfbuzz; HARFBUZZ_SOURCE="$COPY"; HARFBUZZ_ID="$COPY_ID"
copy_source 'fribidi-*/lib/fribidi.c' .ceaukit-unpacked fribidi; FRIBIDI_SOURCE="$COPY";  FRIBIDI_ID="$COPY_ID"
copy_source 'libass-*/meson.build' .ceaukit-unpacked libass;     LIBASS_SOURCE="$COPY";   LIBASS_ID="$COPY_ID"

# Fetches a release that is not among CeauKit's sources, once, into
# build/downloads, and unpacks it to build/src/<name>-<version>: $1 the
# name, $2 the version, $3 the SHA-256 of the archive, then where it is
# served, tried in turn. A file that does not match the SHA-256 is thrown
# away rather than built. Sets FETCHED to the source.
fetch_release() {
    local name="$1" version="$2" sha="$3" url archive actual
    shift 3
    FETCHED="$ROOT/build/src/$name-$version"
    [[ "$(cat "$FETCHED/.unpacked" 2>/dev/null)" != "$sha" ]] || return 0
    archive="$ROOT/build/downloads/$name-$version.tar.gz"
    mkdir -p "$(dirname "$archive")"
    if [[ ! -f "$archive" ]]; then
        log "Fetching $name $version"
        for url in "$@"; do
            curl -fsSL --retry 2 -o "$archive.part" "$url" && break
        done
        [[ -s "$archive.part" ]] || die "could not fetch $name $version from $*"
        mv "$archive.part" "$archive"
    fi
    actual="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
    [[ "$actual" == "$sha" ]] \
        || { rm -f "$archive"; die "$name-$version.tar.gz is not the release: SHA-256 $actual"; }
    rm -rf "$FETCHED" && mkdir -p "$(dirname "$FETCHED")"
    tar -xzf "$archive" -C "$(dirname "$FETCHED")"
    [[ -d "$FETCHED" ]] || die "$name-$version.tar.gz did not unpack to ${FETCHED#"$ROOT"/}"
    echo "$sha" > "$FETCHED/.unpacked"
}

# zlib, from its own site: the release, and where that site keeps a release
# once there is a newer one.
ZLIB_VERSION=1.4
ZLIB_SHA256=02dd159783677a749c04adbdd02b55b8a2bcc7e054f51b76b549199a916ad584
fetch_release zlib "$ZLIB_VERSION" "$ZLIB_SHA256" \
    "https://zlib.net/zlib-$ZLIB_VERSION.tar.gz" "https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz"
ZLIB_SOURCE="$FETCHED"

# win-iconv, as GitHub packs the release its project tagged there. It is in
# the public domain.
ICONV_VERSION=0.0.8
ICONV_SHA256=23adea990a8303c6e69e32a64a30171efcb1b73824a1c2da1bbf576b0ae7c520
fetch_release win-iconv "$ICONV_VERSION" "$ICONV_SHA256" \
    "https://github.com/win-iconv/win-iconv/archive/refs/tags/v$ICONV_VERSION.tar.gz"
ICONV_SOURCE="$FETCHED"

# MARK: The compiler and the linker for one architecture

# Writes $tools/clang-cl and $tools/lld-link: the toolchain's own, told what
# they compile and link for. Every build below uses these two and so agrees
# on the target, the Windows it is for and the C runtime.
write_tools() {
    local tools="$1" triple="$2" ms_arch="$3"
    mkdir -p "$tools"
    cat > "$tools/clang-cl" <<EOF
#!/bin/bash
# clang-cl for $triple, with Microsoft's headers from the sysroot.
#
# clang-cl takes an argument that begins with a slash for an option, and
# /Users/... for /U, which undefines a macro: a file named by its whole path
# is not compiled, and the file is said to be missing. A second slash at the
# front names the same file and no option.
#
# What the compiler records of where the sources were (in its debug
# information and in __FILE__) is this repository as \`.\`, and the sysroot
# and the toolchain by those names, so that what it writes names no folder
# of the Mac it was built on. Some of what says so only means something when
# there is debug information to write, and a compile without any would be
# warned of that: a test a configure script makes with warnings as errors
# would then fail for no reason of its own.
arguments=()
for argument in "\$@"; do
    [[ "\$argument" == /* && -f "\$argument" ]] && argument="/\$argument"
    arguments+=("\$argument")
done
exec $(printf '%q' "$TOOLCHAIN/clang-cl") --target=$triple /winsysroot $(printf '%q' "$SYSROOT") -fuse-ld=lld \\
    $WINDOWS_VERSION \\
    -fdebug-compilation-dir=. -gno-codeview-command-line -Wno-unused-command-line-argument \\
    /clang:-ffile-prefix-map=$(printf '%q' "$ROOT")=. \\
    /clang:-ffile-prefix-map=$(printf '%q' "$SYSROOT")=winsysroot \\
    /clang:-ffile-prefix-map=$(printf '%q' "$(dirname "$TOOLCHAIN")")=toolchain \\
    "\${arguments[@]}"
EOF
    cat > "$tools/lld-link" <<EOF
#!/bin/bash
# lld-link for $triple, with Microsoft's libraries from the sysroot.
#
# The C runtime: Windows' own (ucrt.lib is the import library of the
# Universal CRT, which every Windows 10 and later has) in place of the one
# /MT asks for (libucrt.lib, the same code linked in), and Visual C's part
# of it linked in as /MT has it. What comes out needs no vcruntime140.dll.
#
# -debug writes a PDB beside what is linked, and the binary names it by its
# file name alone. With -debug the linker would keep every function nobody
# calls; -opt:ref has it drop them as it does without. Identical functions
# are not folded into one (-opt:noicf): nothing here can be run to see that
# no code tells two of them apart by their addresses.
exec $(printf '%q' "$TOOLCHAIN/lld-link") -machine:$ms_arch \\
    -libpath:$(printf '%q' "$VISUAL_C/lib/$ms_arch") \\
    -libpath:$(printf '%q' "$WINDOWS_SDK/Lib/$WINDOWS_SDK_VERSION/ucrt/$ms_arch") \\
    -libpath:$(printf '%q' "$WINDOWS_SDK/Lib/$WINDOWS_SDK_VERSION/um/$ms_arch") \\
    -nodefaultlib:libucrt.lib -defaultlib:ucrt.lib \\
    -debug -pdbaltpath:%_PDB% -opt:ref -opt:noicf -Brepro -ignore:4099 \\
    "\$@"
EOF
    chmod +x "$tools/clang-cl" "$tools/lld-link"
}

# Meson is told about the machine the code is for in a file. /MT is the C
# runtime as the linker above expects it; -Z7 puts the debug information
# into the objects, where the linker finds it for the PDB.
write_cross_file() {
    local path="$1" tools="$2" arch="$3" pkgconfig="$4"
    cat > "$path" <<EOF
[binaries]
c = '$tools/clang-cl'
cpp = '$tools/clang-cl'
c_ld = '$tools/lld-link'
cpp_ld = '$tools/lld-link'
ar = '$LLVM_LIB'
nasm = '$NASM'
pkg-config = '$PKG_CONFIG'

[built-in options]
b_vscrt = 'mt'
c_args = ['-Z7']
cpp_args = ['-Z7']

[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['$pkgconfig']

[host_machine]
system = 'windows'
cpu_family = '$arch'
cpu = '$arch'
endian = 'little'
EOF
}

# FFmpeg looks for dav1d and libxml2 through pkg-config and no other way.
# This stands in for pkg-config and knows those two libraries, each where it
# was built for this architecture, so nothing installed on this Mac can be
# found by mistake. libxml2 is a static library here, which its headers have
# to be told on Windows (LIBXML_STATIC), and it asks Windows for random
# numbers (bcrypt).
write_pkg_config() {
    local path="$1" deps="$2"
    cat > "$path" <<EOF
#!/bin/sh
package="" want=""
for argument; do
    case "\$argument" in
        --version) echo 0.29.2; exit 0 ;;
        --cflags|--libs|--variable=includedir) want="\$argument" ;;
        dav1d|dav1d\ *) package=dav1d ;;
        libxml-2.0|libxml-2.0\ *) package=libxml2 ;;
        -*|">="|[0-9]*) ;;
        *) exit 1 ;;
    esac
done
[ -n "\$package" ] || exit 1
case "\$package\$want" in
    dav1d--cflags) echo '-I$deps/include' ;;
    dav1d--libs) echo '-L$deps/lib -ldav1d' ;;
    dav1d--variable=includedir) echo '$deps/include' ;;
    libxml2--cflags) echo '-I$deps/include/libxml2 -I$deps/include -DLIBXML_STATIC' ;;
    libxml2--libs) echo '-L$deps/lib -lxml2 -lbcrypt' ;;
    libxml2--variable=includedir) echo '$deps/include' ;;
esac
EOF
    chmod +x "$path"
}

# MARK: Building

build() {
    local arch="$1" triple ms_arch
    case "$arch" in
        x86_64)  triple=x86_64-pc-windows-msvc;  ms_arch=x64 ;;
        aarch64) triple=aarch64-pc-windows-msvc; ms_arch=arm64 ;;
    esac
    local out="$ROOT/build/windows/$arch" prefix="$ROOT/build/windows/$arch/install"
    local tools="$out/tools" deps="$out/deps"
    local cc="$tools/clang-cl" ld="$tools/lld-link"
    mkdir -p "$out" "$deps/include" "$deps/lib/pkgconfig"
    write_tools "$tools" "$triple" "$ms_arch"
    write_cross_file "$out/cross.ini" "$tools" "$arch" "$deps/lib/pkgconfig"
    write_pkg_config "$out/pkg-config" "$deps"
    # What every part below was compiled and linked with: a part built with
    # other tools, or told other things, is built again.
    local tools_id
    tools_id="$(cat "$tools/clang-cl" "$tools/lld-link" "$out/cross.ini" | shasum -a 256 | cut -c1-16) $("$TOOLCHAIN/clang-cl" --version | head -1)"
    # Meson finds lld-link by that name.
    local meson_path="$tools:$PATH"

    # zlib: its fifteen files as they are, into a static library that FFmpeg
    # (deflate in HTTP, in Matroska and in PNG) and FreeType (compressed
    # fonts) are linked with. FFmpeg's configure asks for it as zlib.lib.
    log "zlib $ZLIB_VERSION for $arch"
    local stamp="$out/zlib/built-with" identity="$ZLIB_SHA256 $tools_id zlib-1"
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$identity" && -f "$deps/lib/zlib.lib" ]]; then
        echo "reusing the finished build in ${out#"$ROOT"/}/zlib"
    else
        rm -rf "$out/zlib" && mkdir -p "$out/zlib"
        local file objects=()
        for file in "$ZLIB_SOURCE"/*.c; do
            local object="$out/zlib/$(basename "${file%.c}").obj"
            "$cc" -nologo -MT -O2 -Z7 -D_CRT_SECURE_NO_DEPRECATE -D_CRT_NONSTDC_NO_DEPRECATE \
                -c "$file" "-Fo$object" >> "$out/zlib/compile.log" 2>&1 \
                || { tail -30 "$out/zlib/compile.log"; die "zlib: compile failed for $arch"; }
            objects+=("$object")
        done
        rm -f "$deps/lib/zlib.lib"
        "$LLVM_LIB" -nologo "-out:$deps/lib/zlib.lib" "${objects[@]}" || die "zlib: no library for $arch"
        cp "$ZLIB_SOURCE/zlib.h" "$ZLIB_SOURCE/zconf.h" "$deps/include/"
        printf 'prefix=%s\nName: zlib\nDescription: zlib\nVersion: %s\nLibs: -L${prefix}/lib -lzlib\nCflags: -I${prefix}/include\n' \
            "$deps" "$ZLIB_VERSION" > "$deps/lib/pkgconfig/zlib.pc"
        echo "$identity" > "$stamp"
    fi

    # An iconv, which Windows does not bring: win-iconv, one file that
    # answers iconv's three calls with the conversions Windows has itself.
    # FFmpeg turns the names of a transport stream's programmes into UTF-8
    # with it (on many a Chinese one they are GB2312), and the engine hands
    # those names to its host. Of the encodings FFmpeg asks for there, it
    # knows the ones Windows knows: not ISO 6937, ISO 8859-10, -11 and -14,
    # nor KS C 5601 by the name FFmpeg calls it. A name in one of those is
    # left as it was sent, which is what FFmpeg does without any iconv.
    # It can be built to load an iconv DLL that an environment variable
    # names (USE_LIBICONV_DLL); it is not, and the object is looked at.
    log "win-iconv $ICONV_VERSION for $arch"
    stamp="$out/iconv/built-with" identity="$ICONV_SHA256 $tools_id iconv-1"
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$identity" && -f "$deps/lib/iconv.lib" ]]; then
        echo "reusing the finished build in ${out#"$ROOT"/}/iconv"
    else
        rm -rf "$out/iconv" "$deps/lib/iconv.lib" && mkdir -p "$out/iconv"
        "$cc" -nologo -MT -O2 -Z7 -DWINICONV_CONST= -D_CRT_SECURE_NO_WARNINGS \
            -c "$ICONV_SOURCE/win_iconv.c" "-Fo$out/iconv/win_iconv.obj" > "$out/iconv/compile.log" 2>&1 \
            || { tail -30 "$out/iconv/compile.log"; die "win-iconv: compile failed for $arch"; }
        # (Not `grep -q`, which stops reading, has strings told so, and fails the pipe.)
        if strings -a "$out/iconv/win_iconv.obj" | grep WINICONV_LIBICONV_DLL > /dev/null; then
            die "win-iconv for $arch was built to load an iconv DLL named in the environment"
        fi
        "$LLVM_LIB" -nologo "-out:$deps/lib/iconv.lib" "$out/iconv/win_iconv.obj" || die "win-iconv: no library for $arch"
        cp "$ICONV_SOURCE/iconv.h" "$deps/include/"
        echo "$identity" > "$stamp"
    fi

    # dav1d, as CeauKit builds it: a static library, with its assembly
    # (nasm's for x86_64, the compiler's for arm64).
    log "dav1d for $arch"
    stamp="$out/dav1d/built-with" identity="$DAV1D_ID $tools_id dav1d-1"
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$identity" && -f "$deps/lib/dav1d.lib" ]]; then
        echo "reusing the finished build in ${out#"$ROOT"/}/dav1d"
    else
        rm -rf "$out/dav1d" && mkdir -p "$out/dav1d"
        PATH="$meson_path" "$MESON" setup "$out/dav1d/obj" "$DAV1D_SOURCE" --cross-file "$out/cross.ini" \
            --prefix "$out/dav1d/install" --libdir lib --buildtype release --default-library static \
            --wrap-mode nodownload \
            -Denable_asm=true -Denable_tools=false -Denable_tests=false -Denable_examples=false \
            > "$out/dav1d/setup.log" 2>&1 || { tail -30 "$out/dav1d/setup.log"; die "dav1d: meson failed for $arch"; }
        grep -q '^#define HAVE_ASM 1' "$out/dav1d/obj/config.h" || die "dav1d: no assembly for $arch"
        PATH="$meson_path" "$NINJA" -C "$out/dav1d/obj" -j "$JOBS" install > "$out/dav1d/build.log" 2>&1 \
            || { tail -40 "$out/dav1d/build.log"; die "dav1d: build failed for $arch"; }
        [[ -f "$out/dav1d/install/lib/libdav1d.a" ]] || die "dav1d: no library for $arch"
        # By the name FFmpeg's configure asks the linker for.
        cp "$out/dav1d/install/lib/libdav1d.a" "$deps/lib/dav1d.lib"
        rm -rf "$deps/include/dav1d" && cp -R "$out/dav1d/install/include/dav1d" "$deps/include/dav1d"
        echo "$identity" > "$stamp"
    fi

    # libxml2, as CeauKit builds it: its parser, its tree and its threads,
    # and nothing else the library offers.
    log "libxml2 for $arch"
    stamp="$out/libxml2/built-with" identity="$LIBXML2_ID $tools_id libxml2-1"
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$identity" && -f "$deps/lib/xml2.lib" ]]; then
        echo "reusing the finished build in ${out#"$ROOT"/}/libxml2"
    else
        rm -rf "$out/libxml2" && mkdir -p "$out/libxml2"
        PATH="$meson_path" "$MESON" setup "$out/libxml2/obj" "$LIBXML2_SOURCE" --cross-file "$out/cross.ini" \
            --prefix "$out/libxml2/install" --libdir lib --buildtype release --default-library static \
            --wrap-mode nodownload \
            -Dminimum=true -Dthreads=enabled \
            -Dhttp=disabled -Diconv=disabled -Diso8859x=disabled -Dicu=disabled -Dzlib=disabled \
            -Dcatalog=disabled -Dmodules=disabled -Dpython=disabled -Ddocs=disabled \
            -Dreadline=disabled -Dhistory=disabled \
            > "$out/libxml2/setup.log" 2>&1 || { tail -30 "$out/libxml2/setup.log"; die "libxml2: meson failed for $arch"; }
        PATH="$meson_path" "$NINJA" -C "$out/libxml2/obj" -j "$JOBS" install > "$out/libxml2/build.log" 2>&1 \
            || { tail -40 "$out/libxml2/build.log"; die "libxml2: build failed for $arch"; }
        [[ -f "$out/libxml2/install/lib/libxml2.a" ]] || die "libxml2: no library for $arch"
        # What it was configured with is looked at in the header it
        # installs, which states each part the library has.
        local parts
        echo '#include <libxml/xmlversion.h>' > "$out/libxml2/parts.c"
        parts="$("$cc" -nologo -I"$out/libxml2/install/include/libxml2" -DLIBXML_STATIC -E /clang:-dM "$out/libxml2/parts.c" 2>/dev/null \
            | sed -n 's/^#define LIBXML_\([A-Z0-9_]*\)_ENABLED.*/\1/p' | sort | tr '\n' ' ')"
        [[ "$parts" == "THREAD TREE " ]] || die "libxml2 for $arch has other parts than its parser, its tree and its threads: $parts"
        cp "$out/libxml2/install/lib/libxml2.a" "$deps/lib/xml2.lib"
        rm -rf "$deps/include/libxml2" && cp -R "$out/libxml2/install/include/libxml2" "$deps/include/libxml2"
        echo "$identity" > "$stamp"
    fi

    log "FFmpeg for $arch"
    local extra=()
    case "$arch" in
        x86_64)  extra+=(--x86asmexe="$NASM") ;;
        # Its assembly for arm64 goes through the compiler, as on every other
        # system: Microsoft's armasm64, which FFmpeg would look for with
        # these tools, reads another language.
        aarch64) extra+=(--as="$cc") ;;
    esac
    local options=(
        --prefix="$out/ffmpeg/install"
        --enable-cross-compile --toolchain=msvc --target-os=win32 --arch="$arch" --host-os=darwin
        --cc="$cc" --cxx="$cc" --ld="$ld"
        --ar="$TOOLCHAIN/llvm-ar" --nm="$TOOLCHAIN/llvm-nm"
        --host-cc="$HOST_CC"
        --extra-cflags="-MT -DWINICONV_CONST= -I$deps/include"
        --extra-ldflags="-libpath:$deps/lib"
        # FFmpeg's configure, told to find nothing by itself, looks for
        # iconv in the C runtime alone, where Windows has none. So the
        # library is named for every link, as the linker spells it (this
        # option is handed on as it is); only what calls it takes it in.
        --extra-libs=iconv.lib
        --pkg-config="$out/pkg-config"
        --enable-shared --disable-static
        --disable-programs --disable-doc --enable-debug
        --disable-avdevice --disable-encoders --disable-muxers
        --disable-autodetect --enable-w32threads
        --enable-schannel --enable-d3d11va
        --enable-zlib --enable-iconv
        --enable-libdav1d
        --enable-libxml2 --disable-demuxer=imf
        --disable-demuxer=aa
        --disable-filters
        --enable-filter=bwdif,yadif,scale,format,null,anull,aresample,aformat,volume,acompressor,dynaudnorm,loudnorm
        ${extra[@]+"${extra[@]}"}
    )
    stamp="$out/ffmpeg/built-with"
    identity="$FFMPEG_ID $ZLIB_SHA256 $ICONV_SHA256 $DAV1D_ID $LIBXML2_ID $tools_id ffmpeg-1 ${options[*]}"
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$identity" ]]; then
        echo "reusing the finished build in ${out#"$ROOT"/}/ffmpeg"
    else
        rm -rf "$out/ffmpeg" && mkdir -p "$out/ffmpeg" && cd "$out/ffmpeg"
        "$FFMPEG_SOURCE/configure" "${options[@]}" > configure.log 2>&1 \
            || { tail -30 configure.log; die "FFmpeg: configure failed for $arch"; }

        # FFmpeg keeps the command it was configured with, to show when asked
        # (`avformat_configuration`), and that command names folders of the
        # Mac it was built on. What ships says where in this repository
        # things were, not whose home the repository was in.
        sed -i '' -e "s|$ROOT/||g" -e "s|$ROOT|.|g" -e "s|$HOME|~|g" config.h

        grep -qE '^#define CONFIG_(GPL|NONFREE|VERSION3) 1' config.h \
            && die "FFmpeg for $arch was configured with GPL, LGPL 3 or nonfree parts"
        grep -q '^#define FFMPEG_LICENSE "LGPL version 2.1 or later"' config.h \
            || die "FFmpeg for $arch is not under the LGPL 2.1"
        grep -q '^#define CONFIG_SCHANNEL 1' config.h && grep -q '^#define CONFIG_HTTPS_PROTOCOL 1' config_components.h \
            || die "FFmpeg for $arch has no SChannel and so no https"
        local decoder
        for decoder in H264_D3D11VA2 HEVC_D3D11VA2 VP9_D3D11VA2 AV1_D3D11VA2; do
            grep -q "^#define CONFIG_${decoder}_HWACCEL 1" config_components.h \
                || die "FFmpeg for $arch has no $decoder hardware decoder"
        done
        grep -q '^#define CONFIG_LIBDAV1D_DECODER 1' config_components.h || die "FFmpeg for $arch was configured without dav1d"
        grep -q '^#define CONFIG_LIBXML2 1' config.h && grep -q '^#define CONFIG_DASH_DEMUXER 1' config_components.h \
            || die "FFmpeg for $arch was configured without libxml2 and DASH"
        grep -q '^#define CONFIG_IMF_DEMUXER 0' config_components.h || die "FFmpeg for $arch was configured with the IMF reader"
        grep -q '^#define CONFIG_AA_DEMUXER 0' config_components.h || die "FFmpeg for $arch was configured with Audible's .aa reader"
        grep -q '^#define CONFIG_ZLIB 1' config.h || die "FFmpeg for $arch was configured without zlib"
        grep -q '^#define CONFIG_ICONV 1' config.h || die "FFmpeg for $arch was configured without an iconv"
        grep -q '^#define HAVE_W32THREADS 1' config.h || die "FFmpeg for $arch was configured without Windows' threads"
        # The hand-written code is what makes software decoding quick enough
        # to watch. A build that was meant to have it and has not is not a build.
        if [[ "$arch" == aarch64 ]]; then
            grep -q '^#define HAVE_NEON 1' config.h || die "FFmpeg for $arch was configured without its assembly"
        else
            grep -q '^#define HAVE_X86ASM 1' config.h || die "FFmpeg for $arch was configured without its assembly"
        fi

        # FFmpeg writes the list of what a DLL exports with a script
        # (compat/windows/makedef; Patches/ffmpeg-windows/0001 has it use
        # the archiver and the nm named above) that keeps its work in a file
        # of one name whichever library it is for: two libraries linked at
        # one time would write over each other's. So they are made one after
        # the other, each compiled with every job.
        local library
        : > make.log
        for library in avutil swresample swscale avcodec avformat avfilter; do
            make -j"$JOBS" "lib$library/$library.dll" >> make.log 2>&1 \
                || { tail -40 make.log; die "FFmpeg: make failed for $arch at $library"; }
        done
        make install > install.log 2>&1 || { tail -20 install.log; die "FFmpeg: make install failed for $arch"; }
        echo "$identity" > "$stamp"
    fi

    # FreeType, by its Meson build: a static library, with its reader of
    # compressed fonts on the zlib above and nothing else it could link. It
    # maps font files into memory (builds/windows/ftsystem.c), as CeauKit has
    # it do on Apple's systems. Patches/freetype-windows has that build not
    # ask for a resource compiler, which a static library has no use for.
    log "FreeType for $arch"
    stamp="$out/freetype/built-with" identity="$FREETYPE_ID $ZLIB_SHA256 $tools_id freetype-1"
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$identity" && -f "$deps/lib/libfreetype.a" ]]; then
        echo "reusing the finished build in ${out#"$ROOT"/}/freetype"
    else
        rm -rf "$out/freetype" "$deps/include/freetype2" "$deps/lib/libfreetype.a" "$deps/lib/pkgconfig/freetype2.pc"
        mkdir -p "$out/freetype"
        PATH="$meson_path" "$MESON" setup "$out/freetype/obj" "$FREETYPE_SOURCE" --cross-file "$out/cross.ini" \
            --prefix "$deps" --libdir lib --buildtype release --default-library static \
            --wrap-mode nodownload \
            -Dzlib=system -Dbzip2=disabled -Dpng=disabled -Dharfbuzz=disabled -Dbrotli=disabled -Dhvf=disabled \
            -Dmmap=enabled -Dtests=disabled \
            > "$out/freetype/setup.log" 2>&1 || { tail -30 "$out/freetype/setup.log"; die "FreeType: meson failed for $arch"; }
        grep -q 'builds/windows/ftsystem.c' "$out/freetype/obj/build.ninja" \
            || die "FreeType: configured to read font files through stdio for $arch, not to map them"
        PATH="$meson_path" "$NINJA" -C "$out/freetype/obj" -j "$JOBS" install > "$out/freetype/build.log" 2>&1 \
            || { tail -40 "$out/freetype/build.log"; die "FreeType: build failed for $arch"; }
        [[ -f "$deps/lib/libfreetype.a" && -f "$deps/lib/pkgconfig/freetype2.pc" ]] || die "FreeType: no library for $arch"
        echo "$identity" > "$stamp"
    fi

    # HarfBuzz as one source file, with no exceptions or run-time types, so
    # that it needs nothing of the C++ library when it runs.
    #
    # Microsoft's math.h spells NAN as infinity times nought, which their
    # compiler takes for a constant and clang does not, and HarfBuzz
    # initialises a constant with it. A header read before everything else
    # reads math.h first and then gives NAN the spelling clang has for it;
    # math.h is read once, so that spelling stays.
    log "HarfBuzz for $arch"
    stamp="$out/harfbuzz/built-with" identity="$HARFBUZZ_ID $tools_id harfbuzz-2"
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$identity" && -f "$deps/lib/harfbuzz.lib" ]]; then
        echo "reusing the finished build in ${out#"$ROOT"/}/harfbuzz"
    else
        rm -rf "$out/harfbuzz" "$deps/include/harfbuzz" "$deps/lib/harfbuzz.lib"
        mkdir -p "$out/harfbuzz" "$deps/include/harfbuzz"
        printf '#include <math.h>\n#undef NAN\n#define NAN __builtin_nanf("")\n' > "$out/harfbuzz/constant-nan.h"
        "$cc" -nologo -MT -O2 -Z7 /std:c++17 /GR- /EHs-c- /Zc:threadSafeInit- \
            -DHB_NO_PRAGMA_GCC_DIAGNOSTIC_ERROR -D_CRT_SECURE_NO_WARNINGS "/FI$out/harfbuzz/constant-nan.h" \
            -c "$HARFBUZZ_SOURCE/src/harfbuzz.cc" "-Fo$out/harfbuzz/harfbuzz.obj" > "$out/harfbuzz/compile.log" 2>&1 \
            || { tail -30 "$out/harfbuzz/compile.log"; die "HarfBuzz: compile failed for $arch"; }
        "$LLVM_LIB" -nologo "-out:$deps/lib/harfbuzz.lib" "$out/harfbuzz/harfbuzz.obj" || die "HarfBuzz: no library for $arch"
        cp "$HARFBUZZ_SOURCE"/src/hb*.h "$deps/include/harfbuzz/"
        printf 'prefix=%s\nName: harfbuzz\nDescription: HarfBuzz\nVersion: %s\nLibs: -L${prefix}/lib -lharfbuzz\nCflags: -I${prefix}/include/harfbuzz\n' \
            "$deps" "$(version_of "$HARFBUZZ_SOURCE")" > "$deps/lib/pkgconfig/harfbuzz.pc"
        echo "$identity" > "$stamp"
    fi

    # FriBidi's files as they are, with its tables ready made, into a DLL of
    # its own: FriBidi is LGPL 2.1, and a user can only replace it as the
    # licence asks if it is not part of another file. Its headers export
    # what they declare when FRIBIDI_BUILD says the library itself is being
    # compiled, and import it otherwise, which is what libass then does. The
    # DLL has the name FriBidi's own build gives it.
    log "FriBidi for $arch"
    stamp="$out/fribidi/built-with" identity="$FRIBIDI_ID $tools_id fribidi-1"
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$identity" && -f "$deps/lib/fribidi.lib" ]]; then
        echo "reusing the finished build in ${out#"$ROOT"/}/fribidi"
    else
        rm -rf "$out/fribidi" "$deps/include/fribidi" "$deps/lib/fribidi.lib"
        mkdir -p "$out/fribidi" "$deps/include/fribidi"
        local version major rest file objects=()
        version="$(version_of "$FRIBIDI_SOURCE")"
        major="${version%%.*}" rest="${version#*.}"
        sed -e "s/@PACKAGE@/fribidi/" -e "s/@PACKAGE_NAME@/GNU FriBidi/" -e "s/@PACKAGE_BUGREPORT@//" \
            -e "s/@FRIBIDI_VERSION@/$version/" -e "s/@FRIBIDI_MAJOR_VERSION@/$major/" \
            -e "s/@FRIBIDI_MINOR_VERSION@/${rest%%.*}/" -e "s/@FRIBIDI_MICRO_VERSION@/${rest#*.}/" \
            -e "s/@FRIBIDI_INTERFACE_VERSION@/4/g" -e "s/@SIZEOF_INT@/4/" \
            -e "s/@FRIBIDI_MSVC_BUILD_PLACEHOLDER@//" -e "s/@configure_input@/made by build-engine-libs.sh/" \
            "$FRIBIDI_SOURCE/lib/fribidi-config.h.in" > "$deps/include/fribidi/fribidi-config.h"
        grep -q '@' "$deps/include/fribidi/fribidi-config.h" && die "FriBidi: fribidi-config.h.in has a field this script does not fill"
        cp "$FRIBIDI_SOURCE"/lib/fribidi*.h "$deps/include/fribidi/"
        for file in "$FRIBIDI_SOURCE"/lib/*.c; do
            local object="$out/fribidi/$(basename "${file%.c}").obj"
            "$cc" -nologo -MT -O2 -Z7 -I"$deps/include/fribidi" -I"$FRIBIDI_SOURCE/lib" -DFRIBIDI_BUILD \
                -DHAVE_STDLIB_H=1 -DHAVE_STRING_H=1 -DHAVE_STRINGIZE=1 -DSTDC_HEADERS=1 -D_CRT_SECURE_NO_WARNINGS \
                -c "$file" "-Fo$object" >> "$out/fribidi/compile.log" 2>&1 \
                || { tail -30 "$out/fribidi/compile.log"; die "FriBidi: compile failed for $arch"; }
            objects+=("$object")
        done
        (cd "$out/fribidi" && "$ld" -nologo -dll -out:fribidi-0.dll -implib:fribidi.lib "${objects[@]}") > "$out/fribidi/link.log" 2>&1 \
            || { tail -30 "$out/fribidi/link.log"; die "FriBidi: link failed for $arch"; }
        write_def "$out/fribidi/fribidi-0.dll" "$out/fribidi/fribidi-0.def"
        grep -q '^ *fribidi_log2vis$' "$out/fribidi/fribidi-0.def" || die "FriBidi: the DLL for $arch does not export its API"
        cp "$out/fribidi/fribidi.lib" "$deps/lib/fribidi.lib"
        printf 'prefix=%s\nName: fribidi\nDescription: GNU FriBidi\nVersion: %s\nLibs: -L${prefix}/lib -lfribidi\nCflags: -I${prefix}/include/fribidi\n' \
            "$deps" "$version" > "$deps/lib/pkgconfig/fribidi.pc"
        echo "$identity" > "$stamp"
    fi

    # libass, by its Meson build, as a static library first: with its
    # assembly, and with DirectWrite for the fonts of the system (which it
    # loads when it runs; what it links is GDI and the window system's
    # device context, to find a font by the name a subtitle calls it). Then
    # the DLL: libass with FreeType, HarfBuzz and
    # zlib in it and FriBidi named, not in it, exporting what libass's own
    # list (libass.sym) says and nothing of the libraries inside.
    #
    # libass asks git what it is built from, to say so in its log. Asked
    # inside this repository, git would answer with a commit of Ceau's;
    # it is stopped from looking above build/ (GIT_CEILING_DIRECTORIES).
    log "libass for $arch"
    stamp="$out/libass/built-with"
    identity="$LIBASS_ID $FREETYPE_ID $HARFBUZZ_ID $FRIBIDI_ID $ZLIB_SHA256 $tools_id libass-1"
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$identity" && -f "$out/libass/ass.dll" ]]; then
        echo "reusing the finished build in ${out#"$ROOT"/}/libass"
    else
        rm -rf "$out/libass" && mkdir -p "$out/libass"
        PATH="$meson_path" GIT_CEILING_DIRECTORIES="$ROOT/build" "$MESON" setup "$out/libass/obj" "$LIBASS_SOURCE" --cross-file "$out/cross.ini" \
            --prefix "$out/libass/install" --libdir lib --buildtype release --default-library static \
            --wrap-mode nodownload \
            -Dfontconfig=disabled -Ddirectwrite=enabled -Dcoretext=disabled -Dasm=enabled -Dlibunibreak=disabled \
            -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled \
            > "$out/libass/setup.log" 2>&1 || { tail -30 "$out/libass/setup.log"; die "libass: meson failed for $arch"; }
        PATH="$meson_path" GIT_CEILING_DIRECTORIES="$ROOT/build" "$NINJA" -C "$out/libass/obj" -j "$JOBS" install > "$out/libass/build.log" 2>&1 \
            || { tail -40 "$out/libass/build.log"; die "libass: build failed for $arch"; }
        [[ -f "$out/libass/install/lib/libass.a" ]] || die "libass: no library for $arch"
        grep -q '^#define CONFIG_DIRECTWRITE 1' "$out/libass/obj/config.h" || die "libass: configured without DirectWrite for $arch"
        grep -q '^#define CONFIG_ASM 1' "$out/libass/obj/config.h" || die "libass: configured without its assembly for $arch"
        grep -qE '^#define CONFIG_(FONTCONFIG|CORETEXT|ICONV|UNIBREAK) 1' "$out/libass/obj/config.h" \
            && die "libass: configured with a part it was not to have for $arch"
        { echo EXPORTS; sed 's/^/    /' "$LIBASS_SOURCE/libass/libass.sym"; } > "$out/libass/ass.def"
        # Its assembly for arm64 is a library beside it, which Meson does
        # not install.
        local archives=("$out/libass/install/lib/libass.a") archive
        while IFS= read -r archive; do archives+=("$archive"); done < <(find "$out/libass/obj" -name 'libass_asm.a')
        (cd "$out/libass" && "$ld" -nologo -dll -out:ass.dll -implib:ass.lib -def:ass.def "${archives[@]}" \
            "$deps/lib/harfbuzz.lib" "$deps/lib/libfreetype.a" "$deps/lib/zlib.lib" "$deps/lib/fribidi.lib" gdi32.lib user32.lib) \
            > "$out/libass/link.log" 2>&1 || { tail -30 "$out/libass/link.log"; die "libass: link failed for $arch"; }
        echo "$identity" > "$stamp"
    fi

    # What the build is for: one folder with the DLLs and their symbols, the
    # import libraries, the headers and the licences, made afresh from the
    # parts above every time.
    log "Putting $arch together in ${prefix#"$ROOT"/}"
    rm -rf "$prefix" && mkdir -p "$prefix/bin" "$prefix/lib" "$prefix/include/ass" "$prefix/licenses"
    cp "$out/ffmpeg/install/bin"/*.dll "$out"/ffmpeg/lib*/*.pdb "$prefix/bin/"
    cp "$out/ffmpeg/install/bin"/*.lib "$out/ffmpeg/install/lib"/*.def "$prefix/lib/"
    cp -R "$out/ffmpeg/install/include"/* "$prefix/include/"
    cp "$out/fribidi/fribidi-0.dll" "$out/fribidi/fribidi-0.pdb" "$out/libass/ass.dll" "$out/libass/ass.pdb" "$prefix/bin/"
    cp "$out/fribidi/fribidi.lib" "$out/fribidi/fribidi-0.def" "$out/libass/ass.lib" "$out/libass/ass.def" "$prefix/lib/"
    cp "$out/libass/install/include/ass"/*.h "$prefix/include/ass/"
    local dll
    for dll in "$prefix/bin"/*.dll; do
        [[ -f "${dll%.dll}.pdb" ]] || die "$(basename "$dll") for $arch has no symbols beside it"
    done
    # The licences travel with the binaries.
    cp "$FFMPEG_SOURCE/COPYING.LGPLv2.1" "$prefix/licenses/FFmpeg-LGPLv2.1.txt"
    cp "$DAV1D_SOURCE/COPYING" "$prefix/licenses/dav1d.txt"
    cp "$LIBXML2_SOURCE/LICENSE-libxml2.txt" "$prefix/licenses/libxml2.txt"
    cp "$ZLIB_SOURCE/LICENSE" "$prefix/licenses/zlib.txt"
    cp "$ICONV_SOURCE/readme.txt" "$prefix/licenses/win-iconv.txt"
    cp "$LIBASS_SOURCE/COPYING" "$prefix/licenses/libass.txt"
    cp "$FREETYPE_SOURCE/docs/FTL.TXT" "$prefix/licenses/FreeType-FTL.txt"
    cp "$HARFBUZZ_SOURCE/COPYING" "$prefix/licenses/HarfBuzz.txt"
    cp "$FRIBIDI_SOURCE/COPYING" "$prefix/licenses/FriBidi-LGPLv2.1.txt"
    {
        echo "For Windows on $arch ($triple), Windows 10 and later."
        echo "FFmpeg $(version_of "$FFMPEG_SOURCE"), with CeauKit's patches ($patches_id) and Patches/ffmpeg-windows: $(cd "$ROOT/Patches/ffmpeg-windows" 2>/dev/null && ls *.patch 2>/dev/null | tr '\n' ' ')"
        echo "License: LGPL version 2.1 or later; a DLL for each of its libraries"
        echo "dav1d $(version_of "$DAV1D_SOURCE"), linked into avcodec. License: BSD 2-Clause"
        echo "libxml2 $(version_of "$LIBXML2_SOURCE"), linked into avformat, for the DASH reader: its parser, its tree and its threads. License: MIT"
        echo "zlib $ZLIB_VERSION, source SHA-256 $ZLIB_SHA256, linked into avcodec, avformat and ass. License: zlib"
        echo "win-iconv $ICONV_VERSION, source SHA-256 $ICONV_SHA256, linked into avcodec and avformat. Public domain"
        echo "libass $(version_of "$LIBASS_SOURCE"), with DirectWrite. License: ISC"
        echo "FreeType $(version_of "$FREETYPE_SOURCE"), linked into ass, with Patches/freetype-windows: $(cd "$ROOT/Patches/freetype-windows" 2>/dev/null && ls *.patch 2>/dev/null | tr '\n' ' '). License: FreeType License (FTL)"
        echo "HarfBuzz $(version_of "$HARFBUZZ_SOURCE"), linked into ass. License: MIT"
        echo "FriBidi $(version_of "$FRIBIDI_SOURCE"), a DLL of its own. License: LGPL version 2.1 or later"
        echo "C runtime: the Universal CRT of Windows; Visual C's part of it (${VISUAL_C##*/}) is linked into each DLL"
        echo "Compiler: $("$TOOLCHAIN/clang-cl" --version | head -1), as clang-cl with lld-link"
        echo "Windows SDK $WINDOWS_SDK_VERSION; headers told that the code is for the first Windows 10 ($WINDOWS_VERSION)"
        echo "Assembler for x86_64: $("$NASM" --version)"
        echo "Meson $("$MESON" --version), Ninja $("$NINJA" --version)"
        echo "Debug symbols: a PDB beside each DLL, which does not ship"
        echo "Built $(date -u +%Y-%m-%dT%H:%M:%SZ) by Scripts/build-engine-libs.sh"
    } > "$prefix/BUILD-INFO.txt"
}

for arch in "${ARCHITECTURES[@]}"; do
    build "$arch"
done
log "Built for ${ARCHITECTURES[*]}: build/windows/<arch>/install"
