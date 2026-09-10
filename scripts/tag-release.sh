#!/bin/zsh
# One-shot release helper — LOCAL BUILD version.
#
# Homebrew's build sandbox blocks Swift Package Manager's manifest
# compilation, and GitHub Actions runners lag behind Swift 6.2, so we
# ship a PRE-BUILT Record.app as a GitHub Release asset instead. The
# Homebrew formula then just downloads the zip and copies the .app into
# place — no compilation on the user's machine, install takes seconds.
#
# Flow:
#   1. Bumps CFBundleShortVersionString + CFBundleVersion in Info.plist.
#   2. Commits and pushes the version bump.
#   3. Builds Record.app locally with your Swift 6.2 toolchain.
#   4. Zips it with ditto (preserves code signature).
#   5. Creates a git tag v<version>.
#   6. Creates a GitHub Release with the zip attached.
#   7. GitHub Actions rewrites Formula/record.rb in charsree/homebrew-tools
#      with the new url + sha256 (see .github/workflows/update-formula.yml).
#
# Usage: zsh scripts/tag-release.sh <version>
#   e.g. zsh scripts/tag-release.sh 0.3.1

set -euo pipefail

if [[ $# -lt 1 ]]; then
    print "Usage: zsh scripts/tag-release.sh <version>"
    print "  e.g. zsh scripts/tag-release.sh 0.3.1"
    exit 1
fi

version="$1"
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
dist_dir="$root_dir/dist"
zip_path="$dist_dir/Record-$version.zip"
cd "$root_dir"

if [[ -n "$(git status --porcelain)" ]]; then
    print "Working tree is dirty. Commit or stash first."
    git status --short
    exit 1
fi

# 1. Bump version strings in Info.plist.
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" App/Info.plist
current=$(/usr/bin/plutil -extract CFBundleVersion raw App/Info.plist 2>/dev/null || echo "0")
next=$((current + 1))
/usr/bin/plutil -replace CFBundleVersion -string "$next" App/Info.plist

git add App/Info.plist
git commit -m "chore: release $version"
git push origin main

# 2. Build the .app locally.
print
print "→ swift build -c release"
swift build -c release

print "→ zsh scripts/build-app.sh"
zsh "$root_dir/scripts/build-app.sh"

# 3. Zip it with ditto (preserves signature + xattrs).
mkdir -p "$dist_dir"
rm -f "$zip_path"
print "→ ditto → $zip_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "$root_dir/Build/Record.app" \
    "$zip_path"

sha256=$(shasum -a 256 "$zip_path" | awk '{print $1}')
size=$(du -h "$zip_path" | awk '{print $1}')
print "  Size:   $size"
print "  SHA256: $sha256"

# 4. Tag + create release with the zip attached. The
#    update-formula workflow will pick this up and rewrite the tap.
git tag -a "v$version" -m "Release $version"
git push origin "v$version"

gh release create "v$version" \
    "$zip_path" \
    --title "Record $version" \
    --generate-notes

print
print "✅ Released v$version:"
print "   Release: https://github.com/charsree/record/releases/tag/v$version"
print "   Zip:     $zip_path"
print
print "GitHub Actions is now rewriting Formula/record.rb in charsree/homebrew-tools."
print "Once the run finishes:  brew update && brew upgrade record"
