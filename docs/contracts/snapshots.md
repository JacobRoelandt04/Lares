# Contract: system snapshots

The fixed names and formats between the root tool (`tools/snapshot/root/`), the user's tools (`tools/snapshot/lares-snapshot`,
`tools/snapshot/lares-offsite`), the rescue image and the shell (`modules/bar/system_update/`). User page: `docs/snapshots.md`.
A name in here is changed HERE first, then in every part.

## 1. Who does what
| Part | Runs as | Owns |
|---|---|---|
| `lares-snapshot-root` (Python, stdlib, `python3 -I`) | root | restic, the repository, the records, the rule, the guards, the retention |
| `hook` (sh) | root, inside pacman | lets the transaction through when the tool cannot work; else runs the root tool |
| rescue image (ash) | root, before the system | the offline restore |
| `lares-snapshot` (Python) | you | the CLI, the undo plan, the undo run |
| `lares-offsite` (Python) | you | the copy on Proton Drive |
| `SnapshotService.qml` | the shell, once | says when, shows the state; holds no rule of its own but `SnapshotRules.js` (section 4) |

The root tool imports nothing from your home. What it shares with the user's tools is copied beside it at install (`snaprules.py`,
`jsonc.py`); the repo has one copy of each (`tools/snapshot/root/snaprules.py`, `tools/lib/jsonc.py`).

## 2. Files
```
/usr/local/lib/lares/snapshot/        root:root 0755
    lares-snapshot-root  hook  snaprules.py  jsonc.py  defaults.json  user (one line: your name)  rescue/
/etc/pacman.d/hooks/00-lares-snapshot.hook          PreTransaction, NeedsTargets, AbortOnFail
/etc/pacman.d/hooks/zz-lares-snapshot-done.hook     PostTransaction, NeedsTargets
/etc/grub.d/45_lares_rescue
/boot/lares/rescue-vmlinuz  /boot/lares/rescue.img
/usr/share/polkit-1/actions/org.lares.snapshot.policy   /etc/polkit-1/rules.d/50-lares-snapshot.rules
/etc/lares/snapshot.off               exists = the hook does nothing (the break-glass file; root makes it, root removes it)

/.lares-snapshots/                    root:root 0755; outside every covered path, so no restore can reach it
    repo/            restic, format 2, root:<you>, directories 2750 (setgid: what restic writes is yours to read at once), files group-readable (ciphertext)
    oplock           root 0600, flock: one create / keep / tidy / delete at a time. Root only: what anyone can open, anyone can hold
    key              root 0600, the repository's password (one line)
    lock             0644, flock: only the forget + prune part of `tidy` and `delete` take it exclusive (a tidy that cannot skips its prune), the
                     off-site upload shared. A create never takes it: it removes nothing, so a process of yours holding it cannot stop an update
    records/<short>.json   0644 (section 5)
    index.tsv        0644 (section 5), for the rescue
    state.json       0644 (section 6)
    log              0644, the tool's own log, cut at 1 MB

$XDG_RUNTIME_DIR/lares/snapshot-skip           the one-run skip token (section 7)
$XDG_STATE_HOME/lares/snapshots/offsite.json   (section 9)   offsite-manifest.json beside it
config/snapshots.jsonc                         (section 8)   .examples/snapshots.jsonc
```

## 3. What a snapshot covers
- Paths: `/usr /opt /etc /srv /root /var/lib`, and every regular file DIRECTLY in `/boot` (never a directory of it). `--one-file-system`.
- Default excludes (`defaults.json`): `/var/lib/ollama`, `/var/lib/systemd/coredump`, `/var/lib/docker`, `/var/lib/containers`,
  `/var/lib/containerd`, `/var/lib/libvirt/images`, `/var/lib/machines`, `/var/lib/portables`, `/var/lib/flatpak/repo`, `/var/lib/waydroid`,
  `/var/lib/pacman/sync`, `/root/.cache`. Only what a restore can name is left out, so never `--exclude-caches`: a restore with `--delete` would
  empty every tagged folder.
- Protected at a restore (kept as they are now): `/usr/local/lib/lares/snapshot`, `/etc/pacman.d/hooks/00-lares-snapshot.hook`,
  `/etc/pacman.d/hooks/zz-lares-snapshot-done.hook`, `/etc/grub.d/45_lares_rescue`, `/etc/lares`, `/etc/fstab`, `/etc/crypttab`,
  `/usr/share/polkit-1/actions/org.lares.snapshot.policy`, `/etc/polkit-1/rules.d/50-lares-snapshot.rules`. A restore leaves alone the UNION of the record's
  excludes and the default list, whatever the record says (a record with no list must not delete what was never saved). `/boot/lares`, `/boot/grub` and
  `/boot/EFI` are not covered, so nothing there is read or written.
