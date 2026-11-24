pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import ".."
import "../../common/components/Mix.js" as Mix
import "../../common/components/LiveMarkdown.js" as LM

// =============================================================================
// NoteEditorPane.qml -- the open note: the live-markdown editor bound to the
// store's current document, plus what a note needs around it.
//
//   * The inline title is the file name; it commits (a rename, Obsidian
//     suffix on a clash) when the caret leaves it, never per keystroke.
//   * Relative images resolve against the note's REAL folder; a pasted image
//     lands in .attachments and is linked relatively; a dropped image is
//     linked where it lies (absolute path).
//   * A file changed on disk while there are unsaved edits here stops
//     autosave and asks, in a carved band at the top: Keep mine / Load theirs.
//   * Caret and scroll are remembered per note and restored on reopening.
// =============================================================================
FocusScope {
    id: pane

    property var store: null
    property Item overlayItem: null
    property string fontFamily: "Inter"
    property real bodySize: 12
    property real titleSize: 22
    property color ground: Theme.surface
    // The popup's outline in this item's coordinates (the scroll fades).
    property var outline: null
    // The poured tint's ramp near the join, for the fades (ScrollDressing.surfaceRamp); null: the ground is one colour.
    property var surfaceRamp: null
    // Room beside the title for the popup's chevron and reset button.
    property real titleLeftInset: 0
    property real titleRightInset: 0
    // The centre of the title's first line, from this item's top.
    readonly property real titleCentreY: ed.y + ed.titleLineCentre

    readonly property var rec: pane.store ? pane.store.current : null
    readonly property string noteKey: pane.store ? pane.store.noteKey : ""
    readonly property var entry: pane.store && pane.store.docSerial >= 0 ? pane.store.entryOf(pane.noteKey) : null
    readonly property bool conflict: pane.rec !== null && pane.store.docSerial >= 0 && pane.rec.conflict !== null && pane.rec.conflict !== undefined
    // One line under the title: the conflict question, else a save problem.
    readonly property string problem: pane.rec !== null && pane.store.docSerial >= 0 && pane.rec.problem ? pane.rec.problem : ""
    readonly property bool banded: pane.conflict || pane.problem !== ""
    readonly property alias editor: ed

    property string linkClick: "ctrl"
    signal escapePressed

    function kindOf(e) {
        if (!e)
            return "markdown";
        return /\.(md|markdown|txt)$/i.test(e.name || "") ? "markdown" : "text";
    }
    function languageOf(e) {
        const m = /\.([A-Za-z0-9+#]+)$/.exec(e ? e.name : "");
        return m ? m[1].toLowerCase() : "";
    }

    function focusEditor() {
        if (!pane.rec)
            return;
        const s = pane.store.noteSession[pane.rec.id];
        if (pane.store.newNote) {
            ed.focusTitle(true);
            return;
        }
        if (s && s.caret) {
            ed.setCaret(s.caret, s.anchor || s.caret, false);
            if (s.scroll)
                ed.restoreScroll(s.scroll);
        } else {
            ed.focusBodyAt({
                line: 0,
                col: 0
            });
        }
    }

    // The editor keeps the keyboard, the caret where it IS: at the end of the
    // opening morph the user may already be typing (focusEditor there would put the
    // caret back at the remembered place mid-word).
    function keepFocus() {
        if (!pane.rec)
            return;
        const row = ed.viewport.delegateFor(pane.rec.doc.caret.line);
        if (ed.titleItem.activeFocus || (row && row.edit.activeFocus))
            return;
        if (pane.store.newNote)
            ed.focusTitle(true);
        else
            ed.focusBodyAt(pane.rec.doc.caret);
    }

    // Before leaving the note: where the caret and the scroll were.
    function remember() {
        if (!pane.rec || !pane.rec.doc)
            return;
        pane.store.rememberPlace(pane.rec.id, pane.rec.doc.caret, pane.rec.doc.anchor, ed.scrollState());
    }

    // An image dropped onto the open note: linked where it lies.
    function insertImage(absPath) {
        if (!pane.rec)
            return;
        ed.insertImageLine(LM.imageMarkdown(absPath, ""));
    }

    LiveMarkdownEditor {
        id: ed
        anchors.fill: parent
        anchors.topMargin: pane.banded ? banner.height + 8 : 0
        doc: pane.rec ? pane.rec.doc : null
        kind: pane.kindOf(pane.entry)
        language: pane.languageOf(pane.entry)
        realDir: pane.store ? pane.store.realDirOf(pane.noteKey) : ""
        title: pane.store && pane.store.newNote ? pane.store.pendingTitle : (pane.entry ? pane.entry.title : "")
        titleEditable: !pane.entry || !pane.entry.broken
        titlePlaceholder: pane.store ? pane.store.service.untitled : "Untitled"
        linkClick: pane.linkClick
        fontFamily: pane.fontFamily
        bodySize: pane.bodySize
        titleSize: pane.titleSize
        ground: pane.ground
        surfaceRamp: pane.surfaceRamp
        outline: pane.outline ? {
            x: pane.outline.x - ed.x,
            y: pane.outline.y - ed.y,
            w: pane.outline.w,
            h: pane.outline.h,
            radii: pane.outline.radii
        } : null
        titleLeftInset: pane.titleLeftInset
        titleRightInset: pane.titleRightInset
        onEscapePressed: pane.escapePressed()
        onTitleCommitted: text => pane.store.commitTitle(text)
        onLinkOpened: href => Qt.openUrlExternally(href)
        onWikiOpened: target => {
            pane.remember();
            pane.store.openWiki(target);
        }
        onPasteImageRequested: pane.store.pasteImage(path => {
            const rel = LM.relativePath(pane.store.realDirOf(pane.noteKey), path);
            ed.insertImageLine(LM.imageMarkdown(rel, ""));
        })
    }

    // ---- The conflict band --------------------------------------------------------------------------
    Item {
        id: banner
        visible: pane.banded
        x: 12
        width: pane.width - 24
        height: 34
        ShadowBox {
            anchors.fill: parent
            baseWidth: banner.width
            baseHeight: banner.height
            baseRadius: 10
            surfaceColor: "transparent"
            bevelColor: ed.carveBevel
            shadowColor: ed.carveShadow
            backgroundColor: ed.sunk(Theme.listBox)
            shadowProgress: 1
            shadowProgressColor: Theme.warn
            bevelWidth: 1
            shadowWidth: 3
        }
        Text {
            x: 12
            anchors.verticalCenter: parent.verticalCenter
            text: pane.conflict ? "Changed on disk" : pane.problem
            width: Math.min(implicitWidth, parent.width - 24)
            elide: Text.ElideRight
            font.family: pane.fontFamily
            font.pixelSize: 12
            color: Theme.textPrimary
        }
        Row {
            visible: pane.conflict
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 14
            Repeater {
                model: ["Keep mine", "Load theirs"]
                delegate: Text {
                    id: choice
                    required property string modelData
                    property real hf: choiceArea.containsMouse ? 1 : 0
                    Behavior on hf {
                        NumberAnimation {
                            duration: 120
                            easing.type: Easing.OutCubic
                        }
                    }
                    text: choice.modelData
                    font.family: pane.fontFamily
                    font.pixelSize: 12
                    color: Mix.c(Theme.textMuted, Theme.accent, choice.hf)
                    MouseArea {
                        id: choiceArea
                        anchors.fill: parent
                        anchors.margins: -4
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (choice.modelData === "Keep mine")
                                pane.store.keepMine(pane.rec.id);
                            else
                                pane.store.loadTheirs(pane.rec.id);
                        }
                    }
                }
            }
        }
    }
}
