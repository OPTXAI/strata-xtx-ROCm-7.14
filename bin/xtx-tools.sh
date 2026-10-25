#!/usr/bin/env bash
# strata-xtx: installeer en update de toolchain in de LXC (git, compiler, cmake, ninja, python, diagnose-tools).
# Veilig om vaak te draaien: alleen apt install/upgrade van deze pakketten, plus pip/cmake/ninja in Strata's .venv.
. "$(dirname "$(readlink -f "$0")")/xtx-lib.sh"
need_root

export DEBIAN_FRONTEND=noninteractive
command -v apt-get >/dev/null || die "deze scripts verwachten Ubuntu/Debian (apt-get)"

. /etc/os-release
PKGS=(git git-lfs build-essential cmake ninja-build pkg-config ccache
      python3 python3-venv python3-pip python3-dev
      curl wget ca-certificates gnupg jq rsync
      pciutils usbutils kmod procps psmisc lsof numactl hwloc htop
      util-linux iproute2 tmux less nano)

# locale: zonder deze blijven perl/apt waarschuwen ("Setting locale failed")
if ! locale -a 2>/dev/null | grep -qi '^en_US.utf8$'; then
  apt-get install -y -qq locales >/dev/null 2>&1 && sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen en_US.UTF-8 >/dev/null && update-locale LANG=en_US.UTF-8 >/dev/null 2>&1
fi
export LC_ALL=C.UTF-8

say "apt: pakketlijsten verversen"
apt-get update -qq || die "apt-get update mislukte"

if [ "${GIT_PPA}" = "yes" ] && [ "${ID}" = "ubuntu" ]; then
  if ! grep -rqs "git-core/ppa" /etc/apt/sources.list /etc/apt/sources.list.d/; then
    say "git: ppa:git-core/ppa toevoegen (nieuwste stabiele git)"
    apt-get install -y -qq software-properties-common >/dev/null
    add-apt-repository -y ppa:git-core/ppa >/dev/null && apt-get update -qq || warn "PPA toevoegen mislukte: Ubuntu's eigen git blijft"
  fi
fi

say "toolchain installeren / bijwerken"
apt-get install -y -qq --no-install-recommends "${PKGS[@]}" >/dev/null || die "apt-get install mislukte"
# alleen de toolchain-pakketten upgraden (geen volledige dist-upgrade van de container)
apt-get install -y -qq --only-upgrade "${PKGS[@]}" >/dev/null || warn "upgrade van een pakket mislukte"
# ROCm uit AMD's apt-repo (apt-variant): kleine updates binnen dezelfde X.Y meenemen
if [ "$ROCM_SOURCE" = apt ] && [ -n "$ROCM_APT" ] && [ "$ROCM_APT" != latest ]; then
  mapfile -t rp < <(rocm_apt_pkgs "$ROCM_APT")
  apt-get install -y -qq --only-upgrade "${rp[@]}" >/dev/null 2>&1 && ok "ROCm $ROCM_APT (apt) bijgewerkt" || warn "ROCm-apt-upgrade mislukte"
fi
# radeontop / amdgpu_top zijn handig voor live GPU-gebruik op een headless kaart
apt-get install -y -qq radeontop >/dev/null 2>&1 || true

ok "git $(git --version | awk '{print $3}'), gcc $(gcc -dumpversion), cmake $(cmake --version | head -1 | awk '{print $3}'), ninja $(ninja --version), python $(python3 -V | awk '{print $2}')"

# Strata's eigen venv (setup gebruikt cmake/ninja daaruit wanneer die nieuwer zijn)
if [ -x "$STRATA_DIR/.venv/bin/python" ]; then
  say "Strata .venv: pip / cmake / ninja bijwerken"
  as_user "$STRATA_DIR/.venv/bin/python" -m pip install -q --upgrade --disable-pip-version-check pip cmake ninja \
    && ok "venv bijgewerkt" || warn "pip upgrade in .venv mislukte"
fi

date -Is > "$STATE_DIR/tools-updated" 2>/dev/null || true
