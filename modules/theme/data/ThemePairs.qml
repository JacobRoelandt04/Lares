pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"

// =============================================================================
// ThemePairs.qml -- what the theme popup shows, one per shell (ThemeControl holds it).
//
//   names     the pairs on disk, sorted: a Repeater's model. It holds no colour, and is only reassigned when it changes. With `order`
//             (shell.jsonc theme.pairs) it is those of it that are on disk, in its order, and the pair in force when it is not among them.
//   entries   name -> { name, modes: ["light", "dark"], light: colours, dark: colours }. Colours are the mode's own resolved values, as DATA: a card shows a pair that is not
//             in force, so nothing here may follow the theme, and a Theme token in here would rebuild the cards on every frame of a crossfade (CLAUDE.md, A REPEATER'S MODEL).
//   rescan()  read it all again, on every open: a pair added or edited while the shell runs (`ls` ran at the start, and nothing watches the directories).
//
// Nothing runs until the first rescan(), which is the prewarm's or the first open's.
// =============================================================================
QtObject {
    id: root

    readonly property var names: root._names
    readonly property var entries: root._entries

    // The tokens a card draws with.
    readonly property var colorKeys: ["surface", "panelSunk", "listBox", "headerBox", "border", "shadowDeep", "textPrimary", "textMuted", "textFaint", "accent", "ok", "warn", "error",
        "terminalBg", "terminalFg", "ansiRed", "ansiGreen", "ansiYellow", "ansiBlue", "ansiMagenta", "ansiCyan", "hyprBorderActive", "hyprBorderInactive"]

    property var order: []
    onOrderChanged: root._rebuild()

    property var _names: []
    property var _entries: ({})
    property string _sig: ""
    property bool _used: false

    function rescan(): void {
        root._used = true;
        Theme.rescanPairs();
        root._rebuild();
    }
    property Connections _theme: Connections {
        target: Theme
        function onPairsChanged() {
            root._rebuild();
        }
    }

    // A pair's colours, resolved once per text of its file: every open comes through here on the GUI thread, on its way to moving, and a resolve of three pairs is 6 ms of
    // the shell's JS. name -> { text, modes: { light: colours, dark: colours } }; a plain map nobody binds to. A file that does not parse (an editor mid-save) has no modes.
    property var _resolved: ({})
    function _colours(name: string): var {
        const text = Theme.pairText(name);
        const have = root._resolved[name];
        if (have && have.text === text)
            return have.modes;
        const modes = {};
        let doc = null;
        try {
            doc = text.length > 0 ? JSON.parse(text) : null;
        } catch (e) {
            doc = null;
        }
        for (const m of ["light", "dark"]) {
            const colors = doc && typeof doc === "object" ? Theme.resolvedColors(doc, m, root.colorKeys) : null;
            if (colors)
                modes[m] = colors;
        }
        root._resolved[name] = { text: text, modes: modes };
        return modes;
    }

    function _rebuild(): void {
        if (!root._used)
            return;
        const all = Theme.pairs || [];
        const listed = root.order.filter((n, i) => all.indexOf(n) >= 0 && root.order.indexOf(n) === i);
        const pairs = listed.length === 0 ? all : listed.indexOf(Theme.themeName) >= 0 ? listed : listed.concat([Theme.themeName]);
        const names = [];
        const entries = {};
        for (let i = 0; i < pairs.length; i++) {
            const name = pairs[i];
            const colours = root._colours(name);
            const e = { name: name, modes: ["light", "dark"].filter(m => colours[m]) };
            if (e.modes.length === 0)
                continue;
            for (const m of e.modes)
                e[m] = colours[m];
            names.push(name);
            entries[name] = e;
        }
        // a read that found what the last one found changes nothing: no delegate is touched by an open
        const sig = JSON.stringify(entries);
        if (sig === root._sig)
            return;
        root._sig = sig;
        root._entries = entries;
        if (names.join("\n") !== root._names.join("\n"))
            root._names = names;
    }
}
