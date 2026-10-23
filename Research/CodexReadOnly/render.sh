#!/bin/bash
set -eu
source_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
visual_root="${1:?Supply an output directory for the visual QA bundle}"
bundle="$visual_root/CodexPreview.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>preview</string>
<key>CFBundleIdentifier</key><string>com.agentnotch.CodexVisual</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun xcstringstool compile "$source_root/Resources/Localizable.xcstrings" \
    --output-directory "$bundle/Contents/Resources"
xcrun actool "$source_root/Resources/Assets.xcassets" --platform macosx \
    --minimum-deployment-target 14.0 --compile "$bundle/Contents/Resources"
production_sources=()
while IFS= read -r -d '' source_file; do
    case "$source_file" in
        */NotchSettingsView.swift|*/AppDelegate.swift|*/AgentNotchApp.swift) continue ;;
    esac
    production_sources+=("$source_file")
done < <(find "$source_root/Sources" -type f -name '*.swift' -print0)
xcrun swiftc -parse-as-library -module-cache-path "$visual_root/module-cache" \
    "${production_sources[@]}" \
    "$source_root/Research/CodexReadOnly/RenderCodex.swift" \
    -o "$bundle/Contents/MacOS/preview"
"$bundle/Contents/MacOS/preview" "$visual_root/images"
