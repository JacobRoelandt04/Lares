.pragma library

// =============================================================================
// PackageJobRules.js -- PackageJobWatch's rules, with no Qt in them: which of pkgjobs.py's process records are a package job, whose
// job it is, what to call it, and when a job has run long enough to count.
//
// WHICH COMMAND LINES ARE A TRANSACTION is the restart guard's rule in tools/shell/lares (`pm_args_transact`: pacman / yay `-S` that is not
// a query, `-U`, `-R`; NOT `-Q`, `-F`, and NOT a command that names `--dbpath` / `-b`, which is checkupdates' `pacman -Sy` on a private copy
// of the database, run every few minutes by the shell's own update check). `transacts()` is its port, and both are held to ONE table:
// tools/dev/pm_transact_cases.txt (the idle causes probe runs the bash function and this one over it). Two things are added here and not
// there, because only the idle hold needs them: a bare `yay` / `paru` (no flag: it IS `-Syu`; `yay <term>` searches and then installs) and
// `makepkg` (an AUR build compiles for minutes holding no database lock).
//
// A JOB is a tree of those processes: a makepkg under its yay is the yay's, a pacman under a yay is the yay's. The lock file alone
// (`/var/lib/pacman/db.lck`) is a job only when a GUI package manager's daemon runs (pamac, PackageKit): a lock with no process is a crashed
// transaction's leftover, and a hold on it would never end.
//
// THE SHELL'S OWN UPDATE is told by FACT, not by timing: a job whose process tree has the update supervisor's pid among its ancestors
// (update-run.sh -> systemd-inhibit -> script -> yay) is `own`, and with a run going whose pid is not known (`ownUnknown`) no job can be told
// from it, so none is counted as someone else's. The own run keeps its own cause ("System update running", IdleAuto's `update`).
//
// ONLY A LONG JOB COUNTS (`minAgeMs`, 2 minutes: the user's rule, as for downloads -- a short install ends before a suspend could hurt it).
// A job's age runs from the first look that saw it; a gap of `gapMs` with no job at all begins a new one (two pacman commands chained
// with `&&` are one job; a snapshot is taken every few seconds, so the gap is a few looks).
// =============================================================================

var BASENAME = /[^\/]*$/;
function _base(s) {
    return String(s || "").match(BASENAME)[0];
}

// The restart guard's rule: do these pacman / yay arguments ask for a transaction? (A port of lares's pm_args_transact, same order.)
function transacts(args) {
    var a = args || [];
    var i, x;
    for (i = 0; i < a.length; i++) {
        x = a[i];
        if (x === "--dbpath" || x.indexOf("--dbpath=") === 0 || x === "-b")
            return false;   // checkupdates: a private copy of the database
    }
    for (i = 0; i < a.length; i++) {
        x = a[i];
        if (x === "--upgrade" || x === "--remove")
            return true;
        if (x === "--sync") {
            var j = " " + a.join(" ") + " ";
            var q = [" --search ", " --info ", " --list ", " --groups ", " --print "];
            for (var k = 0; k < q.length; k++)
                if (j.indexOf(q[k]) >= 0)
                    return false;
            return true;
        }
        if (x.indexOf("--") === 0)
            continue;
        if (x.length >= 2 && x.charAt(0) === "-") {
            var cl = x.substring(1);
            if (/[UR]/.test(cl))
                return true;
            if (cl.indexOf("S") >= 0)
                return !/[silgp]/.test(cl);
            return false;   // -Q, -F, -T, -V, -D ...: not a transaction
        }
    }
    return false;
}

// The arguments after the program: the record's argv from the entry whose name is the process's comm (argv[1] for a script an
// interpreter runs), like pm_running.
function argsOf(p) {
    var v = p.argv || [];
    for (var i = 0; i < v.length; i++)
        if (_base(v[i]) === p.comm)
            return v.slice(i + 1);
    return null;
}

var MAKEPKG_INFO = ["--printsrcinfo", "--geninteg", "-g", "--help", "-h", "--version", "-V", "--verifysource"];

// Does this process count as a package job of its own (before it is folded under its parent)?
function counts(p) {
    var args = argsOf(p);
    if (args === null)
        return false;
    if (p.comm === "makepkg") {
        for (var i = 0; i < args.length; i++)
            if (MAKEPKG_INFO.indexOf(args[i]) >= 0)
                return false;
        return true;
    }
    if (transacts(args))
        return true;
    if (p.comm === "yay" || p.comm === "paru") {
        // no flag at all: `yay` alone is `yay -Syu`, `yay term` searches and then installs
        for (var k = 0; k < args.length; k++)
            if (args[k].charAt(0) === "-")
                return false;
        return true;
    }
    return false;
}

// Options of yay / pacman / paru that take a value in the next argument (the value is not a package).
var VALUE_OPTS = ["--sudo", "--sudoflags", "--dbpath", "--root", "--config", "--cachedir", "--makepkg", "--pacman", "--editor",
    "--builddir", "--makepkgconf", "--mflags", "--gpgflags", "--gpgdir", "--logfile", "--arch", "--color", "--ignore", "--ignoregroup",
    "--overwrite", "--asdeps", "--sortby", "--searchby", "--completioninterval", "--redownload", "-b", "-r"];

