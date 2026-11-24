pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// NotesFileOps.qml -- the notes data layer's serialised shell queue.
//
// Everything that touches the notes tree -- the scan's four tools, every
// move, link, group, trash and paste -- runs here, ONE `sh -c` AT A TIME, so a
// scan never reads a tree an op is half-way through changing, and two ops
// never pick the same free name.
//
// A JOB is a plain object with one method, `next(res)`:
//   next(null)  -> the first step, or null when the job needs no shell at all
//   next(res)   -> the step after `res`, or null when the job is finished
// A step is { script, args, stdin }: the script runs as
//   setpriv --pdeathsig TERM -- sh -c <script> sh <args...>
// (positional arguments, never interpolated; the child dies with quickshell).
// `stdin` is a string written to the child and then closed (the
// stdinEnabled dance: enabled before `running`, written in `started`,
// disabled -- that is the EOF); a step without stdin gets </dev/null, because
// a Process leaves an unused stdin open for ever and a tool that reads it
// would hang.
// `res` is { code, out (Uint8Array of stdout), text (the same, decoded by
// Qt), err (stderr text), timedOut }.
//
// A job's own exceptions end the job (logged), never the queue. A step that
// runs past `stepTimeoutMs` is killed and reported with timedOut: true.
// =============================================================================
Scope {
    id: ops

    property int stepTimeoutMs: 60000

    // =========================================================================
    //  The scripts. Every name, path and text is a POSITIONAL argument (or
    //  stdin); nothing is ever spliced into the script text. Outputs are
    //  NUL-terminated records whose first byte is a tag:
    //    N<name>  the name an op took      G/T/D<name>  makeGroup's three
    //    R<key>   a group rmdir'd because we emptied it
    //    P<path> M<mime>  addForeign's check     E<code>  why it failed
    // =========================================================================

    // Shared shell functions.
    //   ex PATH           exists, or is a link (a broken link exists too)
    //   abslinks DIR      every RELATIVE link under DIR re-made absolute --
    //                     before DIR moves, since a relative link inside it
    //                     resolves from wherever the folder lands
    //   mvu SRC DIR B E   move SRC into DIR as B+E, or the first Obsidian
    //                     suffix that is free ("B 1E", "B 2E" ...); NM = the
    //                     name taken. NEVER overwrites: `mv -n` exits 0
    //                     without moving onto an existing name, so every move
    //                     is VERIFIED (source gone, destination there) and a
    //                     clash that lands between the check and the move
    //                     just tries the next suffix. A link with a RELATIVE
    //                     target is re-made with its absolute target instead
    //                     of moved (it would break in another folder).
    //                     2 = the source vanished, 3 = no free name,
    //                     4 = the move itself failed.
    //   rmup DIR          rmdir DIR, then each parent that left empty, up to
    //                     the root (never the root); prints R<key> each
    readonly property string prelude: [
        'ex() { [ -e "$1" ] || [ -L "$1" ]; }',
        'abslinks() {',
        '    find "$1" -type l -exec sh -c \'for l; do case $(readlink -- "$l") in /*) ;; *) t=$(realpath -m -- "$l") && ln -sfn -- "$t" "$l" ;; esac; done\' sh {} +',
        '}',
        'mvu() {',
        '    _s=$1; _d=$2; _b=$3; _e=$4; _n=0',
        '    while [ "$_n" -lt 10000 ]; do',
        '        if [ "$_n" -eq 0 ]; then NM=$_b$_e; else NM="$_b $_n$_e"; fi',
        '        _t=$_d/$NM',
        '        [ "$_t" = "$_s" ] && return 0',
        '        if ! ex "$_t"; then',
        '            _abs=',
        '            if [ -d "$_s" ] && [ ! -L "$_s" ]; then abslinks "$_s"; fi',
        '            if [ -L "$_s" ]; then',
        '                case $(readlink -- "$_s") in',
        '                    /*) ;;',
        '                    *) _abs=$(realpath -m -- "$_s") ;;',
        '                esac',
        '            fi',
        '            if [ -n "$_abs" ]; then',
        '                ln -s -- "$_abs" "$_t" 2>/dev/null && { rm -f -- "$_s"; return 0; }',
        '            else',
        '                mv -n -T -- "$_s" "$_t" 2>/dev/null',
        '                if ! ex "$_s" && ex "$_t"; then return 0; fi',
        '            fi',
        '            ex "$_s" || return 2',
        '            ex "$_t" || return 4',
        '        fi',
        '        _n=$((_n + 1))',
        '    done',
        '    return 3',
        '}',
        'rmup() {',
        '    _d=$1',
        '    while [ "$_d" != "$ROOT" ] && [ "${_d#"$ROOT"/}" != "$_d" ]; do',
        '        rmdir -- "$_d" 2>/dev/null || return 0',
        '        printf "R%s\\0" "${_d#"$ROOT"/}"',
        '        _d=${_d%/*}',
        '    done',
        '}',
        ''
    ].join("\n")

    // Scan: ROOT then folders, each "D<key>" (everything under it) or
    // "S<key>" (its direct children only). The canonical root, then per
    // folder a header (walked up to the nearest folder that still exists)
    // and find's records, hidden names pruned. -H: a root that is itself a
    // link is followed; nothing below it is.
    readonly property string scanScript: [
        'ROOT=$1; shift',
        '_c=$(realpath -m -- "$ROOT") || _c=$ROOT',
        'printf "R\\t%s\\0\\0" "$_c"',
        '_rc=0',
        'for _a in "$@"; do',
        '    case $_a in D*) _deep=1 ;; *) _deep=0 ;; esac',
        '    _d=${_a#?}',
        '    while [ -n "$_d" ] && { [ -L "$ROOT/$_d" ] || [ ! -d "$ROOT/$_d" ]; }; do',
        '        case $_d in */*) _d=${_d%/*} ;; *) _d= ;; esac',
        '    done',
        '    if [ -z "$_d" ]; then _b=$ROOT; else _b=$ROOT/$_d; fi',
        '    if [ ! -d "$_b" ]; then printf "#\\t0\\t%s\\t%s\\0\\0" "$_deep" "$_d"; continue; fi',
        '    printf "#\\t1\\t%s\\t%s\\0\\0" "$_deep" "$_d"',
        '    if [ $_deep = 1 ]; then _m=; else _m="-maxdepth 1"; fi',
        '    find -H "$_b" -mindepth 1 $_m \\( -name ".*" -prune \\) -o -printf "%y\\t%Y\\t%s\\t%T@\\t%B@\\t%i\\t%P\\0%l\\0" || _rc=1',
        'done',
        'exit $_rc'
    ].join("\n")

    // Links (absolute link paths): where each points (in order), then the
    // target's size, mtime and birth for the ones that resolve.
    readonly property string linkScript: [
        'realpath -m -z -- "$@"',
        'printf "S\\0"',
        'stat -L --printf "%s\\t%.9Y\\t%.9W\\t%n\\0" -- "$@" 2>/dev/null',
        'exit 0'
    ].join("\n")

    // MIME types of the NUL-separated paths on stdin, in order.
    readonly property string mimeScript: 'xargs -0 -r file -r -L -N -0 --mime-type --'

    // The first 4096 bytes of each NUL-separated path on stdin, each closed
    // by "\0<token>\0" ($1).
    readonly property string headScript: 'xargs -0 -r sh -c \'for f; do printf "%s\\0" "$f"; head -c 4096 -- "$f" 2>/dev/null; printf "\\0%s\\0" "$0"; done\' "$1"'

    // createNote: ROOT DIR BASE EXT, the text on stdin. The name is taken
    // with noclobber (O_EXCL), so it can never be someone else's file.
    readonly property string createScript: [
        'ROOT=$1; _d=$2; _b=$3; _e=$4',
        'mkdir -p -- "$_d" || { printf "Emkdir\\0"; exit 1; }',
        '_n=0',
        'while [ "$_n" -lt 10000 ]; do',
        '    if [ "$_n" -eq 0 ]; then NM=$_b$_e; else NM="$_b $_n$_e"; fi',
        '    if ( set -C; : > "$_d/$NM" ) 2>/dev/null; then',
        '        cat >> "$_d/$NM" || { printf "Ewrite\\0"; exit 1; }',
        '        printf "N%s\\0" "$NM"; exit 0',
        '    fi',
        '    ex "$_d/$NM" || { printf "Ecreate\\0"; exit 1; }',
        '    _n=$((_n + 1))',
        'done',
        'printf "Efull\\0"; exit 1'
    ].join("\n")

    // renameEntry: ROOT SRC DIR BASE EXT (DIR is SRC's own folder).
    readonly property string renameScript: [
        'ROOT=$1',
        'mvu "$2" "$3" "$4" "$5"; _rc=$?',
        'if [ $_rc -eq 0 ]; then printf "N%s\\0" "$NM"; else printf "E%s\\0" "$_rc"; exit 1; fi'
    ].join("\n")

    // moveEntry: ROOT SRC DESTDIR BASE EXT SRCDIR; SRCDIR goes if emptied.
    readonly property string moveScript: [
        'ROOT=$1',
        'mvu "$2" "$3" "$4" "$5"; _rc=$?',
        'if [ $_rc -ne 0 ]; then printf "E%s\\0" "$_rc"; exit 1; fi',
        'printf "N%s\\0" "$NM"',
        'rmup "$6"'
    ].join("\n")

    // makeGroup: ROOT PARENT TARGET TB TE DRAGGED DB DE DRAGGEDDIR. The group
    // is "Group" (+ suffix) in PARENT, made with mkdir (fails on a clash, so
    // the name is ours); the target moves in first, then the dragged entry;
    // DRAGGEDDIR goes if that emptied it.
    readonly property string groupScript: [
        'ROOT=$1; _p=$2',
        '_g=0',
        'while :; do',
        '    if [ "$_g" -eq 0 ]; then G=Group; else G="Group $_g"; fi',
        '    mkdir -- "$_p/$G" 2>/dev/null && break',
        '    ex "$_p/$G" || { printf "Emkdir\\0"; exit 1; }',
        '    _g=$((_g + 1))',
        '    [ "$_g" -lt 10000 ] || { printf "Efull\\0"; exit 1; }',
        'done',
        'printf "G%s\\0" "$G"',
        'mvu "$3" "$_p/$G" "$4" "$5" || { rmdir -- "$_p/$G"; printf "Emove\\0"; exit 1; }',
        'printf "T%s\\0" "$NM"',
        'mvu "$6" "$_p/$G" "$7" "$8" || { printf "Emove\\0"; exit 1; }',
        'printf "D%s\\0" "$NM"',
        '[ "$9" = "$_p" ] || rmup "$9"'
    ].join("\n")

    // trashEntry: ROOT PATH DIR. Never a link (a foreign note is only ever
    // unlinked); gio trash keeps the links inside a trashed group as links.
    readonly property string trashScript: [
        'ROOT=$1',
        '[ -L "$2" ] && { printf "Eforeign\\0"; exit 1; }',
        'ex "$2" || { printf "Emissing\\0"; exit 1; }',
        'gio trash -- "$2" 2>/dev/null',
        'ex "$2" && { printf "Etrash\\0"; exit 1; }',
        'rmup "$3"'
    ].join("\n")

    // unlinkEntry: ROOT PATH DIR. Only ever a link: a regular file is never
    // removed by this.
    readonly property string unlinkScript: [
        'ROOT=$1',
        '[ -L "$2" ] || { printf "Enotlink\\0"; exit 1; }',
        'rm -- "$2" || { printf "Eunlink\\0"; exit 1; }',
        'rmup "$3"'
    ].join("\n")

    // addForeign, step 1: PATH -> its real path, its MIME type and its first
    // 4096 bytes (the service decides "is it a note" by the same rule as the
    // scan: NotesScan.isNote).
    readonly property string foreignCheckScript: [
        '_r=$(realpath -e -- "$1") || { printf "Emissing\\0"; exit 1; }',
        '_m=$(file -L -b --mime-type -- "$_r" 2>/dev/null)',
        'printf "P%s\\0M%s\\0" "$_r" "$_m"',
        '[ -f "$_r" ] && head -c 4096 -- "$_r" 2>/dev/null',
        'exit 0'
    ].join("\n")

    // addForeign, step 2: ROOT TARGET DIR BASE EXT -> an absolute link; `ln
    // -s` fails on an existing name, so a clash takes the next suffix.
    readonly property string foreignLinkScript: [
        'ROOT=$1; _d=$3; _b=$4; _e=$5',
        'mkdir -p -- "$_d" || { printf "Emkdir\\0"; exit 1; }',
        '_n=0',
        'while [ "$_n" -lt 10000 ]; do',
        '    if [ "$_n" -eq 0 ]; then NM=$_b$_e; else NM="$_b $_n$_e"; fi',
        '    ln -s -- "$2" "$_d/$NM" 2>/dev/null && { printf "N%s\\0" "$NM"; exit 0; }',
        '    ex "$_d/$NM" || { printf "Eln\\0"; exit 1; }',
        '    _n=$((_n + 1))',
        'done',
        'printf "Efull\\0"; exit 1'
    ].join("\n")

    // saveClipboardImage: DIR STAMP -> "Pasted image STAMP.png" (+ suffix),
    // claimed with noclobber before wl-paste fills it; an empty result (no
    // image on the clipboard) is removed again.
    readonly property string pasteScript: [
        '_d=$1; _b="Pasted image $2"; _e=.png',
        'mkdir -p -- "$_d" || { printf "Emkdir\\0"; exit 1; }',
        '_n=0',
        'while [ "$_n" -lt 10000 ]; do',
        '    if [ "$_n" -eq 0 ]; then NM=$_b$_e; else NM="$_b $_n$_e"; fi',
        '    if ( set -C; : > "$_d/$NM" ) 2>/dev/null; then',
        '        if wl-paste -n -t image/png >> "$_d/$NM" 2>/dev/null && [ -s "$_d/$NM" ]; then printf "N%s\\0" "$NM"; exit 0; fi',
        '        rm -f -- "$_d/$NM"; printf "Enoimage\\0"; exit 1',
        '    fi',
        '    ex "$_d/$NM" || { printf "Ecreate\\0"; exit 1; }',
        '    _n=$((_n + 1))',
        'done',
        'printf "Efull\\0"; exit 1'
    ].join("\n")
    readonly property bool busy: ops._job !== null || ops._queue.length > 0

    property var _queue: []
    property var _job: null
    property bool _pumpQueued: false
    property bool _timedOut: false

    // Queue a job; `front` puts it ahead of everything waiting.
    function enqueue(job, front) {
        const q = ops._queue.slice();
        if (front === true)
            q.unshift(job);
        else
            q.push(job);
        ops._queue = q;
        ops._schedulePump();
    }

    function _schedulePump() {
        if (ops._pumpQueued)
            return;
        ops._pumpQueued = true;
        pumpTimer.restart();
    }
    Timer {
        id: pumpTimer
        interval: 0
        onTriggered: {
            ops._pumpQueued = false;
            ops._pump();
        }
    }

    function _pump() {
        if (ops._job !== null || proc.running)
            return;
        while (ops._queue.length > 0) {
            const q = ops._queue.slice();
            const job = q.shift();
            ops._queue = q;
            const step = ops._advance(job, null);
            if (step) {
                ops._job = job;
                ops._run(step);
                return;
            }
        }
    }

    function _advance(job, res) {
        try {
            return job.next(res) || null;
        } catch (e) {
            console.log("NotesFileOps: a job threw and was ended: " + e + (e && e.stack ? "\n" + e.stack : ""));
            return null;
        }
    }

    function _run(step) {
        const body = ops.prelude + step.script;
        const args = ["setpriv", "--pdeathsig", "TERM", "--", "sh", "-c",
                      step.stdin === null || step.stdin === undefined ? "exec </dev/null\n" + body : body, "sh"];
        const a = step.args || [];
        for (let i = 0; i < a.length; i++)
            args.push(String(a[i]));
        ops._stdinText = step.stdin === null || step.stdin === undefined ? null : String(step.stdin);
        ops._timedOut = false;
        ops._exitSeen = false;
        proc.command = args;
        proc.stdinEnabled = ops._stdinText !== null;
        watchdog.interval = ops.stepTimeoutMs;
        watchdog.restart();
        proc.running = true;
    }
    property var _stdinText: null

    function _finished(code) {
        ops._exitSeen = true;
        watchdog.stop();
        const job = ops._job;
        const buf = outC.data;
        const res = {
            code: code,
            out: buf instanceof ArrayBuffer && buf.byteLength > 0 ? new Uint8Array(buf) : new Uint8Array(0),
            // Qt's own decode of the same bytes: exact at exit (the buffer is
            // whole), and native. A parser takes it when it holds no U+FFFD
            // (then the bytes were clean UTF-8) and falls back to the bytes.
            text: String(outC.text || ""),
            err: String(errC.text || ""),
            timedOut: ops._timedOut
        };
        if (!job)
            return;
        const step = ops._advance(job, res);
        if (step) {
            // The next step of the same job starts from a fresh event, not
            // from inside this process's exit.
            ops._nextStep = step;
            stepTimer.restart();
            return;
        }
        ops._job = null;
        ops._schedulePump();
    }
    property var _nextStep: null
    property bool _exitSeen: true
    Timer {
        id: stepTimer
        interval: 0
        onTriggered: {
            const s = ops._nextStep;
            ops._nextStep = null;
            if (s)
                ops._run(s);
        }
    }

    Timer {
        id: watchdog
        repeat: false
        onTriggered: {
            if (!proc.running)
                return;
            ops._timedOut = true;
            const pid = Number(proc.processId);
            if (pid > 0)
                proc.signal(9);
            else
                proc.running = false;
        }
    }

    Process {
        id: proc
        running: false
        stdout: StdioCollector {
            id: outC
        }
        stderr: StdioCollector {
            id: errC
        }
        onStarted: {
            if (ops._stdinText !== null) {
                proc.write(ops._stdinText);
                proc.stdinEnabled = false;
            }
        }
        // `running` falls AFTER `exited` on a real run; falling with no exit
        // means the child never started (setpriv or sh missing): the step
        // fails with code -1 instead of stalling the queue.
        onRunningChanged: {
            if (!proc.running && !ops._exitSeen && ops._job !== null)
                noStartTimer.restart();
        }
    }
    Timer {
        id: noStartTimer
        interval: 0
        onTriggered: {
            if (!ops._exitSeen && !proc.running)
                ops._finished(-1);
        }
    }
    Connections {
        target: proc
        function onExited(exitCode) {
            ops._finished(exitCode);
        }
    }
}
