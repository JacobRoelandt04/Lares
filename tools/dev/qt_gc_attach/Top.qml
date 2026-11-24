import QtQml

// The shell's root: made first, never has a parent, and holds a heap too large to mark in one drain batch.
QtObject {
    property var big: []
    Component.onCompleted: {
        let a = [];
        for (let i = 0; i < 80000; i++)
            a.push({ x: i, l: [i] });
        big = a;
    }
}
