# silicon-helper — wire protocol v1 (part of the frozen contract, silicon.md §3)

Fixed by the orchestrator on 2026-10-03, before stages 2 (the helper) and 3 (the data layer) start
in parallel: stage 2 writes this, stage 3 reads it, neither changes it. A field that turns out to
be missing is asked for, not invented.

## Invocation

- Binary `/usr/local/libexec/silicon-helper` (root:root 0755). Arguments are `<command>
  [key=value ...]`; nothing else is read from the caller (no stdin, no environment but the test
  mode's, no config file of the user's).
- `status` runs UNPRIVILEGED, directly (no pkexec).
- Every write runs as `pkexec /usr/local/libexec/silicon-helper <command> ...` (polkit action
  `org.lares.silicon.helper`, granted to the user without a prompt).
- systemd-only commands (`boot-apply`, `mux-apply`, `mux-guard`) are refused (exit 2) when
  `PKEXEC_UID` is set.
- ONE JSON object on stdout, UTF-8, then a newline; diagnostics go to stderr. The caller parses
  stdout only.

### Test mode (honoured ONLY when the effective uid is not 0)

- `--sysfs-root <dir>`: every `/sys/...` path is read and written under `<dir>/sys/...` (the
  fixtures in `helpers/silicon_helper/tests/fixtures/<name>/sys/...`). `--proc-root <dir>`: the
  same for `/proc` (boot id at `proc/sys/kernel/random/boot_id`, modules at `proc/modules`).
  `--state-dir <dir>`: instead of `/var/lib/silicon`. `--dev-root <dir>`: for `/dev` lookups.
  `--modules-root <dir>`: instead of `/usr/lib/modules` (the DKMS pre-check). `--run-root <dir>`: for
  `/run` -- `<dir>/run/systemd/units/` (or `<dir>` itself as the run directory) is where the
  `silicon-mux.service` check looks (see `prechecks` below). OPTIONAL, and without it the unit is not looked
  for at all in test mode (a probe that predates the option behaves as it always did).
- `SILICON_TEST_FAULTS=<knob>:<fault>[,...]`: `eio` (the write fails with EIO), `ignore` (the write
  succeeds, the value does not change), `clamp:<value>` (the kernel stores `<value>` instead).
  Knob names are the result `knob`s below, plus `mux`.
- `SILICON_TEST_REBOOT=<file>`: a reboot appends a line to `<file>` instead of rebooting.
- In test mode `mux-apply` brings the stack down against the proc root, and nothing is executed: the
  stack "comes down" unless `<proc-root>/proc/modules` shows an NVIDIA module with references from
  outside the stack (an `nvidia_drm` line with a refcount above its dependents) or one that a non-NVIDIA
  module depends on, or a `<proc-root>/proc/<pid>/fd/<n>` link points at a node of the dev root
  (`dev/nvidia0`, `dev/dri/...`), in which case the dGPU direction records `failed` after its (short)
  drain and the way back is written regardless.
- As root, ANY of these (option or variable) → exit 4, nothing read or written.
- In test mode every path the helper REPORTS (`status.paths`) is the real-looking path under the
  test root, so a caller can read it as it would the real one.

### What reads the NVIDIA driver

