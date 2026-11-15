#!/usr/bin/env bash
# Restore a Pi-hole's settings from a config export (config as code), via its API.
#
#   scripts/apply-pi-config.sh            dry run: show what would change on the primary
#   scripts/apply-pi-config.sh --apply    make those changes (then rebuild gravity if lists were added)
#
# Options:
#   --file FILE     export to apply (default: local/pi/config-export.json,
#                   written by scripts/export-pi-config.sh)
#   --target URL    Pi-hole to change (default: http://$PI_IP from .env)
#   --no-gravity    don't rebuild the blocklist DB afterwards
# Password: $TARGET_PASSWORD if set, else PI_PRIMARY_PASSWORD from .env.
#
# Adds what's missing (groups, lists, allow/deny domains, clients) and sets the
# DNS settings that differ (local records, CNAMEs, upstreams, ...) to the
# export's values. It never deletes groups, lists, domains or clients, so it's
# safe to run again. Typical use: after scripts/bootstrap-pi.sh on a new Pi,
# instead of importing a Teleporter archive.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$REPO_DIR/local/pi/config-export.json"
TARGET=""
APPLY=0
GRAVITY=1

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
while (($#)); do
  case $1 in
    --file)       FILE=${2:?}; shift 2 ;;
    --target)     TARGET=${2:?}; shift 2 ;;
    --apply)      APPLY=1; shift ;;
    --no-gravity) GRAVITY=0; shift ;;
    -h|--help)    sed -n '2,/^set -e/{/^set -e/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
    *)            die "unknown option: $1 (see --help)" ;;
  esac
done
[[ -f $FILE ]] || die "no export at $FILE"
jq -e '.dns and .groups and .lists and .domains and .clients' "$FILE" >/dev/null \
  || die "$FILE doesn't look like a config export"

# Read a value from .env (if there is one) without printing it.
# shellcheck source=/dev/null
env_get() { [[ -f "$REPO_DIR/.env" ]] || return 0; (set -a; source "$REPO_DIR/.env"; printf '%s' "${!1:-}"); }
if [[ -z $TARGET ]]; then
  ip="$(env_get PI_IP)"
  [[ -n $ip ]] || die "set PI_IP in .env or pass --target URL"
  TARGET="http://$ip"
fi
TARGET="${TARGET%/}"
password="${TARGET_PASSWORD:-$(env_get PI_PRIMARY_PASSWORD)}"

login() {
  sid="$(jq -n --arg p "$password" '{password: $p}' \
    | curl -fsS -m 10 -X POST -H 'Content-Type: application/json' --data @- "$TARGET/api/auth" \
    | jq -r '.session.sid // empty')"
  [[ -n "$sid" ]] || die "login to $TARGET failed"
}
login
# Always close the session, even on errors (Pi-hole limits the number of sessions).
trap 'curl -sS -m 10 -o /dev/null -X DELETE -H "X-FTL-SID: $sid" "$TARGET/api/auth" || true' EXIT

