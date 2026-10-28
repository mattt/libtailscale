# TailscaleKit for iMCP

The `mattt/imcp` branch of [mattt/libtailscale](https://github.com/mattt/libtailscale)
builds a pinned, trimmed TailscaleKit for iMCP,
a sandboxed macOS menu bar app.
iMCP uses it as a Swift Package Manager binary target
through the `Package.swift` file at the root of this repository.
This branch is not an upstream pull request.

## Changes from upstream

The branch starts at `d1dc45d` on `tailscale/libtailscale` `main`
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
- `IncomingConnection.send(_:)` sends data to the peer
  of an accepted connection.
- `LocalAPIClient.logout()` is public.
- `IpnState.PeerStatus` decodes `UserID`.
- `go.mod` replaces `tailscale.com` with a fork of v1.104.1
  that adds `client/local/cert_omit.go`.
  Without that file, tsnet does not compile with `ts_omit_acme`.
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

For imcp-0.1.0, the signed framework is 20,204,833 bytes with this profile
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
signs the framework ad hoc, and zips the result.
The output is `swift/build/imcp/TailscaleKit.xcframework.zip`.
The target prints the zip's size and its SwiftPM checksum.

The zip contains file timestamps,
so each build has a different checksum.

## Cut a release

1. Run `make -C swift imcp`.
2. In `Package.swift`, set `checksum` to the printed checksum,
   and change the release tag in `url` to the new tag, such as `imcp-0.2.0`.
3. Commit the change.
4. Tag that commit with the same tag, and push the branch and the tag
   to `fork`.
5. Create a GitHub release for the tag on mattt/libtailscale,
   and attach `swift/build/imcp/TailscaleKit.xcframework.zip`:

   ```sh
   gh release create imcp-0.2.0 --repo mattt/libtailscale \
     swift/build/imcp/TailscaleKit.xcframework.zip
   ```

Upload the same zip that you built in step 1.
If you rebuild, update the checksum again.
