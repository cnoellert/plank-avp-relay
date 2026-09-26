#pragma once

#include "pad.h"
#include "pairing.h"

// Serve one already-accepted TCP pairing connection while the pairing window
// is open. The caller owns the socket and Pad. Returns 0 only after a verified
// Client confirmation and result delivery.
int pltr_run_tcp_pair_session(int socket_fd, PltrPairing &pairing,
                              PltrPad &pad, int stop_fd);