# api METHOD PATH [JSON_BODY]
api() {
  local args=(-sS -m 30 --fail-with-body -X "$1" -H "X-FTL-SID: $sid")
  [[ $# -ge 3 ]] && args+=(-H 'Content-Type: application/json' --data "$3")
  curl "${args[@]}" "$TARGET/api$2"
}

changes=0
lists_added=0
change() {
  changes=$((changes + 1))
  if ((APPLY)); then printf '  + %s\n' "$*"; else printf '  would %s\n' "$*"; fi
}

if ((APPLY)); then echo "Applying $FILE to $TARGET"; else echo "Dry run: $FILE vs. $TARGET"; fi

# --- Groups (by name), first: everything else refers to them -----------------
have="$(api GET /groups)"
while IFS= read -r g; do
  name="$(jq -r .name <<<"$g")"
  jq -e --arg n "$name" 'any(.groups[]; .name == $n)' <<<"$have" >/dev/null && continue
  change "add group: $name"
  ((APPLY)) && api POST /groups "$(jq -c '{name, comment, enabled}' <<<"$g")" >/dev/null
done < <(jq -c '.groups[]' "$FILE")

# Group IDs differ between Pi-holes: map export ID → name → target ID.
src_groups="$(jq -c '[.groups[] | {key: (.id | tostring), value: .name}] | from_entries' "$FILE")"
tgt_groups="$(api GET /groups | jq -c '[.groups[] | {key: .name, value: .id}] | from_entries')"
# map_groups JSON_ITEM → item with .groups translated to target IDs
map_groups() {
  jq -c --argjson s "$src_groups" --argjson t "$tgt_groups" \
    '.groups = [(.groups // [])[] | $s[tostring] as $n | $t[$n] // empty]' <<<"$1"
}
group_names() { jq -r --argjson s "$src_groups" '[(.groups // [])[] | $s[tostring]] | join(",")' <<<"$1"; }

# --- Lists (by address + type) -------------------------------------------------
have="$(api GET /lists)"
while IFS= read -r l; do
  addr="$(jq -r .address <<<"$l")" type="$(jq -r .type <<<"$l")"
  jq -e --arg a "$addr" --arg t "$type" 'any(.lists[]; .address == $a and .type == $t)' <<<"$have" >/dev/null && continue
  change "add $type list: $addr (groups: $(group_names "$l"))"
  lists_added=1
  ((APPLY)) && api POST "/lists?type=$type" "$(map_groups "$l" | jq -c '{address, comment, groups, enabled}')" >/dev/null
done < <(jq -c '.lists[]' "$FILE")

# --- Allow/deny domains (by domain + type + kind) ----------------------------
have="$(api GET /domains)"
while IFS= read -r d; do
  dom="$(jq -r .domain <<<"$d")" type="$(jq -r .type <<<"$d")" kind="$(jq -r .kind <<<"$d")"
  jq -e --arg d "$dom" --arg t "$type" --arg k "$kind" \
    'any(.domains[]; .domain == $d and .type == $t and .kind == $k)' <<<"$have" >/dev/null && continue
  change "add $type/$kind domain: $dom"
  ((APPLY)) && api POST "/domains/$type/$kind" "$(map_groups "$d" | jq -c '{domain, comment, groups, enabled}')" >/dev/null
done < <(jq -c '.domains[]' "$FILE")

# --- Clients (by client) -------------------------------------------------------
have="$(api GET /clients)"
while IFS= read -r c; do
  client="$(jq -r .client <<<"$c")"
  jq -e --arg c "$client" 'any(.clients[]; .client == $c)' <<<"$have" >/dev/null && continue
  change "add client: $client"
  ((APPLY)) && api POST /clients "$(map_groups "$c" | jq -c '{client, comment, groups}')" >/dev/null
done < <(jq -c '.clients[]' "$FILE")

# --- DNS settings: every top-level key of the section that differs -----------
have="$(api GET /config/dns | jq -c '.config.dns')"
want="$(jq -c '.dns' "$FILE")"
diff_keys="$(jq -cn --argjson w "$want" --argjson h "$have" '[$w | keys[] | select($w[.] != $h[.])]')"
while IFS= read -r k; do
  change "set dns.$k: $(jq -c --arg k "$k" '.[$k]' <<<"$have") → $(jq -c --arg k "$k" '.[$k]' <<<"$want")"
done < <(jq -r '.[]' <<<"$diff_keys")
if ((APPLY)) && [[ $diff_keys != '[]' ]]; then
  api PATCH /config "$(jq -cn --argjson w "$want" --argjson k "$diff_keys" \
    '{config: {dns: ($w | with_entries(select(.key as $x | $k | index($x))))}}')" >/dev/null
  # FTL restarts itself about a second after a DNS config change. Wait until
  # it's back, and log in again if the session didn't survive the restart.
  echo "Waiting for FTL to restart with the new DNS settings..."
  sleep 3
  for _ in $(seq 30); do curl -fs -m 2 -o /dev/null "$TARGET/api/info/login" && break; sleep 1; done
  curl -fs -m 5 -o /dev/null -H "X-FTL-SID: $sid" "$TARGET/api/auth" || login
fi
unset password

# --- Result --------------------------------------------------------------------
if ((changes == 0)); then
  echo "Nothing to change: $TARGET matches the export."
elif ((!APPLY)); then
  echo "$changes change(s). Run again with --apply to make them."
else
  echo "$changes change(s) made."
  if ((lists_added && GRAVITY)); then
    echo "Rebuilding gravity (downloads the lists; can take a few minutes)..."
    curl -sS -m 900 --fail-with-body -X POST -H "X-FTL-SID: $sid" "$TARGET/api/action/gravity" \
      | LC_ALL=C sed $'s/\033\\[[0-9;]*[A-Za-z]//g' | grep -v '^[[:space:]]*$' | tail -n 2
  fi
fi
