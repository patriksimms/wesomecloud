#!/usr/bin/env bash
# Renders docs/images/wesomecloud-icon-2.svg into AppHost/Assets.xcassets/AppIcon.appiconset.
# macOS app icons sit on a 1024 canvas with the artwork at 824 px plus a soft shadow,
# so the icon matches the size of Apple's own icons in the Dock. Uses the system
# QuickLook renderer, so no extra tools are needed. Re-run after changing the SVG.
set -euo pipefail

cd "$(dirname "$0")/.."

source_svg="docs/images/wesomecloud-icon-2.svg"
iconset="AppHost/Assets.xcassets/AppIcon.appiconset"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Wrap the artwork: strip the outer <svg> element and place the content scaled to 824 px.
{
  cat <<'HEAD'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="12"/>
    </filter>
  </defs>
  <rect x="100" y="110" width="824" height="824" rx="184" fill="#000000" opacity="0.3" filter="url(#shadow)"/>
  <g transform="translate(100 100) scale(0.8046875)">
HEAD
  sed -e '1d' -e '$d' "$source_svg"
  cat <<'TAIL'
  </g>
</svg>
TAIL
} > "$work/icon.svg"

mkdir -p "$iconset"
for px in 16 32 64 128 256 512 1024; do
  qlmanage -t -s "$px" -o "$work" "$work/icon.svg" >/dev/null 2>&1
  mv "$work/icon.svg.png" "$iconset/icon_${px}.png"
done

cat > "$iconset/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

cat > "AppHost/Assets.xcassets/Contents.json" <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "Wrote $iconset"
