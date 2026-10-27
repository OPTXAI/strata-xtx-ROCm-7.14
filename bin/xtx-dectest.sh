#!/usr/bin/env bash
# strata-xtx: decode-test van de profielen xtx-dec1/2/3 tegen het huidige standaardprofiel.
# Draait als losse service 'xtx-dectest' (venster sluiten stopt hem niet). Log: /var/log/xtx-dectest.log.
#   bash /opt/ai/strata-xtx-0149/bin/xtx-dectest.sh
# Na afloop staat het profiel uit xtx.conf weer actief (xtx-bench zet het terug). Klaar = regel 'DECTEST KLAAR'.
here=$(dirname "$(readlink -f "$0")")
LOG=/var/log/xtx-dectest.log
if [ "${1:-}" != "--run" ]; then
  [ "$(id -u)" -eq 0 ] || { echo "FOUT: draai als root" >&2; exit 1; }
  systemctl stop xtx-dectest 2>/dev/null; systemctl reset-failed xtx-dectest 2>/dev/null
  echo "=== start $(date -Is)" >> "$LOG"
  systemd-run --unit=xtx-dectest --collect -p StandardOutput=append:"$LOG" -p StandardError=append:"$LOG" \
    /bin/bash "$here/xtx-dectest.sh" --run </dev/null || { echo "FOUT: starten mislukte" >&2; exit 1; }
  echo "decode-test gestart (± 60-90 min). Log volgen (Ctrl+C stopt alleen het meekijken)."
  exec tail -n +1 -f "$LOG"
fi
. "$here/xtx-lib.sh"
need_root
say "DECTEST: $PROFILE tegen xtx-dec1 xtx-dec2 xtx-dec3 (8k + 32k, 3 runs, 2 rondes)"
bash "$here/xtx-bench.sh" --sizes 8k,32k --runs 3 --rounds 2 "$PROFILE" xtx-dec1 xtx-dec2 xtx-dec3 || die "de meting mislukte"
d=$(ls -dt "$STATE_DIR"/bench/*/ 2>/dev/null | head -1)
echo; [ -f "${d}summary.txt" ] && cat "${d}summary.txt"
ok "DECTEST KLAAR. Resultaten: ${d:-?}"
