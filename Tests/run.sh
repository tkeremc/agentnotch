#!/bin/bash
set -euo pipefail

source_root="$(cd "$(dirname "$0")/.." && pwd)"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/agentnotch-widget-tests.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
architecture="$(uname -m)"
target="${architecture}-apple-macosx14.0"
mkdir -p "$test_build/module-cache" "$test_build/Localization.bundle"

# Exercise the shipping String Catalog through real compiled .lproj resources.
xcrun xcstringstool compile "$source_root/Resources/Localizable.xcstrings" \
    --output-directory "$test_build/Localization.bundle"
cat > "$test_build/Localization.bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.agentnotch.localization-tests</string>
    <key>CFBundleName</key><string>Localization</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
</dict></plist>
PLIST

# Exercise native metadata serialization without opening a media session.
xcrun clang -fobjc-arc -fblocks -framework AppKit -mmacosx-version-min=14.0 \
    "$source_root/Tests/NowPlayingBridgeTests.m" -o "$test_build/NowPlayingBridgeTests"
"$test_build/NowPlayingBridgeTests"

# Build and exercise the exact helper shipped by Xcode, in an isolated folder.
AGENTNOTCH_SOURCE_ROOT="$source_root" TARGET_BUILD_DIR="$test_build" \
UNLOCALIZED_RESOURCES_FOLDER_PATH="Resources" DERIVED_FILE_DIR="$test_build/Derived" \
ARCHS="$architecture" /bin/sh "$source_root/Native/build-codex-bridge.sh"
python3 -B "$source_root/Tests/CodexHookBridgeTests.py" \
    "$test_build/Resources/Codex/agentnotch-codex-hook"

# Component scope validates Codex and the notch views without launching the
# settings macro compiler or unrelated desktop/pasteboard tests.
test_scope="${AGENTNOTCH_TEST_SCOPE:-all}"
production_sources=()
while IFS= read -r -d '' source_file; do
    if [ "$test_scope" = "codex" ]; then
        case "$source_file" in
            */NotchSettingsView.swift|*/AppDelegate.swift|*/AgentNotchApp.swift) continue ;;
        esac
    fi
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

test_sources=("$source_root/Tests/"*.swift)
if [ "$test_scope" = "codex" ]; then
    cat > "$test_build/CodexTestsMain.swift" <<'SWIFT'
import Foundation
import Darwin
@testable import AgentNotch
@main @MainActor struct CodexTestsMain {
    static func main() {
        let cases = CodexActivityTests.cases + CodexUsageTests.cases
            + CodexHookInstallerTests.cases + CodexStoreTests.cases + LocalizationTests.cases
        var failures = 0
        for (name, test) in cases {
            do { try test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("\(cases.count - failures)/\(cases.count) tests passed")
        if failures > 0 { exit(1) }
    }
}
SWIFT
    test_sources=("$source_root/Tests/CodexActivityTests.swift" "$source_root/Tests/CodexUsageTests.swift"
        "$source_root/Tests/CodexHookInstallerTests.swift" "$source_root/Tests/CodexStoreTests.swift"
        "$source_root/Tests/LocalizationTests.swift" "$test_build/CodexTestsMain.swift")
fi

xcrun swiftc -parse-as-library -sdk "$sdk_path" -target "$target" \
    -module-cache-path "$test_build/module-cache" \
    -I "$test_build" -L "$test_build" -lAgentNotch \
    -Xlinker -rpath -Xlinker "$test_build" \
    "${test_sources[@]}" -o "$test_build/WidgetTests"

AGENTNOTCH_TEST_LOCALIZATION_BUNDLE="$test_build/Localization.bundle" \
AGENTNOTCH_TEST_LOCALIZATION_CATALOG="$source_root/Resources/Localizable.xcstrings" \
AGENTNOTCH_TEST_CODEX_HELPER="$test_build/Resources/Codex/agentnotch-codex-hook" \
    "$test_build/WidgetTests"
