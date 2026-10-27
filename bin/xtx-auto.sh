#!/usr/bin/env bash
# strata-xtx: alles achter elkaar, zonder tussenkomst (draait in de container; install.sh start dit).
#   1. installatie (xtx-bootstrap, zonder decode-kalibratie)
#   2. meting: xtx-max-f16-gdn tegen xtx-optimaal (8k/32k/64k, 2 rondes)
# Mislukt stap 1, dan is opnieuw draaien veilig: de bootstrap gaat verder waar hij stopte.
here=$(dirname "$(readlink -f "$0")")
. "$here/xtx-lib.sh"
need_root
chmod +x "$here"/*.sh "$here"/../host/*.sh 2>/dev/null   # via de GitHub-website geupload: geen uitvoerbit

say "AUTO 1/2: installatie"
bash "$here/xtx-bootstrap.sh" --no-calibrate || die "installatie mislukte (zie hierboven; opnieuw starten gaat verder waar het stopte)"

say "AUTO 2/2: meting xtx-max-f16-gdn tegen xtx-optimaal (± 30-60 min)"
bash "$here/xtx-bench.sh" --sizes 8k,32k,64k --rounds 2 xtx-max-f16-gdn xtx-optimaal || die "de meting mislukte"

d=$(ls -dt "$STATE_DIR"/bench/*/ 2>/dev/null | head -1)
echo
[ -f "${d}summary.txt" ] && cat "${d}summary.txt"
ok "AUTO KLAAR. Resultaten: ${d:-?}"
