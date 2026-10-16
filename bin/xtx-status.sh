#!/usr/bin/env bash
# strata-xtx: kort overzicht - versie, patches, profiel, service, laatste update, live snelheid.
. "$(dirname "$(readlink -f "$0")")/xtx-lib.sh"
"$XTX_DIR/bin/xtx-patches.sh" status 2>/dev/null
cfg=$(find_config 2>/dev/null) && echo "run-config    : $cfg (profiel $(jq -r '._xtx.profile // "-"' "$cfg"))"
echo "engine        : $(jq -c '{version,archs,extra_cmake}' "$STRATA_DIR/engine/BUILD.json" 2>/dev/null)"
echo "service       : $(systemctl is-active "$SERVICE") ($(systemctl is-enabled "$SERVICE" 2>/dev/null)); timer: $(systemctl is-enabled "$XTX_NAME-update.timer" 2>/dev/null)"
echo "laatste update: $(cat "$STATE_DIR/last-update.json" 2>/dev/null || echo -)"
st=$(curl -fsS -m 5 -H "$(auth_header)" "http://127.0.0.1:$PORT/v1/status" 2>/dev/null) && \
  echo "laatste vraag : $(printf '%s' "$st" | jq -c '.last_timings | {prompt_n, cache_n, prompt_per_second, predicted_per_second}' 2>/dev/null)"
