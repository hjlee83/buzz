#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BRANCH="${BUZZ_RELEASE_BRANCH:-main}"
INSTALL_DIR="${BUZZ_INSTALL_DIR:-${BUZZ_PAIR_INSTALL_DIR:-$HOME/.local/bin}}"
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

cargo test -p buzz-pairing-cli -p buzz-acp
cargo build --release -p buzz-pairing-cli -p buzz-acp

pair_binary="$ROOT/target/release/buzz-pair"
acp_binary="$ROOT/target/release/buzz-acp"
for binary in "$pair_binary" "$acp_binary"; do
  [[ -x "$binary" ]] || {
    printf 'release binary missing: %s\n' "$binary" >&2
    exit 2
  }
done

"$pair_binary" source --help | grep -q -- '--approval-listen'
"$pair_binary" source --help | grep -q -- '--approval-public-url'
"$acp_binary" --help | grep -q -- '--respond-to-allowlist-exact'
grep -Fq 'handle /pair-approve* {' "$CADDY_TEMPLATE"
grep -Fq 'reverse_proxy 127.0.0.1:3097' "$CADDY_TEMPLATE"
grep -Fq 'handle /pair* {' "$CADDY_TEMPLATE"
grep -Fq 'reverse_proxy 127.0.0.1:3096' "$CADDY_TEMPLATE"

if (( ! APPLY )); then
  printf 'verified build revision=%s pair_binary=%s acp_binary=%s; release state unchanged (use --apply to deploy)\n' "$revision" "$pair_binary" "$acp_binary"
  exit 0
fi

command -v caddy >/dev/null
sudo -n true
[[ -f "$CADDY_CONFIG" ]] || {
  printf 'caddy config missing: %s\n' "$CADDY_CONFIG" >&2
  exit 2
}
caddy validate --config "$CADDY_TEMPLATE" --adapter caddyfile >/dev/null

# Capture the service set before mutating release state. Process substitution
# would hide `systemctl list-units` failures behind mapfile's exit status.
active_hermes_units_raw=""
if ! active_hermes_units_raw="$(systemctl list-units --type=service --state=active --no-legend 'buzz-hermes@*.service')"; then
  printf 'failed to enumerate active Buzz Hermes services\n' >&2
  exit 2
fi
active_hermes_units=()
while read -r unit _; do
  [[ -n "$unit" ]] || continue
  active_hermes_units+=("$unit")
done <<<"$active_hermes_units_raw"

install -d -m 0755 "$INSTALL_DIR"
backup_dir="$(mktemp -d)"
pair_backup="$backup_dir/buzz-pair"
acp_backup="$backup_dir/buzz-acp"
site_backup="$backup_dir/buzz.caddy"
had_pair=0
had_acp=0
had_site=0
rollback_needed=0
tmp_pair=""
tmp_acp=""
next_site=""

if [[ -e "$INSTALL_DIR/buzz-pair" || -L "$INSTALL_DIR/buzz-pair" ]]; then
  cp -a "$INSTALL_DIR/buzz-pair" "$pair_backup"
  had_pair=1
fi
if [[ -e "$INSTALL_DIR/buzz-acp" || -L "$INSTALL_DIR/buzz-acp" ]]; then
  cp -a "$INSTALL_DIR/buzz-acp" "$acp_backup"
  had_acp=1
fi
if sudo -n test -e "$CADDY_SITE"; then
  sudo -n cp -a "$CADDY_SITE" "$site_backup"
  had_site=1
fi

