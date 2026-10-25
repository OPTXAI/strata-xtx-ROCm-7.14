#!/usr/bin/env bash
# strata-xtx: volledig automatische installatie, te starten op de PROXMOX-HOST:
#   bash install-ct.sh CTID
# Doet: memlock-regel in de LXC-config zetten (staat boven elke [sectie]), container (her)starten als dat nodig is,
# de overlay in de container clonen, en daar de installatie + meting starten (xtx-auto.sh, als service 'xtx-install').
# Draait de installatie los van deze terminal: sluit je de terminal, dan gaat hij door. Log in de container:
# /var/log/xtx-install.log. Opnieuw uitvoeren is veilig.
CT=${1:-}
REPO=${XTX_REPO:-https://github.com/OPTXAI/strata-xtx-ROCm-7.14-0.1.49.2.git}
DIR=/opt/ai/strata-xtx-0149
die() { echo "FOUT: $*" >&2; exit 1; }
command -v pct >/dev/null 2>&1 || die "pct niet gevonden: dit script draait op de Proxmox-host"
[[ "$CT" =~ ^[0-9]+$ ]] || die "gebruik: bash install-ct.sh CTID"
CONF=/etc/pve/lxc/$CT.conf
[ -f "$CONF" ] || die "geen $CONF"

running() { [ "$(pct status "$CT" | awk '{print $2}')" = running ]; }
limit_ok() { pct exec "$CT" -- awk '/Max locked memory/{print $4}' /proc/1/limits 2>/dev/null | grep -qx unlimited; }

if ! grep -q '^lxc.prlimit.memlock:' "$CONF"; then
  sed -i '1i lxc.prlimit.memlock: unlimited' "$CONF" && echo "memlock-regel toegevoegd aan $CONF"
fi
running && ! limit_ok && { echo "container herstarten (memlock)"; pct stop "$CT"; }
running || pct start "$CT" || die "container $CT starten mislukte"
for i in $(seq 30); do limit_ok && break; sleep 2; done
limit_ok || die "memlock in container $CT is niet unlimited (zie $CONF: staat er een andere waarde?)"
for i in $(seq 30); do pct exec "$CT" -- getent hosts github.com >/dev/null 2>&1 && break; sleep 2; done
pct exec "$CT" -- getent hosts github.com >/dev/null 2>&1 || die "container heeft geen internet (github.com)"

echo "overlay in container $CT ophalen"
pct exec "$CT" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq git ca-certificates >/dev/null && if [ -d $DIR/.git ]; then git -C $DIR pull -q --ff-only; else git clone -q $REPO $DIR; fi" \
  || die "overlay ophalen mislukte"

echo "installatie + meting starten (service xtx-install in de container)"
pct exec "$CT" -- bash -c "systemctl stop xtx-install 2>/dev/null; systemctl reset-failed xtx-install 2>/dev/null; echo \"=== start \$(date -Is)\" >> /var/log/xtx-install.log; systemd-run --unit=xtx-install --collect -p StandardOutput=append:/var/log/xtx-install.log -p StandardError=append:/var/log/xtx-install.log /bin/bash $DIR/bin/xtx-auto.sh" \
  || die "starten mislukte"

echo "log volgen (Ctrl+C stopt alleen het meekijken; de installatie gaat door). Klaar = regel 'AUTO KLAAR'."
pct exec "$CT" -- tail -n +1 -f /var/log/xtx-install.log &
T=$!
trap 'kill $T 2>/dev/null' EXIT
while pct exec "$CT" -- systemctl is-active -q xtx-install; do sleep 20; done
sleep 3
echo "installatie-service klaar: $(pct exec "$CT" -- systemctl show xtx-install -p Result --value 2>/dev/null)"
