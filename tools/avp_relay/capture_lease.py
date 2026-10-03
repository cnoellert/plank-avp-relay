# SPDX-License-Identifier: GPL-3.0-or-later
"""Process-lifetime ownership of the shared Linux tablet input reader."""
import errno
import socket


# Linux abstract AF_UNIX addresses have no filesystem path or stale lock file.
# The raw-HID service binds this exact address before it opens tablet input.
ADDRESS = b'\0plank-tablet-capture-v1'


class CaptureBusy(ValueError):
    pass


class CaptureLease:
    def __init__(self):
        self.socket = None

    @property
    def held(self):
        return self.socket is not None

    def acquire(self):
        if self.held:
            return True
        candidate = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            candidate.setblocking(False)
            candidate.bind(ADDRESS)
        except OSError as error:
            candidate.close()
            if error.errno == errno.EADDRINUSE:
                return False
            raise
        self.socket = candidate
        return True

    def release(self):
        if self.socket is not None:
            self.socket.close()
            self.socket = None

    def busy(self):
        """Advisory status only; an actual operation must still acquire."""
        if self.held:
            return False
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            probe.setblocking(False)
            try:
                probe.connect(ADDRESS)
            except OSError as error:
                if error.errno in (errno.ENOENT, errno.ECONNREFUSED):
                    return False
                raise
            return True
        finally:
            probe.close()