restart_and_verify_hermes() {
  local unit pid live_exe expected_exe
  expected_exe="$(readlink -f "$INSTALL_DIR/buzz-acp")"
  for unit in "${active_hermes_units[@]}"; do
    sudo -n systemctl restart "$unit"
  done
  for unit in "${active_hermes_units[@]}"; do
    sudo -n systemctl is-active --quiet "$unit"
    pid="$(systemctl show -p MainPID --value "$unit")"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || {
      printf 'invalid MainPID after restart: unit=%s pid=%s\n' "$unit" "$pid" >&2
      return 1
    }
    live_exe="$(readlink -f "/proc/$pid/exe")"
    [[ "$live_exe" == "$expected_exe" ]] || {
      printf 'service executable mismatch: unit=%s live=%s expected=%s\n' "$unit" "$live_exe" "$expected_exe" >&2
      return 1
    }
  done
}

restore_previous() {
  if (( had_pair )); then
    rm -f "$INSTALL_DIR/buzz-pair"
    cp -a "$pair_backup" "$INSTALL_DIR/buzz-pair"
  else
    rm -f "$INSTALL_DIR/buzz-pair"
  fi
  if (( had_acp )); then
    rm -f "$INSTALL_DIR/buzz-acp"
    cp -a "$acp_backup" "$INSTALL_DIR/buzz-acp"
  else
    rm -f "$INSTALL_DIR/buzz-acp"
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
  if (( had_acp )) && ((${#active_hermes_units[@]} > 0)); then
    restart_and_verify_hermes >/dev/null 2>&1 || true
  fi
}

cleanup() {
  status=$?
  trap - EXIT
  set +e
  if (( rollback_needed && status != 0 )); then
    restore_previous
  fi
  [[ -z "$tmp_pair" ]] || rm -f "$tmp_pair"
  [[ -z "$tmp_acp" ]] || rm -f "$tmp_acp"
  [[ -z "$next_site" ]] || sudo -n rm -f "$next_site"
  rm -rf "$backup_dir"
  exit "$status"
}
trap cleanup EXIT

rollback_needed=1

tmp_pair="$(mktemp "$INSTALL_DIR/.buzz-pair.XXXXXX")"
tmp_acp="$(mktemp "$INSTALL_DIR/.buzz-acp.XXXXXX")"
install -m 0755 "$pair_binary" "$tmp_pair"
install -m 0755 "$acp_binary" "$tmp_acp"
mv -f "$tmp_pair" "$INSTALL_DIR/buzz-pair"
mv -f "$tmp_acp" "$INSTALL_DIR/buzz-acp"

for name in buzz-pair buzz-acp; do
  case "$name" in
    buzz-pair) built="$pair_binary" ;;
    buzz-acp) built="$acp_binary" ;;
  esac
  installed_sha="$(sha256sum "$INSTALL_DIR/$name" | awk '{print $1}')"
  built_sha="$(sha256sum "$built" | awk '{print $1}')"
  [[ "$installed_sha" == "$built_sha" ]] || {
    printf 'installed binary checksum mismatch: %s\n' "$name" >&2
    exit 2
  }
done

"$INSTALL_DIR/buzz-pair" source --help | grep -q -- '--approval-listen'
"$INSTALL_DIR/buzz-pair" source --help | grep -q -- '--approval-public-url'
"$INSTALL_DIR/buzz-acp" --help | grep -q -- '--respond-to-allowlist-exact'

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

if ((${#active_hermes_units[@]} > 0)); then
  restart_and_verify_hermes
fi

# The existing relay (3095) and pairing relay (3096) remain separately
# managed services; this adapter does not restart them. Port 3097 is
# intentionally ephemeral: a buzz-pair source session binds it only while
# waiting for explicit SAS approval. The one-shot approval semantics are owned
# by buzz-pairing-cli; this release only installs that CLI and exposes its
# loopback listener through HTTPS.
rollback_needed=0

printf 'verified revision=%s pair_binary=%s acp_binary=%s hermes_units=%s caddy_site=%s approval_route=127.0.0.1:3097 pairing_route=127.0.0.1:3096\n' "$revision" "$INSTALL_DIR/buzz-pair" "$INSTALL_DIR/buzz-acp" "${#active_hermes_units[@]}" "$CADDY_SITE"
