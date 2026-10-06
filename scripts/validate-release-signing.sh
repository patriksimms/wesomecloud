#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

archive=false
manual_updates=false
for argument in "$@"; do
  case "$argument" in
    --archive)
      archive=true
      ;;
    --manual-updates)
      manual_updates=true
      ;;
    *)
      echo "Unknown argument: $argument" >&2
      exit 64
      ;;
  esac
done

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required release setting: $name" >&2
    exit 2
  fi
}

reject_placeholder() {
  local name="$1"
  local value="$2"
  shift 2
  local placeholder
  for placeholder in "$@"; do
    if [[ "$value" == *"$placeholder"* ]]; then
      echo "Release setting $name still contains placeholder value: $placeholder" >&2
      exit 2
    fi
  done
}

require_team_id() {
  local value="$1"
  if [[ ! "$value" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "WESOME_CLOUD_DEVELOPMENT_TEAM must be a 10-character Apple team ID." >&2
    exit 2
  fi
}

require_developer_id_identity() {
  local identity="$1"
  local team_id="$2"
  if [[ "$identity" != Developer\ ID\ Application:* ]]; then
    echo "WESOME_CLOUD_SIGNING_IDENTITY must be a Developer ID Application identity." >&2
    exit 2
  fi
  if [[ "$identity" != *"($team_id)"* ]]; then
    echo "WESOME_CLOUD_SIGNING_IDENTITY must include the configured team ID ($team_id)." >&2
    exit 2
  fi
}

require_https_url() {
  local name="$1"
  local value="$2"
  if [[ "$value" != https://* ]]; then
    echo "$name must use an https:// URL." >&2
    exit 2
  fi
}

require_sparkle_public_key() {
  local value="$1"
  local decoded_length
  if ! decoded_length="$(printf '%s' "$value" | /usr/bin/base64 -D 2>/dev/null | wc -c | tr -d ' ')"; then
    echo "WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY must be valid base64." >&2
    exit 2
  fi
  if [[ "$decoded_length" != "32" ]]; then
    echo "WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY must decode to a 32-byte Ed25519 public key." >&2
    exit 2
  fi
}

require_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "Expected $file to contain: $needle" >&2
    exit 1
  fi
}

require_path() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "Expected release artifact path to exist: $path" >&2
    exit 2
  fi
}

require_nonempty_file() {
  local path="$1"
  if [[ ! -s "$path" ]]; then
    echo "Expected release artifact file to exist and be non-empty: $path" >&2
    exit 2
  fi
}

require_zip_contains_app() {
  local zip="$1"
  if ! /usr/bin/unzip -Z -1 "$zip" | grep -F "WesomeCloud.app/Contents/MacOS/WesomeCloud" >/dev/null; then
    echo "Expected distribution archive to contain WesomeCloud.app executable." >&2
    exit 2
  fi
}

require_plist_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected $plist:$key to be '$expected' but found '$actual'." >&2
    exit 2
  fi
}

require_file_provider_extension() {
  local app="$1"
  local extension="$app/Contents/PlugIns/WesomeFileProviderExtension.appex"
  require_path "$extension"
  require_plist_value "$extension/Contents/Info.plist" CFBundleIdentifier "cloud.wesome.wesomecloud.fileprovider"
  require_plist_value "$extension/Contents/Info.plist" NSExtension:NSExtensionPointIdentifier "com.apple.fileprovider-nonui"
  require_plist_value "$extension/Contents/Info.plist" NSExtension:NSExtensionFileProviderDocumentGroup "$WESOME_CLOUD_DEVELOPMENT_TEAM.cloud.wesome.wesomecloud"
}

require_release_bundle_metadata() {
  local app="$1"
  local extension="$app/Contents/PlugIns/WesomeFileProviderExtension.appex"
  require_plist_value "$app/Contents/Info.plist" CFBundleIdentifier "cloud.wesome.wesomecloud"
  require_plist_value "$app/Contents/Info.plist" CFBundleExecutable "WesomeCloud"
  require_plist_value "$app/Contents/Info.plist" CFBundlePackageType "APPL"
  require_plist_value "$extension/Contents/Info.plist" CFBundleExecutable "WesomeFileProviderExtension"
  require_plist_value "$extension/Contents/Info.plist" CFBundlePackageType "XPC!"
  require_plist_value "$app/Contents/Info.plist" CFBundleShortVersionString "$release_version"
  require_plist_value "$app/Contents/Info.plist" CFBundleVersion "$release_build"
  require_plist_value "$app/Contents/Info.plist" LSMinimumSystemVersion "15.0"
  require_plist_value "$extension/Contents/Info.plist" CFBundleShortVersionString "$release_version"
  require_plist_value "$extension/Contents/Info.plist" CFBundleVersion "$release_build"
  require_plist_value "$extension/Contents/Info.plist" LSMinimumSystemVersion "15.0"
  require_path "$app/Contents/Resources/LICENSE"
  require_path "$app/Contents/Resources/NOTICE"
  require_path "$app/Contents/Resources/Sparkle-LICENSE.txt"
}

require_sparkle_framework() {
  local app="$1"
  require_path "$app/Contents/Frameworks/Sparkle.framework"
}

require_signed_entitlements() {
  local bundle="$1"
  local require_keychain="${2:-false}"
  local require_listener="${3:-false}"
  local entitlements
  entitlements="$(mktemp "${TMPDIR:-/tmp}/wesome-entitlements.XXXXXX.plist")"
  codesign -d --entitlements :- "$bundle" > "$entitlements" 2>/dev/null
  require_plist_value "$entitlements" com.apple.security.app-sandbox "true"
  require_plist_value "$entitlements" com.apple.security.network.client "true"
  if [[ "$require_listener" == true ]]; then
    require_plist_value "$entitlements" com.apple.security.network.server "true"
    require_plist_value "$entitlements" com.apple.security.temporary-exception.mach-lookup.global-name:0 "cloud.wesome.wesomecloud-spks"
    require_plist_value "$entitlements" com.apple.security.temporary-exception.mach-lookup.global-name:1 "cloud.wesome.wesomecloud-spki"
  fi
  if ! /usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$entitlements" | grep -Fq "$WESOME_CLOUD_DEVELOPMENT_TEAM.cloud.wesome.wesomecloud"; then
    echo "Expected signed entitlements for $bundle to include $WESOME_CLOUD_DEVELOPMENT_TEAM.cloud.wesome.wesomecloud." >&2
    rm -f "$entitlements"
    exit 2
  fi
  if [[ "$require_keychain" == true ]] && ! /usr/libexec/PlistBuddy -c "Print :keychain-access-groups" "$entitlements" | grep -Fq "$WESOME_CLOUD_DEVELOPMENT_TEAM.cloud.wesome.wesomecloud"; then
    echo "Expected signed entitlements for $bundle to include $WESOME_CLOUD_DEVELOPMENT_TEAM.cloud.wesome.wesomecloud." >&2
    rm -f "$entitlements"
    exit 2
  fi
  rm -f "$entitlements"
}

require_env WESOME_CLOUD_DEVELOPMENT_TEAM
require_env WESOME_CLOUD_SIGNING_IDENTITY
require_env WESOME_CLOUD_NOTARY_PROFILE
if [[ "$manual_updates" == true ]]; then
  WESOME_CLOUD_APPCAST_URL=""
  WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY=""
else
  require_env WESOME_CLOUD_APPCAST_URL
  require_env WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY
fi

reject_placeholder WESOME_CLOUD_DEVELOPMENT_TEAM "$WESOME_CLOUD_DEVELOPMENT_TEAM" YOURTEAMID TEAMID
reject_placeholder WESOME_CLOUD_SIGNING_IDENTITY "$WESOME_CLOUD_SIGNING_IDENTITY" Example YOURTEAMID TEAMID
reject_placeholder WESOME_CLOUD_NOTARY_PROFILE "$WESOME_CLOUD_NOTARY_PROFILE" example placeholder
if [[ "$manual_updates" == false ]]; then
  reject_placeholder WESOME_CLOUD_APPCAST_URL "$WESOME_CLOUD_APPCAST_URL" example.com updates.example.com
  reject_placeholder WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY "$WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY" base64-ed25519-public-key placeholder
  require_https_url WESOME_CLOUD_APPCAST_URL "$WESOME_CLOUD_APPCAST_URL"
  require_sparkle_public_key "$WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY"
fi
require_team_id "$WESOME_CLOUD_DEVELOPMENT_TEAM"
require_developer_id_identity "$WESOME_CLOUD_SIGNING_IDENTITY" "$WESOME_CLOUD_DEVELOPMENT_TEAM"

require_contains project.yml "CODE_SIGN_STYLE: Automatic"
require_contains project.yml "PRODUCT_BUNDLE_IDENTIFIER: cloud.wesome.wesomecloud"
require_contains project.yml "PRODUCT_BUNDLE_IDENTIFIER: cloud.wesome.wesomecloud.fileprovider"
require_contains project.yml "product: Sparkle"
require_contains AppHost/WesomeCloud.entitlements "com.apple.security.app-sandbox"
require_contains AppHost/WesomeFileProviderExtension.entitlements "com.apple.security.app-sandbox"
require_contains AppHost/WesomeCloud.entitlements "com.apple.security.network.client"
require_contains AppHost/WesomeCloud.entitlements "com.apple.security.network.server"
require_contains AppHost/WesomeFileProviderExtension.entitlements "com.apple.security.network.client"
require_contains AppHost/WesomeCloud.entitlements '$(TeamIdentifierPrefix)cloud.wesome.wesomecloud'
require_contains AppHost/WesomeFileProviderExtension.entitlements '$(TeamIdentifierPrefix)cloud.wesome.wesomecloud'
require_contains AppHost/Info.plist "SUFeedURL"
require_contains AppHost/Info.plist "SUPublicEDKey"

release_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AppHost/Info.plist)"
release_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' AppHost/Info.plist)"

