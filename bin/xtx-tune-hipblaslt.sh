#!/usr/bin/env bash
# strata-xtx: kalibreer een hipBLASLt-tabel voor DEZE kaart en DEZE geïnstalleerde hipBLASLt-versie.
#
# Waarom: de engine gebruikt een tabel alleen als arch + hipBLASLt-versie exact passen; anders leest hij prompts via
# plain hipBLAS (upstream: tot ~45% trager bij 131K, 926 vs 1.687 tok/s op een 7900 XTX). De meegeleverde tabellen
# dekken niet elke versie, en die voor 1.2.x/1.5.0 missen de "small-T" expert-GEMM-rijen die op 1.4.1 +32% prompt
# gaven. Dit script tunet de UNIE van alle gfx1100-geometrieën van upstream, en voegt T-buckets 16384/32768 toe voor
# de dichte GEMM's (ons profiel leest prompts in chunks tot 32768). Resultaat: $STATE_DIR/hipblaslt/, en xtx-config
# zet STRATA_HIPBLASLT_TUNING erop zodra hij bij de versie past en meer rijen heeft dan de meegeleverde.
#
# De service wordt hiervoor gestopt (de GPU moet vrij zijn) en daarna weer gestart. Duur: ~5-20 minuten.
# Opties: --no-big-t (geen 16384/32768-buckets)
. "$(dirname "$(readlink -f "$0")")/xtx-lib.sh"
need_root
BIG_T=1
while [ $# -gt 0 ]; do case "$1" in --no-big-t) BIG_T=0 ;; *) die "onbekende optie $1" ;; esac; shift; done

meta="$STRATA_DIR/engine/BUILD.json"
[ -f "$meta" ] || die "geen engine/BUILD.json: eerst xtx-bootstrap"
mapfile -t LIBS < <(jq -r '.lib_dirs[]' "$meta")
ROOT=$(dirname "${LIBS[0]}")
[ -x "$ROOT/llvm/bin/clang++" ] || [ -x "$ROOT/lib/llvm/bin/clang++" ] || [ -x "$ROOT/bin/hipcc" ] || die "ROCm-root niet gevonden ($ROOT)"
hdr="$ROOT/include/hipblaslt/hipblaslt-version.h"
VER=$(awk '/HIPBLASLT_VERSION_MAJOR/{a=$3}/HIPBLASLT_VERSION_MINOR/{b=$3}/HIPBLASLT_VERSION_PATCH/{c=$3}END{if(a!="")printf "%d", a*100000+b*100+c}' "$hdr" 2>/dev/null)
[ -n "$VER" ] || die "hipBLASLt-versie niet leesbaar uit $hdr"
ok "ROCm $ROOT, hipBLASLt $VER"

export HIP_PLATFORM=amd HIP_COMPILER=clang HIP_RUNTIME=rocclr ROCM_PATH="$ROOT" HIP_PATH="$ROOT"
LDP=$(IFS=:; echo "${LIBS[*]}")
CMAKE=$( [ -x "$STRATA_DIR/.venv/bin/cmake" ] && echo "$STRATA_DIR/.venv/bin/cmake" || command -v cmake)

say "tune_hipblaslt bouwen"
( cd "$STRATA_DIR" && as_user env PATH="$ROOT/bin:$ROOT/llvm/bin:$ROOT/lib/llvm/bin:$STRATA_DIR/.venv/bin:$PATH" LD_LIBRARY_PATH="$LDP" \
    HIP_PLATFORM=amd ROCM_PATH="$ROOT" HIP_PATH="$ROOT" \
    "$CMAKE" --build build-hip --target tune_hipblaslt -j "$(nproc)" ) || die "bouwen mislukte (is build-hip er nog? anders: xtx-update.sh --force)"
TUNE="$STRATA_DIR/build-hip/tune_hipblaslt"

# de cases: unie van alle gfx1100-tabellen (rij = dtype N K ldy T sol) + grote T-buckets voor de dichte GEMM's
CASES=$(cat "$STRATA_DIR"/tools/hip/gfx1100-hipblaslt-*.txt | awk -v big=$BIG_T '
  /^STRATA_HIPBLASLT_TUNING_V1/ || /^#/ || NF < 6 {next}
  { k=$1","$5","$2","$3","$4; if(!(k in s)){s[k]=1; print k}
    if (big && ($5==4096 || $5==8192) && $2>=512) for (t=16384; t<=32768; t*=2) { k2=$1","t","$2","$3","$4; if(!(k2 in s)){s[k2]=1; print k2} } }')
n=$(printf '%s\n' "$CASES" | wc -l)
ok "$n cases (unie van upstream's gfx1100-tabellen$([ $BIG_T = 1 ] && echo ' + T=16384/32768'))"
args=(); while read -r c; do args+=(--case "$c"); done <<<"$CASES"

was=0; systemctl is-active --quiet "$SERVICE" && { was=1; say "service stoppen (GPU vrijmaken)"; systemctl stop "$SERVICE"; }
trap '[ $was = 1 ] && systemctl start "$SERVICE"' EXIT
out="$STATE_DIR/hipblaslt"; install -d -o "$SERVICE_USER" "$out"
tmp=$(as_user mktemp -d)
# eerst één zware case om de klokken op te warmen (upstream: de eerste baseline-meting is anders te snel/traag)
as_user env LD_LIBRARY_PATH="$LDP" "$TUNE" --case f16,8192,12288,2560,12288 >/dev/null 2>&1 || true
say "tunen (elke kandidaat wordt eerst op juistheid tegen hipBLAS gecontroleerd)"
as_user env LD_LIBRARY_PATH="$LDP" "$TUNE" --workspace-mib 32 "${args[@]}" --tuning-out "$tmp/table.txt" > "$tmp/tune.log" 2>&1
tail -5 "$tmp/tune.log"
[ -s "$tmp/table.txt" ] || die "tune schreef geen tabel (log: $tmp/tune.log)"
final="$out/gfx1100-hipblaslt-$VER.txt"
cp "$tmp/table.txt" "$final.new"
head -2 "$final.new" | grep -q "STRATA_HIPBLASLT_TUNING_V1 gfx1100 $VER" || die "onverwachte kop in de tabel: $(head -2 "$final.new")"
[ -f "$final" ] && cp "$final" "$final.prev"
mv "$final.new" "$final"; chown "$SERVICE_USER" "$final"; cp "$tmp/tune.log" "$out/tune-$VER.log" 2>/dev/null
ok "tabel: $final ($(grep -cvE '^(#|STRATA_)' "$final") rijen)"

apply_config
trap - EXIT
if [ $was = 1 ]; then
  systemctl start "$SERVICE"; wait_loaded "$UPDATE_SMOKE_TIMEOUT" && smoke_test && ok "service draait met de nieuwe tabel" \
    || warn "service niet gezond: zet terug met: rm $final; xtx-apply.sh"
fi
echo "Controle: journalctl -u $SERVICE | grep 'hipBLASLt tuning enabled'   (moet $VER en het aantal rijen noemen)"
echo "Meet daarna met xtx-bench.sh; STRATA_HIPBLASLT_VERBOSE=1 in de env laat 'fallbacks=0' zien als alle vormen gedekt zijn."
