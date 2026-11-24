import QtQuick
import Quickshell
import Quickshell.Io
import "modules/common/components"
import "modules/common/components/JsonComments.js" as JsonComments

// tools/dev/qml/configfile_probe.qml -- ConfigFile (`<name>.jsonc` first, then `<name>.json`), on files in CF_DIR
// (tools/dev/configfile_probe.sh runs it, in a private directory). Prints CF lines and "CF RESULT PASS|FAIL".
Scope {
    id: root
    property string dir: Quickshell.env("CF_DIR")
    property int fails: 0
    property int checks: 0
    property string armName: Quickshell.env("CF_ARM") || ""

    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok) root.fails++;
        console.log("CF " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }
    function parsed(t: string): var {
        try { return JSON.parse(JsonComments.strip(t)); } catch (e) { return null; }
    }

    // a.json only (a comment in it); b has both; c neither; d is named .jsonc with only the .json there; plain.txt is no JSON name
    ConfigFile { id: a;  path: root.dir + "/a.json" }
    ConfigFile { id: b;  path: root.dir + "/b.json" }
    ConfigFile { id: c;  path: root.dir + "/c.json" }
    ConfigFile { id: d;  path: root.dir + "/d.jsonc" }
    ConfigFile { id: p;  path: root.dir + "/plain.txt" }
    ConfigFile { id: e;  path: root.dir + "/e.json" }
    // THE config/ FOLDER (2026-11-12): named where it lives; the same names one level up are where every config lived before
    ConfigFile { id: f;  path: root.dir + "/config/f.jsonc" }        // only the old f.jsonc
    ConfigFile { id: g;  path: root.dir + "/config/g.jsonc" }        // only the old g.json
    ConfigFile { id: h;  path: root.dir + "/config/h.jsonc" }        // both config/h.jsonc and the old h.jsonc
    ConfigFile { id: k;  path: root.dir + "/fresh/config/k.jsonc" }  // none, and no config/ folder yet
    // a host reading at ITS Component.onCompleted, which runs before its child's (the notification service does)
    Item {
        id: host
        property string seen: "unset"
        ConfigFile { id: hcf; path: root.dir + "/a.json" }
        Component.onCompleted: host.seen = hcf.text()
    }

    property int step: 0
    property bool waiting: false
    property int ticks: 0
    function sh(cmd: string): void { runner.command = ["sh", "-c", cmd]; runner.running = true; }

    Process { id: runner }

    // The sequence: each step starts a shell edit and waits for a condition on the config files, never for a time.
    function goto(n: int): void { root.step = n; root.waiting = true; root.ticks = 0; }

    function cond(): bool {
        switch (root.step) {
        case 1: return a.active === "jsonc";
        case 2: return a.active === "json";
        case 3: return e.active === "jsonc" && c.jsoncExists;
        case 4: return f.active === "jsonc" && k.jsoncExists;
        }
        return true;
    }

    Timer {
        interval: 25
        repeat: true
        running: true
        onTriggered: {
            if (root.step === 0) {
                // the state at creation
                root.check("a: only a.json -> active json", a.active === "json" && a.exists && !a.jsoncExists && a.jsonExists, a.active);
                root.check("a: the .json's text, comments and all", a.text().indexOf("// from a.json") >= 0, a.text());
                root.check("a: the text parses with the comments stripped", root.parsed(a.text()) && root.parsed(a.text()).from === "a.json", a.text());
                root.check("a: activePath is the .json", a.activePath === root.dir + "/a.json", a.activePath);
                root.check("a host's own Component.onCompleted (before its child's) already reads the file in force", host.seen.indexOf("from a.json") >= 0, host.seen);
                root.check("b: both exist -> the .jsonc wins", b.active === "jsonc" && b.jsoncExists && b.jsonExists, b.active);
                root.check("b: the .jsonc's text", root.parsed(b.text()) && root.parsed(b.text()).from === "b.jsonc", b.text());
                root.check("c: neither -> no file, empty text, activePath is the .jsonc", !c.exists && c.active === "" && c.text() === "" && c.activePath === root.dir + "/c.jsonc", c.activePath);
                root.check("d: a .jsonc name with only the .json there reads the .json", d.active === "json" && root.parsed(d.text()) && root.parsed(d.text()).from === "d.json", d.active + " " + d.text());
                root.check("d: the pair is the same whichever name was given", d.jsonPath === root.dir + "/d.json" && d.jsoncPath === root.dir + "/d.jsonc", d.jsonPath);
                root.check("plain.txt: one file, no sibling", p.jsonPath === "" && p.active === "jsonc" && p.text() === "plain\n", p.active + "|" + p.text());
                root.check("f: config/f.jsonc absent -> the old f.jsonc one level up is read", f.active === "oldJsonc" && root.parsed(f.text()) && root.parsed(f.text()).from === "old f.jsonc"
                           && f.activePath === root.dir + "/f.jsonc", f.active + " " + f.activePath);
                root.check("g: only the old g.json -> read", g.active === "oldJson" && root.parsed(g.text()) && root.parsed(g.text()).from === "old g.json", g.active);
                root.check("h: config/ and the old place both there -> config/ wins", h.active === "jsonc" && h.oldJsoncExists && root.parsed(h.text()).from === "config/h.jsonc", h.active);
                root.check("k: none -> activePath (a first write) is config/k.jsonc", !k.exists && k.activePath === root.dir + "/fresh/config/k.jsonc", k.activePath);
                root.check("a plain folder has no old place", a.oldJsoncPath === "" && a.oldJsonPath === "", a.oldJsoncPath);
                // step 1: a .jsonc appears beside a.json
                root.sh("printf '{ \"from\": \"a.jsonc\" } // later\\n' > '" + root.dir + "/a.jsonc'");
                root.goto(1);
                return;
            }
            if (!root.waiting) return;
            root.ticks++;
            if (root.cond()) {
                root.waiting = false;
                root.after(root.step);
            } else if (root.ticks > 200) {
                root.check("step " + root.step + " reached", false, "timed out; a=" + a.active + " e=" + e.active + " f=" + f.active + " k=" + k.active + "/" + k.jsoncExists);
                root.finish();
            }
        }
    }

    function after(s: int): void {
        switch (s) {
        case 1:
            root.check("a: a .jsonc created later is followed in place", a.active === "jsonc" && root.parsed(a.text()).from === "a.jsonc", a.active + " " + a.text());
            root.sh("rm '" + root.dir + "/a.jsonc'");
            root.goto(2);
            break;
        case 2:
            root.check("a: the .jsonc removed -> back to the .json", a.active === "json" && root.parsed(a.text()).from === "a.json", a.active);
            // a write with neither file creates the .jsonc; a write with only a .json goes to the .json
            c.setText("{ \"v\": 1 }\n");
            a.setText("{ \"from\": \"a.json\", \"v\": 2 }\n");
            // the first write of c is a child process (mkdir + the file), so the readback waits for its file (up to 3 s), and for a's write
            root.sh("i=0; while { [ ! -s '" + root.dir + "/c.jsonc' ] || ! grep -q '\"v\": 2' '" + root.dir + "/a.json'; } && [ $i -lt 60 ]; do sleep 0.05; i=$((i+1)); done; "
                    + "cat '" + root.dir + "/c.jsonc' > '" + root.dir + "/c.written'; test ! -e '" + root.dir + "/c.json'; echo $? > '" + root.dir + "/c.nojson'; cat '" + root.dir + "/a.json' > '" + root.dir + "/a.written'; test ! -e '" + root.dir + "/a.jsonc'; echo $? > '" + root.dir + "/a.nojsonc'; printf '{ \"v\": 2 }' > '" + root.dir + "/e.jsonc'");
            root.goto(3);
            break;
        case 3:
            root.check("c: setText with neither file creates the .jsonc", c.active === "jsonc" || c.jsoncExists, c.active);
            readback.running = true;
            return;
        case 4:
            root.check("f: moved into config/ while read -> followed in place", f.active === "jsonc" && root.parsed(f.text()).from === "old f.jsonc"
                       && f.activePath === root.dir + "/config/f.jsonc", f.active + " " + f.activePath);
            root.check("k: a first write made config/ and landed in config/k.jsonc", k.jsoncExists && root.parsed(k.text()) && root.parsed(k.text()).from === "k", k.active + " " + k.text());
            root.finish();
            return;
        }
    }

    Process {
        id: readback
        command: ["sh", "-c", "echo c=$(cat '" + root.dir + "/c.written') cn=$(cat '" + root.dir + "/c.nojson') a=$(cat '" + root.dir + "/a.written') an=$(cat '" + root.dir + "/a.nojsonc')"]
        stdout: StdioCollector {
            onStreamFinished: {
                const t = this.text;
                root.check("c: the write landed in c.jsonc and no c.json was made", t.indexOf("c={ \"v\": 1 }") >= 0 && t.indexOf("cn=0") >= 0, t);
                root.check("a: the write landed in a.json (the only one there) and no a.jsonc was made", t.indexOf("\"v\": 2") >= 0 && t.indexOf("an=0") >= 0, t);
                // the user moves f into config/ while it is read; a first write with no config/ folder makes it
                root.sh("mv '" + root.dir + "/f.jsonc' '" + root.dir + "/config/f.jsonc'");
                k.setText("{ \"from\": \"k\" }\n");
                root.goto(4);
            }
        }
    }

    function finish(): void {
        console.log("CF RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + ")");
        quitTimer.start();
    }
    Timer { id: quitTimer; interval: 0; onTriggered: Qt.quit() }
}
