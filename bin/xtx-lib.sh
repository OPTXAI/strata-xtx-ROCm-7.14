#!/usr/bin/env bash
# strata-xtx: gedeelde functies. Wordt ge-"source"d door de andere xtx-* scripts.
set -o pipefail

XTX_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XTX_NAME=strata-xtx; CMD_PREFIX=xtx; STRATA_DIR_DEFAULT=/opt/ai/strata; ROCM_VERSION_DEFAULT=; ROCM_INDEX_DEFAULT=; CONFLICTS=
ROCM_SOURCE_DEFAULT=wheel; ROCM_APT_DEFAULT=
# shellcheck disable=SC1091
[ -f "$XTX_SELF_DIR/variant.env" ] && . "$XTX_SELF_DIR/variant.env"
XTX_CONF="${XTX_CONF:-/etc/$XTX_NAME/xtx.conf}"

# --- standaardwaarden (overschreven door xtx.conf) ---
STRATA_DIR=$STRATA_DIR_DEFAULT
DATA_DIR=/opt/ai/Strata-data
XTX_DIR="$XTX_SELF_DIR"
SERVICE_USER=strata
UPSTREAM_URL=https://github.com/Niko1221/Strata.git
UPSTREAM_BRANCH=main
KEEP_GOOD_TAGS=10
FAMILY=qwen
MODEL=IQ3_S
CONTEXT=262144
KV=int8
VISION=cpu
HOST=0.0.0.0
PORT=8080
API_KEY=
PROFILE=xtx-max
AUTO_TUNE=yes
AUTO_CALIBRATE=yes
VRAM_RESERVE_MIB=512
MEMORY_LIMIT_MIB=auto
RESIDENT_HEADROOM_GIB=
BUILD_JOBS=
EXTRA_CMAKE_ARGS=
ROCM_VERSION=$ROCM_VERSION_DEFAULT
ROCM_INDEX=$ROCM_INDEX_DEFAULT
ROCM_SOURCE=$ROCM_SOURCE_DEFAULT          # wheel = AMD's pip-wheels in .venv | apt = systeem-ROCm uit AMD's apt-repo
ROCM_APT=$ROCM_APT_DEFAULT                # apt: 10.1, of latest (= nieuwste bij installatie, daarna vast)
ROCM_APT_REPO=https://stable.repo.amd.com/rocm/core/packages/ubuntu2404/
ROCM_APT_KEY=https://stable.repo.amd.com/rocm/gpg/packages.gpg
GFX=gfx1100
UPDATE_SMOKE_TIMEOUT=900
UPGRADE_OS_PACKAGES=yes
GIT_PPA=yes

# shellcheck disable=SC1090
[ -f "$XTX_CONF" ] && . "$XTX_CONF"
[ -z "$API_KEY" ] && [ -r "/etc/$XTX_NAME/api-key" ] && API_KEY="$(cat "/etc/$XTX_NAME/api-key")"

SERVICE=$XTX_NAME.service
RUNTIME_ENV=/etc/$XTX_NAME/runtime.env
LOG_DIR=/var/log/$XTX_NAME
STATE_DIR=/var/lib/$XTX_NAME

