#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"
derived="$repo/.build/app-derived"
app="$repo/.build/Srez.app"
mkdir -p "$repo/.build"
bash scripts/build-ffmpeg.sh
log="$repo/.build/app-build.log"
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
minimum_version=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" App/Info.plist)
if ! xcodebuild -scheme Srez -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived" -configuration Release \
    OTHER_LDFLAGS="\$(inherited) -Xlinker -platform_version -Xlinker macos -Xlinker $minimum_version -Xlinker $sdk_version" \
    SWIFT_COMPILATION_MODE=wholemodule COMPILER_INDEX_STORE_ENABLE=NO build >"$log" 2>&1; then
    tail -100 "$log"
    exit 1
fi
products="$derived/Build/Products/Release"
actual_sdk=$(xcrun vtool -show-build "$products/Srez" | awk '$1 == "sdk" { print $2 }')
if [[ "$actual_sdk" != "$sdk_version" ]]; then
    echo "Неверная версия SDK в бинарнике: $actual_sdk (ожидалась $sdk_version)." >&2
    exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$products/Srez" "$app/Contents/MacOS/"
cp "$repo/.build/ffmpeg/ffmpeg" "$app/Contents/MacOS/"
codesign --force --sign - "$app/Contents/MacOS/ffmpeg"
cp App/Info.plist "$app/Contents/Info.plist"
xcrun actool Assets/AppIcon.icon --compile "$app/Contents/Resources" \
    --output-format human-readable-text --app-icon AppIcon \
    --output-partial-info-plist "$repo/.build/app-icon.plist" \
    --target-device mac --minimum-deployment-target 14.0 --platform macosx
/usr/libexec/PlistBuddy -c "Merge $repo/.build/app-icon.plist" "$app/Contents/Info.plist"
rm -rf "$app/Contents/Resources/mlx-swift_Cmlx.bundle"
cp -R "$products/mlx-swift_Cmlx.bundle" "$app/Contents/Resources/"
rm -rf "$app/Contents/Resources/Srez_Srez.bundle"
cp -R "$products/Srez_Srez.bundle" "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/FFmpeg"
cp "$repo/.build/ffmpeg/source.tar.xz" "$repo/.build/ffmpeg/configure.sh" \
    "$repo/.build/ffmpeg/source/COPYING.LGPLv2.1" "$repo/.build/ffmpeg/source/LICENSE.md" \
    ThirdParty/FFmpeg/README.md "$app/Contents/Resources/FFmpeg/"
rm -f "$app/Contents/Resources/Defaults.plist"
codesign --force --deep --sign - "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "Готово: $app"
