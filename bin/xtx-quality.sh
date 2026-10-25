#!/usr/bin/env bash
# strata-xtx: kwaliteitscontrole van tuning-profielen (needle-test op 32K/128K + 6 codevragen met uitvoerbare tests).
#
#   xtx-quality.sh [--sizes 32k,128k] [--seeds 2] [PROFIEL ...]        standaard: xtx-max xtx-max-f16-gdn (ontbreekt f16-gdn: stock xtx-max)
#
# Elk profiel krijgt een verse engine en dezelfde prompts. Na afloop staat het profiel uit xtx.conf (PROFILE) weer actief.
# Resultaten: /var/lib/<naam>/quality/<datum>/. Duur: ~10 min per profiel.
. "$(dirname "$(readlink -f "$0")")/xtx-lib.sh"
need_root
SIZES=32k,128k; SEEDS=2; PROFILES=()
while [ $# -gt 0 ]; do
  case "$1" in --sizes) SIZES="$2"; shift ;; --seeds) SEEDS="$2"; shift ;;
    -*) die "onbekende optie $1" ;; *) PROFILES+=("$1") ;; esac; shift
done
if [ ${#PROFILES[@]} -eq 0 ]; then   # standaard: wat deze variant heeft; minder dan twee profielen? dan stock ernaast
  for p in xtx-max xtx-max-f16-gdn; do [ -f "$XTX_DIR/profiles/$p.json" ] && PROFILES+=("$p"); done
  [ ${#PROFILES[@]} -ge 2 ] || PROFILES=(stock "${PROFILES[@]}")
fi
for p in "${PROFILES[@]}"; do [ -f "$XTX_DIR/profiles/$p.json" ] || die "geen profiel $p"; done

dir="$STATE_DIR/quality/$(date +%Y%m%d-%H%M%S)"; install -d "$dir"
out="$dir/results.jsonl"
cfg=$(find_config) || die "geen run-config"
trap 'say "profiel $PROFILE terugzetten"; apply_config "$cfg" "$PROFILE" >/dev/null; systemctl restart "$SERVICE"' EXIT
{ echo "datum: $(date -Is)"; echo "strata: $(git_s log -1 --format='%h %s')"; echo "model: $MODEL ($FAMILY), context $CONTEXT"; } > "$dir/machine.txt"

for p in "${PROFILES[@]}"; do
  say "kwaliteit: $p"
  apply_config "$cfg" "$p" > "$dir/config-$p.txt"
  systemctl restart "$SERVICE"
  wait_loaded "$UPDATE_SMOKE_TIMEOUT" || { warn "$p laadde niet - overgeslagen"; continue; }
  STRATA_API_KEY="$API_KEY" python3 "$XTX_DIR/bin/xtx-quality.py" --url "http://127.0.0.1:$PORT" --label "$p" \
    --out "$out" --sizes "$SIZES" --seeds "$SEEDS" --context "$CONTEXT" | tee -a "$dir/quality.log"
done

say "samenvatting"
[ -s "$out" ] || die "geen resultaten"
python3 - "$out" <<'EOF' | tee "$dir/summary.txt"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
labels = list(dict.fromkeys(r["label"] for r in rows))
sizes = sorted({r["size"] for r in rows if r["kind"] == "needle"})
head = f"{'profiel':<18}" + "".join(f"{'needle ' + str(s // 1024) + 'K':>13}" for s in sizes) + f"{'code':>8}"
print(head)
for L in labels:
    line = f"{L:<18}"
    for s in sizes:
        sel = [r for r in rows if r["label"] == L and r["kind"] == "needle" and r["size"] == s]
        line += f"{sum(r['ok'] for r in sel):>9}/{len(sel):<3}"
    sel = [r for r in rows if r["label"] == L and r["kind"] == "code"]
    line += f"{sum(r['ok'] for r in sel):>5}/{len(sel)}"
    print(line)
bad = [r for r in rows if not r["ok"]]
if bad:
    print("\nfouten:")
    for r in bad:
        what = f"needle {r['size'] // 1024}K diepte {int(r['depth'] * 100)}% seed {r['seed']}" if r["kind"] == "needle" else f"code {r['task']} ({r['detail']})"
        print(f"  {r['label']}: {what}")
else:
    print("\nalles goed")
EOF
ok "resultaten: $dir"
