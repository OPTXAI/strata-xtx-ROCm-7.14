#!/usr/bin/env bash
# strata-xtx: eerste installatie in de LXC. Idempotent: opnieuw draaien maakt af wat nog ontbreekt.
#
#   1. toolchain (xtx-tools)          5. setup.sh: ROCm-wheels, engine voor gfx1100, model-download (~70-120 GB)
#   2. gebruiker + mappen             6. tuning-profiel + LXC-instellingen over het run-config
#   3. upstream clonen                7. systemd-service, starten, rooktest
#   4. branch xtx = upstream + patches
#
# Opties: --no-start (alles behalve starten), --skip-check, --no-tune, --no-calibrate
. "$(dirname "$(readlink -f "$0")")/xtx-lib.sh"
need_root
NO_START=0; SKIP_CHECK=0
for a in "$@"; do case "$a" in --no-start) NO_START=1 ;; --skip-check) SKIP_CHECK=1 ;; --no-tune) AUTO_TUNE=no ;; --no-calibrate) AUTO_CALIBRATE=no ;; *) die "onbekende optie $a" ;; esac; done

install -d -m 0755 "/etc/$XTX_NAME" "$LOG_DIR" "$STATE_DIR" "$STATE_DIR/hipblaslt"
exec > >(tee -a "$LOG_DIR/bootstrap-$(date +%Y%m%d-%H%M%S).log") 2>&1
[ -f "$XTX_CONF" ] || { cp "$XTX_SELF_DIR/xtx.conf.example" "$XTX_CONF"; warn "nieuw: $XTX_CONF (standaardwaarden; pas aan en draai opnieuw als je wilt)"; }

# overlay op zijn vaste plek
if [ "$XTX_SELF_DIR" != "$XTX_DIR" ]; then
  say "overlay -> $XTX_DIR"
  install -d "$XTX_DIR"
  rsync -a --delete --exclude .git/ "$XTX_SELF_DIR"/ "$XTX_DIR"/ 2>/dev/null || cp -a "$XTX_SELF_DIR"/. "$XTX_DIR"/
