// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

//go:build darwin

package main

import "golang.org/x/sys/unix"

// setNoSigPipe sets SO_NOSIGPIPE on fd, so that a write to fd after the
// peer closed its end fails with EPIPE instead of raising SIGPIPE.
//
// Go ignores SIGPIPE for writes on Go threads, but C and Swift callers
// write to connection fds on their own threads. There, SIGPIPE has its
// default action and terminates the process (see "Go programs that use
// cgo or SWIG" in the os/signal documentation). Darwin has no
// MSG_NOSIGNAL for write(2), so the option goes on the socket.
func setNoSigPipe(fd int) error {
	return unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_NOSIGPIPE, 1)
}
