#!/bin/bash
set -euo pipefail

source_root="$(cd "$(dirname "$0")/.." && pwd)"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/agentnotch-widget-tests.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
architecture="$(uname -m)"
target="${architecture}-apple-macosx14.0"
mkdir -p "$test_build/module-cache"

production_sources=()
while IFS= read -r -d '' source_file; do
    production_sources+=("$source_file")
done < <(find "$source_root/Sources" -type f -name '*.swift' -print0)
if [ "${#production_sources[@]}" -eq 0 ]; then
    echo "No production Swift files found in Sources." >&2
    exit 1
fi

# Compile the actual app into an importable module. Its app entry point is not
# invoked: the executable below supplies the test runner's own entry point.
xcrun swiftc -parse-as-library -emit-library -emit-module -enable-testing \
    -module-name AgentNotch -sdk "$sdk_path" -target "$target" \
    -module-cache-path "$test_build/module-cache" \
    -emit-module-path "$test_build/AgentNotch.swiftmodule" \
    -Xlinker -install_name -Xlinker @rpath/libAgentNotch.dylib \
    "${production_sources[@]}" \
    -o "$test_build/libAgentNotch.dylib"

xcrun swiftc -parse-as-library -sdk "$sdk_path" -target "$target" \
    -module-cache-path "$test_build/module-cache" \
    -I "$test_build" -L "$test_build" -lAgentNotch \
    -Xlinker -rpath -Xlinker "$test_build" \
    "$source_root/Tests/"*.swift -o "$test_build/WidgetTests"

"$test_build/WidgetTests"