`status.paths.dgpu.nvidia` (the card's `/dev/nvidiaN`) comes from the driver's own proc entry,
`/proc/driver/nvidia/gpus/<pci>/information` ("Device Minor"). That read goes through the driver's locks,
so a wedged driver can block it for good. It is made by the `status` command and by the answer to a command
the shell runs (pkexec: its status replaces the shell's own copy, `paths` included) -- and by NOTHING that
writes: `apply`, `set-charge-limit`, `set-boot`, `mux-request`, `mux-apply`'s write, the guard's revert and
withdrawal and `boot-apply` look at the machine without it. The answers of systemd's own commands
(`record-caps`, `boot-apply`, `mux-apply`, `mux-guard`, which only reach the journal) read it not at all:
their `status.paths.dgpu.nvidia` is `null`.

## Exit codes

0 everything asked was done and read back · 1 a write failed or read back wrong (others may have
succeeded: see `results`) · 2 refused: nothing was written (bad argument, a value outside the
kernel's list or a range, a systemd-only command under pkexec, a knob that is absent) · 3 I/O
before any write (status unreadable) · 4 test mode as root.

## `status`

```jsonc
{
  "ok": true,
  "proto": 1,
  "status": {
    "features": {              // false = the knob is absent on this kernel: the shell hides it
      "profile": true, "epp": true, "turbo": true, "governor": true, "maxPerfPct": true,
      "caps": true,            // RAPL writable AND the firmware's ceiling recorded (limits.capCeilW)
      "chargeLimit": true, "mux": true
    },
    "values": {
      "profile": "quiet",      // the kernel's name; null when absent
      "epp": "power",          // the same on every policy, else "mixed"; null when absent
      "turbo": false,          // = !intel_pstate/no_turbo
      "governor": "powersave", // the same on every policy, else "mixed"
      "maxPerfPct": 100,
      "caps": {                // watts, from constraint_0 (PL1, long_term) and constraint_1 (PL2, short_term)
        "pl1W": 45, "pl2W": 115,                       // effective: the lower of the zones present
        "zones": { "msr": { "pl1W": 65, "pl2W": 115 }, "mmio": { "pl1W": 45, "pl2W": 115 } }
      },                                               // a zone that is absent is null
      "chargeLimit": 80,       // charge_control_end_threshold as read (any integer)
      "muxStored": "hybrid"    // gpu_mux_mode: 1 "hybrid", 0 "dgpu" -- the firmware's STORED setting
    },
    "lists": {                 // always the kernel's own lists, in the kernel's order
      "profiles": ["quiet", "balanced", "performance"],          // minus "custom"
      "epps": ["performance", "balance_performance", "balance_power", "power"],   // minus "default"
      "governors": ["performance", "powersave"]
    },
    "limits": {
      "capFloorW": 8,
      "capCeilW": { "pl1": 45, "pl2": 115 },   // the firmware's effective values recorded at boot,
                                               // before anything was written; null = not recorded
                                               // in this boot yet (caps then are NOT writable)
      "maxPerfPct": { "min": 9, "max": 100 },  // min = intel_pstate/min_perf_pct
      "eppLocked": false                       // true while the governor is performance (EPP fixed)
    },
    "paths": {                 // where the shell's own readers look; null when absent
      "dgpu": { "pci": "0000:01:00.0", "card": "/dev/dri/card0", "render": "/dev/dri/renderD128",
                "nvidia": "/dev/nvidia0", "powerState": "/sys/bus/pci/devices/0000:01:00.0/power_state" },
      "battery": "/sys/class/power_supply/BAT0",
      "ac": "/sys/class/power_supply/AC0",
      "coretemp": "/sys/class/hwmon/hwmon6",   // the hwmon whose `name` is coretemp
      "rc6": "/sys/class/drm/card1/gt/gt0/rc6_residency_ms",   // the i915 card's
      "cpufreq": "/sys/devices/system/cpu/cpufreq"             // policyN/ live here
    },
    "prechecks": {
      "mux": { "ok": true, "why": "" }   // what a request for dgpu would meet: nvidia loaded, a DKMS-built
                                         // nvidia module for EVERY installed kernel, AND silicon-mux.service
                                         // active (it writes a queued change at shutdown: a change queued
                                         // while it is not would never be written); `why` names what is
                                         // missing, "; "-joined
    },
    "mux": {
      "stored": "hybrid",                // = values.muxStored
      "wiringNow": "hybrid",             // from which eDP connector is connected (Intel card =
                                         // hybrid, NVIDIA card = dgpu); null if neither reads
      "record": null                     // or the record below
    },
    "boot": { "id": "4d0c...", "applied": true }   // boot_id; silicon-boot ran in this boot
  }
}
```

The MUX record (`/var/lib/silicon/mux.json`, also `status.mux.record`):

```jsonc
{ "want": "dgpu", "from": "hybrid",
  "state": "queued",          // queued -> applied (written at shutdown) -> awaiting-keep (the new
                              // boot, dgpu only) -> kept | reverted; also cancelled, failed
  "why": "",                  // for failed / reverted: plain words. For `applied`: empty, except a way back
                              // written with NVIDIA modules loaded: "written with the NVIDIA driver still
                              // loaded (<modules>): the way back does not wait for the stack"
  "requestedAtMs": 1759500000000, "bootId": "<the boot it was requested in>",
  "deadlineMs": null,         // awaiting-keep: the hard deadline as WALL-CLOCK ms (boot + 5 min,
                              // or prompt-shown + 120 s, whichever is first) -- for the shell's
                              // countdown only
  "deadlineBootId": null,     // awaiting-keep: the boot the guard's own deadline counts in, and
  "deadlineUptimeMs": null }  // that deadline as ms SINCE BOOT -- what the guard decides on (a
                              // wall clock steps at boot when NTP corrects it; time since boot
                              // does not). A record still awaiting-keep in ANOTHER boot is past
                              // its deadline: the guard reverts at once.
```

The shell's "reverting in m:ss" counts down from `deadlineUptimeMs` minus its own `/proc/uptime`
when `deadlineBootId` equals `status.boot.id` (the guard's own clock, so the two agree); `deadlineMs`
is the fallback for display only. The three deadline fields are null in every state but
awaiting-keep, and a record in the older shape (no pair) still reads.

## Writes

Every write command answers:

```jsonc
{ "ok": false,
  "results": [
    { "knob": "profile", "want": "performance", "got": "performance", "ok": true, "code": "ok", "why": "" },
    { "knob": "pl1W", "want": 60, "got": null, "ok": false, "code": "refused",
      "why": "above the firmware's 45 W" }
  ],
  "status": { ...the status object, read after the writes... } }
```

`knob` ∈ `profile epp turbo governor maxPerfPct pl1W pl2W chargeLimit mux`. `code` ∈ `ok` ·
`refused` (validation; nothing was written by this call) · `absent` (the knob does not exist here:
refused) · `locked` (EPP under the performance governor: refused) · `io` (the write failed) ·
`mismatch` (written, but the read-back differs: `got` is what the kernel holds). `why` is plain
words a caption can show. EVERY argument is validated before ANYTHING is written; one refusal
refuses the whole call (exit 2, every result `refused` or the offending code, nothing written).

- `apply [profile=<name>] [epp=<name>] [turbo=0|1] [governor=<name>] [max_perf_pct=<int>]
  [pl1_w=<W>|firmware] [pl2_w=<W>|firmware]` — any subset, applied in this order: profile →
  governor → EPP → turbo → max_perf_pct → caps. Names from `status.lists` only (never `custom`,
  never `default`); `max_perf_pct` within `limits.maxPerfPct`; caps: `capFloorW <= W <= capCeilW`
  for that PL, PL1 <= PL2 after the call, written to EVERY RAPL zone present (MSR and MMIO), PL4
  never; `firmware` = the recorded ceiling. EPP with the resulting governor `performance` →
  `locked`. A failed write does not stop the later knobs; each is read back.
- `set-charge-limit 80|100` — `chargeLimit`; also stored for the next boot.
- `set-boot <the apply arguments>` — validated as `apply` would (without writing them now) and
  stored as what `boot-apply` applies (`/var/lib/silicon/boot.json`). Answers results with code
  `ok` and `got` = the stored value.
- `mux-request dgpu|hybrid` — pre-checks, then writes the record `queued`. The NVIDIA stack's checks
  apply to dgpu only; **`silicon-mux.service` being active applies to both directions** (refused, exit 2,
  `why` = `prechecks.mux.why`: "silicon-mux.service is not active, so a GPU mode change queued now would
  never be written at shutdown (sudo systemctl start silicon-mux.service)"). The unit is judged by the link
  systemd keeps for an active unit, `/run/systemd/units/invocation:silicon-mux.service` (one `lstat`, no
  process, cheap enough for every `status`): systemd exports it while a unit is active and removes it when it
  goes inactive or failed -- and calls the files an implementation detail, so the check FAILS OPEN: when no
  unit at all has such a link (another systemd, a container) it cannot tell and refuses nothing. NOTHING is
  written to the firmware here. A request equal to the wiring now clears a queued record instead (state
  `cancelled`), and `mux-cancel` -- undoing needs no unit.
- `mux-cancel` — a `queued` record → `cancelled`.
- `mux-prompt-shown` — in `awaiting-keep`: both deadlines become min(deadline, now + 120 s), each
  on its own clock.
- `mux-confirm` — in `awaiting-keep`: → `kept`.

systemd-only (refused under pkexec):
- `record-caps`: records the firmware's caps for this boot (`/var/lib/silicon/firmware_caps.json`
  = `{bootId, msr, mmio}`), only if its bootId is not this boot's -- a later run never records
  values something lowered. Nothing else. (`install.sh` runs this, so a re-install mid-session
  never re-applies the boot set.)
- `boot-apply` (silicon-boot.service, early): FIRST `record-caps`, then applies `boot.json` and
  the stored charge limit; retries while knobs are not there yet (up to 30 s).
- `mux-apply` (silicon-mux.service's ExecStop, at shutdown): a `queued` record only, and only while
  systemd says the system is stopping (else refused, exit 2, record untouched). **The stack rule is by
  direction:**
  - `want: dgpu` (the switch TO dGPU-only; its pre-checks must still pass): waits for the dGPU's users
    to drain (bounded), stops nvidia-powerd / nvidia-persistenced, unloads the NVIDIA modules; if any of
    that fails the write is NOT made (record `failed`, `why` says what held; exit 1; the user is still on
    hybrid, and a failed record is terminal: a new request is needed); else it writes.
  - `want: hybrid` (the way back from dGPU-only, or the undo of a dgpu switch before its reboot): **no
    teardown, no waiting, no condition on the stack** -- the write is the first thing after validation.
    After a dGPU-only boot the console runs on the NVIDIA card and `nvidia_drm` may refuse to unload, and
    staying stuck in dGPU-only is the unsafe outcome; the teardown is also the part of the helper most
    tied to the driver and kernel version, so the user's way out does not depend on it. If NVIDIA modules
    are loaded at that moment, the record's `why`, the result's `why` (`code` stays `ok`, exit 0) and a
    stderr line all say `written with the NVIDIA driver still loaded (<modules>): the way back does not
    wait for the stack`; with no driver loaded `why` is empty. (`mux-guard`'s revert writes hybrid the
    same way.)
  Either way the write is the same one: `gpu_mux_mode` (asus-armoury's `current_value` when present, the
  legacy asus-nb-wmi file otherwise) through the one door (canonical path on the whitelist, the kernel's
  own value `1` hybrid / `0` dgpu, everything validated before anything is written), read back; record →
  `applied`. A write that fails or reads back wrong is `failed` (`io` / `mismatch`).
- `mux-guard` (silicon-mux-guard.service, on boot): an `applied` record in a NEW boot: wiring is
  `want` → `awaiting-keep` with deadline = boot + 5 min (dgpu) or `kept` at once (hybrid); wiring
  not `want` → `failed`: a switch to dgpu that did not take puts hybrid back in the firmware (the pending
  dGPU setting is withdrawn); **a way back that did not take (wanted hybrid, the panel still on the NVIDIA card)
  writes nothing** -- `why` says "...wired to dgpu after the reboot (wanted hybrid); the firmware setting was
  left as it is". The helper never writes the dGPU value at boot: only `mux-apply`, at shutdown, for a request
  the user made, with the pre-checks passed and the stack down, and then the confirmation window below. In
  `awaiting-keep` it waits for `kept` or the deadline (time since boot,
  `deadlineUptimeMs`; a record from another boot is past it); at the deadline it
  writes hybrid (1) at once, record → `reverted`, and reboots — once per record (the record's
  state is written BEFORE the reboot is asked for).

State files are written atomically (temp file in the same directory + fsync + rename + fsync of
the directory) under one lock (`/var/lib/silicon/.lock`, flock).
