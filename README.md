# CeauKit third-party sources

CeauKit is the playback engine of the app Ceau. Its binaries contain builds of
seven open-source libraries, three of them with changes. This repository holds
what those builds are made from: the patches, the build scripts, the licence
texts, and every upstream source archive, with its address and checksum.

CeauKit itself is not in this repository.

## The libraries

Two dynamic frameworks are built. `FFmpeg.framework` contains FFmpeg, with
dav1d and libxml2 linked into it statically (libxml2 for FFmpeg's DASH reader). `Libass.framework` contains libass, FreeType,
HarfBuzz and FriBidi. For watchOS only FFmpeg is built, without dav1d: a
watch plays sound alone.

| Library | Version | Licence | Patches | Upstream archive | SHA-256 of the archive |
| --- | --- | --- | --- | --- | --- |
| FFmpeg | 9.0.2 | LGPL 2.1 or later | 16 | [ffmpeg-9.0.2.tar.xz](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz) | `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` |
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
  in it and a privacy manifest, and each xcframework a `BUILD-INFO.txt`.
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

Each patch in `Patches/` is offered under the licence of the library it
changes.

## Releases and tags

No version of Ceau that contains these libraries has been released, and this
repository has no tags. The `main` branch holds what the current development
builds of CeauKit are made from.

## Questions

Open an issue in this repository.
