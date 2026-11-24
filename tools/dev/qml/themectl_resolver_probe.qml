pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "modules/common/theme"
import "modules/common/theme/ThemeResolve.js" as Resolve

// One theme through the shell's side of the resolver (tools/dev/themectl_resolver_parity.sh): THR_FIXTURE is read here and handed to
// ThemeResolve.js directly (every key, with Theme's L0), and the same file is the active theme of the Theme singleton
// (its XDG_CONFIG_HOME has it as theme/themes/parity.json), whose baseOf() is then asked for every declared token in both modes.
// The answers go to THR_OUT as one JSON object: { l0, lib_light, lib_dark, theme_light, theme_dark }.
ShellRoot {
    id: root
    settings.watchFiles: false

    FileView {
        id: fixture
        path: Quickshell.env("THR_FIXTURE")
        blockLoading: true
        printErrors: false
    }
    FileView {
        id: outFile
        path: Quickshell.env("THR_OUT")
        blockWrites: true
        printErrors: false
    }

    function tokens(): var {
        const o = {};
        const names = Theme.tokenNames;
        for (let i = 0; i < names.length; i++) {
            const c = Theme.baseOf(names[i]);
            o[names[i]] = [Math.round(c.r * 255), Math.round(c.g * 255), Math.round(c.b * 255), Math.round(c.a * 255)];
        }
        return o;
    }

    function run(): void {
        // started with no fixture (tools/dev/smoke.sh --all loads every harness bare): nothing to resolve
        if (!Quickshell.env("THR_FIXTURE")) {
            console.log("THR idle: no THR_FIXTURE (this probe is run by tools/dev/themectl_resolver_parity.sh)");
            Qt.quit();
            return;
        }
        const doc = JSON.parse(fixture.text());
        const out = { l0: Theme.defaults };
        out.lib_light = Resolve.resolveAll(Theme.defaults, doc.common, doc.light);
        out.lib_dark = Resolve.resolveAll(Theme.defaults, doc.common, doc.dark);
        out.theme_name = Theme.themeName;
        out.theme_light = root.tokens();
        Theme.setMode("dark");
        out.theme_dark = root.tokens();
        outFile.setText(JSON.stringify(out));
        console.log("THR RESULT done theme=" + Theme.themeName + " tokens=" + Object.keys(out.theme_light).length);
        quitTimer.start();
    }

    // Theme's own start-up (state, the theme file, the pair listing) is finished well inside this.
    Timer {
        interval: 500
        running: true
        onTriggered: root.run()
    }
    Timer {
        id: quitTimer
        interval: 200
        onTriggered: Qt.quit()
    }
}
