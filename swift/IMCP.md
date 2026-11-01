# TailscaleKit for iMCP

The `mattt/imcp` branch of [mattt/libtailscale](https://github.com/mattt/libtailscale)
builds a pinned, trimmed TailscaleKit for iMCP,
a sandboxed macOS menu bar app.
iMCP uses it as a Swift Package Manager binary target
through the `Package.swift` file at the root of this repository.
This branch is not an upstream pull request.

## Changes from upstream

The branch starts at `ac7ed43` on `tailscale/libtailscale` `main`
and adds these changes:

- `OutgoingConnection.send(_:)` writes inside `withUnsafeBytes`.
  Before this fix, short messages could arrive with incorrect bytes.
- `tailscale_whois` and `TailscaleNode.whois(_:)` identify the peer
  at an IP address or IP:port.
  The lookup uses tsnet's in-memory LocalAPI, not the loopback server.
  The Swift method runs the lookup off the node's actor,
  because the lookup can take up to 10 seconds.
  A mutex now guards each server's last error message,
  because lookups can run at the same time.
  The node still has one last error message,
  so when calls fail at the same time,
  an error's details can describe another call's failure.
- `IncomingConnection.send(_:timeout:)` sends data to the peer
  of an accepted connection.
- On Darwin, libtailscale sets `SO_NOSIGPIPE` on both ends
  of each connection socketpair.
  A write after the peer goes away fails with `EPIPE`.
  Before this change, the write raised `SIGPIPE` on the caller's thread,
  which terminated the process.
- `IncomingConnection.send(_:timeout:)` and `OutgoingConnection.send(_:timeout:)`
  write all of the data, retry after `EINTR`,
  and throw `ETIMEDOUT` when the peer does not accept the data in time.
  The timeout is in milliseconds, as for the receive methods,
  and the default is 10 seconds.
  Before this change, a send to a peer that stopped reading blocked forever.
- `tailscale_logout` and `TailscaleNode.logout()` log the node out
  through tsnet's in-memory LocalAPI.
  The Swift method runs off the node's actor,
  because the logout can take up to 30 seconds.
- `LocalAPIClient.logout()` is public.
  Like the other `LocalAPIClient` methods, it uses the loopback server,
  which starts a SOCKS5 proxy and a LocalAPI listener on 127.0.0.1
  for the rest of the node's life.
- `IpnState.PeerStatus` decodes `UserID`.
- `go.mod` replaces `tailscale.com` with a fork of v1.104.1
  that adds `client/local/cert_omit.go`.
  Without that file, tsnet does not compile with `ts_omit_acme`.
- `make -C swift test` builds the tests with optimization,
  and runs the tstestcontrol calls on one thread.
  The test bundle links two Go runtimes,
  and a thread that calls into one runtime and then the other
  can crash the process.
- `swift/imcp-feature-tags.txt` lists the feature profile,
  and `make -C swift imcp` builds the release archive.

## Upstream tracking

- [tailscale/libtailscale#70](https://github.com/tailscale/libtailscale/pull/70)
  contains the `OutgoingConnection.send(_:)` fix
  for [tailscale/tailscale#22025](https://github.com/tailscale/tailscale/issues/22025).
- [tailscale/tailscale#22031](https://github.com/tailscale/tailscale/pull/22031)
  adds `cert_omit.go`.
  The fork branch
  [`mattt/imcp-v1.104.1`](https://github.com/mattt/tailscale/tree/mattt/imcp-v1.104.1)
  backports only that file to v1.104.1.
  Remove the `replace` directive when a Tailscale release includes the file.
- [tailscale/tailscale#22039](https://github.com/tailscale/tailscale/issues/22039)
  tracks the design of the whois, send, and logout API additions.

## Feature profile

The build omits every optional Tailscale feature
except the features in this table.

| Feature | Why the build keeps it |
| --- | --- |
| `netstack` | tsnet uses userspace networking for its listeners and connections. |
| `ipnbus` | `tsnet.Server.Up` waits for the node to start through the IPN bus. |
| `serve` | tsnet and `tailscale_enable_funnel_to_localhost_plaintext_http1` call Serve methods directly. The build fails without it. |
| `udptransport` | Without it, all peer traffic goes through DERP relays. |
| `nattraversal` | STUN and hole punching make direct connections through NAT. |
| `portmapper` | NAT-PMP, PCP, and UPnP port mapping make more direct connections. |
| `tailnetlock` | Without it, the node does not check node key signatures, so it accepts peers that Tailnet Lock rejects. |
| `health` | Magicsock changes its home DERP region only while health reports a connection to control. Without it, the home region does not change after the first choice, and status reports the node as offline. |

The build omits `logtail` and `netlog`,
so the library cannot upload logs or network flow logs.
It omits `acme`, so the node cannot get TLS certificates.

For 0.2.0-imcp.1, the signed framework is 17,066,149 bytes with this profile,
and the zip is 6,502,502 bytes.
Before the strip step and the removal of the Project directory
and the ABI descriptor,
the same build was 20,215,969 bytes, with a 6,899,635-byte zip.
For imcp-0.1.0, which had no strip step,
the framework was 20,204,833 bytes with this profile
and 24,167,473 bytes with the same build and no feature tags.
These sizes are the sums of the regular files in the framework bundle.

To change the profile, edit the `--add` list in the header of
`swift/imcp-feature-tags.txt`, then regenerate the list
at the pinned `tailscale.com` version:

```sh
go run tailscale.com/cmd/featuretags --min \
  --add=netstack,ipnbus,serve,udptransport,nattraversal,portmapper,tailnetlock,health \
  | tr , '\n'
```

## Use the package

Add the package from `https://github.com/mattt/libtailscale`
at the release tag, such as `0.2.0-imcp.1`.
A consumer must meet these requirements:

- Build with Swift 6.4 or later (Xcode 27.1).
  The framework contains only a `.swiftinterface`, not a binary module,
  and Swift 6.4 generated the interface.
- Target macOS 15.6 or later, on arm64 only.
  The framework has no x86_64 slice.
- Add the framework to the app target with "Embed & Sign".
  The release signs the framework ad hoc;
  embedding re-signs it with the app's identity,
  which notarization requires.

With logtail omitted, tsnet does not upload logs.
It still writes `tailscaled.log.conf`
and empty log buffer (filch) files in the node's state directory.

## Rebuild

Build on an arm64 Mac with Xcode and the Go version in `go.mod`:

```sh
make -C swift imcp
```

The target builds `libtailscale.a` with the feature tags,
`-trimpath`, and `-ldflags="-s -w"`.
It then builds `TailscaleKit.framework` in Release
for macOS 15.6 on arm64 only.
It wraps the framework in `TailscaleKit.xcframework`,
strips debug and local symbols from the binary,
and removes `Modules/TailscaleKit.swiftmodule/Project/`
and the module's `.abi.json` ABI descriptor,
which record local source paths.
It then signs the framework ad hoc and zips the result.
The output is `swift/build/imcp/TailscaleKit.xcframework.zip`.
The target prints the zip's size and its SwiftPM checksum.

The zip contains file timestamps,
so each build has a different checksum.

Go records the commit and whether the tree had changes
in the binary's build information.
Build from a clean tree, so that the build records a commit
and `vcs.modified=false`.
To read them, run `go version -m` on the framework binary.

## Cut a release

The checksum in `Package.swift` depends on the zip,
so the build and the checksum are in different commits:
the binary records the build commit,
and the release tag goes on the next commit,
which changes only `Package.swift` and this file.

1. Commit all code changes, and check that `git status` shows a clean tree.
2. Run `make -C swift imcp`.
3. In `Package.swift`, set `checksum` to the printed checksum,
   and change the release tag in `url` to the new tag, such as `0.2.0-imcp.1`.
4. Commit the change.
5. Tag that commit with the same tag, and push the branch and the tag
   to `fork`.
6. Create a GitHub release for the tag on mattt/libtailscale,
   and attach `swift/build/imcp/TailscaleKit.xcframework.zip`:

   ```sh
   gh release create 0.2.0-imcp.1 --repo mattt/libtailscale \
     swift/build/imcp/TailscaleKit.xcframework.zip
   ```

Upload the same zip that you built in step 2.
If you rebuild, update the checksum again.
