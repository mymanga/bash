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

- **nginx** + **PHP-FPM** serving the Laravel panel from `/var/www/html` (with Let's Encrypt via certbot). PHP is pinned per product — SimpleISP: **7.4** (the panel has code that breaks on newer PHP), SimpleSpot: **8.2** — and installs from the ondrej PPA on every supported Ubuntu release, so the pin holds on 24.04 too.
- **MariaDB** (unix_socket root auth; credentials written to a file reported at the end of the install)
- **FreeRADIUS 3.2** with buffered SQL accounting into the `radius` database — accounting goes to a local detail file and the `buffered-sql` virtual server replays it into SQL, so records survive DB stalls/restarts. Packages come from NetworkRADIUS on focal/jammy (config root `/etc/freeradius/`, their archives only have 3.0.x) and from the Ubuntu archive on noble+ (config root `/etc/freeradius/3.0/`, 3.2 in main with security updates). Existing noble servers installed with NetworkRADIUS packages keep them — apt won't downgrade; only fresh installs switch.
- **Valkey** (Redis-compatible cache) with systemd hardening overrides — installed from Percona's repo on focal/jammy (service `valkey`), from the Ubuntu archive on noble (service `valkey-server`)
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

## Migration

### `aisp.sh` — SimpleISP → AISP migration prep

Opens a SimpleISP server up for a migration pull: a read-only MariaDB user on the `radius` database reachable from outside, and root SSH by public key while password login stays available for everyone else. Run on the **source** (SimpleISP) server as root:

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/mymanga/bash/main/aisp.sh)
```

Four steps, each backing up what it touches:

- **SSH** — rewrites `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf` to `PermitRootLogin prohibit-password` + `PasswordAuthentication yes`, so root is key-only and other accounts keep password login. Aborts if `/root/.ssh/authorized_keys` is empty (you would lock yourself out), validates with `sshd -t` before reloading, and warns if another drop-in or the main config also sets those keywords — sshd honours the **first** occurrence it reads, so an earlier-sorting file silently wins.
- **MariaDB** — sets `bind-address = 0.0.0.0` in `/etc/mysql/mariadb.conf.d/50-server.cnf` (handles a commented-out line), comments out `skip-networking`, restarts.
- **Database user** — `aisp_ro`@`%` with `SELECT, SHOW VIEW` on `radius`. Credentials are written to **`/root/aisp.txt`** (mode 600) as `KEY=value` lines, so the migration tooling can `source` it directly.
- **UFW** — allows `3306/tcp`.

Both edited configs are backed up alongside the originals as `.bak-<timestamp>`, and the run ends by printing the connection string and the teardown commands.

Overrides via environment:

| Variable | Default | Purpose |
|---|---|---|
| `DB_NAME` | `radius` | Database to grant read access on |
| `DB_USER` | `aisp_ro` | User to create |
| `DB_PASS` | *generated* | 28-char random if unset; must not contain quotes or backslashes |
| `DB_PORT` | `3306` | Port to open and record |
| `ALLOW_CIDR` | `any` | Restrict the UFW rule to a single source |
| `CREDS_FILE` | `/root/aisp.txt` | Where credentials are written |

```bash
sudo ALLOW_CIDR=203.0.113.10/32 bash <(curl -fsSL https://raw.githubusercontent.com/mymanga/bash/main/aisp.sh)
```

Use process substitution (`bash <(curl ...)`) rather than `curl ... | sudo bash` — the script prompts on the missing-root-key check, and in a pipe that `read` consumes the script itself instead of your answer.

Tear down once the migration is complete. Leaving 3306 open to the internet with a plaintext password on disk is the wide-open state this script deliberately creates, and it should not outlive the migration:

```bash
ufw status numbered && ufw delete <num>
mysql -e "DROP USER 'aisp_ro'@'%';"
shred -u /root/aisp.txt
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