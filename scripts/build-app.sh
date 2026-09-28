#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"
derived="$repo/.build/app-derived"
app="$repo/.build/Srez.app"
mkdir -p "$repo/.build"
log="$repo/.build/app-build.log"
if ! xcodebuild -scheme Srez -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived" -configuration Release \
    SWIFT_COMPILATION_MODE=wholemodule COMPILER_INDEX_STORE_ENABLE=NO build >"$log" 2>&1; then
    tail -100 "$log"
    exit 1
fi
products="$derived/Build/Products/Release"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$products/Srez" "$app/Contents/MacOS/"
cp App/Info.plist "$app/Contents/Info.plist"
xcrun actool AppIcon.icon --compile "$app/Contents/Resources" \
    --output-format human-readable-text --app-icon AppIcon \
    --output-partial-info-plist "$repo/.build/app-icon.plist" \
    --target-device mac --minimum-deployment-target 14.0 --platform macosx
/usr/libexec/PlistBuddy -c "Merge $repo/.build/app-icon.plist" "$app/Contents/Info.plist"
rm -rf "$app/Contents/Resources/mlx-swift_Cmlx.bundle"
cp -R "$products/mlx-swift_Cmlx.bundle" "$app/Contents/Resources/"
/usr/libexec/PlistBuddy -c Clear -c "Add :modelDirectory string $repo/Models/GigaAM-v3-MLX" \
    "$app/Contents/Resources/Defaults.plist" >/dev/null
codesign --force --deep --sign - "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "Готово: $app"
