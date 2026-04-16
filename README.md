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
- **`ipfw divert` + `--sockarg` loop-guard** — matches upstream zapret's pfSense init script. An `ipfw divert` rule with `not diverted not sockarg xmit <wan>` intercepts outbound TCP on the configured ports; dvtws2 is launched with `--sockarg=0x200` so its reinjected packets sail past the rule. Combined with the upstream recipe's `pfctl -d; pfctl -e` pfil-hook reorder, this works on both bare-metal PPPoE and virtualized OPNsense (Proxmox/virtio), for both firewall-local traffic and NAT'd LAN clients. (Earlier `pf divert-to`–based 1.6.x releases broke LAN-NAT'd traffic; v1.6.5_3 reverted to the upstream ipfw recipe.)

## Requirements

- OPNsense 26.1 or later (FreeBSD 14.x).
- Any WAN type — PPPoE, DHCP, static, all work.
- The plugin's `setup.sh` will install `luajit`, `jq`, `git-lite`, `pkgconf` from FreeBSD's main repo and compile `dvtws2`. Internet access required for the one-time setup.

## Installation

Releases ship as a real FreeBSD `.pkg`. Install with `pkg add` — OPNsense registers it like any other plugin.

```sh
# On the OPNsense firewall (SSH as root)

fetch -o /tmp/os-zapret2.pkg \
    https://github.com/ugorur/os-zapret2/releases/latest/download/os-zapret2-1.6.5_3.pkg
# (asset filename tracks PLUGIN_VERSION_PLUGIN_REVISION from Makefile — check the
#  Releases page for the current version if the URL above 404s)

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

`+PRE_DEINSTALL` cleanly stops the service and removes ipfw divert rules before files are deleted. Saved settings in `config.xml` are preserved — reinstalling later picks them up.

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
LAN client ──► OPNsense (ipfw divert) ──► dvtws2 (manipulates TLS ClientHello) ──► WAN ──► ISP DPI ──► destination
```

1. Two `ipfw` divert rules (one per configured port, default 80 and 443) match outbound TCP on the WAN device and divert it to a local divert socket on port `989`. The filter `not diverted not sockarg` skips any packet already tagged by the divert path.
2. `dvtws2` reads the diverted packets, applies the LUA-driven desync strategy you configured, and reinjects — marking its reinjects with `SO_USER_COOKIE=0x200` (via `--sockarg=0x200`) so the `not sockarg` clause above skips them on the way back out.
3. On boot/start the plugin also runs `pfctl -d; pfctl -e` once, so pf re-registers its `pfil` hooks **after** `ipfw` — without this reorder pf would drop the reinjected packets for state mismatch on FreeBSD 13+.
4. Reinjected packets go out the WAN. The ISP's DPI sees a TLS ClientHello it can't parse, so it doesn't match the blocklist.
5. The destination server's TLS stack is more lenient than the DPI's, so it reassembles the modified packets and the connection completes normally.

The `ipfw` rules live in the reserved range 19000-19010 and are reinstalled on every `configctl zapret start`, so a config reload (OPNsense save) rebuilds them cleanly.

## Safety

- **`daemon -r` supervision.** If dvtws2 dies, `daemon(8)` auto-restarts it within ~1 second — only a few in-flight packets get dropped by the unhandled divert socket during the restart window.
- **Watchdog auto-stop.** Every minute, a watchdog probes `https://example.com` through the bypass. If 3 consecutive checks fail (= a misconfigured strategy is breaking general HTTPS, or dvtws2 genuinely won't stay up), the watchdog calls `configctl zapret stop` itself. That removes the `ipfw` divert rules and traffic flows through unbypassed again; full recovery in ~3 minutes without anyone touching anything. Check `tail /var/log/messages | grep zapret-watchdog` for the reason. Override the probe URL via `/usr/local/etc/zapret2/watchdog.conf` (`CONTROL_URL=https://...`).
- **No DNS changes required.** The plugin operates at the packet level; your DNS configuration is independent. (For ISP DNS poisoning, pair this with AdGuard/Unbound DoH, which OPNsense supports natively.)
- **WAN-only.** The `ipfw` rules are scoped with `xmit <wan_dev>`; LAN-to-LAN traffic and other interfaces are untouched.

## Troubleshooting

**General HTTPS broke after I clicked Save.** The strategy you picked is too aggressive. Wait ~3 minutes for the watchdog to auto-stop the service, OR click **Stop** in the GUI manually. Re-run **Diagnostics → Blockcheck** to find a milder strategy.

**Bypass works for me on the firewall but not from LAN devices.** The shipped ipfw-divert architecture (v1.6.5_3+) handles NAT'd LAN traffic identically to firewall-local traffic — if you see this, most likely cause is (a) **Host List Mode** set to `Only specific domains` with the target site not listed, or (b) LAN clients using their own DNS (not the OPNsense resolver) so an upstream DNS-level block is still in effect. Check `ipfw list 19000 19001` on the firewall — if the packet counters increment when you curl the blocked site from the LAN, the divert is firing and the issue is elsewhere.

**Service won't start — "dvtws2 child failed to start".** Run `setup.sh` again — the binary may not have compiled. Check `ls /usr/local/etc/zapret2/binaries/my/dvtws2`. If missing, `cd /usr/local/etc/zapret2 && make`.

**Bypass auto-stops repeatedly.** The watchdog is doing its job — your strategy is dropping general HTTPS. Either find a different strategy via Blockcheck or switch **Host List Mode** to `Only specific domains` and list just the censored sites.

## License

MIT — same as [bol-van/zapret2](https://github.com/bol-van/zapret2).

## Credits

- [bol-van/zapret2](https://github.com/bol-van/zapret2) — the underlying DPI bypass tool and lua strategy engine.
- [OPNsense](https://opnsense.org/) — the firewall platform.
