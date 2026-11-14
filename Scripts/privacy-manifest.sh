#!/bin/bash
# Writes a framework's privacy manifest from what its binary calls.
#
# Apple lists the APIs an app has to give a reason for using ("Describing use
# of required reason API" in its documentation), in five categories: file
# timestamps, the time since the system started, disk space, the active
# keyboards, and user defaults. A framework states its own uses in a
# PrivacyInfo.xcprivacy inside it, and App Store Connect holds an upload
# against those statements. So the statement is made from the binary, not from
# memory: a slice that calls nothing on the list says so, one that calls
# `fstat` says that, and a new version of a library that starts calling
# `statfs` stops the build until somebody has written down why.
#
# How it is found out. The undefined symbols of the finished binary are
# everything it asks the system for (`nm -u`, every architecture). The C
# functions and Core Foundation keys on Apple's list are looked for among
# them by name. The rest of the list is Foundation and UIKit (`UserDefaults`,
# `systemUptime`, file attributes, `activeInputModes`), which is reached by
# sending Objective-C messages, and a symbol table does not show which. A
# binary that calls into Objective-C or Swift at all is therefore refused
# here rather than vouched for; the libraries CeauKit builds are plain C.
#
# What the manifest says besides: no tracking, no tracking domains, no data
# collected. These libraries read and decode what they are handed and send
# nothing anywhere of their own accord.
#
# Sourced by the build scripts, which call `write_privacy_manifest`. Run on
# its own, it prints what a binary would have to state:
#
#   Scripts/privacy-manifest.sh Vendor/FFmpeg.xcframework/ios-arm64/FFmpeg.framework/FFmpeg

# The categories a symbol on Apple's list belongs to. `getattrlist` and its
# kin are on two lists: they can read a file's dates and a volume's space.
privacy_categories_of() {
    case "$1" in
        stat|fstat|lstat|fstatat|stat64|fstat64|lstat64|getattrlistbulk) echo FileTimestamp ;;
        getattrlist|fgetattrlist|getattrlistat) echo FileTimestamp DiskSpace ;;
        statfs|fstatfs|statvfs|fstatvfs|statfs64|fstatfs64) echo DiskSpace ;;
        mach_absolute_time) echo SystemBootTime ;;
        kCFURLCreationDateKey|kCFURLContentModificationDateKey) echo FileTimestamp ;;
        kCFURLVolumeAvailableCapacity*Key|kCFURLVolumeTotalCapacityKey) echo DiskSpace ;;
        CFPreferences*) echo UserDefaults ;;
    esac
}

# Prints "Category symbol" for every listed API the binary imports, and fails
# for a binary this way of looking cannot answer for.
privacy_uses() {
    local binary="$1" imports symbol category
    imports="$(nm -u -arch all "$binary" 2>/dev/null | awk 'NF { print $NF }' | sort -u)"
    [[ -n "$imports" ]] || { echo "error: $binary has no symbol table to read" >&2; return 1; }
    if grep -q -E '^(_objc_msgSend|_OBJC_CLASS_\$_|_\$s|_swift_)' <<< "$imports"; then
        echo "error: $binary calls into Objective-C or Swift; its symbols do not show which required-reason APIs it uses" >&2
        return 1
    fi
    for symbol in $imports; do
        symbol="${symbol#_}"
        symbol="${symbol%%\$*}"    # _stat$INODE64 is stat
        for category in $(privacy_categories_of "$symbol"); do
            echo "$category $symbol"
        done
    done | sort -u
}

# write_privacy_manifest <binary> <output> <name> [Category=REASON,REASON ...]
#
# The reasons are the caller's: why its library calls what it calls. One is
# written only where the binary uses the category, and a category the binary
# uses with no reason given is an error.
write_privacy_manifest() {
    local binary="$1" output="$2" name="$3"; shift 3
    local uses categories category reasons entry reason summary=""
    uses="$(privacy_uses "$binary")" || exit 1
    categories="$(awk '{ print $1 }' <<< "$uses" | sort -u)"
    {
        cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key><false/>
    <key>NSPrivacyTrackingDomains</key><array/>
    <key>NSPrivacyCollectedDataTypes</key><array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
EOF
        for category in $categories; do
            reasons=""
            for entry in "$@"; do
                [[ "${entry%%=*}" == "$category" ]] && reasons="${entry#*=}"
            done
            if [[ -z "$reasons" ]]; then
                echo "error: $name calls $(awk -v c="$category" '$1 == c { printf "%s ", $2 }' <<< "$uses")($category), and its build script gives no reason for it" >&2
                exit 1
            fi
            echo "        <dict>"
            echo "            <key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategory$category</string>"
            echo "            <key>NSPrivacyAccessedAPITypeReasons</key>"
            echo "            <array>"
            for reason in ${reasons//,/ }; do
                echo "                <string>$reason</string>"
            done
            echo "            </array>"
            echo "        </dict>"
        done
        cat <<'EOF'
    </array>
</dict>
</plist>
EOF
    } > "$output"
    plutil -lint "$output" > /dev/null || { echo "error: $output is not a property list" >&2; exit 1; }
    for category in $categories; do
        summary+="$category ($(awk -v c="$category" '$1 == c { print $2 }' <<< "$uses" | tr '\n' ' ' | sed 's/ $//')) "
    done
    echo "privacy manifest: ${summary:-no API that needs a reason}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    [[ $# -ge 1 ]] || { echo "usage: $0 <binary> ..." >&2; exit 2; }
    for binary in "$@"; do
        uses="$(privacy_uses "$binary")"
        echo "$binary: ${uses:-no API that needs a reason}" | tr '\n' ';' | sed 's/;$//'
        echo
    done
fi
