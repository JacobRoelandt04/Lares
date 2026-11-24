#!/usr/bin/env python3
"""Put a tripwire into every real service a MOCK shell must never build -- in a SANDBOX COPY, never the tree.

    tools/dev/shell_tripwires.py <sandbox dir>

Each service's file gets a property `_tripwire` right after its root's `id:` line, whose initial binding logs
"TRIPWIRE <Type>" (a binding with no dependencies runs once, at creation -- on any root type: a QtObject root takes no child
object, and a root that has a Component.onCompleted of its own cannot take a second), so any construction of the type says so on
the console. A mock shell (SHELL_SERVICES=mock) builds each module's
mock twin: silicon's service calls pkexec and its helper, the aerial service starts its helper, a persisted TimerService doubles the
alarms, BatteryData reads the embedded controller once a second -- none of them may exist, not even for a moment (the first
version of the shell started a SiliconService that way: its frame was made before the services had loaded, every owner was
handed null and built its own). The runners (shell_frame_probe.sh, shell_probe.sh) patch their copy with this and fail on any
TRIPWIRE line in the log.
"""
import re
import sys

sb = sys.argv[1]
targets = {
    "SiliconService": "modules/silicon/data/SiliconService.qml",
    "AerialService": "modules/aerial/data/AerialService.qml",
    "CalendarService": "modules/clock/data/CalendarService.qml",
    "WikiService": "modules/wiki/data/WikiService.qml",
    "ScreentimeService": "modules/screentime/data/ScreentimeService.qml",
    "StocksService": "modules/stocks/data/StocksService.qml",
    "WeatherService": "modules/weather/data/WeatherService.qml",
    "ClipboardService": "modules/clipboard/data/ClipboardService.qml",
    "MpdService": "modules/common/components/MpdService.qml",
    "PipewireService": "modules/bar/audio/data/PipewireService.qml",
    "ActiveWindowService": "modules/windowtray/data/ActiveWindowService.qml",
    "BatteryData": "modules/common/system/BatteryData.qml",
}
for name, rel in targets.items():
    p = f"{sb}/{rel}"
    s = open(p, encoding="utf-8").read()
    m = re.search(r"^[A-Z]\w+ \{\n", s, re.M)
    if not m:
        print("no root in", rel)
        sys.exit(1)
    m2 = re.compile(r"^    id: \w+\n", re.M).search(s, m.end())
    if not m2:
        print("no id in", rel)
        sys.exit(1)
    ins = f'    property bool _tripwire: {{ console.log("TRIPWIRE {name}"); return true; }}\n'
    open(p, "w", encoding="utf-8").write(s[:m2.end()] + ins + s[m2.end():])
