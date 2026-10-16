#!/usr/bin/env bash
# strata-xtx: draai dit op de PROXMOX-HOST (niet in de container). Controleert amdgpu/KFD/IOMMU en print de
# LXC-regels met de juiste nummers. Verandert niets.
#   ./host-check.sh [CTID]
CT=${1:-}
say() { printf '\n\e[1m==> %s\e[0m\n' "$*"; }
okk() { printf '  ok  %s\n' "$*"; }
wrn() { printf '  \e[33m!!\e[0m  %s\n' "$*"; }

say "host"
okk "kernel $(uname -r); $(pveversion 2>/dev/null | head -1)"
lsmod | grep -q '^amdgpu' && okk "amdgpu geladen" || wrn "amdgpu is niet geladen (modprobe amdgpu; staat hij op een blacklist voor VFIO?)"
for d in /sys/bus/pci/devices/*; do
  [ "$(cat "$d/vendor" 2>/dev/null)" = 0x1002 ] && [ "$(cat "$d/class" 2>/dev/null | cut -c1-6)" = 0x0300 ] || continue
  drv=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)
  okk "$(basename "$d") device $(cat "$d/device") driver=${drv:-geen} link $(cat "$d/current_link_speed" 2>/dev/null) x$(cat "$d/current_link_width" 2>/dev/null)"
  [ "$drv" = vfio-pci ] && wrn "deze kaart hangt aan vfio-pci (VM-passthrough): voor een LXC moet amdgpu hem hebben"
done
[ -e /dev/kfd ] && okk "/dev/kfd: $(ls -l /dev/kfd | awk '{print $5$6}' | tr -d ,) (major,minor)" || wrn "/dev/kfd ontbreekt"
ls -l /dev/dri/ 2>/dev/null | grep -E 'card|render' | sed 's/^/      /'

say "IOMMU"
cl=$(cat /proc/cmdline)
if [ -d /sys/kernel/iommu_groups ] && [ -n "$(ls /sys/kernel/iommu_groups 2>/dev/null)" ]; then
  echo "$cl" | grep -q 'iommu=pt' && okk "IOMMU aan met iommu=pt" || \
    wrn "IOMMU staat aan zonder iommu=pt: AMD raadt iommu=pt aan voor ROCm (DMA naar gepind host-geheugen). Voeg 'iommu=pt' toe aan de kernel-cmdline (/etc/kernel/cmdline of GRUB) en herstart - dit raakt VFIO-passthrough van andere kaarten niet."
else okk "IOMMU uit (geen iommu-groepen)"; fi

say "geheugen"
okk "host RAM $(awk '/MemTotal/{print int($2/1048576)}' /proc/meminfo) GiB, vrij $(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo) GiB"
okk "THP: $(cat /sys/kernel/mm/transparent_hugepage/enabled); hugetlb 2M: $(cat /proc/sys/vm/nr_hugepages)"
command -v zpool >/dev/null && { arc=$(awk '/^c_max/{print int($3/1073741824)}' /proc/spl/kstat/zfs/arcstats 2>/dev/null); okk "ZFS ARC max ${arc:-?} GiB (telt mee bij de host, niet bij de LXC)"; }

say "voorgestelde regels voor /etc/pve/lxc/${CT:-<CTID>}.conf"
echo "dev0: /dev/kfd,gid=44"
for r in /dev/dri/renderD*; do [ -e "$r" ] && echo "dev1: $r,gid=44" && break; done
echo "lxc.prlimit.memlock: unlimited"
echo "swap: 0"
echo "# memory: 98304   (of meer; laat de host >= 16 GiB over + ZFS ARC)"
if [ -n "$CT" ] && [ -f "/etc/pve/lxc/$CT.conf" ]; then
  say "huidige /etc/pve/lxc/$CT.conf"
  grep -E '^(cores|memory|swap|dev[0-9]|lxc\.|unprivileged|features)' "/etc/pve/lxc/$CT.conf" | sed 's/^/      /'
fi