if ! xcrun notarytool history --keychain-profile "$WESOME_CLOUD_NOTARY_PROFILE" >/dev/null; then
  echo "Could not validate notarytool profile: $WESOME_CLOUD_NOTARY_PROFILE" >&2
  exit 3
fi

if [[ "$archive" == false ]]; then
  echo "Release signing configuration is present. Pass --archive to build a signed archive."
  exit 0
fi

if [[ ! -d WesomeCloud.xcodeproj ]]; then
  echo "WesomeCloud.xcodeproj is not present; run scripts/generate-xcode-project.sh first." >&2
  exit 2
fi

archive_path="${WESOME_CLOUD_ARCHIVE_PATH:-$PWD/build/WesomeCloud.xcarchive}"
export_path="${WESOME_CLOUD_EXPORT_PATH:-$PWD/build/export}"
export_options_path="${WESOME_CLOUD_EXPORT_OPTIONS_PATH:-$PWD/build/ExportOptions.plist}"
updates_path="${WESOME_CLOUD_UPDATES_PATH:-$PWD/build/updates}"
zip_path="${WESOME_CLOUD_ZIP_PATH:-$updates_path/WesomeCloud-$release_version.zip}"
mkdir -p "$(dirname "$archive_path")"
mkdir -p "$export_path"
mkdir -p "$(dirname "$zip_path")"