- restic: `backup --one-file-system --no-cache --pack-size 64 --read-concurrency 8 --json --tag lares --tag <reason>`, `--host` the machine's name.
  Password through `RESTIC_PASSWORD_FILE=/.lares-snapshots/key`. Normal priority in the hook, idle CPU and I/O class in `tidy`.
- **The disk decides the time, not restic** (2026-11-22, this laptop: QLC SSD at 88 %, TRIM never run): reading and comparing 599 000 files is
  22 s; WRITING was 228 MB/s for about 1 GB, then 30 MB/s (`dd oflag=direct`; after the first TRIM the same test wrote 0.7 to 2.4 GB/s over 6 GB). The first snapshot (12 GB) took 8 min 34 s at normal priority and 8 min 42 s at
  `nice`. Hence the prime (section 6): what an update brought is written after it, in the background, so the snapshot before the next one is the 22 s.
- A second snapshot of one machine is grouped by `--group-by host` (the paths of `/boot` change with the kernels), so the parent is found.

## 4. The rule (`SnapshotRules.js` and `snaprules.py`, one table: `tools/dev/snapshot_rule_cases.json`)
`wants(names, settings) -> { want, count, critical[] }`: want = `count >= minPackages`, or a name matches a critical glob (`*` only,
whole name, case sensitive). `names` are the packages the transaction upgrades or installs.
- Default `minPackages` 40. Default critical list: `linux linux-lts linux-zen linux-hardened linux-firmware nvidia* mesa glibc gcc-libs systemd systemd-libs
  grub mkinitcpio pacman pam sudo polkit sddm hyprland aquamarine quickshell* qt6-base qt6-declarative openssl util-linux e2fsprogs dbus
  wayland bash coreutils python`.
- Once per run: the run is the TOP-MOST ancestor process of the hook whose comm is one of `yay paru pikaur aura pamac pacman`, as
  `<pid>:<starttime>` (field 22 of `/proc/<pid>/stat`). A later transaction of a run that already has a snapshot answers `skip run`.
- An `Operation = Remove` alone never asks for one.
- `notable(names)`: the critical ones first in list order, then nothing else; at most 4 shown.

## 5. The records
`records/<short>.json`, `<short>` = the first 8 hex digits of the restic id:
```
{ "version": 1, "id": "<64 hex>", "short": "6a493314", "time": <unix seconds>,
  "reason": "update" | "undo" | "manual" | "rescue",
  "run": "<pid>:<starttime>" | null,
  "count": 112, "critical": ["linux", "mesa"],
  "targets": ["linux", ...],
  "before": { "<name>": "<version>", ... },          every installed package (pacman -Q) before the transaction
  "changed": [ { "name", "from", "to" } ] | null,     written by `hook done`; from null = installed, to null = removed
  "state": "open" | "done",                           open until `hook done` ran; open with no pacman running = the update did not finish
  "keep": false, "note": "",
  "added": <bytes>, "addedPacked": <bytes>, "files": <n>, "bytes": <n>, "seconds": <n>,
  "unreadable": <n>,                                 files restic could not read: a restore of this snapshot deletes them, so the rescue says how many
  "paths": [...], "excludes": [...], "kernel": "7.3.5-arch1-1" }
```
`index.tsv`, newest first, for the rescue: `<id>\t<unix seconds>\t<reason>\t<title>`; the title is ASCII, at most 60 characters:
`Before 112 packages: linux, mesa` / `Manual` / `Before the restore of <date>`. Both are rebuilt by `reindex` from restic's own list (tags and
the record file that every snapshot carries: the record as it stood at the snapshot is written to `/var/lib/lares/snapshot-record.json` before
the backup and is part of it).

## 6. The root tool
| Verb | Who | Answer |
|---|---|---|
| `status` | anyone | one JSON object, below |
| `list` | anyone | `{ "records": [ <record without before> ] }`, newest first |
| `create [--note <text>]` | polkit `org.lares.snapshot.create`, no password for you | progress lines as in section 7, then `{ "ok", "short" }` |
| `keep <short> on|off` | polkit `org.lares.snapshot.keep`, no password | `{ "ok" }` |
| `delete <short>` | polkit `org.lares.snapshot.delete`, password or face | `{ "ok" }` (forget + prune) |
| `hook pre` / `hook done` | pacman | section 7 |
| `tidy` | `systemd-run --no-block`, root, idle CPU and I/O | 1. the prime: a backup tagged `lares-prime` (no record, not in the index, not counted in `keep`) so the next snapshot finds its data already there; 2. forget + prune (`--max-unused 20%`, so little is rewritten and uploaded again; keep newest `keep` + kept; every prime but the newest; none once a newer real snapshot exists); 3. a repository check of 5 % of the data once a month |
| `init` / `reindex` / `rescue-build` / `password` | root in a terminal | text |
| `dump <short> <path>` | root in a terminal | the file on stdout |

