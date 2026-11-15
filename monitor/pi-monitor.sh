#!/bin/sh
# pi-monitor: sends an ntfy push when a Pi-hole stops answering, and again
# when it recovers. Runs in a plain alpine container (busybox only).
#
# Checks, every $INTERVAL seconds, for both Pi-holes (pi = Raspberry Pi,
# mac = this Mac's):
#   1. FTL's unauthenticated /api/info/login answers "dns":true.
#   2. A real DNS lookup of $TEST_DOMAIN through it. This also catches a broken
#      upstream, i.e. its unbound.
# A target counts as down after $FAILS_BEFORE_ALERT failures in a row, so
# short hiccups and reboots don't alert.
#
# Pushes that can't be delivered (network or ntfy trouble) are retried every
# round until they get through, so an alert is delayed, never lost.
set -u

INTERVAL="${INTERVAL:-60}"
FAILS_BEFORE_ALERT="${FAILS_BEFORE_ALERT:-3}"
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
PI_URL="${PI_URL:?PI_URL is not set}"   # e.g. http://192.168.1.2
PI_DNS="${PI_DNS:?PI_DNS is not set}"   # e.g. 192.168.1.2
MAC_URL="${MAC_URL:-http://pihole}"
MAC_DNS="${MAC_DNS:-pihole}"
TEST_DOMAIN="${TEST_DOMAIN:-example.com}"
TITLE_PREFIX="${TITLE_PREFIX:-}"   # e.g. "[TEST] " for test runs
: "${NTFY_TOPIC:?NTFY_TOPIC is not set}"

log() { echo "$(date '+%F %T') $*"; }

# notify TITLE PRIORITY TAGS MESSAGE. Returns non-zero if not delivered.
notify() {
  if wget -q -T 10 -O /dev/null \
      --header "Title: $TITLE_PREFIX$1" --header "Priority: $2" --header "Tags: $3" \
      --post-data "$4" "$NTFY_SERVER/$NTFY_TOPIC" 2>/tmp/notify.err; then
    log "sent: $1"
    return 0
  fi
  log "WARN: push not delivered, will retry next round: $1 ($(sed 's/^wget: //' /tmp/notify.err | head -1))"
  return 1
}

# Sets $reason on failure.
check_api() {
  body=$(wget -q -T 5 -O - "$1/api/info/login" 2>/tmp/wget.err) || {
    reason="web API not reachable ($(sed 's/^wget: //' /tmp/wget.err | head -1))"
    return 1
  }
  case "$body" in *'"dns":true'*) return 0 ;; esac
  reason="FTL says its DNS server is not running"
  return 1
}

check_dns() {
  nslookup -timeout=5 "$TEST_DOMAIN" "$1" >/dev/null 2>&1 \
    || { reason="DNS lookup of $TEST_DOMAIN failed (FTL runs, so probably its upstream/unbound)"; return 1; }
}

check_pi()  { check_api "$PI_URL"  && check_dns "$PI_DNS"; }
check_mac() { check_api "$MAC_URL" && check_dns "$MAC_DNS"; }

# Per-target state, in variables named <field>_<id>:
#   fails      failed checks in a row
#   down       current state: 1 = down (after FAILS_BEFORE_ALERT failures)
#   told       state the user was last told about (push delivered)
#   since      time of the first failure of the current outage
#   why        reason of the latest failure
#   took       outage length, set at recovery
for id in pi mac; do eval "fails_$id=0 down_$id=0 told_$id=0 since_$id=0 why_$id='' took_$id=''"; done

# run ID LABEL CHECK_FUNCTION
run() {
  id=$1 label=$2 check=$3 reason=""
  eval "fails=\$fails_$id down=\$down_$id told=\$told_$id since=\$since_$id why=\$why_$id took=\$took_$id"
  now=$(date +%s)

  if $check; then
    if [ "$down" = 1 ]; then
      mins=$(( (now - since) / 60 ))
      if [ "$mins" -lt 1 ]; then took="less than a minute"; else took="about $mins min"; fi
      log "$label: back up (down $took)"
    elif [ "$fails" -gt 0 ]; then
      log "$label: ok again after $fails failed check(s)"
    fi
    fails=0 down=0
  else
    fails=$((fails + 1))
    [ "$fails" = 1 ] && since=$now
    why=$reason
    log "$label: check failed ($fails): $reason"
    [ "$fails" -ge "$FAILS_BEFORE_ALERT" ] && down=1
  fi

  # Tell the user about a state change, or retry a push that didn't get through.
  # (If an outage ends before its alert could be delivered, nothing is sent.)
  if [ "$down" != "$told" ]; then
    if [ "$down" = 1 ]; then
      notify "$label is down" high warning \
        "$label has failed $fails checks in a row since $(date -d "@$since" '+%H:%M'). Reason: $why." \
        && told=1
    else
      notify "$label is back" default white_check_mark \
        "$label answers again. It was down for $took." \
        && told=0
    fi
  fi

  eval "fails_$id=\$fails down_$id=\$down told_$id=\$told since_$id=\$since why_$id=\$why took_$id=\$took"
}

log "started: pi=$PI_URL ($PI_DNS) mac=$MAC_URL ($MAC_DNS) every ${INTERVAL}s, alert after $FAILS_BEFORE_ALERT failures"
started_told=0

while :; do
  if [ "$started_told" = 0 ]; then
    notify "pi-monitor started" low information_source \
      "Watching both Pi-holes. You'll get a push if one stops answering. (This also means the Mac has just started or restarted.)" \
      && started_told=1
  fi
  run pi  "Raspberry Pi Pi-hole" check_pi
  run mac "Mac Pi-hole (fallback)" check_mac
  sleep "$INTERVAL"
done
