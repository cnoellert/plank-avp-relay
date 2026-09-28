#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Run in a Debian/Ubuntu build environment; always package a clean Git snapshot.
set -euo pipefail
relay_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$relay_root"
if [[ -n $(git status --porcelain) ]]; then
    echo 'Commit the source changes before building a package.' >&2
    exit 1
fi
command -v dpkg-buildpackage >/dev/null
source_commit=$(git rev-parse HEAD)
build_root=${PLANK_DEB_BUILD_ROOT:-"$relay_root/build/deb"}
mkdir -p "$build_root/dependencies" "$relay_root/artifacts/deb"
build_root=$(cd "$build_root" && pwd)
archive="$build_root/dependencies/libsodium-1.0.22.tar.gz"
if [[ ! -f "$archive" ]]; then
    curl --fail --location --proto '=https' --tlsv1.2 \
        https://github.com/jedisct1/libsodium/releases/download/1.0.22-RELEASE/libsodium-1.0.22.tar.gz \
        -o "$archive.partial"
    mv "$archive.partial" "$archive"
fi
printf '%s  %s\n' adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349 "$archive" | sha256sum -c -
stage=$(mktemp -d "$build_root/package.XXXXXX")
mkdir "$stage/source"
git archive "$source_commit" | tar -x -C "$stage/source"
mkdir -p "$stage/source/debian/vendor"
cp "$archive" "$stage/source/debian/vendor/"
(
    cd "$stage/source"
    dpkg-buildpackage --build=binary --no-sign
)
destination="$relay_root/artifacts/deb/$source_commit"
mkdir -p "$destination"
cp "$stage/"*.deb "$stage/"*.buildinfo "$stage/"*.changes "$destination/"
printf '%s\n' "$source_commit" > "$destination/source-commit.txt"
(cd "$destination" && sha256sum *.deb *.buildinfo *.changes source-commit.txt > SHA256SUMS)
printf 'Package artifacts: %s\nBuild source: %s\n' "$destination" "$stage/source"
