#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Small Apple-only build: no desktop Client, FFmpeg, Qt, SDL or Rust transport.
set -euo pipefail
relay_root=$(cd "$(dirname "$0")/.." && pwd)
platform=${1:-simulator}
case "$platform" in
    simulator) sdk=xrsimulator; target=arm64-apple-xros27.0-simulator; system=visionOS ;;
    device) sdk=xros; target=arm64-apple-xros27.0; system=visionOS ;;
    macos) sdk=macosx; target=arm64-apple-macos27.0; system=Darwin ;;
    *) echo "Usage: $0 simulator|device|macos" >&2; exit 2 ;;
esac
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || {
    echo "Build on the authorized Apple Silicon Mac or Apple Silicon CI runner." >&2; exit 1;
}
sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
sdk_version=$(xcrun --sdk "$sdk" --show-sdk-version)
[[ ${sdk_version%%.*} -ge 27 ]] || { echo "SDK27 or newer is required" >&2; exit 1; }
cmake_bin=${CMAKE_COMMAND:-cmake}
jobs=${PLANK_BUILD_JOBS:-4}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo "Invalid PLANK_BUILD_JOBS" >&2; exit 2; }
build_root=${PLANK_TABLET_BUILD_ROOT:-"$relay_root/build/tablet-setup"}
mkdir -p "$build_root/dependencies"
sodium_version=1.0.22
sodium_sha=adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349
archive="$build_root/dependencies/libsodium-$sodium_version.tar.gz"
if [[ ! -f "$archive" ]]; then
    curl --fail --location --proto '=https' --tlsv1.2 \
        "https://github.com/jedisct1/libsodium/releases/download/$sodium_version-RELEASE/libsodium-$sodium_version.tar.gz" \
        -o "$archive.partial"
    mv "$archive.partial" "$archive"
fi
printf '%s  %s\n' "$sodium_sha" "$archive" | shasum -a 256 -c -
# Include the complete fixed recipe as well as source and compiler/SDK inputs.
sodium_recipe='-O2 --disable-shared --enable-static --disable-asm license-v1'
fingerprint=$( { printf '%s\n' "$sodium_sha" "$target" "$sdk_path" "$sdk_version" "$sodium_recipe";
                 xcrun --sdk "$sdk" clang --version; } | shasum -a 256 | cut -c1-20)
dependency="$build_root/dependencies/sodium-$platform-$fingerprint"
prefix="$dependency/install"
if [[ -f "$prefix/.complete" ]]; then
    (cd "$prefix" && shasum -a 256 -c .complete)
else
    mkdir -p "$dependency/source" "$dependency/objects"
    tar -xzf "$archive" -C "$dependency/source" --strip-components=1
    (
        cd "$dependency/objects"
        CC="$(xcrun --sdk "$sdk" --find clang)" \
        CFLAGS="-O2 -target $target -isysroot $sdk_path" \
        LDFLAGS="-target $target -isysroot $sdk_path" \
        "$dependency/source/configure" --host=aarch64-apple-darwin \
            --prefix="$prefix" --disable-shared --enable-static --disable-asm
        make -j "$jobs"
        make install
    )
    mkdir -p "$prefix/share/licenses/libsodium"
    cp "$dependency/source/LICENSE" "$prefix/share/licenses/libsodium/LICENSE"
    (cd "$prefix" && shasum -a 256 lib/libsodium.a include/sodium.h include/sodium/*.h \
        share/licenses/libsodium/LICENSE > .complete)
fi
app_build="$build_root/$platform"
# Re-detect the selected Xcode; an OS/Xcode update can remove the old compiler
# path. This refreshes configuration, not the verified dependency cache.
"$cmake_bin" --fresh -S "$relay_root/apps/tablet-setup" -B "$app_build" -G Xcode \
    -DCMAKE_SYSTEM_NAME="$system" -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 \
    -DPLANK_DEVELOPMENT_TEAM= \
    -DPLANK_SETUP_BUILD_NUMBER="${PLANK_SETUP_BUILD_NUMBER:-1}" \
    -DPLANK_SODIUM_PREFIX="$prefix"
"$cmake_bin" --build "$app_build" --config Debug --parallel "$jobs" -- -quiet CODE_SIGNING_ALLOWED=NO
if [[ $platform == macos ]]; then
    "${CTEST_COMMAND:-ctest}" --test-dir "$app_build" -C Debug --output-on-failure
fi
configuration=Debug
[[ $platform == macos ]] || configuration="Debug-$sdk"
python3 "$relay_root/scripts/check-tablet-setup-bundle.py" \
    "$app_build/$configuration/PLANK Tablet Setup.app" --platform "$platform"
printf '\nBuilt: %s/%s/PLANK Tablet Setup.app\n' "$app_build" "$configuration"
printf 'Unsigned prototype. See apps/tablet-setup/README.md for device provisioning.\n'
