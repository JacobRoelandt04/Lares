pragma ComponentBehavior: Bound

import QtQuick

import "../common/components"
import "popup"

// =============================================================================
// PanoramaBarOwner.qml -- the machine popup on the machine island (docs/contracts/panorama.md section 5; decision 9: the glyph is always
// there, a click toggles the popup, no key, no quick switch). ONE popup, TWO TABS (the user, 2026-11-21): "Displays" (the arrangement) and
// "Presets" (the saved desktops, modules/presets), behind this one button.
//
// THE TAB (`currentTab`, held HERE like the clock's): decided at the click by SITUATION (`situationTab`): Displays when a display besides the
// laptop's is connected (on a machine with no panel of its own: a second display) or a mirror is up, Presets when the machine's own screen is
// all there is. A tab clicked or swiped inside the popup is
// written back, and the next click decides again. "Arrange…" (`openWith(name)`) always opens Displays. A content built ahead of the click or
// kept parked is told the tab through a Binding (RestoreNone): its own first assignment would kill a plain binding.
//
// THE SHELL (docs/contracts/shell.md section 4): hosted, it builds no service (the host injects the ONE PanoramaService and the ONE
// PresetsService; null = the feature is absent), writes none of its properties (`sharedFlags.popupOpen` is ORed by the host over the screens and
// written once) and registers no shortcut. Not hosted and with no service handed in (a mockup, a bare bar), it runs a PanoramaMock of its own
// on its "desk" scenario and no presets.
//
// `popupOpen` MEANS "THE DISPLAYS TAB IS ON SHOW": the service reads the monitors' DDC state and the panel's backlight only then, so the
// Presets tab (the laptop alone, usually) costs the displays nothing; switching to Displays raises it.
//
// A PRESETS OPEN reads the saved desktops and the windows as they are now again (a preset saved from a terminal; the save card), on the open
// and whenever the Presets tab comes on show. A LOAD from the Presets tab closes the popup (the windows move under it) and the glyph's
// flourish plays once (`deal()` of the button), so the click is answered on the bar.
//
// A CAST BEING MADE is the button's to show (`working`: the hover hue, the flourish over and over): the owner writes it there from the service's
// `castWorking`, whoever started the cast and whether or not a popup is open -- every screen's owner its own button.
//
// The never-seen toast's "Arrange…" (`service.openRequested(name)`) opens the popup with that display's tile selected -- on the FOCUSED
// screen's owner only (unaddressed requests go there: the host routes it, `focusedOwner`). Apply closes the popup (decision 32: the keep
// toast must be in plain view): the content emits `closeRequested`.
// =============================================================================
Item {
    id: owner

    property var engine: null                 // GooeyEngine
    property var bar: null                    // GooeyBar
    property string barId: ""
    property string ownerId: "panorama"
    property Item anchorItem: null            // the bar button the popup hangs from

    // ---- the shell (CONTRACT section 4) ----
    property bool shellHosted: false
    readonly property var sharedFlags: ({
            popupOpen: owner.popupMine && owner.currentTab === "displays"
        })

    // ---- the services: injected, else our own mock (and no presets) ----
    property var service: null
    readonly property var svc: owner.service ?? ownService.item
    property var presets: null                // PresetsService (ShellServices: one per shell)
    property var appLookup: null              // AppLookup (the presets' icons)

    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen
                                      && owner.engine.popupOwnerId === owner.ownerId
    readonly property bool popupPresent: !!owner.engine && owner.engine.thePopup.ownerId === owner.ownerId && owner.engine.thePopup.phase !== "closed"
    readonly property bool _windowShown: owner.Window.window ? owner.Window.window.visible : true

    property string fontFamily: "Inter"
    property real renderScale: owner.engine ? owner.engine.renderScale : 1

    // the tab on show (held here), and the one the situation gives
    property string currentTab: "displays"
    readonly property string situationTab: {
        const s = owner.svc;
        if (!s)
            return "displays";
        const ds = s.displays || [];
        // a display besides the machine's own: an external beside a laptop's panel, a second one on a machine that has none
        const more = ds.some(d => d.internal) ? ds.some(d => !d.internal) : ds.length > 1;
        // a cast that runs or connects is a display going on: the tab is Displays (the chip is there to stop it)
        return more || s.mirroring === true || s.castActive === true ? "displays" : "presets";
    }

    // the tile the next open selects ("" = none: the popup opens with no side popup)
    property string _select: ""

    Loader {
        id: ownService
        active: owner.service === null && !owner.shellHosted
        source: owner.service === null && !owner.shellHosted ? Qt.resolvedUrl("data/PanoramaMock.qml") : ""
    }
    Binding {
        target: ownService.item
        property: "scenario"
        value: "desk"
        when: !!ownService.item
    }
    Binding {
        target: owner.svc
        property: "popupOpen"
        value: owner.popupMine && owner.currentTab === "displays"
        when: !owner.shellHosted && !!owner.svc
    }

    readonly property Component popupComponent: Component {
        PanoramaTabs {
            id: content
            service: owner.svc
            presets: owner.presets
            appLookup: owner.appLookup
            fontFamily: owner.fontFamily
            renderScale: owner.renderScale
            motionRunning: owner.popupPresent && owner._windowShown
            selected: owner._select
            currentTab: owner.currentTab
            restTab: owner.situationTab
            onCurrentTabChanged: owner.currentTab = content.currentTab
            onCloseRequested: owner.close()
            onPresetLoadStarted: owner._dealTheGlyph()
            // the plain bindings above die at the content's own first assignment (a tab clicked, a tile picked); a content kept parked
            // between opens is told what the OWNER chose for the open that adopts it
            Binding {
                target: content
                property: "currentTab"
                value: owner.currentTab
                restoreMode: Binding.RestoreNone
            }
            Binding {
                target: content
                property: "selected"
                value: owner._select
                restoreMode: Binding.RestoreNone
            }
        }
    }

    // The pointer resting on the glyph: the content is built ahead of the click (parked), on the tab the click will show.
    HoverIntent {
        target: owner.anchorItem
        onIntent: {
            if (owner.engine && owner.svc && !owner.popupMine) {
                owner.currentTab = owner.situationTab;
                owner.engine.prebuild(owner.ownerId, owner.popupComponent, { parked: true });
            }
        }
    }

    function toggle() {
        if (owner.popupMine)
            owner.close();
        else {
            owner.currentTab = owner._tabAtOpen();
            owner._opened = true;
            owner.open();
        }
    }

    // panorama.jsonc openTab: "situation" (the rule above), "displays", "presets", or "last" (the tab the popup was left on; the situation the
    // first time)
    readonly property string openTab: owner.svc && owner.svc.settings && owner.svc.settings.openTab ? owner.svc.settings.openTab : "situation"
    property bool _opened: false
    function _tabAtOpen(): string {
        if (owner.openTab === "displays" || owner.openTab === "presets")
            return owner.openTab;
        if (owner.openTab === "last" && owner._opened)
            return owner.currentTab;
        return owner.situationTab;
    }

    // A tab by name (shell.jsonc clicks: "displays", "presets"): the popup opens on it, or one that is up turns to it.
    function openOn(tab: string) {
        owner.currentTab = tab === "presets" ? "presets" : "displays";
        owner._opened = true;
        if (!owner.popupMine)
            owner.open();
    }

    // Opens the popup on `currentTab` as it stands -- the mechanism. The default-tab rule is toggle()'s, the click's.
    function open() {
        if (!owner.engine || !owner.bar || !owner.anchorItem || owner.popupMine || !owner.svc)
            return;
        owner._readPresets();
        // A whole middle: the popup rests about it and its tiles land on whole pixels.
        const centre = Math.round(owner.anchorItem.mapToItem(owner.bar, owner.anchorItem.width / 2, owner.anchorItem.height / 2).x);
        owner.engine.open(owner.ownerId, owner.barId, centre, null, null, false, owner.popupComponent, 1);
    }

    // "Arrange…" on the never-seen toast: Displays, with that display's tile selected (a parked content is told through its Binding).
    function openWith(name: string) {
        owner._select = name;
        owner.currentTab = "displays";
        if (owner.popupMine && owner.engine.contentItem && owner.engine.contentItem.selected !== undefined)
            owner.engine.contentItem.selected = name;
        else
            owner.open();
    }

    function close() {
        if (owner.popupMine)
            owner.engine.close();
        owner._select = "";
    }

    // the saved desktops and the windows as they are NOW (the content may be a parked one, whose Component.onCompleted ran long ago)
    function _readPresets() {
        if (!owner.presets)
            return;
        owner.presets.refresh();
        owner.presets.refreshCurrent();
    }
    onCurrentTabChanged: {
        if (owner.popupMine && owner.currentTab === "presets")
            owner._readPresets();
    }
    // While the Presets tab is on show the save card follows the desktop: this popup holds the service's watch (PresetsService), and a
    // display change Panorama sees is told to it (Hyprland's own events it hears itself).
    readonly property bool _presetsShown: owner.popupMine && owner.currentTab === "presets"
    on_PresetsShownChanged: {
        if (!owner.presets)
            return;
        if (owner._presetsShown)
            owner.presets.holdWatch(owner);
        else
            owner.presets.releaseWatch(owner);
    }
    Component.onDestruction: {
        if (owner.presets)
            owner.presets.releaseWatch(owner);
    }
    Connections {
        target: owner.svc
        enabled: owner._presetsShown && !!owner.presets
        function onDisplaysChanged() {
            owner.presets.desktopChanged("displays");
        }
    }

    // a cast being made, on the button (a host whose anchor is another item has no such word)
    readonly property bool _castWorking: !!owner.svc && owner.svc.castWorking === true
    readonly property bool _castActive: !!owner.svc && owner.svc.castActive === true
    on_CastWorkingChanged: owner._tellTheGlyph()
    on_CastActiveChanged: owner._tellTheGlyph()
    onAnchorItemChanged: owner._tellTheGlyph()
    function _tellTheGlyph(): void {
        // qmllint disable missing-property
        if (owner.anchorItem && owner.anchorItem.working !== undefined)
            owner.anchorItem.working = owner._castWorking;
        if (owner.anchorItem && owner.anchorItem.casting !== undefined)
            owner.anchorItem.casting = owner._castActive;
        // qmllint enable missing-property
    }

    // A preset load began on the Presets tab: the glyph deals its tiles once, as the popup goes (the button answers the click on the bar).
    function _dealTheGlyph() {
        Qt.callLater(() => {
            // qmllint disable missing-property
            if (owner.anchorItem && typeof owner.anchorItem.deal === "function")
                owner.anchorItem.deal();
        });
    }
}
