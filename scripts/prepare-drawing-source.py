#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Prepare the exact drawing source for a package build; never use working files."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile


def prepare(manifest, destination, repository=None):
    pin = json.loads(Path(manifest).read_text())
    destination = Path(destination)
    if destination.exists():
        raise ValueError('Drawing source destination must not exist')
    with tempfile.TemporaryDirectory(prefix='plank-drawing-source-') as scratch:
        scratch = Path(scratch)
        if repository is None:
            repository = scratch / 'repository'
            subprocess.run(['git', 'init', '--bare', str(repository)], check=True,
                           stdout=subprocess.DEVNULL)
            subprocess.run(['git', '-C', str(repository), 'fetch', '--depth=1',
                            '--no-tags', '--recurse-submodules=no', pin['repository'],
                            pin['commit']], check=True)
        commit = subprocess.check_output(['git', '-C', str(repository), 'rev-parse',
                                          pin['commit'] + '^{commit}'], text=True).strip()
        if commit != pin['commit']:
            raise ValueError('Drawing commit mismatch')
        archive = scratch / 'source.tar'
        subprocess.run(['git', '-C', str(repository), 'archive', commit, '-o', str(archive)], check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != pin['archive_sha256']:
            raise ValueError('Drawing source archive hash mismatch')
        with tarfile.open(archive) as source:
            # No links, submodules or special files are build inputs.
            for member in source.getmembers():
                if (not (member.isfile() or member.isdir()) or
                    Path(member.name).is_absolute() or '..' in Path(member.name).parts):
                    raise ValueError('Unsafe drawing source archive member')
            destination.mkdir(parents=True)
            source.extractall(destination, filter='data')
    print('Drawing source verified: ' + commit)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest')
    parser.add_argument('destination')
    parser.add_argument('--repository', help='Local Git repository for an offline, verified build')
    args = parser.parse_args()
    prepare(args.manifest, args.destination, args.repository)
