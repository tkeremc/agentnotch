#!/bin/sh
set -eu

source_root="${AGENTNOTCH_SOURCE_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
claude_output="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Claude"
claude_intermediates="${DERIVED_FILE_DIR:-${TARGET_TEMP_DIR:-${TMPDIR:-/tmp}}}/agentnotch-claude-bridge"
mkdir -p "$claude_output" "$claude_intermediates"
set --
for architecture in ${ARCHS:-arm64 x86_64}; do
    architecture_binary="$claude_intermediates/agentnotch-claude-hook-$architecture"
    /usr/bin/xcrun swiftc -O -target "$architecture-apple-macosx14.0" \
        -module-cache-path "$claude_intermediates/module-cache" \
        "$source_root/Native/ClaudeHookBridge.swift" -o "$architecture_binary"
    set -- "$@" "$architecture_binary"
done
/usr/bin/xcrun lipo -create "$@" -output "$claude_output/agentnotch-claude-hook"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
    "$claude_output/agentnotch-claude-hook"
