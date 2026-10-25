#!/usr/bin/env bash
# strata-xtx: draai dit op de PROXMOX-HOST, eenmalig per container:  bash set-memlock.sh CTID
# Zonder bestand (zelfde werking, voor CT 103), plakken als root op de host:
#   grep -q '^lxc.prlimit.memlock' /etc/pve/lxc/103.conf || sed -i '1i lxc.prlimit.memlock: unlimited' /etc/pve/lxc/103.conf; pct stop 103; pct start 103 && sleep 10 && pct exec 103 -- grep locked /proc/1/limits && pct snapshot 103 schoon-memlock
# Zet 'lxc.prlimit.memlock: unlimited' bovenaan de LXC-config (boven elke [sectie]), herstart de container als dat nodig is,
# controleert het resultaat en maakt de snapshot 'schoon-memlock' (terugzetten naar die snapshot houdt de regel).
# Installeert niets op de host.
CT=${1:-}
die() { echo "FOUT: $*" >&2; exit 1; }
command -v pct >/dev/null 2>&1 || die "pct niet gevonden: dit draait op de Proxmox-host"
[[ "$CT" =~ ^[0-9]+$ ]] || die "gebruik: bash set-memlock.sh CTID"
CONF=/etc/pve/lxc/$CT.conf
[ -f "$CONF" ] || die "geen $CONF"
running() { [ "$(pct status "$CT" | awk '{print $2}')" = running ]; }
limit_ok() { pct exec "$CT" -- awk '/Max locked memory/{print $4}' /proc/1/limits 2>/dev/null | grep -qx unlimited; }
grep -q '^lxc.prlimit.memlock:' "$CONF" || { sed -i '1i lxc.prlimit.memlock: unlimited' "$CONF" && echo "memlock-regel toegevoegd aan $CONF"; }
if running && limit_ok; then echo "container $CT draait al met memlock unlimited"
else
  running && pct stop "$CT"
  pct start "$CT" || die "container $CT starten mislukte"
  for i in $(seq 30); do limit_ok && break; sleep 2; done
fi
limit_ok || die "memlock in container $CT is niet unlimited (staat er in $CONF een andere waarde?)"
echo "ok: memlock unlimited in container $CT"
pct listsnapshot "$CT" 2>/dev/null | grep -qw schoon-memlock || pct snapshot "$CT" schoon-memlock && echo "snapshot schoon-memlock bestaat"
