#!/usr/bin/env bash
# qml_census.sh -- which QML objects of a RUNNING Qt Quick process lost their storage to the collector while they live.
#
# An object in that state reads 0 / null for every property it declares and has no functions (the log says "Cannot find member data"
# when a binding reads an object-typed property of it, and nothing for the rest). The census is a small library loaded into the
# process (tools/dev/qml_census/livecensus.cpp): it walks every QObject tree once, on the GUI thread, and writes a report -- the dead
# by class, and every dead object with its flags ([I] C++-owned, [d] not; `nowrapper`), where it is declared and its parent chain.
#
#   tools/dev/qml_census.sh build              build the library (Qt's private headers); prints its path
#   tools/dev/qml_census.sh command [<pid>]    PRINT the command that loads it into a process (default: the deployed shell, pid from
#                                              lares's state). It needs root (kernel.yama.ptrace_scope = 1) and is the USER's to run:
#                                              this script never runs sudo and never attaches to anything it did not start.
#   tools/dev/qml_census.sh self-test          a private offscreen `qml` process, the library loaded with gdb, the report read back;
#                                              ends in QML_CENSUS RESULT PASS|FAIL
#
# The report lands in /tmp/qml-census-<uid>/report.txt (LIVECENSUS_OUT in the TARGET's environment names another file).
# RISK, said to the user with the command: gdb stops the process for ~0.3 s; stopped at a bad instant (inside malloc) the load can
# hang or crash it. Used 2026-11-14 on the user's shell (171 dead helpers): CLAUDE.md "A GC CYCLE THAT STARTS INSIDE A COMPONENT'S BUILD".
set -u
cd "$(dirname "$0")/../.." || exit 2
ROOT=$(pwd)
D="/tmp/qml-census-$(id -u)"
SO="$D/livecensus.so"
OUT="$D/report.txt"

build() {
    local qv q=/usr/include/qt6
    qv=$(pkg-config --modversion Qt6Qml 2> /dev/null)
    [ -n "$qv" ] && [ -f "$q/QtQml/$qv/QtQml/private/qqmlvmemetaobject_p.h" ] || { echo "qml_census: no Qt private headers for Qt6Qml '$qv'" >&2; return 1; }
    mkdir -p "$D" || return 1
    g++ -std=c++20 -O1 -fPIC -shared -o "$SO" "$ROOT/tools/dev/qml_census/livecensus.cpp" -DLIVECENSUS_DEFAULT_OUT="\"$OUT\"" \
        -I$q -I$q/QtCore -I$q/QtGui -I$q/QtQml -I$q/QtQuick -I$q/QtCore/$qv -I$q/QtCore/$qv/QtCore -I$q/QtQml/$qv -I$q/QtQml/$qv/QtQml \
        -lQt6Quick -lQt6Qml -lQt6Gui -lQt6Core > "$D/build.log" 2>&1 || { grep -m5 error "$D/build.log" >&2; echo "qml_census: the library does not build against Qt $qv" >&2; return 1; }
}
inject_args() {  # pid -> gdb's arguments, one per line
    printf '%s\n' -p "$1" -batch -ex 'set debuginfod enabled off' -ex "call ((void*(*)(const char*,int))dlopen)(\"$SO\", 2)" -ex detach
}

case "${1:-}" in
    build) build && echo "$SO" ;;
    command)
        build || exit 1
        pid=${2:-}
        if [ -z "$pid" ]; then pid=$(cat "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lares/pid" 2> /dev/null); fi
        [ -n "$pid" ] && [ -d "/proc/$pid" ] || { echo "qml_census: no such process '${pid:-}' (give a pid)" >&2; exit 1; }
        echo "# loads the census into pid $pid ($(tr '\0' ' ' < "/proc/$pid/cmdline" | cut -c1-80)); the report: $OUT"
        echo "sudo gdb -p $pid -batch -ex 'set debuginfod enabled off' -ex 'call ((void*(*)(const char*,int))dlopen)(\"$SO\", 2)' -ex detach"
        ;;
    self-test)
        build || { echo "QML_CENSUS RESULT FAIL (build)"; exit 1; }
        W=$(mktemp -d "$D/self.XXXXXX") || exit 2
        trap 'kill "$T" 2> /dev/null; rm -rf "$W"' EXIT
        printf '#include <sys/prctl.h>\n__attribute__((constructor)) static void init(void) { prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0); }\n' > "$W/ptracer.c"
        cc -shared -fPIC -o "$W/ptracer.so" "$W/ptracer.c" || { echo "QML_CENSUS RESULT FAIL (ptracer)"; exit 1; }
        printf 'import QtQuick\nItem { width: 10; height: 10\n    Repeater { model: 40; Item { property var v: [1]; function f() { return 1; } } }\n}\n' > "$W/t.qml"
        # this process allows itself to be traced: the test attaches to nothing but its own child
        env -u QS_CONFIG_PATH QT_QPA_PLATFORM=offscreen LD_PRELOAD="$W/ptracer.so" LIVECENSUS_OUT="$W/report.txt" /usr/lib/qt6/bin/qml "$W/t.qml" > "$W/target.log" 2>&1 &
        T=$!
        sleep 3
        mapfile -t args < <(inject_args "$T")
        gdb "${args[@]}" > "$W/gdb.log" 2>&1
        sleep 1
        if grep -q '^LIVECENSUS objects=[0-9]* vme=[1-9][0-9]* dead=0 ' "$W/report.txt" 2> /dev/null && kill -0 "$T" 2> /dev/null; then
            echo "  ok   $(head -1 "$W/report.txt")"; echo "QML_CENSUS RESULT PASS"; exit 0
        fi
        echo "  FAIL no report, or the target died: $(tail -2 "$W/gdb.log" | tr '\n' ' ')"; echo "QML_CENSUS RESULT FAIL (1)"; exit 1
        ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
