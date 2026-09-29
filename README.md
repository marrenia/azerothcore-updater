# acore-update

Unattended updater for [AzerothCore](https://www.azerothcore.org/) and its
modules. Fetches upstream, rebuilds, reinstalls, restarts the realm, and rolls
back automatically if it does not come back healthy — while letting you carry
local source patches that never block a future update.

It is written to work against an install it knows nothing about. On most
systems it needs **no configuration at all**.

```
$ sudo acore-update detect
  source tree     : /home/acore/azerothcore
  build dir       : /home/acore/azerothcore/build
  install prefix  : /home/acore/server
  server config   : /home/acore/server/etc
  runs as user    : acore
  world service   : acore-worldserver
  health probe    : <tcp 127.0.0.1:8085>
  failure reports : /home/you  (written as you)

repositories discovered:
  core               Playerbot    /home/acore/azerothcore
  mod-ah-bot         master       /home/acore/azerothcore/modules/mod-ah-bot
  mod-playerbots     master       /home/acore/azerothcore/modules/mod-playerbots

health right now: OK
```

## Honest status

This was extracted from one working private realm, where it has run unattended
for a short time — days, not months. It is **vibecoded**: written quickly with
an AI assistant, reviewed, and exercised against exactly one server layout
(Ubuntu, systemd, MySQL, playerbots fork, out-of-the-box paths).

The logic is defensive and every failure path was reasoned through, but only
some have actually fired for real. The patch-no-longer-applies path has, and
aborted the run cleanly with the realm untouched. So has a build failure: a
newly added module that did not compile on the playerbots fork, which rolled
the source back without ever stopping the realm. A full restore-from-rollback
has not.

If your realm matters, read the script before you run it, and try
`--dry-run` first. It is about 500 lines of readable bash with comments
explaining *why*, not just what.

## Install

```bash
git clone https://github.com/marrenia/azerothcore-updater.git
cd azerothcore-updater
sudo ./install.sh
```

The installer copies two scripts to `/usr/local/sbin`, creates
`/etc/acore-update.conf` with everything commented out, records **your** home
directory as the place failure reports go (see [When a run fails](#when-a-run-fails)),
runs `detect` so you can see what it found, and offers a daily systemd timer.

Then, before trusting it:

```bash
sudo acore-update detect        # is this your server?
sudo acore-update --dry-run     # what would it do?
sudo acore-update test-report   # where would you hear about a failure?
```

## What it detects, and how

| Thing | How |
|---|---|
| Source tree | a git checkout with `CMakeLists.txt` + `src/server`, in the usual places |
| Build dir | the directory containing `CMakeCache.txt` |
| Install prefix | `CMAKE_INSTALL_PREFIX` read straight out of `CMakeCache.txt` |
| Service user | owner of the source tree |
| Repos to track | core, plus **every** `modules/*/` that is its own git checkout |
| Branch per repo | whatever each repo is already on — no assumptions |
| systemd units | tries `acore-worldserver`, `worldserver`, `azerothcore-worldserver`, `ac-worldserver` |
| World port | `WorldServerPort` from `worldserver.conf`, else 8085 |
| DB credentials | the `*DatabaseInfo` lines in `worldserver.conf` |

Anything wrong or undetectable is one line in `/etc/acore-update.conf`. See
[`acore-update.conf.example`](acore-update.conf.example).

**Not using systemd?** Set `ACORE_START_CMD` and `ACORE_STOP_CMD` to anything —
docker compose, tmux, screen, supervisor — and the unit detection is bypassed
entirely. Examples are in the config file.

## Local patches that don't block updates

The point of the patch series: carry your own C++ changes forever without ever
being unable to update.

```bash
sudo acore-patch edit mod-playerbots        # pristine upstream + your series
# ...edit files...
sudo acore-patch create mod-playerbots fix-thing
sudo acore-patch check                      # do they all still apply?
sudo acore-update --force
```

Patches are applied with `git apply` into the **working tree**, never
`git am`. This is the whole trick: commits would move `HEAD` off the upstream
branch and the next `git merge --ff-only` would refuse — silently turning a
patched server into one that never updates again. Working-tree patches keep
`HEAD` byte-identical to upstream, so fast-forward always succeeds and the
series is re-applied on top after each update.

A patch that stops applying **aborts the run before the build**, with the realm
untouched. That is deliberate: quietly shipping a binary missing a fix someone
added by hand is worse than not shipping.

A changed patch set also triggers a rebuild on its own, so a patch added today
does not sit unbuilt until upstream happens to move.

## Order of operations

```
detect → fast-forward → apply patches → build → backup → install → verify → rollback?
```

Two orderings are deliberate:

**The build happens while the realm is still up.** The build tree is separate
from the install prefix, so compiling costs no downtime. The realm only stops
for `cmake --install` and the restart.

**The database dump is taken after the build, not before.** AzerothCore applies
SQL migrations when the worldserver starts. A dump taken before a two-hour
compile is already two hours stale as a restore point; taken after, it is
seconds old.

## Safety

- Refuses to start against an **already-unhealthy** realm — otherwise its own
  breakage is indistinguishable from the pre-existing kind, and "rollback"
  restores something that was already down.
- **Fast-forward only.** If upstream rewrote history it aborts rather than
  `reset --hard` unsupervised.
- **Build failure never touches the realm** — source is reset, the running
  server is left completely alone.
- **Install failure** restores the binary tarball taken moments earlier.
- **Unhealthy after restart** rolls binaries *and* source back, then re-checks.
- Optional `ACORE_MEM_MAX` caps the build in a systemd scope so that under
  memory pressure the kernel kills the compiler, never the worldserver.
- `git clean` runs **without** `-x`, so gitignored content such as
  `data/sql/custom/` survives every update.

### The one thing it will not do

**It never auto-restores the database.** After a rollback the schema stays
newer than the restored binary. Migrations are additive in almost every case
and an older binary generally tolerates a newer schema, whereas restoring a
dump silently discards every character change since it was taken. Trading real
player progress for a usually-cosmetic mismatch is the worse deal, so that call
is left to a human. The dumps are in `ACORE_BACKUP_DIR` if you want them.

## Exit codes and status

| Code | Meaning |
|---|---|
| 0 | Nothing to do, or updated successfully |
| 1 | Failed, **realm is healthy** |
| 2 | Failed **and the realm is down** — needs a human |

`/var/lib/acore-update/last-run.json` is written on every exit, including
crashes, so a monitor never mistakes a stale success for a current one:

```json
{
  "result": "success",
  "phase": "verify",
  "updated": "core 06234df3d->025ede00f (132); ",
  "patches_applied": 1,
  "realm_healthy": true
}
```

`result` is one of `noop`, `success`, `failed`, `rolledback`, `down`,
`skipped`, `dryrun`. For a build failure, `detail` includes the first compiler
errors.

## When a run fails

A failed, rolled-back or realm-down run leaves a plain-text report in the home
directory of whoever installed acore-update, so finding out needs no mail
server, chat bot or webhook - just `ls ~`:

```
~/acore-update-FAILED-2026-09-29T16-49-33Z.txt
```

It says what failed and when, whether the realm is still up, and what changed.
For a **build** failure it also includes the first compiler errors and the last
60 lines of the build log. One file per failure; the newest 10 are kept
(`ACORE_REPORT_KEEP`).

- `install.sh` records `SUDO_USER` and their home directory in
  `/etc/acore-update.conf` as `ACORE_REPORT_DIR` / `ACORE_REPORT_OWNER`.
  The nightly timer runs as root and would otherwise have no idea who you are.
  Change either, or unset `ACORE_REPORT_DIR` to turn reports off.
- The file is written **as that user**, never as root. Root writing into a
  directory another user controls can be redirected onto any file on the
  system by a symlink planted at the report's path; writing as the owner means
  it can only ever touch what they could.
- `sudo acore-update test-report` writes a clearly labelled sample, so you can
  confirm where reports land without waiting for something to break.

The full output of the most recent build is kept in
`/var/lib/acore-update/build-last.log` (the one before as `.1`), whether it
succeeded or not.

## Adding and removing modules

Modules are discovered, not configured: clone one into `modules/` and the next
run tracks it. Changing the **set** of modules triggers a rebuild on its own,
even if no repository has new commits. A freshly cloned module is already at
its upstream head, so without this it would be tracked forever and never
compiled in.

The first run after upgrading to a version with this behaviour records the
current set as a baseline instead of rebuilding, so upgrading acore-update
never costs you a surprise restart. If you added a module just before
upgrading, run `sudo acore-update --force` once.

## Requirements

`git`, `cmake`, `bash` 4+, and a compiler — i.e. whatever you already needed to
build AzerothCore. `mysqldump` for database backups (skipped with a warning if
absent). `systemd` only if you want the timer, the memory cap, or unit
detection.

## Things that bit us, so they might bite you

- **Shallow clones.** `git clone --depth 1` leaves no usable merge-base, so
  "commits behind" reports the entire upstream history — we saw *20058* for an
  eight-day gap. The script deepens once on first run.
- **`runuser` keeps the caller's `HOME`.** Without an explicit `HOME=`, ccache
  writes to `/root/.ccache` as the service user and silently caches nothing
  while the build still succeeds.
- **The cmake variable is `TOOLS_BUILD`, not `TOOLS`.** `-DTOOLS=0` is accepted
  and ignored.
- **A new module is never built.** Each repository is checked for new upstream
  commits, and a module you just cloned has none - so it sat on disk, tracked
  and uncompiled. Now the module set itself is a rebuild trigger.
- **Compiler errors went missing.** A real build failure left no compiler error
  in the journal at all; the cause had to be found by hand-compiling objects
  one by one. We never pinned down why. Build output is now also written to a
  file, and the first errors are copied into the status file and the report.
- **Module compatibility with the playerbots fork.** Some modules call
  `WorldSession::IsHeadless()`, which upstream AzerothCore added and the
  playerbots fork still names `IsBot()`. They fail to compile there. Carry a
  small compatibility patch (see *Local patches*) until the fork catches up.

## Licence

MIT. See [LICENSE](LICENSE).
