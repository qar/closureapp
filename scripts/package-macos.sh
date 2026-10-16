#!/usr/bin/env bash
set -euo pipefail

app_path=${1:?Usage: package-macos.sh Closure.app output-directory}
output_dir=${2:?Usage: package-macos.sh Closure.app output-directory}

if [[ ! -d "$app_path/Contents/Frameworks/Sparkle.framework" ]]; then
    echo "Sparkle.framework is missing from the app bundle" >&2
    exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)

identity=${APPLE_SIGNING_IDENTITY:--}
sign_args=(--force --sign "$identity")
if [[ "$identity" != - ]]; then
    sign_args+=(--options runtime --timestamp)
fi

framework="$app_path/Contents/Frameworks/Sparkle.framework"
codesign "${sign_args[@]}" "$framework/Versions/B/Autoupdate"
codesign "${sign_args[@]}" "$framework/Versions/B/Updater.app"
codesign "${sign_args[@]}" "$framework/Versions/B/XPCServices/Downloader.xpc"
codesign "${sign_args[@]}" "$framework/Versions/B/XPCServices/Installer.xpc"
codesign "${sign_args[@]}" "$framework"
codesign "${sign_args[@]}" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/closure-package.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

if [[ -n "${APPLE_NOTARY_APPLE_ID:-}${APPLE_NOTARY_PASSWORD:-}${APPLE_NOTARY_TEAM_ID:-}" ]]; then
    if [[ "$identity" == - || -z "${APPLE_NOTARY_APPLE_ID:-}" || -z "${APPLE_NOTARY_PASSWORD:-}" || -z "${APPLE_NOTARY_TEAM_ID:-}" ]]; then
        echo "Notarization needs a Developer ID identity and all APPLE_NOTARY_* values" >&2
        exit 1
    fi

    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$work_dir/notary.zip"
    xcrun notarytool submit "$work_dir/notary.zip" --apple-id "$APPLE_NOTARY_APPLE_ID" \
        --password "$APPLE_NOTARY_PASSWORD" --team-id "$APPLE_NOTARY_TEAM_ID" --wait
    xcrun stapler staple "$app_path"
fi

zip_path="$output_dir/Closure-$version-mac.zip"
dmg_path="$output_dir/Closure-$version-mac.dmg"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"

mkdir "$work_dir/dmg"
ditto "$app_path" "$work_dir/dmg/Closure.app"
ln -s /Applications "$work_dir/dmg/Applications"
hdiutil create -volname "Closure" -srcfolder "$work_dir/dmg" -ov -format UDZO "$dmg_path"

echo "$zip_path"
echo "$dmg_path"
