#!/usr/bin/env bash
# Builds the Remote Hub macOS app for one architecture from config/build-lock.json.
#
# Usage: tools/build-macos.sh [--arch arm64] [--allow-dirty]
#
# Release only: the Xcode project links ../../target/release/liblibrustdesk.dylib.
# The checkout must be clean (tools/source_state.py) so the app is exactly its
# stated commit. --allow-dirty builds uncommitted changes for testing; the app
# is then labeled <commit>-dirty and is not a release.
#
# Prerequisites (checked by tools/doctor.py --target macos-arm64):
#   VCPKG_ROOT   vcpkg at the pinned commit with the arm64-osx packages installed
#                (its own root: see vcpkgNote in the build lock)
#   RH_FLUTTER   flutter binary of the pinned version (default: flutter on PATH)
#   RH_TOOLS     cargo root holding flutter_rust_bridge_codegen + cargo-expand
#   NASM 2.16.03, GNU sed, CocoaPods, Xcode
# Optional:
#   RH_BUILD_DIR staging directory (default: ../remote-hub-build next to the repo)
#
# The repository is never modified: tracked files plus new untracked files are
# copied to a staging tree, where the CI-only Flutter 3.44 patch, the
# deployment target and the Remote Hub identity are applied. No signing
# credentials are used; the app is ad-hoc signed by Xcode.
#
# Exit codes: 0 built, 1 a build step failed, 2 bad arguments, 3 doctor failed.
set -euo pipefail

ARCH=arm64
MODE=release
ALLOW_DIRTY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$ARCH" == arm64 ]] || { echo "only arm64 is pinned in the build lock" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/config/build-lock.json"
# lock KEY... prints one value of the build lock, e.g. `lock targets macos-arm64 rust`.
lock() {
  python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    d = d[k]
print(d)' "$LOCK" "$@"
}
RUST="$(lock targets macos-arm64 rust)"
FEATURES="$(lock targets macos-arm64 cargoFeatures)"
MIN_MACOS="$(lock targets macos-arm64 deploymentTarget)"
BUNDLE_ID="$(lock product macosBundleId)"
DISPLAY_NAME="$(lock product displayName)"
DART_DEFINE="$(lock product dartDefine)"
CODEGEN_RUST="$(lock bridgeGenerator rust)"
FLUTTER="${RH_FLUTTER:-flutter}"
TOOLS="${RH_TOOLS:-$HOME/.cargo}"
OUT="${RH_BUILD_DIR:-$(dirname "$ROOT")/remote-hub-build}"
SRC="$OUT/src"

if ! python3 "$ROOT/tools/doctor.py" --target macos-arm64; then
  exit 3
fi

# Staging copies the working tree, so the label must describe the working tree.
SOURCE_ARGS=()
VERIFY_ARGS=(--release)
if [[ "$ALLOW_DIRTY" == 1 ]]; then
  SOURCE_ARGS+=(--allow-dirty)
  VERIFY_ARGS=()
fi
COMMIT="$(python3 "$ROOT/tools/source_state.py" "$ROOT" ${SOURCE_ARGS[@]+"${SOURCE_ARGS[@]}"})" || exit 1

echo "== staging sources in $SRC"
mkdir -p "$SRC"
find "$SRC" -mindepth 1 -maxdepth 1 ! -name target -exec rm -rf {} +
(
  cd "$ROOT"
  { git ls-files --recurse-submodules; git ls-files -o --exclude-standard; } |
    while IFS= read -r f; do [ -e "$f" ] && printf '%s\n' "$f"; done |
    rsync -a --files-from=- ./ "$SRC/"
)

cd "$SRC"
# build.rs writes src/version.rs, which staging just deleted; a newer build.rs
# makes cargo rerun it when target/ is reused.
touch build.rs
export PATH="/opt/homebrew/opt/gnu-sed/libexec/gnubin:$(dirname "$FLUTTER"):$PATH"
echo "== Flutter 3.44 source patch (as in CI)"
# The script only prints `git diff` at the end, which fails outside a git
# checkout; a no-op git keeps its own before/after validation authoritative.
NOGIT="$OUT/nogit"
mkdir -p "$NOGIT"
printf '#!/bin/sh\nexit 0\n' > "$NOGIT/git"
chmod +x "$NOGIT/git"
PATH="$NOGIT:$PATH" bash .github/patches/apply_flutter_3.44_source_patches.sh
sed -i -e "s/MACOSX_DEPLOYMENT_TARGET\=[0-9]*.[0-9]*/MACOSX_DEPLOYMENT_TARGET=${MIN_MACOS}/" build.py
sed -i -e "s/platform :osx, '.*'/platform :osx, '${MIN_MACOS}'/" flutter/macos/Podfile
sed -i -e "s/osx_minimum_system_version = \"[0-9]*.[0-9]*\"/osx_minimum_system_version = \"${MIN_MACOS}\"/" Cargo.toml
sed -i -e "s/MACOSX_DEPLOYMENT_TARGET = [0-9]*.[0-9]*;/MACOSX_DEPLOYMENT_TARGET = ${MIN_MACOS};/" flutter/macos/Runner.xcodeproj/project.pbxproj
# Xcode 27 rejects pod targets below macOS 12.0; align every pod with the app.
sed -i -e "s/^    flutter_additional_macos_build_settings(target)$/&\n    target.build_configurations.each { |c| c.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '${MIN_MACOS}' }/" flutter/macos/Podfile
grep -q "build_settings\['MACOSX_DEPLOYMENT_TARGET'\] = '${MIN_MACOS}'" flutter/macos/Podfile
echo "== Remote Hub identity: $DISPLAY_NAME / $BUNDLE_ID"
sed -i -e "s/^PRODUCT_NAME = .*/PRODUCT_NAME = ${DISPLAY_NAME}/" \
  -e "s/^PRODUCT_BUNDLE_IDENTIFIER = .*/PRODUCT_BUNDLE_IDENTIFIER = ${BUNDLE_ID}/" \
  flutter/macos/Runner/Configs/AppInfo.xcconfig
