# os-zapret2

OPNsense plugin for [zapret2](https://github.com/bol-van/zapret2) — DPI bypass for anti-censorship.

GUI-managed, fail-open, supervised, works on both bare-metal OPNsense and virtualized OPNsense (Proxmox/ESXi/Hyper-V).

## What it does

Many ISPs use Deep Packet Inspection (DPI) to read the SNI field in TLS ClientHello packets and block specific websites. zapret2 defeats this by manipulating outgoing TLS handshakes so the DPI device can't read the SNI, while the destination server still reassembles the connection correctly.

This plugin packages [bol-van/zapret2](https://github.com/bol-van/zapret2) into an OPNsense service with:
- A real `pkg add`-installable package that registers under **Firmware → Plugins**.
- Settings page under **Services → Zapret DPI Bypass**.
- Diagnostics page that runs upstream's `blockcheck2` for you and shows winning strategies for your ISP.
- Auto-start on every reboot once Enable is checked.
- `daemon -r` supervision so a dvtws2 crash auto-restarts within ~1 second.
- A safety watchdog that auto-stops the service if a misconfigured strategy starts breaking general HTTPS — your household internet recovers in ~3 minutes without anyone touching anything.
- **`pf divert-to` packet interception** (not `ipfw divert`) — works on virtualized OPNsense (Proxmox/virtio) where the ipfw approach infinite-loops, AND fail-opens if dvtws2 dies (traffic just passes through without bypass instead of being dropped).

## Requirements

- OPNsense 26.1 or later (FreeBSD 14.x).
- Any WAN type — PPPoE, DHCP, static, all work.
- The plugin's `setup.sh` will install `luajit`, `jq`, `git-lite`, `pkgconf` from FreeBSD's main repo and compile `dvtws2`. Internet access required for the one-time setup.

## Installation

Releases ship as a real FreeBSD `.pkg`. Install with `pkg add` — OPNsense registers it like any other plugin.

```sh
# On the OPNsense firewall (SSH as root)

fetch -o /tmp/os-zapret2.pkg \
    https://github.com/ugorur/os-zapret2/releases/latest/download/os-zapret2-1.6.pkg
# (the asset filename uses the Makefile PLUGIN_VERSION (1.6), not the tag (v1.6.0))

pkg add /tmp/os-zapret2.pkg

# Bootstrap dependencies and compile dvtws2 (~1 minute, one-time)
/usr/local/opnsense/scripts/OPNsense/Zapret/setup.sh
```

> **Why `setup.sh` instead of dependencies?** OPNsense's pkg repository doesn't carry `luajit` / `jq` (those live in FreeBSD's main repo, which OPNsense ships disabled by default). `setup.sh` enables that repo for the duration of the install, fetches the deps, then restores the original repo state. The `.pkg` itself stays clean and rapid to install.

After setup, navigate to **Services → Zapret DPI Bypass → Settings** in the GUI.

Verify the install:

```sh
pkg info os-zapret2
```

The plugin will also appear in **Firmware → Plugins** (as `os-zapret2`) and **System → Services** (as `Zapret2 DPI Bypass`) with start/stop controls.

### Uninstall

```sh
pkg delete os-zapret2
```

`+PRE_DEINSTALL` cleanly stops the service and removes pf rules before files are deleted. Saved settings in `config.xml` are preserved — reinstalling later picks them up.

### Build from source

```sh
# On a FreeBSD 14 host (or in a FreeBSD VM — CI uses vmactions/freebsd-vm)
git clone https://github.com/ugorur/os-zapret2.git
cd os-zapret2
pkg install -y jq
sh scripts/build-pkg.sh
# Output: dist/os-zapret2-<version>.pkg
```

## Quick start

1. **Services → Zapret DPI Bypass → Diagnostics → Blockcheck.** Enter a domain that's blocked on your ISP (e.g., `rutracker.org`, or any site you can't reach). Click **Run**. Wait 1–3 minutes — the plugin runs upstream's `blockcheck2` against ~50 strategies and reports the winning ones.
2. Copy the strategy with a working result.
3. **Services → Zapret DPI Bypass → Settings.** Tick **Enable**, pick your **WAN Interface** from the dropdown, paste the winning strategy into **HTTPS Strategy**, click **Save & Apply**.
4. Test the same blocked domain from a LAN device — should now load.

## How it works

```
LAN client ──► OPNsense (pf divert-to) ──► dvtws2 (manipulates TLS ClientHello) ──► WAN ──► ISP DPI ──► destination
```

1. A pf rule in the plugin's private anchor (`userrules/zapret`) matches outbound traffic to the configured ports (default 80, 443) on the WAN interface and diverts it to a local divert socket on `127.0.0.1:989`.
2. `dvtws2` reads the diverted packets, applies the LUA-driven desync strategy you configured, and reinjects.
3. pf's stateful divert-to handling re-injects past the divert rule (no infinite loop).
4. Reinjected packets go out the WAN. The ISP's DPI sees a TLS ClientHello it can't parse, so it doesn't match the blocklist.
5. The destination server's TLS stack is more lenient than the DPI's, so it reassembles the modified packets and the connection completes normally.

The plugin's anchor survives `pfctl -f` reloads (i.e. OPNsense saves), so the divert rule stays installed across config changes.

## Safety

- **Fail-open under listener death.** If dvtws2 crashes, pf's divert-to skips the divert (instead of dropping packets like ipfw would). Internet keeps working without bypass.
- **`daemon -r` supervision.** Even if dvtws2 dies, it auto-restarts within ~1 second.
- **Watchdog auto-stop.** Every minute, a watchdog probes `https://example.com` through the bypass. If 3 consecutive checks fail (= a misconfigured strategy is breaking general HTTPS), the watchdog calls `configctl zapret stop` itself. Internet recovers in ~3 minutes; check `tail /var/log/messages | grep zapret-watchdog` for the reason. Override the probe URL via `/usr/local/etc/zapret2/watchdog.conf` (`CONTROL_URL=https://...`).
- **No DNS changes required.** The plugin operates at the packet level; your DNS configuration is independent. (For ISP DNS poisoning, pair this with AdGuard/Unbound DoH, which OPNsense supports natively.)
- **WAN-only.** The pf rule is scoped to outbound on the WAN device; LAN-to-LAN traffic and other interfaces are untouched.

## Troubleshooting

**General HTTPS broke after I clicked Save.** The strategy you picked is too aggressive. Wait ~3 minutes for the watchdog to auto-stop the service, OR click **Stop** in the GUI manually. Re-run **Diagnostics → Blockcheck** to find a milder strategy.

**Bypass works for me on the firewall but not from LAN devices.** That used to be a thing with the old ipfw architecture; the current pf divert-to handles forwarded LAN traffic identically. If you still see this, check that **Host List Mode** is `All traffic on configured ports` (not `Only specific domains` with an empty domain list).

**Service won't start — "dvtws2 child failed to start".** Run `setup.sh` again — the binary may not have compiled. Check `ls /usr/local/etc/zapret2/binaries/my/dvtws2`. If missing, `cd /usr/local/etc/zapret2 && make`.

**Bypass auto-stops repeatedly.** The watchdog is doing its job — your strategy is dropping general HTTPS. Either find a different strategy via Blockcheck or switch **Host List Mode** to `Only specific domains` and list just the censored sites.

## License

MIT — same as [bol-van/zapret2](https://github.com/bol-van/zapret2).

## Credits

- [bol-van/zapret2](https://github.com/bol-van/zapret2) — the underlying DPI bypass tool and lua strategy engine.
- [OPNsense](https://opnsense.org/) — the firewall platform.
