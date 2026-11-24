pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/bar/system_update/components"
import "modules/common/mockup"

// =============================================================================
// mockups/terminal.qml -- the system update's terminal: TerminalBackend (a command on a PTY, its output parsed into
// rows) and TerminalView (those rows on screen, its own wheel reader, the input row and the prompt banner).
//
// The stage is the view at a fixed size, with its input row and banner on (the system update popup turns them off
// and answers prompts itself). The Run tab starts commands: presets from plain colour output to progress bars and
// prompts, a line of your own, and -- behind a second click -- the two that act on the machine (sudo -v, yay -Syu).
// A command runs in a real PTY (script(1)) as you: start nothing here you would not type in a terminal.
//
// Save writes TerminalView's and TerminalBackend's own defaults. The system update sets its own font size, wrap, bold
// and axis ratio (its mockup's Terminal tab) and its own scrollback; the rest reaches it from here.
//
// Env (this file's own): LARES_TERMINAL_AUTOCMD=<command> runs it at load; LARES_TERMINAL_DUMP=1 prints every committed
// line (=html their HTML) to the log; LARES_TERMINAL_DEBUG=1 logs every byte chunk.
//
//   quickshell -p mockups/terminal.qml
// =============================================================================
MockupWindow {
    id: win

    moduleId: "terminal"
    title: "Terminal mockup"
    stageLabel: "TerminalView on its TerminalBackend"
    content: termView
    target: termView
    targets: ({
            backendParams: termBackend
        })
    zoom: 1

    lists: ({
            viewParams: win.viewParams,
            backendParams: win.backendParams
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "View",
            lists: ["viewParams"]
        },
        {
            name: "Backend",
            lists: ["backendParams"]
        }
    ]

    // ---- the backend ---------------------------------------------------------
    property bool logToFile: false
    TerminalBackend {
        id: termBackend
        logFilePath: win.logToFile ? (Quickshell.env("HOME") + "/.cache/lares/terminal-test.log") : ""
        _debugChunks: Quickshell.env("LARES_TERMINAL_DEBUG") === "1"

        onLineAppended: raw => {
            // LARES_TERMINAL_DUMP: a headless run can read what the parser made of a command.
            const mode = Quickshell.env("LARES_TERMINAL_DUMP");
            if (mode === "1")
                console.log("[line] " + raw);
            else if (mode === "html")
                console.log("[html] " + termBackend.linesModel.get(termBackend.linesModel.count - 1).html);
        }
        onPreviewUpdated: raw => {
            const mode = Quickshell.env("LARES_TERMINAL_DUMP");
            if (mode === "1")
                console.log("[preview len=" + raw.length + "] '" + raw + "'");
            else if (mode === "html")
                console.log("[prev-html] " + termBackend.linesModel.get(termBackend.linesModel.count - 1).html);
        }
        onExited: (code, status) => {
            if (Quickshell.env("LARES_TERMINAL_DUMP") === "1")
                console.log("[exited] code=" + code + " status=" + status);
        }
    }
    function run(cmd: string): void {
        termBackend.command = cmd;
        termBackend.start();             // queues behind a running one; clears at launch when clearOnStart
        termView.focusInput();
    }
    Component.onCompleted: {
        const cmd = Quickshell.env("LARES_TERMINAL_AUTOCMD");
        if (cmd && cmd.length > 0)
            win.run(cmd);
    }

    // ---- the drop-in content -----------------------------------------------------
    TerminalView {
        id: termView
        implicitWidth: 900
        implicitHeight: 560
        backend: termBackend
    }

    // The two commands that act on the machine: the first click arms, a second within four seconds runs.
    property string armed: ""
    Timer {
        id: armTimer
        interval: 4000
        onTriggered: win.armed = ""
    }

    // =====================================================================
    //  THE RUN PAGE
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Scenarios"
                blurb: "Commands that show one thing each about how output becomes rows. They read and print only."
            }
            Repeater {
                model: [
                    {
                        name: "ls --color=always /",
                        cmd: "ls --color=always -la /",
                        tip: "Plain lines with SGR colours: the palette of the theme's ANSI slots."
                    },
                    {
                        name: "colour test (SGR sweep)",
                        cmd: "printf '\\033[1mbold\\033[0m \\033[3mitalic\\033[0m \\033[4munderline\\033[0m\\n'; for c in 30 31 32 33 34 35 36 37 90 91 92 93 94 95 96 97; do printf \"\\033[${c}m${c} \\033[0m\"; done; printf '\\n'; for c in 40 41 42 43 44 45 46 47; do printf \"\\033[${c}m  ${c}  \\033[0m \"; done; printf '\\n'",
                        tip: "Bold, italic, underline, the sixteen foreground colours and the eight backgrounds."
                    },
                    {
                        name: "truecolour gradient",
                        cmd: "awk 'BEGIN{for(i=0;i<80;i++){r=int(255*i/80); g=int(255*(80-i)/80); b=128; printf \"\\033[38;2;%d;%d;%dm#\",r,g,b} print \"\\033[0m\"}'",
                        tip: "24-bit colour (SGR 38;2), eighty steps."
                    },
                    {
                        name: "progress bar (CR, fixed width)",
                        cmd: "for i in $(seq 0 20); do printf '\\rProgress [%-20s] %3d%%' \"$(printf '#%.0s' $(seq 1 $i))\" $((i*5)); sleep 0.1; done; echo",
                        tip: "A line redrawn in place with carriage returns: it stays one row and changes under the cursor."
                    },
                    {
                        name: "progress bar (CR, variable width)",
                        cmd: "for i in $(seq 0 20); do printf '\\rProgress [%-20s] %d%%' \"$(printf '#%.0s' $(seq 1 $i))\" $((i*5)); sleep 0.1; done; echo",
                        tip: "The same with a figure that grows a digit: the redraw is shorter than the line it covers until it is not."
                    },
                    {
                        name: "yay -Qua (available updates)",
                        cmd: "yay -Qua",
                        tip: "The AUR updates yay would take, read only."
                    },
                    {
                        name: "checkupdates",
                        cmd: "checkupdates",
                        tip: "The repository updates, read only (pacman's database is copied, never touched)."
                    },
                    {
                        name: "read prompt",
                        cmd: "printf 'Enter value: '; read x; echo You said: $x",
                        tip: "A question with no newline after it: the input row and the banner open for the answer."
                    },
                    {
                        name: "yes/no prompt",
                        cmd: "printf 'Continue? [Y/n] '; read a; case \"${a:-Y}\" in [Yy]*) echo YES ;; *) echo NO ;; esac",
                        tip: "A yes/no question: the banner offers its two shortcuts, the default first."
                    }
                ]
                delegate: TipRow {
                    id: preset
                    required property var modelData
                    tip: preset.modelData.tip
                    Layout.fillWidth: true
                    Button {
                        text: preset.modelData.name
                        Layout.fillWidth: true
                        onClicked: win.run(preset.modelData.cmd)
                    }
                }
            }

            TipGroup {
                title: "Drive"
                blurb: "A command of your own, and the controls of the one that runs."
            }
            TipRow {
                tip: "Runs this line in the PTY as you, as a terminal would (Enter or Run)."
                Layout.fillWidth: true
                TextField {
                    id: customCmd
                    Layout.fillWidth: true
                    placeholderText: "a command line"
                    onAccepted: if (customCmd.text.length > 0) win.run(customCmd.text)
                }
                Button {
                    text: "Run"
                    enabled: customCmd.text.length > 0
                    onClicked: win.run(customCmd.text)
                }
            }
            TipRow {
                tip: "Stop ends the command (its process group); ^C sends an interrupt as a key would; Clear empties the buffer."
                Layout.fillWidth: true
                Button {
                    text: "Stop"
                    Layout.fillWidth: true
                    enabled: termBackend.running
                    onClicked: termBackend.stop()
                }
                Button {
                    text: "^C"
                    Layout.fillWidth: true
                    enabled: termBackend.running
                    onClicked: termBackend.sendInterrupt()
                }
                Button {
                    text: "Clear"
                    Layout.fillWidth: true
                    onClicked: termBackend.clear()
                }
            }

            TipGroup {
                title: "What reaches the machine"
                blurb: "Off until asked: each takes a second click within four seconds."
            }
            TipRow {
                tip: "sudo -v asks for your password (or face) and caches it, as the update's first step does. yay -Syu is a FULL SYSTEM UPDATE, answered at its prompts in the input row. Both act on this machine."
                Layout.fillWidth: true
                Repeater {
                    model: [
                        {
                            name: "sudo -v",
                            cmd: "sudo -v && echo 'sudo cached'"
                        },
                        {
                            name: "yay -Syu (full update)",
                            cmd: "yay -Syu --color=always"
                        }
                    ]
                    delegate: Button {
                        id: realCmd
                        required property var modelData
                        Layout.fillWidth: true
                        text: win.armed === realCmd.modelData.name ? realCmd.modelData.name + " -- click again" : realCmd.modelData.name
                        onClicked: {
                            if (win.armed !== realCmd.modelData.name) {
                                win.armed = realCmd.modelData.name;
                                armTimer.restart();
                                return;
                            }
                            win.armed = "";
                            win.run(realCmd.modelData.cmd);
                        }
                    }
                }
            }
            TipRow {
                tip: "Tees the raw bytes (before ANSI stripping) to ~/.cache/lares/terminal-test.log as they stream, for a capture."
                Layout.fillWidth: true
                CheckBox {
                    text: "tee to ~/.cache/lares/terminal-test.log"
                    checked: win.logToFile
                    onToggled: win.logToFile = checked
                }
            }

            TipGroup {
                title: "State"
                blurb: "What the backend holds now."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "running " + termBackend.running + "   exit code " + termBackend.exitCode + "   lines " + termBackend.linesModel.count
                      + "\nawaiting input " + termBackend.awaitingInput + (termBackend.passwordPrompt ? " (password)" : "")
                      + "\nlast prompt: " + termBackend.lastPrompt
                      + (termBackend.lastError.length > 0 ? "\nlast error: " + termBackend.lastError : "")
                color: termBackend.lastError.length > 0 ? "#EC0000" : "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
            }
        }
    ]

    readonly property var viewParams: [
        {
            label: "font px",
            prop: "fontPixelSize",
            group: "Text",
            blurb: "How the output is set.",
            tip: "Pixel size of the output's monospace face. 13 is this view's own; the system update sets its own (its Terminal tab).",
            val: 13,
            from: 8,
            to: 28,
            step: 1
        },
        {
            label: "bold",
            prop: "fontBold",
            group: "Text",
            tip: "On: the output in bold, as the desktop's kitty draws its Consolas. The system update sets its own.",
            val: true
        },
        {
            label: "wrap lines",
            prop: "wrapLines",
            group: "Text",
            tip: "On: long lines wrap. Off: they run off the right edge and the view scrolls sideways (a two-finger swipe or a tilt wheel), with no scrollbar. The system update sets its own.",
            val: false
        },
        {
            label: "margin px",
            prop: "contentMargin",
            group: "Text",
            tip: "Space between the view's edge and its text, px.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "notch lines",
            prop: "wheelStepMultiplier",
            group: "Scroll",
            blurb: "The view's one wheel reader: a motion keeps one axis until the fingers lift.",
            tip: "How many of the shell's notches a mouse notch moves: 3 brings dense terminal output close to a native terminal's scroll. A touchpad follows the fingers and is not scaled.",
            val: 3,
            from: 1,
            to: 8,
            step: 0.5
        },
        {
            label: "sideways notch",
            prop: "hWheelStepMultiplier",
            group: "Scroll",
            tip: "The same for a sideways notch (a tilt wheel).",
            val: 6,
            from: 1,
            to: 12,
            step: 0.5
        },
        {
            label: "axis ratio",
            prop: "wheelAxisRatio",
            group: "Scroll",
            tip: "How far one axis must be ahead of the other before a motion locks to it. The system update sets its own.",
            val: 1.4,
            from: 1,
            to: 4,
            step: 0.1
        },
        {
            label: "motion idle ms",
            prop: "wheelIdleMs",
            group: "Scroll",
            tip: "Ends a motion that never sends the fingers-lifted event (a mouse wheel sends none), ms.",
            val: 140,
            from: 40,
            to: 600,
            step: 10
        },
        {
            label: "live tail rows",
            prop: "liveTailRows",
            group: "Cost",
            blurb: "What the view keeps rebuilding.",
            tip: "How many rows at the end of the output are still live (a program may rewrite them by moving the cursor); older ones are final and are never rebuilt. A screen's worth: cursor addressing reaches no further back.",
            val: 64,
            from: 16,
            to: 256,
            step: 1
        }
    ]

    readonly property var backendParams: [
        {
            label: "PTY",
            prop: "useTTY",
            group: "Process",
            blurb: "How the command is run.",
            tip: "On: the command runs on a PTY (script(1)): yay, sudo and pacman need a terminal to colour, prompt and draw progress. Off: plain pipes.",
            val: true
        },
        {
            label: "columns",
            prop: "ptyColumns",
            group: "Process",
            tip: "The PTY's width in columns. pacman lays its download and install rows to the full width and truncates names to fit; 200 keeps the longest package names whole.",
            val: 200,
            from: 80,
            to: 300,
            step: 1
        },
        {
            label: "rows",
            prop: "ptyRows",
            group: "Process",
            tip: "The PTY's height in rows.",
            val: 50,
            from: 20,
            to: 100,
            step: 1
        },
        {
            label: "clear on start",
            prop: "clearOnStart",
            group: "Process",
            tip: "On: a start empties the buffer at the launch itself, so the tail of a dying run cannot land in the new one.",
            val: true
        },
        {
            label: "scrollback",
            prop: "scrollbackMax",
            group: "Buffer",
            blurb: "What the backend keeps of the output.",
            tip: "Lines kept; older ones drop off the front. The system update keeps its own 5000.",
            val: 2000,
            from: 200,
            to: 10000,
            step: 100
        },
        {
            label: "tail cap",
            prop: "tailMaxChars",
            group: "Buffer",
            tip: "Characters kept of an unterminated line: a multi-megabyte progress block would otherwise grow the buffer quadratically.",
            val: 32768,
            from: 4096,
            to: 131072,
            step: 1024
        },
        {
            label: "linger ms",
            prop: "previewLingerMs",
            group: "Live line",
            blurb: "The line under the cursor, redrawn in place.",
            tip: "How long the cursor line keeps what was on it after the tail goes empty, ms: erasing a line and drawing the next thing on it are two writes, often in two reads.",
            val: 150,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "preview ms",
            prop: "progressPreviewMs",
            group: "Live line",
            tip: "How often the in-place progress text is handed on, ms: it arrives thousands of times a second and nothing downstream needs that rate.",
            val: 120,
            from: 20,
            to: 1000,
            step: 10
        },
        {
            label: "preview segments",
            prop: "progressPreviewSegments",
            group: "Live line",
            tip: "How many of the last redrawn segments the preview carries, so a parser sees the Total row of a download block and not only the per-file rows.",
            val: 40,
            from: 1,
            to: 100,
            step: 1
        }
    ]
}
