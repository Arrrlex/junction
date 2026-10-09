#!/usr/bin/env bash
# Builds Junction and installs it to ~/Applications/Junction.app, plus:
#   - ~/.config/junction/config.js, copied from config.example.js if you don't have one
#   - the `junction` CLI, linked into ~/.local/bin
#   - the fix-browser-routing Claude Code skill, linked into ~/.claude/skills (if ~/.claude exists)
# Safe to re-run; it never overwrites your config. Rule changes only need config.js edits,
# not a reinstall.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
app="$HOME/Applications/Junction.app"
config_dir="$HOME/.config/junction"
# macOS ties permissions and the default-browser setting to the bundle id. To use your own,
# put it in a file called .bundle-id in the repo (gitignored) or set JUNCTION_BUNDLE_ID.
bundle_id="${JUNCTION_BUNDLE_ID:-$(cat "$repo/.bundle-id" 2>/dev/null || echo local.junction.Junction)}"

cd "$repo"
swift build -c release

was_running=false
if pgrep -xq Junction; then was_running=true; pkill -x Junction; fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Junction "$app/Contents/MacOS/Junction"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# Sign with the same local identity every time, so macOS keeps the Accessibility
# permission across rebuilds (an ad-hoc signature changes with every build).
# codesign only finds identities in keychains on the search list, so add the
# project keychain for the duration of the codesign call and then restore the list.
keychain="$repo/.signing/junction.keychain-db"
[[ -f "$keychain" ]] || scripts/make-signing-identity.sh
security unlock-keychain -p junction "$keychain"
saved_list=()
while IFS= read -r k; do
  k="${k#"${k%%[![:space:]]*}"}"   # strip leading whitespace
  saved_list+=("${k//\"/}")         # strip quotes
done < <(security list-keychains -d user)
restore_list() { security list-keychains -d user -s "${saved_list[@]}"; }
trap restore_list EXIT
security list-keychains -d user -s "${saved_list[@]}" "$keychain"
codesign --force --sign "Junction Local Signing" --identifier "$bundle_id" "$app"
restore_list
trap - EXIT
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"

mkdir -p "$config_dir" "$HOME/.local/bin"
if [[ ! -e "$config_dir/config.js" ]]; then
  cp config.example.js "$config_dir/config.js"
  echo "Created $config_dir/config.js from config.example.js; edit it to set up your browsers."
fi
ln -sfn "$app/Contents/MacOS/Junction" "$HOME/.local/bin/junction"
if [[ -d "$HOME/.claude" ]]; then
  mkdir -p "$HOME/.claude/skills"
  ln -sfn "$repo/skill" "$HOME/.claude/skills/fix-browser-routing"
fi

if $was_running; then open "$app"; fi
echo "Installed $app ($bundle_id)"
