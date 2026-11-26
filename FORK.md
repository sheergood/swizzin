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

## Useful checks on a server

```bash
systemctl list-timers swizzin-smart.timer      # when SMART data last refreshed
ls -l /var/lib/swizzin/smart/                  # one JSON per physical disk
journalctl -u panel -n 50                      # panel errors
vnstat -d 7                                    # the numbers behind the "Data transferred" card
```
