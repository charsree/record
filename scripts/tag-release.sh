#!/bin/zsh
# One-shot release helper. Bumps the version in Info.plist, commits,
# tags, and pushes. GitHub Actions handles the rest (auto-updates the
# Homebrew tap formula).
#
# Usage: zsh scripts/tag-release.sh <version>
#   e.g. zsh scripts/tag-release.sh 0.3.0

set -euo pipefail

if [[ $# -lt 1 ]]; then
    print "Usage: zsh scripts/tag-release.sh <version>"
    print "  e.g. zsh scripts/tag-release.sh 0.3.0"
    exit 1
fi

version="$1"
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root_dir"

if [[ -n "$(git status --porcelain)" ]]; then
    print "Working tree is dirty. Commit or stash first."
    git status --short
    exit 1
fi

# Bump CFBundleShortVersionString in Info.plist so About and Preferences
# reflect the new version.
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" App/Info.plist

# Auto-increment CFBundleVersion so Sparkle-style updaters don't get confused.
current=$(/usr/bin/plutil -extract CFBundleVersion raw App/Info.plist 2>/dev/null || echo "0")
next=$((current + 1))
/usr/bin/plutil -replace CFBundleVersion -string "$next" App/Info.plist

git add App/Info.plist
git commit -m "chore: release $version"
git tag -a "v$version" -m "Release $version"
git push origin main
git push origin "v$version"

print
print "✅ Tag v$version pushed."
print "GitHub Actions is now:"
print "  • updating charsree/homebrew-tools/Formula/record.rb"
print
print "Watch the run at: https://github.com/charsree/record/actions"
print
print "Once green:  brew update && brew upgrade record"
