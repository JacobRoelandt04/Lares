import QtQml

// A non-visual helper with storage of its own (a property, a function): what a Connections with handlers or a style object is.
QtObject {
    property var v: [1]
    property int n: 3
    function f() { return 1; }
}
