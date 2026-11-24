# snapshots -- system snapshots, undo and the rescue

## What it is
Before a large or important update, pacman's hook takes a snapshot of the system files: `/usr`, `/opt`, `/etc`, `/srv`, `/root`, `/var/lib`
and the files directly in `/boot`. Nothing of `/home` is in it. The snapshot goes into an encrypted restic repository at
`/.lares-snapshots` on the same disk. It gives you three things: a list of snapshots in the update popup, an Undo that puts the old
package files back with `pacman -U`, and a rescue entry in the GRUB menu that restores a whole snapshot before the system starts, so it
works when the system does not.
A copy of the repository on Proton Drive is optional. The contract (fixed names and formats) is
[contracts/snapshots.md](contracts/snapshots.md).

## Where it lives
- Update popup: a Snapshot notch on the phase rail in a run that takes one, a progress figure on the card while it is taken, a line
  "Snapshot 3 h ago" (or "No snapshot yet") under the idle card, and the snapshots page, which the line opens as the popup's side page.
- Root part, installed once: `/usr/local/lib/lares/snapshot/` (the tool, its rules and defaults), `/etc/pacman.d/hooks/00-lares-snapshot.hook`
  and `zz-lares-snapshot-done.hook`, the polkit action and rule, `/etc/grub.d/45_lares_rescue`, the rescue image in `/boot/lares/`.
- Your part: `lares snapshot ...` (`tools/snapshot/lares-snapshot`) and `lares snapshot offsite ...` (`tools/snapshot/lares-offsite`).
- Data: `/.lares-snapshots/` (repository, password, records, log). It is outside every path a snapshot covers, so a restore cannot reach it.
- Settings: `config/snapshots.jsonc` (example `.examples/snapshots.jsonc`).
- Mockup: `mockups/snapshots.qml`. Code: `modules/bar/system_update/snapshots/`.

## What you can do
- Read the snapshots page: when, what it was for ("Before 112 packages", "Manual", "Before undoing an update"), the notable packages that
  changed, how much it added, whether it is kept and whether it is on Proton Drive. "Snapshot now" takes one.
- Keep a snapshot past the automatic cleanup (no password), delete one (asks for your password or face; a kept one is released first).
- Undo an update: the row says what can be put back ("All 12 packages can be put back", or how many old versions are gone). It runs
  in the update run's terminal view as `pacman -U` of the old files from the pacman cache, else from the Arch Linux Archive. A snapshot is
  taken first, as the undo's own safety. An old kernel that is gone blocks the undo; any other missing package is left as it is.
  Undo only changes packages. Settings you changed in `/etc` since stay.
- When the snapshot cannot be taken the update stops with nothing installed, and the card says why ("No snapshot, so nothing was
  installed": not enough disk space, the snapshot would grow far too large, it took too long, another snapshot is running, or it
  failed). "Update without it" runs the update once without a snapshot. Setting `"onFail": "continue"` makes that the default.
- From a terminal: `lares snapshot status | list | show <short> | create [--note T] | keep <short> on|off | delete <short> | undo-plan <short> |
  files <short> | undo <short> [--print] | rescue status`.

## What it does by itself
- The rule: a snapshot when an update brings at least `minPackages` (40) packages, or one of the critical ones (kernels, firmware, graphics
  driver, glibc, systemd, grub, pacman, hyprland, quickshell, python and so on; the list is in the contract). One per run, however many
  transactions the run has. Removing packages alone never asks for one.
- After the update, in the background and at idle priority, the "prime": it writes what the update brought, so the snapshot before the
  next update only compares (about 22 seconds here). The same job deletes snapshots past `keep` and checks 5 % of the data once a month.
- With the Proton copy on, it uploads after an update and once a day (not on battery or a metered link unless you allow it, and never while
  the keyring is locked: a face unlock does not open it, your password does). A copy that waits for the charger starts when it
  goes in; one that waits for something else is asked again every few minutes, and when you open the page.

## Settings (`config/snapshots.jsonc`)

