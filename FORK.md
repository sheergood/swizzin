# sheergood/swizzin

A personal fork of [swizzin/swizzin](https://github.com/swizzin/swizzin) for my seedbox servers.
All upstream applications, `box` commands and install scripts are kept exactly as upstream —
the fork only replaces the panel UI and adds the background collectors it reads.
Licensed under GPL-3.0 like upstream; every change is listed in `CHANGELOG.md` under the
`sheergood-*` entries.

## What's different

| Area | Upstream | This fork |
|---|---|---|
| Installer source | `swizzin/swizzin` | `sheergood/swizzin` (`SWIZ_REPO` overrides) |
| Panel source | `liaralabs/swizzin_dashboard` | `sheergood/swizzin_dashboard` (`PANEL_REPO`, `PANEL_BRANCH`) |
| Panel UI | Bootstrap dashboard | Liquid-glass dashboard with CPU/GPU/SMART/wear/network detail; old UI at `/classic` |
| Apps | all | all — unchanged from upstream |
| Drive health | — | `swizzin-smart.timer` → `/var/lib/swizzin/smart/*.json`; SSD wear level, HDD SMART table |
| Traffic stats | Panel table | Today / week / 7 days / month / all time + 7-day chart from vnstat |
| Security | — | fail2ban jails and recent bans (`swizzin-f2b.timer` → `/var/lib/swizzin/fail2ban.json`) |
| Updates | — | non-fatal panel extras, panel backup + health check + auto-rollback, CI |

## Rolling out to production safely

1. **Try it on one server first** (or a cheap VPS) before the rest.
2. **Pin a version** instead of following `master` if you want to choose when servers change.
   Use a commit hash from the GitHub history, or a release tag you created on GitHub
   (Releases → Draft a new release → tag `sheergood-1`):
   ```bash
   sudo -i
   SWIZ_GIT_REF=<commit> box update           # a commit hash from GitHub
   SWIZ_GIT_REF=tags/sheergood-1 box update   # or a release tag
   ```
   Plain `box update` follows `master` again. The panel always tracks `master` of
   sheergood/swizzin_dashboard but rolls itself back if an update doesn't start.
3. What `box update` does to protect a live server:
   - apps are untouched: the fork changes nothing outside the panel
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
`sheergood/swizzin_dashboard` (your `core/custom` profiles are kept) and installs the SMART and
fail2ban timers. Nothing else on the server changes.

## Extra app: FileBrowser Quantum

```bash
box install fbquantum     # newest stable release, at https://your-server/fbquantum/
box upgrade fbquantum     # newest stable; rolls back by itself if it fails to start
box remove fbquantum      # removes the app and its settings, never your files
```

The original File Browser (`box install filebrowser`) still works but was archived upstream on
Aug 31 2026 and gets no more security fixes; Quantum is its maintained successor. Both can be
installed side by side while you move over.

## Staying up to date with the original swizzin (automatic)

`.github/workflows/upstream-sync.yml` runs every Monday at 03:17 UTC (08:47 IST):

1. merges new commits from `swizzin/swizzin` `master` into the scratch branch `upstream-sync`;
2. runs this fork's full CI on it (file permissions, bash syntax, shellcheck, Python, helpers);
3. only if that passes, fast-forwards `master` and `custom` (never forced). Servers pick it up on
   their next `box update`.

If the merge conflicts, CI fails, or upstream changes a GitHub workflow file (which an automated
job isn't allowed to push), nothing is changed and an issue labelled `upstream-sync` is opened in
this fork with the details; it closes itself once a later run succeeds. Nothing is ever sent to the
original author. To run it now: **Actions → upstream-sync → Run workflow** (tick *test only* to
rehearse without changing any branch). `sheergood/swizzin_dashboard` has the same job
(Mondays 03:41 UTC) against `liaralabs/swizzin_dashboard`.

Merging by hand, if an issue asks for it:

```bash
git remote add upstream https://github.com/swizzin/swizzin.git
git fetch upstream
git merge upstream/master   # resolve conflicts, then
git push origin HEAD:master HEAD:custom
```

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
