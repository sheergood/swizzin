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

## Upstream updates: how the original project's changes reach your servers

Both forks follow the same protocol. `sheergood/swizzin` follows `swizzin/swizzin`, and
`sheergood/swizzin_dashboard` follows `liaralabs/swizzin_dashboard`. It is run every Monday by
`.github/workflows/upstream-sync.yml`. It only ever pushes to these forks: never to the original
projects, and it never opens pull requests there.

```
upstream commit ──(7 days old?)──► merge into upstream-sync ──► full CI ──► needs approval? ──► promote
       │ no: waits                        │ conflict: issue           │ fail: issue    │ yes: issue
       ▼                                  ▼                           ▼                ▼  + approve
   next run                         you merge by hand          nothing changes    gh workflow run …
```

1. **Quarantine.** An upstream commit is taken only once it's `QUARANTINE_DAYS` (7) days old. A
   broken release and the author's fix the next day therefore arrive together, and a reverted
   commit never arrives at all.
2. **Merge on a scratch branch.** The update is merged into `upstream-sync`. `master` and
   `custom` are untouched.
   - A merge conflict opens an issue.
   - Upstream changes to workflow files always need a merge by hand, because GitHub doesn't let
     the job change them.
3. **Full CI on the merged result.** This runs the same tests as every push: shellcheck, the
   panel and fail2ban tests, nginx config tests and the FileBrowser Quantum end-to-end test.
   If anything fails, nothing changes and an issue says why.
4. **Approval for anything risky.** The update is merged and tested, but waits for you, when it:
   - changes code `box update` runs on every server (`REVIEW_PATHS`: `scripts/box`, `setup.sh`,
     `sources/`, `scripts/update/`);
   - changes an app you run (`PROTECTED_APPS`: autobrr, Filebrowser, FileBrowser Quantum, Plex,
     Prowlarr, qBittorrent, Radarr, Sonarr, panel, nginx, Let's Encrypt);
   - changes a file this fork has changed too, even when git merged it cleanly. A clean text
     merge can still break what the fork's change relies on;
   - removes an app (this fork keeps every app unless you decide otherwise);
   - comes from the dashboard's upstream at all (`REVIEW_ALL`): the panel is rewritten here, so
     no upstream change is taken unseen.

   The issue lists the reasons, the CI result, the commits and a link to the full diff. To
   approve, use the command in the issue. The update is merged and tested again, then promoted:
   ```bash
   gh workflow run upstream-sync.yml -R sheergood/swizzin -f approve=<upstream commit>
   ```
   (or Actions → upstream-sync → Run workflow → approve). To decline, do nothing. It keeps
   waiting, and the issue is only updated when upstream adds more.
5. **Promote, with a rollback point.** The current `master` is tagged `pre-sync-<date>-<commit>`.
   Then `master` and `custom` are fast-forwarded; this is never forced, so a branch that moved
   meanwhile is left alone and reported. The result is tagged `sync-<date>-<commit>`. Servers
   get it on their next `box update`, which you start yourself, and which still has the panel's
   own health check and rollback.

**Rolling a server back** to the version before an upstream update:
```bash
sudo -i
SWIZ_GIT_REF=tags/pre-sync-20261207-1bb1321 box update     # the tag from the sync summary
```
Plain `box update` goes back to following `master`. To hold a server at a version you trust, keep
using `SWIZ_GIT_REF=tags/<tag>` until you're ready.

**Parameters** are in `.github/upstream-sync.conf` in each repository: `QUARANTINE_DAYS`,
`REVIEW_ALL`, `REVIEW_PATHS` and `PROTECTED_APPS`. A change there is tested by CI like any other
change (`.github/scripts/test-upstream-merge.sh` checks every rule). To rehearse a sync without
changing anything, use Actions → upstream-sync → Run workflow → test only.

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
box install fbquantum     # newest stable release, at https://your-server/fbquantum/ (own login page, swizzin username/password)
box upgrade fbquantum     # newest stable; rolls back by itself if it fails to start
box remove fbquantum      # removes the app and its settings, never your files
```

The original File Browser (`box install filebrowser`) still works but was archived upstream on
Aug 31 2026 and gets no more security fixes; Quantum is its maintained successor. Both can be
installed side by side while you move over.

## Merging an upstream update by hand

When an issue asks for it (conflict, or upstream changed a workflow file). See "Upstream updates"
above for everything else.

```bash
git clone https://github.com/sheergood/swizzin && cd swizzin
git remote add upstream https://github.com/swizzin/swizzin.git
git fetch upstream
git merge <upstream commit from the issue>   # resolve conflicts, add a CHANGELOG entry
git push origin HEAD:custom                  # CI runs; when it's green:
git push origin HEAD:master
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
