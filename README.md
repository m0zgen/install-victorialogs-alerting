# VictoriaLogs Alerting Installer

A Bash installer for **vmalert and Alertmanager** on Debian/Ubuntu with systemd.

Downloads the latest stable releases from the official GitHub repositories, verifies SHA256 checksums, installs binaries, and starts the services. VictoriaLogs must be installed separately.

Once rules and notification receivers are configured, the intended flow is:

**VictoriaLogs → vmalert → Alertmanager → Telegram / other receivers**

## Features

- Linux `amd64` and `arm64` support.
- Latest stable releases resolved through the GitHub Releases API.
- Archive verification using the SHA256 `digest` published by the GitHub API. Installation stops if no digest is available.
- Installs `vmalert`, `alertmanager`, and `amtool` into `/usr/local/bin`.
- Backs up existing configurations, local unit files, and binaries.
- Preserves existing configuration files and systemd units.
- Validates configurations before replacing binaries and restarting services.
- Checks HTTP endpoints after startup.
- Prints installed versions, service status, and configuration paths.

The script does not invoke `apt`, upgrade system packages, or refresh package indexes. If a required utility is missing, it exits with a list of missing dependencies.

## Requirements

- Debian/Ubuntu running systemd.
- Root privileges.
- HTTPS access to the GitHub API and GitHub Releases download servers.
- HTTP/HTTPS access to VictoriaLogs.
- Utilities: `curl`, `jq`, `tar`, `sha256sum`, `install`, `mktemp`, `flock`, `runuser`, `getent`, `useradd`, and `groupadd`.
- System CA bundle at `/etc/ssl/certs/ca-certificates.crt`.

Most utilities are included in a standard system installation. Install any missing packages manually, for example:

```bash
sudo apt-get install --no-install-recommends curl jq ca-certificates
```

The GitHub API limits unauthenticated requests. If the limit is exceeded, wait for it to reset before retrying.

## Installation

Save `install-victorialogs-alerting.sh` from this repository to your server, then run:

```bash
sudo bash install-victorialogs-alerting.sh
```

The default VictoriaLogs address is:

```text
http://127.0.0.1:9428
```

To use a different address:

```bash
sudo bash install-victorialogs-alerting.sh \
  --victorialogs-url http://192.168.10.160:9428
```

Show help:

```bash
bash install-victorialogs-alerting.sh --help
```

`--victorialogs-url` sets the address only when creating a new `/etc/vmalert/vmalert.env`. If the file already exists, its contents are preserved. To change the address, edit the environment file and restart vmalert.

## Installation Process

1. Checks the OS, architecture, dependencies, and whether another installer instance is running.
2. Downloads the latest stable `vmutils` and Alertmanager archives and verifies SHA256 checksums.
3. Backs up existing files.
4. Creates the required users, directories, and missing configuration files.
5. Validates configurations using `amtool check-config` and `vmalert -dryRun` as the service users.
6. Creates systemd units for services that do not already exist.
7. Replaces binaries, enables both services at boot, and restarts them.
8. Checks HTTP endpoints and prints an installation summary.

Temporary executables are staged under `/usr/local/lib/victorialogs-alerting-stage.*`. The staging directory is removed when the script exits.

## Existing Alertmanager Installations

The script can update an Alertmanager installation using `alertmanager.service` and the binary at `/usr/local/bin/alertmanager`.

| Item | Behavior |
| --- | --- |
| `/usr/local/bin/alertmanager`, `/usr/local/bin/amtool` | Replaced with the downloaded versions |
| `/etc/alertmanager/alertmanager.yml` | Preserved if present; created otherwise |
| `alertmanager.service` | Existing unit is preserved |
| Existing unit's `ExecStart` arguments | Preserved, including storage and network settings |
| Alertmanager service | Enabled at boot and restarted |
| `/etc/alertmanager` | Set to mode `0750` and ownership `root:alertmanager` |
| `/var/lib/alertmanager` | Created or set to mode `0750` and ownership `alertmanager:alertmanager` |

For example, if the existing unit uses `--storage.path=/data/alertmanager`, this setting remains unchanged. The script still creates `/var/lib/alertmanager`, but the existing service does not automatically start using it.

**Updating restarts Alertmanager and briefly interrupts its operation.** Existing vmalert rules and Alertmanager receivers remain enabled.

Docker installations and services with different names are not automatically detected. If an existing unit uses a different binary path, it continues to use that path; the updated `/usr/local/bin/alertmanager` may not be used.

