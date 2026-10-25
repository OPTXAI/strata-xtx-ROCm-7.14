#!/usr/bin/env bash
# strata-xtx: upstream-updates binnenhalen en onze patches/optimalisaties er opnieuw overheen zetten.
#
#   1. toolchain bijwerken (xtx-tools)            6. setup.sh --update: engine opnieuw bouwen (alleen wat veranderde)
#   2. overlay bijwerken (als het een git-repo is)  7. tuning-profiel opnieuw toepassen (setup herschrijft args)
#   3. upstream fetch                              8. starten + rooktest
#   4. xtx-candidate = upstream + patch-queue      9. gelukt: tag xtx-good-*   mislukt: automatische rollback
#   5. backup van engine/ + config, service stop
#
# Opties: --auto (vanuit de timer), --force (ook zonder nieuwe commits), --ref <commit> (op een bepaalde upstream-
#         commit bouwen), --no-tools, --rollback (terug naar de vorige goede stand), --dry-run (alleen kijken)
# Exit: 0 ok/niets te doen, 3 patch past niet (niets veranderd), 4 build/test mislukt (teruggedraaid), 5 rollback mislukt
. "$(dirname "$(readlink -f "$0")")/xtx-lib.sh"
need_root

AUTO=0; FORCE=0; REF=""; TOOLS=1; ROLLBACK=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --auto) AUTO=1 ;; --force) FORCE=1 ;; --no-tools) TOOLS=0 ;; --rollback) ROLLBACK=1 ;; --dry-run) DRY=1 ;;
    --ref) REF="$2"; shift ;;
    *) die "onbekende optie $1 (zie de kop van dit script)" ;;
  esac; shift
done

install -d "$LOG_DIR" "$STATE_DIR"
exec 9>"/run/$XTX_NAME-update.lock"
flock -n 9 || die "er draait al een update"
LOG="$LOG_DIR/update-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG" 9>&-) 2>&1   # tee erft de lock-fd niet (anders blokkeert de herstart na een overlay-update zichzelf)
STATUS="$STATE_DIR/last-update.json"
status() { printf '{"time":"%s","result":"%s","detail":"%s","log":"%s"}\n' "$(date -Is)" "$1" "${2//\"/\'}" "$LOG" > "$STATUS"; }
[ -d "$STRATA_DIR/.git" ] || die "$STRATA_DIR is geen clone: eerst xtx-bootstrap.sh"

BACKUP="$STATE_DIR/prev"
was_active=0; systemctl is-active --quiet "$SERVICE" && was_active=1

start_and_test() {
  systemctl restart "$SERVICE" || return 1
  say "laden + rooktest (max ${UPDATE_SMOKE_TIMEOUT}s)"
  wait_loaded "$UPDATE_SMOKE_TIMEOUT" || { warn "model laadde niet"; journalctl -u "$SERVICE" -n 60 --no-pager; return 1; }
  smoke_test || return 1
  ok "rooktest geslaagd"
}

do_rollback() {   # terug naar $BACKUP (commit + engine + config)
  say "ROLLBACK naar $(cat "$BACKUP/commit" 2>/dev/null)"
  [ -f "$BACKUP/commit" ] || { warn "geen backup in $BACKUP"; return 1; }
  systemctl stop "$SERVICE" 2>/dev/null
  git_s checkout -q -f -B xtx "$(cat "$BACKUP/commit")" || return 1
  if [ -d "$BACKUP/engine" ]; then
    rsync -a --delete "$BACKUP/engine"/ "$STRATA_DIR/engine"/ || return 1
  fi
  for f in "$BACKUP"/strata-*.json; do [ -f "$f" ] && cp -p "$f" "$STRATA_DIR"/; done
  run_setup --update --no-start || warn "setup --update na rollback gaf een fout"
  apply_config
  [ $was_active -eq 1 ] || [ $ROLLBACK -eq 1 ] || return 0
  start_and_test
}

if [ $ROLLBACK -eq 1 ]; then
  was_active=1
  do_rollback && { status rolled-back "handmatig"; ok "teruggezet"; exit 0; } || { status rollback-failed "handmatig"; exit 5; }
fi

if [ $TOOLS -eq 1 ] && [ "$UPGRADE_OS_PACKAGES" = yes ] && [ $DRY -eq 0 ]; then
  say "toolchain"; "$XTX_DIR/bin/xtx-tools.sh" || warn "xtx-tools gaf een fout (update gaat door)"
fi

