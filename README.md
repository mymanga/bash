# SimpleISP / SimpleSpot Server Scripts

Bash scripts for installing and maintaining [SimpleISP](https://github.com/simpleisp/radius) and SimpleSpot hotspot/ISP billing servers on Ubuntu (focal / jammy / noble).

## Installers

| Script | Installs | PHP |
|---|---|---|
| `ubuntu_simpleisp.sh` | SimpleISP (ISP billing panel) | 7.4 |
| `ubuntu_simplespot.sh` | SimpleSpot (hotspot billing panel) | 8.2 |

The two installers are identical except for the application repository and PHP version. Run on a fresh Ubuntu server as root:

```bash
chmod +x ubuntu_simpleisp.sh
sudo ./ubuntu_simpleisp.sh
```

Each installer sets up the full stack:

- **nginx** + **PHP-FPM** serving the Laravel panel from `/var/www/html` (with Let's Encrypt via certbot)
- **MariaDB** (unix_socket root auth; credentials written to a file reported at the end of the install)
- **FreeRADIUS 3.2** (NetworkRADIUS packages) with SQL accounting into the `radius` database
- **Valkey** (Redis-compatible cache) with systemd hardening overrides
- **OpenVPN** (via `openvpn.sh`) with systemd `ReadWritePaths` overrides so the panel can manage `/etc/openvpn`
- **supervisor** for Laravel queue workers, UFW rules, cron jobs, and sudoers entries for `www-data` service control

At the end, the installer places the maintenance scripts below into `/var/www/html/sh/`, schedules them, and runs the autotune once.

## Maintenance scripts

Installed to `/var/www/html/sh/` on the server; all three support `--dry-run`.

### `universal.sh` — capacity-model autotune

Sizes MariaDB, Valkey, PHP-FPM, and FreeRADIUS from one capacity model that scales from 2 vCPU / 2 GB to 16 vCPU / 16 GB (~5,000 concurrent hotspot users at the top tier). Copy it unchanged to any size server; it self-sizes.

- Backs up the database and all touched configs before changing anything; keeps the newest **3** runs (including the `.bak.*` copies written next to live configs)
- Applies MariaDB and Valkey settings **live** (`SET GLOBAL` / `valkey-cli`) — no restart, no cold cache
- Reloads PHP-FPM only if its pool config changed and `php-fpm -t` passes; restarts FreeRADIUS only if `radiusd.conf` changed **and** validates with `-XC` (rolls back otherwise)
- Ensures indexes on `radacct` and friends
- Removes the legacy `update_memory_config.sh` (file + cron) if a previous install left it behind
- Logs to `/var/log/universal_<timestamp>.log`; backups under `/var/backups/universal/`

### `db_cleanup.sh` — RADIUS database retention

Batched cleanup of closed `radacct` sessions, `radpostauth`, expired portal sessions and vouchers, payment ledgers, and Laravel `failed_jobs`; closes zombie sessions and runs `ANALYZE` / conditional `OPTIMIZE`.

```
db_cleanup.sh [--dry-run] [--auto] [--ask]
```

Run interactively it prompts per category for a retention age (`12h`, `2d`, `1w`, `3m`, `s` to skip) and confirms before deleting. Without a terminal (or with `--auto`) it silently uses the built-in defaults. **Not scheduled** — run it manually when the database needs trimming. Logs to `/var/log/radius_db_cleanup.log`.

### `ovpn_fix.sh` — PHP-FPM OpenVPN sandbox fix

Debian/Ubuntu php-fpm units ship with `ProtectSystem=full`, which makes `/etc` read-only inside the service and breaks panel writes to `/etc/openvpn/server.conf`. This script finds every installed `phpX.Y-fpm` unit (and any systemd Laravel queue-worker units), installs a `ReadWritePaths=/etc/openvpn` drop-in, restarts the affected units, and verifies writability from inside each service's mount namespace. Idempotent — safe to re-run any time.

```
ovpn_fix.sh [--dry-run] [--no-restart]
```

## Scheduled jobs (installed to root's crontab)

| Schedule | Job |
|---|---|
| `* * * * *` | Laravel scheduler (`artisan schedule:run`) |
| `*/5 * * * *` | Valkey health monitor (`valkey-debug.sh`) |
| `0 3 * * *` | `universal.sh` — daily autotune |
| `@reboot` (after 120 s) | `universal.sh` — re-tune after boot |

`db_cleanup.sh` is deliberately not scheduled; run it manually when needed.

## Utility scripts

| Script | Purpose |
|---|---|
| `openvpn.sh` | Standalone OpenVPN road-warrior installer (downloaded and run by the installers) |
| `clean_server.sh` | Uninstalls everything the installer set up and prepares the server for a clean reinstall (writes a marker the installer detects) |
| `ports.sh` | Configures firewall/port rules for a given subnet (`ports.sh -net <subnet>`) |
| `setup.sh` / `install.sh` | Minimal standalone MariaDB + app bootstrap (older path) |
| `transfer_tmpl.sh` | Proxmox: clones VM templates between nodes via the API |
| `template_generation.sh` | Proxmox: commands to build an Ubuntu cloud-image VM template |

## Legacy

`ubuntu_simpleisp_old.sh` and `ubuntu_simplespot_old.sh` are the previous generation of the installers, kept for reference. They embed the superseded `update_memory_config.sh` tuning approach — new installs should always use the current `ubuntu_simpleisp.sh` / `ubuntu_simplespot.sh`.
