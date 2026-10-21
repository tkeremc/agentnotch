#!/bin/sh
set -eu

source_root="${AGENTNOTCH_SOURCE_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
codex_output="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Codex"
codex_intermediates="${DERIVED_FILE_DIR:-${TARGET_TEMP_DIR:-${TMPDIR:-/tmp}}}/agentnotch-codex-bridge"
mkdir -p "$codex_output" "$codex_intermediates"
set --
for architecture in ${ARCHS:-arm64 x86_64}; do
    architecture_binary="$codex_intermediates/agentnotch-codex-hook-$architecture"
    /usr/bin/xcrun swiftc -O -target "$architecture-apple-macosx14.0" \
        -module-cache-path "$codex_intermediates/module-cache" \
        "$source_root/Native/CodexHookBridge.swift" -o "$architecture_binary"
    set -- "$@" "$architecture_binary"
done
/usr/bin/xcrun lipo -create "$@" -output "$codex_output/agentnotch-codex-hook"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
    "$codex_output/agentnotch-codex-hook"
