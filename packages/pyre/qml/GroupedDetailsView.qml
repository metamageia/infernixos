import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Grouped details view (T10) — columnar listing with section headers
// driven by the model's `groupKey` role and `groupMode` property
// ("letter" | "type" | "date").  Ctrl+5 toggles between Details and
// Grouped view in the View menu.
Item {
    id: root
    signal rowContext(int row)
    property var model: fsModel

    function typeIcon(isDir, iconName) {
        if (isDir) return "folder"
        switch (iconName) {
        case "image":  return "image-x-generic"
        case "audio":  return "audio-x-generic"
        case "video":  return "video-x-generic"
        case "pdf":    return "application-pdf"
        case "archive":return "application-x-archive"
        case "code":   return "text-x-python"
        default:       return "text-x-generic"
        }
    }

    property var cols: [
        {label: "Name", w: 300, key: 0},
        {label: "Size", w: 90, key: 1},
        {label: "Date Modified", w: 150, key: 2},
        {label: "Type", w: 100, key: 3}
    ]

    ListView {
        id: list
        anchors.fill: parent
        model: root.model
        clip: true
        focus: true
        section.property: "groupKey"
        section.criteria: ViewSection.FullString
        section.delegate: Rectangle {
            width: list.width
            height: 22
            color: th.sidebarBg
            Rectangle { height: 1; width: parent.width; color: th.border; anchors.top: parent.top }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                x: 6
                text: section
                color: th.accent
                font.bold: true
                font.pixelSize: 11
            }
        }

        header: Row {
            height: 26
            Repeater {
                model: root.cols
                Rectangle {
                    width: modelData.w
                    height: 26
                    color: th.sidebarBg
                    border.color: th.border
                    Text {
                        anchors.centerIn: parent
                        text: modelData.label + (root.model.sort_key === modelData.key ? (root.model.sort_desc ? " ↓" : " ↑") : "")
                        color: th.fg
                        font.bold: true
                        font.pixelSize: 12
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (root.model.sort_key === modelData.key) root.model.setSort(modelData.key, !root.model.sort_desc)
                            else root.model.setSort(modelData.key, false)
                        }
                    }
                }
            }
        }

        delegate: Rectangle {
            width: list.width
            height: 24
            color: model.selected ? th.selection : (ma.containsMouse ? th.hover : "transparent")
            Row {
                spacing: 4
                leftPadding: 4
                Image {
                    width: 16; height: 16
                    source: "image://theme/" + root.typeIcon(model.isDir, model.iconName)
                    fillMode: Image.PreserveAspectFit
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    width: root.cols[0].w - 20; text: model.fileName
                    color: model.selected ? th.selectionFg : th.fg; elide: Text.ElideMiddle
                    font.pixelSize: 12
                }
                Text { width: root.cols[1].w; text: model.isDir ? "" : model.sizeText; color: th.fg; font.pixelSize: 12 }
                Text { width: root.cols[2].w; text: model.modText; color: th.fg; font.pixelSize: 12 }
                Text { width: root.cols[3].w; text: model.fileType; color: th.fg; font.pixelSize: 12 }
            }
            MouseArea {
                id: ma
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: (mouse) => {
                    if (mouse.button === Qt.RightButton) { root.model.set_selected(index, true); root.rowContext(index) }
                    else root.model.select_click(index, mouse.modifiers & Qt.ControlModifier, mouse.modifiers & Qt.ShiftModifier)
                }
                onDoubleClicked: model.isDir ? controller.enterDir(index) : controller.openRow(index)
            }
        }
    }

    Keys.onPressed: (event) => {
        var cur = fsModel.currentRow
        var target = -1
        if (event.key === Qt.Key_Up) target = cur - 1
        else if (event.key === Qt.Key_Down) target = cur + 1
        else if (event.key === Qt.Key_Home) target = 0
        else if (event.key === Qt.Key_End) target = fsModel.rowCount - 1
        if (target >= 0) { fsModel.navigate(target, event.modifiers & Qt.ShiftModifier); event.accepted = true; return }
        var text = event.text
        if (text.length === 1 && text >= " " && text !== " " &&
            !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
            grpBuf = (grpBuf + text).slice(-64)
            fsModel.typeahead(grpBuf)
            event.accepted = true
        }
    }
    property string grpBuf: ""
    focus: true
}
