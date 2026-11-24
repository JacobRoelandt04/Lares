pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

// =============================================================================
// MockupPage -- module-specific content for one tab of the control panel.
//
// A column the mockup fills with its own TipRows, TipGroups, buttons and
// readouts (a "Run" page that drives the content through its states, a
// toggle that belongs beside a list's sliders). Declare it in
// MockupWindow.pages and name it from a tabDef:
//
//     pages: [ MockupPage { id: runPage; ... } ]
//     tabDefs: [ { name: "Run", page: runPage }, ... ]
//
// The framework parents it under that tab's header, after the tab's lists.
// =============================================================================
ColumnLayout {
    Layout.fillWidth: true
    spacing: 10
}
