#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BRANCH="${BUZZ_RELEASE_BRANCH:-main}"
INSTALL_DIR="${BUZZ_PAIR_INSTALL_DIR:-$HOME/.local/bin}"
CADDY_CONFIG="${BUZZ_CADDY_CONFIG:-/etc/caddy/Caddyfile}"
CADDY_SITE="${BUZZ_CADDY_SITE:-/etc/caddy/sites-enabled/buzz.caddy}"
CADDY_TEMPLATE="$ROOT/ops/dev-control/buzz.caddy"

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

if [[ "${1:-}" != "--apply" ]]; then
  printf 'verified build revision=%s binary=%s; release state unchanged (use --apply to deploy)\n' "$revision" "$binary"
  exit 0
fi

install -d -m 0755 "$INSTALL_DIR"
tmp_binary="$(mktemp "$INSTALL_DIR/.buzz-pair.XXXXXX")"
cleanup_binary() { rm -f "$tmp_binary"; }
trap cleanup_binary EXIT
install -m 0755 "$binary" "$tmp_binary"
mv -f "$tmp_binary" "$INSTALL_DIR/buzz-pair"
trap - EXIT

installed_sha="$(sha256sum "$INSTALL_DIR/buzz-pair" | awk '{print $1}')"
built_sha="$(sha256sum "$binary" | awk '{print $1}')"
[[ "$installed_sha" == "$built_sha" ]] || {
  printf 'installed binary checksum mismatch\n' >&2
  exit 2
}

"$INSTALL_DIR/buzz-pair" source --help | grep -q -- '--approval-listen'
"$INSTALL_DIR/buzz-pair" source --help | grep -q -- '--approval-public-url'

command -v caddy >/dev/null
sudo -n true
caddy validate --config "$CADDY_TEMPLATE" --adapter caddyfile >/dev/null

old_site="$(mktemp)"
cleanup_caddy() { rm -f "$old_site"; }
trap cleanup_caddy EXIT
if [[ -f "$CADDY_SITE" ]]; then
  cp "$CADDY_SITE" "$old_site"
else
  : > "$old_site"
fi

next_site="${CADDY_SITE}.next.$$"
sudo -n install -m 0644 "$CADDY_TEMPLATE" "$next_site"
sudo -n mv -f "$next_site" "$CADDY_SITE"

if ! sudo -n caddy validate --config "$CADDY_CONFIG" --adapter caddyfile >/dev/null; then
  if [[ -s "$old_site" ]]; then
    sudo -n install -m 0644 "$old_site" "$CADDY_SITE"
  else
    sudo -n rm -f "$CADDY_SITE"
  fi
  sudo -n caddy validate --config "$CADDY_CONFIG" --adapter caddyfile >/dev/null || true
  printf 'caddy validation failed; previous site configuration restored\n' >&2
  exit 2
fi

sudo -n systemctl reload caddy
sudo -n systemctl is-active --quiet caddy

grep -Fq 'handle /pair-approve* {' "$CADDY_SITE"
grep -Fq 'reverse_proxy 127.0.0.1:3097' "$CADDY_SITE"
grep -Fq 'handle /pair* {' "$CADDY_SITE"
grep -Fq 'reverse_proxy 127.0.0.1:3096' "$CADDY_SITE"
cleanup_caddy
trap - EXIT

printf 'verified revision=%s binary=%s caddy_site=%s approval_route=127.0.0.1:3097 pairing_route=127.0.0.1:3096\n' "$revision" "$INSTALL_DIR/buzz-pair" "$CADDY_SITE"