fi
chmod +x "$XTX_DIR"/bin/* "$XTX_DIR"/host/*.sh 2>/dev/null
[ -d "$XTX_DIR/.git" ] && git -C "$XTX_DIR" config core.fileMode false   # anders blokkeert die chmod een latere git pull

say "1/7 toolchain"
"$XTX_DIR/bin/xtx-tools.sh" || die "xtx-tools mislukte"

say "2/7 gebruiker $SERVICE_USER"
getent group render >/dev/null || groupadd -r render
getent group video  >/dev/null || groupadd -r video
id "$SERVICE_USER" >/dev/null 2>&1 || useradd -r -m -d "/home/$SERVICE_USER" -s /bin/bash "$SERVICE_USER"
usermod -aG render,video "$SERVICE_USER"
# de gid's van de doorgegeven devices (kunnen afwijken van de groepen van de container)
for d in /dev/kfd /dev/dri/renderD*; do
  [ -e "$d" ] || continue
  g=$(stat -c %g "$d"); gn=$(getent group "$g" | cut -d: -f1)
  [ -n "$gn" ] && usermod -aG "$gn" "$SERVICE_USER" || warn "$d heeft gid $g zonder groep in de container: zie host/proxmox-lxc.conf (gid=)"
done
mkdir -p "$(dirname "$STRATA_DIR")" "$DATA_DIR"   # de oudermap (bv. /opt/ai) blijft van root
chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"   # ook een eerder (als root) gedownload model
ok "$(id "$SERVICE_USER")"
[ -z "$API_KEY" ] && [ "$HOST" != "127.0.0.1" ] && warn "geen API-sleutel: iedereen op het netwerk kan de server gebruiken (API_KEY= in xtx.conf)"

[ $SKIP_CHECK -eq 1 ] || { say "controle"; "$XTX_DIR/bin/xtx-check.sh" || die "los eerst de problemen hierboven op (of --skip-check)"; }

say "3/7 upstream"
if [ -d "$STRATA_DIR" ] && [ ! -d "$STRATA_DIR/.git" ] && [ -n "$(ls -A "$STRATA_DIR" 2>/dev/null)" ]; then
  old="$STRATA_DIR.pre-xtx-$(date +%Y%m%d-%H%M)"
  systemctl stop "$SERVICE" 2>/dev/null; pkill -f "$STRATA_DIR/serve/server.py" 2>/dev/null && sleep 5
  mv "$STRATA_DIR" "$old"
  warn "bestaande installatie zonder git verplaatst naar $old (modellen in $DATA_DIR blijven staan; verwijder $old als alles werkt)"
fi
if [ ! -d "$STRATA_DIR/.git" ]; then
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" "$STRATA_DIR"
  as_user git clone -q --branch "$UPSTREAM_BRANCH" "$UPSTREAM_URL" "$STRATA_DIR" || die "clone mislukte"
fi
git_s remote set-url origin "$UPSTREAM_URL"
git_s fetch -q origin || die "fetch mislukte"
ok "upstream: $(git_s log -1 --format='%h %cs %s' "origin/$UPSTREAM_BRANCH")"

say "4/7 patches"
if git_s rev-parse -q --verify xtx >/dev/null; then
  ok "branch xtx bestaat al ($(git_s log -1 --format=%h xtx)); bijwerken doet xtx-update.sh"
  git_s checkout -q xtx
else
  "$XTX_DIR/bin/xtx-patches.sh" build "origin/$UPSTREAM_BRANCH" || die "patches passen niet op upstream: zie de kop van xtx-patches.sh"
  git_s checkout -q -B xtx xtx-candidate && git_s branch -q -D xtx-candidate
fi

STOPPED=()
for c in $CONFLICTS; do   # RAM/GPU vrijmaken: een andere variant mag niet tegelijk draaien
  systemctl is-active -q "$c.service" 2>/dev/null && { systemctl stop "$c.service"; STOPPED+=("$c.service"); warn "$c.service gestopt (dezelfde GPU)"; }
done
# mislukt de installatie, dan draait de andere variant gewoon weer
trap 'rc=$?; if [ $rc -ne 0 ] && [ ${#STOPPED[@]} -gt 0 ]; then systemctl start "${STOPPED[@]}" && warn "${STOPPED[*]} weer gestart (installatie mislukt)"; fi' EXIT
if [ "$ROCM_SOURCE" = apt ]; then   # systeem-ROCm uit AMD's apt-repo (alleen de $GFX-pakketten)
  say "ROCm uit AMD's apt-repo"
  rocm_apt_repo || die "AMD's apt-repo toevoegen mislukte ($ROCM_APT_REPO)"
  if [ -z "$ROCM_APT" ] || [ "$ROCM_APT" = latest ]; then
    v=$(rocm_apt_latest); [ -n "$v" ] || die "geen amdrocm-core-dev*-$GFX in $ROCM_APT_REPO"
    ROCM_APT=$v
    if grep -q '^ROCM_APT=' "$XTX_CONF"; then sed -i "s/^ROCM_APT=.*/ROCM_APT=$v   # vastgezet bij installatie (was latest)/" "$XTX_CONF"
    else echo "ROCM_APT=$v" >> "$XTX_CONF"; fi
  fi
  mapfile -t rp < <(rocm_apt_pkgs "$ROCM_APT")
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${rp[@]}" >/dev/null \
    || die "apt install ${rp[*]} mislukte"
  r=$(rocm_apt_root) || die "ROCm $ROCM_APT geïnstalleerd, maar geen map met bin/hipcc + lib/libhipblas.so (find /opt -name hipcc)"
  [ -f "$r/lib/cmake/hip-lang/hip-lang-config.cmake" ] || warn "$r mist lib/cmake/hip-lang: setup valt dan terug op de wheels"
  ok "ROCm $ROCM_APT in $r ($(echo "${rp[*]}"))"
else case "$ROCM_VERSION" in latest:*)
  v=$(resolve_rocm_version "$ROCM_VERSION")
  [ -n "$v" ] || die "geen ROCm ${ROCM_VERSION#latest:}.x gevonden op ${ROCM_INDEX:-de gfx110X-dgpu-index} (zet ROCM_VERSION= in $XTX_CONF op een exacte versie)"
  ROCM_VERSION=$v
  if grep -q '^ROCM_VERSION=' "$XTX_CONF"; then sed -i "s/^ROCM_VERSION=.*/ROCM_VERSION=$v   # vastgezet bij installatie (was latest:)/" "$XTX_CONF"
  else echo "ROCM_VERSION=$v" >> "$XTX_CONF"; fi
  ok "ROCm $v (nieuwste ${v%%.*}.x op de index, vastgezet in $XTX_CONF)" ;;
esac; fi
say "5/7 setup (ROCm, engine voor gfx1100, model) - de eerste keer 30-90 minuten"
setup_args=(--backend hip --family "$FAMILY" --model "$MODEL" --context "$CONTEXT" --kv "$KV" --vision "$VISION"
            --data-dir "$DATA_DIR" --host "$HOST" --port "$PORT" --vram-reserve-mib "$VRAM_RESERVE_MIB"
            --no-browser --yes --no-start)
[ -n "$API_KEY" ] && setup_args+=(--api-key "$API_KEY")
if cfg=$(find_config) && [ -f "$STRATA_DIR/engine/BUILD.json" ]; then
  ok "al geïnstalleerd ($cfg): setup --update"
  run_setup --update --no-start || die "setup --update mislukte"
else
  run_setup --setup "${setup_args[@]}" || die "setup mislukte (log hierboven; opnieuw draaien gaat verder waar het stopte)"
fi

