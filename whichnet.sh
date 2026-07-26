#!/bin/bash
# whichnet — print which connection the Mac is currently routing through.

iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')

case "$iface" in
    en0) echo "Wi-Fi (en0) — landlord network" ;;
    en4) echo "Cellular (en4) — Pixel tether" ;;
    "")  echo "No default route — offline?" ;;
    *)   echo "Other ($iface)" ;;
esac
