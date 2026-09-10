#!/bin/zsh
# Builds Record.app with all non-system dylibs bundled into
# Contents/Frameworks. The resulting bundle runs on any Apple Silicon
# Mac (macOS 26+) without needing whisper-cpp / ggml installed.
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$root_dir/Build"
app_dir="$build_dir/Record.app"
binary_path="$root_dir/.build/release/Record"
frameworks_dir="$app_dir/Contents/Frameworks"
executable="$app_dir/Contents/MacOS/Record"

cd "$root_dir"

# `--disable-sandbox` lets swift build work inside Homebrew's install
# sandbox. No-op locally.
swift build -c release --disable-sandbox

# Rebuild the icon if the source script is newer than the .icns.
if [[ ! -f "$root_dir/App/AppIcon.icns" \
      || "$root_dir/scripts/make-icon.swift" -nt "$root_dir/App/AppIcon.icns" ]]; then
  swift "$root_dir/scripts/make-icon.swift" >/dev/null
  iconutil -c icns "$root_dir/App/AppIcon.iconset" -o "$root_dir/App/AppIcon.icns"
fi

# Fresh app bundle each time.
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
mkdir -p "$frameworks_dir"

cp "$binary_path" "$executable"
cp "$root_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
cp "$root_dir/App/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
if [[ -f "$root_dir/Models/ggml-base.en.bin" ]]; then
  cp "$root_dir/Models/ggml-base.en.bin" "$app_dir/Contents/Resources/ggml-base.en.bin"
fi

# ----------------------------------------------------------------------
# Bundle third-party dylibs into Contents/Frameworks and rewrite the
# executable's load paths so it uses the bundled copies instead of
# whatever's in /opt/homebrew.
# ----------------------------------------------------------------------
#
# The Record executable pulls in whisper-cpp + ggml via SwiftPM's
# unsafe_flags(-L/opt/homebrew/lib), which bakes the Homebrew prefix
# path right into the binary. Rewrite each to @rpath so we can point at
# our own bundled copies via LC_RPATH.
brew_prefix=$(brew --prefix 2>/dev/null || echo "/opt/homebrew")
dylibs_to_bundle=()

# Discover every non-system dylib the executable references, following
# transitive links so that (e.g.) libwhisper's own dependency on
# libggml-base and libggml-cpu ends up in the bundle too.
collect_deps() {
  local target="$1"
  # Skip anything already collected.
  for existing in "${dylibs_to_bundle[@]:-}"; do
    [[ "$existing" == "$target" ]] && return
  done
  dylibs_to_bundle+=("$target")
  while IFS= read -r line; do
    local raw
    raw=$(print -r -- "$line" | awk '{print $1}')
    # Only pick up Homebrew-installed libs; skip /usr/lib and system frameworks.
    case "$raw" in
      "$brew_prefix"/*|/opt/homebrew/*|/usr/local/*)
        [[ -f "$raw" ]] && collect_deps "$raw"
        ;;
    esac
  done < <(otool -L "$target" 2>/dev/null | tail -n +2)
}
collect_deps "$executable"

# Copy dylibs (resolving symlinks so we grab the real files),
# canonicalize install names, and rewrite load commands to @rpath.
for source in "${dylibs_to_bundle[@]:-}"; do
  # Skip the executable itself.
  [[ "$source" == "$executable" ]] && continue
  resolved="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$source")"
  filename="${source##*/}"
  target="$frameworks_dir/$filename"
  if [[ ! -f "$target" ]]; then
    cp "$resolved" "$target"
    chmod u+w "$target"
    /usr/bin/install_name_tool -id "@rpath/$filename" "$target" 2>/dev/null
  fi
done

# Rewrite every dylib reference in the executable and inside each
# bundled dylib. This covers both the top-level references from Record
# and the cross-references between the bundled dylibs themselves.
rewrite_load_paths() {
  local target="$1"
  otool -L "$target" | tail -n +2 | awk '{print $1}' | while read -r ref; do
    case "$ref" in
      "$brew_prefix"/*|/opt/homebrew/*|/usr/local/*)
        local basename_ref="${ref##*/}"
        /usr/bin/install_name_tool -change "$ref" "@rpath/$basename_ref" "$target" 2>/dev/null || true
        ;;
    esac
  done
}

rewrite_load_paths "$executable"
for bundled in "$frameworks_dir"/*.dylib(N); do
  rewrite_load_paths "$bundled"
done

# Point the executable at its bundled Frameworks dir.
/usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$executable" 2>/dev/null || true

# ----------------------------------------------------------------------
# Sign every mach-o inside the bundle (including the newly-copied
# dylibs) and then the bundle itself. Signing must go inside-out —
# nested dylibs first, then the app.
# ----------------------------------------------------------------------
identity=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Record Local Signer"'; then
    identity="Record Local Signer"
elif line=$(security find-identity -v -p codesigning 2>/dev/null | grep '"Developer ID Application:' | head -1); then
    identity=$(print -r -- "$line" | sed -E 's/.*"([^"]+)".*/\1/')
fi
sign_args=(--force --identifier dev.charsree.record)
if [[ -n "$identity" ]]; then
  sign_args+=(--sign "$identity")
else
  sign_args+=(--sign -)
fi

for bundled in "$frameworks_dir"/*.dylib(N); do
  codesign "${sign_args[@]}" "$bundled"
done
codesign "${sign_args[@]}" "$app_dir"

if [[ -n "$identity" ]]; then
    print "Signed with: $identity"
else
    print "Signed ad-hoc — expect Screen Recording / Mic prompts on rebuild."
fi

# Quick sanity check: no external Homebrew dylibs left.
if otool -L "$executable" | grep -qE '(/opt/homebrew|/usr/local/opt)/'; then
  print "WARNING: executable still references Homebrew paths:"
  otool -L "$executable" | grep -E '(/opt/homebrew|/usr/local/opt)/' | head -5
  exit 1
fi

print "$app_dir"