if [[ "$manual_updates" == false ]]; then
  swift package resolve
  sparkle_bin="$PWD/.build/artifacts/sparkle/Sparkle/bin"
  sparkle_account="${WESOME_CLOUD_SPARKLE_ACCOUNT:-cloud.wesome.wesomecloud}"
  keychain_public_key="$("$sparkle_bin/generate_keys" --account "$sparkle_account" -p)"
  if [[ "$keychain_public_key" != "$WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY" ]]; then
    echo "The configured Sparkle public key does not match the signing key in Keychain." >&2
    exit 2
  fi
  download_url_prefix="${WESOME_CLOUD_DOWNLOAD_URL_PREFIX:-https://github.com/patriksimms/wesomecloud/releases/download/v$release_version/}"
  require_https_url WESOME_CLOUD_DOWNLOAD_URL_PREFIX "$download_url_prefix"
fi

sed "s/\$(WESOME_CLOUD_DEVELOPMENT_TEAM)/$WESOME_CLOUD_DEVELOPMENT_TEAM/g" \
  AppHost/ExportOptions.plist > "$export_options_path"
/usr/libexec/PlistBuddy -c "Add :signingCertificate string $WESOME_CLOUD_SIGNING_IDENTITY" "$export_options_path"

xcodebuild \
  -project WesomeCloud.xcodeproj \
  -scheme WesomeCloud \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -allowProvisioningUpdates \
  ENABLE_HARDENED_RUNTIME=YES \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS=arm64 \
  DEVELOPMENT_TEAM="$WESOME_CLOUD_DEVELOPMENT_TEAM" \
  CODE_SIGN_IDENTITY="Apple Development" \
  WESOME_CLOUD_APPCAST_URL="$WESOME_CLOUD_APPCAST_URL" \
  WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY="$WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY" \
  CODE_SIGNING_ALLOWED=YES \
  archive \
  -archivePath "$archive_path"

app_path="$archive_path/Products/Applications/WesomeCloud.app"
require_release_bundle_metadata "$app_path"
require_plist_value "$app_path/Contents/Info.plist" SUFeedURL "$WESOME_CLOUD_APPCAST_URL"
require_plist_value "$app_path/Contents/Info.plist" SUPublicEDKey "$WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY"
require_file_provider_extension "$app_path"
require_sparkle_framework "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
require_signed_entitlements "$app_path" true true
require_signed_entitlements "$app_path/Contents/PlugIns/WesomeFileProviderExtension.appex" true

