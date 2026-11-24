pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/icons"
import ".."
import "../../common/components/Mix.js" as Mix
import "RowText.js" as RT
import "RowGeometry.js" as RG

// =============================================================================
// AppRow.qml -- one app (or script, or .desktop in a folder) in the launcher.
//
// The icon the active icon theme gives the app (AppIcon), and the name beside it; a favourite has a star at the right end (colour is not the favourite mark: every icon is in full colour),
// and any other row shows a faint one while it is hovered, which a click
// makes a favourite.
// A link (a dropped script, a linked app) carries notes' chain glyph before
// the star; its tip names where the file really is.
// The highlight is the well gliding under the row (LauncherGrid); a search's
// matched letters are the accent.
// A hit found inside a folder carries the folder's name, muted, after its own.
// While the row is being renamed, an editor takes the name's place.
//
// `facts` is the service's record (LauncherService.entry): facts only, never
// a colour. `hovered`, `starHovered` and `linkHovered` come from the grid,
// which owns the one pointer layer and hit-tests the marks by RowGeometry's
// numbers (a HoverHandler on a row would take the grid's hover, CLAUDE.md).
// =============================================================================
Item {
    id: row

    property var facts: null
    property LauncherTune tune: null
    property Item overlayItem: null
    property bool hovered: false
    // A dragged row hovering this one to make a folder (DragIntent "group").
    property bool target: false
    // Search: where the query matched in the name, and whether this is a
    // flattened hit (its folder's name then follows its own; inside the
    // folder itself it would only repeat the header).
    property var matchIndices: []
    property bool showFolder: false

    readonly property real _pad: row.tune ? row.tune.rowInset : 6
    readonly property real _icon: row.tune ? row.tune.iconSize : 40

    // The favourite mark: a star at the row's right end (every icon is in full colour,
    // so colour does not say it). It has NO fade
    // of any kind (a fading star shows ghosted on every
    // row the highlight has just left while scrolling fast): presence, colour
    // and the favourite toggle all follow their facts in the same frame. The
    // grid hit-tests it (a click there toggles the favourite) and says when
    // the pointer is on it.
    property real favF: row.facts && row.facts.favorite ? 1 : 0
    property bool starHovered: false
    property real starHoverF: row.facts && row.starHovered ? 1 : 0
    // The same star, faint, on a hovered row that is not a favourite yet: the
    // affordance is the pointer's (house rule), so it is there only while
    // the pointer is on the row. It follows the hover alone, favourite or not
    // (a favourite's star is there anyway): gated on "not a favourite" it
    // fell while favF rose, and a star made a favourite under the pointer
    // dimmed to three quarters on its way (f + (1 - f)^2 at the crossing).
    property real hoverStarF: row.facts && row.hovered ? 1 : 0
    // A link's chain glyph and whether the pointer is on it (the grid says).
    readonly property bool isLink: !!row.facts && !!row.facts.isLink
    property bool linkHovered: false
    // The inline rename (LauncherGrid.beginRename): the editor replaces the
    // name while this is set.
    property bool renaming: false
    signal renameCommitted(string text)
    // Escape (true: the list takes the keyboard back) or the focus gone.
    signal renameCancelled(bool refocus)
    property real targetF: row.facts && row.target ? 1 : 0
    Behavior on targetF {
        enabled: !row._snap
        NumberAnimation {
            duration: 140
            easing.type: Easing.OutCubic
        }
    }

    // The grid REUSES a face for the row coming into view (LauncherGrid's
    // face pool) and calls this before handing it that row: every fraction
    // then takes the new row's value at once, as a face built for it would,
    // instead of the tint fading out of the last row's.
    property bool _snap: false
    function snap() {
        row._snap = true;
        snapEnd.restart();
    }
    Timer {
        id: snapEnd
        interval: 0
        onTriggered: row._snap = false
    }

    // The well a folder is about to be made in: the target row's own, faint
    // accent, as the notes group tile tints for a drop.
    ShadowBox {
        visible: row.targetF > 0.01
        opacity: row.targetF
        x: 0
        y: 0
        width: row.width
        height: row.height
        baseWidth: row.width
        baseHeight: row.height
        baseRadius: row.tune ? row.tune.wellRadius : 10
        surfaceColor: "transparent"
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        backgroundColor: Mix.c(Theme.panelSunk, Theme.accent, 0.14)
        bevelWidth: 1
        shadowWidth: 3
    }

    AppIcon {
        id: mark
        objectName: "rowIcon"
        x: row._pad
        y: Math.round((row.height - row._icon) / 2)
        scale: 1 + 0.06 * row.targetF
        size: row._icon
        icon: row.facts ? row.facts.icon : ""
        kind: row.facts ? row.facts.kind : ""
        appId: row.facts ? row.facts.desktopId : ""
    }

    // The confirm flourish reads where the name and the icon are, to carry
    // the row as it is drawn (LauncherGrid.flourishCapture).
    readonly property Item nameItem: nameText
    readonly property Item iconItem: mark

    Text {
        id: nameText
        x: row._pad + row._icon + (row.tune ? row.tune.iconGap : 10)
        y: Math.round((row.height - height) / 2)
        visible: !row.renaming
        width: Math.max(0, RG.nameRight(row.width, row.tune, row.isLink) - x)
        textFormat: Text.StyledText
        text: RT.styled(row.facts ? row.facts.name : "", row.matchIndices, Theme.accent.toString(), row.showFolder && row.facts ? (row.facts.folderName || "") : "", Theme.textMuted.toString())
        elide: Text.ElideRight
        font.family: row.tune ? row.tune.fontFamily : "Inter"
        font.pixelSize: row.tune ? row.tune.nameSize : 12
        color: Theme.textPrimary
    }

    // The inline rename: the LLM sidebar's (LlmSidebar renameField). A bare
    // TextInput, not a Controls field, so no padding pushes the caret off the
    // name's first letter (CLAUDE.md). Return or Enter commits, Escape or
    // losing the focus cancels; keys it does not take stop here, so typing
    // never reaches the grid's search while it is open.
    TextInput {
        id: renameField
        objectName: "renameField"
        x: nameText.x
        y: Math.round((row.height - height) / 2)
        width: nameText.width
        visible: row.renaming
        clip: true
        font.family: nameText.font.family
        font.pixelSize: nameText.font.pixelSize
        color: Theme.textPrimary
        selectionColor: Mix.c(Theme.surface, Theme.accent, 0.3)
        selectedTextColor: Theme.textPrimary
        selectByMouse: true
        // Driven off `renaming` (a face taken from the pool for a row already
        // being renamed begins in onCompleted), never off `visible`.
        function begin() {
            renameField.text = row.facts ? row.facts.name : "";
            renameField.forceActiveFocus();
            // Selected backwards, so the caret lands at 0 and a title too long
            // for the slot shows its START (the LLM sidebar's reason).
            renameField.select(renameField.text.length, 0);
        }
        Component.onCompleted: {
            if (row.renaming)
                renameField.begin();
        }
        onActiveFocusChanged: {
            if (!renameField.activeFocus && row.renaming)
                row.renameCancelled(false);
        }
        // Return commits and STOPS here: a TextInput emits accepted() and then lets the key go on to its parents, and by
        // then the rename is over, so the grid would take it for "launch the highlighted row".
        Keys.onReturnPressed: event => {
            row.renameCommitted(renameField.text.trim());
            event.accepted = true;
        }
        Keys.onEnterPressed: event => {
            row.renameCommitted(renameField.text.trim());
            event.accepted = true;
        }
        Keys.onEscapePressed: row.renameCancelled(true)
        // The terminal's editing keys (Ctrl+W, Ctrl+U, Alt+B ...) take the key before the field types it.
        Keys.forwardTo: [renameKeys]
        EditKeys {
            id: renameKeys
            target: renameField
            selectAll: true
        }
    }
    // While the rename is open, whatever the field leaves unused stops HERE (the grid's search and its
    // Ctrl+F must not hear it). It sits on the row, not on the field: the field has to see the key BEFORE
    // it types it (an Alt+B typed a "b"), and a key it ignores bubbles up to its parent.
    Keys.onPressed: event => {
        if (row.renaming)
            event.accepted = true;
    }
    onRenamingChanged: {
        if (row.renaming) {
            renameField.begin();
        } else {
            // The face goes back to the pool and serves other rows: one that
            // kept the editor's focus flag had the caret back the moment it
            // was re-parented, in an editor nobody could see.
            renameField.focus = false;
        }
    }

    // The chain glyph (notes' link glyph): a link, whose real file is
    // elsewhere. The accent while the pointer is on it, an instant switch as
    // notes has it; a click opens the file chooser at the real file's folder
    // (LauncherGrid hit-tests it).
    Text {
        id: linkGlyph
        objectName: "linkGlyph"
        visible: row.isLink
        x: Math.round(RG.linkX(row.width, row.tune) + (RG.LINK_SLOT - width) / 2)
        y: Math.round((row.height - height) / 2)
        text: "\uF0C1"
        font.family: "Symbols Nerd Font"
        font.pixelSize: 10
        color: Mix.c(Theme.textFaint, Theme.accent, row.linkHovered ? 1 : 0)
    }

    // One star: the favourite's (accent, the hover colour on the star) and
    // the hovered row's faint one (the accent while the pointer is on it),
    // one mark whose colour switches between the two, so an unfavourite under
    // the pointer turns faint in place.
    Text {
        id: star
        objectName: "favStar"
        readonly property real presence: row.favF + (1 - row.favF) * row.hoverStarF
        visible: star.presence > 0.01
        opacity: star.presence
        x: Math.round(row.width - row._pad - width)
        y: Math.round((row.height - height) / 2)
        text: "\uF005"
        font.family: "Symbols Nerd Font"
        font.pixelSize: row.tune ? row.tune.starSize : 12
        color: Mix.c(Mix.c(Theme.textFaint, Theme.accent, row.starHoverF), Mix.c(Theme.accent, Theme.accentHover, row.starHoverF), row.favF)
    }

    // Where a link really is, only while the pointer is on its glyph (notes'
    // tip, the home folder as ~; notes' "Missing: " has no case here -- the
    // service never lists a broken link). Built only for the hovered link: a
    // tip per row costs 30 ms of every open.
    Loader {
        active: row.hovered && row.isLink && !!row.facts.realPath
        sourceComponent: HoverTip {
            objectName: "linkTip"
            anchorItem: linkGlyph
            overlayItem: row.overlayItem
            show: row.linkHovered
            text: row.facts ? String(row.facts.realPath || "").replace(/^\/home\/[^\/]+/, "~") : ""
            fontFamily: row.tune ? row.tune.fontFamily : "Inter"
        }
    }
}