`status` = `{ "version": 1, "installed": true, "repo": true, "off": false, "enabled": true, "restic": "0.19.1", "count": 6, "newest": "<short>",
"repoBytes": n, "freeBytes": n, "busy": "" | "create" | "tidy" | "delete", "check": { "time", "ok", "text" } | null,
"rescue": { "built": <unix>, "kernel", "restic", "entry": true } | null, "settings": { ...in force }, "problems": [ "<text>" ] }`.
Exit status: 0 done; 1 failed; 2 usage; 3 nothing to do; 4 refused; 5 not root where root is needed.
polkit: three actions, each with the annotations `org.freedesktop.policykit.exec.path` (the tool) and `.exec.argv1` (create | keep | delete):
pkexec picks the action by both. The rule answers YES for `create` and `keep`, for you, active and local; `delete` is `auth_admin_keep`; every
other verb falls to pkexec's own action and asks an administrator. `keep` marks live in `state.json` (`restic tag` would change the id).
A create that finds another job: a tidy is told to stop; a delete or another create is waited for, 120 s.
Test options `--root <dir>` and `--restic <path>` are refused when the effective user is root.

## 7. The hook's lines (stdout, one per line, at most 25; what the shell's parser reads)
```
lares-snapshot: start 112 packages: linux, mesa, nvidia-open
lares-snapshot: progress 35
lares-snapshot: done 6a493314 added=812345678 seconds=24
lares-snapshot: skip <code> <text>       small | run | asked | off | chroot | tool | repo
lares-snapshot: failed <code> <text>     space | added | time | lock | restic | internal
lares-snapshot: notice <text>
```
- `progress` rises only, in steps of 5, at most one a second: the bytes done over the larger of restic's total and the last snapshot's.
- `failed` exits 1 (pacman: `failed to commit transaction (failed to run transaction hooks)`, nothing installed) unless `onFail` is `continue`.
- The wrapper answers `skip` itself and exits 0 when the tool, python or restic is missing or does not run, there is no repository, the
  machine is a chroot, or `/etc/lares/snapshot.off` exists. A tool that CRASHES (any exit but 0 and 1) is `skip tool` and 0: pacman is never bricked.
- The skip token: `/run/user/<uid of user>/lares/snapshot-skip`, opened without following links, a regular file owned by that uid, at most 2 h old.
  Not consumed; the shell writes it when a run starts without a snapshot and removes it when the run ends.
- Guards: free space after the transaction's own need below `minFreeGB` -> `space`; the repository grew by more than `maxAddedGB` in this snapshot (not the
  first one) -> `added`, restic is stopped, the text names the three largest new files; `maxMinutes` -> `time` (the first snapshot: 60). The prime obeys
  `minFreeGB` and `maxAddedGB` too; a prime that fails is a line in the log and nothing else.

## 8. `config/snapshots.jsonc`
```
{ "enabled": true,
  "rule": { "minPackages": 40, "critical": [...], "criticalAlso": [] },
  "keep": 5, "minFreeGB": 10, "maxAddedGB": 15, "maxMinutes": 15,
  "prime": true,
  "exclude": [],
  "onFail": "stop",
  "offsite": { "enabled": false, "folder": "/my-files/Lares snapshots", "onBattery": false, "metered": false } }
```
Clamps: minPackages 1..9999, keep 1..50, minFreeGB 1..500, maxAddedGB 1..500, maxMinutes 1..120. A wrong type = the default, and a line in
`problems`. `exclude`: absolute, normalised, below `/var/lib`, `/opt`, `/srv`, `/root` or `/usr/local`, never `/var/lib/pacman`. The root tool opens the first
candidate that exists (`jsonc.py` `candidates`) with O_NOFOLLOW, a regular file owned by you, at most 64 KB; anything else = the defaults.

