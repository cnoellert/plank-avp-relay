#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Run in a Debian/Ubuntu build environment; always package a clean Git snapshot.
set -euo pipefail
relay_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$relay_root"
source_status=$(git status --porcelain)
if [[ -n $source_status ]]; then
    echo 'Commit the source changes before building a package.' >&2
    exit 1
fi
command -v dpkg-buildpackage >/dev/null
architecture=$(dpkg-architecture -qDEB_HOST_ARCH)
if [[ $architecture != "$(dpkg-architecture -qDEB_BUILD_ARCH)" ]]; then
    echo 'Use a native builder so package tests execute on the target architecture.' >&2
    exit 2
fi
# Include the userspace baseline: packages built on newer distributions may
# require newer libc/Python even when the CPU architecture is identical.
source /etc/os-release
build_platform="${ID}-${VERSION_ID}/${architecture}"
jobs=${PLANK_BUILD_JOBS:-4}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid PLANK_BUILD_JOBS' >&2; exit 2; }
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
    dpkg-buildpackage --build=binary --no-sign --jobs-force="$jobs"
)
mkdir "$stage/install-test"
dpkg-deb --extract "$stage/"plank-tablet-relay-ble_*.deb "$stage/install-test"
python3 "$stage/source/tests/installed_relay_smoke.py" "$stage/install-test"
destination="$relay_root/artifacts/deb/$source_commit/$build_platform"
mkdir -p "$destination"
shopt -s nullglob
cp "$stage/"*.{deb,ddeb,buildinfo,changes} "$destination/"
printf '%s\n' "$source_commit" > "$destination/source-commit.txt"
python3 - "$destination" "$source_commit" "$architecture" <<'PY'
import json
import platform
import subprocess
import sys
from pathlib import Path

destination, commit, architecture = sys.argv[1:]
metadata = {
    "source_commit": commit,
    "architecture": architecture,
    "machine": platform.machine(),
    "os_release": Path("/etc/os-release").read_text(),
    "compiler": subprocess.check_output(["cc", "--version"], text=True).splitlines()[0],
    "package_version": subprocess.check_output(
        ["dpkg-parsechangelog", "-SVersion"], text=True).strip(),
    "validation": ["libsodium make check", "relay ctest", "extracted package smoke"],
}
Path(destination, "provenance.json").write_text(json.dumps(metadata, indent=2) + "\n")
PY
(cd "$destination" && sha256sum *.{deb,ddeb,buildinfo,changes} source-commit.txt provenance.json > SHA256SUMS)
printf 'Package artifacts: %s\nBuild source: %s\n' "$destination" "$stage/source"