c_b=$'\e[1m'; c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_0=$'\e[0m'
[ -t 1 ] || { c_b=; c_g=; c_y=; c_r=; c_0=; }
say()  { printf '%s\n' "${c_b}==>${c_0} $*"; }
ok()   { printf '%s\n' "  ${c_g}ok${c_0}  $*"; }
warn() { printf '%s\n' "  ${c_y}!!${c_0}  $*" >&2; }
die()  { printf '%s\n' "  ${c_r}FOUT${c_0} $*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "draai dit als root (sudo $0 $*)"; }

as_user() {   # een commando als SERVICE_USER, met een schone login-achtige omgeving
  if [ "$(id -un)" = "$SERVICE_USER" ]; then "$@"; else runuser -u "$SERVICE_USER" -- "$@"; fi
}

git_s() { as_user git -C "$STRATA_DIR" "$@"; }   # git altijd als SERVICE_USER: geen root-bestanden in de clone

# het run-config dat setup schreef voor MODEL (strata-<model>.json), of de nieuwste
find_config() {
  local want f
  want="$STRATA_DIR/strata-$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]').json"
  [ -f "$want" ] && { echo "$want"; return 0; }
  f=$(ls -t "$STRATA_DIR"/strata-*.json 2>/dev/null | grep -v -e '\.shared-settings\.json$' -e '\.bak$' | head -1)
  [ -n "$f" ] && { echo "$f"; return 0; }
  return 1
}

setup_env() {   # de omgeving die setup.py meekrijgt
  local e=(LANG=C.UTF-8 PYTHONUNBUFFERED=1 HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)" PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
  e+=(STRATA_BUILD_JOBS="${BUILD_JOBS:-$(nproc)}")
  [ -n "$EXTRA_CMAKE_ARGS" ] && e+=(STRATA_EXTRA_CMAKE_ARGS="$EXTRA_CMAKE_ARGS")
  if [ "$ROCM_SOURCE" = apt ]; then   # setup gebruikt een systeem-ROCm via ROCM_PATH
    local r; r=$(rocm_apt_root) && e+=(ROCM_PATH="$r")
  else   # nooit per ongeluk een systeem-ROCm (/opt/rocm, bv. van de apt-variant) oppikken: altijd de wheels
    e+=(ROCM_PATH=/var/empty/xtx-no-system-rocm)
    [ -n "$ROCM_VERSION" ] && e+=(STRATA_ROCM_VERSION="$ROCM_VERSION")
    [ -n "$ROCM_INDEX" ] && e+=(STRATA_ROCM_INDEX="$ROCM_INDEX")
  fi
  printf '%s\n' "${e[@]}"
}

run_setup() {   # ./setup.sh <args> als SERVICE_USER, niet-interactief
  local envs=()
  mapfile -t envs < <(setup_env)
  ( cd "$STRATA_DIR" && as_user env -i "${envs[@]}" ./setup.sh "$@" )
}

auth_header() { [ -n "$API_KEY" ] && printf 'Authorization: Bearer %s' "$API_KEY" || printf 'X-None: 1'; }

wait_loaded() {   # wacht tot /health "loaded": true zegt (max $1 s)
  local t=${1:-600} i=0 body
  while [ $i -lt "$t" ]; do
    body=$(curl -fsS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)
    case "$body" in *'"loaded": true'*|*'"loaded":true'*) return 0 ;; esac
    if ! systemctl is-active --quiet "$SERVICE"; then
      systemctl is-failed --quiet "$SERVICE" && return 2
    fi
    sleep 5; i=$((i + 5))
  done
  return 1
}

smoke_test() {    # één korte greedy vraag; 0 als het antwoord "Paris" bevat
  local out
  out=$(curl -fsS -m 300 "http://127.0.0.1:$PORT/v1/chat/completions" -H "$(auth_header)" \
        -H 'Content-Type: application/json' \
        -d '{"messages":[{"role":"user","content":"What is the capital of France? Answer with one word."}],
             "max_tokens":64,"temperature":0,"reasoning_effort":"none"}' 2>&1) || { warn "smoke: $out"; return 1; }
  printf '%s' "$out" | grep -qi 'paris' && return 0
  warn "smoke: onverwacht antwoord: $(printf '%s' "$out" | head -c 400)"
  return 1
}

apply_config() {   # profiel + LXC-instellingen over het run-config, en runtime.env voor systemd
  local cfg="${1:-}" prof="${2:-$PROFILE}"
  [ -n "$cfg" ] || cfg=$(find_config) || die "geen strata-*.json in $STRATA_DIR (is setup gedraaid?)"
  XTX_API_KEY="$API_KEY" python3 "$XTX_DIR/bin/xtx-config.py" --config "$cfg" --profile "$prof" \
    --profiles-dir "$XTX_DIR/profiles" --strata-dir "$STRATA_DIR" \
    --vram-reserve-mib "$VRAM_RESERVE_MIB" --memory-limit-mib "$MEMORY_LIMIT_MIB" \
    --resident-headroom-gib "$RESIDENT_HEADROOM_GIB" --host "$HOST" --port "$PORT" \
    --table-dir "$STATE_DIR/hipblaslt" || die "xtx-config mislukte"
  install -d -m 0755 "/etc/$XTX_NAME"
  cat > "$RUNTIME_ENV" <<EOR
# geschreven door $XTX_NAME (apply_config) - niet met de hand aanpassen
STRATA_DIR=$STRATA_DIR
STRATA_CONFIG=$cfg
STRATA_PORT=$PORT
EOR
  chmod 0644 "$RUNTIME_ENV"
  ok "config: $cfg (profiel $prof)"
}

hipblaslt_installed() {   # hipBLASLt-versie van de ROCm die de engine gebruikt (bv. 100200), leeg als onbekend
  local d
  d=$(jq -r '.lib_dirs[0] // empty' "$STRATA_DIR/engine/BUILD.json" 2>/dev/null) || return 0
  [ -n "$d" ] || return 0
  awk '/HIPBLASLT_VERSION_MAJOR/{a=$3}/HIPBLASLT_VERSION_MINOR/{b=$3}/HIPBLASLT_VERSION_PATCH/{c=$3}
       END{if(a!="")printf "%d", a*100000+b*100+c}' "$(dirname "$d")/include/hipblaslt/hipblaslt-version.h" 2>/dev/null
}

