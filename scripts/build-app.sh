#!/bin/zsh
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$root_dir/Build"
app_dir="$build_dir/Record.app"
binary_path="$root_dir/.build/release/Record"

cd "$root_dir"
swift build -c release

# Rebuild the icon if the source script is newer than the .icns.
if [[ ! -f "$root_dir/App/AppIcon.icns" \
      || "$root_dir/scripts/make-icon.swift" -nt "$root_dir/App/AppIcon.icns" ]]; then
  swift "$root_dir/scripts/make-icon.swift" >/dev/null
  iconutil -c icns "$root_dir/App/AppIcon.iconset" -o "$root_dir/App/AppIcon.icns"
fi

mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$binary_path" "$app_dir/Contents/MacOS/Record"
cp "$root_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
cp "$root_dir/App/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
# Optional bundled starter model. When absent (fresh clone) the app just
# prompts the user to pick one from Preferences → Transcription on first
# launch. Keeping this out of the repo lets us stay under GitHub's file
# size limits.
if [[ -f "$root_dir/Models/ggml-base.en.bin" ]]; then
  cp "$root_dir/Models/ggml-base.en.bin" "$app_dir/Contents/Resources/ggml-base.en.bin"
fi

# Sign preference order — only identities that let a locally-built app
# actually launch without a provisioning profile:
#   1) A user-installed "Record Local Signer" self-signed identity (from
#      scripts/setup-signing.sh) — stable, real, TCC-friendly.
#   2) A "Developer ID Application:" identity (also stable, but needs
#      notarization for Gatekeeper across users; fine on the signing Mac).
#   3) Ad-hoc — always works, but the code hash changes on every build,
#      so macOS TCC (Screen Recording, Mic, …) invalidates and re-prompts
#      on every rebuild.
#
# Apple Development certs are intentionally skipped: they require a
# matching provisioning profile embedded in the app or macOS refuses to
# launch them locally.
identity=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Record Local Signer"'; then
    identity="Record Local Signer"
elif line=$(security find-identity -v -p codesigning 2>/dev/null | grep '"Developer ID Application:' | head -1); then
    identity=$(print -r -- "$line" | sed -E 's/.*"([^"]+)".*/\1/')
fi

if [[ -n "$identity" ]]; then
    codesign --force --sign "$identity" --identifier dev.charsree.record "$app_dir"
    print "Signed with: $identity"
else
    codesign --force --sign - --identifier dev.charsree.record "$app_dir"
    print "Signed ad-hoc — expect Screen Recording / Mic prompts to re-appear on each rebuild."
    print "To make TCC grants persist, run: scripts/setup-signing.sh"
fi

print "$app_dir"
