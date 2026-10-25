#!/usr/bin/env bash
# strata-xtx: de patch-queue beheren.
#
#   xtx-patches.sh build [REF]   branch "xtx-candidate" = REF (standaard origin/$UPSTREAM_BRANCH) + alle patches
#   xtx-patches.sh status        welke patches toegepast zijn, hoe ver upstream voor ligt
#   xtx-patches.sh export        commits op "xtx" boven upstream -> patches/ (na een handmatige fix of nieuwe patch)
#   xtx-patches.sh check         droog: past de queue nog op de nieuwste upstream? (verandert niets)
#
# Werkwijze voor een nieuwe patch: git -C $STRATA_DIR checkout xtx; wijzig; git commit; xtx-patches.sh export.
# Werkwijze bij een conflict na een upstream-update:
#   sudo -u strata git -C $STRATA_DIR checkout -B xtx origin/main
#   sudo -u strata git -C $STRATA_DIR am --3way $XTX_DIR/patches/<patch>   -> conflict oplossen, git add -A,
#   sudo -u strata git -C $STRATA_DIR am --continue   (of --skip als upstream het al doet)
#   xtx-patches export; daarna de overlay committen en xtx-update --force
. "$(dirname "$(readlink -f "$0")")/xtx-lib.sh"

PATCH_DIR="$XTX_DIR/patches"
series() { grep -v -e '^\s*#' -e '^\s*$' "$PATCH_DIR/series"; }

ensure_identity() {
  git_s config user.email >/dev/null || git_s config user.email "strata-xtx@localhost"
  git_s config user.name  >/dev/null || git_s config user.name  "strata-xtx"
}

apply_queue() {   # op de huidige HEAD; 0 = alles toegepast
  local p n=0
  while read -r p; do
    [ -f "$PATCH_DIR/$p" ] || die "patch ontbreekt: $PATCH_DIR/$p"
    if ! git_s am --3way --keep-cr -q "$PATCH_DIR/$p"; then
      warn "patch past niet meer: $p"
      git_s am --show-current-patch=diff 2>/dev/null | head -40 >&2
      git_s am --abort 2>/dev/null
      return 1
    fi
    n=$((n + 1)); ok "toegepast: $p"
  done < <(series)
  ok "$n patch(es) toegepast"
}

cmd=${1:-status}; shift || true
case "$cmd" in
  build)
    ensure_identity
    ref=${1:-origin/$UPSTREAM_BRANCH}
    [ -z "$(git_s status --porcelain --untracked-files=no)" ] || die "er zijn lokale wijzigingen in $STRATA_DIR (git status)"
    git_s checkout -q -B xtx-candidate "$ref" || die "checkout $ref mislukte"
    apply_queue || exit 3
    ;;
  check)
    ensure_identity
    git_s fetch -q origin "$UPSTREAM_BRANCH" || die "fetch mislukte"
    tmp=$(as_user mktemp -d)
    git_s worktree add -q --detach "$tmp" "origin/$UPSTREAM_BRANCH" || die "worktree mislukte"
    rc=0
    while read -r p; do
      if as_user git -C "$tmp" am --3way -q "$PATCH_DIR/$p" >/dev/null 2>&1; then ok "past: $p"
      else warn "past NIET: $p"; as_user git -C "$tmp" am --abort >/dev/null 2>&1; rc=3; break; fi
    done < <(series)
    git_s worktree remove --force "$tmp"
    exit $rc
    ;;
  status)
    base=$(git_s merge-base xtx "origin/$UPSTREAM_BRANCH" 2>/dev/null) || die "geen branch xtx (eerst xtx-bootstrap)"
    echo "huidige branch : $(git_s rev-parse --abbrev-ref HEAD)"
    echo "xtx gebouwd op : $(git_s log -1 --format='%h %cs %s' "$base")"
    echo "upstream nu    : $(git_s log -1 --format='%h %cs %s' "origin/$UPSTREAM_BRANCH")"
    echo "upstream voor  : $(git_s rev-list --count "$base..origin/$UPSTREAM_BRANCH") commit(s) (na de laatste fetch)"
    echo "onze commits   :"; git_s log --format='   %h %s' "$base..xtx"
    echo "laatste goede  : $(git_s tag -l 'xtx-good-*' --sort=-creatordate | head -1)"
    ;;
  export)
    base=$(git_s merge-base xtx "origin/$UPSTREAM_BRANCH") || die "geen branch xtx"
    out=$(as_user mktemp -d)
    git_s format-patch -q --zero-commit -N -o "$out" "$base..xtx" || die "format-patch mislukte"
    mkdir -p "$PATCH_DIR/.previous" && mv -f "$PATCH_DIR"/*.patch "$PATCH_DIR/.previous/" 2>/dev/null
    cp "$out"/*.patch "$PATCH_DIR"/ && rm -rf "$out"
    ( cd "$PATCH_DIR" && { echo '# Patch queue, applied in this order with "git am --3way" on top of upstream/main.'
                           echo '# One patch per line; lines starting with # are skipped.'
                           ls -1 [0-9]*.patch; } > series )
    ok "$(ls "$PATCH_DIR"/*.patch | wc -l) patch(es) in $PATCH_DIR (vergeet niet: git commit in $XTX_DIR)"
    ;;
  *) sed -n '2,14p' "$0"; exit 2 ;;
esac
