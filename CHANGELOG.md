# Changelog

All notable changes to os-zapret2 are documented in this file.

## Unreleased

### Fixed

- **"Auto-detect blocked domains" never detected anything** (#12). The service
  diverted only outgoing packets, so dvtws2 never saw the RSTs an ISP injects
  for blocked sites, nor the SYN-ACKs autottl relies on. It now also diverts
  SYN-ACK, FIN and RST replies for the TCP ports on their way to the LAN.
  Upstream's inbound rule is not usable on OPNsense: pf strips ipfw's divert
  tag from reinjected packets, which loops or drops them. The extra rule
  lowers the limit from 11 to 10 TCP ports (9 with QUIC).

## v1.8.3 - 2026-08-10

Most of this release was contributed by [apfilipp](https://github.com/apfilipp).

### Added

- **Asynchronous Blockcheck diagnostics** with live progress, persistent logs,
  explicit stop support, and single-job locking. The configured Zapret service
  is suspended only for the scan and restored afterward.
- **HTTP/3 / QUIC strategy discovery** backed by a bundled private HTTP/3 curl,
  so QUIC checks do not depend on the capabilities of OPNsense's system curl.
- **Per-strategy HTTPS stability test** in Diagnostics. An administrator can
  paste dvtws2 arguments (or leave the field empty to test direct connectivity
  without bypass), resolve every IPv4 address for a domain, and run ten requests
  against each address. The test uses an isolated temporary dvtws2 instance
  and a target-specific ipfw rule, reports compact per-address success counts,
  writes a persistent log under `/var/log/zapret`, and leaves the
  configured service and its firewall rules unchanged. The UI explicitly
  identifies this as a firewall-originated test rather than a LAN-path test.

### Fixed

- **Blockcheck lifecycle and firewall safety.** Concurrent starts are rejected,
  elapsed time freezes after stop, required upstream patch targets are
  validated, firewall setup fails closed, and domain/timeout guards are
  preserved when refreshing the bundled upstream script.
- **Blockcheck result validation.** Only confirmed packet-test successes are
  accepted, malformed results are rejected, and winning strategies are parsed
  without treating headings or unrelated output as usable configurations.
- **Service restoration.** A running Zapret instance is restored after a scan,
  and its firewall state is repaired after WAN address renewal.
- **Package installation no longer leaves `configd` stopped.** The post-install
  hook reloads the existing configd worker under its persistent supervisor
  instead of restarting the whole daemon inside the pkg transaction. Plugin
  configuration is also refreshed after uninstall.
- **Diagnostics failures are visible.** Domain checks preserve failure output
  and now show an explicit backend/configd error instead of clearing the result
  field when no response is returned.
- **QUIC hostlist handling** now follows upstream zapret semantics.
- Invalid `zapret_service.sh` subcommands exit non-zero again instead of
  reporting success.

### Changed

- **dvtws2 is now explicitly scoped with `--filter-tcp=<ports>`.** Previously
  the daemon applied its strategy to everything the ipfw divert rules handed
  it; the TCP profile is now bound to the configured Ports value so the new
  QUIC profile can be attached as a separate `--new` profile. Behavior is
  unchanged for the default `80,443`, but anyone relying on dvtws2 processing
  traffic beyond the configured ports should re-check their setup.
- **QUIC ipfw rules are only installed when a QUIC strategy is set.** Leaving
  the QUIC Strategy field empty reproduces the pre-1.8.3 rule set exactly.
- **The bundled HTTP/3 client is fetched from the FreeBSD `latest` repository
  at build time**, so its version is not pinned. The resolved version is now
  printed during the build and recorded in
  `/usr/local/libexec/zapret2/curl-h3/VERSION`.

## v1.8.2 - 2026-07-28

### Fixed

- **Source Networks silently disabled the bypass entirely** (regression in
  v1.8.0, affects v1.8.0 and v1.8.1). The rule builder appended ipfw's `me`
  keyword to the source address list (`from 10.0.30.0/24,me`), but `me` is a
  standalone keyword that ipfw refuses inside a comma-separated list — it
  rejects the rule with `hostname "me" unknown`. Because the install used
  `ipfw -qf add`, the parse error was suppressed, so **no divert rules were
  installed at all** while the service still reported "running". Anyone who
  set Source Networks got no DPI bypass and no error.

  The firewall's own traffic now gets a separate rule per port sharing the
  same rule number (ipfw permits duplicate numbers, and `ipfw delete N` still
  removes every rule with that number), and a failed rule install is reported
  on stderr instead of swallowed. Verified live on OPNsense 26.1 / FreeBSD 14
  with Source Networks set to a single LAN: client traffic diverts, other
  networks pass through untouched, and the watchdog's firewall-originated
  control probe still exercises the bypass path.

## v1.8.1 - 2026-07-28

### Fixed

- **`setup.sh` works on OPNsense 26.7+/27, which ships no FreeBSD repo
  definition at all** (issue #4, follow-up). The script used to write a bare
  `FreeBSD: { enabled: yes }` override and rely on the base definition in
  `/etc/pkg/FreeBSD.conf` for the URL; on newer OPNsense that base file is
  gone, so the merged repo had no URL and pkg failed with "No repositories
  are enabled." The override now carries the complete stock repo definition
  (URL, srv mirror, signature fingerprints). When no override file exists,
  a temporary one is created and deleted again on exit — a marker comment
  lets a later run clean up leftovers from a crashed run.

## v1.8.0 - 2026-07-28

### Added

- **Source Networks setting** (General Settings). Optionally limit the DPI
  bypass to traffic coming from specific IPv4 networks or hosts (e.g. a single
  LAN subnet like `192.168.1.0/24`, or one device). Empty keeps the previous
  behavior of intercepting all traffic leaving the WAN. Matching happens on the
  pre-NAT source address — ipfw is hooked ahead of pf's NAT on the outbound
  chain, so the LAN client's real address is visible to the divert rule. When
  the setting is used, `me` is appended to the ipfw source list so the safety
  watchdog's firewall-originated control probe still exercises the bypass path.
- **FreeBSD 15 / OPNsense 26.7+ packages** (issue #5). pkg refuses to install
  a package across FreeBSD major versions, and OPNsense 26.7 moved to a
  FreeBSD 15 core, so the previously shipped FreeBSD:14 build failed there
  with `wrong architecture: FreeBSD:14:amd64 instead of FreeBSD:15:amd64`.
  CI and releases now build one package per major — `os-zapret2-<ver>-freebsd14.pkg`
  (OPNsense 26.1–26.4) and `os-zapret2-<ver>-freebsd15.pkg` (OPNsense 26.7+).

### Fixed

- **`setup.sh` no longer dies silently when the FreeBSD catalog refresh
  fails** (issue #4). The refresh now targets only the temporarily enabled
  FreeBSD repo (`pkg update -r FreeBSD`), and on failure prints the local pkg
  ABI and kernel version plus a hint to check `/usr/local/etc/pkg.conf` for a
  stale ABI override — the usual cause of pkg rejecting the catalog with
  "repository FreeBSD contains packages for wrong OS version".

## v1.7.2 - 2026-06-25

### Fixed

- **Diverted traffic no longer dropped by pf (the bypass now actually works
  end-to-end).** `configure_ipfw_reinject()` enabled ipfw *after* the
  `pfctl -d; pfctl -e` bounce, which left ipfw registered *behind* pf on the
  outbound IPv4 pfil chain. pf then built no state for dvtws2's reinjected
  packets and dropped the server's return traffic, so even general HTTPS hung
  whenever the service was active. The enable now runs *before* the pf bounce,
  so pf re-registers behind ipfw (`ipfw:default` → `pf:default-out`) and the
  diverted/desynced flow completes. Verified live on OPNsense 26.1 / FreeBSD 14
  (bare-metal PPPoE): blocked domain bypasses, untouched domains keep working.
- Removed the `net.inet.ip.pfil.outbound=ipfw,pf` ordering sysctls — that OID
  does not exist on FreeBSD 14, so it was a silent no-op. The hook order is now
  achieved purely through enable-then-bounce registration ordering.

### Known limitations

- An OPNsense filter reload triggered by unrelated firewall changes can
  re-register pf ahead of ipfw again, silently disabling the bypass until the
  next `configctl zapret restart` / Save & Apply. A self-healing re-assert is
  planned for a future release.

## v1.7.1 - 2026-06-25

### Fixed

- Service start now explicitly enables the ipfw firewall engine
  (`net.inet.ip.fw.enable=1`) in `configure_ipfw_reinject()`. Previously the
  service only ran `kldload ipfw`, which initialises `fw.enable` to 1 *only* on
  the module's first load. On OPNsense ipfw is commonly already resident (e.g.
  after a Diagnostics → Blockcheck run, which loads ipfw and restores
  `fw.enable=0` on exit), so the load short-circuited and the firewall stayed
  disabled. The divert rules were installed but ipfw evaluated nothing, so no
  traffic was ever diverted to dvtws2 and the bypass silently did nothing.

## v1.7.0 - 2026-06-24

### Changed

- Documented the shipped `ipfw divert` + `--sockarg` architecture and clarified why the plugin uses the upstream zapret pfSense-style packet path.
- Updated package metadata for the `1.7.0` release.

### Fixed

- Hardened `setup.sh` so the FreeBSD package repository is always restored after dependency installation.
- Added recovery for stale FreeBSD repository backup files left by interrupted setup runs.
- Made setup tolerate both `git-lite` and `git` package names when installing zapret build dependencies.
- Kept the plugin install clean by continuing to install external dependencies during setup instead of declaring them as package dependencies.

## v1.6.5_3 - 2026-04-16

### Fixed

- Bumped the package revision so the generated asset name matched the release tag.

## v1.6.5_2 - 2026-04-16

### Changed

- Reverted the runtime packet path to upstream zapret's `ipfw` + divert recipe for better LAN NAT behavior.

## v1.6.5_1 - 2026-04-16

### Changed

- Improved blockcheck fallback summaries, persistent logs, run duration reporting, and pf restore handling.

### Fixed

- Prevented diagnostics from silently falling back to `rutracker.org`.
- Fixed diagnostics shell handling issues.

## v1.6.5 - 2026-04-16

### Fixed

- Parsed blockcheck `SUMMARY` headings and made diagnostics complete cleanly even when blockcheck reports no winning strategy.

## v1.6.4 - 2026-04-16

### Fixed

- Bounded DNS lookup timeouts in `test_domain.sh` and improved no-answer diagnostics.

## v1.6.3 - 2026-04-16

### Fixed

- Increased diagnostics PHP and configd timeouts so longer blockcheck runs can finish.

## v1.6.1 - 2026-04-16

### Changed

- Published a cleaned release after history sanitization.

## v1.1.0 - 2026-03-27

### Added

- Added an exclude domains list to keep selected sites out of DPI bypass handling.

## v1.0.0 - 2026-03-26

### Fixed

- Corrected README install instructions to match the actual package format.