need_tune() {   # 0 als er voor de geïnstalleerde hipBLASLt nog geen eigen tabel is
  local v; v=$(hipblaslt_installed)
  [ -n "$v" ] && [ ! -s "$STATE_DIR/hipblaslt/gfx1100-hipblaslt-$v.txt" ]
}

resolve_rocm_version() {   # ROCM_VERSION=latest:10 -> de nieuwste 10.x-wheel op de index (eenmalig bij installatie)
  local want=$1 idx=${ROCM_INDEX:-https://rocm.nightlies.amd.com/v2/gfx110X-dgpu/}
  case "$want" in latest:*) ;; *) printf '%s' "$want"; return 0 ;; esac
  curl -fsSL -m 60 "${idx%/}/rocm/" 2>/dev/null | python3 -c '
import re, sys
major = sys.argv[1]
vs = set(re.findall(r"rocm-(\d+\.\d+\.\d+(?:[a-z]+\d+)?)\.(?:tar\.gz|whl)", sys.stdin.read()))
key = lambda v: tuple(int(x or 0) for x in re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:[a-z]+(\d+))?", v).groups())
vs = sorted((v for v in vs if v.split(".")[0] == major), key=key)
print(vs[-1] if vs else "")' "${want#latest:}"
}

# --- ROCm uit AMD's apt-repo (ROCM_SOURCE=apt, bv. ROCm 10) ---
rocm_apt_pkgs() {   # runtime + HIP-dev + hipBLAS/hipBLASLt (+ dev), alleen voor $GFX (niet het pakket voor alle kaarten)
  printf '%s\n' "amdrocm-core-dev$1-$GFX" "amdrocm-blas$1-$GFX" "amdrocm-blas-dev$1"
}

rocm_apt_latest() {   # nieuwste X.Y waarvoor amdrocm-core-devX.Y-$GFX bestaat
  apt-cache pkgnames amdrocm-core-dev 2>/dev/null | sed -n "s/^amdrocm-core-dev\([0-9][0-9.]*\)-$GFX\$/\1/p" | sort -V | tail -1
}

rocm_apt_repo() {   # AMD's apt-repo + sleutel toevoegen (idempotent)
  local src=/etc/apt/sources.list.d/amdrocm-stable.sources key=/etc/apt/keyrings/amdrocm.gpg tmp
  [ -s "$key" ] && [ -f "$src" ] && return 0
  install -d -m 0755 /etc/apt/keyrings
  tmp=$(mktemp); curl -fsSL -m 60 "$ROCM_APT_KEY" -o "$tmp" || { rm -f "$tmp"; return 1; }
  if grep -q 'BEGIN PGP' "$tmp"; then gpg --dearmor --yes -o "$key" < "$tmp"; else cp "$tmp" "$key"; fi
  rm -f "$tmp"; chmod 0644 "$key"
  cat > "$src" <<EOS
Types: deb
URIs: $ROCM_APT_REPO
Suites: stable
Components: main
Architectures: amd64
Signed-By: $key
EOS
  apt-get update -qq
}

rocm_apt_root() {   # de map van de geïnstalleerde ROCm $ROCM_APT met hipcc, libhipblas en HIP-cmake-bestanden
  local major=${ROCM_APT%%.*} h d
  for h in $(find /opt -maxdepth 5 -path '*/bin/hipcc' 2>/dev/null | sort -rV); do
    d=$(dirname "$(dirname "$h")")
    ls "$d"/lib/libhipblas.so* >/dev/null 2>&1 || continue
    grep -qE "ROCM_VERSION_MAJOR[[:space:]]+$major\b" "$d/include/rocm-core/rocm_version.h" 2>/dev/null || continue
    [ "$ROCM_APT" = "$major" ] || grep -qE "ROCM_VERSION_MINOR[[:space:]]+${ROCM_APT#*.}\b" "$d/include/rocm-core/rocm_version.h" || continue
    readlink -f "$d"; return 0
  done
  return 1
}

need_calibrate() {   # 0 als setup voor dit model + deze context nog geen kalibratie bewaard heeft (~strata/.config/strata)
  local cfg h; cfg=$(find_config) || return 1
  h=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
  python3 - "$cfg" "$h/.config/strata/settings.json" <<'EOP'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8-sig")); a = cfg.get("args", [])
ctx = a[a.index("--max-context") + 1] if "--max-context" in a else "?"
try: cal = json.load(open(sys.argv[2], encoding="utf-8")).get("calibration") or {}
except (OSError, ValueError): cal = {}
want = f"|{cfg.get('model_name', '?')}|{ctx}|"
sys.exit(1 if any(want in k for k in cal) else 0)
EOP
}
