import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// One themed sidebar row (icon + label + click + optional highlight), shared
// by the Places and Folders lists so both have the same flush-left indent,
// row height, and spacing (unified aesthetic). Icon source and highlight
// differ per list; everything else is fixed here.
Item {
    id: row
    property string iconSource: ""
    property string label: ""
    property bool selected: false
    signal clicked()

    height: 24
    // align with "File" on the menu bar (the menu bar has ~7px inset)
    readonly property real leftInset: 8

    RowLayout {
        anchors.left: parent.left
        anchors.leftMargin: row.leftInset
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6
        Image {
            source: row.iconSource
            width: 18; height: 18
            sourceSize: Qt.size(18, 18)
        }
        Text {
            text: row.label
            color: row.selected ? th.selectionFg : th.fg
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
    }
    Rectangle {
        anchors.fill: parent
        color: row.selected ? th.selection : "transparent"
        z: -1
    }
    MouseArea { anchors.fill: parent; onClicked: row.clicked() }
}