## 9. Off-site
`offsite.json` = `{ "state": "off" | "idle" | "running" | "waiting" | "error", "reason": "<text>", "cause": "<word>", "lastOk": <unix> | 0, "pending": { "files", "bytes" },
"done": { "files", "bytes" }, "snapshots": [ "<short>" ], "pid": n }`. `cause` is the word a reader acts on: waiting `battery` | `metered` | `update` |
`keyring` | `busy` | `throttled` | `stopped`, error `signin`, else "". The page says what it waits for from `cause` and the battery as it IS (the file holds what was true when the copy last looked).
`lares-offsite status --json | sync [--dry] [--json] [--verify] [--allow-shrink] | remotes | fetch <dir> [--from=<machine>/<repository>] | verify | try`.
- **The place:** `<folder>/<machine>/<repository>/`, the repository as it is. `<machine>` = `offsite.machine`, else the host's name; `<repository>` = the first 8 hex digits
  of the SHA-256 of the repository's own `config` file (random, never rewritten). Two machines of one name, or a repository made anew, never share a place.
- **The second lock:** before anything is sent or removed, the `config` in the place must be this repository's (size and SHA-1) or absent; else refused (exit 4).
  Only "Node not found" means absent: any other failed listing stops the run.
- **Conditions** (else `waiting`, and no call to the CLI): mains, not metered, no update running, the login keyring OPEN (read with `busctl --auto-start=no`; a locked one
  would open a password window).
- **The CLI's shapes are recorded** (0.9.0, 2026-11-22): `fs list -j` = an array; `name` = `{ok, value}`; a file's size and SHA-1 are `activeRevision.claimedSize` and
  `.claimedDigests.sha1` (`totalStorageSize` is the encrypted size); `fs delete /trash/<name>`; a killed upload leaves nothing; "You need to login first". Not recorded: the
  words for too many requests.
- **When:** 2 min after a run that made a snapshot, else once a day; a copy that waits for the charger starts 5 s after it goes in (`SnapshotService.onBattery`); one that waits for
  anything else but a pause is asked again after 5 min, the rest after 30 min, an `error` or a `running` left standing after 3 h; opening the page asks what waits or failed again
  (at most once a minute). `SnapshotWords.offsiteDue` is the rule; exit 3 ("it waits") is no failed unit (`SuccessExitStatus=3`).

## 10. Undo
`lares-snapshot undo-plan <short> --json` = `{ "ok", "short", "files": [ { "name", "now", "to", "source": "pacman" | "yay" | "archive", "path" } ],
"missing": [ { "name", "now", "to" } ], "blockedBy": [ "<name>" ], "takenOver": [ { "name", "owner", "path" } ], "newSince": [ "<name>" ],
"removedSince": [ { "name", "to" } ] }`. `takenOver`: a package installed since owns a file an old one brings (openssl-3 took libcrypto.so.3 from
openssl) and does not conflict with it by name: pacman refuses ("conflicting files", nothing changed), so the plan says no first.
A missing package that the rule calls critical blocks the undo (`"ok": false`, `"blockedBy": [names]`): a kernel without its modules is worse than
no undo. Any other missing one is listed and left as it is. Nothing to put back is `"ok": false` with an empty `files`.
The snapshot the hook takes inside an undo run has reason `undo` (an ancestor of the hook is `lares-snapshot undo` or `update-run.sh --kind undo`) and note = the short of the snapshot undone.
`lares-snapshot undo <short>` runs on the run's PTY, as the parent of sudo (not replaced by it): `sudo [-A] pacman -U -- <files>` (the Archive's as URLs), `-A` when `SUDO_ASKPASS` is set.
The run is started as `helpers/update-run.sh --kind undo <run-dir> <command...>`; `run.json` and the marker carry `"kind": "update" | "undo"`.
Only `update` counts for last-success, the notification and the aura; the waiting list is refreshed after both.

## 11. The shell
`PackageUpdateParser`: `snapshotState` ("" | "running" | "done" | "skipped" | "failed"), `snapshotProgress` (0..1, -1 unknown), `snapshotCode`,
`snapshotText`, `snapshotShort`; all reset with the parser. A failed one adds an error of pkg `snapshot`. `subPhase` stays `L4_PREHOOKS`.
`SystemUpdatePopup`: `property var snapshots` (the service or null: no notch, no line, no page), `signal startWithoutSnapshotRequested()`.
`SystemUpdateService`: `startUpdate(withoutSnapshot)`, `startUndo(short)`, `runKind`.
`SnapshotService` (D): `live` (default false), `ready`, `status`, `rows` (newest first), `busy`, `wantsFor(names)`, `refresh()`, `create()`, `keep(short, on)`,
`remove(short)`, `planUndo(short)` -> `undoPlans[short]`, `offsite`; signal `failed(string text)`.
A row: `{ short, timeMs, title, reason, changed[], notable[], count, state, keep, addedBytes, offsite, unfinished }`.
`SnapshotsPage`: `service`, `fontFamily`, `runActive`, `naturalHeight`, `implicitWidth`; `signal undoRequested(string short)`.