function _clip(s, n) {
    s = String(s || "");
    return s.length > n ? s.substring(0, n - 1) + "…" : s;
}

function _targets(args) {
    var out = [];
    for (var i = 0; i < args.length; i++) {
        var a = args[i];
        if (VALUE_OPTS.indexOf(a) >= 0) {
            i++;
            continue;
        }
        if (a.charAt(0) === "-")
            continue;
        out.push(a);
    }
    return out;
}

function _names(list) {
    if (list.length === 1)
        return _clip(list[0], 30);
    if (list.length === 2)
        return _clip(list[0], 20) + ", " + _clip(list[1], 20);
    return list.length + " packages";
}

// What a pacman / yay command line does, in words: "Installing foo", "Updating packages", "Removing foo".
function operation(args) {
    var t = _targets(args);
    var op = "";
    for (var i = 0; i < args.length; i++) {
        var a = args[i];
        if (a === "--upgrade") op = "U";
        else if (a === "--remove") op = "R";
        else if (a === "--sync") op = "S";
        else if (a.indexOf("--") !== 0 && a.length >= 2 && a.charAt(0) === "-" && op === "") {
            var cl = a.substring(1);
            op = /U/.test(cl) ? "U" : /R/.test(cl) ? "R" : /S/.test(cl) ? "S" : "";
        }
        if (op !== "")
            break;
    }
    if (op === "R")
        return t.length > 0 ? "Removing " + _names(t) : "Removing packages";
    if (op === "U")
        return t.length > 0 ? "Installing " + (t.length === 1 ? _clip(_base(t[0]).replace(/\.pkg\.tar.*$/, ""), 30) : _names(t)) : "Installing packages";
    if (t.length === 0)
        return "Updating packages";
    return "Installing " + _names(t);
}

// The jobs in a snapshot (pkgjobs.py's line, parsed): [{ pid, tool, what, own }] -- a job is the tree under one root process.
// ownPids: the pids of the shell's own update supervisor; ownUnknown: a shell-run update goes and its pid is not known.
function jobs(snap, ownPids, ownUnknown) {
    var s = snap || {};
    var procs = (s.procs || []).filter(counts);
    var pids = {};
    procs.forEach(function (p) { pids[p.pid] = true; });
    var own = {};
    (ownPids || []).forEach(function (p) { own[p] = true; });
    var out = [];
    procs.forEach(function (p) {
        var below = false;
        for (var i = 0; i < p.chain.length; i++)
            if (pids[p.chain[i]]) below = true;
        if (below)
            return;
        var tree = procs.filter(function (q) {
            return q.pid === p.pid || q.chain.indexOf(p.pid) >= 0;
        });
        var isOwn = ownUnknown === true;
        tree.forEach(function (q) {
            if (own[q.pid]) isOwn = true;
            for (var k = 0; k < q.chain.length; k++)
                if (own[q.chain[k]]) isOwn = true;
        });
        var build = null;
        tree.forEach(function (q) {
            if (q.comm === "makepkg" && build === null) build = q;
        });
        var what;
        if (build !== null) {
            var dir = _base(String(build.cwd || "").replace(/\/+$/, ""));
            what = "Building " + (dir !== "" ? _clip(dir, 30) : "a package") + " (" + p.comm + ")";
        } else if (p.comm === "makepkg") {
            what = "Building a package (makepkg)";
        } else {
            what = operation(argsOf(p) || []) + " (" + p.comm + ")";
        }
        out.push({ pid: p.pid, tool: p.comm, what: what, own: isOwn });
    });
    if (out.length === 0 && s.lock === true && s.others === true)
        out.push({ pid: 0, tool: "lock", what: "Package transaction running", own: ownUnknown === true });
    return out;
}

// ---- the age -----------------------------------------------------------------------------------------------------------------
// state: { start (ms of the first look of this run of jobs, null when none), emptySince (ms the picture became empty), present }.
function newState() {
    return { start: null, emptySince: null, present: false };
}

// One look: `has` = some job (not the shell's own) shows now.
function observe(st, nowMs, has, gapMs) {
    if (has) {
        if (st.start === null || (st.emptySince !== null && nowMs - st.emptySince >= gapMs))
            st.start = nowMs;
        st.emptySince = null;
        st.present = true;
    } else {
        st.present = false;
        if (st.emptySince === null)
            st.emptySince = nowMs;
    }
}

// Has the run lasted long enough, and is a job there now?
function holds(st, nowMs, minAgeMs) {
    return st.present && st.start !== null && nowMs - st.start >= minAgeMs;
}

// ms until the answer changes by itself (a young run coming of age); 0 when nothing can.
function untilChange(st, nowMs, minAgeMs) {
    if (!st.present || st.start === null)
        return 0;
    var left = st.start + minAgeMs - nowMs;
    return left > 0 ? left : 0;
}
