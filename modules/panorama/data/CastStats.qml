import QtQml

import "CastParse.js" as CP

// =============================================================================
// CastStats.qml -- the figures of the running cast (frames, rates, the round trip: docs/contracts/panorama.md 9.1 `stats`), published ONCE a
// beat and ONLY WHILE SOMETHING SHOWS THEM. CastService and CastMock hold one each, so the two cannot differ.
//
//   take(ev)            every event of the tool passes here; CastParse.js decides what it does to the figures
//   hold() / release()  one per shower (the cast display's detail): the first hold publishes what is known at once, the last release takes it back
//   value               the published figures (CastParse.js `figures`), null while nobody holds them or none are known
//
// What is known is kept in a plain holder no binding can see: with nobody looking, a beat costs one small object and wakes nothing.
// =============================================================================
QtObject {
    id: root

    readonly property var value: root._value
    readonly property int holds: root._holds

    function hold(): void {
        root._holds++;
        root._publish();
    }
    function release(): void {
        root._holds = Math.max(0, root._holds - 1);
        root._publish();
    }
    function take(ev: var): void {
        const next = CP.figures(root._known.figures, ev);
        if (next === root._known.figures)
            return;
        root._known.figures = next;
        root._publish();
    }

    property int _holds: 0
    property var _value: null
    readonly property var _known: ({ figures: null })
    function _publish(): void {
        root._value = root._holds > 0 ? root._known.figures : null;
    }
}
