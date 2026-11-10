#!/usr/bin/env bash
# Debian/Ubuntu + systemd. No Telegram credentials or production alerts required.
# Usage: sudo bash install-victorialogs-alerting.sh [--victorialogs-url URL]
# Author: Yevgeniy G., https://lab.sys-adm.in/

set -Eeuo pipefail
umask 027
export LC_ALL=C
SCRIPT_VERSION=1.0.1
VL_URL=http://127.0.0.1:9428
VL_EXPLICIT=0
WORK_DIR=
BACKUP_DIR=
log() { printf '[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT
trap 'printf "[ERROR] Installation stopped at line %s. Check journalctl -u vmalert -u alertmanager. Backup: %s\n" "$LINENO" "${BACKUP_DIR:-not created}" >&2' ERR

while (($#)); do
  case "$1" in
    --victorialogs-url)
      (($# >= 2)) || die 'Missing URL'
      VL_URL=${2%/}; VL_EXPLICIT=1; shift 2 ;;
    -h|--help)
      printf '%s\n' "Installer $SCRIPT_VERSION: vmalert + Alertmanager" \
        'Usage: sudo bash install-victorialogs-alerting.sh [--victorialogs-url http://127.0.0.1:9428]' \
        'Fetches latest stable releases. Preserves existing configs and units.' \
        'Custom URL is used for a NEW environment file only; existing settings are preserved.'
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ $EUID -eq 0 ]] || die 'Run as root (sudo bash install-victorialogs-alerting.sh)'
[[ -r /etc/os-release ]] || die 'Missing /etc/os-release'
. /etc/os-release
case "${ID:-} ${ID_LIKE:-}" in
  *debian*|*ubuntu*) ;;
  *) die 'Supported systems: Debian/Ubuntu' ;;
