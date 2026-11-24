pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../../common/theme"

// =============================================================================
// TerminalBackend.qml
//
// Headless, non-visual terminal backend. Spawns a child process (optionally
// wrapped in script(1) for a real PTY), captures its stdout+stderr, parses
// ANSI SGR escape sequences into styled line segments, exposes a line buffer
// as a ListModel of rich-text rows for direct consumption by a Text delegate
// (textFormat: Text.RichText), and accepts input back to the process stdin.
//
// This component has NO visual presence — it produces data. Wrap it in any
// QML hierarchy that reads `linesModel`, `running`, `exitCode`, and calls
// `start()`, `submit(text)`, `write(bytes)`, `sendInterrupt()`, `stop()`.
//
// Scope is intentionally narrow:
//   - SGR colors + bold/dim/italic/underline (16-color, 256-color, truecolor)
//   - `\r` within a line = overwrite-from-column-0 (last fragment wins)
//   - `\b` = backspace (drop last char of buffer)
//   - All other escape sequences (cursor moves, clear-screen, alt-buffer,
//     OSC, DCS, etc.) are recognised and silently stripped.
//   - Backslash-continuation, word wrap, scroll regions, mouse: out of scope.
//
// The design target is `yay -Syu` and sibling package-manager flows, which
// emit one status-line-per-event punctuated by `\n`. Progress bars that
// animate via `\r` without newlines collapse to their final state on line
// flush, which is the behaviour we want in a popup scrollback.
// =============================================================================
Item {
    id: root

    // -------------------------------------------------------------------------
    // Configuration — set before calling start().
    // -------------------------------------------------------------------------

    // Shell command string. Interpreted by sh -c (useTTY=false) or passed to
    // `script -qefc` (useTTY=true). Use the string form because that's what
    // script(1) expects anyway, and it keeps the API single-shape.
    property string command: ""

    // Allocate a PTY via script(1). Most interactive CLI tools (yay, sudo,
    // pacman-with-progress) require a tty on stdout/stderr/stdin to behave
    // normally; without it, colors disappear, sudo refuses to prompt, and
    // `read` loops exit immediately. Default on.
    property bool useTTY: true

    // ---- PTY size -------------------------------------------------------
    //
    // The PTY `script` allocates inherits the parent's size, and a shell
    // launched without a controlling terminal has none — it reports 0x0, so
    // every program in it falls back to 80 columns. At 80, pacman truncates
    // download filenames to fit ("bubblewrap-0.12....") and prints the
    // COMPACT transaction table, which carries no per-package sizes at all.
    //
    // Both of those are load-bearing here: the truncated names are what the
    // download tracker matches packages by, and the per-package sizes are what
    // weights category progress by data rather than by package count. Neither
    // is recoverable afterwards, so the width is set before the command runs.
    //
    // 200 is wide enough for the longest package name plus every column pacman
    // prints, without making each progress redraw needlessly large. pacman lays
    // its download and install rows out to the terminal's full width: the
    // filename column takes what the longest name needs and the progress bar
    // takes ALL the rest, so a wider terminal stretches the bar. The longest
    // filename in a 157-package run was 56 characters. If a name ever is
    // truncated, the parser's prefix/suffix filename matching still resolves it.
    property int ptyColumns: 200
    property int ptyRows: 50

    // Extra environment to inject. Keys/values as strings.
    // Example: { "SUDO_ASKPASS": "/path", "LANG": "en_US.UTF-8" }
    property var extraEnv: ({})

    // Working directory (empty = inherit).
    property string workingDirectory: ""

    // Debug: if true, every incoming byte chunk is console-logged with
    // control chars escaped. Leave off in production.
    property bool _debugChunks: false

    // Max lines retained in `linesModel`. Older lines are shifted off the
    // front when the cap is exceeded. Keep this conservative — a Text delegate
    // per row inside a ListView is cheap, but the underlying ListModel is not.
    property int scrollbackMax: 2000

    // When true, start() wipes the line buffer just before launching. This
    // is the right timing (not at call time) because rapid stop+start
    // sequences queue: calling clear() from the caller would run now, then
    // the dying old process's tail bytes would land in the fresh buffer
    // before the new run gets to launch. Clearing exactly at launch
    // prevents that window.
    property bool clearOnStart: true

    // If non-empty, raw bytes (before ANSI stripping) are appended to this
    // file as they stream. The caller is responsible for rotating stale logs.
    property string logFilePath: ""

    // -------------------------------------------------------------------------
    // 16-color ANSI palette, from the theme. `ansiBright` is the 8
    // high-intensity slots (90–97 / 100–107).
    //
    // These ARE the kitty palette (~/.config/kitty/themes/eva*.conf),
    // carried as theme tokens, so the popup's terminal and a real kitty
    // window colour yay's output identically in either mode. Still plain
    // properties: a caller may override them.
    //
    // A colour is baked into a line's HTML when the line is parsed, so a
    // theme switch recolours the palette for output that arrives AFTER it.
    // Scrollback that was already coloured keeps the ink it was written in;
    // unstyled text (the great majority) follows `defaultFg` live, because
    // the view sets its own `color` from it.
    // -------------------------------------------------------------------------
    property var ansi: Theme.ansi
    property var ansiBright: Theme.ansiBright

    // Default foreground when no SGR colour is active. The Text delegate
    // should set its own `color` to this, so plain unstyled lines inherit it
    // without HTML markup on every span (smaller model, faster painting).
    property color defaultFg: Theme.terminalFg

    // Monospace font injected into the outer white-space:pre wrapper AND
    // honoured by the host TerminalView on its TextEdit delegate. Setting
    // it here (instead of only on the view) matters because QTextDocument's
    // RichText pipeline picks the font-family from the CSS when present,
    // not from the TextEdit.font — a missing family on font.family would
    // silently fall back to a proportional font, which is why progress-bar
    // closing brackets drift: space glyphs render narrower than `#` glyphs
    // in proportional fonts. Must be a single existing family name — QML
    // `font.family` does not parse CSS-style comma stacks.
    property string fontFamily: "Consolas"

    // -------------------------------------------------------------------------
    // Output — read-only from consumer perspective.
    // -------------------------------------------------------------------------

    // ListModel of { html: "..." } rows. Feed directly into a ListView
    // whose delegate is a Text with textFormat: Text.RichText.
    property alias linesModel: _lines

    property bool running: false
    property int exitCode: -1
    property string lastError: ""

    // Live heuristic: set when the last non-empty line looks like a prompt.
    // `passwordPrompt` says sudo is asking on the TERMINAL. The update's sudo
    // asks through askpass (helpers/update-run.sh), so this only fires for
    // something that bypassed it -- and nothing here takes a password: see
    // submit().
    property bool awaitingInput: false
    property bool passwordPrompt: false
    property string lastPrompt: ""

    signal started()
    signal exited(int code, int status)
    signal lineAppended(string rawLine)  // raw text (no HTML, no ANSI)
    signal previewUpdated(string rawLine) // fires on every transient tail update

    // -------------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------------

    // ---- ATTACH MODE --------------------------------------------------
    //
    // A run the shell does not own. helpers/update-run.sh holds the process,
    // the PTY, the fifo and the systemd inhibitor; this backend only WATCHES
    // it -- `tail -F` on the transcript for output, the fifo for input. The
    // parsing path below is untouched: bytes are bytes, whether they came
    // from a pipe we own or a file somebody else is writing.
    //
    // Why the shell must not own it: Quickshell's `Process` destructor calls
    // kill(), and `Process` is a PostReloadHook, so a CONFIG RELOAD would kill
    // the update mid-transaction. Saving a .qml file is enough.
    property string attachDir: ""
    // The supervisor's pid, from run.json: the root every sudo of the run
    // descends from (the update's AskpassServer checks requests against it).
    property int attachPid: 0
    readonly property bool attached: root.attachDir.length > 0
    readonly property string _fifoPath: root.attachDir + "/stdin.fifo"

    // `pid` is the supervisor's, from run.json. `tail --pid` exits when it
    // does, so the tail's own exit IS the run ending -- no polling, and no
    // watcher on a file that does not exist yet.
    function attach(runDir, supervisorPid) {
        root.attachDir = runDir;
        root.attachPid = supervisorPid > 0 ? supervisorPid : 0;
        root.useTTY = false;
        // -n +1: from the first byte, so the parser rebuilds the whole run.
        // This is the replay path that tools/system_update/replay_yay_log.sh already
        // exercises, pointed at a file that is still growing.
        // `setpriv --pdeathsig TERM`: a child does not die with quickshell unless told to, and a
        // shell that crashes or is SIGKILLed would leave this tail reading the transcript until
        // the run ended (the run is not ours to end, the viewer is: exec keeps the pid ours).
        root.command = "exec setpriv --pdeathsig TERM -- tail -n +1 -F"
            + (supervisorPid > 0 ? " --pid=" + supervisorPid : "")
            + " " + root._shQuote(runDir + "/transcript.log");
        // The logger should report the supervisor's transcript as this run's
        // log; the tee below stays off, because script(1) is already writing
        // that exact file.
        root.logFilePath = runDir + "/transcript.log";
        root.start();
    }

    function start() {
        // Re-entry while a previous run is still tearing down: remember the
        // intent, poke stop(), and let onExited relaunch us. Without this,
        // a user clicking "Run" while the old Process is still shutting
        // down would silently no-op (the running guard would hit TRUE
        // because onExited has not fired yet).
        if (root.running || _proc.running) {
            root._pendingStart = true;
            root.stop();
            return;
        }
        if (!root.command || root.command.length === 0) {
            root.lastError = "empty command";
            return;
        }
        // Clear NOW — after queue-return decisions, right before launch. If
        // we're coming out of a queued restart, any dying bytes from the
        // previous process have now settled (we're past onExited).
        if (root.clearOnStart) {
            _lines.clear();
        }
        root._resetParseState();
        root.lastError = "";
        root.exitCode = -1;
        root.awaitingInput = false;
        root.passwordPrompt = false;
        root.lastPrompt = "";

        // script -q (quiet), -f (flush every write), -e (propagate exit
        // code), -c CMD. /dev/null = don't record to a typescript file.
        // Result: CMD runs under a PTY whose master is piped back to us.
        // Size the PTY from the inside: `script` has no flag for it, and the
        // slave's stty is what the child actually reads.
        const sized = (root.ptyColumns > 0 && root.ptyRows > 0)
            ? "stty cols " + root.ptyColumns + " rows " + root.ptyRows
              + " 2>/dev/null; " + root.command
            : root.command;
        _proc.command = root.useTTY
            ? ["script", "-qefc", sized, "/dev/null"]
            : ["sh", "-c", root.command];
        // Only touch environment when we actually have overrides; assigning
        // an empty hash has been observed to clear inherited PATH on some
        // Quickshell builds, which breaks `script` lookup entirely.
        if (root.extraEnv && Object.keys(root.extraEnv).length > 0) {
            _proc.environment = root.extraEnv;
        }
        if (root.workingDirectory && root.workingDirectory.length > 0) {
            _proc.workingDirectory = root.workingDirectory;
        }
        // StdioCollector.text is REPLACED on each new spawn, not appended —
        // reading its old length in onStarted would leave our diff offset
        // pointing past the end of the new text, silently dropping the
        // leading bytes of every restart. Zero both offsets here, before
        // the child produces anything.
        root._stdoutLen = 0;
        root._stderrLen = 0;
        _proc.running = true;
    }

    function stop() {
        // ATTACHED: the run is not ours to kill. The only thing that reaches
        // it is 0x03 into the fifo -- script(1) hands it to the pty and the
        // line discipline raises SIGINT on the foreground process group,
        // which is the one signal path that reaches root-owned pacman.
        // Killing the tail instead would just blind us to a run still going.
        if (root.attached) {
            if (!_proc.running) return;
            root.write("\x03");
            return;
        }
        if (!_proc.running) return;
        // QProcess.terminate sends SIGTERM to script(1), which doesn't
        // propagate it to the PTY children (sudo, yay, pacman). Send
        // Ctrl-C through the PTY first so the foreground process group
        // sees SIGINT and tears down cleanly. If the child is still alive
        // 800 ms later, escalate to QProcess.terminate via running=false.
        if (root.useTTY) {
            try { _proc.write("\x03"); } catch (e) {}
            _stopEscalate.restart();
        } else {
            _proc.running = false;
        }
    }

    Timer {
        id: _stopEscalate
        interval: 800
        repeat: false
        onTriggered: {
            if (_proc.running) _proc.running = false;
        }
    }

    // Write raw bytes to child stdin (no terminator appended).
    function write(data) {
        if (root.attached) {
            // Only while the run is live. Opening a fifo write-only with no
            // reader BLOCKS -- answering a prompt on a run that has just
            // finished would leak a stuck `sh` per attempt. The tail exits
            // when the supervisor does (`tail --pid`), so `_proc.running` is
            // the same question asked cheaply.
            if (!_proc.running) return;
            _fifoWriter.send(data);
            return;
        }
        if (!_proc.running) return;
        _proc.stdinEnabled = true;
        _proc.write(data);
    }

    // Write text + newline. Use this for Y/n prompts and the like -- NEVER a
    // password: while the terminal's tail is a password prompt this writes
    // nothing. A secret goes through the authentication broker (sudo's
    // askpass), because bytes into a PTY nobody reads as a password land in
    // the next reader, echoed.
    function submit(text) {
        if (root.passwordPrompt) {
            console.warn("TerminalBackend: refused to write to a password prompt");
            return;
        }
        root.write((text === undefined ? "" : text) + "\n");
        // Clear awaiting-input hint optimistically; the next line flush from
        // the process will refresh it.
        root.awaitingInput = false;
        root.passwordPrompt = false;
    }

    // Send Ctrl+C (ETX, 0x03) down the PTY so the child sees SIGINT.
    function sendInterrupt() { root.write("\x03"); }

    function clear() {
        _lines.clear();
        root.trimmedLines = 0;
        // Must also zero the streaming state — otherwise a stale
        // _previewing=true + empty model would make the next _commitLine
        // call _lines.remove(-1) and log a ListModel out-of-range warning
        // (and, worse, leave the model in a weird state so subsequent
        // operations silently misbehave).
        root._tailBuf = "";
        root._previewing = false;
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    ListModel { id: _lines }

    // Short delay between a previous Process teardown and the queued
    // restart. See the onExited handler for the why.
    // Tiny deferral between Process teardown and the queued restart so
    // QProcess finishes its signalling cycle. Empirically 10 ms is fine;
    // 50 ms as a safety margin.
    Timer {
        id: _restartDebounce
        interval: 50
        repeat: false
        onTriggered: root.start()
    }

    // Style state carried across COMMITTED lines — bold / colour set on one
    // line survives into the next until explicitly reset by `\e[0m`. The
    // preview row re-parses using a clone of this so its transient content
    // doesn't pollute the carry.
    property var _carryState: null

    // Intake buffers. StdioCollector accumulates all text; we diff against
    // the last seen length and feed only the new delta into _consumeBytes.
    property int _stdoutLen: 0
    property int _stderrLen: 0

    // Bytes accumulated since the last newline. Rendered as a "preview" row
    // at the tail of linesModel while non-empty; promoted to a committed
    // row when \n arrives.
    property string _tailBuf: ""
    property bool _previewing: false
    // THE PREVIEW ROW IS THE TERMINAL'S CURSOR LINE. While it is up it is
    // always the LAST row of `_lines`, a committed row is inserted ABOVE it,
    // and nothing else may append past it. Removing it on every commit and appending it
    // again when the next chunk arrives would oscillate the document's
    // height by one row several times a second through cargo's
    // build -- the bar flashing in and out at the foot of the terminal, and
    // everything above it stepping a row with it. A terminal has no such gap.
    //
    // `_committedCount` is therefore the end of the real output: the index a
    // new row lands at, and the clamp for every cursor move.
    readonly property int _committedCount: _lines.count - (root._previewing ? 1 : 0)
    // How long the cursor line holds what was on it after the tail goes empty.
    // Erasing a line and drawing the next thing on it is TWO writes, and the
    // PTY read often ends between them: cargo writes "\r" + EL, then the
    // "Compiling" line, ends it with "\r\n" and only then draws the bar
    // again. Blanking the row in that window is the same flash by another
    // route, so what was on the line stays until something overwrites it --
    // as it does on a screen -- and only a line that STAYS empty (the end of
    // the output, not a redraw) takes the row away.
    property int previewLingerMs: 150
    Timer {
        id: _previewLinger
        interval: root.previewLingerMs
        onTriggered: root._dropPreview()
    }
    // The line is being redrawn: keep what is on it and start the clock that
    // takes the row away if nothing comes back. An answered question must not
    // keep the input field open for that long, so the prompt flags go now.
    function _holdPreview() {
        if (root._previewing && !_previewLinger.running) _previewLinger.restart();
        root.awaitingInput = false;
        root.passwordPrompt = false;
    }
    // Take the cursor line away: the output is over, or the model is being
    // rebuilt under it.
    function _dropPreview() {
        _previewLinger.stop();
        if (!root._previewing) return;
        if (_lines.count > 0) _lines.remove(_lines.count - 1);
        root._previewing = false;
        if (root._curRow > _lines.count) root._curRow = _lines.count;
    }
    // Lines dropped from the FRONT of linesModel since start, so a view can
    // map "the n-th line ever" to a model index and keep an append-only copy.
    property int trimmedLines: 0

    // ---- In-place progress rendering -------------------------------------
    // pacman with ParallelDownloads > 1 draws its download block by moving the
    // cursor between lines and rewriting them, emitting NO newline for the
    // whole download phase. In a real capture that is one "line" of 1.5 MB —
    // 82% of an entire 8.7 MB transcript — which means a consumer that only
    // sees committed lines gets no download progress at all, for minutes.
    //
    // `progressPreview` carries the most recently rendered segment (the text
    // after the last carriage return) so a parser can read live progress out
    // of an unterminated line. Throttled, because these arrive thousands of
    // times a second and nothing downstream needs that rate.
    // Carries the last few rendered segments joined by newlines — effectively
    // a snapshot of what is currently on screen. One segment is not enough:
    // the block interleaves per-file rows with a single aggregate
    // "Total (n/m)" row, so sampling only the most recent segment almost
    // always lands on a per-file row and the aggregate is never seen.
    signal progressPreview(string text)

    // Rows that were drawn by CURSOR ADDRESSING rather than terminated by a
    // newline, coalesced to their latest value and emitted on a throttle.
    //
    // pacman's parallel-download block parks a live region on screen (one row
    // per concurrent download plus the aggregate Total) and repaints it in
    // place with CR + CSI row moves, emitting no newline for the whole phase.
    // `lineAppended` therefore never carries a single per-package download row
    // — not because the data is absent, but because it never crosses the
    // newline boundary the line feed is built on. The screen model already
    // reconstructs these as discrete rows for display; this signal routes the
    // same rows to the parser so per-package download state can be read.
    signal screenRows(var rows)
    property int progressPreviewMs: 120
    property int progressPreviewSegments: 40
    // Hard cap on an unterminated line. Without it `_tailBuf += chunk` grows
    // quadratically across a multi-megabyte progress block: every chunk
    // reallocates and copies the whole buffer.
    property int tailMaxChars: 32768
    property string _pendingPreview: ""

    // ---- Screen model (display only) --------------------------------------
    // pacman and makepkg redraw finished lines in place using CPL/CNL
    // (ESC[nF / ESC[nE) rather than newlines. Stripping those escapes and
    // concatenating would turn the repo results into one run-on line —
    //   "core is up to date extra is up to date multilib is up to date:: Starting..."
    // — where a real terminal shows four. It would also make the parallel-download
    // block scroll past as thousands of rows instead of a fixed set updating
    // in place with the "Total (n/m)" row anchored at the bottom.
    //
    // `_curRow` is where the next write lands: an index into `_lines`, or
    // `_lines.count` meaning "append". Cursor moves retarget it; a newline
    // sends it back to the end.
    //
    // Scope note: this drives the DISPLAY only. The parser keeps receiving the
    // original newline-delimited stream, unchanged, so nothing about phase
    // detection or prompt handling depends on this model being perfect.
    property int _curRow: 0
    // Column tracking is deliberately omitted: every in-place rewrite these
    // tools emit starts at column 0 and is followed by EL (erase-to-end), so
    // a cursor move always replaces the whole row. Modelling columns would
    // mean a full cell buffer for no visible gain.
    // Set false to fall back to the newline-only intake, kept as an escape hatch.
    property bool screenModel: true

    // If set, onExited will re-invoke start() once the previous Process has
    // fully torn down. Lets callers blindly call start() without caring
    // whether another run is still mid-exit.
    property bool _pendingStart: false

    function _resetParseState() {
        root._carryState = {
            fg: null, bg: null,
            bold: false, dim: false,
            italic: false, underline: false,
            reverse: false
        };
        root._tailBuf = "";
        _previewLinger.stop();
        root._previewing = false;
        root._curRow = 0;
    }
    Component.onCompleted: root._resetParseState()

    Process {
        id: _proc
        running: false
        stdinEnabled: true

        // StdioCollector (waitForEnd:false) fires textChanged on every buffer
        // arrival, giving us live byte-level streaming. SplitParser only
        // emits on its marker, which would leave prompts without trailing \n
        // (e.g. "Continue? [Y/n] ") and \r-only progress bars sitting in the
        // internal buffer invisible to the model.
        stdout: StdioCollector {
            id: _stdoutCollector
            waitForEnd: false
            onTextChanged: {
                const t = text;
                if (t.length > root._stdoutLen) {
                    const chunk = t.substring(root._stdoutLen);
                    root._stdoutLen = t.length;
                    root._consumeBytes(chunk);
                }
            }
        }
        stderr: StdioCollector {
            id: _stderrCollector
            waitForEnd: false
            onTextChanged: {
                const t = text;
                if (t.length > root._stderrLen) {
                    const chunk = t.substring(root._stderrLen);
                    root._stderrLen = t.length;
                    root._consumeBytes(chunk);
                }
            }
        }

        onStarted: {
            root.running = true;
            // Offsets were already zeroed by start(); leave them alone.
            root.started();
        }
        onExited: (code, status) => {
            // Flush any leftover tail before exit. Some commands finish
            // without a final \n (shells printing a prompt, tools that
            // write a banner and die). We commit whatever's buffered so
            // users don't lose the final message.
            root._dropPreview();
            if (root._tailBuf.length > 0) {
                root._commitLine(root._tailBuf);
                root._tailBuf = "";
            }
            root.running = false;
            // ATTACHED: `code` is the TAIL's exit, which says nothing about
            // the update. The supervisor writes the real one to `exit` when
            // the command ends; blockLoading so it is there to read now.
            if (root.attached) {
                code = root._readExitCode(root.attachDir + "/exit");
                _fifoWriter.close();
            }
            root.exitCode = code;
            root.awaitingInput = false;
            root.passwordPrompt = false;
            root.exited(code, status);

            // Re-fire if a restart was queued while we were shutting down.
            // A same-tick Qt.callLater was observed to spawn the new child
            // which immediately exited with code 0 and no output — Process
            // seems to need a few ms to finalise the previous QProcess
            // teardown before running=true will actually re-spawn. A short
            // debounce resolves it reliably.
            if (root._pendingStart) {
                root._pendingStart = false;
                _restartDebounce.start();
            }
        }
    }

    // -------------------------------------------------------------------------
    // Byte-level intake
    // -------------------------------------------------------------------------

    function _consumeBytes(chunk) {
        if (root._debugChunks) {
            let esc = "";
            for (let i = 0; i < chunk.length; i++) {
                const c = chunk.charCodeAt(i);
                if (c === 0x0D) esc += "\\r";
                else if (c === 0x0A) esc += "\\n";
                else if (c === 0x1B) esc += "\\e";
                else if (c < 0x20) esc += "\\x" + c.toString(16).padStart(2, "0");
                else esc += chunk.charAt(i);
            }
            console.log("[chunk len=" + chunk.length + "] '" + esc + "'");
        }
        // Tee raw bytes (ANSI + all) to the log file. Verbose-mode logs want
        // the unfiltered stream; a parsed version would be lossy.
        if (root.logFilePath && root.logFilePath.length > 0) {
            // NOT when attached: script(1) is already writing that exact
            // file, and two writers on one transcript is a corrupt log.
            if (!root.attached) _logWriter.appendRaw(chunk);
        }

        root._tailBuf += chunk;

        if (root.screenModel) {
            // ONE pass over the buffer with an offset, and each touched row
            // rendered ONCE at the end.
            //
            // The obvious loop — find the next break, slice it off, repeat —
            // rescans the whole remaining buffer every iteration and reslices
            // a multi-megabyte string each time. On the reference capture's
            // 1.5 MB download block (~29 000 cursor moves) that is quadratic
            // and never finishes. Rendering every intermediate state of a row
            // that is about to be overwritten again is wasted too: only the
            // last value of each row in this chunk can be seen.
            const buf = root._tailBuf;
            const touched = ({});          // rowIndex -> latest source
            const order = [];
            // Rows ended by a cursor move, in the order they were drawn.
            //
            // Deliberately a SEQUENCE, not coalesced by row index like
            // `touched` above. Coalescing is right for the display, where only
            // the last value of a row can be seen, but it destroys the time
            // series the parser needs: replaying a capture with `cat` delivers
            // the whole download phase in a handful of chunks, and collapsing
            // by row would turn 26 749 progress rows into 4. Cost is bounded
            // downstream instead — the parser gates every model write on the
            // percent actually changing.
            const screen = [];
            let pos = 0;
            let consumed = 0;
            let brk;
            while ((brk = root._nextRowBreak(buf, pos)) !== null) {
                const seg = buf.substring(pos, brk.index);
                pos = brk.index + brk.length;
                consumed = pos;

                const target = root._curRow;
                // A segment that WRITES NOTHING leaves its row as it was: the
                // cursor passed over it on the way somewhere else. Recording it
                // anyway would blank that row mid-screen, and at the foot it would make
                // an empty one -- a blank line under every package name
                // while pacman stacks its download block ("\r\n" then CPL
                // back up, over and over). The one exception is a newline at
                // the foot: an empty line is output.
                const atFoot = target >= root._committedCount;
                if (!root._writesNothing(seg) || (brk.kind === "nl" && atFoot)) {
                    if (touched[target] === undefined) order.push(target);
                    touched[target] = seg;
                }

                if (brk.kind === "nl") {
                    // Flush pending rows so appends land in stream order.
                    const trimmedBefore = root.trimmedLines;
                    root._flushRows(touched, order);
                    // A newline moves the cursor ONE row down, as a terminal
                    // does -- at the foot that is the next new line, and up
                    // inside a block it is the row under this one, not the end
                    // of the output. The flush may have trimmed scrollback off
                    // the top, which moves every index up with it.
                    const shift = root.trimmedLines - trimmedBefore;
                    root._curRow = atFoot ? root._committedCount
                        : Math.max(0, Math.min(root._committedCount, target + 1 - shift));
                    root._feedParser(seg);
                } else if (brk.kind === "up") {
                    screen.push(seg);
                    root._curRow = Math.max(0, root._curRow - brk.n);
                } else {
                    screen.push(seg);
                    root._curRow = Math.min(root._committedCount, root._curRow + brk.n);
                }
                // Flush in batches so one enormous chunk cannot build an
                // unbounded array before anything is delivered.
                if (screen.length >= root.screenRowBatch) root._emitScreenRows(screen);
            }
            root._flushRows(touched, order);
            root._tailBuf = buf.substring(consumed);
            // Emitted at the END OF THE CHUNK, synchronously — not on a
            // timer. A timer decouples these rows from the newline-delimited
            // lines in the same chunk, and the consumer sees them out of
            // order: replaying a whole capture at once would deliver every install
            // line first, so by the time the download rows arrived every
            // package would already be marked installed and the parser would correctly
            // discard them as stale. Per-chunk emission keeps stream order
            // while still coalescing each row to one value per chunk, which is
            // what bounds the cost — the reference capture repaints 26 749
            // per-package rows over the download phase.
            root._emitScreenRows(screen);
        } else {
            let idx;
            while ((idx = root._tailBuf.indexOf("\n")) >= 0) {
                const line = root._tailBuf.substring(0, idx);
                root._tailBuf = root._tailBuf.substring(idx + 1);
                root._writeRow(line);
                root._curRow = root._committedCount;
                root._feedParser(line);
            }
        }

        // Surface the live render of an unterminated line, and stop the buffer
        // growing without bound while one is in progress.
        if (root._tailBuf.length > 0) {
            const cr = root._tailBuf.lastIndexOf("\r");
            if (cr >= 0) {
                const segs = root._tailBuf.split("\r");
                root._pendingPreview =
                    segs.slice(Math.max(0, segs.length - root.progressPreviewSegments))
                        .join("\n");
                if (!_previewTimer.running) _previewTimer.start();
                // Only trim a buffer that is being redrawn in place; a
                // genuinely long single line must stay intact.
                if (root._tailBuf.length > root.tailMaxChars) {
                    root._tailBuf = root._tailBuf.substring(
                        root._tailBuf.length - Math.floor(root.tailMaxChars / 2));
                }
            }
        }
        root._updatePreview();
    }

    // Largest batch of screen rows delivered in one signal.
    property int screenRowBatch: 512

    function _emitScreenRows(src) {
        if (src.length === 0) return;
        const out = [];
        for (let i = 0; i < src.length; i++) {
            // Strip trailing CRs FIRST, exactly as _writeRow does.
            //
            // A carriage return means "overwrite from column 0", so the ANSI
            // parser correctly discards everything before it. Every in-place
            // progress row ends with one, which would render the row to an
            // empty string and send the whole download phase to the parser as
            // nothing at all. The row's content is what PRECEDES the CR.
            let raw = src[i];
            while (raw.length > 0 && raw.charCodeAt(raw.length - 1) === 0x0D)
                raw = raw.substring(0, raw.length - 1);
            if (raw.length === 0) continue;
            const plain = root._segmentsToPlain(
                root._parseAnsiLine(raw,
                    root._cloneState(root._carryState)).segments);
            if (plain.length > 0) out.push(plain);
        }
        src.length = 0;
        if (out.length > 0) root.screenRows(out);
    }

    Timer {
        id: _previewTimer
        interval: root.progressPreviewMs
        repeat: false
        onTriggered: {
            if (root._pendingPreview.length > 0)
                root.progressPreview(root._pendingPreview);
        }
    }

    // Earliest row break at or after `from`: a newline, or a cursor-row move.
    // Returns {index, length, kind, n} or null. Takes an offset rather than a
    // sliced string so the caller never has to copy the buffer.
    // Does this segment put anything on its row? Carriage returns and escape
    // sequences aside it must have characters -- except an erase (EL), which
    // is a write: it blanks the row on purpose.
    function _writesNothing(seg) {
        if (seg.length === 0) return true;
        if (seg.indexOf("\x1b") < 0) return seg.replace(/\r/g, "").length === 0;
        if (/\x1b\[[0-2]?K/.test(seg)) return false;
        return seg.replace(/\x1b\[[0-9;?]*[@-~]/g, "")
                  .replace(/\x1b[()][A-Za-z0-9]/g, "")
                  .replace(/\r/g, "").length === 0;
    }

    function _nextRowBreak(buf, from) {
        const nl = buf.indexOf("\n", from);
        let best = nl >= 0 ? {index: nl, length: 1, kind: "nl", n: 1} : null;

        // CPL / CNL / CUU / CUD — the only escapes that change row.
        const re = /\x1b\[([0-9]*)([FEAB])/g;
        re.lastIndex = from;
        const m = re.exec(buf);
        if (m && (!best || m.index < best.index)) {
            const n = m[1].length > 0 ? parseInt(m[1]) : 1;
            best = {
                index: m.index, length: m[0].length,
                kind: (m[2] === "F" || m[2] === "A") ? "up" : "down", n: n
            };
        }
        return best;
    }

    // Render the coalesced row writes, in the order the rows were first
    // touched, then clear the pending set.
    //
    // `_curRow` is the LOGICAL cursor being tracked by the scan; writing uses
    // it as the destination, so it must be saved and restored around a flush.
    // Letting the flush leave it pointing at the last row written would make every
    // subsequent cursor move relative to the wrong row, and the cursor would walk
    // away from the screen — which locks the UI thread on the first block of
    // in-place redraws.
    function _flushRows(touched, order) {
        const logical = root._curRow;
        for (let i = 0; i < order.length; i++) {
            const idx = order[i];
            if (touched[idx] === undefined) continue;
            root._curRow = idx;
            root._writeRow(touched[idx]);
            delete touched[idx];
        }
        order.length = 0;
        root._curRow = Math.max(0, Math.min(root._committedCount, logical));
    }

    // Render one row's worth of source and place it at the current cursor row,
    // appending if the cursor is at the end.
    function _writeRow(src) {
        while (src.length > 0 && src.charCodeAt(src.length - 1) === 0x0D)
            src = src.substring(0, src.length - 1);

        const parsed = root._parseAnsiLine(src, root._carryState);
        root._carryState = parsed.state;
        const html = root._segmentsToHtml(parsed.segments);
        const rawText = root._segmentsToPlain(parsed.segments);

        if (root._isNoise(rawText)) return;

        // `_committedCount` is one past the last committed row -- the cursor
        // line, when there is one, sits at that index and stays there.
        let end = root._committedCount;
        if (root._curRow < end) {
            // An in-place rewrite of a row further up; the cursor line is not
            // part of it.
            _lines.set(root._curRow, { html: html, raw: rawText });
            return;
        }
        // WAS THE CURSOR LINE CONSUMED BY THIS ROW, OR ERASED UNDER IT?
        //
        // The program says which, and it says it with an ERASE. A line
        // redrawn in place and then ended -- pacman's "(277/279) checking
        // keys" overwritten by CR up to "(279/279)" and a newline, a read that
        // fell mid-line, a question's echo -- is the SAME line finished: the
        // committed row takes the cursor line's place.
        //
        // A line cleared with EL and then written with something unrelated is
        // a line being made room on: cargo sends "\r" + EL, a "Compiling" line,
        // "\r\n", and only then draws its progress bar again. The bar is coming
        // straight back, so its row stays and the committed line goes ABOVE
        // it; dropping it there and appending it on the next read would take the bar
        // off the foot of the view once per crate.
        //
        // A prefix test would not do: "(279/279) ..." does not start with
        // "(277/279) ...", so the finished row would land above a stale copy of its own earlier state.
        if (root._previewing && _lines.count > 0) {
            const held = _lines.get(_lines.count - 1).raw;
            if (held.length === 0 || !/\x1b\[[0-2]?K/.test(src)) {
                root._dropPreview();
                end = root._committedCount;
            }
        }
        _lines.insert(end, { html: html, raw: rawText });
        root._curRow = end;
        while (_lines.count > root.scrollbackMax) {
            { _lines.remove(0); root.trimmedLines += 1; }
            if (root._curRow > 0) root._curRow -= 1;
        }
    }

    // script(1)'s SIGTERM handler prints these when we stop the process; they
    // belong to script, not to the user's command.
    function _isNoise(rawText) {
        return rawText === "Session terminated, killing shell..."
            || rawText === "...killed."
            || /^Session terminated, killing shell\.\.\.\s*\.\.\.killed\.$/.test(rawText);
    }

    // Feed one newline-delimited line to consumers (parser, prompt hint).
    function _feedParser(line) {
        while (line.length > 0 && line.charCodeAt(line.length - 1) === 0x0D)
            line = line.substring(0, line.length - 1);
        const plain = root._segmentsToPlain(
            root._parseAnsiLine(line, root._cloneState(root._carryState)).segments);
        if (root._isNoise(plain)) return;
        root.lineAppended(plain);
        root._updatePromptHint(plain);
    }

    // Commit one complete line (no trailing \n). Carry state advances
    // permanently; the preview row, if any, is replaced.
    // A tail left without its newline when the child exits: rendered and fed
    // like any other line.
    function _commitLine(line) {
        root._writeRow(line);
        root._feedParser(line);
    }

    // Render whatever is in _tailBuf as the last row (transient). Does NOT
    // advance _carryState — we clone and discard so if the tail is aborted
    // (Ctrl+C, process dies), carry stays consistent.
    function _updatePreview() {
        // STRIP TRAILING CRs FIRST, exactly as _writeRow and _feedParser do.
        //
        // A carriage return means "overwrite from column 0", so the parser
        // correctly throws away everything before the last one -- and a
        // progress line being redrawn in place ENDS with one, which would make the
        // preview row render to nothing for as long as the redraw lasts.
        // Cargo's build line is a CR redraw several times a second, so the
        // verbose view would show a blank row at the foot of the terminal with
        // "Compiling…" flashing through it for the one frame between a chunk
        // arriving and its CR landing. What the row is showing is what
        // PRECEDES the carriage return.
        let buf = root._tailBuf;
        // A row write is FINISHED when it ends in a carriage return, or in an
        // erase: pacman ends "<file> failed to download" with EL instead of a
        // CR, and that row is as complete as it will ever be.
        const finished = buf.length > 0
            && (buf.charCodeAt(buf.length - 1) === 0x0D || /\x1b\[[0-2]?K$/.test(buf));
        while (buf.length > 0 && buf.charCodeAt(buf.length - 1) === 0x0D)
            buf = buf.substring(0, buf.length - 1);

        // THE CURSOR IS UP INSIDE THE SCREEN. A program redrawing a block in
        // place -- pacman's parallel downloads, one row per file and a Total
        // under them, rewritten through CPL/CNL -- leaves its unfinished tail
        // on the row the cursor is ON, not on a new line at the foot. Drawn as
        // the foot's cursor line, every row of the block would take its turn on the
        // last line, cycling rapidly between all currently downloading items.
        // A FINISHED write of that row (above) goes INTO it; one still being
        // typed waits for the read that finishes it, since half a row written
        // over a whole one would flicker the other half. And there is no
        // cursor line at the foot while the cursor is up there.
        if (root._curRow < root._committedCount) {
            root._dropPreview();
            if (finished && !root._writesNothing(buf)) {
                const parsedRow = root._parseAnsiLine(buf, root._cloneState(root._carryState));
                _lines.set(root._curRow, {
                    html: root._segmentsToHtml(parsedRow.segments),
                    raw: root._segmentsToPlain(parsedRow.segments)
                });
            }
            root.awaitingInput = false;
            root.passwordPrompt = false;
            return;
        }

        if (buf.length === 0) {
            root._holdPreview();
            return;
        }
        const snap = root._cloneState(root._carryState);
        const parsed = root._parseAnsiLine(buf, snap);
        const html = root._segmentsToHtml(parsed.segments);
        const rawText = root._segmentsToPlain(parsed.segments);
        // The erase arrived on its own: "\r" + EL is a tail that is not empty
        // and renders to nothing. Writing that over the cursor line blanks it,
        // which is the same flash by another route.
        if (rawText.length === 0) {
            root._holdPreview();
            return;
        }
        _previewLinger.stop();
        if (root._previewing && _lines.count > 0) {
            _lines.set(_lines.count - 1, { html: html, raw: rawText });
        } else {
            _lines.append({ html: html, raw: rawText });
            root._previewing = true;
        }
        root.previewUpdated(rawText);
        root._updatePromptHint(rawText);
    }

    function _cloneState(s) {
        return {
            fg: s.fg, bg: s.bg,
            bold: s.bold, dim: s.dim,
            italic: s.italic, underline: s.underline,
            reverse: s.reverse
        };
    }

    // Detect likely interactive prompts. Heuristic, not exhaustive — this is
    // only a UX hint (show an input field, maybe mask it). The real input
    // handling is always "type + submit", regardless of detection.
    function _updatePromptHint(rawText) {
        const t = rawText.trim();
        if (t.length === 0) return;

        // Sudo password: "[sudo] password for user:", "Password:", "password for root:"
        if (/^\[?sudo\]?\s*password(\s+for\s+\S+)?\s*:/i.test(t)
            || /^password(\s+for\s+\S+)?\s*:/i.test(t)) {
            root.awaitingInput = true;
            root.passwordPrompt = true;
            root.lastPrompt = rawText;
            return;
        }

        // yay / pacman Y/n prompts end with something like "[Y/n]" or "(y/N)"
        if (/\[[yY]\/[nN]\]\s*[:?]?\s*$/.test(t)
            || /\([yY]\/[nN]\)\s*[:?]?\s*$/.test(t)) {
            root.awaitingInput = true;
            root.passwordPrompt = false;
            root.lastPrompt = rawText;
            return;
        }

        root.awaitingInput = false;
        root.passwordPrompt = false;
    }

    // -------------------------------------------------------------------------
    // ANSI SGR parser
    //
    // Input: one logical line (no trailing \n) possibly containing:
    //   ESC [ ... m        SGR (styling)
    //   ESC [ ... <other>  CSI (silently dropped — cursor moves, clear, etc.)
    //   ESC ] ... BEL/ST   OSC (silently dropped)
    //   \r                 reset line buffer — later content overwrites
    //   \b                 backspace
    //   BEL                ignored
    //   everything else    literal text
    //
    // Output:
    //   { segments: [{text, fg, bg, bold, dim, italic, underline, reverse}...],
    //     state:    <terminal style after this line> }
    // -------------------------------------------------------------------------
    function _parseAnsiLine(line, carry) {
        let state = {
            fg: carry ? carry.fg : null,
            bg: carry ? carry.bg : null,
            bold: carry ? carry.bold : false,
            dim: carry ? carry.dim : false,
            italic: carry ? carry.italic : false,
            underline: carry ? carry.underline : false,
            reverse: carry ? carry.reverse : false
        };
        let segments = [];
        let buf = "";
        let i = 0;
        const n = line.length;

        const flush = () => {
            if (buf.length === 0) return;
            segments.push(root._mkSegment(buf, state));
            buf = "";
        };

        while (i < n) {
            const ch = line.charCodeAt(i);

            if (ch === 0x1B) { // ESC
                flush();
                i++;
                if (i >= n) break;
                const kind = line.charAt(i);
                if (kind === "[") { // CSI
                    i++;
                    const paramStart = i;
                    // Parameters: 0x30–0x3F (digits, ;, :, <, =, >, ?)
                    // Intermediates: 0x20–0x2F
                    // Terminator: 0x40–0x7E
                    while (i < n) {
                        const cc = line.charCodeAt(i);
                        if (cc >= 0x40 && cc <= 0x7E) break;
                        i++;
                    }
                    if (i >= n) break;
                    const term = line.charAt(i);
                    const params = line.substring(paramStart, i);
                    i++;
                    if (term === "m") root._applySgr(state, params);
                    // Everything else (K, H, J, A, B, C, D, ...) silently dropped.
                } else if (kind === "]") { // OSC — read until BEL or ST (ESC \)
                    i++;
                    while (i < n) {
                        const cc = line.charCodeAt(i);
                        if (cc === 0x07) { i++; break; }
                        if (cc === 0x1B && i + 1 < n && line.charAt(i + 1) === "\\") { i += 2; break; }
                        i++;
                    }
                } else if (kind === "P" || kind === "X" || kind === "^" || kind === "_") {
                    // DCS / SOS / PM / APC — read until ST.
                    i++;
                    while (i < n) {
                        const cc = line.charCodeAt(i);
                        if (cc === 0x1B && i + 1 < n && line.charAt(i + 1) === "\\") { i += 2; break; }
                        i++;
                    }
                } else if (kind === "(" || kind === ")" || kind === "*" || kind === "+" || kind === "#") {
                    // Designator sequence: ESC ( B, ESC ) 0, etc. Three bytes total.
                    // We've already advanced past ESC and the designator; skip the
                    // charset/arg that follows so it doesn't leak into the buffer
                    // as a literal character.
                    i += 2;
                } else {
                    // Plain two-byte ESC sequence (ESC 7, ESC 8, ESC c, ESC M, ...).
                    i++;
                }
                continue;
            }

            if (ch === 0x0D) {          // CR — overwrite from column 0.
                segments = [];
                buf = "";
                i++;
                continue;
            }
            if (ch === 0x08) {          // BS
                if (buf.length > 0) buf = buf.substring(0, buf.length - 1);
                i++;
                continue;
            }
            if (ch === 0x07) { i++; continue; } // BEL — ignore
            if (ch === 0x00) { i++; continue; } // NUL — ignore

            buf += line.charAt(i);
            i++;
        }
        flush();

        return { segments: segments, state: state };
    }

    function _mkSegment(text, state) {
        return {
            text: text,
            fg: state.fg, bg: state.bg,
            bold: state.bold, dim: state.dim,
            italic: state.italic, underline: state.underline,
            reverse: state.reverse
        };
    }

    // Apply one SGR parameter string (the chars between ESC[ and m) to state.
    function _applySgr(state, params) {
        if (params.length === 0) { // empty = reset
            state.fg = null; state.bg = null;
            state.bold = false; state.dim = false;
            state.italic = false; state.underline = false; state.reverse = false;
            return;
        }
        const parts = params.split(";");
        let i = 0;
        while (i < parts.length) {
            let n = parseInt(parts[i], 10);
            if (isNaN(n)) { i++; continue; }

            if (n === 0) {
                state.fg = null; state.bg = null;
                state.bold = false; state.dim = false;
                state.italic = false; state.underline = false; state.reverse = false;
            }
            else if (n === 1) state.bold = true;
            else if (n === 2) state.dim = true;
            else if (n === 3) state.italic = true;
            else if (n === 4) state.underline = true;
            else if (n === 7) state.reverse = true;
            else if (n === 22) { state.bold = false; state.dim = false; }
            else if (n === 23) state.italic = false;
            else if (n === 24) state.underline = false;
            else if (n === 27) state.reverse = false;
            else if (n >= 30 && n <= 37) state.fg = root.ansi[n - 30];
            else if (n === 38) {
                const next = parseInt(parts[i + 1], 10);
                if (next === 5) {
                    state.fg = root._color256(parseInt(parts[i + 2], 10));
                    i += 2;
                } else if (next === 2) {
                    const r = parseInt(parts[i + 2], 10) || 0;
                    const g = parseInt(parts[i + 3], 10) || 0;
                    const b = parseInt(parts[i + 4], 10) || 0;
                    state.fg = root._rgbHex(r, g, b);
                    i += 4;
                }
            }
            else if (n === 39) state.fg = null;
            else if (n >= 40 && n <= 47) state.bg = root.ansi[n - 40];
            else if (n === 48) {
                const next = parseInt(parts[i + 1], 10);
                if (next === 5) {
                    state.bg = root._color256(parseInt(parts[i + 2], 10));
                    i += 2;
                } else if (next === 2) {
                    const r = parseInt(parts[i + 2], 10) || 0;
                    const g = parseInt(parts[i + 3], 10) || 0;
                    const b = parseInt(parts[i + 4], 10) || 0;
                    state.bg = root._rgbHex(r, g, b);
                    i += 4;
                }
            }
            else if (n === 49) state.bg = null;
            else if (n >= 90 && n <= 97) state.fg = root.ansiBright[n - 90];
            else if (n >= 100 && n <= 107) state.bg = root.ansiBright[n - 100];
            // unknown codes silently skipped
            i++;
        }
    }

    // xterm 256-colour map: 0-15 = ansi + ansiBright, 16-231 = 6×6×6 cube,
    // 232-255 = grayscale.
    function _color256(n) {
        if (isNaN(n)) return null;
        if (n >= 0 && n <= 7) return root.ansi[n];
        if (n >= 8 && n <= 15) return root.ansiBright[n - 8];
        if (n >= 16 && n <= 231) {
            const v = n - 16;
            const r = Math.floor(v / 36);
            const g = Math.floor((v % 36) / 6);
            const b = v % 6;
            const steps = [0, 95, 135, 175, 215, 255];
            return root._rgbHex(steps[r], steps[g], steps[b]);
        }
        if (n >= 232 && n <= 255) {
            const v = 8 + (n - 232) * 10;
            return root._rgbHex(v, v, v);
        }
        return null;
    }

    function _rgbHex(r, g, b) {
        const to2 = (x) => {
            const h = Math.max(0, Math.min(255, x | 0)).toString(16);
            return h.length === 1 ? "0" + h : h;
        };
        return "#" + to2(r) + to2(g) + to2(b);
    }

    // -------------------------------------------------------------------------
    // Segment serialisation
    // -------------------------------------------------------------------------
    function _segmentsToPlain(segs) {
        let out = "";
        for (let i = 0; i < segs.length; i++) out += segs[i].text;
        return out;
    }

    function _htmlEscape(s) {
        // Only escape the HTML metacharacters — spaces stay literal. The
        // outer <span style="white-space:pre"> wrapper (see _segmentsToHtml)
        // is what prevents the RichText renderer from collapsing runs of
        // spaces. Converting to &nbsp; seemed to fix the problem in
        // isolated HTML dumps but column drift persisted at render time,
        // suggesting DejaVu Sans Mono's &#160; glyph advance did not match
        // the regular-space advance — fonts promise nothing about NBSP
        // metrics. Letting the CSS whitespace rule do the preserving sides-
        // steps that entire risk.
        let out = "";
        for (let i = 0; i < s.length; i++) {
            const c = s.charAt(i);
            if (c === "&") out += "&amp;";
            else if (c === "<") out += "&lt;";
            else if (c === ">") out += "&gt;";
            else out += c;
        }
        return out;
    }

    function _segmentsToHtml(segs) {
        if (segs.length === 0) return "";
        // Outer wrapper: `white-space:pre` preserves literal spaces, and
        // `font-family` forces the RichText pipeline to use an actual
        // installed monospace font. Setting only TextEdit.font.family on
        // the delegate is insufficient: QTextDocument's HTML renderer
        // picks font-family from CSS first and falls back to a system
        // proportional font when no CSS family is given. Proportional
        // fonts render space narrower than `#`, which is what shifts
        // progress-bar closing brackets rightward as fills grow.
        let out = "<span style=\"white-space:pre; font-family: '"
                + root.fontFamily + "', monospace;\">";
        for (let i = 0; i < segs.length; i++) {
            const s = segs[i];
            let css = "";
            let fg = s.fg, bg = s.bg;
            if (s.reverse) { const t = fg; fg = bg || root.defaultFg; bg = t; }
            if (fg) css += "color:" + fg + ";";
            if (bg) css += "background-color:" + bg + ";";
            if (s.bold) css += "font-weight:bold;";
            if (s.italic) css += "font-style:italic;";
            if (s.underline) css += "text-decoration:underline;";
            if (s.dim) css += "opacity:0.6;"; // approximation
            const text = root._htmlEscape(s.text);
            if (css.length === 0) out += text;
            else out += "<span style=\"" + css + "\">" + text + "</span>";
        }
        out += "</span>";
        return out;
    }

    function _shQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    // -------------------------------------------------------------------------
    // Log writer — append raw chunks to a file.
    //
    // ONE `cat >> LOG` for the whole run, fed through stdin, closed when the
    // child exits or the path changes. A fresh cat per 200ms batch, its stdin closed
    // each time, would not work: stdinEnabled stays false for every spawn after the first,
    // so every batch after the first would go into a stdin that was never opened
    // (a real run's transcript came out 55 bytes long).
    // -------------------------------------------------------------------------
    // Prompt answers and the abort byte go to the supervisor's fifo. One
    // long-lived `cat`, for the same reason the log writer below is one: a
    // process per write leaves stdinEnabled false after the first spawn and
    // swallows everything after it.
    Item {
        id: _fifoWriter
        property string _openPath: ""
        function send(data) {
            if (!root.attached) return;
            if (!_fifoProc.running || _fifoWriter._openPath !== root._fifoPath) {
                if (_fifoProc.running) _fifoProc.running = false;
                _fifoProc.stdinEnabled = true;
                // The supervisor holds the fifo open read-write, so this
                // open never blocks and closing it never EOFs the child.
                _fifoProc.command = ["sh", "-c", "cat > " + root._shQuote(root._fifoPath)];
                _fifoProc.running = true;
                _fifoWriter._openPath = root._fifoPath;
            }
            _fifoProc.write(data);
        }
        function close() {
            if (_fifoProc.running) {
                _fifoProc.stdinEnabled = false;
                _fifoProc.running = false;
            }
            _fifoWriter._openPath = "";
        }
    }
    Process { id: _fifoProc; running: false }
    // The supervisor's exit file, one FileView per read. The path is a run's own directory, so
    // there is no static path to give a view -- and a FileView loads synchronously on its FIRST
    // path assignment only: a single view repointed at the next run's file hands back
    // the PREVIOUS file's bytes, so the second run of a session would end with the first one's exit code
    // (CLAUDE.md, "A FileView loads synchronously on its FIRST path assignment"). A view made for the
    // one read has only a first assignment. Same shape as SystemUpdateService's `statViewC`.
    Component {
        id: _exitViewC
        FileView {
            blockLoading: true
            printErrors: false
        }
    }
    // -1 when the file is missing or empty (the supervisor was killed before it could write it).
    function _readExitCode(path) {
        const fv = _exitViewC.createObject(root, { path: path }) as FileView;
        const t = fv.text().trim();
        fv.destroy();
        const n = t.length > 0 ? parseInt(t, 10) : -1;
        return isNaN(n) ? -1 : n;
    }

    Item {
        id: _logWriter
        property string _pending: ""
        property string _openPath: ""

        function appendRaw(bytes) {
            _pending += bytes;
            if (!_flushTimer.running) _flushTimer.start();
        }

        function close() {
            if (_logProc.running) {
                _flush();
                _logProc.stdinEnabled = false;   // EOF -> cat exits
            }
            _openPath = "";
        }

        Timer {
            id: _flushTimer
            interval: 200
            repeat: false
            onTriggered: _logWriter._flush()
        }

        Process {
            id: _logProc
            running: false
            stdinEnabled: true
        }

        function _flush() {
            if (!root.logFilePath || root.logFilePath.length === 0) {
                _pending = "";
                return;
            }
            if (_pending.length === 0) return;
            if (_logProc.running && _openPath !== root.logFilePath) {
                // The path moved under us: finish the old file first.
                _logProc.stdinEnabled = false;
                _logProc.running = false;
            }
            if (!_logProc.running) {
                _logProc.stdinEnabled = true;
                _logProc.command = ["sh", "-c",
                    "cat >> " + root._shQuote(root.logFilePath)];
                _logProc.running = true;
                _openPath = root.logFilePath;
            }
            const chunk = _pending;
            _pending = "";
            _logProc.write(chunk);
        }

        Connections {
            target: root
            function onExited(code, status) { _logWriter.close() }
        }
    }
}
