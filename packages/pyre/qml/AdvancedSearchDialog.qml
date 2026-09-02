import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Advanced search dialog (PRD §9). All criteria combine with AND and run in
// SearchModel's worker QThread so the UI stays responsive during content grep.
Dialog {
    id: advDlg
    title: "Advanced Search"
    modal: true
    width: 620

    property QtObject th: null

    // ---- unit multiplier for the size fields (B / KB / MB) ----
    property int unitMult: 1

    function bytesOf(v) {
        return (v || 0) * advDlg.unitMult
    }

    function runSearch() {
        searchModel.advancedSearch(controller.currentPathProp, {
            "name": nameField.text,
            "content": contentField.text,
            "sizeMin": bytesOf(sizeMin.value),
            "sizeMax": bytesOf(sizeMax.value),
            "from": fromField.text,
            "to": toField.text,
            "type": typeField.text,
            "recursive": recursiveBtn.checked
        })
        resultsLabel.visible = true
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 10

        GridLayout {
            columns: 3
            columnSpacing: 8
            rowSpacing: 8

            Label { text: "Name contains:"; color: th ? th.fg : "#000" }
            TextField { id: nameField; Layout.columnSpan: 2; Layout.fillWidth: true; placeholderText: "substring of file name" }

            Label { text: "Content contains:"; color: th ? th.fg : "#000" }
            TextField { id: contentField; Layout.columnSpan: 2; Layout.fillWidth: true; placeholderText: "text inside text files" }

            Label { text: "Min size:"; color: th ? th.fg : "#000" }
            RowLayout {
                Layout.columnSpan: 2
                SpinBox { id: sizeMin; from: 0; to: 999999; editable: true; value: 0 }
                Label { text: "bytes"; color: th ? th.fg : "#000" }
            }

            Label { text: "Max size:"; color: th ? th.fg : "#000" }
            RowLayout {
                Layout.columnSpan: 2
                SpinBox { id: sizeMax; from: 0; to: 999999; editable: true; value: 0 }
                Label { text: "bytes"; color: th ? th.fg : "#000" }
            }

            Label { text: "Size unit:"; color: th ? th.fg : "#000" }
            ComboBox {
                Layout.columnSpan: 2
                model: ["B", "KB", "MB"]
                onCurrentTextChanged: {
                    advDlg.unitMult = currentIndex === 0 ? 1
                                     : currentIndex === 1 ? 1024 : 1024 * 1024
                }
            }

            Label { text: "Modified from:"; color: th ? th.fg : "#000" }
            TextField { id: fromField; Layout.columnSpan: 2; Layout.fillWidth: true; placeholderText: "YYYY-MM-DD (optional)" }

            Label { text: "Modified to:"; color: th ? th.fg : "#000" }
            TextField { id: toField; Layout.columnSpan: 2; Layout.fillWidth: true; placeholderText: "YYYY-MM-DD (optional)" }

            Label { text: "File type:"; color: th ? th.fg : "#000" }
            TextField { id: typeField; Layout.columnSpan: 2; Layout.fillWidth: true; placeholderText: "e.g. txt, png — empty = all" }

            Label { text: "Scope:"; color: th ? th.fg : "#000" }
            RowLayout {
                Layout.columnSpan: 2
                RadioButton { id: recursiveBtn; text: "Recursive (subfolders)"; checked: true }
                RadioButton { id: folderBtn; text: "Current folder only" }
            }
        }

        RowLayout {
            Button { text: "Search"; onClicked: advDlg.runSearch() }
            Button { text: "Close"; onClicked: advDlg.close() }
            Item { Layout.fillWidth: true }
            Label { id: resultsLabel; visible: false; color: th ? th.fg : "#000" }
        }

        ListView {
            id: results
            Layout.fillWidth: true
            Layout.preferredHeight: 280
            clip: true
            model: searchModel
            delegate: ItemDelegate {
                width: results.width
                text: model.path
                onClicked: controller.revealPath(model.path)
            }
        }
    }

    // Enter opens the first result; Esc closes (existing behavior).
    Keys.onReturnPressed: {
        if (results.count > 0 && searchModel.firstResult())
            controller.revealPath(searchModel.firstResult())
    }
    Keys.onEscapePressed: advDlg.close()

    onOpened: {
        nameField.forceActiveFocus()
        resultsLabel.text = ""
        resultsLabel.visible = false
    }
}
