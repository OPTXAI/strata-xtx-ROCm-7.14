#!/usr/bin/env bash
# strata-xtx: vergelijk tuning-profielen op deze machine (A/B, elke arm met een verse engine).
#
#   xtx-bench.sh [--sizes 8k,32k,64k] [--runs 3] [--rounds 2] PROFIEL [PROFIEL ...]
#   bv.  xtx-bench.sh stock xtx xtx-max
#
# Rondes wisselen de volgorde af (A B C, C B A, ...) tegen opwarm- en klokeffecten. Na afloop staat het profiel uit
# xtx.conf (PROFILE) weer actief. Resultaten: /var/lib/strata-xtx/bench/<datum>/. Duur: ~5-10 min per arm per ronde.
. "$(dirname "$(readlink -f "$0")")/xtx-lib.sh"
need_root
SIZES=8k,32k,64k; RUNS=3; ROUNDS=2; PROFILES=()
while [ $# -gt 0 ]; do
  case "$1" in --sizes) SIZES="$2"; shift ;; --runs) RUNS="$2"; shift ;; --rounds) ROUNDS="$2"; shift ;;
    -*) die "onbekende optie $1" ;; *) PROFILES+=("$1") ;; esac; shift
done
[ ${#PROFILES[@]} -ge 1 ] || PROFILES=(stock xtx)
for p in "${PROFILES[@]}"; do [ -f "$XTX_DIR/profiles/$p.json" ] || die "geen profiel $p"; done

dir="$STATE_DIR/bench/$(date +%Y%m%d-%H%M%S)"; install -d "$dir"
out="$dir/results.jsonl"
cfg=$(find_config) || die "geen run-config"
trap 'say "profiel $PROFILE terugzetten"; apply_config "$cfg" "$PROFILE" >/dev/null; systemctl restart "$SERVICE"' EXIT
{ echo "datum: $(date -Is)"; echo "strata: $(git_s log -1 --format='%h %s')"; echo "engine: $(cat "$STRATA_DIR/engine/BUILD.json" 2>/dev/null | tr -d '\n ')"
  echo "model: $MODEL ($FAMILY), context $CONTEXT"; grep -m1 'model name' /proc/cpuinfo; echo "RAM: $(awk '/MemTotal/{print int($2/1048576)" GiB"}' /proc/meminfo)"; } > "$dir/machine.txt"

order=("${PROFILES[@]}")
for round in $(seq 1 "$ROUNDS"); do
  for p in "${order[@]}"; do
    say "ronde $round: $p"
    apply_config "$cfg" "$p" > "$dir/config-$p.txt"
    systemctl restart "$SERVICE"
    wait_loaded "$UPDATE_SMOKE_TIMEOUT" || { warn "$p laadde niet - overgeslagen"; continue; }
    STRATA_API_KEY="$API_KEY" python3 "$XTX_DIR/bin/xtx-bench.py" --url "http://127.0.0.1:$PORT" --label "$p" \
      --out "$out" --sizes "$SIZES" --runs "$RUNS" | tee -a "$dir/bench.log"
  done
  # volgende ronde in omgekeerde volgorde
  rev=(); for ((i=${#order[@]}-1; i>=0; i--)); do rev+=("${order[$i]}"); done; order=("${rev[@]}")
done

say "samenvatting (medianen over alle rondes, alleen runs zonder cache-hergebruik)"
python3 - "$out" <<'EOF' | tee "$dir/summary.txt"
import json, statistics, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
rows = [r for r in rows if not r.get("cache_n") and r.get("prompt_tps")]
labels = list(dict.fromkeys(r["label"] for r in rows)); sizes = sorted({r["size"] for r in rows})
base = labels[0] if labels else None
ktok = {s: f"{statistics.median(r['prompt_n'] for r in rows if r['size'] == s) / 1000:.1f}K" for s in sizes}
print(f"{'profiel':<16}" + "".join(f"{ktok[s]+' prompt':>14}{'decode':>9}" for s in sizes))
for L in labels:
    line = f"{L:<16}"
    for s in sizes:
        sel = [r for r in rows if r["label"] == L and r["size"] == s]
        if not sel: line += f"{'-':>14}{'-':>9}"; continue
        p = statistics.median(r["prompt_tps"] for r in sel); d = statistics.median(r["decode_tps"] for r in sel)
        b = [r for r in rows if r["label"] == base and r["size"] == s]
        rel = f" {100*(p/statistics.median(x['prompt_tps'] for x in b)-1):+.0f}%" if b and L != base else ""
        line += f"{p:>9.0f}{rel:>5}{d:>9.1f}"
    print(line)
print(f"\n(K = echte prompt-tokens; % = prompt t.o.v. {base}; decode in tok/s. Verschillen onder ~3% zijn ruis.)")
EOF
ok "resultaten: $dir"
