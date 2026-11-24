pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../components"
import "../theme"
import "../system"

// =============================================================================
// MockupWindow -- the standard module mockup.
//
//   - Left : the content, on a stage that follows its implicit size, zoomable.
//   - Right: the control panel. One tab per tabDef; sliders and hex colour
//            fields write straight into the live content; a * marks a value
//            that differs from the mockup file's `val:` default; "Save to
//            mockup" writes the tweaks back into those defaults; the
//            Profiles tab keeps whole sets as JSON for switching between.
//
// A mockup file is `MockupWindow { ... }` and provides (docs/
// mockup_framework.md has the full contract):
//   moduleId    profiles directory name; also the mockup's file name: mockups/<moduleId>.qml.
//   mockupFile  absolute path of the mockup file, for "Save to mockup" (only when it is not that).
//   content     the drop-in item. Sized by its implicitWidth/implicitHeight.
//   lists       ({ listId: entries }) -- every key is the NAME of a plain
//               `readonly property var <listId>: [ ... ]` on the mockup.
//   target      the object lists write to; `targets` ({listId: object})
//               for the ones that write elsewhere.
//   themedLists [listId] whose values are theme tokens rather than the
//               module's own colours.
//   fileBackedLists  ({listId: "<file>"}) lists whose values the mockup keeps
//               in a file of the module's own (a config it writes as the rows
//               move): out of Save to mockup, in Reset and the profiles.
//   fitContent  the window opens wide enough for the content at its zoom
//               beside the panel, and the caption warns while it is cut.
//   tabDefs     [{ name, lists, subs: [{name, lists, groups}], page }]
//   pages       [ MockupPage { id: ... } ] named by tabDefs' `page`.
//   footer      a Component pinned under the tab pages on every tab (default
//               none: nothing is added and the panel is unchanged).
//
// Environment:
//   GRAB=<png> GRAB_MS=<n>   grab the whole window after n ms (1500) and quit
//                            (PANEL_GRAB / PANEL_GRAB_MS still work).
//   SHEET_GRAB=<png>         the stage alone, zoom 1, after GRAB_MS (the cleanup check's sheet).
//   PANEL_TAB / PANEL_SUBTAB the tab (and sub-tab) shown at start.
//   PANEL_LIST_TABS=1        print "PANEL_TABS <key>=<name> ..." and quit.
//   PANEL_TEST=1             self-test of marks, profiles and save; logs
//                            PANEL_TEST lines, ends with PANEL_TEST RESULT.
//   PANEL_MOCKUP_PATH        save to this file instead of mockupFile.
//   PANEL_PROFILE_DIR        profiles here instead of the module's directory
//                            (<repo>/mockup_profiles/<moduleId>).
//   MOCKUP_REPO              the config tree the mockup's files belong to,
//                            when it runs from a COPY: Save to mockup and the
//                            profiles write there, not into the copy the next
//                            sync puts back. tools/dev/sandbox.sh exports it (the
//                            config it copies) unless the caller set it; set
//                            empty, every write stays in the copy.
//   MOCKUP_STAGE_ORIGIN=1    after MOCKUP_STAGE_ORIGIN_MS (2500), print where the
//                            scene stands in the window (whole pixels) and the
//                            unrounded centring offset, then quit.
//   PANEL_SAVE_TEST=<json>   apply {listId: {prop: value}}, press Save, print what it did, quit
//                            (tools/dev/mockup_promote_probe.sh); PANEL_SAVE_SHARED=list.prop,...
//                            first turns those rows' "shared default" switches on;
//                            PANEL_SAVE_HOLD=1 stops before Save (a GRAB then shows the modified rows);
//                            PANEL_SAVE_KEEP=1 stays up after it (a GRAB then shows the strip).
//   MOCKUP_PLAN=1            ask tools/dev/mockup_promote.py what Save would do with each
//                            row even in a scripted mode (a grab never asks).
//   MOCKUP_LARES=<path>   the program Save runs to commit the module's files
//                            (default <repo>/tools/shell/lares; a probe's stub).
//   MOCKUP_RUNNING=1         after MOCKUP_RUNNING_MS (4000), print the QML
//                            type chain of every object in the window whose
//                            `running` is true, then quit. What is still
//                            moving when the mockup is idle, by name --
//                            tools/dev/perf/mockup_running.sh.
//
// The stage's magnification is kept across launches, per module, in
// $XDG_STATE_HOME/lares/mockup/<moduleId>.json. It is a view setting,
// not a value of the module, so it stays out of the profiles. So are the
// theme controls in the toolbar (ThemeBar): light/dark, the theme pair, and
// the one crossfade clock's length and curve are shell-wide, which is why
// they are in the toolbar and not on a tab.
// =============================================================================
Window {
    id: root

    // ---- The contract -----------------------------------------------------
    property string moduleId: "mockup"
    property string mockupFile: RepoRoot.dir + "/mockups/" + root.moduleId + ".qml"
    property Item content: null
    // A module whose width changes with a panel opening on the right is
    // anchored by its LEFT edge on the bar; the stage can emulate that instead
    // of re-centring and dragging the whole module sideways. Off by default:
    // for a module that grows in every direction, centred is the honest view.
    property bool anchorLeft: false
    // The stage cuts the content to its easing box, as thePopup does.
    property bool clipContent: false
    property var lists: ({})
    property var target: null
    property var targets: ({})
    // The colour lists whose entries are theme tokens, not the module's own
    // palette. Forwarded to the registry, which is what decides where such a
    // row's edit goes; declared here so a mockup states it once, beside the
    // lists themselves.
    property var themedLists: []
    // ({listId: "<file name>"}): lists whose values live in a file of the
    // module's own, which the mockup writes as their rows move (a config the
    // service reads). Their `val:` is the code's default, so Save to mockup
    // leaves them out -- a saved val would be overridden by the file at the
    // next launch, or override it -- and the name is what their tips cite.
    property var fileBackedLists: ({})
    // The window's first size fits the content at its zoom beside the panel,
    // and the caption warns while the stage cuts it (a tiled window, a zoom
    // in). Off by default: a mockup magnified on purpose pans instead.
    property bool fitContent: false
    property var tabDefs: []
    property list<Item> pages
    // A Component drawn under the tab pages on every tab, pinned (the pages
    // scroll above it): a module's transport or readout that must stay in view
    // whatever tab is open. Declared in the mockup, so it sees the mockup's ids.
    // Default none: the panel is then unchanged.
    property Component footer: null
    // Caption over the stage.
    property string stageLabel: "Popup content (drop-in for thePopup)"
    // What the stage is painted with. In the real bar thePopup paints the
    // popup's background and the content draws none of its own, so a mockup
    // binds this to whatever its content calls its surface -- otherwise a
    // surface colour on the panel only shows in the ring around the content's
    // carved boxes.
    property color stageColor: Theme.surface
    // Stage magnification; the toolbar slider drives it. What a mockup
    // declares here is the starting point, which the value kept from the
    // last session then overrides.
    property real zoom: 1.0
    property int panelWidth: 440

    // ---- Where the mockup's own files are -------------------------------
    // The config tree Save to mockup and the profiles write into. From the
    // config itself that is RepoRoot.dir; from a COPY (tools/dev/sandbox.sh rsyncs the
    // tree with --delete on every call) it is the tree the copy was made of,
    // named by MOCKUP_REPO -- a save into the copy reported success and was
    // gone at the next launch (R2E P1.1).
    function _norm(p) {
        return String(p || "").replace(/\/+/g, "/").replace(/\/$/, "");
    }
    readonly property string repoDir: root._norm(Quickshell.env("MOCKUP_REPO") || RepoRoot.dir)
    readonly property bool fromCopy: root.repoDir !== root._norm(RepoRoot.dir)
    // A path inside the running tree, moved to the same place in the repo.
    function inRepo(p) {
        const here = root._norm(RepoRoot.dir);
        const s = root._norm(p);
        return root.fromCopy && s.indexOf(here + "/") === 0 ? root.repoDir + s.substring(here.length) : s;
    }
    // Where a save and the profiles go when no PANEL_* env redirects them:
    // what the self-test reports, and what the user's run writes.
    readonly property string saveTarget: root.inRepo(root.mockupFile)
    // The mockup's path inside the repo ("" when it is not in it): the module side of Save reads the
    // mockup's lists by it (tools/dev/mockup_promote.py).
    readonly property string mockupRel: {
        const t = root._norm(root.saveTarget);
        const r = root.repoDir;
        return t.indexOf(r + "/") === 0 ? t.substring(r.length + 1) : "";
    }
    // WHY SAVE DOES NOT WRITE THE MODULE FROM HERE ("" = it does). The module's files are the repo's:
    // a mockup run from a COPY of the config (tools/dev/sandbox.sh) must not write them -- its Save keeps
    // writing the mockup's own val: there, as it always has -- and a save redirected to a scratch file
    // (PANEL_MOCKUP_PATH) is a test. The panel's self-test plans the module and writes none of it.
    readonly property string moduleBlock: {
        if (root.mockupRel === "")
            return "the mockup file is not inside the config tree (" + root.repoDir + ")";
        if (root.fromCopy)
            return "this mockup runs from a copy of the config (tools/dev/sandbox.sh): the module's files are the repo's, and Save writes them only from the config itself";
        if ((Quickshell.env("PANEL_MOCKUP_PATH") || "") !== "" && !root.selfTest)
            return "the save is redirected (PANEL_MOCKUP_PATH): a test, not the real mockup";
        return "";
    }
    // Ask tools/dev/mockup_promote.py what Save would do with each row (the per-row notes and switches): for an
    // interactive session only. A scripted mode -- a grab, a render, a list of tabs, a probe -- never asks, so
    // its panel is exactly what it was; MOCKUP_PLAN=1 asks anyway (the panel's probe).
    readonly property bool wantPlan: (Quickshell.env("MOCKUP_PLAN") || "") === "1"
        || (root.grabPath === "" && !root.selfTest && !root.listTabsOnly && !root.runningProbe && !root.originProbe)
    readonly property string defaultProfileDir: root.inRepo(RepoRoot.dir + "/mockup_profiles/" + root.moduleId)
    // THE DERIVED default.json FROM A COPY is this launch's vals -- read from
    // the COPY's file -- written into the REPO's profile directory. So it is
    // written only while the copy's file is the repo's byte for byte: a probe
    // that patched a val in its copy, or a copy synced before the user's last
    // save, would otherwise leave its numbers as the repo's default, and
    // tools/dev/sandbox.sh names the repo for every run it starts. Profiles a
    // test redirects (PANEL_PROFILE_DIR) are its own and written as ever.
    // Read on demand with reload(): a FileView loads on its FIRST path only,
    // and a mockup's own mockupFile may resolve after these paths were set.
    FileView {
        id: copyFileView
        path: root.fromCopy ? root.mockupFile : ""
        blockAllReads: true
        printErrors: false
    }
    FileView {
        id: repoFileView
        path: root.fromCopy ? root.saveTarget : ""
        blockAllReads: true
        printErrors: false
    }
    function _mayWriteDefault() {
        if (!root.fromCopy || store.profileDir !== root.defaultProfileDir)
            return true;
        const read = v => {
            try {
                v.reload();
                return v.text();
            } catch (e) {
                return "";
            }
        };
        const mine = read(copyFileView);
        return mine.length > 0 && mine === read(repoFileView);
    }

    readonly property alias registry: registry
    readonly property alias store: store
    readonly property alias stage: stage
    readonly property alias panel: panel
    // The panel's tabs: the mockup's, then the framework's Profiles tab.
    readonly property var allTabs: root.tabDefs.concat([{ name: "Profiles", lists: [], page: root.profilesPage }])
    readonly property Item profilesPage: ProfilesPage {
        registry: registry
        store: store
    }

    // ---- Environment ------------------------------------------------------
    // FPS=1: start the frame counter at load and print each reading, so a
    // frame rate can be compared between two builds from a log instead of by
    // eye. The counter is off by default so a still stage can be left still;
    // it counts frameSwapped and makes no frames of its own.
    readonly property bool fpsEnv: (Quickshell.env("FPS") || "") === "1"
    readonly property string grabPath: Quickshell.env("GRAB") || Quickshell.env("PANEL_GRAB") || ""
    readonly property int grabMs: Number(Quickshell.env("GRAB_MS") || Quickshell.env("PANEL_GRAB_MS") || 1500)
    readonly property int envTab: Math.max(0, Math.min(root.allTabs.length - 1, Number(Quickshell.env("PANEL_TAB") || 0)))
    readonly property int envSub: Number(Quickshell.env("PANEL_SUBTAB") || 0)
    readonly property bool selfTest: (Quickshell.env("PANEL_TEST") || "") !== ""
    readonly property bool listTabsOnly: (Quickshell.env("PANEL_LIST_TABS") || "") !== ""

    width: 1480
    height: 960
    visible: true
    title: root.moduleId + " mockup"
    color: "#AAADB4"

    MockupRegistry {
        id: registry
        lists: root.lists
        target: root.target
        targets: root.targets
        themedLists: root.themedLists
        fileBacked: root.fileBackedLists
        // A themed row writes themes/<name>.json of the tree quickshell runs
        // from (Theme's own path): under a copy that is the copy's, so it is
        // read-only there rather than an edit the next sync undoes.
        themeWritable: !root.fromCopy
    }
    MockupStore {
        id: store
        registry: registry
        repoDir: root.repoDir
        mockupRel: root.mockupRel
        moduleId: root.moduleId
        moduleBlock: root.moduleBlock
        moduleDry: root.selfTest
        lares: Quickshell.env("MOCKUP_LARES") || ""
        mockupFile: Quickshell.env("PANEL_MOCKUP_PATH") || root.saveTarget
        // Beside the mockup in the REPO: for the user, running from the real
        // config, that is the same directory; a copy run by tools/dev/sandbox.sh
        // writes the real ones (MOCKUP_REPO; set empty, the copy's -- and
        // the self-test says so).
        profileDir: Quickshell.env("PANEL_PROFILE_DIR") || root.defaultProfileDir
    }

    // ---- The zoom, kept across launches ----------------------------------
    //
    // Read in Component.onCompleted (blockLoading), after every declared
    // value and BEFORE fitContent sizes the window: restored later (it was a
    // Qt.callLater off onLoaded), the window was fitted to the declared zoom
    // and every launch after a zoom change opened cut (R2E refix). Written
    // only on a deliberate change, so a session that never touches the zoom
    // cannot overwrite what was stored.
    readonly property string viewStateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/mockup"

    FileView {
        id: viewFile
        path: root.viewStateDir + "/" + root.moduleId + ".json"
        blockLoading: true
        atomicWrites: true
        printErrors: false
    }
    function _restoreZoom() {
        const txt = viewFile.text();
        if (!txt)
            return;
        try {
            const z = JSON.parse(txt).zoom;
            if (typeof z === "number" && z > 0)
                root.zoom = z;
        } catch (e) {
            // A hand-edited or truncated file just means no zoom to restore;
            // the mockup's own value stands.
        }
    }
    Timer {
        id: viewSave
        interval: 500
        onTriggered: viewFile.setText(JSON.stringify({
            zoom: root.zoom
        }, null, 2))
    }
    // Called by whatever changes the zoom, rather than watching the property:
    // only a deliberate change is worth storing.
    function setZoom(z) {
        root.zoom = z;
        viewSave.restart();
    }

    Component.onCompleted: {
        // Every list's `val:` into its target, so the sliders and colour
        // fields hold the mockup's defaults rather than the components'.
        // `initial`: a colour whose default follows a token the component
        // may already bind keeps the component's own binding
        // (registry.applyDefaults).
        registry.applyDefaults(registry.listIds, true);
        store.writeDefault = root._mayWriteDefault();
        store.refreshProfiles();
        Quickshell.execDetached(["mkdir", "-p", root.viewStateDir]);
        root._restoreZoom();
        if (root.sheetGrabPath !== "")
            root.zoom = 1;
        root._fit();
        if (root.wantPlan)
            planTimer.start();
    }
    // A moment after load, so the python process does not compete with the first frames.
    Timer {
        id: planTimer
        interval: 800
        onTriggered: store.loadPlan()
    }
    // fitContent: the first size holds the content at its zoom (the one kept
    // from the last session) beside the panel. Once, at load -- the window is
    // the user's to resize after that.
    // The stage has no padding of its own, so the need is the zoomed content
    // plus the body's margins, the split handle and the panel; in height,
    // the toolbar rows above the stage.
    function _fit() {
        if (!root.fitContent || !root.content)
            return;
        const needW = Math.ceil(root.content.implicitWidth * root.zoom) + root.panelWidth + 2 * 24 + 12 + 2;
        const needH = Math.ceil(root.content.implicitHeight * root.zoom) + 2 * 24
            + captionRow.implicitHeight + themeBar.implicitHeight + 2 * 12 + 2;
        root.width = Math.max(root.width, needW);
        root.height = Math.max(root.height, needH);
    }

    // ========================== LAYOUT ==========================
    // Draggable split between the stage and the controls: wide controls
    // while tuning values, narrow ones while inspecting the result.
    // A light/dark switch crossfades a PICTURE of this whole body rather than
    // lerping every token underneath (ThemeCrossfade): the fade costs one
    // quad a frame whatever mockup is on the stage. A sibling, so the picture
    // is not in its own picture.
    ThemeCrossfade {
        target: body
        anchors.fill: parent
        anchors.margins: 24
    }

    SplitView {
        id: body
        anchors.fill: parent
        anchors.margins: 24
        orientation: Qt.Horizontal

        // The default handle is a hairline that is hard to aim at. This one
        // keeps a comfortable grab width while drawing as a thin rule.
        handle: Rectangle {
            implicitWidth: 12
            color: "transparent"
            Rectangle {
                anchors.centerIn: parent
                width: 2
                height: parent.height
                radius: 1
                color: SplitHandle.pressed ? "#4480F4" : SplitHandle.hovered ? "#8A8A8C" : "#CED1D7"
                Behavior on color {
                    ColorAnimation {
                        duration: 120
                    }
                }
            }
        }

        // -------- LEFT: caption, view toolbar, stage --------
        ColumnLayout {
            SplitView.fillWidth: true
            SplitView.minimumWidth: 320
            spacing: 12

            RowLayout {
                id: captionRow
                Layout.fillWidth: true
                spacing: 10

                Label {
                    // fitContent: a stage narrower than the content says so,
                    // in words, where the eye already is (a synthetic click
                    // aimed past the cut lands on the panel -- R2E I10.4).
                    text: root.stageLabel + (root.fitContent && stage.contentCut
                        ? "  --  CUT: the stage is smaller than the content at this zoom (widen the window or zoom out)" : "")
                    color: "#5D5D5F"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                    font.bold: true
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                TipRow {
                    tip: "Magnifies the content as a render transform, so every pixel size inside keeps its true relationship — paddings, grooves, particles and fonts scale together. A faithful magnifier of the 1:1 appearance, not a different layout. Once the zoom outgrows the window the stage scrolls."
                    Layout.fillWidth: false
                    Label {
                        text: "zoom"
                        color: "#8A8A8C"
                        font.family: "Audiowide"
                        font.pixelSize: 14
                    }
                    Slider {
                        Layout.preferredWidth: 150
                        from: 0.5
                        to: 4.0
                        stepSize: 0.05
                        value: root.zoom
                        onMoved: root.setZoom(value)
                    }
                    Label {
                        text: root.zoom.toFixed(2) + "x"
                        color: "#5D5D5F"
                        font.family: "Audiowide"
                        font.pixelSize: 14
                        Layout.preferredWidth: 50
                        horizontalAlignment: Text.AlignRight
                    }
                    Button {
                        text: "1:1"
                        font.pixelSize: 13
                        padding: 4
                        onClicked: root.setZoom(1.0)
                    }
                }

                // Counts the window's frameSwapped: the frames it PRESENTED. It must
                // not drive the loop it measures -- a running FrameAnimation makes
                // the window render every vsync whether anything changed, so the
                // earlier meter read the panel's refresh rate (120) whatever the
                // content did. Now an idle stage reads ~0 and a capped one its cap.
                TipRow {
                    tip: "Frames the window actually presented per second (frameSwapped), so the counter does not make frames of its own: a still stage reads about 0, a stage capped at 60 reads 60. Green 55 and up, orange 28 and up, red 10 and up, grey below (idle). OFF by default so a still stage can be left still."
                    Layout.fillWidth: false
                    Label {
                        text: "fps"
                        color: "#8A8A8C"
                        font.family: "Audiowide"
                        font.pixelSize: 14
                    }
                    Label {
                        id: fpsLabel
                        property int frames: 0
                        property real t0: 0
                        property real fps: 0
                        text: !fpsToggle.checked ? "off" : fps > 0 ? fps.toFixed(0) : "—"
                        color: fps >= 55 ? "#40A02B" : fps >= 28 ? "#FE640B" : fps >= 10 ? "#D20F39" : "#8A8A8C"
                        font.family: "Audiowide"
                        font.pixelSize: 15
                        font.bold: true
                        Layout.preferredWidth: 30
                        Connections {
                            target: root
                            enabled: fpsToggle.checked
                            function onFrameSwapped() {
                                const now = Date.now();
                                if (fpsLabel.t0 === 0) {
                                    fpsLabel.t0 = now;
                                    return;
                                }
                                fpsLabel.frames++;
                                if (now - fpsLabel.t0 >= 1000) {
                                    fpsLabel.fps = fpsLabel.frames * 1000 / (now - fpsLabel.t0);
                                    fpsLabel.frames = 0;
                                    fpsLabel.t0 = now;
                                    // FPS=1 also prints it, so the rate can be
                                    // compared between two builds without
                                    // somebody reading a label off a screen.
                                    if (root.fpsEnv)
                                        console.log("FPS " + fpsLabel.fps.toFixed(1));
                                }
                            }
                        }
                    }
                    CheckBox {
                        id: fpsToggle
                        text: "measure"
                        checked: root.fpsEnv
                        font.family: "Audiowide"
                        font.pixelSize: 13
                        onCheckedChanged: {
                            fpsLabel.t0 = 0;
                            fpsLabel.frames = 0;
                            fpsLabel.fps = 0;
                        }
                    }
                }
            }

            // The theme is a view setting like the zoom above it, so it sits
            // in the toolbar and not on a tab: it is not a value of the module
            // on the stage and must stay out of its profiles and its `val:`
            // defaults. Its own line, right-aligned under the zoom and fps
            // controls it belongs with, because the four controls together are
            // wider than the caption leaves free -- on one line the caption
            // would elide away to buy room for them.
            ThemeBar {
                id: themeBar
                Layout.alignment: Qt.AlignRight
            }

            MockupStage {
                id: stage
                Layout.fillWidth: true
                Layout.fillHeight: true
                content: root.content
                zoom: root.zoom
                anchorLeft: root.anchorLeft
                clipContent: root.clipContent
                stageColor: root.stageColor
            }
        }

        // -------- RIGHT: the control panel --------
        MockupPanel {
            id: panel
            SplitView.preferredWidth: root.panelWidth
            SplitView.minimumWidth: 240
            registry: registry
            store: store
            tabs: root.allTabs
            footer: root.footer
            tabIndex: root.envTab
            initialTab: root.envTab
            initialSub: root.envSub
        }
    }

    // ========================== SCRIPTED USE ==========================
    // GRAB=<png>: grab the whole window after GRAB_MS and quit
    // (tools/dev/mockup_grab.sh).
    Timer {
        running: root.grabPath !== ""
        interval: root.grabMs
        // The panel's left edge rides along, so tools/dev/mockup_grab.sh crops the
        // panel where it IS rather than at a guessed share of the width.
        onTriggered: root.contentItem.grabToImage(function (r) {
            r.saveToFile(root.grabPath);
            console.log("GRAB saved " + root.grabPath + " panel=" + Math.round(panel.mapToItem(root.contentItem, 0, 0).x));
            Qt.quit();
        })
    }

    // SHEET_GRAB=<png>: the stage alone (its ground and the content at zoom 1, never the panel) GRAB_MS after the start, then
    // quit: the cleanup check's reference sheet (tools/dev/sheet_render.py), where a panel may change and a stage may not. The focus
    // goes first, because a caret blinks on the wall clock. `sheetGrabItem` is for a scene that is not the stage's child.
    readonly property string sheetGrabPath: Quickshell.env("SHEET_GRAB") || ""
    property Item sheetGrabItem: root.content ? root.content.parent : null
    Timer {
        running: root.sheetGrabPath !== ""
        interval: root.grabMs
        onTriggered: {
            const it = root.activeFocusItem;
            if (it)
                it.focus = false;
            root.contentItem.forceActiveFocus();
            root.sheetDropParticles(root.contentItem);
            root.sheetAboutToGrab();
            sheetGrabLate.start();
        }
    }
    // Some frames after that: a MultiEffect's bloom over a particle layer still holds the last frame's texture on the next one.
    Timer {
        id: sheetGrabLate
        interval: 120
        onTriggered: root.sheetGrab()
    }
    // For a value that rests somewhere a frame clock decided: the mockup puts it on a fixed place here.
    signal sheetAboutToGrab
    // A live particle stands wherever its system's clock took it, a different place in every run, so a picture holds none.
    function sheetDropParticles(o: var): void {
        const kids = o.data ?? [];
        for (let i = 0; i < kids.length; i++) {
            const k = kids[i];
            if (String(k).indexOf("QQuickParticleSystem") === 0)
                k.reset();
            else
                root.sheetDropParticles(k);
            if (k._paintIfStale) {              // SquishItem: what stays on its canvas is whichever paint the frame times last allowed
                k._painted = null;
                k._paintIfStale();
            }
        }
    }
    function sheetGrab(): void {
        root.sheetGrabItem.grabToImage(function (r) {
            r.saveToFile(root.sheetGrabPath);
            console.log("SHEET_GRAB saved " + root.sheetGrabPath);
            sheetGrabQuit.start();
        });
    }
    Timer {
        id: sheetGrabQuit
        interval: 0
        onTriggered: Qt.quit()
    }

    // MOCKUP_RUNNING=1: name everything that is RUNNING while the mockup sits
    // there, then quit (tools/dev/perf/mockup_running.sh).
    //
    // WHY. An idle mockup that renders 70 frames a second is not rendering
    // because a pixel changed: Qt Quick keeps asking for frames for as long as
    // ANY QAbstractAnimation is running -- a FrameAnimation, a ParticleSystem,
    // a Behavior mid-flight, an animation whose condition came out true by
    // accident. Reading the QML tells you which ones COULD run; this says
    // which ones DO, by name, and it took one run to find what a day of
    // ablation had not.
    //
    // The walk is over `data`, which holds an item's children AND the
    // non-visual objects declared inside it -- where every animation and timer
    // lives. `data` is a tree, so no visited set is needed; the depth cap is
    // the only guard. The chain printed for each hit is the QML TYPE of every
    // object it hangs under, so `.../VinylStage/FrameAnimation` names the file
    // to open.
    readonly property bool runningProbe: (Quickshell.env("MOCKUP_RUNNING") || "") === "1"
    function _typeName(o) {
        const s = String(o);
        const i = s.indexOf("(");
        return (i > 0 ? s.substring(0, i) : s).replace(/_QMLTYPE_\d+$/, "");
    }
    property int _runVisited: 0
    function reportRunning() {
        const out = [];
        root._runVisited = 0;
        function walk(o, path, depth) {
            if (!o || depth > 60)
                return;
            root._runVisited++;
            const here = path + "/" + root._typeName(o);
            // `running` on an object that has no such property reads as
            // undefined, and `=== true` is what keeps a truthy string out.
            if (o.running === true) {
                // A timer's interval names it where a type chain cannot:
                // two QQmlTimers under the same item are told apart by the
                // number they were declared with.
                const iv = o.interval;
                out.push(here + (iv !== undefined ? "  [interval=" + iv + " repeat=" + o.repeat + "]" : ""));
            }
            const kids = o.data;
            if (kids !== undefined && kids !== null)
                for (let i = 0; i < kids.length; ++i)
                    walk(kids[i], here, depth + 1);
        }
        walk(root.contentItem, "", 0);
        console.log("MOCKUP_RUNNING visited=" + root._runVisited + " running=" + out.length);
        for (const p of out)
            console.log("MOCKUP_RUNNING   " + p);
    }
    Timer {
        running: root.runningProbe
        interval: Number(Quickshell.env("MOCKUP_RUNNING_MS") || 4000)
        onTriggered: {
            root.reportRunning();
            Qt.quit();
        }
    }

    // MOCKUP_STAGE_ORIGIN=1: where the scene stands in the window, after
    // MOCKUP_STAGE_ORIGIN_MS (2500), and the centring offset before it was put
    // on a whole pixel; then quit. The real
    // shell's window sits at the screen's origin, so a scene on a half pixel
    // is a picture no screen shows (the engine's layers land on the window's
    // grid): the line is how that is measured.
    readonly property bool originProbe: (Quickshell.env("MOCKUP_STAGE_ORIGIN") || "") === "1"
    Timer {
        running: root.originProbe
        interval: Number(Quickshell.env("MOCKUP_STAGE_ORIGIN_MS") || 2500)
        onTriggered: {
            const o = stage.sceneOrigin(root.contentItem);
            console.log("MOCKUP_STAGE_ORIGIN " + root.moduleId + " x=" + o.x + " y=" + o.y
                        + " rawx=" + stage.centreX + " rawy=" + stage.centreY
                        + " zoom=" + root.zoom + " view=" + stage.width + "x" + stage.height);
            Qt.quit();
        }
    }

    // PANEL_SAVE_TEST=<json {listId: {prop: value}}>: the values go in through the registry (the path the
    // panel's own controls take), then Save is pressed and what it did is printed, then the window quits
    // (tools/dev/mockup_promote_probe.sh: a Save from a mockup run from a scratch copy writes the module and
    // calls the stub lares). PANEL_SAVE_SHARED=list.prop,... turns those rows' "shared default" switches
    // on first. The values are applied a moment after load, so the framework's own defaults are in.
    readonly property string saveTestJson: Quickshell.env("PANEL_SAVE_TEST") || ""
    Timer {
        running: root.saveTestJson !== ""
        interval: Number(Quickshell.env("PANEL_SAVE_TEST_MS") || 2200)
        onTriggered: {
            let changes = {};
            try {
                changes = JSON.parse(root.saveTestJson);
            } catch (e) {
                console.log("PANEL_SAVE_TEST bad json: " + e);
                Qt.quit();
                return;
            }
            registry.applyValues(changes);
            console.log("PANEL_SAVE_TEST modified=" + registry.modifiedCount(registry.defaultsRev, registry.savedIds(), null)
                        + " saveable=" + panel.saveableTotal + " moduleBlock=" + JSON.stringify(store.moduleBlock));
            for (const k of (Quickshell.env("PANEL_SAVE_SHARED") || "").split(",")) {
                if (k === "")
                    continue;
                const i = k.indexOf(".");
                const e = registry.entries(k.substring(0, i)).find(x => x.prop === k.substring(i + 1));
                if (e)
                    registry.setShared(k.substring(0, i), e, true);
            }
            if ((Quickshell.env("PANEL_SAVE_HOLD") || "") === "1")
                return;                 // the values are in and the switches set; a GRAB shows the panel as the user would
            store.saveToMockup();
            saveTestWait.start();
        }
    }
    Timer {
        id: saveTestWait
        interval: 150
        repeat: true
        onTriggered: {
            if (store.saving)
                return;
            saveTestWait.stop();
            console.log("PANEL_SAVE_TEST status: " + store.saveStatus.replace(/\n/g, " | "));
            console.log("PANEL_SAVE_TEST summary: " + store.saveSummary + (store.saveSummaryBad ? " [BAD]" : ""));
            console.log("PANEL_SAVE_TEST after modified=" + registry.modifiedCount(registry.defaultsRev, registry.savedIds(), null)
                        + " rev=" + registry.defaultsRev);
            console.log("PANEL_SAVE_TEST done");
            if ((Quickshell.env("PANEL_SAVE_KEEP") || "") !== "1")
                Qt.quit();                // KEEP: stay up for a GRAB to show the strip after the save
        }
    }

    // PANEL_LIST_TABS=1: the keys tools/dev/mockup_grab.sh can ask for, one per
    // tab and sub-tab ("3" is tab 3's first sub-tab, "3.1" its second).
    function grabKeys() {
        const out = [];
        root.allTabs.forEach((t, i) => {
            const subs = t.subs || [];
            if (subs.length > 1)
                subs.forEach((s, j) => out.push((j === 0 ? "" + i : i + "." + j) + "=" + t.name + "/" + s.name));
            else
                out.push(i + "=" + t.name);
        });
        return out;
    }
    Timer {
        running: root.listTabsOnly
        interval: 50
        onTriggered: {
            console.log("PANEL_TABS " + root.grabKeys().join(" "));
            Qt.quit();
        }
    }

    // PANEL_TEST=1: scripted exercise of the * marks, a profile round trip
    // and the save (tools/dev/mockup_panel_test.sh). Nudges the first entry of
    // the first and last numeric list and of the first and last colour
    // list, plus the first boolean row the mockup has, then checks every
    // count along the way and logs PANEL_TEST RESULT PASS or FAIL. Point PANEL_MOCKUP_PATH and PANEL_PROFILE_DIR at
    // scratch copies first; the save really rewrites the file it is given.
    // Themed lists are out of it entirely -- see _testIds.
    property var _test: ({ picks: [], fails: [] })
    function _testExpect(cond, what) {
        if (!cond)
            root._test.fails.push(what);
    }
    // The lists the self-test may drive. A themed list is deliberately not
    // one of them: its values live in the theme file, and unlike the mockup
    // file and the profile directory there is no scratch copy to redirect a
    // test write to, so exercising one would edit the user's real theme --
    // and its Reset is Theme's, not applyDefaults', which skips it.
    function _testIds() {
        return registry.listIds.filter(id => !registry.isThemed(id) && registry.entries(id).length > 0);
    }
    function _testTabLists(t) {
        const ids = root._testIds();
        return registry.tabLists(t).filter(id => ids.indexOf(id) >= 0);
    }
    function _testPick(id, e) {
        // registry.nudgedValue knows what "a different value" means for each
        // kind of row; the kinds live there and only there.
        return { id: id, prop: e.prop, e: e, orig: e.val, value: registry.nudgedValue(id, e) };
    }
    function _testPicks() {
        const ids = root._testIds();
        const nums = ids.filter(id => !registry.isColorList(id));
        const cols = ids.filter(id => registry.isColorList(id));
        const chosen = [];
        for (const id of [nums[0], cols[0], nums[nums.length - 1], cols[cols.length - 1]])
            if (id && chosen.indexOf(id) < 0)
                chosen.push(id);
        const picks = chosen.map(id => root._testPick(id, registry.entries(id)[0]));
        // And the first BOOLEAN row anywhere, which the four lists above
        // reach only if one happens to be their first entry. A switch takes
        // a different path through every step this test walks -- the mark,
        // the profile, the `val: true` a save writes -- so a run that never
        // touched one proved nothing about any of it.
        for (const id of nums) {
            const e = registry.entries(id).find(x => registry.isBoolEntry(x));
            if (e && !picks.some(p => p.id === id && p.prop === e.prop)) {
                picks.push(root._testPick(id, e));
                break;
            }
        }
        // And one row of a FILE-BACKED list, if the mockup has one: Save to
        // mockup must leave it out -- still modified, its val: unchanged -- or
        // the save writes a default the module's own file overrules at the
        // next launch (R2E P1.2).
        const fb = ids.find(id => registry.isFileBacked(id));
        if (fb && !picks.some(p => p.id === fb))
            picks.push(root._testPick(fb, registry.entries(fb)[0]));
        return picks;
    }
    function _testStep1() {
        const picks = root._testPicks();
        root._test = { picks: picks, fails: [] };
        // Through the registry, which is the path the panel's own controls
        // take: a value written straight onto the target would bypass whatever
        // that list's kind requires, and for a themed row a JS assignment
        // destroys the theme binding permanently.
        const vals = {};
        for (const p of picks)
            vals[p.id] = Object.assign(vals[p.id] || {}, { [p.prop]: p.value });
        registry.applyValues(vals);
        const marked = root.allTabs.filter(t => registry.modifiedCount(registry.defaultsRev, root._testTabLists(t), null) > 0).map(t => t.name);
        const n = registry.modifiedCount(registry.defaultsRev, root._testIds(), null);
        // Where the button and the profiles write WITHOUT this test's
        // PANEL_* redirection -- tools/dev/mockup_panel_test.sh checks that these
        // are the real tree's (under version control), not a sandbox copy's.
        console.log("PANEL_TEST mockupFile=" + root.saveTarget);
        console.log("PANEL_TEST profileDir=" + root.defaultProfileDir);
        console.log("PANEL_TEST modified=" + n + " tabsMarked=" + marked.join(",") + " picks=" + picks.map(p => p.id + "." + p.prop + "=" + p.value).join(","));
        root._testExpect(picks.length > 0, "no lists to test");
        root._testExpect(n === picks.length, "modified after nudge: " + n + ", expected " + picks.length);
        store.saveProfile("claude-test");
        root._testWhenIdle(root._testStep2);
    }
    // THE PROFILE PROCESS IS ONE: a save asked while the launch's own listing still runs is dropped without a word (`_profileRun` answers false), and a
    // fixed 900 ms pause is too short for it on a loaded machine and a mockup that is slow to start (test_silicon: "profile not listed after save",
    // the profile "saved" a step later). The self-test goes on when the process is idle, as Save's own wait does.
    property var _testIdleFn: null
    property int _testIdleTicks: 0
    function _testWhenIdle(fn) {
        root._testIdleFn = fn;
        root._testIdleTicks = 0;
        testIdle.start();
    }
    Timer {
        id: testIdle
        interval: 100
        repeat: true
        property int quiet: 0
        onTriggered: {
            root._testIdleTicks++;
            // idle on three ticks running: an operation's exit starts the listing that follows it a turn later
            testIdle.quiet = store.profileBusy ? 0 : testIdle.quiet + 1;
            if (testIdle.quiet < 3 && root._testIdleTicks < 600)
                return;
            testIdle.stop();
            testIdle.quiet = 0;
            root._testIdleFn();
        }
    }
    function _testStep2() {
        const picks = root._test.picks;
        console.log("PANEL_TEST profiles=" + JSON.stringify(store.profileNames) + " status=" + store.profileStatus);
        root._testExpect(store.profileNames.indexOf("claude-test") >= 0, "profile not listed after save");
        registry.applyDefaults(root._testIds());
        const n0 = registry.modifiedCount(registry.defaultsRev, root._testIds(), null);
        console.log("PANEL_TEST afterReset modified=" + n0);
        root._testExpect(n0 === 0, "reset left " + n0 + " modified");
        store.loadProfile("claude-test");
        const n1 = registry.modifiedCount(registry.defaultsRev, root._testIds(), null);
        console.log("PANEL_TEST afterLoad modified=" + n1 + " " + picks.map(p => p.id + "." + p.prop + "=" + registry.liveValue(p.id, p.e)).join(" "));
        root._testExpect(n1 === picks.length, "modified after load: " + n1 + ", expected " + picks.length);
        for (const p of picks)
            root._testExpect(registry.liveValue(p.id, p.e) === p.value, "after load " + p.id + "." + p.prop + " is " + registry.liveValue(p.id, p.e) + ", expected " + p.value);
        store.saveToMockup();
        // Save plans the module before it writes the mockup: seconds, not a fixed pause. Wait for it.
        root._testSaveTicks = 0;
        testSaveWait.start();
    }
    property int _testSaveTicks: 0
    Timer {
        id: testSaveWait
        interval: 100
        repeat: true
        onTriggered: {
            root._testSaveTicks++;
            if ((store.saving || store.saveStatus === "") && root._testSaveTicks < 300)
                return;
            testSaveWait.stop();
            root._testStep3();
            testEnd.start();
        }
    }
    Timer {
        id: testEnd
        interval: 900
        onTriggered: root._testStep4()
    }
    function _testStep3() {
        const picks = root._test.picks;
        console.log("PANEL_TEST save: " + store.saveStatus.replace(/\n/g, " | "));
        // A mockup whose every list is FILE-BACKED (test_shell: shell.jsonc) has nothing Save may write: it says so and changes nothing -- no module
        // line, no new defaults, every pick still modified (the file keeps them). Otherwise the module side planned and reported (or blocked, with its
        // reason) -- and wrote nothing of the module.
        const nothing = picks.every(p => registry.isFileBacked(p.id));
        if (nothing)
            root._testExpect(store.saveStatus.indexOf("nothing to save") === 0 && store.saveStatus.indexOf("FAILED") < 0,
                             "every pick is file-backed, and Save did not say there is nothing to save: " + store.saveStatus.replace(/\n/g, " | "));
        else
            root._testExpect(store.saveStatus.indexOf("module") >= 0 && store.saveStatus.indexOf("FAILED") < 0,
                             "the module side of Save printed no 'module' line, or failed: " + store.saveStatus.replace(/\n/g, " | "));
        root._testExpect(store.saveStatus.indexOf("commit:") < 0, "the self-test committed something");
        const n = registry.modifiedCount(registry.defaultsRev, root._testIds(), null);
        // A file-backed pick is not saved: it stays modified with its old val.
        const kept = picks.filter(p => registry.isFileBacked(p.id));
        console.log("PANEL_TEST afterSave modified=" + n + " rev=" + registry.defaultsRev + " defaults=" + picks.map(p => p.id + "." + p.prop + "=" + registry.defaultOf(p.id, p.prop)).join(","));
        root._testExpect(n === kept.length, "save left " + n + " modified, expected " + kept.length + " (the file-backed picks)");
        root._testExpect(registry.defaultsRev === (nothing ? 0 : 1), "defaultsRev is " + registry.defaultsRev + ", expected " + (nothing ? 0 : 1));
        for (const p of picks) {
            const want = registry.isFileBacked(p.id) ? p.orig : p.value;
            root._testExpect(registry.defaultOf(p.id, p.prop) === want, "default of " + p.id + "." + p.prop + " is " + registry.defaultOf(p.id, p.prop) + ", expected " + want
                             + (registry.isFileBacked(p.id) ? " (file-backed: never saved)" : ""));
        }
        store.deleteProfile("claude-test");
    }
    function _testStep4() {
        console.log("PANEL_TEST afterDelete profiles=" + JSON.stringify(store.profileNames) + " status=" + store.profileStatus);
        root._testExpect(store.profileNames.indexOf("claude-test") < 0, "profile still listed after delete");
        const fails = root._test.fails;
        console.log("PANEL_TEST RESULT " + (fails.length === 0 ? "PASS" : "FAIL: " + fails.join("; ")));
        Qt.quit();
    }
    SequentialAnimation {
        running: root.selfTest
        PauseAnimation {
            duration: 900
        }
        ScriptAction {
            script: root._testWhenIdle(root._testStep1)
        }
    }
}
