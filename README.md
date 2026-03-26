# os-zapret2

OPNsense plugin for [zapret2](https://github.com/bol-van/zapret2) — a DPI (Deep Packet Inspection) bypass tool for anti-censorship.

Provides a full GUI integration for managing zapret2's `dvtws2` on OPNsense firewalls running FreeBSD 14+.

## What It Does

Many ISPs use DPI to inspect TLS ClientHello packets and block websites based on the SNI (Server Name Indication) field. zapret2 defeats this by manipulating outgoing packets — splitting, faking, or reordering them so the DPI device can't read the SNI, while the destination server reassembles them correctly.

## Features

- **GUI Settings** — Enable/disable, WAN interface selection, DPI desync mode, TTL, ports, custom arguments
- **Multiple Desync Strategies** — fake, multisplit, fakedsplit, fakeddisorder, syndata, hopbyhop, destopt, ipfrag1
- **Fooling Methods** — badsum, badseq, md5sig, datanoack
- **Domain Hostlist** — Apply bypass to all traffic or only specific domains
- **Diagnostics Page** — Test domain connectivity and run blockcheck2 to find the best strategy for your ISP
- **Service Management** — Start/stop/restart from the GUI with status indicator
- **Safe ipfw Integration** — Coexists with OPNsense's pf firewall; ipfw loaded as module with default-allow policy

## Requirements

- OPNsense 26.1 or later (FreeBSD 14.x)
- WAN interface (PPPoE, DHCP, static — any type)
- `luajit` package (auto-installed as dependency)

## Installation

### Method 1: Install from Release

```sh
# On the OPNsense firewall (via SSH)

# Download the latest release
fetch -o /tmp/os-zapret2.pkg https://github.com/ugorur/os-zapret2/releases/latest/download/os-zapret2-1.0.0.pkg

# Extract to OPNsense directories
cd /tmp && tar -xJf os-zapret2.pkg -C /usr/local

# Set permissions
chmod +x /usr/local/opnsense/scripts/OPNsense/Zapret/*.sh
chmod +x /usr/local/opnsense/scripts/OPNsense/Zapret/rc.d/zapret

# Download and compile zapret2
/usr/local/opnsense/scripts/OPNsense/Zapret/setup.sh

# Restart configd to register the plugin
service configd restart
```

Then navigate to **Services > Zapret DPI Bypass** in the GUI.

### Method 2: Install from Source

```sh
# On the OPNsense firewall (via SSH)
cd /tmp
git clone https://github.com/ugorur/os-zapret2.git
cd os-zapret2

# Copy plugin files to OPNsense
cp -r src/opnsense/* /usr/local/opnsense/

# Set permissions
chmod +x /usr/local/opnsense/scripts/OPNsense/Zapret/*.sh
chmod +x /usr/local/opnsense/scripts/OPNsense/Zapret/rc.d/zapret

# Download and compile zapret2
/usr/local/opnsense/scripts/OPNsense/Zapret/setup.sh

# Restart configd to register the plugin
service configd restart
```

## Quick Start

1. Run `blockcheck2.sh` via SSH to find working strategies for your ISP (see [Finding the Right Strategy](#finding-the-right-strategy))
2. Go to **Services > Zapret DPI Bypass > Settings**
3. Check **Enable** and select your **WAN Interface**
4. Paste the HTTP strategy from blockcheck2 results into the **HTTP Strategy** field
5. Paste the HTTPS strategy into the **HTTPS Strategy** field
6. Click **Save** then **Start**
7. Test: Go to **Diagnostics** tab, enter a blocked domain, click **Test**

## Finding the Right Strategy

Every ISP's DPI is different. Use the **Diagnostics > Blockcheck** feature to test which strategy works for your connection:

1. Go to **Services > Zapret DPI Bypass > Diagnostics**
2. Enter a domain that is known to be blocked on your network
3. Click **Run** — blockcheck2 will test multiple strategies and report which ones work
4. Apply the recommended settings on the **Settings** page

## How It Works

```
Client → [pf firewall] → [ipfw divert] → dvtws2 → [pf firewall] → ISP → Internet
                              ↓
                    Modifies TLS ClientHello
                    (splits/fakes SNI field)
```

1. ipfw rules divert outbound HTTPS traffic to a divert socket
2. `dvtws2` intercepts packets and applies the configured DPI desync strategy
3. Modified packets pass through pf and reach the ISP
4. The ISP's DPI can no longer read the SNI, so the connection is not blocked
5. The destination server reassembles packets normally

## Safety

- **ipfw coexists with pf** — ipfw is loaded as a kernel module with default-allow policy, so it doesn't interfere with OPNsense's firewall rules
- **Only port 443 (HTTPS) on WAN is affected** — LAN traffic, DNS, VPN, and other services are untouched
- **Easy rollback** — Stop the service from GUI, or `kldunload ipfw` from SSH, or simply reboot
- **No DNS changes needed** — works at the packet level, independent of your DNS configuration

## License

MIT License — same as [zapret2](https://github.com/bol-van/zapret2)

## Credits

- [bol-van/zapret2](https://github.com/bol-van/zapret2) — the underlying DPI bypass tool
- [OPNsense](https://opnsense.org/) — the firewall platform
