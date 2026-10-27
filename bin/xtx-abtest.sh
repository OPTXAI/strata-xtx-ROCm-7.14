#!/usr/bin/env bash
# strata-xtx: A/B-test xtx-optimaal tegen xtx-optimaal zonder een of meer schakelaars (gepaard per run).
#   bash /opt/ai/strata-xtx-0149/bin/xtx-abtest.sh                         standaard: zonder STRATA_MMVF_ROWS en STRATA_SPEC_COST
#   bash /opt/ai/strata-xtx-0149/bin/xtx-abtest.sh STRATA_TSUM             zonder deze schakelaar(s)
# 8k-prompt, 10 runs, 6 rondes. Draait als losse service 'xtx-abtest' (venster sluiten stopt hem niet).
# Log: /var/log/xtx-abtest.log. Klaar = regel 'ABTEST KLAAR'. Het tijdelijke profiel wordt na afloop verwijderd.
here=$(dirname "$(readlink -f "$0")")
LOG=/var/log/xtx-abtest.log
if [ "${1:-}" != "--run" ]; then
  [ "$(id -u)" -eq 0 ] || { echo "FOUT: draai als root" >&2; exit 1; }
  systemctl stop xtx-abtest 2>/dev/null; systemctl reset-failed xtx-abtest 2>/dev/null
  echo "=== start $(date -Is)" >> "$LOG"
  systemd-run --unit=xtx-abtest --collect -p StandardOutput=append:"$LOG" -p StandardError=append:"$LOG" \
    /bin/bash "$here/xtx-abtest.sh" --run "$@" </dev/null || { echo "FOUT: starten mislukte" >&2; exit 1; }
  echo "A/B-test gestart. Log volgen (Ctrl+C stopt alleen het meekijken)."
  exec tail -n +1 -f "$LOG"
fi
shift
FLAGS="${*:-STRATA_MMVF_ROWS STRATA_SPEC_COST}"
. "$here/xtx-lib.sh"
need_root
P="$XTX_DIR/profiles"
B=zonder-test
[ -f "$P/xtx-optimaal.json" ] || die "geen $P/xtx-optimaal.json"
trap 'rm -f "$P/$B.json"' EXIT
python3 - "$P/xtx-optimaal.json" "$P/$B.json" $FLAGS <<'EOF' || die "profiel $B maken mislukte"
import json, sys
src, dst, flags = sys.argv[1], sys.argv[2], sys.argv[3:]
d = json.load(open(src))
assert "inherits" not in d, "xtx-optimaal moet plat zijn"
for f in flags:
    if f not in d.get("env", {}): sys.exit(f"{f} staat niet in xtx-optimaal")
    d["env"].pop(f)
d["description"] = "Tijdelijk (xtx-abtest): xtx-optimaal zonder " + ", ".join(flags) + "."
json.dump(d, open(dst, "w"), indent=1)
EOF
say "ABTEST: xtx-optimaal tegen xtx-optimaal zonder $FLAGS (8k, 10 runs, 6 rondes)"
bash "$here/xtx-bench.sh" --sizes 8k --runs 10 --rounds 6 xtx-optimaal "$B" || die "de meting mislukte"
d=$(ls -dt "$STATE_DIR"/bench/*/ 2>/dev/null | head -1)
say "gepaarde vergelijking (zelfde prompt, zelfde ronde, zelfde run)"
python3 - "${d}results.jsonl" "$B" "$FLAGS" <<'EOF' | tee "${d}abtest.txt"
import json, math, statistics, sys
path, b, flags = sys.argv[1:4]
rows = [json.loads(l) for l in open(path) if l.strip()]
A = [r for r in rows if r["label"] == "xtx-optimaal"]
Bv = [r for r in rows if r["label"] == b]
pairs = [(x["decode_tps"], y["decode_tps"]) for x, y in zip(A, Bv)
         if x["run"] == y["run"] and not x.get("cache_n") and not y.get("cache_n") and x["decode_tps"] and y["decode_tps"]]
a = [p[0] for p in pairs]; z = [p[1] for p in pairs]; dif = [q - p for p, q in pairs]
n = len(dif); m = statistics.mean(dif); se = statistics.stdev(dif) / math.sqrt(n); ma = statistics.mean(a)
print(f"paren: {n}")
print(f"xtx-optimaal              mediaan {statistics.median(a):.1f}  gemiddeld {ma:.1f} tok/s")
print(f"zonder {flags:<19}mediaan {statistics.median(z):.1f}  gemiddeld {statistics.mean(z):.1f} tok/s")
print(f"verschil (zonder - met): {m:+.2f} tok/s = {100*m/ma:+.1f}%, 95%-interval {100*(m-2*se)/ma:+.1f}% .. {100*(m+2*se)/ma:+.1f}%")
print(f"zonder sneller in {sum(1 for x in dif if x > 0)} van {n} paren")
if m - 2 * se > 0: print("conclusie: zonder deze schakelaar(s) is sneller (interval helemaal boven 0)")
elif m + 2 * se < 0: print("conclusie: deze schakelaar(s) helpen (interval helemaal onder 0)")
else: print("conclusie: geen aantoonbaar verschil (interval bevat 0)")
EOF
ok "ABTEST KLAAR. Resultaten: ${d:-?}"
