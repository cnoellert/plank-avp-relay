# SPDX-License-Identifier: GPL-3.0-or-later
"""Short Linux process labels; full executable/service names remain descriptive."""
from pathlib import Path


def name_process(name):
    if len(name.encode()) > 15 or '\n' in name:
        raise ValueError('Linux process labels must fit in 15 bytes.')
    Path('/proc/self/comm').write_text(name + '\n')
