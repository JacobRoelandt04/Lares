import QtQuick

// =============================================================================
// FactGrid.qml -- the settings' facts flow left to right, top to bottom with no hole. Its children are Captioned blocks: a `half` block takes
// one of two columns, any other the whole row; a hidden block (`shown` false) takes nothing; a half block with no partner (the last one, or the
// one before a full-width block) stands in the LEFT column. The plan is ONE binding over the children's `shown`, `half` and `implicitHeight`,
// applied in its change handler (positions only: nothing the plan reads), so a block that comes or goes moves everything in one turn and
// `implicitHeight` steps once (the engine eases the box).
// =============================================================================
Item {
    id: grid

    property real gap: 12
    readonly property real _half: Math.floor((grid.width - grid.gap) / 2)

    readonly property var plan: {
        const kids = grid.children, W = grid.width, hw = grid._half;
        const items = [];
        let y = 0, rowH = 0, right = false;
        for (let i = 0; i < kids.length; i++) {
            const c = kids[i];
            if (!("shown" in c))
                continue;
            const h = c.shown ? c.implicitHeight : 0;
            if (!c.shown) {
                items.push({ item: c, x: 0, y: y, w: W });
            } else if (c.half) {
                if (!right) {
                    items.push({ item: c, x: 0, y: y, w: hw });
                    rowH = h;
                    right = true;
                } else {
                    items.push({ item: c, x: W - hw, y: y, w: hw });
                    y += Math.max(rowH, h);
                    rowH = 0;
                    right = false;
                }
            } else {
                if (right) {
                    y += rowH;
                    rowH = 0;
                    right = false;
                }
                items.push({ item: c, x: 0, y: y, w: W });
                y += h;
            }
        }
        if (right)
            y += rowH;
        return { items: items, total: y };
    }

    implicitHeight: grid.plan.total
    height: grid.implicitHeight

    function _apply(): void {
        for (const p of grid.plan.items) {
            p.item.x = p.x;
            p.item.y = p.y;
            p.item.width = p.w;
        }
    }
    onPlanChanged: grid._apply()
    Component.onCompleted: grid._apply()
}