xcodebuild \
  -exportArchive \
  -allowProvisioningUpdates \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options_path"

exported_app="$export_path/WesomeCloud.app"
require_release_bundle_metadata "$exported_app"
require_plist_value "$exported_app/Contents/Info.plist" SUFeedURL "$WESOME_CLOUD_APPCAST_URL"
require_plist_value "$exported_app/Contents/Info.plist" SUPublicEDKey "$WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY"
require_plist_value "$exported_app/Contents/Info.plist" SUEnableInstallerLauncherService "true"
require_plist_value "$exported_app/Contents/Info.plist" SURequireSignedFeed "true"
require_file_provider_extension "$exported_app"
require_sparkle_framework "$exported_app"
codesign --verify --deep --strict --verbose=2 "$exported_app"
for binary in "$exported_app/Contents/MacOS/WesomeCloud" "$exported_app/Contents/PlugIns/WesomeFileProviderExtension.appex/Contents/MacOS/WesomeFileProviderExtension"; do
  architectures="$(lipo -archs "$binary")"
  if [[ "$architectures" != "arm64" ]]; then
    echo "Expected only Apple Silicon code in $binary" >&2
    exit 2
  fi
done
require_signed_entitlements "$exported_app" true true
require_signed_entitlements "$exported_app/Contents/PlugIns/WesomeFileProviderExtension.appex" true
/usr/bin/ditto -c -k --keepParent "$exported_app" "$zip_path"
require_nonempty_file "$zip_path"
require_zip_contains_app "$zip_path"

# Staple the app before creating the DMG so copied apps carry their own ticket.
xcrun notarytool submit "$zip_path" \
  --keychain-profile "$WESOME_CLOUD_NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$exported_app"
xcrun stapler validate "$exported_app"
spctl --assess --type execute --verbose=2 "$exported_app"

dmg_path="${WESOME_CLOUD_DMG_PATH:-$PWD/build/WesomeCloud-$release_version.dmg}"
staging="$(mktemp -d "${TMPDIR:-/tmp}/wesome-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto "$exported_app" "$staging/WesomeCloud.app"
ln -s /Applications "$staging/Applications"
mkdir -p "$(dirname "$dmg_path")"
hdiutil create -volname "WesomeCloud" -srcfolder "$staging" -format UDZO -ov "$dmg_path"
codesign --sign "$WESOME_CLOUD_SIGNING_IDENTITY" --timestamp "$dmg_path"
codesign --verify --verbose=2 "$dmg_path"
xcrun notarytool submit "$dmg_path" \
  --keychain-profile "$WESOME_CLOUD_NOTARY_PROFILE" \
  --wait

xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"
/usr/bin/ditto -c -k --keepParent "$exported_app" "$zip_path"
require_nonempty_file "$zip_path"
require_zip_contains_app "$zip_path"
if [[ "$manual_updates" == false ]]; then
  mkdir -p "$updates_path"
  if [[ "$(dirname "$zip_path")" != "$updates_path" ]]; then
    echo "WESOME_CLOUD_ZIP_PATH must be inside WESOME_CLOUD_UPDATES_PATH for appcast generation." >&2
    exit 2
  fi
  appcast_path="$updates_path/appcast.xml"
  # Sign the final ZIP after stapling. Preparing a release never needs a live feed.
  "$sparkle_bin/generate_appcast" --account "$sparkle_account" \
    --download-url-prefix "$download_url_prefix" \
    --versions "$release_build" --maximum-deltas 0 \
    -o "$appcast_path" "$updates_path"
  "$sparkle_bin/sign_update" --account "$sparkle_account" --verify "$appcast_path"
  zip_length="$(wc -c < "$zip_path" | tr -d ' ')"
  swift run wesomecloud validate-appcast "$appcast_path" --version "$release_version" --build "$release_build" --download-length "$zip_length"
  zip_signature="$(/usr/bin/xmllint --xpath "string(/rss/channel/item[*[local-name()='version']='$release_build']/enclosure/@*[local-name()='edSignature'])" "$appcast_path")"
  "$sparkle_bin/sign_update" --account "$sparkle_account" --verify "$zip_path" "$zip_signature"
  echo "Locally prepared appcast: $appcast_path"
fi

echo "Signed and notarized app validated at $exported_app"
echo "Distribution archive: $zip_path"
echo "Disk image: $dmg_path"
