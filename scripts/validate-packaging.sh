#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

require_generated=false
configuration=Debug
for argument in "$@"; do
  case "$argument" in
    --require-generated)
      require_generated=true
      ;;
    --release)
      configuration=Release
      ;;
    *)
      echo "Unknown argument: $argument" >&2
      exit 64
      ;;
  esac
done

require_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "Expected $file to contain: $needle" >&2
    exit 1
  fi
}

require_absent() {
  local file="$1"
  local needle="$2"
  if grep -Fq "$needle" "$file"; then
    echo "Expected $file not to contain production-blocking value: $needle" >&2
    exit 1
  fi
}

require_contains Package.swift '.library(name: "WesomeCloudMacApp", targets: ["WesomeCloudMacApp"])'
require_contains Package.swift '.library(name: "WesomeFileProviderExtension", targets: ["WesomeFileProviderExtension"])'
require_contains project.yml 'product: WesomeCloudMacApp'
require_contains project.yml 'product: WesomeFileProviderExtension'
require_contains project.yml 'target: WesomeFileProviderExtensionHost'
require_contains project.yml 'embed: true'
require_contains project.yml 'PRODUCT_BUNDLE_IDENTIFIER: cloud.wesome.wesomecloud'
require_contains project.yml 'PRODUCT_BUNDLE_IDENTIFIER: cloud.wesome.wesomecloud.fileprovider'
require_contains AppHost/WesomeCloud.entitlements '$(TeamIdentifierPrefix)cloud.wesome.wesomecloud'
require_contains AppHost/WesomeFileProviderExtension.entitlements '$(TeamIdentifierPrefix)cloud.wesome.wesomecloud'
require_contains AppHost/WesomeCloud.entitlements 'com.apple.security.app-sandbox'
require_contains AppHost/WesomeFileProviderExtension.entitlements 'com.apple.security.app-sandbox'
require_contains AppHost/WesomeCloud.entitlements 'com.apple.security.network.client'
require_contains AppHost/WesomeCloud.entitlements 'com.apple.security.network.server'
require_contains AppHost/WesomeFileProviderExtension.entitlements 'com.apple.security.network.client'
require_absent AppHost/WesomeFileProviderExtension.entitlements 'com.apple.developer.fileprovider.testing-mode'
require_contains AppHost/WesomeFileProviderExtension-Info.plist 'com.apple.fileprovider-nonui'
require_contains AppHost/WesomeFileProviderExtension-Info.plist '$(PRODUCT_MODULE_NAME).FileProviderExtension'
require_contains AppHost/Info.plist '<key>CFBundleVersion</key>'
require_contains AppHost/WesomeFileProviderExtension-Info.plist '<key>CFBundleVersion</key>'
require_contains AppHost/Info.plist '<key>CFBundleIdentifier</key>'
require_contains AppHost/WesomeFileProviderExtension-Info.plist '<key>CFBundleIdentifier</key>'
require_contains AppHost/Info.plist '<key>CFBundleShortVersionString</key>'
require_contains AppHost/WesomeFileProviderExtension-Info.plist '<key>CFBundleShortVersionString</key>'
require_contains AppHost/Info.plist '<key>LSMinimumSystemVersion</key>'
require_contains AppHost/WesomeFileProviderExtension-Info.plist '<key>LSMinimumSystemVersion</key>'
require_contains project.yml 'MACOSX_DEPLOYMENT_TARGET: "15.0"'

app_bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' AppHost/Info.plist)"
extension_bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' AppHost/WesomeFileProviderExtension-Info.plist)"
if [[ "$app_bundle_version" != "$extension_bundle_version" ]]; then
  echo "Expected app and extension CFBundleVersion values to match." >&2
  exit 1
fi

app_short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AppHost/Info.plist)"
extension_short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AppHost/WesomeFileProviderExtension-Info.plist)"
if [[ "$app_short_version" != "$extension_short_version" ]]; then
  echo "Expected app and extension CFBundleShortVersionString values to match." >&2
  exit 1
fi

app_minimum_system_version="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' AppHost/Info.plist)"
extension_minimum_system_version="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' AppHost/WesomeFileProviderExtension-Info.plist)"
if [[ "$app_minimum_system_version" != "$extension_minimum_system_version" ]]; then
  echo "Expected app and extension LSMinimumSystemVersion values to match." >&2
  exit 1
fi
if [[ "$app_minimum_system_version" != "15.0" ]]; then
  echo "Expected LSMinimumSystemVersion to match MACOSX_DEPLOYMENT_TARGET 15.0." >&2
  exit 1
fi

if [[ -d WesomeCloud.xcodeproj ]]; then
  xcodebuild \
    -project WesomeCloud.xcodeproj \
    -scheme WesomeCloud \
    -configuration "$configuration" \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    build
else
  echo "WesomeCloud.xcodeproj is not present; run scripts/generate-xcode-project.sh after installing xcodegen to validate the generated app bundle." >&2
  if [[ "$require_generated" == true ]]; then
    exit 2
  fi
fi
