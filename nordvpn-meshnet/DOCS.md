# NordVPN Meshnet

Joins Home Assistant to your NordVPN Meshnet so you can reach it from a remote
network without exposing it to the internet, without port forwarding, and
without a cloud subscription.

## What it does and does not do

It brings up **Meshnet only**. It never runs `nordvpn connect`, so Home
Assistant's own traffic continues to leave over the LAN exactly as before. That
is deliberate: routing HA through a VPN server would break local discovery of
Govee, LIFX, Matter and similar devices.

It runs with far fewer privileges than is typical for a VPN add-on:
`NET_ADMIN` and `SYS_ADMIN`, plus `/dev/net/tun`. No `full_access`, no
`SYS_MODULE`. Dropping `SYS_MODULE` is possible because NordVPN 5.x ships
`libtelio.so` and implements WireGuard in userspace — verified against
`nordvpn_5.2.0_arm64.deb`, which contains no kernel module and declares no
module dependency.

### Why SYS_ADMIN is needed

For exactly one thing. Enabling Meshnet fails with:

```
setting mesh: setting routing rules: setting rp filter:
sysctl: permission denied on key "net.ipv4.conf.all.rp_filter"
```

The NordVPN client requires `net.ipv4.conf.all.rp_filter=2`, and `/proc/sys`
is mounted read-only in add-on containers. `SYS_ADMIN` lets the add-on remount
it read-write so the client can apply that value.

Because the add-on runs in the host network namespace, **this changes the
host's reverse-path filtering setting**, not just the container's. The add-on
records the previous value and restores it when it stops. Going from the usual
`0` to `2` turns on *loose* reverse-path validation, which is more filtering
than `0`, not less — but it is a host-wide change and you should know about it.

The trade-off of the remount is that, while running, the add-on can write any
sysctl.

`SYS_ADMIN` alone is not enough: Home Assistant's default AppArmor profile
denies `mount(2)`, so the add-on also sets `apparmor: false`. There is no way
around this from inside an add-on — the sysctl cannot be set from any add-on
container, with or without root, so it cannot be pre-set out of band either.
The add-on remains bounded by its two capabilities; it does not use
`full_access`.

## Getting an access token

The CLI cannot use your email and password. You need an *access token*:

1. Sign in at <https://my.nordaccount.com>.
2. Go to **NordVPN → Manual setup → Set up NordVPN manually**.
3. Choose **Generate new token** and copy it.
4. Paste it into this add-on's **Configuration** tab, then start the add-on.

The token is stored in the add-on's options, and the resulting login session is
kept in `/data` so it survives add-on updates and restarts.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `token` | *(empty)* | NordVPN access token. Required. |
| `nickname` | `homeassistant` | Meshnet nickname for this device, giving you `http://<nickname>.nord:8123`. Max 25 characters, no leading or trailing dash. If the name is already taken the device keeps its generated `<name>.nord` hostname. |
| `allow_incoming` | `true` | Let your own Meshnet devices open connections to this one. Turning this off means peers can see the node but cannot reach port 8123. |
| `allow_lan_access` | `false` | Let peers route traffic through this node **and** reach the rest of your LAN through it. Powerful and worth understanding before enabling — see below. |
| `allow_fileshare` | `false` | Allow Meshnet peers to send files to Home Assistant. Off by default; an appliance has no reason to accept file transfers. |
| `nordvpn_firewall` | `false` | Leave off. See "The firewall option" below. |
| `check_interval` | `300` | Seconds between Meshnet health checks. |
| `log_level` | `info` | Set to `debug` to also pass through nordvpnd's own (very verbose) logging. |

### `allow_lan_access`

NordVPN's local-network permission only functions in tandem with traffic
routing, so this option grants **both** to each peer. With it on, a remote
device routing through Home Assistant can reach every other device on your
LAN — including your routers' admin pages. Leave it off unless you specifically
want Home Assistant to act as a gateway into the whole network. To reach only
Home Assistant, `allow_incoming` is sufficient.

### The firewall option

This add-on runs in the host network namespace, which is what makes Home
Assistant reachable at the node's Meshnet address. The consequence is that any
firewall rule NordVPN writes lands in the *host's* netfilter tables, which Home
Assistant OS also manages. The add-on therefore disables NordVPN's firewall by
default and leaves access control to Meshnet's per-peer permissions.

Enable `nordvpn_firewall` only if you understand that trade-off.

## Where to reach Home Assistant

On startup the add-on logs the node's Meshnet IP and nickname, for example:

```
Meshnet is up. Reach Home Assistant from any peer at:
    http://100.85.x.x:8123
    http://homeassistant.nord:8123
```

Both work from any device signed into the same NordVPN account with Meshnet
enabled.

## Ordering constraints (why the startup sequence looks the way it does)

These were established by running the 5.2.0 CLI, not guessed:

- `set killswitch off` fails once the firewall is disabled
  (*"Firewall must be enabled to use 'Kill Switch'"*), so it runs first.
- `set autoconnect off` fails before login (*"You're not logged in"*), so it
  runs after.
- `set analytics off` also resolves the first-run `User Consent: undefined`
  state, which otherwise leaves the client waiting on a prompt nobody can answer.
- Post-quantum encryption is explicitly incompatible with Meshnet, so it is
  forced off before Meshnet is enabled.

## Troubleshooting

**"Login failed or timed out."** The token is wrong, revoked, or the device
limit is reached. Meshnet allows up to 10 devices on one account.

**The add-on starts but no peers are listed.** Peers only appear once they are
signed into the same account with Meshnet enabled. Run `nordvpn meshnet peer
refresh` on the other device.

**"Could not remount /proc/sys read-write."** `apparmor: false` is missing from
`config.yaml`, or the add-on lacks `SYS_ADMIN`. Both are required; see "Why
SYS_ADMIN is needed" above.

**"moose: sqlite connect error", then login hangs forever.** `/var/lib/nordvpn`
has been made a symlink. It must be a real directory — the add-on mirrors it to
`/data` instead. This was the original cause of logins that never completed.

**Home Assistant became unreachable on the LAN.** Stop the add-on. Everything
it changes is either inside the container or a NordVPN setting; it writes no
Home Assistant configuration. `arp-ignore` is explicitly disabled at startup
precisely to avoid altering how the host answers ARP.

## Notes for this network

The Home Assistant Pi is wired, so this add-on is unaffected by the Archer's
11 PM–8 AM wireless schedule. A Meshnet node on Wi-Fi would go dark nightly in
that window; this one does not.
