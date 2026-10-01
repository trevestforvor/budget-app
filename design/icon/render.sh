#!/usr/bin/env bash
# Renders the app icon from its SVGs and installs it everywhere it's used.
#   design/icon/render.sh
# Sources: icon-any.svg (full color), icon-dark.svg (iOS dark mode), icon-tinted.svg (grayscale; iOS tints it).
# concept-A/B/C.svg are the three original concepts (A was chosen).
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for v in icon-any icon-dark icon-tinted; do
  printf '<html><body style="margin:0;overflow:hidden">%s</body></html>' "$(cat $v.svg)" > $v.html
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1024,1024 --screenshot="$PWD/$v-rgba.png" "file://$PWD/$v.html" 2>/dev/null
done
swift flatten.swift icon-any-rgba.png icon-dark-rgba.png icon-tinted-rgba.png   # the App Store rejects an alpha channel
rm -f ./*-rgba.png
cp icon-any.png icon-dark.png icon-tinted.png ../../App/Assets.xcassets/AppIcon.appiconset/
sips -Z 180 icon-any.png --out touch-180.png >/dev/null   # dashboard apple-touch-icon (embedded in Dashboard.swift)
sips -Z 64 icon-any.png --out favicon-64.png >/dev/null   # dashboard favicon (embedded in Dashboard.swift)
sips -Z 256 icon-any.png --out olares-256.png >/dev/null  # the Olares Market tile, if you publish the server as an Olares app
echo "Installed the app icon. Re-embed touch/favicon in Dashboard.swift (and update your Olares tile) if they changed."
