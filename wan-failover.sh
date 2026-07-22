#!/bin/bash
#
# wan-failover.sh — active-probe WAN failover for macOS
#
# Probes the Wi-Fi upstream DIRECTLY (bound to the Wi-Fi interface) so it
# detects a "connected but no internet" black hole, which macOS Service
# Order cannot. On failure it moves the default route to the Pixel tether,
# and moves back once Wi-Fi is convincingly healthy again.
#
# Tuning rationale:
#   - Fast to leave Wi-Fi  : a dead link costs money at the tables.
#   - Deliberate to return : avoids flapping on a shakily-recovering line,
#                            where each transition costs a Moonlight resume.
#
# Detection budget (worst case, ~1.05s):
#     400ms failed probe  +  250ms sleep  +  400ms failed probe
#
# Requires root: sub-second ping intervals and `route change` both need it.
#
#   sudo ./wan-failover.sh          (foreground test)
#   tail -f /Users/yoni/Projects/internet_connectivity_monitor/wan-failover.log
#

#=== CONFIG ===================================================
WIFI_IF="en0"                 # Wi-Fi BSD device (stable on this Mac)
TETHER_SERVICE="Pixel 9a"     # name as shown in Network preferences

TARGET="1.1.1.1"              # probe target — must NOT be on the local LAN
TARGET2="8.8.8.8"             # alternate target, used on alternating cycles

PING_WAIT=400                 # ms to wait for a single reply  (-W, per packet)
PROBE_INTERVAL=0.25           # seconds between probes
FAIL_THRESHOLD=2              # consecutive failures before failover  (~1s)
OK_THRESHOLD=120              # consecutive successes before restore  (~30s)

# Flap detection: if we fail over this many times inside this window,
# the line is unstable and restoring keeps failing — say so loudly.
FLAP_COUNT=3
FLAP_WINDOW=600               # seconds (10 min)

LOG_DIR="/Users/yoni/Projects/internet_connectivity_monitor"
LOG_FILE="$LOG_DIR/wan-failover.log"
#==============================================================

fail_count=0
ok_count=0
state="WIFI"                  # WIFI | TETHER
down_time=0
failover_times=""             # space-separated epochs, for flap detection
probe_toggle=0                # alternates which target is used

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Resolve the tether service name to its CURRENT BSD device.
# Looked up at call time, not startup: the device name can change
# between reconnects, and the phone may not be plugged in yet.
# Returns empty if the service isn't present.
tether_if() {
    networksetup -listallhardwareports \
      | awk -v svc="$TETHER_SERVICE" '
          $0 ~ "^Hardware Port: " svc "$" { getline; print $2; exit }'
}

# Is the Wi-Fi upstream actually passing traffic?
#
# -b binds the probe to the Wi-Fi interface, so the answer stays
# independent of wherever the default route currently points. This is
# the whole trick: an unbound ping would succeed over cellular after
# failover, the script would conclude Wi-Fi had recovered, switch back
# into the dead link, fail again — flapping forever.
#
# -W is the PER-PACKET reply timeout in milliseconds. (Note: -t on macOS
# is a total deadline for the whole ping run, not a per-packet timeout —
# easy to misread, so -W is used deliberately here.)
#
# ONE target per cycle, alternating between the two. Trying both targets
# serially in a single cycle doubled the worst-case detection time; with
# alternation, two consecutive failures still means two different hosts
# were unreachable back-to-back, so a single flaky target won't trigger
# a failover.
wifi_alive() {
    local t
    if [ "$probe_toggle" -eq 0 ]; then
        t="$TARGET"
        probe_toggle=1
    else
        t="$TARGET2"
        probe_toggle=0
    fi
    ping -c 1 -W "$PING_WAIT" -b "$WIFI_IF" "$t" >/dev/null 2>&1
}

# Record a failover and warn if the line looks unstable.
note_failover() {
    local now cutoff t recent="" n
    now=$(date +%s)
    cutoff=$((now - FLAP_WINDOW))

    for t in $failover_times; do
        [ "$t" -ge "$cutoff" ] && recent="$recent $t"
    done
    recent="$recent $now"
    failover_times="$recent"

    n=$(echo $recent | wc -w | tr -d ' ')
    if [ "$n" -ge "$FLAP_COUNT" ]; then
        log "WARNING: $n failovers in the last $((FLAP_WINDOW / 60)) min — wifi line looks unstable"
    fi
}

switch_to_tether() {
    local dev gw
    dev=$(tether_if)
    if [ -z "$dev" ]; then
        log "ERROR: tether service '$TETHER_SERVICE' not found — is the Pixel plugged in and USB tethering on?"
        return 1
    fi
    gw=$(ipconfig getoption "$dev" router 2>/dev/null)
    if [ -z "$gw" ]; then
        log "ERROR: no gateway on $dev — tethering may not be fully up"
        return 1
    fi
    route -n change default "$gw" >/dev/null 2>&1 \
        || route -n add default "$gw" >/dev/null 2>&1
    log "FAILOVER -> tether ($dev via $gw)"
    return 0
}

switch_to_wifi() {
    local gw
    gw=$(ipconfig getoption "$WIFI_IF" router 2>/dev/null)
    if [ -z "$gw" ]; then
        log "ERROR: no gateway on $WIFI_IF"
        return 1
    fi
    route -n change default "$gw" >/dev/null 2>&1 \
        || route -n add default "$gw" >/dev/null 2>&1
    log "RESTORE -> wifi ($WIFI_IF via $gw)"
    return 0
}

#--- startup ---------------------------------------------------
log "monitor started (wifi=$WIFI_IF tether-service='$TETHER_SERVICE')"

# Warn loudly if the safety net isn't in place. Better to find out now
# than mid-hand: with no tether there is no failover at all.
startup_dev=$(tether_if)
if [ -z "$startup_dev" ]; then
    log "WARNING: tether not present at startup — NO FAILOVER AVAILABLE until the Pixel is plugged in and tethering"
else
    log "tether present at startup ($startup_dev)"
fi

#--- main loop -------------------------------------------------
while true; do
    if wifi_alive; then
        fail_count=0
        ok_count=$((ok_count + 1))

        if [ "$state" = "TETHER" ] && [ "$ok_count" -ge "$OK_THRESHOLD" ]; then
            if switch_to_wifi; then
                state="WIFI"
                ok_count=0
                log "wifi upstream healthy again (outage ~$(( $(date +%s) - down_time ))s)"
            fi
        fi
    else
        ok_count=0
        fail_count=$((fail_count + 1))

        if [ "$state" = "WIFI" ] && [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
            down_time=$(date +%s)
            log "wifi upstream dead ($fail_count consecutive failures)"
            if switch_to_tether; then
                state="TETHER"
                note_failover
            fi
        fi
    fi

    sleep "$PROBE_INTERVAL"
done
