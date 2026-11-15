#!/usr/bin/env bash
# Set up the primary Pi-hole on a freshly flashed Raspberry Pi: automatic
# security updates, unbound (recursive resolver on 127.0.0.1#5335) and
# Pi-hole using it. Safe to run again: every step checks first.
#
# On the Pi (Raspberry Pi OS Lite 64-bit / Debian, fixed IP, SSH on):
#   sudo apt-get install -y git
#   git clone https://github.com/h-holm/home-dns.git && cd home-dns
#   sudo scripts/bootstrap-pi.sh
# Then, from the replica host: scripts/apply-pi-config.sh (dry run, then --apply)
# to restore lists, allow/deny entries and local DNS records.
#
# Environment: PIHOLE_INTERFACE (default: the interface of the default route).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UNBOUND_CONF=/etc/unbound/unbound.conf.d/pi-hole.conf
UNBOUND_LOG=/var/log/unbound/unbound.log
UPSTREAM='127.0.0.1#5335'

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root: sudo $0"
command -v apt-get >/dev/null || die "this script expects Debian / Raspberry Pi OS"
[[ -f "$REPO_DIR/pi/unbound/pi-hole.conf" ]] || die "run it from a clone of the repo"

step "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq unattended-upgrades unbound bind9-dnsutils curl >/dev/null
ok "unattended-upgrades, unbound, dig, curl"

step "Automatic security updates (Debian's defaults, no automatic reboot)"
# The same file `dpkg-reconfigure -plow unattended-upgrades` writes.
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
apt-config dump | grep -q 'APT::Periodic::Unattended-Upgrade "1"' || die "unattended-upgrades not enabled"
ok "enabled (log: /var/log/unattended-upgrades/)"

step "unbound on $UPSTREAM"
install -m 644 "$REPO_DIR/pi/unbound/pi-hole.conf" "$UNBOUND_CONF"
install -d -o unbound -g unbound -m 755 "$(dirname "$UNBOUND_LOG")"
[[ -f $UNBOUND_LOG ]] || install -o unbound -g unbound -m 644 /dev/null "$UNBOUND_LOG"
# Pi-hole's unbound guide: on Debian, unbound-resolvconf would point the system
# resolver at unbound directly, bypassing Pi-hole. Turn it off if present.
if systemctl is-enabled --quiet unbound-resolvconf.service 2>/dev/null; then
  systemctl disable --now unbound-resolvconf.service
  ok "unbound-resolvconf disabled"
fi
# The trust anchor normally appears when the service first starts; make sure
# it's there before checking the config (what the systemd unit itself runs).
[[ -f /var/lib/unbound/root.key ]] || /usr/libexec/unbound-helper root_trust_anchor_update
unbound-checkconf >/dev/null
systemctl enable --quiet unbound
systemctl restart unbound
for _ in 1 2 3 4 5; do dig +short +time=3 pi-hole.net @127.0.0.1 -p 5335 | grep -q . && break; sleep 2; done
dig +short +time=5 pi-hole.net @127.0.0.1 -p 5335 | grep -q . || die "unbound doesn't resolve pi-hole.net"
ok "resolves pi-hole.net"
dig +time=5 dnssec-failed.org @127.0.0.1 -p 5335 | grep -q 'status: SERVFAIL' \
  || die "DNSSEC validation not working (dnssec-failed.org should be SERVFAIL)"
ok "DNSSEC validation (dnssec-failed.org → SERVFAIL)"

step "Pi-hole"
if command -v pihole >/dev/null; then
  ok "already installed ($(pihole -v | tr '\n' ' '))"
else
  iface="${PIHOLE_INTERFACE:-$(ip -o -4 route show default | awk '{print $5; exit}')}"
  [[ -n $iface ]] || die "no default route; set PIHOLE_INTERFACE"
  # The installer only runs without dialogs when a config already exists, so
  # preseed the two settings that matter; FTL fills in the defaults.
  install -d -m 755 /etc/pihole
  cat >/etc/pihole/pihole.toml <<EOF
[dns]
  upstreams = ["$UPSTREAM"]
  interface = "$iface"
EOF
  curl -fsSL https://install.pi-hole.net | bash /dev/stdin --unattended
  ok "installed on $iface"
fi
pihole-FTL --config dns.upstreams | grep -qF "$UPSTREAM" || {
  pihole-FTL --config dns.upstreams "[\"$UPSTREAM\"]" >/dev/null
  ok "upstream set to $UPSTREAM"
}

step "Web/API password"
if [[ -n "$(pihole-FTL --config webserver.api.pwhash 2>/dev/null)" ]]; then
  ok "already set (change it with: sudo pihole setpassword)"
else
  echo "    Use the same one as PI_PRIMARY_PASSWORD in the replica's .env."
  pihole setpassword
fi

step "Checks"
pihole status
dig +short +time=5 pi-hole.net @127.0.0.1 | grep -q . || die "Pi-hole doesn't resolve"
ok "Pi-hole resolves through unbound"

cat <<EOF

Done. Next, from the replica host (the Mac):
  scripts/apply-pi-config.sh           # dry run: shows what it would restore
  scripts/apply-pi-config.sh --apply   # lists, allow/deny entries, local DNS records
EOF
