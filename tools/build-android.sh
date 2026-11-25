#!/usr/bin/env bash
# Builds the controller-only Remote Hub APK for arm64 (Pixel 6) from
# config/build-lock.json.
#
# Usage: tools/build-android.sh --debug | --release
#
#   --debug    debug-signed APK for testing on the owner's phone. Uncommitted
#              changes are allowed; the APK is then labeled <commit>-dirty.
#   --release  release APK signed with the owner's own key. Needs a key.properties
#              outside the repository and outside the staging sources (staging is
#              wiped on every build): $RH_ANDROID_KEY_PROPERTIES, default
#              $RH_BUILD_DIR/signing/key.properties, with an absolute storeFile path.
#              Never committed; the build stops if it is missing. The checkout
#              must be clean (tools/source_state.py), so the APK is exactly
#              its stated commit.
#
# Prerequisites (checked by tools/doctor.py --target android-arm64):
#   VCPKG_ROOT (a root used only for Android, see vcpkgNote), ANDROID_NDK_HOME (NDK r28c), JDK 17, cargo-ndk 3.1.2,
#   RH_FLUTTER (Flutter 3.24.5), RH_TOOLS (flutter_rust_bridge_codegen 1.80.1)
# Optional: RH_BUILD_DIR staging directory (default ../remote-hub-build-android)
#
# Steps: doctor -> stage sources -> vcpkg arm64-android -> bridge codegen ->
# cargo ndk (features from the lock) -> controller-only manifest and app id ->
# flutter build apk. The repository itself is never modified.
#
# Exit codes: 0 built, 1 a step failed, 2 bad arguments, 3 doctor failed.
set -euo pipefail

MODE=""
case "${1:-}" in
  --debug) MODE=debug ;;
  --release) MODE=release ;;
  *) echo "usage: $0 --debug|--release" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/config/build-lock.json"
lock() {
  python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    d = d[k]
print(d)' "$LOCK" "$@"
}
RUST="$(lock targets android-arm64 rust)"
FEATURES="$(lock targets android-arm64 cargoFeatures)"
APP_ID="$(lock product androidApplicationId)"
DART_DEFINE="$(lock product dartDefine)"
CODEGEN_RUST="$(lock bridgeGenerator rust)"
FLUTTER="${RH_FLUTTER:-flutter}"
TOOLS="${RH_TOOLS:-$HOME/.cargo}"
OUT="${RH_BUILD_DIR:-$(dirname "$ROOT")/remote-hub-build-android}"
SRC="$OUT/src"
KEY_PROPERTIES="${RH_ANDROID_KEY_PROPERTIES:-$OUT/signing/key.properties}"

python3 "$ROOT/tools/doctor.py" --target android-arm64 || exit 3

# Staging copies the working tree, so the label must describe the working tree:
# a release refuses uncommitted changes, a debug build is labeled <sha>-dirty.
SOURCE_ARGS=()
[[ "$MODE" == debug ]] && SOURCE_ARGS+=(--allow-dirty)
COMMIT="$(python3 "$ROOT/tools/source_state.py" "$ROOT" ${SOURCE_ARGS[@]+"${SOURCE_ARGS[@]}"})" || exit 1

