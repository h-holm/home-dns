#!/usr/bin/env bash
# Export the primary Pi-hole's configuration, read-only via its API.
#
#   scripts/export-pi-config.sh               write local/pi/config-export.json
#   scripts/export-pi-config.sh --teleporter  also save a Teleporter archive to $BACKUP_DIR
#
# The JSON holds only non-secret settings: versions, the DNS config section,
# blocklists, allow/deny entries, groups, clients. Counters that change on
# every gravity run (number of domains, status, last update) are left out, so
# `git diff` in local/ shows only real changes. It describes your network
# (local DNS records), so it goes into your private overlay (local/), not into
# this repo. scripts/apply-pi-config.sh restores a Pi-hole from it.
# The Teleporter archive contains secrets (password hash), so it never goes
# into any git repo.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_DIR/local/pi/config-export.json"

[[ -f "$REPO_DIR/.env" ]] || { echo "ERROR: $REPO_DIR/.env is missing (see .env.example)" >&2; exit 1; }
[[ -d "$REPO_DIR/local" ]] || {
  echo "ERROR: $REPO_DIR/local/ is missing. Clone your private overlay repo there (see README)." >&2
  exit 1
}

# Read only what's needed from .env, without printing the password.
# shellcheck source=/dev/null
env_get() { (set -a; source "$REPO_DIR/.env"; printf '%s' "${!1:-}"); }
PI_IP="$(env_get PI_IP)"
BACKUP_DIR="$(env_get BACKUP_DIR)"
[[ -n "$PI_IP" ]] || { echo "ERROR: set PI_IP in .env" >&2; exit 1; }
PI="http://$PI_IP"
PI_PRIMARY_PASSWORD="$(env_get PI_PRIMARY_PASSWORD)"

sid="$(jq -n --arg p "$PI_PRIMARY_PASSWORD" '{password: $p}' \
  | curl -fsS -m 10 -X POST -H 'Content-Type: application/json' --data @- "$PI/api/auth" \
  | jq -r '.session.sid // empty')"
unset PI_PRIMARY_PASSWORD
[[ -n "$sid" ]] || { echo "ERROR: login to $PI failed" >&2; exit 1; }
# Always close the session, even on errors (Pi-hole limits the number of sessions).
trap 'curl -sS -m 10 -o /dev/null -X DELETE -H "X-FTL-SID: $sid" "$PI/api/auth" || true' EXIT

get() { curl -fsS -m 30 -H "X-FTL-SID: $sid" "$PI/api$1"; }

mkdir -p "$(dirname "$OUT")"
jq -n -S \
  --argjson version "$(get /info/version)" \
  --argjson dns     "$(get /config/dns)" \
  --argjson lists   "$(get /lists)" \
  --argjson domains "$(get /domains)" \
  --argjson groups  "$(get /groups)" \
  --argjson clients "$(get /clients)" \
  '{
    pihole_version: ($version.version | {core: .core.local.version, web: .web.local.version, ftl: .ftl.local.version}),
    dns: $dns.config.dns,
    lists: [$lists.lists[] | del(.number, .invalid_domains, .abp_entries, .status, .date_updated)] | sort_by(.id),
    domains: [$domains.domains[]] | sort_by(.id),
    groups: [$groups.groups[]] | sort_by(.id),
    clients: [$clients.clients[]] | sort_by(.id)
  }' > "$OUT"
echo "Wrote $OUT"
if git -C "$REPO_DIR/local" rev-parse --git-dir >/dev/null 2>&1 \
   && [[ -n "$(git -C "$REPO_DIR/local" status --porcelain -- pi/config-export.json)" ]]; then
  echo "It changed: review with 'git -C local diff' and commit it in local/."
fi

if [[ "${1:-}" == "--teleporter" ]]; then
  [[ -n "$BACKUP_DIR" ]] || { echo "ERROR: set BACKUP_DIR in .env" >&2; exit 1; }
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
  v="$(jq -r '.pihole_version.core' "$OUT")"
  f="$BACKUP_DIR/pi-teleporter-$(date +%Y%m%d-%H%M)-$v.zip"
  (umask 077; get /teleporter > "$f")
  unzip -tq "$f" >/dev/null
  echo "Wrote $f (zip test OK)"
fi
