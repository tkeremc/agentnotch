#!/bin/sh
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
xcrun swiftc -parse-as-library -module-cache-path "$visual_root/module-cache" \
    "$source_root/Sources/Localization/AppLocalization.swift" \
    "$source_root/Sources/Localization/L10nKey.swift" \
    "$source_root/Sources/Features/Settings/NotchSettings.swift" \
    "$source_root/Sources/Features/Widgets/Models/WidgetKind.swift" \
    "$source_root/Sources/Features/Widgets/Models/WidgetDescriptor.swift" \
    "$source_root/Sources/Features/Widgets/Codex/"*.swift \
    "$source_root/Research/CodexReadOnly/RenderCodex.swift" \
    -o "$bundle/Contents/MacOS/preview"
"$bundle/Contents/MacOS/preview" "$visual_root/images"
