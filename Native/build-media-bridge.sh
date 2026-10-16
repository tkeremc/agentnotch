#!/bin/sh
set -eu

# Build from repository sources; no download or third-party executable is needed.
source_root="${AGENTNOTCH_SOURCE_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
media_output="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Media"
mkdir -p "$media_output"
set --
for architecture in ${ARCHS:-arm64 x86_64}; do
    set -- "$@" -arch "$architecture"
done
/usr/bin/xcrun clang "$@" -dynamiclib -fobjc-arc -fblocks \
    -mmacosx-version-min=14.0 -framework AppKit \
    -install_name '@rpath/NowPlayingBridge.dylib' \
    "$source_root/Native/NowPlayingBridge.m" -o "$media_output/NowPlayingBridge.dylib"
/bin/cp "$source_root/Resources/Media/now-playing-bridge.pl" "$media_output/now-playing-bridge.pl"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
    "$media_output/NowPlayingBridge.dylib"
