#!/usr/bin/env bash
# strata-xtx: zet het profiel + de instellingen uit xtx.conf (opnieuw) op het run-config en herstart de service.
#   xtx-apply.sh                 het PROFILE uit xtx.conf
#   xtx-apply.sh xtx-max         dit profiel, eenmalig (een volgende update/apply neemt weer xtx.conf)
#   xtx-apply.sh xtx-max --save  dit profiel, en ook in xtx.conf vastzetten
#   xtx-apply.sh --no-restart    alleen het config schrijven
. "$(dirname "$(readlink -f "$0")")/xtx-lib.sh"
need_root
prof=$PROFILE; save=0; restart=1
for a in "$@"; do case "$a" in --save) save=1 ;; --no-restart) restart=0 ;; -*) die "onbekende optie $a" ;; *) prof=$a ;; esac; done
[ -f "$XTX_DIR/profiles/$prof.json" ] || die "geen profiel $prof (ls $XTX_DIR/profiles)"
if [ $save -eq 1 ]; then
  grep -q '^PROFILE=' "$XTX_CONF" && sed -i "s/^PROFILE=.*/PROFILE=$prof/" "$XTX_CONF" || echo "PROFILE=$prof" >> "$XTX_CONF"
  ok "PROFILE=$prof in $XTX_CONF"
fi
apply_config "" "$prof"
[ $restart -eq 1 ] || exit 0
systemctl restart "$SERVICE"
wait_loaded "$UPDATE_SMOKE_TIMEOUT" && smoke_test && ok "service draait met profiel $prof" || die "service niet gezond: journalctl -u $SERVICE -n 100"