# The Runner target also sets the id in the project, which wins over the xcconfig.
sed -i -e "s/PRODUCT_BUNDLE_IDENTIFIER = com.carriez.rustdesk;/PRODUCT_BUNDLE_IDENTIFIER = ${BUNDLE_ID};/" \
  flutter/macos/Runner.xcodeproj/project.pbxproj
if grep -q "com.carriez.rustdesk;" flutter/macos/Runner.xcodeproj/project.pbxproj; then
  echo "upstream bundle id still set in the Xcode project" >&2
  exit 1
fi
# No rustdesk:// deep links: they could start sessions or set options from outside.
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" flutter/macos/Runner/Info.plist

echo "== flutter pub get + bridge codegen"
(cd flutter && "$FLUTTER" config --no-enable-swift-package-manager >/dev/null && "$FLUTTER" pub get)
CODEGEN_RUSTC_DIR="$(dirname "$(rustup which --toolchain "$CODEGEN_RUST" rustc)")"
PATH="$CODEGEN_RUSTC_DIR:$TOOLS/bin:$PATH" "$TOOLS/bin/flutter_rust_bridge_codegen" \
  --rust-input ./src/flutter_ffi.rs \
  --dart-output ./flutter/lib/generated_bridge.dart \
  --c-output ./flutter/macos/Runner/bridge_generated.h
cp ./flutter/macos/Runner/bridge_generated.h ./flutter/ios/Runner/bridge_generated.h

echo "== cargo build ($RUST, features $FEATURES)"
PROFILE_DIR=release
XCODE_CONFIG=Release
RUSTC_DIR="$(dirname "$(rustup which --toolchain "$RUST" rustc)")"
PATH="$RUSTC_DIR:$PATH" MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
  cargo build --locked --features "$FEATURES" --release
cp "target/$PROFILE_DIR/liblibrustdesk.dylib" "target/$PROFILE_DIR/librustdesk.dylib"

echo "== flutter build macos ($MODE)"
(
  cd flutter
  FLUTTER_XCODE_ARCHS=arm64 FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES \
    "$FLUTTER" build macos "--$MODE" "--dart-define=$DART_DEFINE"
)
APP_DIR="flutter/build/macos/Build/Products/$XCODE_CONFIG"
APP="$APP_DIR/$DISPLAY_NAME.app"
cp -f "target/$PROFILE_DIR/service" "$APP/Contents/MacOS/"
codesign --force --deep --sign - "$APP"

mkdir -p "$OUT/artifacts"
rm -rf "$OUT/artifacts/$DISPLAY_NAME.app"
cp -R "$APP" "$OUT/artifacts/"
python3 - "$OUT/artifacts" "$DISPLAY_NAME" "$COMMIT" "$MODE" <<'PY'
import hashlib, json, pathlib, platform, sys, datetime
out, name, commit, mode = sys.argv[1:]
app = pathlib.Path(out, f"{name}.app")
files = {}
for p in sorted(app.rglob("*")):
    if p.is_file() and (p.suffix in (".dylib",) or p.parent.name == "MacOS"):
        files[str(p.relative_to(out))] = hashlib.sha256(p.read_bytes()).hexdigest()
info = {
    "target": "macos-arm64",
    "mode": mode,
    "sourceCommit": commit,
    # "<sha>-dirty" when built with --allow-dirty: not a release.
    "release": not commit.endswith("-dirty"),
    "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "host": f"{platform.system()} {platform.mac_ver()[0]} {platform.machine()}",
    "sha256": files,
}
pathlib.Path(out, "build-info-macos.json").write_text(json.dumps(info, indent=2))
print(json.dumps(info, indent=2))
PY
python3 "$ROOT/tools/verify-release.py" macos "$OUT/artifacts/$DISPLAY_NAME.app" --commit "$COMMIT" \
  ${VERIFY_ARGS[@]+"${VERIFY_ARGS[@]}"}
echo "== done: $OUT/artifacts/$DISPLAY_NAME.app"