if [ -d "$XTX_DIR/.git" ] && [ $DRY -eq 0 ]; then
  say "overlay bijwerken"
  git -C "$XTX_DIR" config core.fileMode false   # chmod +x van de scripts telt niet als lokale wijziging
  before=$(git -C "$XTX_DIR" rev-parse HEAD)
  git -C "$XTX_DIR" pull -q --ff-only && ok "overlay: $(git -C "$XTX_DIR" log -1 --format='%h %s')" \
    || warn "overlay: git pull --ff-only lukte niet (lokale wijzigingen?) - ga verder met wat er staat"
  chmod +x "$XTX_DIR"/bin/* 2>/dev/null
  if [ "$before" != "$(git -C "$XTX_DIR" rev-parse HEAD)" ] && [ -z "${XTX_REEXEC:-}" ]; then
    say "overlay veranderd: verder met de nieuwe versie van dit script"
    args=(--no-tools); [ $AUTO -eq 1 ] && args+=(--auto); [ $FORCE -eq 1 ] && args+=(--force); [ -n "$REF" ] && args+=(--ref "$REF")
    XTX_REEXEC=1 exec "$XTX_DIR/bin/xtx-update.sh" "${args[@]}"
  fi
fi

say "upstream ophalen"
git_s fetch -q --tags origin || die "fetch mislukte"
target=$(git_s rev-parse "${REF:-origin/$UPSTREAM_BRANCH}") || die "onbekende ref ${REF}"
current_base=$(git_s merge-base xtx "$target" 2>/dev/null || true)
phash=$(cat "$XTX_DIR/patches/series" "$XTX_DIR"/patches/*.patch 2>/dev/null | sha256sum | cut -c1-16)
last=$(cat "$STATE_DIR/good" 2>/dev/null || true)
ok "upstream: $(git_s log -1 --format='%h %cs %s' "$target")"
if [ $FORCE -eq 0 ] && [ "$last" = "$target $phash" ]; then
  ok "niets nieuw (upstream en patches ongewijzigd)"; status up-to-date ""; exit 0
fi
[ -n "$current_base" ] && git_s --no-pager log --format='   %h %s' "$current_base..$target" | head -40

say "patch-queue op $(git_s log -1 --format=%h "$target")"
if [ $DRY -eq 1 ]; then "$XTX_DIR/bin/xtx-patches.sh" check; exit $?; fi
if ! "$XTX_DIR/bin/xtx-patches.sh" build "$target"; then
  git_s checkout -q -f xtx
  status patch-conflict "een patch past niet meer op $target"
  die "een patch past niet op de nieuwe upstream - er is NIETS veranderd, de service draait door. Oplossen: zie de kop van xtx-patches.sh."
fi

say "backup"
rm -rf "$BACKUP"; install -d "$BACKUP"
git_s rev-parse xtx > "$BACKUP/commit"
[ -d "$STRATA_DIR/engine" ] && rsync -a "$STRATA_DIR/engine"/ "$BACKUP/engine"/
cp -p "$STRATA_DIR"/strata-*.json "$BACKUP"/ 2>/dev/null || true
ok "vorige stand: $(cat "$BACKUP/commit" | cut -c1-9) (+ engine, config)"

say "bouwen (service gestopt: de engine-binary wordt vervangen)"
systemctl stop "$SERVICE" 2>/dev/null
git_s checkout -q -f -B xtx xtx-candidate && git_s branch -q -D xtx-candidate
if ! run_setup --update --no-start; then
  warn "setup --update mislukte"
  do_rollback && { status rolled-back "setup --update mislukte op $target"; exit 4; }
  status rollback-failed "setup --update mislukte op $target"; exit 5
fi
apply_config

if [ $was_active -eq 1 ] || [ $AUTO -eq 1 ]; then
  if ! start_and_test; then
    do_rollback && { status rolled-back "rooktest mislukte op $target"; exit 4; }
    status rollback-failed "rooktest mislukte op $target"; exit 5
  fi
fi

if [ "$AUTO_TUNE" = yes ] && need_tune && { [ $was_active -eq 1 ] || [ $AUTO -eq 1 ]; }; then
  say "nieuwe hipBLASLt-versie ($(hipblaslt_installed)): eigen tabel maken"
  "$XTX_DIR/bin/xtx-tune-hipblaslt.sh" || warn "tunen mislukte - de service draait met de meegeleverde tabel"
fi

tag="xtx-good-$(date +%Y%m%d-%H%M)"
git_s tag -f "$tag" xtx >/dev/null
git_s tag -l 'xtx-good-*' --sort=-creatordate | tail -n +$((KEEP_GOOD_TAGS + 1)) | while read -r t; do git_s tag -d "$t" >/dev/null; done
echo "$target $phash" > "$STATE_DIR/good"
status ok "$(git_s log -1 --format='%h' xtx) op upstream $(git_s log -1 --format='%h' "$target")"
ok "bijgewerkt: $tag  (engine $(jq -r .version "$STRATA_DIR/engine/BUILD.json" 2>/dev/null))"
