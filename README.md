# CeauKit third-party sources

CeauKit is the playback engine of the app Ceau. Its binaries contain builds of
seven open-source libraries, three of them with changes. This repository holds
what those builds are made from: the patches, the build scripts, the licence
texts, and every upstream source archive, with its address and checksum. Ceau
for Android builds the same libraries, less two, with OpenSSL and changes of
its own: see [Android](#android). Ceau for Windows builds all seven, with zlib,
win-iconv and changes of its own: see [Windows](#windows).

CeauKit itself is not in this repository.

## The libraries

Two dynamic frameworks are built. `FFmpeg.framework` contains FFmpeg, with
dav1d and libxml2 linked into it statically (libxml2 for FFmpeg's DASH reader). `Libass.framework` contains libass, FreeType,
HarfBuzz and FriBidi. For watchOS only FFmpeg is built, without dav1d: a
watch plays sound alone.

| Library | Version | Licence | Patches | Upstream archive | SHA-256 of the archive |
| --- | --- | --- | --- | --- | --- |
| FFmpeg | 9.0.2 | LGPL 2.1 or later | 19 | [ffmpeg-9.0.2.tar.xz](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz) | `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` |
| dav1d | 1.5.4 | BSD 2-Clause | 0 | [dav1d-1.5.4.tar.xz](https://downloads.videolan.org/pub/videolan/dav1d/1.5.4/dav1d-1.5.4.tar.xz) | `686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5` |
| libass | 0.17.5 | ISC | 1 | [libass-0.17.5.tar.xz](https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz) | `2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc` |
| FreeType | 2.15.0 | FreeType License (FTL) | 2 | [freetype-2.15.0.tar.xz](https://download.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz) | `93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5` |
| HarfBuzz | 15.1.0 | MIT | 0 | [harfbuzz-15.1.0.tar.xz](https://github.com/harfbuzz/harfbuzz/releases/download/15.1.0/harfbuzz-15.1.0.tar.xz) | `0fc7c565443a5f4be7da65ac5ee5bd737d9b158dc908708b7689a0a5796b0c8d` |
| FriBidi | 1.0.18 | LGPL 2.1 or later | 0 | [fribidi-1.0.18.tar.xz](https://github.com/fribidi/fribidi/releases/download/v1.0.18/fribidi-1.0.18.tar.xz) | `1de5e8073d035388b71d0b2d452b1da1f8caeea8a7702997b401fe1b6250727f` |
| libxml2 | 2.15.4 | MIT | 0 | [libxml2-2.15.4.tar.xz](https://download.gnome.org/sources/libxml2/2.15/libxml2-2.15.4.tar.xz) | `98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821` |

The same checksums are in [SHA256SUMS](SHA256SUMS) and in the build scripts,
which refuse an archive that does not match.

FFmpeg is configured without `--enable-gpl` and without `--enable-nonfree`.
The full list of configure options is in
[Scripts/build-ffmpeg.sh](Scripts/build-ffmpeg.sh).

## What is in this repository

| Path | What it is |
| --- | --- |
| `Patches/ffmpeg/`, `Patches/freetype/`, `Patches/libass/` | The changes made to the upstream sources. Each file is a description followed by a unified diff. |
| `Scripts/build-ffmpeg.sh` | Builds `FFmpeg.xcframework` from FFmpeg and dav1d. |
| `Scripts/build-libass.sh` | Builds `Libass.xcframework` from libass, FreeType, HarfBuzz and FriBidi. |
| `Scripts/privacy-manifest.sh` | Read by both build scripts. Writes each framework's privacy manifest from the symbols its binary imports. |
| `LICENSES/` | The licence text of each library, one file per library, copied unchanged from its source archive. |
| `BUILD-INFO/` | A copy of the `BUILD-INFO.txt` each build script wrote into the xcframework it last assembled: versions, checksums, patches, the assembler and the Xcode used, and the time of the build. |
| `dist/` | The upstream source archives the builds were made from, as they were downloaded: one `.tar.xz` per library. |
| `SHA256SUMS` | The SHA-256 of each upstream archive. |
| `android/` | What Ceau for Android adds: its patches and its build scripts (see [Android](#android)). |
| `windows/` | What Ceau for Windows adds: its patches and its build scripts (see [Windows](#windows)). |

## The patches

Within a library the patches are applied in the order of their file names,
with `patch -p1`, to the unpacked upstream archive. The description at the top
of each file says what it changes and why.

### FFmpeg 9.0.2

| Patch | What it changes |
| --- | --- |
| `0001-videotoolbox-build-for-visionos` | VideoToolbox builds for visionOS: Metal-compatible buffers are asked for there, because the visionOS SDK marks the OpenGL ES key unavailable. |
| `0002-http-proxy-option-holds-and-407-has-a-code` | A proxy set with the `http_proxy` option is no longer skipped for a host the `no_proxy` environment variable lists, and a proxy's 407 is reported as `AVERROR_HTTP_PROXY_AUTH_REQUIRED`. |
| `0003-hls-seek-past-a-discontinuity` | A seek in a complete HLS playlist that lands past an `EXT-X-DISCONTINUITY` finds its place, where it used to end at the end of the file. |
| `0004-hls-a-ranged-request-is-counted-from-where-it-begins` | A connection opened for a byte range counts its position from where the range begins, so the next segment read over the same connection is not partly skipped. |
| `0005-http-headers-for-another-host` | New option `headers_elsewhere`: what to send in place of `headers` once a redirect has led to a host of another name. |
| `0006-a-seek-the-source-turns-down-fails-and-says-why` | A seek whose request the source refuses fails with what the source said and leaves the reader where it was (Matroska demuxer and HTTP). |
| `0007-http-a-body-sent-as-bare-deflate-is-read` | A body sent under `Content-Encoding: deflate` as deflate with no zlib wrapper is read. |
| `0008-tls-a-failed-handshake-says-what-stood-in-the-way` | Secure Transport: a handshake that fails because the certificate is not trusted, or because no common TLS version exists, returns an error code of its own for each. |
| `0009-hls-a-playlist-that-starts-over-is-joined-again` | A live HLS playlist whose sequence numbers start over is joined again, and its timestamps are passed on as they come. |
| `0010-hls-a-segment-in-hand-is-read-under-its-own-number` | A live HLS playlist is read again only between segments, so a reader that has fallen behind no longer loses segments that are still listed. |
| `0011-http-a-seek-lets-go-of-its-connection-first` | An HTTP seek closes the connection it has before it opens the next, for sources that allow a client one connection. |
| `0012-tls-a-certificate-the-caller-trusts-and-the-one-turned-down` | Secure Transport: new option `trusted_cert_sha256` to trust one certificate named by its SHA-256, and a handshake that fails over a certificate returns that certificate's digest as `refused_cert_sha256`. |
| `0013-http-headers-for-another-host-also-when-tls-is-left` | `headers_elsewhere` also takes effect when a redirect on the same host goes from HTTPS to HTTP. |
| `0014-rtsp-what-was-sent-before-a-play-is-not-of-it` | RTSP: packets and sender reports a source sent before a PLAY that follows another one are not read as the first of what that PLAY sends, so a seek in a recording that comes as datagrams begins at the place asked for. |
| `0015-dash-a-manifest-read-leaves-libxml2-to-the-others` | DASH: reading a manifest leaves libxml2's global state alone, so other users of libxml2 in the same process are not disturbed. |
| `0016-dash-a-live-segment-not-there-yet-is-waited-for` | DASH: a live segment that is listed but not yet there is waited for rather than skipped. |
| `0017-hls-subtitles-in-playlists-of-their-own` | HLS: a subtitle rendition's playlist is fetched when its stream is first wanted, not at the opening. Its WebVTT cues are placed by `X-TIMESTAMP-MAP` (new WebVTT option `timestamp_map`). New HLS option `subtitles_from` starts a newly wanted playlist at the time shown. A cue still up at a seek is kept, and a failed subtitle segment or playlist costs only its subtitles. |
| `0018-hls-a-reader-at-the-end-of-a-live-playlist-keeps-its-pace` | HLS: a reader that has read all of a live playlist sleeps until its reload is due, not up to 100 ms past it, and counts the next reload from the time this one was due, not from when its answer came in, so it no longer falls behind the playlist with every segment. |
| `0019-avs3a-audio-vivid-decoded` | Audio Vivid (AVS3-P3) is decoded: the decoder, parser and readers by Peter Ross in FFmpeg's pull request [25207](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/25207), at its head of 2026-11-20, carried to 9.0.2. It was not merged into FFmpeg when it was taken, and its file says what was changed to carry it. |

### FreeType 2.15.0

| Patch | What it changes |
| --- | --- |
| `0001-unix-size-a-font-file-without-fstat` | The size of a font file that is to be mapped into memory is found with `lseek`, not `fstat`. |
| `0002-hvf-the-version-is-asked-on-every-system-that-has-the-library` | The system's version is asked before every call into Apple's HVF library on tvOS, watchOS and visionOS too, not on macOS and iOS alone. |

### libass 0.17.5

| Patch | What it changes |
| --- | --- |
| `0001-font-find-a-named-instance-by-its-postscript-name` | A named instance of a variable font is found by its PostScript name. |

dav1d, HarfBuzz and FriBidi are built from their upstream sources unchanged.

## Building

The scripts are the ones CeauKit's frameworks are built with, unchanged. They
run on a Mac, from the root of this repository.

They need:

- Xcode, with the SDK of every platform to be built. The builds recorded in
  `BUILD-INFO/` were made with Xcode 27.2.
- `python3`, for `build-ffmpeg.sh` only. dav1d is built with Meson and Ninja,
  which the script installs from PyPI into a Python environment of its own
  under `Vendor/build/tools` (Meson 1.12.1 and Ninja 1.13.2, each held to the
  checksum written in the script). Nothing is installed on the Mac itself.
- `nasm`, optionally, for the hand-written assembly of the Intel half of the
  macOS slice. Without it that half is built in plain C and the script says
  so. The recorded builds used NASM 3.02.
- A network connection, for the upstream archives that are not already in
  `Vendor/build/src/` and for Meson and Ninja.

```bash
Scripts/build-ffmpeg.sh
```

```bash
Scripts/build-libass.sh
```

With no arguments each script builds every platform: `macos` (arm64 and
x86_64), `ios`, `ios-simulator`, `tvos`, `tvos-simulator`, `xros`,
`xros-simulator` (arm64); `build-ffmpeg.sh` also `watchos` (arm64 and
arm64_32) and `watchos-simulator`. Naming platforms builds only those, for example
`Scripts/build-ffmpeg.sh macos ios`. `CEAUKIT_JOBS=4` in the environment
limits a build to four parallel jobs; the default is every core.

Each script looks for its archives in `Vendor/build/src/` and downloads the
ones that are missing from the addresses in the table above. To build from
the copies in this repository, put them there first:

```bash
mkdir -p Vendor/build/src && cp dist/*.tar.xz Vendor/build/src/
```

Either way the script checks each archive against its SHA-256 and stops if it
differs. To check a folder of archives by hand:

```bash
(cd dist && shasum -a 256 -c ../SHA256SUMS)
```

Everything the scripts write is under `Vendor/`, which git ignores:

- `Vendor/FFmpeg.xcframework` and `Vendor/Libass.xcframework`: one dynamic
  framework per platform. Each framework carries the licence texts of what is
  in it and a privacy manifest, each slice its dSYM (the debug symbols the
  framework's binary is stripped of), and each xcframework a `BUILD-INFO.txt`.
- `Vendor/CFFmpeg/` and `Vendor/CAss/`: the libraries' headers, laid out for
  CeauKit's Swift package. Each contains a link to a header of CeauKit that is
  not in this repository, so here the link points at nothing. The frameworks
  do not need it.
- `Vendor/build/`: the unpacked and patched sources, the build tools and the
  intermediate files.

## Licences

The licence text of each library is in [LICENSES/](LICENSES), one file per
library:

| File | Library | Licence |
| --- | --- | --- |
| `LICENSES/FFmpeg.txt` | FFmpeg | GNU Lesser General Public License, version 2.1 |
| `LICENSES/dav1d.txt` | dav1d | BSD 2-Clause |
| `LICENSES/libass.txt` | libass | ISC |
| `LICENSES/FreeType.txt` | FreeType | The FreeType Project License (FTL) |
| `LICENSES/HarfBuzz.txt` | HarfBuzz | MIT ("Old MIT") |
| `LICENSES/FriBidi.txt` | FriBidi | GNU Lesser General Public License, version 2.1 |
| `LICENSES/libxml2.txt` | libxml2 | MIT |
| `LICENSES/OpenSSL.txt` | OpenSSL (Android only) | Apache License 2.0 |
| `LICENSES/zlib.txt` | zlib (Windows only) | zlib License |
| `LICENSES/win-iconv.txt` | win-iconv (Windows only) | Public domain |

Each patch in `Patches/` is offered under the licence of the library it
changes.

## Android

Ceau for Android packs, for each ABI it ships (arm64-v8a, armeabi-v7a,
x86_64), these shared libraries: `libavutil.so`, `libswresample.so`,
`libswscale.so`, `libavcodec.so`, `libavformat.so` and `libavfilter.so`
(FFmpeg), `libass.so` (libass, with FreeType and HarfBuzz linked into it) and
`libceau_fribidi.so` (FriBidi, a library of its own, so that it can be exchanged
like FFmpeg's). They are built from the same archives as above with the same
patches (`0019` from the first build after 2026-11-23; which ones the
current build has is in `BUILD-INFO/Android.txt`), and these differences:

- **OpenSSL 3.5.9** takes the place of Secure Transport for https, linked
  into `libavformat.so`. Its archive is in `dist/`, its licence in
  `LICENSES/OpenSSL.txt`. OpenSSL 3 is under the Apache License 2.0, which
  keeps FFmpeg under the LGPL as it is.
- **MediaCodec** is FFmpeg's hardware decoder there (`--enable-jni
  --enable-mediacodec`), and VideoToolbox, AudioToolbox and Secure Transport
  are left out.
- **dav1d and libxml2 are not built**.
- **Patches of Android's own**, in `android/Patches/`, applied after the ones
  above:

| Patch | What it changes |
| --- | --- |
| `ffmpeg-android/0001-tls-openssl-a-failed-handshake-says-what-stood-in-the-way` | A handshake that fails says which of two things stood in the way. |
| `ffmpeg-android/0002-tls-openssl-a-certificate-the-caller-trusts-and-the-one-turned-down` | A certificate the caller trusts by itself, and which one was turned down. |
| `ffmpeg-android/0003-tls-openssl-the-roots-named-in-ssl-cert-file-read-once-for-every-connection` | The roots named in `SSL_CERT_FILE`, read once for every connection. |
| `ffmpeg-android/0004-mediacodec-a-decoder-that-stalls-no-longer-holds-its-caller-for-ever` | A decoder that stalls no longer holds its caller for ever. |
| `ffmpeg-android/0005-mediacodec-a-running-decoder-can-be-handed-another-surface` | A running decoder can be handed another surface. |
| `ffmpeg-android/0006-mediacodec-a-decoder-that-is-draining-says-a-picture-or-the-end` | A decoder that is draining says a picture or the end. |
| `ffmpeg-android/0007-mediacodec-a-buffer-let-go-of-after-its-decoder-closed-logs-with-no-context` | A buffer let go of after its decoder closed logs with no context (a crash once its context was freed). |
| `ffmpeg-android/0008-mediacodec-a-stalled-decoder-s-two-seconds-are-read-off-the-clock` | Track decoder stall time using the clock. |
| `ffmpeg-android/0009-mediacodec-the-decoder-is-told-how-large-a-picture-s-packet-may-be` | Specify the maximum expected packet size for MediaCodec. |
| `ffmpeg-android/0010-mediacodec-allow-hevc-with-in-band-parameter-sets` | Allow HEVC live streams to supply parameter sets after the hardware decoder opens. |
| `libass-android/0001-fontselect-android-s-fonts-for-the-letters-no-other-font-has` | A font provider of Android's: a letter the chosen font lacks is drawn in the system's font that has it. |
| `libass-android/0002-fontselect-android-s-list-of-its-fonts-where-it-has-no-font-matcher` | On Android 9, which has no font matcher, the provider goes by the system's own list of its fonts (`/system/etc/fonts.xml`). |

To build them again from this repository, with the Android NDK (r30), python3
and, for x86_64, nasm:

```bash
android/Scripts/prepare-sources.sh
CEAUKIT="$PWD/android/work/CeauKit" android/Scripts/build-engine-libs.sh arm64-v8a armeabi-v7a x86_64
```

The first lays `dist/` and `Patches/` out as the Android build reads them;
the second is a copy of the script the app is built with, and writes each
ABI's libraries to `android/build/android/<abi>/install/lib`. What was used
for the current build is in [BUILD-INFO/Android.txt](BUILD-INFO/Android.txt).

## Windows

Ceau for Windows packs, for each architecture it ships (x64 and ARM64, which
the build calls `x86_64` and `aarch64`), these DLLs: `avutil-61.dll`, `swresample-7.dll`, `swscale-10.dll`,
`avcodec-63.dll`, `avformat-63.dll` and `avfilter-12.dll` (FFmpeg, with dav1d
linked into `avcodec-63.dll` and libxml2 into `avformat-63.dll`), `ass.dll`
(libass, with FreeType and HarfBuzz linked into it) and `fribidi-0.dll`
(FriBidi, a library of its own, so that it can be exchanged like FFmpeg's).
They are built from the same archives as above with the same patches
(`0019` from the first build after 2026-11-23; which ones the current build
has is in `BUILD-INFO/Windows.txt`), and these differences:

- **zlib 1.4 and win-iconv 0.0.8**, which Apple's systems and Android bring
  themselves and Windows does not. zlib is linked into `avcodec-63.dll`,
  `avformat-63.dll` and `ass.dll`, win-iconv (an iconv made of the
  conversions Windows has) into `avcodec-63.dll` and `avformat-63.dll`.
  Their archives are in `dist/`, as the build fetches them
  ([zlib-1.4.tar.gz](https://zlib.net/fossils/zlib-1.4.tar.gz) from zlib.net,
  and win-iconv's tag `v0.0.8` as
  [GitHub packs it](https://github.com/win-iconv/win-iconv/archive/refs/tags/v0.0.8.tar.gz)),
  with their checksums in `SHA256SUMS`; their licences are in
  `LICENSES/zlib.txt` and `LICENSES/win-iconv.txt`.
- **SChannel**, the TLS of Windows, takes the place of Secure Transport for
  https (`--enable-schannel`), and **D3D11VA** is FFmpeg's hardware decoder
  there (`--enable-d3d11va`), with Windows' threads; VideoToolbox,
  AudioToolbox, Secure Transport and bzip2 are left out.
- **libass finds the system's fonts through DirectWrite.**
- **Patches of Windows' own**, in `windows/Patches/`, applied after the ones
  above:

| Patch | What it changes |
| --- | --- |
| `ffmpeg-windows/0001-configure-a-dll-s-exports-are-listed-without-microsoft-s-tools` | The list of what a DLL exports is made without Microsoft's own tools: where there is no `lib.exe`, with the archiver and the nm that were named. Build only. |
| `ffmpeg-windows/0002-tls-schannel-a-failed-handshake-says-what-stood-in-the-way` | A handshake that fails says which of two things stood in the way (patch 0008 above, for SChannel). |
| `ffmpeg-windows/0003-tls-schannel-a-certificate-the-caller-trusts-and-the-one-turned-down` | A certificate the caller trusts by itself, and which one was turned down (patch 0012 above, for SChannel); revocation is read from what Windows has cached. |
| `ffmpeg-windows/0004-tls-schannel-tls-1-3-where-windows-speaks-it` | TLS 1.3 where Windows speaks it (Windows 11 and Windows Server 2022), TLS 1.2 as before on Windows 10. |
| `freetype-windows/0001-meson-a-static-library-needs-no-resource-compiler` | A static library is built without a resource compiler. Build only. |

The DLLs are built on a Mac, for Microsoft's ABI, with swift.org's toolchain
for the Mac (6.4.2: its `clang-cl`, `lld-link`, `llvm-ar`, `llvm-nm` and
`llvm-objdump`), Microsoft's C runtime and Windows SDK as
[xwin](https://github.com/Jake-Shadle/xwin) lays them out, nasm, meson,
ninja, pkg-config and Xcode's command line tools. Fetching Microsoft's C
runtime and SDK is accepting the licence of Microsoft's build tools, which
is for the person who fetches them to accept:

```bash
xwin --arch x86_64,aarch64 splat --use-winsysroot-style --preserve-ms-arch-notation \
    --disable-symlinks --output ~/Library/Developer/CeauKitWindowsCheck/winsysroot
```

To build them again from this repository:

```bash
windows/Scripts/prepare-sources.sh
CEAUKIT_DIR="$PWD/windows/work/CeauKit" CEAU_WINDOWS_TOOLCHAIN=<the toolchain's usr/bin> \
    windows/Scripts/build-engine-libs.sh x86_64 aarch64
```

The first lays `dist/` and `Patches/` out as the Windows build reads them;
the second is a copy of the script the app is built with (in the app's
repository, which is not public, as of its commit `db706b9` of 19 November
2026), and writes each architecture's DLLs to
`windows/build/windows/<arch>/install/bin`. `CEAU_WINDOWS_SYSROOT` names
the folder xwin wrote, if it is not the one above. Where the script's
messages send the reader to CeauKit's scripts, `prepare-sources.sh` stands
in for them, and the paragraph above for the tools. What was used for the
current build is in
[BUILD-INFO/Windows.txt](BUILD-INFO/Windows.txt).

## Releases and tags

Each version of Ceau that ships with these libraries gets a tag here, named
`ceau-` and the version number the App Store and the app itself show: the
source of the libraries in Ceau 3.0.0 is the tag `ceau-3.0.0`. Each version
of Ceau for Windows gets one named `ceau-windows-` and its version number,
and each version of Ceau for Android one named `ceau-android-` and its
version number. The China edition of Ceau for Android is numbered on its
own, and its versions are tagged `ceau-android-cn-` and the version number.

A tag is on the first commit whose patches, build scripts and build
information are those of the libraries in that version, so versions that
carry the same libraries share a commit. It is made when that version is
released, is never moved, and stays as long as that version is distributed.
Where no commit of `main` held exactly what built a version, its tag is on a
commit of its own beside `main`, whose message says how it differs; the tag
is what keeps that commit.

Ceau, on iPhone, iPad, Apple Watch, Mac, Apple TV and Apple Vision:

| Version | Tag | Libraries |
| --- | --- | --- |
| 3.0.0 (build 25) | [`ceau-3.0.0`](https://github.com/akiralereal/CeauKit-thirdparty/tree/ceau-3.0.0) | FFmpeg with patches 0001-0018 |
| 3.1.0 (build 26) | [`ceau-3.1.0`](https://github.com/akiralereal/CeauKit-thirdparty/tree/ceau-3.1.0) | the same as 3.0.0 |
| 3.2.0 (build 27) | [`ceau-3.2.0`](https://github.com/akiralereal/CeauKit-thirdparty/tree/ceau-3.2.0) | FFmpeg with patches 0001-0019 |

Ceau for Windows, from the Microsoft Store (1.0.1 was built and never
released):

| Version | Tag | Libraries |
| --- | --- | --- |
| 1.0.0 (MSIX 1.0.0.0) | [`ceau-windows-1.0.0`](https://github.com/akiralereal/CeauKit-thirdparty/tree/ceau-windows-1.0.0) | FFmpeg with patches 0001-0018 |
| 1.1.0 (MSIX 1.1.0.0) | [`ceau-windows-1.1.0`](https://github.com/akiralereal/CeauKit-thirdparty/tree/ceau-windows-1.1.0) | the same as 1.0.0 |
| 1.2.0 (MSIX 1.2.0.0) | [`ceau-windows-1.2.0`](https://github.com/akiralereal/CeauKit-thirdparty/tree/ceau-windows-1.2.0) | the same as 1.0.0 |
| 1.3.0 (MSIX 1.3.0.0) | [`ceau-windows-1.3.0`](https://github.com/akiralereal/CeauKit-thirdparty/tree/ceau-windows-1.3.0) | FFmpeg with patches 0001-0019 |

Ceau for Android has not been released on Google Play yet; its test builds
there have no tags. The China edition of Ceau for Android:

| Version | Tag | Libraries |
| --- | --- | --- |
| 0.3 (build 30) | [`ceau-android-cn-0.3`](https://github.com/akiralereal/CeauKit-thirdparty/tree/ceau-android-cn-0.3) | for API level 30, FFmpeg with patches 0001-0018; on a commit beside `main` |
| 0.4 (build 40) | [`ceau-android-cn-0.4`](https://github.com/akiralereal/CeauKit-thirdparty/tree/ceau-android-cn-0.4) | the same as 0.3 |
| 0.5 (build 50) | [`ceau-android-cn-0.5`](https://github.com/akiralereal/CeauKit-thirdparty/tree/ceau-android-cn-0.5) | for API level 28, FFmpeg with patches 0001-0018; on a commit beside `main` |
| 0.6 (build 60) | [`ceau-android-cn-0.6`](https://github.com/akiralereal/CeauKit-thirdparty/tree/ceau-android-cn-0.6) | the same as 0.5 |
| 0.7 (build 70) | [`ceau-android-cn-0.7`](https://github.com/akiralereal/CeauKit-thirdparty/tree/ceau-android-cn-0.7) | for API level 28, FFmpeg with patches 0001-0019 |
| 0.8 (build 80) | [`ceau-android-cn-0.8`](https://github.com/akiralereal/CeauKit-thirdparty/tree/ceau-android-cn-0.8) | the same as 0.7 |
| 0.9 (build 100) | [`ceau-android-cn-0.9`](https://github.com/akiralereal/CeauKit-thirdparty/tree/ceau-android-cn-0.9) | Android FFmpeg patches 0001–0010 and application-specific FriBidi SONAME at [`61bd410`](https://github.com/akiralereal/CeauKit-thirdparty/commit/61bd4104b391f6dd955b6104a269049d901e0ef3) |

To build the libraries of a released version, check out its tag:

```bash
git checkout ceau-3.2.0
```

The `main` branch holds what the current development builds of CeauKit are
made from, and can be ahead of the latest tag.

## Questions

Open an issue in this repository.
