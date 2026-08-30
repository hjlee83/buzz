#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BRANCH="${BUZZ_RELEASE_BRANCH:-main}"
INSTALL_DIR="${BUZZ_PAIR_INSTALL_DIR:-$HOME/.local/bin}"
CADDY_CONFIG="${BUZZ_CADDY_CONFIG:-/etc/caddy/Caddyfile}"
CADDY_SITE="${BUZZ_CADDY_SITE:-/etc/caddy/sites-enabled/buzz.caddy}"
CADDY_TEMPLATE="$ROOT/ops/dev-control/buzz.caddy"

usage() {
  echo 'usage: ops/native-release.sh [--apply]' >&2
  exit 2
}

case "$#" in
  0) APPLY=0 ;;
  1) [[ "$1" == "--apply" ]] || usage; APPLY=1 ;;
  *) usage ;;
esac

cd "$ROOT"

git diff --quiet
git diff --cached --quiet
test -z "$(git status --porcelain --untracked-files=normal)"
branch="$(git branch --show-current)"
[[ "$branch" == "$DEFAULT_BRANCH" ]] || {
  printf 'refusing deploy: branch=%s expected=%s\n' "$branch" "$DEFAULT_BRANCH" >&2
  exit 2
}

git fetch --quiet origin "$DEFAULT_BRANCH"
revision="$(git rev-parse HEAD)"
remote_revision="$(git rev-parse "origin/$DEFAULT_BRANCH")"
[[ "$revision" == "$remote_revision" ]] || {
  printf 'refusing deploy: HEAD=%s origin/%s=%s\n' "$revision" "$DEFAULT_BRANCH" "$remote_revision" >&2
  exit 2
}

# Use the repository-pinned toolchain for every Rust operation.
# shellcheck disable=SC1091
. "$ROOT/bin/activate-hermit"

cargo test -p buzz-pairing-cli
cargo build --release -p buzz-pairing-cli

binary="$ROOT/target/release/buzz-pair"
[[ -x "$binary" ]] || {
  printf 'release binary missing: %s\n' "$binary" >&2
  exit 2
}

"$binary" source --help | grep -q -- '--approval-listen'
"$binary" source --help | grep -q -- '--approval-public-url'
grep -Fq 'handle /pair-approve* {' "$CADDY_TEMPLATE"
grep -Fq 'reverse_proxy 127.0.0.1:3097' "$CADDY_TEMPLATE"
grep -Fq 'handle /pair* {' "$CADDY_TEMPLATE"
grep -Fq 'reverse_proxy 127.0.0.1:3096' "$CADDY_TEMPLATE"

if (( ! APPLY )); then
  printf 'verified build revision=%s binary=%s; release state unchanged (use --apply to deploy)\n' "$revision" "$binary"
  exit 0
fi

command -v caddy >/dev/null
sudo -n true
[[ -f "$CADDY_CONFIG" ]] || {
  printf 'caddy config missing: %s\n' "$CADDY_CONFIG" >&2
  exit 2
}
caddy validate --config "$CADDY_TEMPLATE" --adapter caddyfile >/dev/null

install -d -m 0755 "$INSTALL_DIR"
backup_dir="$(mktemp -d)"
binary_backup="$backup_dir/buzz-pair"
site_backup="$backup_dir/buzz.caddy"
had_binary=0
had_site=0
rollback_needed=0
tmp_binary=""
next_site=""

if [[ -e "$INSTALL_DIR/buzz-pair" || -L "$INSTALL_DIR/buzz-pair" ]]; then
  cp -a "$INSTALL_DIR/buzz-pair" "$binary_backup"
  had_binary=1
fi
if sudo -n test -e "$CADDY_SITE"; then
  sudo -n cp -a "$CADDY_SITE" "$site_backup"
  had_site=1
fi

restore_previous() {
  if (( had_binary )); then
    rm -f "$INSTALL_DIR/buzz-pair"
    cp -a "$binary_backup" "$INSTALL_DIR/buzz-pair"
  else
    rm -f "$INSTALL_DIR/buzz-pair"
  fi

  if (( had_site )); then
    sudo -n rm -f "$CADDY_SITE"
    sudo -n cp -a "$site_backup" "$CADDY_SITE"
  else
    sudo -n rm -f "$CADDY_SITE"
  fi

  if sudo -n caddy validate --config "$CADDY_CONFIG" --adapter caddyfile >/dev/null 2>&1; then
    sudo -n systemctl reload caddy >/dev/null 2>&1 || true
  fi
}

cleanup() {
  status=$?
  trap - EXIT
  set +e
  if (( rollback_needed && status != 0 )); then
    restore_previous
  fi
  [[ -z "$tmp_binary" ]] || rm -f "$tmp_binary"
  [[ -z "$next_site" ]] || sudo -n rm -f "$next_site"
  rm -rf "$backup_dir"
  exit "$status"
}
trap cleanup EXIT

rollback_needed=1

tmp_binary="$(mktemp "$INSTALL_DIR/.buzz-pair.XXXXXX")"
install -m 0755 "$binary" "$tmp_binary"
mv -f "$tmp_binary" "$INSTALL_DIR/buzz-pair"

installed_sha="$(sha256sum "$INSTALL_DIR/buzz-pair" | awk '{print $1}')"
built_sha="$(sha256sum "$binary" | awk '{print $1}')"
[[ "$installed_sha" == "$built_sha" ]] || {
  printf 'installed binary checksum mismatch\n' >&2
  exit 2
}

"$INSTALL_DIR/buzz-pair" source --help | grep -q -- '--approval-listen'
"$INSTALL_DIR/buzz-pair" source --help | grep -q -- '--approval-public-url'

next_site="${CADDY_SITE}.next.$$"
sudo -n install -m 0644 "$CADDY_TEMPLATE" "$next_site"
sudo -n mv -f "$next_site" "$CADDY_SITE"

sudo -n caddy validate --config "$CADDY_CONFIG" --adapter caddyfile >/dev/null
# Adapt the top-level config, not just the template. Finding this host and both
# upstreams here proves the installed site is actually imported by Caddy.
adapted="$(sudo -n caddy adapt --config "$CADDY_CONFIG" --adapter caddyfile 2>/dev/null)"
grep -Fq '"buzz.hojinlab.com"' <<<"$adapted"
grep -Fq '127.0.0.1:3097' <<<"$adapted"
grep -Fq '127.0.0.1:3096' <<<"$adapted"

sudo -n systemctl reload caddy
sudo -n systemctl is-active --quiet caddy

grep -Fq 'handle /pair-approve* {' "$CADDY_SITE"
grep -Fq 'reverse_proxy 127.0.0.1:3097' "$CADDY_SITE"
grep -Fq 'handle /pair* {' "$CADDY_SITE"
grep -Fq 'reverse_proxy 127.0.0.1:3096' "$CADDY_SITE"

# The existing relay (3095) and pairing relay (3096) remain separately
# managed services; this adapter does not restart them. Port 3097 is
# intentionally ephemeral: a buzz-pair source session binds it only while
# waiting for explicit SAS approval. The one-shot approval semantics are owned
# by buzz-pairing-cli; this release only installs that CLI and exposes its
# loopback listener through HTTPS.
rollback_needed=0

printf 'verified revision=%s binary=%s caddy_site=%s approval_route=127.0.0.1:3097 pairing_route=127.0.0.1:3096\n' "$revision" "$INSTALL_DIR/buzz-pair" "$CADDY_SITE"
