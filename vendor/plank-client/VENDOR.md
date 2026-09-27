# PLANK Client raw Wacom worker snapshot

Source repository: `instinctual/plank-client` (GPL-3.0-or-later)

Source commit: `e937564d43dc8d012dad89e1a76fd219b89fae49`

Files copied without edits:

| Vendored file | Upstream path |
| --- | --- |
| `linuxrawwacom.cpp` | `app/streaming/input/linuxrawwacom.cpp` |
| `linuxrawwacom.h` | `app/streaming/input/linuxrawwacom.h` |
| `plank.h` | `moonlight-common-c/moonlight-common-c/src/plank.h` |

CMake checks each file's SHA-256 digest against this snapshot before compiling
the Linux worker. Update the Client first, then deliberately update these
files, hashes and commit together.
