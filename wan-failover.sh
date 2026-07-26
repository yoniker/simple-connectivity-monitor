#!/bin/bash
#
# wan-failover.sh — active-probe WAN failover for macOS
#
# Probes the Wi-Fi upstream DIRECTLY (bound to the Wi-Fi interface) so it
# detects a "connected but no internet" black hole, which macOS Service
# Order cannot. On failure it moves the default route to the Pixel tether;
# it moves back only once Wi-Fi has proven solid for a sustained stretch.
#
# Behaviour, precisely:
#   FAILOVER : as soon as Wi-Fi is confirmed down, if a tether exists, switch.
#              The tether is re-checked EVERY cycle while Wi-Fi is down, so
#              plugging the phone in mid-outage triggers a switch on the next
#              probe with no manual action.
#   RESTORE  : only after Wi-Fi has been healthy for RESTORE_SECS of sustained
#              probing. A few isolated misses are tolerated; a cluster of
#              failures resets the clock. This keeps a flaky-but-recovering
#              line from bouncing you back prematurely.
#   STARTUP  : state is set from the ACTUAL current default route, so a
#              restarted daemon never carries stale state.
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

# Restore: Wi-Fi must be healthy for this long before we go back.
RESTORE_SECS=120                              # 2 minutes
RESTORE_PROBES=$(python3 -c "print(int($RESTORE_SECS / $PROBE_INTERVAL))" 2>/dev/null || echo 480)
RESTORE_MISS_BUDGET=5         # isolated misses tolerated inside the window
RESTORE_CLUSTER=2             # this many failures in a row = still flaky, reset

# Flap detection: if we fail over this many times inside this window,
# the line is unstable — say so loudly.
FLAP_COUNT=3
FLAP_WINDOW=600               # seconds (10 min)

LOG_DIR="/Users/yoni/Projects/internet_connectivity_monitor"
LOG_FILE="$LOG_DIR/wan-failover.log"
#==============================================================

fail_count=0
state="WIFI"                  # WIFI | TETHER
down_time=0
failover_times=""            # space-separated epochs, for flap detection
probe_toggle=0

# restore-window accounting
ok_run=0                      # probes seen in the current healthy window
ok_miss=0                     # isolated misses in the window
consec_fail=0                 # consecutive failures (cluster detector)

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

tether_if() {
    networksetup -listallhardwareports \
      | awk -v svc="$TETHER_SERVICE" '
          $0 ~ "^Hardware Port: " svc "$" { getline; print $2; exit }'
}

# Current default-route interface — ground truth for reconciling state.
current_if() {
    route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}'
}

# One target per cycle, alternating. -b binds to Wi-Fi so the answer is
# independent of the current default route (an unbound ping would succeed
# over cellular after failover and cause endless flapping). -W is the
# per-packet timeout in ms (macOS -t is a whole-run deadline, not per packet).
wifi_alive() {
    local t
    if [ "$probe_toggle" -eq 0 ]; then t="$TARGET"; probe_toggle=1
    else t="$TARGET2"; probe_toggle=0; fi
    ping -c 1 -W "$PING_WAIT" -b "$WIFI_IF" "$t" >/dev/null 2>&1
}

reset_restore_window() {
    ok_run=0; ok_miss=0; consec_fail=0
}

note_failover() {
    local now cutoff t recent="" n
    now=$(date +%s); cutoff=$((now - FLAP_WINDOW))
    for t in $failover_times; do
        [ "$t" -ge "$cutoff" ] && recent="$recent $t"
    done
    recent="$recent $now"; failover_times="$recent"
    n=$(echo $recent | wc -w | tr -d ' ')
    [ "$n" -ge "$FLAP_COUNT" ] && \
        log "WARNING: $n failovers in the last $((FLAP_WINDOW / 60)) min — wifi line looks unstable"
}

switch_to_tether() {
    local dev gw
    dev=$(tether_if)
    [ -z "$dev" ] && return 1          # no tether — caller stays on Wi-Fi, silent
    gw=$(ipconfig getoption "$dev" router 2>/dev/null)
    if [ -z "$gw" ]; then
        log "ERROR: tether $dev present but no gateway yet — tethering not fully up"
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

# Reconcile state with the ACTUAL current route, not an assumption.
cur=$(current_if)
if [ "$cur" = "$WIFI_IF" ]; then
    state="WIFI"
    log "startup: currently on wifi ($WIFI_IF)"
elif [ -n "$cur" ]; then
    state="TETHER"
    down_time=$(date +%s)
    log "startup: currently on non-wifi route ($cur) — treating as TETHER"
fi

startup_dev=$(tether_if)
if [ -z "$startup_dev" ]; then
    log "note: tether not present at startup — failover unavailable until the Pixel is plugged in and tethering"
else
    log "note: tether present at startup ($startup_dev)"
fi

#--- main loop -------------------------------------------------
while true; do
    if wifi_alive; then
        fail_count=0

        if [ "$state" = "TETHER" ]; then
            # accumulate a healthy window; tolerate isolated misses
            ok_run=$((ok_run + 1))
            consec_fail=0
            if [ "$ok_run" -ge "$RESTORE_PROBES" ]; then
                if switch_to_wifi; then
                    state="WIFI"
                    reset_restore_window
                    log "wifi healthy for ~${RESTORE_SECS}s (outage ~$(( $(date +%s) - down_time ))s)"
                fi
            fi
        fi
    else
        # Wi-Fi probe failed
        if [ "$state" = "TETHER" ]; then
            # we're on cellular, counting toward restore — a miss erodes it
            ok_miss=$((ok_miss + 1))
            consec_fail=$((consec_fail + 1))
            if [ "$consec_fail" -ge "$RESTORE_CLUSTER" ] || [ "$ok_miss" -gt "$RESTORE_MISS_BUDGET" ]; then
                reset_restore_window     # still flaky — start the 2 min over
            fi
        else
            # we're on Wi-Fi and it's failing
            fail_count=$((fail_count + 1))
            if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
                # Attempt failover EVERY cycle while down, so plugging the
                # phone in mid-outage switches on the next probe. Only log
                # the "dead" line once per outage to avoid log spam.
                if [ "$down_time" -eq 0 ]; then
                    down_time=$(date +%s)
                    log "wifi upstream dead ($fail_count consecutive failures)"
                fi
                if switch_to_tether; then
                    state="TETHER"
                    reset_restore_window
                    note_failover
                fi
            fi
        fi
    fi

    # reset the once-per-outage latch when Wi-Fi is healthy and we're on it
    if [ "$state" = "WIFI" ] && [ "$fail_count" -eq 0 ]; then
        down_time=0
    fi

    sleep "$PROBE_INTERVAL"
done
