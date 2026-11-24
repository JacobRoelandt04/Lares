pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// CurlRequest.qml
//
// ONE HTTP POST through a `curl` child, streamed to the owner line by line,
// and KILLABLE -- which is the whole reason it exists. Qt's QML XMLHttpRequest
// cannot close a socket: `abort()` detaches the callbacks and the connection
// stays up until the process exits, so a server that stops work when its
// client goes away (Ollama abandons a load, a prompt evaluation or a
// generation on a disconnect) never hears one. A signal to this child closes
// its socket, and the server's request ends in the same millisecond
// (measured, Ollama 0.34.2: it logged `context for request
// finished` within 1 ms of SIGTERM, SIGKILL, `running = false` and
// `destroy()` alike).
//
// Generic: nothing here knows about LLMs. Create one per request with
// `Component.createObject(owner, { url, body })`, connect `line` and `done`,
// call `begin()`, and `destroy()` it after `done`.
//
//     line(text)  every body line, in order, trailing "\r" stripped
//     done(r)     exactly once: { httpStatus, exitCode, killed, signalled,
//                                 startFailed, stderr }
//       httpStatus   0 when no response came (refused, unresolved, killed)
//       killed       WE killed it through kill(); the owner asked, so the
//                    owner already knows what that means
//       signalled    the child died of a signal (killed or not -- a kill we
//                    did not send is still an ending nobody asked for)
//       startFailed  curl never ran (not installed, bad argv, or setpriv
//                    could not exec it -- see "A quickshell that DIES")
//       stderr       curl's last stderr line, "curl: (7) Failed to connect ..."
//
// WHAT EACH LINE BELOW IS FOR (all measured):
//   * `-N`: without it curl buffers a pipe and frames arrive in ~400 ms
//     bursts (first frame 389 ms instead of 49); with it one line per token,
//     the first-to-last span equal to the server's own eval_duration.
//   * THE STATUS IS A MARKER ON STDOUT: `-w "<U+001E>LARESHTTP %{http_code}\n"`
//     arrives after every body line and before `exited`, every time. It
//     cannot go to stderr (`%{stderr}` has no ordering against stdout: for a
//     404 it came BEFORE the body) nor come from `-i` (CR-terminated headers
//     and a `100 Continue` block for big bodies). It is read at the END of a
//     line, not as a line of its own: an error body with no trailing newline
//     -- Ollama's 404 is exactly that -- runs straight into it, and the text
//     in front of it is that body's last line. The owner sees body lines
//     only. (A "\n" put in front of the marker would end such a body, but
//     after a body that DID end in one it makes an empty line which has to
//     be held until the next line says whether the marker followed -- so
//     every REAL empty line would be held too, SSE's event ends included,
//     and reach the owner one line late.) U+001E has to be a
//     REAL character in argv; `-w` interprets only \n \r \t, and '\036'
//     came out literally. JSON never carries it raw (a control character
//     must be escaped), so no JSON body line ends in the marker.
//   * THE BODY GOES ON STDIN, NEVER ON ARGV. Linux caps one argv string at
//     128 KiB, a turn with pages and screenshots is far past that, and argv
//     is readable in /proc/<pid>/cmdline by anything on the machine. So
//     `--data-binary @-`, `stdinEnabled` set true BEFORE `running`, the body
//     written in `onStarted` and the channel closed by setting it false
//     again. A Process started with the default `stdinEnabled: false` leaves
//     the child's stdin open FOR EVER: curl reads all of stdin before it
//     connects, and hung until the flag flipped (3003 ms later, to the ms).
//     A 6 MB body: write 2 ms, received intact 17 ms after start.
//   * `-H "Expect:"`: past 1 MB curl sends `Expect: 100-continue` and waits
//     for the server's go-ahead. Removing the header changed nothing
//     measurable on a 6 MB body (48-53 ms either way); it is one handshake
//     fewer for a server to get wrong.
//   * `-q` first among curl's arguments: no ~/.curlrc (none exists) can
//     change the request.
//   * NO `--max-time`: an answer can take minutes. `--connect-timeout` bounds
//     only the connect (exit 28 on a blackholed host).
//   * The reader is `SplitParser`, NOT StdioCollector. SplitParser buffers
//     bytes and decodes whole lines, so no U+FFFD for a character split
//     across reads (checked inside é, 😀 and 中, and on a child killed
//     mid-character); StdioCollector's `text` showed "caf�" first and
//     cost ~10x the CPU (a 28 MB stream: 1.1 s against 11.7 s). A 4 MB
//     single line (a tool call's one frame) came through in one read.
//     BUT ITS SLICES ARE NOT ALWAYS LINES (Quickshell 0.3.1, measured):
//     an EMPTY line that follows another line in the SAME read
//     is never emitted, and the slice after it starts with its "\n" --
//     "a\n\nb\n" written at once reads "a", "\nb"; "b\n\n\nc\n" reads "b",
//     "\n", "c". NDJSON has no empty lines and never showed it; SSE ends
//     EVERY event with one (unsplit, the OpenAI path parsed nothing past its
//     first event). `_onOut` splits every slice on "\n" again, which
//     restores the lines -- but not their TIMING: an empty line that ENDS a
//     read comes out only with the NEXT read ("a\n\n", 500 ms, "b\n" reads
//     "a" at once and "\nb" 500 ms later), and Ollama writes each SSE event
//     as one `data: ...\n\n`. So an owner must never wait for an empty line
//     to act (LlmBackend dispatches an SSE event on its whole payload). A
//     CRLF empty line is "\r" to SplitParser, not empty, and is never held.
//   * Proxies: curl honours http_proxy / https_proxy / no_proxy from the
//     environment like any CLI. This machine sets none, so none is added
//     or overridden here.
//
// QUICKSHELL 0.3.1 PROCESS FACTS this file is built around (all measured):
//   * a child that never starts gets NO `exited` -- only `running` falling
//     to false with no `started` before it. That is settled as
//     `startFailed`, one tick later so `done` never fires inside begin().
//   * every stdout line (a final unterminated one included) and the stderr
//     tail arrive BEFORE `exited`, so `done` is emitted from `exited`.
//   * `exited(code, status)`: status 1 is death by a signal, and then the
//     code IS the signal number (15, 9) -- which collides with curl's own
//     codes (6 is both "could not resolve" and SIGABRT), hence `signalled`.
//   * `signal(15)` and `running = false` are both SIGTERM, and neither ever
//     escalates; curl does not ignore TERM. kill() sends TERM and arms a
//     SIGKILL a second later as a belt real curl has never needed (a stand-in
//     that ignores TERM was ended by it 1002 ms after kill()).
//   * `destroy()` on a running Process SIGKILLs the child and emits nothing.
//     So an owner that is destroyed aborts its requests ON THE SERVER, which
//     is what a destroyed owner should do.
//   * A quickshell that DIES destroys nothing: 0.3.1 installs no handler for
//     SIGTERM or SIGHUP (it exits 143 / 129) and a crash runs no teardown,
//     so curl, reparented to PID 1, keeps its socket open until the server
//     next writes to it -- which in a cold load or a non-streaming request
//     is after the server has done all the work. So curl is exec'd through
//     util-linux `setpriv --pdeathsig TERM`, and the KERNEL signals it when
//     its parent dies: measured, the server saw the connection close 1-2 ms
//     after a SIGTERM or SIGHUP to quickshell and 27 ms after a SIGSEGV (its
//     crash handler runs first), where without it the orphan was still
//     connected a second later. setpriv execs curl in place, so
//     `processId`, `signal()` and `exited` are curl's own; when it cannot
//     exec curl it exits 127 (not found) or 126 (not executable), codes curl
//     never uses, and that is settled as `startFailed`. (The death signal
//     follows the THREAD that forked; a Process starts from the GUI thread,
//     which lives as long as the process.)
//   * `processId` is null again by the time `exited` fires.
//   * An inline `onExited: (code, status) =>` makes qmllint warn about
//     QProcess::ExitStatus; the Connections below is the LlmTools idiom.
//   * `running` is assigned, never bound: a binding would restart the child.
// No systemd scope (LlmTools needs one because its tools fork): curl is one
// process, its DNS lookup a thread, and a signal to its pid ended the
// server's request every time.
// =============================================================================
Process {
    id: root

    // ---- Request -----------------------------------------------------------
    property string url: ""
    property string body: ""                // written on stdin, never on argv
    property var    headers: ["Content-Type: application/json"]
    property int    connectTimeoutS: 5

    signal line(string text)
    signal done(var r)

    // ---- Internal ----------------------------------------------------------
    readonly property string _marker: "\u001eQSHTTP "
    property bool   _begun: false
    property bool   _sawStarted: false
    property bool   _exited: false
    property bool   _killed: false
    property bool   _settled: false
    property int    _httpStatus: 0
    property string _lastErr: ""
    property var    _pending: null          // a startFailed/killed result for _later

    running: false
    stdout: SplitParser { onRead: data => root._onOut(data) }
    stderr: SplitParser { onRead: data => root._onErr(data) }

    onStarted: {
        root._sawStarted = true;
        root.write(root.body);
        // Closing the write channel is curl's EOF; it sends nothing before it.
        root.stdinEnabled = false;
    }
    onRunningChanged: { if (!root.running) root._onStopped(); }

    property Connections _exitWatch: Connections {
        target: root
        function onExited(exitCode, exitStatus) { root._onExited(exitCode, exitStatus); }
    }
    property Timer _belt: Timer {
        interval: 1000
        repeat: false
        onTriggered: root._escalate()
    }
    property Timer _later: Timer {
        interval: 0
        repeat: false
        onTriggered: {
            const r = root._pending;
            root._pending = null;
            if (r) root._settle(r);
        }
    }

    // Starts the request. Once; a second call does nothing.
    function begin() {
        if (root._begun) return;
        root._begun = true;
        if (root._killed) {                 // killed before it was ever begun
            root._settleLater(false);
            return;
        }
        const argv = ["setpriv", "--pdeathsig", "TERM", "--",
                      "curl", "-q", "-sS", "-N", "--connect-timeout", String(root.connectTimeoutS)];
        const hs = root.headers || [];
        for (let i = 0; i < hs.length; i++) argv.push("-H", String(hs[i]));
        argv.push("-H", "Expect:", "--data-binary", "@-",
                  "-w", root._marker + "%{http_code}\n", root.url);
        root.command = argv;
        root.stdinEnabled = true;
        root.running = true;
    }

    // SIGTERM now, SIGKILL after 1000 ms if the child is somehow still there.
    // Idempotent, safe from inside a `line` handler (not one more line is
    // emitted after it), and a no-op once the child has exited. `done` still
    // fires, with `killed: true`.
    function kill() {
        if (root._killed || root._exited || root._settled) return;
        root._killed = true;
        if (!root._begun) return;           // begin() settles it without a child
        // signal() only with a real pid: kill(0, sig) would signal OUR OWN
        // process group. `running = false` is the same SIGTERM (measured) and
        // is safe in every state.
        const pid = Number(root.processId);
        if (pid > 0) root.signal(15);
        else root.running = false;
        root._belt.restart();
    }

    function _escalate() {
        if (root._exited || root._settled) return;
        const pid = Number(root.processId);
        if (pid > 0) root.signal(9);
    }

    // SplitParser's slices are not always lines (see the header): an empty
    // line that follows another line in the same read is folded into the
    // NEXT slice as a leading "\n". A slice never contains a delimiter that
    // SplitParser acted on, so every "\n" in one is that artefact, and
    // splitting on it gives back the lines exactly ("\nb" -> "", "b";
    // "\n" -> "", ""). A later Quickshell that fixes it simply never takes
    // the slow path.
    function _onOut(data) {
        const s = String(data);
        if (s.indexOf("\n") < 0) { root._onLine(s); return; }
        const parts = s.split("\n");
        for (let i = 0; i < parts.length; i++) {
            if (root._killed) return;
            root._onLine(parts[i]);
        }
    }

    // The status marker ends the LAST line curl writes: alone after a body
    // that ended in "\n", glued to the tail of one that did not.
    function _onLine(raw) {
        if (root._killed) return;
        let t = raw;
        const at = t.lastIndexOf(root._marker);
        if (at >= 0 && /^[0-9]{3}$/.test(t.substring(at + root._marker.length))) {
            root._httpStatus = parseInt(t.substring(at + root._marker.length), 10);
            if (at === 0) return;
            t = t.substring(0, at);
        }
        if (t.length > 0 && t.charCodeAt(t.length - 1) === 13) t = t.substring(0, t.length - 1);
        root.line(t);
    }

    // The last non-empty stderr line (the same slice artefact as stdout).
    function _onErr(data) {
        const parts = String(data).split("\n");
        for (let i = 0; i < parts.length; i++)
            if (parts[i].length > 0) root._lastErr = parts[i];
    }

    function _onExited(exitCode, exitStatus) {
        root._exited = true;
        root._belt.stop();
        const signalled = Number(exitStatus) === 1;
        // setpriv's own exits: curl could not be exec'd (127 not found, 126
        // not executable). curl ran if it exited any other way.
        const noCurl = !signalled && (exitCode === 126 || exitCode === 127);
        root._settle({ httpStatus: root._httpStatus, exitCode: exitCode,
                       signalled: signalled, startFailed: noCurl,
                       stderr: root._lastErr });
    }

    // `running` fell. After a real run that is AFTER `exited` and settles
    // nothing; with no `started` before it, curl never ran.
    function _onStopped() {
        if (!root._begun || root._sawStarted || root._exited || root._settled || root._pending) return;
        root._settleLater(true);
    }

    function _settleLater(startFailed) {
        root._pending = { httpStatus: 0, exitCode: -1, signalled: false,
                          startFailed: startFailed, stderr: root._lastErr };
        root._later.restart();
    }

    function _settle(r) {
        if (root._settled) return;
        root._settled = true;
        root._belt.stop();
        r.killed = root._killed;
        root.done(r);
    }
}
