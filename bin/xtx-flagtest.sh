#!/usr/bin/env bash
# strata-xtx: test per decode-schakelaar of hij snelheid kost (leave-one-out).
# Maakt tijdelijk 7 profielen "zonder-<SCHAKELAAR>" (xtx-optimaal min die ene schakelaar), meet ze tegen xtx-optimaal
# (8k-prompt, 10 runs, 3 rondes) en ruimt de tijdelijke profielen daarna op.
# Draait als losse service 'xtx-flagtest' (venster sluiten stopt hem niet). Log: /var/log/xtx-flagtest.log.
#   bash /opt/ai/strata-xtx-0149/bin/xtx-flagtest.sh
# Klaar = regel 'FLAGTEST KLAAR'. Is een "zonder-X" duidelijk sneller dan xtx-optimaal, dan kost X snelheid.
here=$(dirname "$(readlink -f "$0")")
LOG=/var/log/xtx-flagtest.log
FLAGS="STRATA_QFUSE STRATA_MMVF_ROWS STRATA_ATTN_LANECELL STRATA_ATTN_MERGE_V2 STRATA_TSUM STRATA_EXPDEC STRATA_SPEC_COST"
if [ "${1:-}" != "--run" ]; then
  [ "$(id -u)" -eq 0 ] || { echo "FOUT: draai als root" >&2; exit 1; }
  systemctl stop xtx-flagtest 2>/dev/null; systemctl reset-failed xtx-flagtest 2>/dev/null
  echo "=== start $(date -Is)" >> "$LOG"
  systemd-run --unit=xtx-flagtest --collect -p StandardOutput=append:"$LOG" -p StandardError=append:"$LOG" \
    /bin/bash "$here/xtx-flagtest.sh" --run </dev/null || { echo "FOUT: starten mislukte" >&2; exit 1; }
  echo "schakelaartest gestart. Log volgen (Ctrl+C stopt alleen het meekijken)."
  exec tail -n +1 -f "$LOG"
fi
. "$here/xtx-lib.sh"
need_root
P="$XTX_DIR/profiles"
[ -f "$P/xtx-optimaal.json" ] || die "geen $P/xtx-optimaal.json"
arms=(xtx-optimaal)
cleanup() { for f in $FLAGS; do rm -f "$P/zonder-${f#STRATA_}.json"; done; }
trap cleanup EXIT
for f in $FLAGS; do
  n="zonder-${f#STRATA_}"
  python3 - "$P/xtx-optimaal.json" "$P/$n.json" "$f" <<'EOF' || die "profiel $n maken mislukte"
import json, sys
src, dst, flag = sys.argv[1:4]
d = json.load(open(src))
assert "inherits" not in d, "xtx-optimaal moet plat zijn"
if flag not in d.get("env", {}): sys.exit(f"{flag} staat niet in xtx-optimaal")
d["env"].pop(flag)
d["description"] = f"Tijdelijk (xtx-flagtest): xtx-optimaal zonder {flag}."
json.dump(d, open(dst, "w"), indent=1)
EOF
  arms+=("$n")
done
say "FLAGTEST: ${arms[*]} (8k, 10 runs, 3 rondes)"
bash "$here/xtx-bench.sh" --sizes 8k --runs 10 --rounds 3 "${arms[@]}" || die "de meting mislukte"
d=$(ls -dt "$STATE_DIR"/bench/*/ 2>/dev/null | head -1)
say "decode per profiel (alle runs, alle rondes)"
python3 - "${d}results.jsonl" <<'EOF' | tee "${d}flagtest.txt"
import json, statistics, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
rows = [r for r in rows if not r.get("cache_n") and r.get("decode_tps")]
labels = list(dict.fromkeys(r["label"] for r in rows))
ref = statistics.median(r["decode_tps"] for r in rows if r["label"] == "xtx-optimaal")
print(f"{'profiel':<22}{'n':>4}{'mediaan':>9}{'gemiddeld':>11}{'laagste':>9}{'t.o.v. optimaal':>17}")
for L in labels:
    v = [r["decode_tps"] for r in rows if r["label"] == L]
    m = statistics.median(v)
    rel = "" if L == "xtx-optimaal" else f"{100 * (m / ref - 1):+.1f}%"
    print(f"{L:<22}{len(v):>4}{m:>9.1f}{statistics.mean(v):>11.1f}{min(v):>9.1f}{rel:>17}")
print("\n+% = zonder die schakelaar sneller (de schakelaar kost snelheid); -% = de schakelaar helpt.")
EOF
ok "FLAGTEST KLAAR. Resultaten: ${d:-?}"
