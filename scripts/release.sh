#!/bin/zsh
# Builds Record.app, zips it, and computes the SHA256. Output goes to
# ./dist/. Attach the zip to a GitHub Release; drop the printed
# "brew formula" block into the Homebrew tap's Casks/record.rb.
#
# Usage: zsh scripts/release.sh <version>
#   e.g. zsh scripts/release.sh 0.2.0

set -euo pipefail

if [[ $# -lt 1 ]]; then
    print "Usage: zsh scripts/release.sh <version>"
    print "  e.g. zsh scripts/release.sh 0.2.0"
    exit 1
fi

version="$1"
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
dist_dir="$root_dir/dist"
zip_path="$dist_dir/Record-$version.zip"

cd "$root_dir"
mkdir -p "$dist_dir"
rm -f "$zip_path"

# Build the .app.
zsh "$root_dir/scripts/build-app.sh"

# Zip it up. Use `ditto -c -k --sequesterRsrc --keepParent` because
# macOS's own tools produce a bundle Gatekeeper is happy with,
# preserving code signature + extended attributes. plain `zip` strips
# metadata and breaks the signature.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "$root_dir/Build/Record.app" \
    "$zip_path"

sha256=$(shasum -a 256 "$zip_path" | awk '{print $1}')
size=$(du -h "$zip_path" | awk '{print $1}')

print
print "=== Release artifact ==="
print "  Version: $version"
print "  File:    $zip_path"
print "  Size:    $size"
print "  SHA256:  $sha256"
print
print "=== Homebrew cask formula (Casks/record.rb) ==="
cat <<EOF

cask "record" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/charsree/record/releases/download/v#{version}/Record-#{version}.zip"
  name "Record"
  desc "Local-first macOS meeting assistant with mic, system audio, OCR, and Kiro chat"
  homepage "https://github.com/charsree/record"

  depends_on macos: ">= :sequoia"

  app "Record.app"

  zap trash: [
    "~/Library/Application Support/Record",
    "~/Library/Preferences/dev.charsree.record.plist",
  ]
end
EOF

print
print "Next steps:"
print "  1. gh release create v$version $zip_path --title \"Record $version\" --notes \"...\""
print "  2. Update charsree/homebrew-record/Casks/record.rb with the formula above."
print "  3. brew tap charsree/record && brew install --cask record"
