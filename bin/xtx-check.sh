#!/usr/bin/env bash
# strata-xtx: controleer of de LXC klaar is voor Strata op de RX 7900 XTX. Verandert niets.
. "$(dirname "$(readlink -f "$0")")/xtx-lib.sh"
fails=0
bad() { warn "$*"; fails=$((fails + 1)); }

say "container"
virt=$(systemd-detect-virt -c 2>/dev/null || echo onbekend)
ok "virtualisatie: $virt; kernel $(uname -r) (= de Proxmox-host: amdgpu/KFD komen van daar)"
. /etc/os-release; ok "OS: $PRETTY_NAME, $(nproc) CPU's"
grep -q avx2 /proc/cpuinfo && ok "CPU: AVX2$(grep -q avx512f /proc/cpuinfo && echo ' + AVX-512')" || bad "CPU zonder AVX2: alleen de trage experimentele build"

say "GPU-toegang"
if [ -e /dev/kfd ]; then
  ls -l /dev/kfd | awk '{print "  ok  /dev/kfd " $1 " " $3 ":" $4}'
  [ -r /dev/kfd ] && [ -w /dev/kfd ] || [ "$(id -u)" -eq 0 ] || bad "/dev/kfd niet lees/schrijfbaar voor $(id -un)"
else bad "/dev/kfd ontbreekt: geef het door in de LXC-config (host/proxmox-lxc.conf)"; fi
rn=$(ls /dev/dri/renderD* 2>/dev/null | head -1)
[ -n "$rn" ] && ls -l /dev/dri/ | sed 's/^/      /' || bad "/dev/dri/renderD* ontbreekt"
if id "$SERVICE_USER" >/dev/null 2>&1; then
  for d in /dev/kfd $rn; do
    [ -e "$d" ] || continue
    if runuser -u "$SERVICE_USER" -- test -r "$d" -a -w "$d" 2>/dev/null; then ok "$SERVICE_USER kan $d openen"
    else bad "$SERVICE_USER kan $d niet openen: gid van het device ($(stat -c %g "$d")) moet render/video in de container zijn"; fi
  done
fi
nodes=/sys/class/kfd/kfd/topology/nodes
if [ -d $nodes ]; then
  for n in $nodes/*; do
    p=$(cat "$n/properties" 2>/dev/null)
    gid=$(awk '/gfx_target_version/{print $2}' <<<"$p"); [ "${gid:-0}" = 0 ] && continue
    ok "KFD node $(basename "$n"): gfx_target_version $gid ($([ "$gid" = 110000 ] && echo 'gfx1100 = RX 7900 XT/XTX/GRE' || echo 'andere kaart'))"
  done
else bad "$nodes ontbreekt (amdgpu niet geladen op de host?)"; fi
for card in /sys/class/drm/card*/device; do
  [ -f "$card/vendor" ] && [ "$(cat "$card/vendor")" = 0x1002 ] || continue
  vr=$(cat "$card/mem_info_vram_total" 2>/dev/null); vu=$(cat "$card/mem_info_vram_used" 2>/dev/null)
  ok "$(basename "$(readlink -f "$card")"): VRAM $((${vr:-0} >> 20)) MiB, in gebruik $((${vu:-0} >> 20)) MiB; PCIe $(cat "$card/current_link_speed" 2>/dev/null) x$(cat "$card/current_link_width" 2>/dev/null) (max $(cat "$card/max_link_speed" 2>/dev/null) x$(cat "$card/max_link_width" 2>/dev/null))"
  [ "$(cat "$card/current_link_width" 2>/dev/null)" = 16 ] || warn "PCIe-link is niet x16: experts uit RAM gaan dan trager (kan ook idle-powersaving zijn; check onder belasting)"
  pc=$(cat "$card"/hwmon/hwmon*/power1_cap 2>/dev/null | head -1); [ -n "$pc" ] && ok "power cap $((pc / 1000000)) W"
done

