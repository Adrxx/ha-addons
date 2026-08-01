# Adrián's Home Assistant Add-ons

A custom add-on repository for Home Assistant OS.

## Installation

In Home Assistant: **Settings → Add-ons → Add-on Store → ⋮ → Repositories**,
add this repository's URL, then install the add-on from the list that appears.

## Add-ons

### [NordVPN Meshnet](./nordvpn-meshnet)

Joins Home Assistant to your NordVPN Meshnet for remote access, without port
forwarding and without exposing anything to the internet.

Built because the only existing option was an unmaintained add-on that required
`full_access: true` and twelve Linux capabilities. This one needs `NET_ADMIN`
and `/dev/net/tun`, which is sufficient: NordVPN 5.x implements WireGuard in
userspace via `libtelio.so` and loads no kernel module.

It is **Meshnet only** — it never runs `nordvpn connect`, so Home Assistant's
own traffic keeps leaving over the LAN and local device discovery is unaffected.

See [the docs](./nordvpn-meshnet/DOCS.md) for options and setup.
