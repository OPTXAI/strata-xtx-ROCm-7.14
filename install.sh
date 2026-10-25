#!/usr/bin/env bash
# strata-xtx: één commando in een SCHONE container; installeert en meet alles zelf (als losse service 'xtx-install').
#   apt-get update -qq && apt-get install -y -qq curl ca-certificates && curl -fsSL https://raw.githubusercontent.com/OPTXAI/strata-xtx-ROCm-7.14-0.1.49.2/HEAD/install.sh | bash
# Voorwaarde: memlock van de container staat op unlimited (eenmalig op de host, zie host/set-memlock.sh).
# Sluit je het venster, dan gaat de installatie door. Log: /var/log/xtx-install.log. Opnieuw uitvoeren is veilig.
set -u
REPO=https://github.com/OPTXAI/strata-xtx-ROCm-7.14-0.1.49.2.git
DIR=/opt/ai/strata-xtx-0149
LOG=/var/log/xtx-install.log
die() { echo "FOUT: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "draai als root"
if [ -d /etc/pve ] && command -v pveversion >/dev/null 2>&1; then die "dit is de Proxmox-host: draai dit in de container"; fi
ml=$(awk '/Max locked memory/{print $4}' /proc/1/limits)
[ "$ml" = unlimited ] || die "memlock van deze container is '$ml', niet unlimited: zet op de Proxmox-host de regel 'lxc.prlimit.memlock: unlimited' bovenaan /etc/pve/lxc/<CTID>.conf en herstart de container (pct stop <CTID>; pct start <CTID>); zie host/set-memlock.sh"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq </dev/null && apt-get install -y -qq git ca-certificates </dev/null >/dev/null || die "apt mislukte"
if [ -d "$DIR/.git" ]; then git -C "$DIR" pull -q --ff-only </dev/null || die "git pull mislukte"
else git clone -q "$REPO" "$DIR" </dev/null || die "git clone mislukte"; fi
systemctl stop xtx-install 2>/dev/null; systemctl reset-failed xtx-install 2>/dev/null
echo "=== start $(date -Is)" >> "$LOG"
systemd-run --unit=xtx-install --collect -p StandardOutput=append:"$LOG" -p StandardError=append:"$LOG" \
  /bin/bash "$DIR/bin/xtx-auto.sh" </dev/null || die "starten mislukte"
echo "installatie + meting gestart. Log volgen (Ctrl+C stopt alleen het meekijken). Klaar = regel 'AUTO KLAAR'."
exec tail -n +1 -f "$LOG"
