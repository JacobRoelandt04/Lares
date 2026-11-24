# Quickshell notes

Lint with the Qt 6 binary, not bare `qmllint`:

```sh
/usr/lib/qt6/bin/qmllint -I . -I /usr/lib/qt6/qml modules/notes/data/NotesService.qml
```

A minimal FileView that follows its file:

```qml
FileView {
    path: "/tmp/example.md"
    watchChanges: true
    onFileChanged: reload()
}
```

- FileView loads synchronously on its **first** path only.
- `setText("")` writes nothing.
