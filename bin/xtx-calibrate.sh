#!/usr/bin/env bash
# strata-xtx: Niko's eigen kalibratie (./setup.sh --calibrate) voor decode op deze PC, headless.
#
# Meet de instellingen die van de PC afhangen en niet van het model: --pcie-frac (welk deel van de gemiste experts
# naar de GPU gaat i.p.v. op de CPU), --spec-min-p (diepte van de MTP-gok), --pool-workers (CPU-threads voor experts)
# en de adaptieve expert-cache (--adapt-every/-swaps/-decay). Alleen decode; de prompt-snelheid verandert niet.
# Duur 15-30 min; de service staat zolang uit (de kalibratie start de engine zelf). Het resultaat bewaart setup per
# PC + model in zijn settings-bestand, dus updates en herinstallaties nemen het vanzelf over.
. "$(dirname "$(readlink -f "$0")")/xtx-lib.sh"
need_root
cfg=$(find_config) || die "geen run-config: eerst xtx-bootstrap"
install -d "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/calibrate-$(date +%Y%m%d-%H%M%S).log") 2>&1

was_active=0; systemctl is-active -q "$SERVICE" && was_active=1
trap 'if [ $was_active -eq 1 ] && ! systemctl is-active -q "$SERVICE"; then systemctl start "$SERVICE"; fi' EXIT
say "service stoppen (de kalibratie heeft de GPU en het RAM nodig)"
systemctl stop "$SERVICE" 2>/dev/null

say "kalibreren (15-30 min, de PC is bezig)"
run_setup --calibrate --no-start --yes || warn "setup --calibrate gaf een fout (zie hierboven); de vorige instellingen blijven"

say "profiel $PROFILE opnieuw toepassen"
apply_config "$cfg"
ok "engine-opties nu: $(jq -c '[.args[] | select(test("^--(pcie-frac|spec-min-p|pool-workers|adapt-every|adapt-swaps|adapt-decay)$"))] as $k | [range(0; .args|length) as $i | select(.args[$i] as $a | $k | index($a)) | "\(.args[$i]) \(.args[$i+1])"]' "$cfg" 2>/dev/null)"

if [ $was_active -eq 1 ]; then
  systemctl start "$SERVICE"
  wait_loaded "$UPDATE_SMOKE_TIMEOUT" && smoke_test && ok "service draait weer" || warn "service laadde niet: journalctl -u $SERVICE"
fi
ok "meet het effect met: bash $XTX_DIR/bin/xtx-bench.sh $PROFILE  (vergelijk de decode-kolom)"