`offsite.everyHours` (24) is how often the Proton copy runs at most, `offsite.afterUpdate` (true) whether an update's new snapshot starts one.
| Key | Default | What it does |
|---|---|---|
| `enabled` | true | false: no update makes a snapshot; `lares snapshot create` still works |
| `rule.minPackages` | 40 | an update with this many packages or more makes one (1 to 9999) |
| `rule.critical` / `rule.criticalAlso` | built-in list | package names that always make one (`*` matches text); `criticalAlso` adds to the list |
| `keep` | 5 | newest snapshots kept (1 to 50), on top of the ones you marked |
| `minFreeGB` | 10 | the update stops when a snapshot would leave less free space (1 to 500) |
| `maxAddedGB` | 15 | a snapshot that adds more is stopped (1 to 500); the first one is never limited this way |
| `maxMinutes` | 15 | a snapshot that takes longer is stopped (1 to 120); the first one gets 60 |
| `prime` | true | the background write after an update |
| `exclude` | [] | more folders to leave out, in full, below `/var/lib`, `/opt`, `/srv`, `/root` or `/usr/local` |
| `onFail` | "stop" | "stop": a failed snapshot stops the update; "continue": the update goes on |
| `offsite.enabled` | false | the copy on Proton Drive |
| `offsite.folder` | "/my-files/Lares snapshots" | where on Proton Drive; every machine has a folder of its own in it |
| `offsite.machine` | the host's name | this machine's folder |
| `offsite.onBattery`, `offsite.metered` | false | also copy on battery, on a metered link |
A wrong value falls back to its default and is listed under `problems` in `lares snapshot status`. The root tool reads the file only when
it is a regular file of yours, under 64 KB.

## Setting it up
`lares setup` shows the row "R5 system snapshots" and prints the step. In short, in a terminal:
1. `sudo <deployed snapshot>/tools/snapshot/root/install.sh`. It lists every change and waits for `yes`. It installs restic, the tool, the
   polkit rule, the repository, the rescue image with its GRUB entry (it runs `grub-mkconfig` itself) and, last, the pacman hooks.
2. It shows the repository password once. Put it in your password manager now. Without it the snapshots cannot be read from another disk.
3. `lares snapshot create`. The first one takes about 9 minutes on this laptop's disk.
4. `lares snapshot rescue status` must say the image is built. Boot the rescue once to see it (below).
5. Optional: the Proton Drive copy (below).
6. Last, after one real update has made a snapshot: remove Timeshift if you have it (`lares setup` prints the three commands, marked
   irreversible: `sudo timeshift --delete-all`, `sudo rm -rf /timeshift`, `sudo pacman -Rns timeshift`).

## How to undo it
`sudo <deployed snapshot>/tools/snapshot/root/uninstall.sh` takes the hooks out first, then the rule, the tool and the rescue. Pacman is
as it was. Your snapshots stay in `/.lares-snapshots`; delete them for good with `sudo rm -rf /.lares-snapshots`. To switch snapshots off
without uninstalling: `"enabled": false`. To let one update through if the tool misbehaves: `sudo touch /etc/lares/snapshot.off` (the
hook then does nothing), and remove the file afterwards. The hook also lets pacman through by itself when the tool, python or restic is
missing or crashes, so it cannot stop the update that would repair it.

## How to rescue (the system does not start, or an update broke it)
1. Restart. GRUB shows its menu for 1 second on this machine: press an arrow key as soon as it appears, so it stays.
2. Choose "Lares rescue". It starts a small system from `/boot/lares/` with its own programs; nothing of the broken system is used.
3. It lists the snapshots, newest first: date, what it was for, title. Use the arrow keys and Enter. It also answers on the serial port.
4. It checks the root file system and mounts it read-only, then shows what a restore would change (it plans first, a dot every two
   seconds while it works). A swap partition that holds a hibernation image stops the restore until you type `discard`, because
   writing the system under a hibernation image and resuming would corrupt it.
5. Type `yes` to restore. It takes a safety snapshot of the present state first (reason "rescue"; if it cannot, you decide with `go on`),
   then restores `/usr`, `/etc` and the others, and `/boot`'s files last, each written beside the old one, checked and then renamed.
6. Restart. `/etc/fstab`, `/etc/crypttab`, the snapshot tool, its hooks, its rescue entry and `/etc/lares` are kept as they are now.
   `/boot/grub` and the EFI folder are never touched.
Everything since the snapshot is gone from the covered folders, including packages installed since. `/home` is untouched.

## How to restore from Proton Drive onto a new disk
Nothing here is automated, and the Proton copy has not been restored onto a blank disk by any test in this repository. The steps rest on
restic's own commands. You need the repository password.
1. Boot an Arch live system on the new machine or disk, partition and format it, mount the root at `/mnt` and the boot partition
   where your system has it (`/mnt/boot`).
2. Get the copy: on any machine with `lares` and `proton-drive`, `lares snapshot offsite remotes` lists the copies (machine and repository), and
   `lares snapshot offsite fetch <empty folder> --from=<machine>/<repository>` downloads one and checks every file against its own SHA-256 name, then prints "0 wrong, 0 missing" or lists what is wrong. Copy the folder to the live system (or
   fetch it there from a clone of the repo).
