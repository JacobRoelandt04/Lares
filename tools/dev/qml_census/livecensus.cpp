// One-shot census, loaded into a running Qt Quick process (gdb: call dlopen). Queues ONE walk on the GUI thread and writes a
// report: every QML object whose property/method storage was collected while the object lives, with flags and parent chain.
#include <QtCore/QCoreApplication>
#include <QtCore/QSet>
#include <QtCore/QHash>
#include <QtCore/QFile>
#include <QtGui/QGuiApplication>
#include <QtGui/QWindow>
#include <QtQuick/QQuickWindow>
#include <QtQuick/QQuickItem>
#define private public
#define protected public
#include <private/qqmlvmemetaobject_p.h>
#undef private
#undef protected
#include <private/qobject_p.h>
#include <private/qqmldata_p.h>
#include <cstdio>
#include <cstdlib>

static QByteArray flags(QObject *p) {
    QQmlData *d = QQmlData::get(p);
    QByteArray s = d ? (d->indestructible ? "[I" : "[d") : "[-";
    if (d && d->rootObjectInCreation) s += "R";
    if (d && d->jsWrapper.isUndefined()) s += " nowrapper";
    if (d && d->isQueuedForDeletion) s += " queuedForDeletion";
    return s + "]";
}
static QByteArray where(QObject *o) {
    QQmlData *d = QQmlData::get(o);
    if (!d || !d->outerContext) return QByteArray();
    return " @" + d->outerContext->urlString().toUtf8().replace("qs:@/qs/", "") + ":" + QByteArray::number(int(d->lineNumber));
}
static QByteArray chain(QObject *o) {
    QByteArray s;
    int n = 0;
    for (QObject *p = o; p && n < 16; p = p->parent(), ++n) {
        s += p->metaObject()->className();
        s += flags(p);
        if (n == 0) s += where(p);
        s += " <- ";
    }
    return s;
}
static int storageState(QObject *o) {  // 0 none, 1 alive, 2 dead (was set, now collected)
    int st = 0;
    for (QQmlVMEMetaObject *m = QQmlVMEMetaObject::get(o); m; m = m->parentVMEMetaObject()) {
        if (!m->m_propertyAndMethodStorage.valueRef()) continue;
        if (m->m_propertyAndMethodStorage.isUndefined()) return 2;
        st = 1;
    }
    return st;
}
static void census() {
    const char *path = getenv("LIVECENSUS_OUT");
    FILE *f = fopen(path ? path : LIVECENSUS_DEFAULT_OUT, "w");
    if (!f) return;
    QSet<QObject *> roots;
    const auto wins = QGuiApplication::allWindows();
    for (QWindow *w : wins) {
        QObject *t = w;
        while (t->parent()) t = t->parent();
        roots.insert(t);
        if (auto *qw = qobject_cast<QQuickWindow *>(w))
            if (qw->contentItem()) roots.insert(qw->contentItem());
    }
    roots.insert(qApp);
    int total = 0, vme = 0, dead = 0, nowrap = 0, deadNoWrap = 0;
    QList<QObject *> q(roots.begin(), roots.end());
    QSet<QObject *> seen;
    QHash<QByteArray, int> deadBy, aliveBy;
    QList<QObject *> deadList;
    while (!q.isEmpty()) {
        QObject *o = q.takeLast();
        if (seen.contains(o)) continue;
        seen.insert(o);
        ++total;
        for (QObject *c : o->children()) q.append(c);
        if (auto *it = qobject_cast<QQuickItem *>(o)) {
            const auto kids = it->childItems();
            for (QQuickItem *c : kids) q.append(c);
        }
        if (QObject *t = o->parent()) {
            while (t->parent()) t = t->parent();
            if (!seen.contains(t)) q.append(t);
        }
        QQmlData *d = QQmlData::get(o);
        if (!d || !d->hasVMEMetaObject) continue;
        ++vme;
        const bool nw = d->jsWrapper.isUndefined();
        if (nw) ++nowrap;
        QByteArray cls = o->metaObject()->className();
        int us = cls.indexOf("_QMLTYPE_"); if (us > 0) cls.truncate(us);
        if (storageState(o) == 2) { ++dead; if (nw) ++deadNoWrap; deadBy[cls]++; deadList.append(o); }
        else aliveBy[cls]++;
    }
    fprintf(f, "LIVECENSUS objects=%d vme=%d dead=%d nowrapper=%d dead_and_nowrapper=%d\n", total, vme, dead, nowrap, deadNoWrap);
    fprintf(f, "\n== roots (top-level objects walked)\n");
    for (QObject *r : std::as_const(roots)) fprintf(f, "root %s%s children=%d\n", r->metaObject()->className(), flags(r).constData(), int(r->children().size()));
    fprintf(f, "\n== dead by class (dead / alive of the same class)\n");
    for (auto it = deadBy.cbegin(); it != deadBy.cend(); ++it) fprintf(f, "%5d / %5d  %s\n", it.value(), aliveBy.value(it.key()), it.key().constData());
    fprintf(f, "\n== every dead object\n");
    for (QObject *o : std::as_const(deadList)) fprintf(f, "dead %s\n", chain(o).constData());
    fclose(f);
}
__attribute__((constructor)) static void init() {
    if (QCoreApplication::instance())
        QMetaObject::invokeMethod(QCoreApplication::instance(), census, Qt::QueuedConnection);
}