say "geheugen"
mt=$(awk '/MemTotal/{print int($2/1048576)}' /proc/meminfo); ma=$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo)
ok "MemTotal ${mt} GiB, MemAvailable ${ma} GiB (lxcfs-waarden)"
[ "$mt" -ge 72 ] || warn "minder dan 72 GiB: krap voor IQ3_S (gemeten ~70 GiB bij 262K); kies IQ2_XS/IQ3_XXS of geef de LXC meer RAM"
cg=$(cat /sys/fs/cgroup/memory.max 2>/dev/null); ok "cgroup memory.max in de container: ${cg:-onleesbaar} (\"max\" = limiet zit op de host, daarom --memory-limit-mib)"
# De service erft de limiet van de init van de container (systemd); een "pct enter"-shell erft die van de host-shell.
ml1=$(awk '/Max locked memory/{print $5}' /proc/1/limits 2>/dev/null)
if [ "$ml1" = unlimited ]; then ok "memlock (container-init): unlimited$( [ "$(ulimit -l)" = unlimited ] || echo "; deze shell: $(ulimit -l) KiB, maakt niet uit")"
else bad "memlock van de container = ${ml1:-?}: zet op de Proxmox-host 'lxc.prlimit.memlock: unlimited' in /etc/pve/lxc/<CTID>.conf en herstart de container"; fi
sw=$(awk '/SwapTotal/{print int($2/1048576)}' /proc/meminfo); [ "$sw" -eq 0 ] && ok "geen swap" || warn "swap ${sw} GiB: zet swap: 0 voor de LXC (experts in swap = vastlopers)"
thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null); ok "THP: $thp"
hp=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null); ok "hugetlb 2 MiB pages: ${hp:-?} (optioneel)"

say "opslag"
mkdir -p "$DATA_DIR" 2>/dev/null
fs=$(findmnt -no FSTYPE,SOURCE -T "$DATA_DIR" 2>/dev/null); ok "$DATA_DIR op: $fs"
case "$fs" in zfs*) warn "ZFS: O_DIRECT-reads van de n-gramtabel kunnen traag zijn; meet en overweeg --ple-io ram (RAM nodig: ~29 GB) of een ext4/xfs-dataset op NVMe";; esac
df -h "$DATA_DIR" | tail -1 | awk '{print "  ok  vrij: " $4 " van " $2}'
need=90; ls "$DATA_DIR"/models/*/*.gguf >/dev/null 2>&1 && need=20   # model al aanwezig: alleen ROCm + build
avail=$(df -Pk "$DATA_DIR" | awk 'NR==2{print int($4/1048576)}'); [ "${avail:-0}" -ge $need ] || warn "minder dan ~$need GB vrij (model ±85 GB als het er nog niet is, ROCm + build ±15 GB)"

say "software"
if [ "$ROCM_SOURCE" = apt ]; then r=$(rocm_apt_root) && ok "ROCm $ROCM_APT (apt): $r" || ok "ROCm ${ROCM_APT:-latest} (apt): nog niet geïnstalleerd (doet de bootstrap)"
else ok "ROCm: wheels in .venv (${ROCM_VERSION:-setup's standaard})"; fi
for t in git gcc cmake ninja python3 curl jq; do command -v $t >/dev/null && ok "$t $($t --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)" || bad "$t ontbreekt (xtx-tools.sh)"; done
if [ -d "$STRATA_DIR/.git" ]; then
  ok "Strata: $(git_s rev-parse --abbrev-ref HEAD) @ $(git_s log -1 --format='%h %cs')"
  [ -f "$STRATA_DIR/engine/BUILD.json" ] && ok "engine: $(jq -c '{version,archs,extra_cmake}' "$STRATA_DIR/engine/BUILD.json" 2>/dev/null)"
fi
if systemctl list-unit-files "$SERVICE" >/dev/null 2>&1; then
  ok "service: $(systemctl is-active "$SERVICE" 2>/dev/null) / $(systemctl is-enabled "$SERVICE" 2>/dev/null)"
fi

echo
[ $fails -eq 0 ] && ok "geen blokkerende problemen" || { warn "$fails blokkerend(e) probleem/problemen"; exit 1; }
