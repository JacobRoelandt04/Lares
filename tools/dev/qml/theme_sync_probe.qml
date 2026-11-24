pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/components"
import "modules/common/theme"
import "modules/bar/system_update/components"

// =============================================================================
// tools/dev/qml/theme_sync_probe.qml
//
// Does the WHOLE surface finish switching light<->dark at the same moment?
//
// Enumerating the colours by hand cannot answer that: the fault is a second
// animation clock somewhere below the theme, and the whole point is that you
// do not know where. So this measures pixels instead. It lays out one of
// every themed piece the system-update popup is built from -- including the
// states one run cannot show at once (a favourite, a failed row, a disabled
// button) -- toggles the mode, and grabs four frames.
//
// The popup ITSELF is not in here: `grabToImage` never calls back with it in
// the subtree (it starts, and no frame ever arrives), so the run would hang
// rather than fail honestly. Its own composition is covered by the static
// half of tools/dev/theme_sync_probe.sh, which fails if any file in its
// dependency closure animates a colour again.
//
// The four frames:
//
//   mid    at fadeMs/2      -- proof the fade is actually running, so a probe
//                             that measures nothing cannot pass
//   settle at fadeMs + slack
//   final  at fadeMs + 1400
//   final2 200ms after final -- pixels that differ between these two are
//                             animating for reasons of their own (the
//                             skeleton pulses forever, the rail's ball
//                             breathes) and are masked out of the comparison
//
// Outside that mask, `settle` and `final` must be IDENTICAL. Any pixel that
// still moves after the fade is over is something chasing the theme on a
// clock of its own. tools/dev/theme_sync_probe.sh does the comparison and names
// where.
//
//   tools/dev/theme_sync_probe.sh [outdir]
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 900
        implicitHeight: 620
        visible: true
        color: Theme.surface

        readonly property int fadeMs: Theme.fadeMs
        readonly property int slack: Number(Quickshell.env("SLACK_MS") || 80)
        readonly property string outDir: Quickshell.env("OUT_DIR") || "/tmp/theme_sync"

        // A row entry, and the status resolver the popup hands its rows.
        readonly property var pkg: ({
                name: "linux",
                oldVer: "6.18.9.arch1-1",
                newVer: "6.18.10.arch1-1"
            })
        readonly property var favPkg: ({
                name: "qt6-base",
                oldVer: "6.11.1-1",
                newVer: "6.11.2-1",
                isFavorite: true
            })

        Item {
            id: shot
            anchors.fill: parent

            Rectangle {
                anchors.fill: parent
                color: Theme.surface
            }

            Column {
                x: 16
                y: 16
                width: parent.width - 32
                spacing: 14

                // ---- the segmented selector (raised pill on a carved track)
                TabSelector {
                    width: 300
                    height: 32
                    tabs: [
                        {
                            id: "quiet",
                            label: "quiet"
                        },
                        {
                            id: "normal",
                            label: "normal"
                        },
                        {
                            id: "verbose",
                            label: "verbose"
                        }
                    ]
                    currentTab: "normal"
                    swipeEnabled: false
                    trackSurfaceColor: Theme.surface
                    trackBevelColor: Theme.border
                    trackShadowColor: Theme.headerBoxShadow
                    trackBackgroundColor: Theme.panelSunk
                    pillSurfaceColor: Theme.panelSunk
                    pillBevelColor: Theme.accentBevel
                    pillShadowColor: Theme.buttonShadow
                    pillBackgroundColor: Theme.accent
                    textColor: Theme.textPrimary
                    activeTextColor: Theme.textOnAccent
                }

                // ---- the rail, mid-run
                PhaseRail {
                    width: parent.width
                    height: implicitHeight
                    particlesEnabled: false
                    steps: [
                        {
                            key: "sync",
                            label: "Sync"
                        },
                        {
                            key: "resolve",
                            label: "Resolve"
                        },
                        {
                            key: "download",
                            label: "Download"
                        },
                        {
                            key: "install",
                            label: "Install"
                        }
                    ]
                    currentKey: "download"
                    stepProgress: 0.5
                    // Idle: the ball keeps the run's tone but holds still, so
                    // the rail is measured rather than masked.
                    active: false
                    textColor: Theme.textPrimary
                    mutedColor: Theme.textMuted
                    faintColor: Theme.textFaint
                    accentColor: Theme.accent
                    doneColor: Theme.ok
                    errorColor: Theme.error
                    surfaceColor: Theme.surface
                    grooveColor: Theme.panelSunk
                    grooveBevelColor: Theme.bevel
                    grooveShadowColor: Theme.border
                    ballShadowColor: Theme.ballShadow
                }

                // ---- buttons: plain, accent, disabled
                Row {
                    spacing: 10
                    Repeater {
                        model: [
                            {
                                t: "Yes",
                                a: true,
                                e: true
                            },
                            {
                                t: "No",
                                a: false,
                                e: true
                            },
                            {
                                t: "Exclude",
                                a: true,
                                e: false
                            }
                        ]
                        delegate: RaisedButton {
                            required property var modelData
                            text: modelData.t
                            accent: modelData.a
                            enabled: modelData.e
                            surfaceColor: Theme.listBox
                            plateauColor: Theme.buttonPlateau
                            plateauHoverColor: Theme.buttonPlateauHover
                            bevelColor: Theme.buttonBevel
                            shadowColor: Theme.buttonShadow
                            accentColor: Theme.accent
                            accentHoverColor: Theme.accentHover
                            accentBevelColor: Theme.accentBevel
                            textColor: Theme.textPrimary
                            faintTextColor: Theme.textFaint
                            accentTextColor: Theme.textOnAccent
                        }
                    }
                }

                // ---- the carved list, with the rows whose stripes are the
                //      thing that was first noticed lagging
                ShadowBox {
                    width: parent.width
                    height: rowCol.implicitHeight + 16
                    baseRadius: 14
                    surfaceColor: Theme.surface
                    bevelColor: Theme.bevel
                    shadowColor: Theme.border
                    backgroundColor: Theme.listBox
                    bevelWidth: 1
                    shadowWidth: 3

                    Column {
                        id: rowCol
                        x: 8
                        y: 8
                        width: parent.width - 16
                        spacing: 2

                        ListSectionHeader {
                            width: parent.width
                            title: "Core"
                            subtitle: "2 packages"
                            accentColor: Theme.catCore
                            textColor: Theme.textPrimary
                            mutedColor: Theme.textMuted
                            faintColor: Theme.textFaint
                            boxColor: Theme.headerBox
                            boxSurfaceColor: Theme.listBox
                            boxBevelColor: Theme.headerBoxBevel
                            boxShadowColor: Theme.headerBoxShadow
                            errorColor: Theme.error
                        }

                        Repeater {
                            // idle / favourite / mid-download / done / failed:
                            // every branch the stripe and the icon pick from.
                            // runState and dlPct come off the entry, so the
                            // five states are five entries.
                            model: [
                                win.pkg,
                                win.favPkg,
                                Object.assign({}, win.pkg, {
                                    runState: "active",
                                    dlPct: 60
                                }),
                                Object.assign({}, win.pkg, {
                                    runState: "done"
                                }),
                                Object.assign({}, win.pkg, {
                                    runState: "failed"
                                })
                            ]
                            delegate: UpdatePackageRow {
                                required property var modelData
                                width: rowCol.width
                                entry: modelData
                                stepStatusFor: (st, isAur) => st
                                iconGlyph: ""
                                categoryColor: Theme.catCore
                                textColor: Theme.textPrimary
                                mutedColor: Theme.textMuted
                                faintColor: Theme.textFaint
                                errorColor: Theme.error
                                mutedGroundColor: Theme.listBox
                            }
                        }
                    }
                }

                // ---- the silhouette
                ShadowBox {
                    width: parent.width
                    height: 96
                    baseRadius: 14
                    surfaceColor: Theme.surface
                    bevelColor: Theme.bevel
                    shadowColor: Theme.border
                    backgroundColor: Theme.listBox
                    bevelWidth: 1
                    shadowWidth: 3

                    ListSkeleton {
                        anchors.fill: parent
                        headerCount: 2
                        rowsUnderFirst: 1
                        // Still, so its pixels can be judged rather than
                        // masked out as self-animating.
                        pulse: false
                        boxColor: Theme.headerBox
                        barColor: Theme.listBox
                        rowBarColor: Theme.headerBox
                    }
                }
            }
        }

        // ---- the measurement ------------------------------------------------
        function grab(name, done) {
            const started = shot.grabToImage(function (r) {
                r.saveToFile(win.outDir + "/" + name + ".png");
                console.log("SYNC grabbed " + name);
                if (done)
                    Qt.quit();
            });
            if (!started)
                console.log("SYNC grab(" + name + ") refused -- not rendering");
            if (done)
                quitFallback.start();
        }
        // The last grab's callback only arrives if the window is presenting.
        // Without this the process would sit until its timeout with nothing
        // to say.
        Timer {
            id: quitFallback
            interval: 1500
            onTriggered: {
                console.log("SYNC giving up: the window did not render");
                Qt.quit();
            }
        }

        // Timers, not a SequentialAnimation. Qt drives animations off the
        // render loop, so a window the compositor has stopped presenting
        // (occluded, another workspace) freezes the schedule AND the theme
        // fade with it -- the probe then hangs instead of failing, which it
        // did about one run in two while the shell was being worked on. A
        // Timer is wall-clock, so the run always ends; if the window was not
        // rendering there are simply no grabs, and the script retries.
        //
        // Every step is timed from the toggle, so a slow frame cannot make
        // the offsets drift apart.
        property int t0: 1000
        Timer {
            interval: win.t0
            running: true
            onTriggered: {
                console.log("SYNC fadeMs=" + win.fadeMs + " from=" + Theme.mode);
                Theme.toggleMode();
            }
        }
        Timer {
            interval: win.t0 + Math.round(win.fadeMs / 2)
            running: true
            onTriggered: win.grab("mid", false)
        }
        Timer {
            interval: win.t0 + win.fadeMs + win.slack
            running: true
            onTriggered: win.grab("settle", false)
        }
        Timer {
            interval: win.t0 + win.fadeMs + 1400
            running: true
            onTriggered: win.grab("final", false)
        }
        // 600ms after `final`, not 200: the skeleton's pulse is a 900ms
        // sine, and two frames taken near one of its turning points differ by
        // less than a unit -- so those pixels escaped the mask and then
        // showed up as a 1/255 "laggard". Far enough apart, every pulsing
        // pixel is caught.
        Timer {
            interval: win.t0 + win.fadeMs + 2000
            running: true
            onTriggered: win.grab("final2", true)
        }
    }
}
