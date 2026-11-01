// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

//go:build !darwin

package main

// setNoSigPipe is a no-op on platforms other than darwin. Callers there
// can pass MSG_NOSIGNAL to send(2) or ignore SIGPIPE.
func setNoSigPipe(fd int) error {
	return nil
}