if [[ "$MODE" == release ]]; then
  if [[ ! -f "$KEY_PROPERTIES" ]]; then
    echo "release signing: $KEY_PROPERTIES not found (set RH_ANDROID_KEY_PROPERTIES)" >&2
    exit 1
  fi
  STORE_FILE="$(sed -n 's/^[[:space:]]*storeFile[[:space:]]*=[[:space:]]*//p' "$KEY_PROPERTIES" | tail -1)"
  if [[ "$STORE_FILE" != /* || ! -f "$STORE_FILE" ]]; then
    echo "release signing: storeFile in $KEY_PROPERTIES must be an absolute path to an existing keystore" >&2
    exit 1
  fi
fi

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
if [[ "$MODE" == release ]]; then
  # Staging was just rebuilt from Git, so the owner's key file is copied in here.
  cp "$KEY_PROPERTIES" flutter/android/key.properties
fi
export PATH="$(dirname "$FLUTTER"):$PATH"

echo "== vcpkg arm64-android"
./flutter/build_android_deps.sh arm64-v8a

echo "== flutter pub get + bridge codegen"
(cd flutter && "$FLUTTER" pub get)
CODEGEN_RUSTC_DIR="$(dirname "$(rustup which --toolchain "$CODEGEN_RUST" rustc)")"
PATH="$CODEGEN_RUSTC_DIR:$TOOLS/bin:$PATH" "$TOOLS/bin/flutter_rust_bridge_codegen" \
  --rust-input ./src/flutter_ffi.rs \
  --dart-output ./flutter/lib/generated_bridge.dart \
  --c-output ./flutter/macos/Runner/bridge_generated.h

echo "== cargo ndk ($RUST, features $FEATURES)"
HOST_TAG="$(ls "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" | head -1)"
NDK_LLVM="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST_TAG"
# bindgen must parse Android headers with the NDK's clang and sysroot, not the
# host compiler's (which has no Android libc headers).
export LIBCLANG_PATH="$NDK_LLVM/lib"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$NDK_LLVM/sysroot"
# libsodium-sys builds libsodium with autotools, which otherwise takes the macOS
# ranlib: it cannot index ELF objects and the link misses every sodium symbol.
export AR="$NDK_LLVM/bin/llvm-ar" RANLIB="$NDK_LLVM/bin/llvm-ranlib"
RUSTC_DIR="$(dirname "$(rustup which --toolchain "$RUST" rustc)")"
rustup target add --toolchain "$RUST" aarch64-linux-android
if [[ "$MODE" == debug ]]; then
  # Upstream's single-unit fat LTO needs most of a 16 GB Mac for one link step;
  # a test APK does not need it. --release keeps the upstream profile.
  export CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
fi
PATH="$RUSTC_DIR:$PATH" cargo ndk --platform 21 --target aarch64-linux-android \
  build --locked --release --features "$FEATURES"
JNI=flutter/android/app/src/main/jniLibs/arm64-v8a
mkdir -p "$JNI"
cp target/aarch64-linux-android/release/liblibrustdesk.so "$JNI/librustdesk.so"
# A shared library links even with unresolved symbols; they fail only on the phone.
if "$NDK_LLVM/bin/llvm-nm" -D --undefined-only "$JNI/librustdesk.so" | grep -E ' (sodium_|crypto_)'; then
  echo "librustdesk.so has unresolved libsodium symbols" >&2
  exit 1
fi
cp "$NDK_LLVM/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$JNI/"

echo "== controller-only manifest, application id $APP_ID"
python3 "$ROOT/tools/android_controller_manifest.py" flutter/android/app/src/main/AndroidManifest.xml
sed -i.bak -e "s/applicationId \"com.carriez.flutter_hbb\"/applicationId \"$APP_ID\"/" \
  flutter/android/app/build.gradle
rm -f flutter/android/app/build.gradle.bak

echo "== flutter build apk ($MODE)"
(cd flutter && "$FLUTTER" build apk "--$MODE" --target-platform android-arm64 --split-per-abi \
  "--dart-define=$DART_DEFINE")
APK="flutter/build/app/outputs/flutter-apk/app-arm64-v8a-$MODE.apk"
mkdir -p "$OUT/artifacts"
cp "$APK" "$OUT/artifacts/RemoteHub-android-arm64-$MODE.apk"
VERIFY_ARGS=(--commit "$COMMIT")
[[ "$MODE" == release ]] && VERIFY_ARGS+=(--release)
python3 "$ROOT/tools/verify-release.py" apk "$OUT/artifacts/RemoteHub-android-arm64-$MODE.apk" \
  "${VERIFY_ARGS[@]}"
echo "== done: $OUT/artifacts/RemoteHub-android-arm64-$MODE.apk"