3. `pacman -S restic`, then `restic -r <folder> --password-file <file with the password> snapshots`, and
   `restic -r <folder> --password-file <file> restore <id> --target /mnt` for the snapshot you want.
4. Make the new disk bootable: `genfstab -U /mnt > /mnt/etc/fstab` (the old one points at the old disk), then `arch-chroot /mnt`, `mkinitcpio -P`,
   `grub-install ...` for your layout and `grub-mkconfig -o /boot/grub/grub.cfg`. `/boot/grub` and the EFI folder are not in a snapshot.
5. Your files in `/home` come from your own backup; they are not in these snapshots.

## The Proton Drive copy
- `proton-drive auth login`, then `lares snapshot offsite try`: a recording of what the `proton-drive` command really does here, for you to run once in a terminal
  (`tools/dev/proton_cli_try.sh`). It works in one new folder on Proton Drive and removes it at the end. Never part of a test tier.
- Then `"offsite": { "enabled": true }` in `config/snapshots.jsonc`.
- `lares snapshot offsite status | sync [--dry] | verify | remotes | fetch <dir>`. What is uploaded is ciphertext: restic's files as they are, in
  `<folder>/<machine>/<repository>/`. Each machine has its own folder, and each repository its own folder in that (eight digits of the
  repository's config file), so a laptop and a desktop never meet, not even with one name. A folder that holds another repository is refused. The repository password is never read by this part. It uploads data before the snapshot files that need it, and it
  refuses a deletion that looks like a mistake (exit 4; `--allow-shrink` after you looked).
- The page shows "Proton Drive: up to date, 2 h ago", the progress while copying, what it waits for, or what is wrong. A copy that went on
  battery in the middle stops after the files it is sending and goes on from there later.

## Limits
- The disk decides the time. Before its first TRIM this laptop's SSD (88 % full) wrote about 228 MB/s for the first GB and then 30 MB/s; after
  it (2026-11-22, 116 GiB trimmed in 201 s) the same test wrote 0.7 to 2.4 GB/s over 6 GB. The figures below are from before
  (measured 2026-11-22), so the first 12 GB snapshot took 8 min 34 s; reading and comparing 599 000 files takes 22 s. Lowering the
  priority did not help (8 min 42 s). That missing TRIM is the cause is not proven; `lares setup` says when `fstrim.timer` is off.
- The snapshots are on the disk they protect. A dead disk takes them along; that is what the Proton copy is for.
- Snapshots hold system files, not `/home`, and not the excluded folders (`/var/lib/ollama`, docker, libvirt images, flatpak's repo, the pacman sync
  database, caches).
- The first snapshot has to be made by you; the hook makes the later ones.
- The Undo needs the old package files in the pacman cache or the Arch Linux Archive.
- A restore is one direction: back to the snapshot. A snapshot of the state before the restore is taken first.

## How it is built
| Path | Role |
|---|---|
| `tools/snapshot/root/` | the root tool (`lares-snapshot-root`), the hook wrapper, the pacman hooks, polkit action and rule, `install.sh`, `uninstall.sh`, `snaprules.py` (the rule) |
| `tools/snapshot/root/rescue/` | the rescue: `rescue.sh`, `build`, the GRUB fragment, the protect and exclude lists |
| `tools/snapshot/lares-snapshot`, `lares-offsite` | your CLI (undo plan, undo run) and the Proton copy |
| `modules/bar/system_update/snapshots/` | `SnapshotService` (once per shell), `SnapshotsPage`, `SnapshotRow`, `SnapshotRules.js` (the rule's twin), `SnapshotWords.js` |
| `modules/bar/system_update/components/PackageUpdateParser.qml` | reads the hook's `lares-snapshot:` lines (state, progress, code) |

## How to change it, and the checks after a change
- The rule or the critical list: `tools/snapshot/root/snaprules.py` and `SnapshotRules.js` together, held to one table
  `tools/dev/snapshot_rule_cases.json` (`python3 tools/dev/snapshot_cases.py`).
- The root tool or the hook: `tools/dev/snapshot_restic_probe.sh`, `snapshot_install_probe.sh` (the installer and uninstaller on a fake root).
- The rescue: `tools/dev/snapshot_rescue_probe.sh`; the whole path in a VM, `tools/dev/snapshot_vm.sh` (needs KVM and a prepared work folder).
- The Proton copy: `python3 tools/dev/snapshot_offsite_cases.py`.
- The popup: `tools/dev/su_snapshot_probe.sh`, `su_snapnull_sheet.sh`, `snapshot_ui_probe.sh`, `snapshot_engine_probe.sh`; `tools/dev/smoke.sh mockups/snapshots.qml`.
- `lares setup`'s rows: `tools/dev/snapshot_setup_probe.sh`.