eng_rocm=$(jq -r '.lib_dirs[0] // empty' "$STRATA_DIR/engine/BUILD.json" 2>/dev/null)
ok "engine gebouwd tegen: ${eng_rocm:-?}"
if [ "$ROCM_SOURCE" = apt ] && [ -n "$eng_rocm" ] && [ "${eng_rocm#"$(rocm_apt_root)"}" = "$eng_rocm" ]; then
  die "setup gebruikte niet de apt-ROCm $(rocm_apt_root) maar $eng_rocm (zie de waarschuwing van setup hierboven)"
fi

say "6/7 tuning-profiel $PROFILE"
apply_config

say "7/7 service"
unit=/etc/systemd/system/$SERVICE
sed -e "s#^User=.*#User=$SERVICE_USER#; s#^Group=.*#Group=$SERVICE_USER#; s#^WorkingDirectory=.*#WorkingDirectory=$STRATA_DIR#" \
    -e "s#/etc/strata-xtx/#/etc/$XTX_NAME/#; s#^Description=.*#Description=Strata op RX 7900 XTX ($XTX_NAME)#" \
    "$XTX_DIR/systemd/strata-xtx.service" > "$unit"
for c in $CONFLICTS; do sed -i "/^\[Unit\]/a Conflicts=$c.service" "$unit"; done
sed -e "s#/opt/ai/strata-xtx/bin/#$XTX_DIR/bin/#" "$XTX_DIR/systemd/strata-xtx-update.service" > "/etc/systemd/system/$XTX_NAME-update.service"
cp "$XTX_DIR/systemd/strata-xtx-update.timer" "/etc/systemd/system/$XTX_NAME-update.timer"
chmod 0644 "$unit" "/etc/systemd/system/$XTX_NAME-update."*
systemctl daemon-reload
for c in $CONFLICTS; do   # een andere variant op dezelfde GPU: niet meer automatisch starten (blijft geïnstalleerd)
  if systemctl is-enabled -q "$c.service" 2>/dev/null || systemctl is-active -q "$c.service" 2>/dev/null; then
    systemctl disable -q --now "$c.service"; warn "$c.service gestopt en uit autostart (terug: systemctl disable --now $SERVICE && systemctl enable --now $c.service)"
  fi
done
systemctl enable -q "$SERVICE"
git_s tag -f "xtx-good-$(date +%Y%m%d-%H%M)" xtx >/dev/null
echo "$(git_s rev-parse "origin/$UPSTREAM_BRANCH") $(cat "$XTX_DIR/patches/series" "$XTX_DIR"/patches/*.patch | sha256sum | cut -c1-16)" > "$STATE_DIR/good"
cmds=()
for f in "$XTX_DIR"/bin/xtx-*.sh; do
  n=$(basename "$f" .sh); [ "$n" = xtx-lib ] && continue
  ln -sf "$f" "/usr/local/bin/$CMD_PREFIX-${n#xtx-}"; cmds+=("$CMD_PREFIX-${n#xtx-}")
done
ok "commando's in /usr/local/bin: ${cmds[*]}"
if [ $NO_START -eq 1 ]; then ok "klaar (niet gestart): systemctl start $SERVICE"; exit 0; fi

systemctl restart "$SERVICE"
say "model laden (de eerste start duurt het langst; volg mee: journalctl -fu $SERVICE)"
wait_loaded "$UPDATE_SMOKE_TIMEOUT" || die "het model laadde niet binnen ${UPDATE_SMOKE_TIMEOUT}s: journalctl -u $SERVICE -n 200"
smoke_test && ok "rooktest: antwoord bevat 'Paris'" || die "rooktest mislukte"
STOPPED=()   # gelukt: de andere variant blijft uit
if [ "$AUTO_TUNE" = yes ] && need_tune; then
  say "8/8 eigen hipBLASLt-tabel (10-30 min; de service gaat even uit en daarna weer aan)"
  "$XTX_DIR/bin/xtx-tune-hipblaslt.sh" || warn "tunen mislukte - Strata draait wel, met de meegeleverde tabel (later: xtx-tune-hipblaslt)"
fi
if [ "$AUTO_CALIBRATE" = yes ] && need_calibrate; then
  say "decode-kalibratie voor deze PC (15-30 min; de service gaat even uit en daarna weer aan)"
  "$XTX_DIR/bin/xtx-calibrate.sh" || warn "kalibreren mislukte - Strata draait met de standaardinstellingen (later: xtx-calibrate)"
elif [ "$AUTO_CALIBRATE" = yes ]; then
  ok "decode-kalibratie voor dit model/deze context bestaat al (setup past ze toe; opnieuw: xtx-calibrate)"
fi
ip=$(hostname -I 2>/dev/null | awk '{print $1}')
echo
ok "Strata draait: http://${ip:-<lxc-ip>}:$PORT  (OpenAI: /v1, Anthropic: /v1/messages), profiel $PROFILE"
ok "meten kan altijd met: xtx-bench stock $PROFILE"