## Files and Directories

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/vmalert` | vmalert binary |
| `/usr/local/bin/alertmanager` | Alertmanager binary |
| `/usr/local/bin/amtool` | Alertmanager validation and management utility |
| `/etc/vmalert/vmalert.env` | Addresses used by the newly created vmalert unit |
| `/etc/vmalert/rules/*.yml` | vmalert rules |
| `/etc/alertmanager/alertmanager.yml` | Notification routing and receivers |
| `/etc/systemd/system/vmalert.service` | Unit created if the service does not exist |
| `/etc/systemd/system/alertmanager.service` | Unit created if the service does not exist |
| `/var/lib/alertmanager` | State directory used by the newly created Alertmanager unit |
| `/var/backups/victorialogs-alerting-*` | Backups |

## vmalert Configuration

A new `/etc/vmalert/vmalert.env` contains:

```ini
VMALERT_LISTEN_ADDR=0.0.0.0:8880
VICTORIALOGS_URL="http://127.0.0.1:9428"
ALERTMANAGER_URL="http://127.0.0.1:9093"
```

The newly created vmalert unit loads this file through `EnvironmentFile` and passes its values to `-httpListenAddr`, `-datasource.url`, and `-notifier.url`.

After editing the environment file:

```bash
sudo systemctl restart vmalert
```

After editing the systemd unit itself:

```bash
sudo systemctl daemon-reload
sudo systemctl restart vmalert
```

If your unit was created by an earlier installer version, make sure its `ExecStart` contains:

```ini
-httpListenAddr=${VMALERT_LISTEN_ADDR}
```

Rerunning the installer does not add variables to an existing environment file or modify an existing unit. Apply these changes manually when needed.

## Web Interfaces

For a new installation:

| Component | Address |
| --- | --- |
| vmalert | `http://SERVER_IP:8880/vmalert/` |
| Alertmanager | `http://127.0.0.1:9093/` on the server |

By default, a new vmalert installation listens on all IPv4 interfaces (`0.0.0.0:8880`), while a new Alertmanager installation listens on loopback only (`127.0.0.1:9093`). Existing Alertmanager installations retain their unit settings.

Restrict UI access to a trusted network or use a reverse proxy with authentication. The installer does not configure UI authentication or TLS.

To access a local Alertmanager instance over SSH:

```bash
ssh -L 19093:127.0.0.1:9093 user@SERVER_IP
```

Then open `http://127.0.0.1:19093/` in your local browser.

**Current limitation:** readiness checks and the final summary use fixed addresses, `127.0.0.1:8880` and `127.0.0.1:9093`. If you change ports or bind exclusively to a specific IP, update these parts of the script as well. Listening on `0.0.0.0:8880` works with the current loopback check.

## Initial Rules and Notifications

A new installation creates `00-bootstrap.yml` with the `BootstrapNeverFires` rule. Its condition requires a negative event count, so it never fires. This lets vmalert run before production rules are added.

If no Alertmanager configuration exists, the installer creates a `local-only` receiver without integrations: no external notifications are sent. Existing Alertmanager configurations and receivers are preserved.

Configure the Telegram bot, token, `chat_id`, production rules, and notification routing separately. Once production rules are in place, you can remove the bootstrap rule.

VictoriaMetrics is not required for basic rule evaluation and notification delivery. This installer does not configure alert state persistence or restoration through `remoteWrite`/`remoteRead`.

## Verification and Troubleshooting

Service status:

```bash
systemctl status vmalert alertmanager --no-pager
```

Recent logs:

```bash
journalctl -u vmalert -u alertmanager -n 100 --no-pager
```

Check endpoints:

```bash
curl -fsS http://127.0.0.1:8880/health
curl -fsS http://127.0.0.1:9093/-/ready
```

These checks confirm HTTP endpoint readiness. They do not verify Telegram delivery or successful queries to VictoriaLogs. Check the vmalert logs and UI for VictoriaLogs connection errors.

Installed binary versions:

```bash
/usr/local/bin/vmalert -version
/usr/local/bin/alertmanager --version
/usr/local/bin/amtool --version
```

Validate the Alertmanager configuration:

```bash
sudo -u alertmanager /usr/local/bin/amtool \
  check-config /etc/alertmanager/alertmanager.yml
```

Validate vmalert rules:

```bash
sudo -u vmalert /usr/local/bin/vmalert \
  -rule='/etc/vmalert/rules/*.yml' -dryRun
```

## Rerunning and Backups

Each run resolves the latest stable releases again, preserves existing configurations and units, updates binaries, and restarts services.

Before making changes, the script creates a separate `/var/backups/victorialogs-alerting-*` directory. Existing `/etc/vmalert`, `/etc/alertmanager`, local unit files, and the three binaries under `/usr/local/bin` are copied there with their directory structure preserved.

Backups do not include the Alertmanager data directory, vendor units, or systemd drop-in files. Automatic rollback and old backup cleanup are not implemented. If installation fails, inspect the logs, resolve the cause, and rerun the script. Restore individual files from the reported backup manually if needed.

## Component Documentation

- [VictoriaLogs: alerting with logs](https://docs.victoriametrics.com/victorialogs/vmalert/)
- [vmalert](https://docs.victoriametrics.com/victoriametrics/vmalert/)
- [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/)
- [Alertmanager configuration](https://prometheus.io/docs/alerting/latest/configuration/)

## Installer Author

Yevgeniy G. — [Sys-Adm.in Lab](https://lab.sys-adm.in/)
