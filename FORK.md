# sheergood/swizzin

A personal fork of [swizzin/swizzin](https://github.com/swizzin/swizzin) for my seedbox servers.
Licensed under GPL-3.0 like upstream; every change is listed in `CHANGELOG.md` under the
`sheergood-*` entries.

## What's different

| Area | Upstream | This fork |
|---|---|---|
| Installer source | `swizzin/swizzin` | `sheergood/swizzin` (`SWIZ_REPO` overrides) |
| Panel source | `liaralabs/swizzin_dashboard` | `sheergood/swizzin_dashboard` (`PANEL_REPO`, `PANEL_BRANCH`) |
| Panel UI | Bootstrap dashboard | Liquid-glass dashboard with CPU/GPU/SMART/wear/network detail; old UI at `/classic` |
| Apps | ~60 | autobrr, filebrowser, plex, prowlarr, qbittorrent, radarr, sonarr (+ nginx, panel, letsencrypt) |
| Drive health | — | `swizzin-smart.timer` → `/var/lib/swizzin/smart/*.json`; SSD wear level, HDD SMART table |
| Traffic stats | Panel table | Today / week / 7 days / month / all time + 7-day chart from vnstat |
| Security | — | fail2ban jails and recent bans (`swizzin-f2b.timer` → `/var/lib/swizzin/fail2ban.json`) |
| Updates | — | non-fatal extras, panel backup + health check + auto-rollback, unsupported-app warning, CI |

## Rolling out to production safely

1. **Try it on one server first** (or a cheap VPS) before the rest.
2. **Pin a release** instead of following `master` if you want to choose when servers change:
   ```bash
   sudo -i
   SWIZ_GIT_REF=tags/sheergood-1 box update
   ```
   Plain `box update` follows `master` again.
3. What `box update` does to protect a live server:
   - apps this fork dropped are **listed, never removed** — they keep running
   - SMART / fail2ban / vnstat setup can fail without stopping the update
   - the panel is backed up before switching to the fork, health-checked after every upgrade and
     **rolled back automatically** if it doesn't come up; the old UI stays at `/classic`
   - CI runs on every push, so a broken script or panel never lands on `master` unnoticed

## Rollback

```bash
# back to upstream swizzin
sudo git -C /etc/swizzin remote set-url origin https://github.com/swizzin/swizzin.git
sudo box update

# back to the upstream panel (or restore /root/swizzin-panel-backup-*.tar.gz into /opt)
sudo -u swizzin git -C /opt/swizzin remote set-url origin https://github.com/liaralabs/swizzin_dashboard.git
sudo box upgrade panel

# optional: stop the fork's collectors
sudo systemctl disable --now swizzin-smart.timer swizzin-f2b.timer
```

## Fresh install

```bash
bash <(curl -sL https://raw.githubusercontent.com/sheergood/swizzin/master/setup.sh)
```

## Move an existing upstream install onto the fork

```bash
sudo git -C /etc/swizzin remote set-url origin https://github.com/sheergood/swizzin.git
sudo box update
```

`box update` then also switches the panel checkout in `/opt/swizzin` to
`sheergood/swizzin_dashboard` (your `core/custom` profiles are kept) and installs the SMART timer.

## Pulling upstream fixes later

```bash
git remote add upstream https://github.com/swizzin/swizzin.git
git fetch upstream
git merge upstream/master   # resolve conflicts, then push
```

> Apps removed from this fork that are already installed on a server keep running, but `box` can no
> longer remove or upgrade them. Remove them with upstream swizzin **before** switching, e.g.
> `box remove deluge rtorrent`.

## Panel settings (`/opt/swizzin/swizzin.cfg`, then `systemctl restart panel`)

```python
WEATHER_LAT = 25.43          # show weather for a fixed place instead of the server's location
WEATHER_LON = 81.85
WEATHER_PLACE = "Prayagraj"
WEATHER_UNITS = "metric"     # or "imperial"
PLACE_LOOKUPS = False        # never contact ipwho.is / ipinfo.io / open-meteo
```

## Useful checks on a server

```bash
systemctl list-timers swizzin-smart.timer      # when SMART data last refreshed
ls -l /var/lib/swizzin/smart/                  # one JSON per physical disk
systemctl list-timers swizzin-f2b.timer        # fail2ban snapshot (every 2 min)
journalctl -u panel -n 50                      # panel errors
vnstat -d 7                                    # the numbers behind the "Data transferred" card
```
