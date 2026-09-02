import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Breadcrumb bar + editable location bar (PRD §4). Clickable path segments;
// Ctrl+L / double-click switches to an editable text field.
Rectangle {
    id: root
    property string currentPath: ""
    property bool editing: false
    signal navigate(string path)
    signal submitted(string path)

    color: "transparent"

    function pathParts() {
        var parts = currentPath.split("/").filter(function(s){ return s !== "" })
        var acc = "/"
        var out = [{label: "/", path: "/"}]
        for (var i = 0; i < parts.length; i++) {
            acc = acc === "/" ? "/" + parts[i] : acc + "/" + parts[i]
            out.push({label: parts[i], path: acc})
        }
        return out
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // editable mode
        TextField {
            id: editField
            Layout.fillWidth: true
            visible: root.editing
            text: root.currentPath
            onAccepted: { root.submitted(text); root.editing = false }
            onEditingFinished: root.editing = false
            Keys.onEscapePressed: root.editing = false
        }

        // breadcrumb mode
        ListView {
            id: crumbs
            Layout.fillWidth: true
            Layout.fillHeight: true
            orientation: ListView.Horizontal
            visible: !root.editing
            clip: true
            model: root.pathParts()
            delegate: Row {
                spacing: 2
                // fill the bar height so crumbs are vertically centered in the toolbar
                height: crumbs.height
                Rectangle {
                    width: crumbLabel.implicitWidth + 12
                    height: parent.height
                    color: "transparent"
                    radius: 4
                    Label {
                        id: crumbLabel
                        anchors.centerIn: parent
                        text: modelData.label
                        color: th.fg
                        verticalAlignment: Text.AlignVCenter
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: parent.color = th.hover
                        onExited: parent.color = "transparent"
                        onClicked: root.navigate(modelData.path)
                        onDoubleClicked: root.editing = true
                    }
                }
                Label { text: "›"; color: th.fg; anchors.verticalCenter: parent.verticalCenter }
            }
        }
    }
}
