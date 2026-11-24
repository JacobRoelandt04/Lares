// probe.cpp -- Qt's incremental collector loses live QML objects when a component root gets its parent between two slices of
// one cycle. tools/dev/qt_gc_attach_probe.sh builds and runs it; CLAUDE.md "A GC CYCLE THAT STARTS INSIDE A COMPONENT'S BUILD".
//
// THE FAULT (Qt 6.12, src/qml/memory/qv4mm.cpp, read 2026-11-14). The collector keeps a QObject's JS wrapper -- and through it the
// object's property / function storage, which is only a WEAK reference of the object -- alive in two ways:
//   the scan     markWeakValues: a wrapper is marked when its object, or the TOP of its QObject parent chain, is C++-owned or the root
//                in creation (QQmlData::keepAliveDuringGarbageCollection);
//   the rescue   QObjectWrapper::markObjects: a marked wrapper of an object with NO parent marks every QObject below it -- decided when
//                the wrapper is POPPED from the mark stack, not when it was pushed.
// While a nested component is built its root has no parent yet (QQmlObjectCreator sets it after the sub-creator returns), so the scan
// refuses everything below it that is no longer pinned on the JS stack (the helpers of its finished sub-components), and the rescue
// is what saves them. A cycle that STARTS inside a synchronous build runs one time slice there (runGC blocks itself until the sweep:
// allocations do not continue it) and resumes on the event loop -- after the builder (Quickshell's Variants: create, then setParent;
// QQmlComponent::createObject(parent) and a Loader do the same) gave the new root its parent. So: the scan refused the helpers, the
// shell root's rescue walk ran in the first slice, before the new tree hung below it, and the new root is popped WITH a parent: no
// rescue. Every non-visual helper of a finished sub-component built before the cycle began loses its wrapper and its storage, and
// lives on reading 0 / null with no functions ("Cannot find member data"). Items survive: a QQuickItem's wrapper marks its child
// items whatever its parent. The user's bar, 2026-11-14: 171 objects (Connections, Timers, PosedGlyph's paths, HoverArm, styles).
//
// THE PROBE drives the collector's state machine by hand from a C++ object built inside the nested component (GcProbe):
//   mode 0   the cycle's first slice inside the build (the scan, one drain batch), the rest after the parent is set   -> the fault
//   mode 1   the whole cycle inside the build (what a non-incremental collector does)                                -> nobody dies
//   mode 2   no cycle inside the build                                                                               -> nobody dies
//   CURE=1   mode 0 with RootCure.qml: gc() in the root's Component.onCompleted finishes the cycle in flight while the root still
//            has no parent, so its rescue walk runs                                                                  -> nobody dies
// It prints `GCATTACH mode=<m> cure=<0|1> vme=<n> dead=<n> nowrapper=<n>` and the dead by class.
#include <QtGui/QGuiApplication>
#include <QtQml/QQmlEngine>
#include <QtQml/QQmlComponent>
#include <QtQml/qqml.h>
#define private public
#define protected public
#include <private/qqmlvmemetaobject_p.h>
#undef private
#undef protected
#include <private/qobject_p.h>
#include <private/qqmldata_p.h>
#include <private/qv4engine_p.h>
#include <private/qv4mm_p.h>
#include <private/qjsengine_p.h>
#include <cstdio>
#include <cstdlib>

using namespace QV4;

static QQmlEngine *g_engine = nullptr;
static int g_mode = 0;

static MemoryManager *mm() { return g_engine->handle()->memoryManager; }
static void finish()
{
    auto *sm = mm()->gcStateMachine.get();
    int guard = 0;
    while (sm->inProgress() && ++guard < 1000000)
        sm->step();
}

class Anchor : public QObject
{
    Q_OBJECT
};

