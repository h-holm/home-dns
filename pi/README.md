# The Raspberry Pi Pi-hole (primary DNS)

The Pi is the primary DNS: a native Pi-hole install with its own unbound (recursive resolver) on
`127.0.0.1#5335`. The replica on the Mac is a copy of it (see the top-level README). **The Pi is the
source of truth:** change lists, allow/deny entries and local DNS records there, and nebula-sync copies
them to the replica within the hour.

Tested with: Raspberry Pi 4 Model B, Raspberry Pi OS Lite 64-bit (Debian 13 "trixie"), Pi-hole v6.

| File | What |
|---|---|
| `unbound/pi-hole.conf` | unbound config from [Pi-hole's unbound guide](https://docs.pi-hole.net/guides/dns/unbound/): `127.0.0.1:5335`, IPv4 only, DNSSEC hardening, `edns-buffer-size 1232`, prefetch, private ranges. Installed by `scripts/bootstrap-pi.sh`. |
| `unbound/remote-control.conf`, `unbound/root-auto-trust-anchor-file.conf` | For reference: these come with Debian's unbound package. |
| `../scripts/bootstrap-pi.sh` | Sets up a fresh Pi (see below). |
| `../local/pi/config-export.json` | The Pi's non-secret settings (lists, domains, groups, clients, DNS section). In your private overlay, not here; see `examples/` for the format. |

## Setup

- **unbound:** Debian's package with `unbound/pi-hole.conf`, logging to `/var/log/unbound/unbound.log`.
  DNSSEC validation: `dig dnssec-failed.org @127.0.0.1 -p 5335` → `SERVFAIL`.
- **Pi-hole:** upstream `127.0.0.1#5335` only. Re-downloads its blocklists weekly.
- **Automatic updates:** `unattended-upgrades` with Debian's defaults: security updates and stable point
  releases, **no automatic reboot**. Not covered: Raspberry Pi's own sources (kernel, firmware) and
  Pi-hole itself; those come with a manual `sudo apt full-upgrade` (then reboot) and `pihole -up`.
  Log: `/var/log/unattended-upgrades/`. Check: `apt-config dump | grep -i periodic` →
  `Unattended-Upgrade "1"`; `sudo unattended-upgrade --dry-run -d` shows what the next run would install.
- **Fixed address:** a DHCP reservation in the router (`PI_IP` in `.env`).

## Local DNS records

Names that the Pi-holes answer for the home network. Add and change them **on the Pi** (web UI → Settings →
Local DNS Records); nebula-sync copies them to the replica within the hour (records added only on the
replica get overwritten). Then run `scripts/export-pi-config.sh` and commit in `local/`.

- **One A record per machine** ("DNS records"). Every service on that machine gets a **CNAME** pointing
  to it ("Local CNAME records"), so an IP change is one edit. For example:

  | Name | Type | Points to |
  |---|---|---|
  | `nas` | A | `192.168.1.10` |
  | `photos.home` | CNAME | `nas` |
  | `wiki.home` | CNAME | `nas` |

  With a reverse proxy on that machine (port 80), each name reaches the right app.
- `expandHosts` is off, so a name resolves as written (`nas`, not `nas.lan`).
- Avoid the `.local` suffix: Apple devices use it for Bonjour. Bare names, `home.arpa`, or your router's
  search domain (then the short form, e.g. `http://photos/`, works too) are safe.
- Keep the list of what each name is for in your private notes (`local/`), next to the export.

## Updating

Pi-hole: see the top-level README, "Updating Pi-hole" (replica first with the matching `pihole/pihole`
image, then `sudo pihole -up` on the Pi, then compare). OS and unbound:
`sudo apt update && sudo apt full-upgrade`.

## Rebuilding the Pi

The replica keeps DNS running for the whole house in the meantime.

**Fastest: a full SD-card image.** If you make regular images of the card, writing the newest one to a
new card brings back the whole Pi with nothing to set up. Otherwise:

1. **OS:** flash Raspberry Pi OS Lite (64-bit) with Raspberry Pi Imager. In its settings: hostname, your
   user, SSH on. Give the Pi its fixed address again (the DHCP reservation in the router uses the MAC
   address, so a new board needs an updated reservation).
2. **Bootstrap**, on the Pi:
   ```sh
   sudo apt-get install -y git
   git clone https://github.com/h-holm/home-dns.git && cd home-dns
   sudo scripts/bootstrap-pi.sh
   ```
   It enables unattended upgrades, installs and tests unbound (resolution and DNSSEC), installs Pi-hole
   unattended with unbound as its only upstream, and asks for the web password. Use the same one as
   `PI_PRIMARY_PASSWORD` in the replica's `.env` (or update `.env`). Safe to rerun.
3. **Restore the settings**, from the Mac:
   ```sh
   scripts/apply-pi-config.sh          # dry run: what it would add or change
   scripts/apply-pi-config.sh --apply  # lists, allow/deny entries, groups, clients, local records, DNS settings
   ```
   It rebuilds gravity when it added lists. (Alternative: web UI → Settings → Teleporter → import a
   `pi-teleporter-*.zip` from `BACKUP_DIR`, then `pihole -g`.)
4. **Check:** `pihole status`; from the Mac, `scripts/apply-pi-config.sh` reports "Nothing to change", and
   `dig @<PI_IP> doubleclick.net` → `0.0.0.0`. nebula-sync and pi-monitor need no changes: they find the Pi
   at the same address.

### By hand (if the script doesn't fit a newer OS)

- `sudo apt install unattended-upgrades && sudo dpkg-reconfigure -plow unattended-upgrades` (Yes).
- `sudo apt install unbound`; copy `unbound/pi-hole.conf` to `/etc/unbound/unbound.conf.d/`; create the log file:
  `sudo mkdir -p /var/log/unbound && sudo touch /var/log/unbound/unbound.log && sudo chown unbound /var/log/unbound/unbound.log`;
  `sudo systemctl restart unbound`; test with `dig pi-hole.net @127.0.0.1 -p 5335` (an answer) and
  `dig dnssec-failed.org @127.0.0.1 -p 5335` (SERVFAIL). Compare with
  [Pi-hole's unbound guide](https://docs.pi-hole.net/guides/dns/unbound/) if something differs.
- `curl -sSL https://install.pi-hole.net | bash` (upstream: anything, the restore sets it), then
  `sudo pihole setpassword`.
- Continue with step 3 above.
