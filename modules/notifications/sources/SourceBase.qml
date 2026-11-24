pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// SourceBase.qml -- what every notification source is made of.
//
// A source is an Item that LISTENS to one module's service and SAYS what it finds
// through `post` / `withdraw`. It is declared once by the host (NotificationSources) with the
// service it needs; it does nothing until it is `active`: the shell is live, its block in
// notifications.jsonc does not say `enabled: false`, and its service is there (`ready`).
// Going inactive withdraws everything it said, so switching a source off while its card
// is on screen takes the card away.
//
//   host        the NotificationSources: settings, the shared clock, the state file,
//               the owners to open, the program runner
//   sourceId    the slug: the `sources.<id>` block of notifications.jsonc, the record's
//               sourceId, the manager's group key
//   appName     what the card calls it ("System update")
//   glyph       its icon (SourceGlyphs)
//   keys        every key it posts under (the no-service fallback's pool)
//   ready       the source's own part of the switch: the service it listens to exists
//   active      host.live && enabled && ready && host.allows(sourceId) (readonly)
//   settings    this source's resolved block (SourceSettings)
//   attended    the source's own popup is open: its posts file silently
//   post(key, spec) / withdraw(key)
//
// A source implements `onActivated` / `onDeactivated` for what it must start and stop (a
// timer, a stream); the base has already withdrawn its posts when `active` falls.
// =============================================================================
Item {
    id: src
    visible: false

    property var host: null
    property string sourceId: ""
    property string appName: ""
    property string glyph: ""
    property var keys: []
    property bool ready: true
    property bool attended: false

    readonly property var settings: src.host ? src.host.settingsOf(src.sourceId) : ({ enabled: true })
    readonly property bool active: !!src.host && src.host.live && src.host.allows(src.sourceId) && src.settings.enabled !== false && src.ready

    function post(key, spec) {
        return posterItem.post(key, spec);
    }
    function update(uid, patch) {
        return posterItem.update(uid, patch);
    }
    function withdraw(key) {
        posterItem.withdraw(key);
    }
    function has(key) {
        return posterItem.has(key);
    }

    // The source switches on / off (once it has been built: a parent's onCompleted can run before its
    // children's, so the first `activated` waits a turn). A derived source starts and stops what it owns in
    // these two, never in its own onActiveChanged / onCompleted (a base and a derived handler on one name
    // is a question the language answers differently per kind of handler).
    signal activated()
    signal deactivated()
    property bool _begun: false
    function _begin() {
        src._begun = true;
        if (src.active)
            src.activated();
    }
    onActiveChanged: {
        if (!src._begun)
            return;
        if (src.active) {
            src.activated();
        } else {
            posterItem.withdrawAll();
            src.deactivated();
        }
    }
    Component.onCompleted: {
        if (src.host)
            src.host.register(src);
        Qt.callLater(src._begin);
    }
    Component.onDestruction: {
        if (src.host && src.host.unregister)
            src.host.unregister(src);
    }

    SourcePoster {
        id: posterItem
        sourceId: src.sourceId
        appName: src.appName
        glyph: src.glyph
        keys: src.keys
        attended: src.active && src.attended
    }
}