esac
[[ -d /run/systemd/system ]] || die 'A running systemd is required'
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die 'Supported architectures: amd64 and arm64' ;;
esac
# Check dependencies without changing system packages or package indexes.
missing=()
for tool in curl jq tar sha256sum install mktemp flock runuser getent useradd groupadd; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
[[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
if ((${#missing[@]})); then
  die "Missing dependencies: ${missing[*]}. Install only the required packages manually and rerun. This installer never invokes apt."
fi
# Avoid concurrent upgrades.
exec 9>/run/lock/victorialogs-alerting-installer.lock
flock -n 9 || die 'Another installer is running'
[[ "$VL_URL" =~ ^https?://[^[:space:]\"\'\\]+$ ]] || die 'Invalid VictoriaLogs URL'

log 'Dependencies available; system packages and apt indexes will not be changed'
# Stage executables on /usr/local, not /tmp (which may also be mounted noexec).
# 0711 permits service users to traverse known paths without listing the stage.
install -d -m 0755 /usr/local/lib
WORK_DIR=$(mktemp -d /usr/local/lib/victorialogs-alerting-stage.XXXXXXXX)
chmod 0711 "$WORK_DIR"
curl_get() {
  curl --fail --silent --show-error --location --retry 3 \
    --connect-timeout 15 --max-time 600 --proto '=https' --proto-redir '=https' "$@"
}
release() {
  local repo=$1 prefix=$2 pattern=$3
  log "Resolving latest stable release: $repo"
  curl_get "https://api.github.com/repos/$repo/releases/latest" -o "$WORK_DIR/$prefix.json"
  jq -e '.draft == false and .prerelease == false' "$WORK_DIR/$prefix.json" >/dev/null
  jq -er --arg re "$pattern" '
    [.assets[] | select(.name | test($re))] |
    if length == 1 then .[0] else error("Expected one matching release asset") end
  ' "$WORK_DIR/$prefix.json" > "$WORK_DIR/$prefix.asset.json"
  local url digest name
  url=$(jq -er '.browser_download_url' "$WORK_DIR/$prefix.asset.json")
  name=$(jq -er '.name' "$WORK_DIR/$prefix.asset.json")
  digest=$(jq -er '.digest | select(type == "string") | select(test("^sha256:[a-fA-F0-9]{64}$"))' \
    "$WORK_DIR/$prefix.asset.json") || die "No SHA256 digest published for $name; refusing unverified install"
  log "Downloading $name"
  curl_get "$url" -o "$WORK_DIR/$prefix.tar.gz"
  printf '%s  %s\n' "${digest#sha256:}" "$WORK_DIR/$prefix.tar.gz" | sha256sum --check --status
  log "SHA256 verified: $name"
  mkdir "$WORK_DIR/$prefix"
  tar --extract --gzip --file "$WORK_DIR/$prefix.tar.gz" \
    --directory "$WORK_DIR/$prefix" --no-same-owner
}
release VictoriaMetrics/VictoriaMetrics vm "^vmutils-linux-${ARCH}-v[0-9.]+\\.tar\\.gz$"
release prometheus/alertmanager am "^alertmanager-[0-9.]+\\.linux-${ARCH}\\.tar\\.gz$"
VM_TAG=$(jq -er '.tag_name' "$WORK_DIR/vm.json")
AM_TAG=$(jq -er '.tag_name' "$WORK_DIR/am.json")
VM_BIN="$WORK_DIR/vm/vmalert-prod"
AM_ROOTS=("$WORK_DIR"/am/alertmanager-*)
((${#AM_ROOTS[@]} == 1)) || die 'Unexpected Alertmanager archive structure'
AM_ROOT=${AM_ROOTS[0]}
[[ -f "$VM_BIN" && -f "$AM_ROOT/alertmanager" && -f "$AM_ROOT/amtool" ]] || die 'Binaries missing'
chmod 0755 "$VM_BIN" "$AM_ROOT/alertmanager" "$AM_ROOT/amtool"
chmod 0711 "$WORK_DIR/vm" "$WORK_DIR/am" "$AM_ROOT"
"$VM_BIN" -version
"$AM_ROOT/alertmanager" --version

BACKUP_DIR=$(mktemp -d /var/backups/victorialogs-alerting-XXXXXXXX)
chmod 0700 "$BACKUP_DIR"
for path in /etc/vmalert /etc/alertmanager \
  /etc/systemd/system/vmalert.service /etc/systemd/system/alertmanager.service \
  /usr/local/bin/vmalert /usr/local/bin/alertmanager /usr/local/bin/amtool; do
  if [[ -e "$path" || -L "$path" ]]; then
    cp -a --parents "$path" "$BACKUP_DIR/"
  fi
done
log "Existing files backed up: $BACKUP_DIR"

for account in vmalert alertmanager; do
  getent group "$account" >/dev/null || groupadd --system "$account"
  id "$account" >/dev/null 2>&1 || \
    useradd --system --gid "$account" --no-create-home --shell /usr/sbin/nologin "$account"
done
install -d -m 0755 /etc/vmalert /etc/vmalert/rules
install -d -m 0750 -o root -g alertmanager /etc/alertmanager
install -d -m 0750 -o alertmanager -g alertmanager /var/lib/alertmanager

if [[ ! -e /etc/alertmanager/alertmanager.yml ]]; then
  cat > /etc/alertmanager/alertmanager.yml <<'EOF'
# Telegram will be configured in the next step.
global:
  resolve_timeout: 5m
route:
  receiver: local-only
  group_by: [alertname, instance]
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 4h
receivers:
  - name: local-only
EOF
  chown root:alertmanager /etc/alertmanager/alertmanager.yml
  chmod 0640 /etc/alertmanager/alertmanager.yml
else
  log 'Preserved existing Alertmanager configuration'
fi

if [[ ! -e /etc/vmalert/vmalert.env ]]; then
  printf 'VMALERT_LISTEN_ADDR=0.0.0.0:8880\nVICTORIALOGS_URL="%s"\nALERTMANAGER_URL="http://127.0.0.1:9093"\n' \
    "$VL_URL" > /etc/vmalert/vmalert.env
  chmod 0600 /etc/vmalert/vmalert.env
else
  log 'Preserved /etc/vmalert/vmalert.env'
  if ((VL_EXPLICIT)); then
    log '--victorialogs-url did not override existing settings; edit vmalert.env if needed'
  fi
fi
# A valid, permanently inactive bootstrap rule keeps vmalert running before
# real rules are added. The post-stats negative-count condition can never match.
if [[ ! -e /etc/vmalert/rules/00-bootstrap.yml ]]; then
  cat > /etc/vmalert/rules/00-bootstrap.yml <<'EOF'
groups:
  - name: bootstrap
    type: vlogs
    interval: 1m
    rules:
      - alert: BootstrapNeverFires
        expr: |
          {event="__alerting_installer_bootstrap__"}
          | stats count() as events
          | filter events:<0
        labels:
          severity: info
        annotations:
          summary: "Inactive bootstrap rule; remove after adding real rules"
EOF
  chmod 0644 /etc/vmalert/rules/00-bootstrap.yml
fi

# Validate before replacing binaries or restarting existing services.
runuser -u alertmanager -- "$AM_ROOT/amtool" check-config /etc/alertmanager/alertmanager.yml
runuser -u vmalert -- "$VM_BIN" -rule='/etc/vmalert/rules/*.yml' -dryRun

unit_exists() {
  local state
  state=$(systemctl show "$1" --property=LoadState --value)
  [[ "$state" != not-found && -n "$state" ]]
}
if ! unit_exists alertmanager.service; then
  cat > /etc/systemd/system/alertmanager.service <<'EOF'
[Unit]
Description=Prometheus Alertmanager
Wants=network-online.target
After=network-online.target
[Service]
User=alertmanager
Group=alertmanager
ExecStart=/usr/local/bin/alertmanager --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/var/lib/alertmanager --web.listen-address=127.0.0.1:9093 --cluster.listen-address=
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/alertmanager
[Install]
WantedBy=multi-user.target
EOF
else
  log 'Preserved existing alertmanager.service; its ExecStart/settings remain authoritative'
fi
if ! unit_exists vmalert.service; then
  cat > /etc/systemd/system/vmalert.service <<'EOF'
[Unit]
Description=VictoriaLogs alert evaluation
Wants=network-online.target
After=network-online.target alertmanager.service
[Service]
User=vmalert
Group=vmalert
EnvironmentFile=/etc/vmalert/vmalert.env
ExecStart=/usr/local/bin/vmalert -rule=/etc/vmalert/rules/*.yml -datasource.url=${VICTORIALOGS_URL} -notifier.url=${ALERTMANAGER_URL} -httpListenAddr=${VMALERT_LISTEN_ADDR} -rule.evalDelay=5s
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
[Install]
WantedBy=multi-user.target
EOF
else
  log 'Preserved existing vmalert.service; its ExecStart/settings remain authoritative'
fi
# Atomic binary replacement avoids truncating a running executable.
for component in vmalert alertmanager amtool; do
  case "$component" in
    vmalert) source_bin=$VM_BIN ;;
    *) source_bin="$AM_ROOT/$component" ;;
  esac
  install -m 0755 "$source_bin" "/usr/local/bin/.$component.new"
  mv -f "/usr/local/bin/.$component.new" "/usr/local/bin/$component"
done
systemctl daemon-reload
systemctl enable alertmanager.service vmalert.service
systemctl restart alertmanager.service
systemctl restart vmalert.service

for service in alertmanager vmalert; do
  ready=0
  for ((attempt=0; attempt<20; attempt++)); do
    case "$service" in
      alertmanager) endpoint=http://127.0.0.1:9093/-/ready ;;
      vmalert) endpoint=http://127.0.0.1:8880/health ;;
    esac
    if systemctl is-active --quiet "$service" && \
      curl -fsS --max-time 2 "$endpoint" >/dev/null 2>&1; then
      ready=1; break
    fi
    sleep 1
  done
  if ((ready == 0)); then
    journalctl -u "$service" -n 40 --no-pager >&2
    die "$service failed readiness check at $endpoint (check preserved units for custom ports)"
  fi
done

printf '\nInstallation completed (installer %s)\n' "$SCRIPT_VERSION"
printf 'Architecture: %s\nvmalert release: %s\nAlertmanager release: %s\n' "$ARCH" "$VM_TAG" "$AM_TAG"
/usr/local/bin/vmalert -version
/usr/local/bin/alertmanager --version
/usr/local/bin/amtool --version
printf '\nServices:\n'
systemctl --no-pager --full status vmalert alertmanager
printf '\nBackup: %s\n' "$BACKUP_DIR"
printf '%s\n' \
  'Config: /etc/alertmanager/alertmanager.yml' \
  'Environment: /etc/vmalert/vmalert.env' \
  'Rules: /etc/vmalert/rules/*.yml' \
  'UI: http://127.0.0.1:8880/vmalert/ and http://127.0.0.1:9093/' \
  'Fresh install: Telegram is not configured; bootstrap rule never fires.' \
  'Existing notification settings and real rules, if present, remain enabled.' \
  'Next: configure Telegram, test delivery, then add real alert rules.' \
  'Logs: journalctl -u vmalert -u alertmanager -n 100 --no-pager'