// Built as a late child of the nested component: at this instant the component's root has no parent.
class GcProbe : public QObject
{
    Q_OBJECT
public:
    GcProbe()
    {
        auto *sm = mm()->gcStateMachine.get();
        // one state per step(): the deadline has always expired when a state returns
        sm->timeLimit = std::chrono::microseconds(1);
        finish();   // nothing in flight: the cycle below STARTS here, as an allocation over the limit starts one
        if (g_mode == 2)
            return;
        int guard = 0;
        do {
            sm->step();
        } while (sm->inProgress() && sm->state != GCState::MarkDrain && ++guard < 1000000);
        // one deadline's worth of the drain (MarkLoopIterationCountForDrain pops): the shell root is popped, the new root is not
        if (g_mode == 0 && sm->inProgress())
            sm->step();
        if (g_mode == 1)
            finish();
    }
};

static int storageState(QObject *o)   // 0 none, 1 alive, 2 collected while the object lives
{
    QQmlData *d = QQmlData::get(o);
    if (!d || !d->hasVMEMetaObject)
        return 0;
    int st = 0;
    for (QQmlVMEMetaObject *m = QQmlVMEMetaObject::get(o); m; m = m->parentVMEMetaObject()) {
        if (!m->m_propertyAndMethodStorage.valueRef())
            continue;
        if (m->m_propertyAndMethodStorage.isUndefined())
            return 2;
        st = 1;
    }
    return st;
}

int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);
    g_mode = argc > 1 ? atoi(argv[1]) : 0;
    const bool cure = qEnvironmentVariableIsSet("CURE");
    qmlRegisterType<GcProbe>("Probe", 1, 0, "GcProbe");
    qmlRegisterType<Anchor>("Probe", 1, 0, "Anchor");
    QQmlEngine engine;
    g_engine = &engine;

    // the shell's root (made first, C++-owned, never has a parent) and the Variants object under it
    QQmlComponent topComp(&engine, QUrl::fromLocalFile(QStringLiteral("Top.qml")));
    QObject *top = topComp.create();
    if (!top) {
        printf("GCATTACH LOADFAIL %s\n", qPrintable(topComp.errorString()));
        return 2;
    }
    QObject *variants = new QObject(top);

    // one synchronous build, then what Quickshell's Variants does next (src/core/variants.cpp, 0.3.2)
    QQmlComponent comp(&engine, QUrl::fromLocalFile(cure ? QStringLiteral("RootCure.qml") : QStringLiteral("Root.qml")));
    QObject *root = comp.create();
    if (!root) {
        printf("GCATTACH LOADFAIL %s\n", qPrintable(comp.errorString()));
        return 2;
    }
    QQmlEngine::setObjectOwnership(root, QQmlEngine::CppOwnership);
    root->setParent(variants);

    finish();   // the rest of the cycle, on "the event loop": everything has its parent now
    mm()->gcStateMachine->timeLimit = std::chrono::microseconds(0);
    mm()->runFullGC();   // and one more whole cycle, as any later collection is

    int total = 0, dead = 0, nowrap = 0;
    QHash<QByteArray, int> by;
    QList<QObject *> q{ root };
    while (!q.isEmpty()) {
        QObject *o = q.takeLast();
        q += o->children();
        QQmlData *d = QQmlData::get(o);
        const int st = storageState(o);
        if (!d || !st)
            continue;
        ++total;
        if (d->jsWrapper.isUndefined())
            ++nowrap;
        if (st == 2) {
            ++dead;
            by[QByteArray(o->metaObject()->className()).split('_')[0] + " in " + QByteArray(o->parent()->metaObject()->className()).split('_')[0]]++;
        }
    }
    printf("GCATTACH mode=%d cure=%d vme=%d dead=%d nowrapper=%d\n", g_mode, int(cure), total, dead, nowrap);
    for (auto it = by.cbegin(); it != by.cend(); ++it)
        printf("GCATTACH   dead %4d  %s\n", it.value(), it.key().constData());
    return 0;
}

#include "probe.moc"
