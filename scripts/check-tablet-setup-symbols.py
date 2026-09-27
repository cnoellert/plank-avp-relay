#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reject a tablet setup archive missing matching application debug symbols."""
import pathlib
import plistlib
import re
import subprocess
import sys

archive = pathlib.Path(sys.argv[1])
app = archive / 'Products/Applications/PLANK Tablet Setup.app'
info = plistlib.loads((app / 'Info.plist').read_bytes())
binary = app / info['CFBundleExecutable']
symbols = archive / 'dSYMs/PLANK Tablet Setup.app.dSYM'
if not symbols.is_dir():
    sys.exit('FAIL: application dSYM missing from archive')

def uuids(path):
    output = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], text=True)
    return sorted(re.findall(r'UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)', output))

actual, expected = uuids(symbols), uuids(binary)
if not expected or actual != expected:
    sys.exit('FAIL: application and dSYM UUIDs do not match')
print('PASS: application dSYM UUID matches every executable architecture')
