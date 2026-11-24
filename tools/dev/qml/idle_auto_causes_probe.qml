pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io

import "modules/shell"
import "modules/idle"
import "modules/idle/ContentRules.js" as CRules
import "modules/idle/IdleConfig.js" as ICfg
import "modules/notifications/data"
import "modules/common/system"
import "modules/common/system/DownloadRules.js" as DlRules
import "modules/common/system/PackageJobRules.js" as PkRules

// tools/dev/qml/idle_auto_causes_probe.qml -- the idle auto layer's three newer causes on the shell's MOCK services (tools/dev/idle_auto_causes_probe.sh
// runs it in a sandbox copy with private XDG dirs; the sandbox's DL_DIR is the download folder, never the user's):
//
//   the share      ScreenShareWatch (ONE per shell) -> the toasts' holds AND IdleAuto: a shared screen raises NORMAL, and outranks the soft causes
//   the wiki batch the mock wiki's batch (`batch.running`) raises SOFT
//   the download   DownloadRules on a pinned clock (119 s no, 121 s yes, a stall resets the age, a finish before 2 min never counts), then
//                  DownloadWatch against REAL files growing, renamed, stalling in DL_DIR with the 2 minutes shortened to 800 ms: raises SOFT (the folder is `dir`; a second watcher
//                  resolves it through `xdg-user-dir`, whose user-dirs.dirs the runner made private)
//   the package job PackageJobRules on a pinned clock and synthetic process records (an AUR build with no lock counts, checkupdates' copy and
//                  `yay -Qua` never do, the shell's own update is own), the table of cases shared with lares's restart guard, then
//                  PackageJobWatch (pkgjobs.py) against a FAKE /proc and a fake lock file in PK_DIR with the 2 minutes shortened to 800 ms: raises
//                  SOFT with the command line's words, and the shell's own update keeps its own cause and words (no second one)
//   the ignore list  ContentHold (modules/idle) on STUB sources in CH_DIR (a `tail -F` of fake dbus-monitor lines, a file for `hyprctl -j clients`, one
//                  for logind's ListInhibitors): idle.jsonc `contentIgnore` (FreeRDP's SDL client by default) sets a holder aside in all three sources,
//                  by exact name in any case (an SDL game still holds), read hot (IdleConfig.apply), and each ignored name is said once in the log
//   each cause     raises its mode only after the on debounce, drops only after the off one, and names itself (autoReason: the words the idle reel shows beside its strip, ReelReason)
//
// ShellServices in mock mode is the whole wiring (the Bindings of ShellServices.qml); nothing is held, nothing of the desktop is read.
// Prints `ICAUSE ok|FAIL <check>` and `ICAUSE RESULT PASS|FAIL (<n>/<n> checks)`.
Window {
    id: win
    visible: true
    width: 80
    height: 40

    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        win.checks++;
        if (!ok)
            win.fails++;
        console.log("ICAUSE " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    readonly property string dl: Quickshell.env("DL_DIR") || ""
    readonly property string pk: Quickshell.env("PK_DIR") || ""
    FileView {
        id: casesFile
        path: Quickshell.env("CASES") || ""
        blockLoading: true
        printErrors: false
    }

    ShellServices {
        id: services
        mode: "mock"
        windowless: true
    }
    readonly property var idle: services.idle
    readonly property var share: services.shareWatch

    // The toasts' own holds with no shell to hand it a watcher: it holds its own.
    NotificationHolds {
        id: ownHolds
        liveSignals: false
    }

    // The folder, resolved by xdg-user-dir (the runner's private user-dirs.dirs).
    DownloadWatch {
        id: viaXdg
        watch: win.dl !== ""
        minAgeMs: 800
    }

    property int opsExit: -1
    Process {
        id: ops
        onExited: code => win.opsExit = code
    }
    Process {
        id: writer
    }
    function sh(p: var, script: string): void {
        p.command = ["sh", "-c", script, "sh", win.dl];
        p.running = true;
    }

    property double t0: 0
    property int idx: -1
    property var cur: null
    function sinceStart(): double {
        return Date.now() - win.t0;
    }

    // DownloadRules on a pinned clock: the 2-minute age (DownloadWatch.minAgeMs' default), no files, no waiting.
    readonly property int stallMs: 10000
    readonly property int minAge: 120000
    // a write every second from t0 for `secs` seconds; returns the state
    function _run(name: string, t0: double, secs: int, st: var): var {
        const state = st || DlRules.newState();
        for (let t = 0; t <= secs; t += 1)
            DlRules.apply(state, "MODIFY " + name + ".part", t0 + t * 1000, win.stallMs);
        return state;
    }
    function _ruleChecks(): void {
        const T = 1000000;
        let st = win._run("big.iso", T, 119);
        win.check("a download that grew 119 s does not count", DlRules.growing(st, T + 119000, win.stallMs, win.minAge).length === 0, JSON.stringify(DlRules.growing(st, T + 120000, win.stallMs, win.minAge)));
        st = win._run("big.iso", T, 121);
        win.check("a download that grew 121 s counts", DlRules.growing(st, T + 121000, win.stallMs, win.minAge).join() === "big.iso", "");
        win.check("... and the next change is due when it stalls", Math.abs(DlRules.untilChange(st, T + 121000, win.stallMs, win.minAge) - 10000) < 1, String(DlRules.untilChange(st, T + 122000, win.stallMs, win.minAge)));
        win.check("a young download's next change is the instant it comes of age", Math.abs(DlRules.untilChange(win._run("y.iso", T, 60), T + 60000, win.stallMs, win.minAge) - 60000) < 1, "");
        // a stall of 12 s at 100 s resets the age: 100 s + the second run's 30 s never makes 2 minutes
        st = win._run("res.iso", T, 100);
        win._run("res.iso", T + 112000, 30, st);
        win.check("a stall resets the age (a resumed download starts its 2 minutes again)", DlRules.growing(st, T + 142000, win.stallMs, win.minAge).length === 0, JSON.stringify(st));
        win.check("... and the resumed one counts after its own 2 minutes", DlRules.growing(win._run("res.iso", T + 112000, 125, st), T + 112000 + 125000, win.stallMs, win.minAge).join() === "res.iso", "");
        // finished (renamed) at 90 s: nothing counts, ever
        st = win._run("fin.iso", T, 90);
        DlRules.apply(st, "MOVED_FROM fin.iso.part", T + 91000, win.stallMs);
        win.check("a download finished before 2 minutes never holds", DlRules.growing(st, T + 91000, win.stallMs, win.minAge).length === 0 && DlRules.untilChange(st, T + 91000, win.stallMs, win.minAge) === 0, "");
    }

    // ---- the ignore list's rules (pure) ------------------------------------------------------------------------------------
    function _ignoreRuleChecks(): void {
        const L = ["sdl-freerdp3", "Foo"];
        win.check("ContentRules.ignores: exact, trimmed, any case", CRules.ignores(L, "SDL-FreeRDP3") && CRules.ignores(L, " foo ") && !CRules.ignores(L, "sdl") && !CRules.ignores(L, "sdl-freerdp3-x") && !CRules.ignores(L, ""), "");
        win.check("ContentRules.sift splits in the order given", JSON.stringify(CRules.sift(L, ["a", "FOO", "b"])) === '{"kept":["a","b"],"ignored":["FOO"]}', JSON.stringify(CRules.sift(L, ["a", "FOO", "b"])));
        win.check("IdleConfig: the default list is FreeRDP's SDL client", ICfg.parse({}, "/h").contentIgnore.indexOf("sdl-freerdp3") >= 0, JSON.stringify(ICfg.parse({}, "/h").contentIgnore));
        win.check("IdleConfig: ...and KDE Connect's daemon (a connected phone is no content)", ICfg.parse({}, "/h").contentIgnore.indexOf("org.kdeconnect.daemon") >= 0, JSON.stringify(ICfg.parse({}, "/h").contentIgnore));
        win.check("IdleConfig: a list of the wrong kind is the default, an empty list is a list, non-strings and blanks drop",
            ICfg.parse({ contentIgnore: "x" }, "/h").contentIgnore.length === ICfg.parse({}, "/h").contentIgnore.length && ICfg.parse({ contentIgnore: [] }, "/h").contentIgnore.length === 0
            && ICfg.parse({ contentIgnore: [" a ", 3, "", null, "b"] }, "/h").contentIgnore.join() === "a,b", "");
    }

    // ---- the package jobs' rules ---------------------------------------------------------------------------------------
    function _pr(pid: int, comm: string, argv: var, chain: var, cwd: var): var {
        return { pid: pid, comm: comm, argv: argv, chain: chain, cwd: cwd || null };
    }
    function _words(list: var): string {
        return list.map(j => j.what + (j.own ? " [own]" : "")).join(" | ");
    }
    function _pkgRuleChecks(): void {
        // the table shared with lares's pm_args_transact (the runner holds the bash function to the same lines)
        const lines = String(casesFile.text()).split("\n");
        let n = 0;
        const bad = [];
        for (const ln of lines) {
            if (ln === "" || ln.charAt(0) === "#")
                continue;
            const tab = ln.indexOf("\t");
            const want = ln.substring(0, tab) === "yes";
            const args = ln.substring(tab + 1).split(" ").filter(a => a !== "");
            n++;
            if (PkRules.transacts(args) !== want)
                bad.push((want ? "yes " : "no ") + args.join(" "));
        }
        win.check("the table of cases (shared with lares): the JS port agrees on all " + n + " lines", n > 30 && bad.length === 0, n + " cases; wrong: " + bad.join(" ; "));

        const aur = { lock: false, others: false, procs: [
            win._pr(500, "yay", ["yay", "-S", "foo"], [400]),
            win._pr(501, "makepkg", ["/usr/bin/bash", "/usr/bin/makepkg", "-f"], [500, 400], "/home/u/.cache/yay/foo")] };
        let j = PkRules.jobs(aur, [], false);
        win.check("an AUR build with no lock is ONE job, in the command's words", j.length === 1 && j[0].what === "Building foo (yay)" && !j[0].own, win._words(j));
        j = PkRules.jobs({ lock: false, others: false, procs: [win._pr(500, "yay", ["yay", "-S", "foo"], [400])] }, [], false);
        win.check("yay downloading and at its prompts (no makepkg yet) is a job: Installing foo (yay)", j.length === 1 && j[0].what === "Installing foo (yay)", win._words(j));
        const w = (comm, argv) => PkRules.jobs({ lock: true, others: false, procs: [win._pr(700, comm, argv, [1000])] }, [], false).map(x => x.what).join();
        win.check("pacman words: update / two packages / many / remove / a package file", w("pacman", ["pacman", "-Syu"]) === "Updating packages (pacman)"
            && w("pacman", ["pacman", "-S", "foo", "bar"]) === "Installing foo, bar (pacman)" && w("pacman", ["pacman", "-S", "a", "b", "c"]) === "Installing 3 packages (pacman)"
            && w("pacman", ["pacman", "-Rns", "foo"]) === "Removing foo (pacman)" && w("pacman", ["pacman", "-U", "/tmp/foo-1-1-x86_64.pkg.tar.zst"]) === "Installing foo-1-1-x86_64 (pacman)",
            [w("pacman", ["pacman", "-Syu"]), w("pacman", ["pacman", "-S", "foo", "bar"]), w("pacman", ["pacman", "-U", "/tmp/foo-1-1-x86_64.pkg.tar.zst"])].join(" | "));
        win.check("a bare yay is an update (yay -Syu); yay's own --sudo value is no package", w("yay", ["yay"]) === "Updating packages (yay)"
            && w("yay", ["yay", "--sudo", "/h/sudo-askpass", "-Syu", "--sudoloop"]) === "Updating packages (yay)", w("yay", ["yay", "--sudo", "/h/sudo-askpass", "-Syu"]));
        const chk = { lock: true, others: false, procs: [
            win._pr(800, "pacman", ["fakeroot", "--", "pacman", "-Sy", "--config", "/tmp/c.conf", "--dbpath", "/tmp/checkup-db-1000/", "--logfile", "/dev/null"], [790]),
            win._pr(801, "pacman", ["pacman", "-Qu", "--dbpath", "/tmp/checkup-db-1000/"], [790]),
            win._pr(802, "yay", ["yay", "-Qua"], [1000]), win._pr(803, "pacman", ["pacman", "-Ss", "foo"], [1000])] };
        win.check("checkupdates' copy never counts (nor yay -Qua, nor a search)", PkRules.jobs(chk, [], false).length === 0, win._words(PkRules.jobs(chk, [], false)));
        // the shell's own update: its supervisor (pid 300) is an ancestor of the yay
        const own = { lock: true, others: false, procs: [
            win._pr(500, "yay", ["yay", "--sudo", "/h/sudo-askpass", "-Syu", "--sudoloop"], [450, 400, 300, 200]),
            win._pr(501, "makepkg", ["/usr/bin/bash", "/usr/bin/makepkg"], [500, 450, 400, 300, 200], "/home/u/.cache/yay/bar")] };
        j = PkRules.jobs(own, [300], false);
        win.check("the shell's own update is told by its supervisor's pid among the ancestors", j.length === 1 && j[0].own === true, win._words(j));
        j = PkRules.jobs(own, [], true);
        win.check("a run whose pid is not known is nobody else's job", j.length === 1 && j[0].own === true, win._words(j));
        j = PkRules.jobs(own, [999], false);
        win.check("... but with another pid known the same tree is someone else's", j.length === 1 && j[0].own === false, win._words(j));
        win.check("a lock with no process is a crashed transaction's leftover: no job", PkRules.jobs({ lock: true, others: false, procs: [] }, [], false).length === 0, "");
        j = PkRules.jobs({ lock: true, others: true, procs: [] }, [], false);
        win.check("a lock with a GUI package manager's daemon is a job", j.length === 1 && j[0].what === "Package transaction running", win._words(j));
        // the 2 minutes, on a pinned clock
        const T = 5000000, gap = 15000, min = 120000;
        let st = PkRules.newState();
        PkRules.observe(st, T, true, gap);
        win.check("a job that ran 119 s does not count", !PkRules.holds(st, T + 119000, min), "");
        win.check("a job that ran 121 s counts", PkRules.holds(st, T + 121000, min), "");
        win.check("... a young job's next change is the instant it comes of age", Math.abs(PkRules.untilChange(st, T + 60000, min) - 60000) < 1, String(PkRules.untilChange(st, T + 60000, min)));
        PkRules.observe(st, T + 130000, false, gap);
        win.check("a job that ends lets go at once", !PkRules.holds(st, T + 130000, min), "");
        st = PkRules.newState();
        PkRules.observe(st, T, true, gap);
        PkRules.observe(st, T + 50000, false, gap);
        PkRules.observe(st, T + 55000, true, gap);
        win.check("two commands chained (a gap of 5 s) are one job: the age goes on", PkRules.holds(st, T + 121000, min), "");
        st = PkRules.newState();
        PkRules.observe(st, T, true, gap);
        PkRules.observe(st, T + 50000, false, gap);
        PkRules.observe(st, T + 70000, true, gap);
        win.check("a gap of 20 s begins a new job: its 2 minutes start again", !PkRules.holds(st, T + 121000, min) && PkRules.holds(st, T + 70000 + 121000, min), "");
    }

    // ---- the fake /proc of the package job watcher -----------------------------------------------------------------------
    //   mk <pid> <comm> <ppid> <cwd|-> <argv...>   (writes <pid>/comm, cmdline, stat, a cwd link)     rmp <pid>
    readonly property string pkFns: 'P=$1; shift; mk() { pid=$1; comm=$2; ppid=$3; cwd=$4; shift 4; d=$P/proc/$pid; mkdir -p "$d"; echo "$comm" > "$d/comm"; '
        + 'printf "%s\\0" "$@" > "$d/cmdline"; echo "$pid ($comm) S $ppid 0 0 0" > "$d/stat"; if [ "$cwd" != - ]; then ln -sfn "$cwd" "$d/cwd"; fi; }; '
        + 'rmp() { rm -rf "$P/proc/$1"; }; '
    function pkProc(script: string): void {
        ops.command = ["bash", "-c", win.pkFns + script, "bash", win.pk];
        ops.running = true;
    }
    readonly property var pj: services.packageJobs

    // ---- ContentHold on stub sources ----------------------------------------------------------------------------------------
    readonly property string chDir: Quickshell.env("CH_DIR") || ""
    IdleConfig {
        id: chCfg
        live: false
    }
    ContentHold {
        id: ch
        live: win.chDir !== ""
        watch: win.chDir !== ""
        pollMs: 200
        ignore: chCfg.settings.contentIgnore
        dbusCommand: ["tail", "-n", "0", "-F", win.chDir + "/dbus.log"]
        clientsCommand: ["cat", win.chDir + "/clients.json"]
        logindCommand: ["cat", win.chDir + "/logind.json"]
    }
    Process {
        id: chOps
    }
    function chSh(script: string): void {
        chOps.command = ["sh", "-c", script, "sh", win.chDir];
        chOps.running = true;
    }
    // dbus-monitor's own shape: a header in the first column, the arguments indented (application name, then the reason)
    function chInhibit(sender: string, app: string): void {
        win.chSh("printf '%s\\n' 'method call time=1.0 sender=" + sender + " -> destination=org.freedesktop.ScreenSaver serial=5 path=/ScreenSaver; "
            + "interface=org.freedesktop.ScreenSaver; member=Inhibit' '   string \"" + app + "\"' '   string \"Playing a game\"' >> \"$1/dbus.log\"");
    }
    function chUnInhibit(sender: string): void {
        win.chSh("printf '%s\\n' 'method call time=2.0 sender=" + sender + " -> destination=org.freedesktop.ScreenSaver serial=6 path=/ScreenSaver; "
            + "interface=org.freedesktop.ScreenSaver; member=UnInhibit' '   uint32 1' >> \"$1/dbus.log\"");
    }
    function chClients(classes: var): void {
        win.chSh("printf '%s' '" + JSON.stringify(classes.map(c => ({ class: c, inhibitingIdle: true }))) + "' > \"$1/clients.json\"");
    }
    function chLogind(whos: var): void {
        win.chSh("printf '%s' '" + JSON.stringify({ data: [whos.map(w => ["idle", w, "reason", "block", 1000, 1234])] }) + "' > \"$1/logind.json\"");
    }
    function chHeldBy(): string {
        return ch.who().join(",");
    }

    // ---- the steps ----------------------------------------------------------------------------------------------------
    //   { name, act, until, within }  `until` must become true within `within` ms (polled every 20 ms)
    //   { name, act, after, check }   `check` after `after` ms
    //   { name, act, ms }             just `act`, then wait `ms`
    property var steps: [
        { name: "baseline: the mock holds nothing", after: 300, check: () => win.idle.mode === "off" && !win.idle.autoActive, detail: () => win.idle.mode },
        { name: "(rules on a pinned clock)", act: () => win._ruleChecks(), ms: 10 },
        { name: "(package job rules)", act: () => win._pkgRuleChecks(), ms: 10 },
        { name: "the debounce is shortened for the probe", act: () => { win.idle.auto.onMs = 250; win.idle.auto.offMs = 700; }, ms: 10 },

        // ---- the screen share
        { name: "a share is read by the shell's ONE watcher: the toasts' holds use it", act: () => { win.share.castNodes = 1; }, until: () => services.notifications.holds.screencast === true && services.notifications.holdReason === "screencast", within: 600,
          detail: () => "screencast " + services.notifications.holds.screencast + " reason " + services.notifications.holdReason },
        { name: "the holds read the SAME watcher (no second reader)", after: 10, check: () => services.notifications.holds.share === win.share && services.notifications.holds.castNodes === 1, detail: () => "" },
        { name: "a share does nothing before the on debounce (100 ms in)", after: 0, check: () => win.idle.mode === "off" && !win.idle.autoActive, detail: () => win.idle.mode },
        { name: "a shared screen raises normal", until: () => win.idle.mode === "normal" && win.idle.autoActive, within: 1500, detail: () => win.idle.mode },
        { name: "the share is named", after: 50, check: () => win.idle.autoReason === "Screen is being shared", detail: () => win.idle.autoReason },
        { name: "a recorder's process counts as a share (a frame event, then the process)", act: () => { win.share.castNodes = 0; win.share.fakeRecorder = true; win.share.castEvent("1,monitor"); }, after: 50, check: () => win.share.active === true, detail: () => "" },
        { name: "a frame event with no recorder behind it is no share", act: () => { win.share.fakeRecorder = false; win.share.castEvent("1,monitor"); }, after: 50, check: () => win.share.active === false, detail: () => "" },
        { name: "a share that lets go keeps normal until the off debounce", after: 300, check: () => win.idle.mode === "normal", detail: () => win.idle.mode },
        { name: "the share's hold drops after the off debounce", until: () => win.idle.mode === "off" && !win.idle.autoActive, within: 1500, detail: () => win.idle.mode },

        // ---- the wiki batch
        { name: "a wiki batch is running (the mock's)", act: () => { services.wiki.batchStepMs = 250; services.wiki.startBatch("discover"); }, until: () => services.wiki.batch.running === true, within: 300, detail: () => "" },
        { name: "a wiki batch asks nothing before the on debounce", after: 0, check: () => win.idle.mode === "off", detail: () => win.idle.mode },
        { name: "a wiki batch raises soft", until: () => win.idle.mode === "soft" && win.idle.autoActive, within: 1500, detail: () => win.idle.mode },
        { name: "the batch is named", after: 50, check: () => win.idle.autoReason === "Wiki batch running", detail: () => win.idle.autoReason },
        { name: "a share outranks the batch: normal, the share named", act: () => { win.share.castNodes = 1; }, until: () => win.idle.mode === "normal" && win.idle.autoReason === "Screen is being shared", within: 1500, detail: () => win.idle.mode + " / " + win.idle.autoReason },
        { name: "the batch keeps soft when the share ends", act: () => { win.share.castNodes = 0; }, until: () => win.idle.mode === "soft" && win.idle.autoReason === "Wiki batch running" && services.wiki.batch.running === true, within: 2500, detail: () => win.idle.mode + " / " + win.idle.autoReason },
        { name: "a finished batch lets go after the off debounce", until: () => win.idle.mode === "off" && !win.idle.autoActive, within: 8000, detail: () => win.idle.mode + " running " + services.wiki.batch.running },

        // ---- the download: real files in DL_DIR
        { name: "the folder resolves through xdg-user-dir", until: () => viaXdg.watching === win.dl, within: 3000, detail: () => "watching '" + viaXdg.watching + "' want '" + win.dl + "'" },
        { name: "the shell's watcher is pointed at the private folder", act: () => { services.downloadWatch.stallMs = 1500; services.downloadWatch.minAgeMs = 800; services.downloadWatch.dir = win.dl; services.downloadWatch.watch = true; }, until: () => services.downloadWatch.watching === win.dl, within: 1000, detail: () => "" },
        { name: "(settle: inotifywait is up)", ms: 700 },
        { name: "a plain file and a subfolder's partial file count nothing", act: () => win.sh(ops, 'd=$1; echo hi > "$d/readme.txt"; echo hi >> "$d/readme.txt"; mkdir -p "$d/sub"; echo x > "$d/sub/z.part"'),
          after: 700, check: () => !services.downloadWatch.active && viaXdg.names.length === 0, detail: () => JSON.stringify(services.downloadWatch.names) },
        { name: "a growing Firefox .part under the minimum age does not count yet", act: () => win.sh(writer, 'd=$1; for i in $(seq 1 60); do echo 0123456789 >> "$d/a.iso.part"; sleep 0.1; done'),
          after: 450, check: () => !services.downloadWatch.active, detail: () => JSON.stringify(services.downloadWatch.names) },
        { name: "a growing Firefox .part counts once it is old enough",
          until: () => services.downloadWatch.active && services.downloadWatch.firstName === "a.iso", within: 1500, detail: () => JSON.stringify(services.downloadWatch.names) },
        { name: "(both watchers see it)", after: 10, check: () => viaXdg.active, detail: () => "" },
        { name: "a download that keeps growing past the stall time still counts", after: 2300, check: () => services.downloadWatch.active, detail: () => "" },
        { name: "a download raises soft after the on debounce", until: () => win.idle.mode === "soft" && win.idle.autoActive, within: 1500, detail: () => win.idle.mode },
        { name: "the download is named with its file", after: 50, check: () => win.idle.autoReason === "Downloading a.iso", detail: () => win.idle.autoReason },
        { name: "a rename (the download finished) ends it at once", act: () => { writer.running = false; win.sh(ops, 'd=$1; sleep 0.15; mv "$d/a.iso.part" "$d/a.iso"'); }, until: () => !services.downloadWatch.active, within: 700, detail: () => JSON.stringify(services.downloadWatch.names) },
        { name: "its hold drops after the off debounce", until: () => win.idle.mode === "off" && !win.idle.autoActive, within: 2500, detail: () => win.idle.mode },
        { name: "a download finished before the minimum age never holds", act: () => win.sh(ops, 'd=$1; echo x > "$d/q.bin.part"; sleep 0.1; echo y >> "$d/q.bin.part"; sleep 0.2; mv "$d/q.bin.part" "$d/q.bin"'),
          after: 1300, check: () => !services.downloadWatch.active && win.idle.mode === "off", detail: () => JSON.stringify(services.downloadWatch.names) + " " + win.idle.mode },
        { name: "(growth, a stall longer than stallMs, growth again)", act: () => win.sh(writer, 'd=$1; for i in 1 2 3 4 5; do echo x >> "$d/e.bin.part"; sleep 0.1; done; sleep 1.8; for i in $(seq 1 25); do echo x >> "$d/e.bin.part"; sleep 0.1; done'),
          after: 450, check: () => !services.downloadWatch.active, detail: () => JSON.stringify(services.downloadWatch.names) },
        { name: "a stall resets the age: the resumed download starts its minimum again", after: 2200, check: () => !services.downloadWatch.active, detail: () => JSON.stringify(services.downloadWatch.names) },
        { name: "(the resumed one counts after its own minimum age)", until: () => services.downloadWatch.active && services.downloadWatch.firstName === "e.bin", within: 1500, detail: () => JSON.stringify(services.downloadWatch.names) },
        { name: "(it stalls and lets go)", act: () => { writer.running = false; }, until: () => !services.downloadWatch.active, within: 2500, detail: () => JSON.stringify(services.downloadWatch.names) },
        { name: "(its hold drops)", until: () => win.idle.mode === "off", within: 2500, detail: () => win.idle.mode },
        { name: "a Chromium .crdownload counts", act: () => win.sh(ops, 'd=$1; for i in $(seq 1 16); do echo x >> "$d/b.zip.crdownload"; sleep 0.1; done'), until: () => services.downloadWatch.firstName === "b.zip", within: 1800, detail: () => JSON.stringify(services.downloadWatch.names) },
        { name: "a stalled download stops counting (the file still stands)", until: () => !services.downloadWatch.active, within: 2800, detail: () => JSON.stringify(services.downloadWatch.names) },
        { name: "(the stalled partial file still exists)", act: () => win.sh(ops, 'd=$1; test -e "$d/b.zip.crdownload"'), after: 400, check: () => win.opsExit === 0, detail: () => "exit " + win.opsExit },
        { name: "a deleted partial file ends it at once", act: () => win.sh(ops, 'd=$1; for i in $(seq 1 20); do echo x >> "$d/b.zip.crdownload"; sleep 0.1; done; rm -f "$d/b.zip.crdownload"'), until: () => services.downloadWatch.active, within: 1500, detail: () => "" },
        { name: "(deleted)", until: () => !services.downloadWatch.active, within: 1800, detail: () => JSON.stringify(services.downloadWatch.names) },
        { name: "aria2: the data file's writes count while its control file stands", act: () => win.sh(writer, 'd=$1; echo c > "$d/c.bin.aria2"; : > "$d/c.bin"; for i in $(seq 1 40); do echo 0123456789 >> "$d/c.bin"; sleep 0.1; done'),
          until: () => services.downloadWatch.active && services.downloadWatch.firstName === "c.bin", within: 2200, detail: () => JSON.stringify(services.downloadWatch.names) },
        { name: "aria2: the control file gone ends it at once", act: () => { writer.running = false; win.sh(ops, 'd=$1; sleep 0.15; rm -f "$d/c.bin.aria2"'); }, until: () => !services.downloadWatch.active, within: 700, detail: () => JSON.stringify(services.downloadWatch.names) },
        { name: "(clean up)", act: () => win.sh(ops, 'd=$1; rm -rf "$d/sub" "$d"/*'), ms: 100 },

        // ---- package jobs: pkgjobs.py against a fake /proc and a fake lock file in PK_DIR
        { name: "(the package watcher is pointed at the fake /proc, the minimum age shortened to 800 ms)", act: () => {
            win.pkProc('mkdir -p "$P/proc"; : > "$P/db.lck"');
            win.pj.procRoot = win.pk + "/proc"; win.pj.lockPath = win.pk + "/db.lck"; win.pj.intervalS = 0.1; win.pj.minAgeMs = 800; win.pj.gapMs = 500;
            win.pj.ownPid = 0; win.pj.ownRun = false; }, ms: 200 },
        { name: "(the scanner starts)", act: () => { win.pj.watch = true; }, ms: 700 },
        { name: "a stale lock with no process holds nothing", after: 1300, check: () => !win.pj.active && win.pj.jobs.length === 0 && win.idle.mode === "off", detail: () => JSON.stringify(win.pj.jobs) + " " + win.idle.mode },
        { name: "checkupdates' copy and yay -Qua never count, the lock standing beside them",
          act: () => win.pkProc('mk 600 pacman 590 - pacman -Sy --config /tmp/c.conf --dbpath /tmp/checkup-db-1000/; mk 601 yay 1 - yay -Qua; mk 602 pacman 1 - pacman -Ss foo'),
          after: 1300, check: () => !win.pj.active && win.pj.jobs.length === 0 && win.idle.mode === "off", detail: () => JSON.stringify(win.pj.jobs) },
        { name: "(they end)", act: () => win.pkProc('rmp 600; rmp 601; rmp 602; rm -f "$P/db.lck"'), ms: 400 },
        { name: "an AUR build with no lock is seen but does not count before the minimum age",
          act: () => win.pkProc('mk 400 bash 1 - bash; mk 500 yay 400 - yay -S foo; mk 501 makepkg 500 /home/u/.cache/yay/foo /usr/bin/bash /usr/bin/makepkg -f'),
          after: 450, check: () => !win.pj.active && win.pj.jobs.length === 1, detail: () => JSON.stringify(win.pj.jobs) + " active " + win.pj.active },
        { name: "an AUR build with no lock counts once it is old enough, in the command's words", until: () => win.pj.active && win.pj.what === "Building foo (yay)", within: 1500,
          detail: () => "active " + win.pj.active + " what '" + win.pj.what + "' jobs " + JSON.stringify(win.pj.jobs) },
        { name: "a package job raises soft after the on debounce", until: () => win.idle.mode === "soft" && win.idle.autoActive, within: 1500, detail: () => win.idle.mode },
        { name: "the package job is named by its command line", after: 50, check: () => win.idle.autoReason === "Building foo (yay)", detail: () => win.idle.autoReason },
        { name: "a job that ends lets go at once", act: () => win.pkProc('rmp 500; rmp 501'), until: () => !win.pj.active, within: 800, detail: () => JSON.stringify(win.pj.jobs) },
        { name: "its hold drops after the off debounce", until: () => win.idle.mode === "off" && !win.idle.autoActive, within: 2500, detail: () => win.idle.mode },
        { name: "a package job that ends before the minimum age never holds", act: () => win.pkProc('mk 510 pacman 400 - pacman -S bar; : > "$P/db.lck"'),
          after: 350, check: () => !win.pj.active && win.pj.jobs.length === 1 && win.idle.mode === "off", detail: () => JSON.stringify(win.pj.jobs) },
        { name: "(it ends)", act: () => win.pkProc('rmp 510; rm -f "$P/db.lck"'), after: 1200, check: () => !win.pj.active && win.idle.mode === "off", detail: () => win.idle.mode },
        { name: "a pacman transaction counts after the minimum age, in the command's words", act: () => win.pkProc('mk 520 pacman 400 - pacman -Syu; : > "$P/db.lck"'),
          until: () => win.pj.active && win.pj.what === "Updating packages (pacman)", within: 2200, detail: () => "active " + win.pj.active + " what '" + win.pj.what + "'" },
        { name: "(it ends)", act: () => win.pkProc('rmp 520; rm -f "$P/db.lck"'), until: () => win.idle.mode === "off", within: 3000, detail: () => win.idle.mode },

        // ---- the shell's own update keeps its own cause
        { name: "the shell's own update: its tree (the supervisor's pid among the ancestors) keeps the update's cause and words",
          act: () => { win.pj.ownPid = 300; win.pj.ownRun = true; win.idle.auto.update = true;
              win.pkProc('mk 450 bash 300 - bash; mk 530 yay 450 - yay --sudo /h/sudo-askpass -Syu --sudoloop; mk 531 makepkg 530 /home/u/.cache/yay/bar /usr/bin/bash /usr/bin/makepkg'); },
          until: () => win.idle.mode === "soft" && win.idle.autoReason === "System update running", within: 1500, detail: () => win.idle.mode + " / " + win.idle.autoReason },
        { name: "... and it is not counted a second time (no generic package cause beside it)", after: 1400,
          check: () => !win.pj.active && win.pj.ownSeen && !win.idle.auto.counted.pkg && win.idle.autoReason === "System update running",
          detail: () => "active " + win.pj.active + " ownSeen " + win.pj.ownSeen + " pkg counted " + win.idle.auto.counted.pkg + " reason " + win.idle.autoReason },
        { name: "a run whose pid is not known (yet) is nobody else's job either", act: () => { win.pj.ownPid = 0; }, after: 1300, check: () => !win.pj.active && win.pj.ownSeen && !win.idle.auto.counted.pkg, detail: () => "active " + win.pj.active },
        { name: "with no run of the shell's the same tree is someone else's: it counts, in its own words",
          act: () => { win.pj.ownRun = false; win.idle.auto.update = false; },
          until: () => win.pj.active && win.pj.what === "Building bar (yay)" && win.idle.auto.counted.pkg, within: 2500, detail: () => "active " + win.pj.active + " what '" + win.pj.what + "' ownSeen " + win.pj.ownSeen },
        { name: "(clean up)", act: () => { win.pkProc('rmp 450; rmp 530; rmp 531'); }, until: () => win.idle.mode === "off", within: 3000, detail: () => win.idle.mode },
        { name: "(the scanner stops)", act: () => { win.pj.watch = false; }, ms: 100 },

        // ---- the toasts' holds without a shell
        { name: "holds with no shared watcher hold their own: a cast node holds the toasts", act: () => { ownHolds._share.castNodes = 1; }, after: 50,
          check: () => ownHolds.screencast === true && ownHolds.reason === "screencast" && ownHolds.share === null, detail: () => ownHolds.reason },
        { name: "... and it lets go with the node", act: () => { ownHolds._share.castNodes = 0; }, after: 50, check: () => ownHolds.screencast === false && ownHolds.reason === "", detail: () => ownHolds.reason },

        // ---- the ignore list (idle.jsonc contentIgnore): FreeRDP's SDL client inhibits for its whole life
        { name: "(the ignore list's rules)", act: () => win._ignoreRuleChecks(), ms: 10 },
        { name: "the stub sources are up: nothing is held", after: 500, check: () => ch.live && !ch.held && ch.ignore.length === ICfg.parse({}, "/h").contentIgnore.length, detail: () => "live " + ch.live + " held " + ch.held + " ignore " + JSON.stringify(ch.ignore) },
        { name: "the shell's idle service reads the list from idle.jsonc (the default list reaches ContentHold)", after: 10,
          check: () => win.idle.soft.content.ignore.indexOf("sdl-freerdp3") >= 0, detail: () => JSON.stringify(win.idle.soft.content.ignore) },
        { name: "a ScreenSaver holder named sdl-freerdp3 is seen ...", act: () => win.chInhibit(":1.90", "sdl-freerdp3"),
          until: () => ch._appsAll.length === 1, within: 1500, detail: () => JSON.stringify(ch._appsAll) },
        { name: "... and holds nothing: FreeRDP's SDL client is on the default list", after: 300, check: () => !ch.held && ch._apps.length === 0 && ch.firstWho === "", detail: () => "held " + ch.held + " by " + win.chHeldBy() },
        { name: "an SDL game (another name, same sender kind) still holds", act: () => win.chInhibit(":1.91", "SDL Application"),
          until: () => ch.held && win.chHeldBy() === "SDL Application", within: 1500, detail: () => "held " + ch.held + " by " + win.chHeldBy() },
        { name: "a name that only CONTAINS a listed one holds too (exact names, no substring)", act: () => win.chInhibit(":1.92", "my-sdl-freerdp3-game"),
          until: () => win.chHeldBy().indexOf("my-sdl-freerdp3-game") >= 0, within: 1500, detail: () => win.chHeldBy() },
        { name: "(the games end)", act: () => { win.chUnInhibit(":1.91"); win.chUnInhibit(":1.92"); },
          until: () => !ch.held, within: 1500, detail: () => win.chHeldBy() },
        { name: "a window of class com.freerdp.client.sdl3 holding the Wayland inhibitor is ignored, mpv's is not", act: () => win.chClients(["com.freerdp.client.sdl3"]),
          after: 600, check: () => ch._windowsAll.length === 1 && !ch.held, detail: () => "windows " + JSON.stringify(ch._windowsAll) + " held " + ch.held },
        { name: "... mpv beside it holds", act: () => win.chClients(["com.freerdp.client.sdl3", "mpv"]),
          until: () => ch.held && win.chHeldBy() === "mpv", within: 1500, detail: () => win.chHeldBy() },
        { name: "(mpv goes)", act: () => win.chClients([]), until: () => !ch.held, within: 1500, detail: () => win.chHeldBy() },
        { name: "a logind idle inhibitor of who SDL-FreeRDP3 (any case) is ignored", act: () => win.chLogind(["SDL-FreeRDP3"]),
          after: 600, check: () => ch._logindAll.length === 1 && !ch.held, detail: () => "logind " + JSON.stringify(ch._logindAll) + " held " + ch.held },
        { name: "... another who beside it holds", act: () => win.chLogind(["SDL-FreeRDP3", "my-backup"]),
          until: () => ch.held && win.chHeldBy() === "my-backup", within: 1500, detail: () => win.chHeldBy() },
        { name: "(it goes)", act: () => win.chLogind([]), until: () => !ch.held, within: 1500, detail: () => win.chHeldBy() },
        { name: "the list is read hot: an empty contentIgnore makes the FreeRDP holder count at once", act: () => chCfg.apply({ contentIgnore: [] }),
          until: () => ch.held && win.chHeldBy() === "sdl-freerdp3", within: 800, detail: () => "held " + ch.held + " by " + win.chHeldBy() + " ignore " + JSON.stringify(ch.ignore) },
        { name: "... and a user's own list sets it aside again (names trimmed, any case)", act: () => chCfg.apply({ contentIgnore: ["  SDL-FreeRDP3 "] }),
          until: () => !ch.held, within: 800, detail: () => "held " + ch.held + " by " + win.chHeldBy() },
        { name: "(the holder goes)", act: () => win.chUnInhibit(":1.90"), until: () => ch._appsAll.length === 0, within: 1500, detail: () => JSON.stringify(ch._appsAll) }
    ]

    function next(): void {
        win.idx++;
        if (win.idx >= win.steps.length) {
            console.log("ICAUSE RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " (" + (win.checks - win.fails) + "/" + win.checks + " checks)");
            Qt.callLater(Qt.quit);
            return;
        }
        win.cur = win.steps[win.idx];
        if (win.cur.act)
            win.cur.act();
        win.t0 = Date.now();
        poll.restart();
    }
    Timer {
        id: poll
        interval: 20
        repeat: true
        onTriggered: {
            const s = win.cur;
            const el = win.sinceStart();
            if (s.until) {
                if (s.until()) {
                    poll.stop();
                    win.check(s.name, true, "");
                    win.next();
                } else if (el > s.within) {
                    poll.stop();
                    win.check(s.name, false, "not within " + s.within + " ms: " + (s.detail ? s.detail() : ""));
                    win.next();
                }
            } else if (s.check) {
                if (el >= s.after) {
                    poll.stop();
                    win.check(s.name, !!s.check(), s.detail ? s.detail() : "");
                    win.next();
                }
            } else if (el >= (s.ms || 0)) {
                poll.stop();
                win.next();
            }
        }
    }
    Timer {
        interval: 1500
        running: true
        onTriggered: win.next()
    }
    // a hung run ends as a FAIL
    Timer {
        interval: 80000
        running: true
        onTriggered: {
            console.log("ICAUSE FAIL the probe did not finish (step " + win.idx + ")");
            console.log("ICAUSE RESULT FAIL (timeout)");
            Qt.quit();
        }
    }
}
