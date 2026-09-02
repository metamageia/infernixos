import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Info panel (PRD §8) — shows the selected file's metadata.
Item {
    id: root
    // type-aware preview (T6): ext and derived flags live on the root so all
    // children (including the layout) resolve them.
    property string ext: controller.selectedExtProp.toLowerCase()
    property bool isImage: ["png","jpg","jpeg","gif","bmp","webp","svg","ico"].indexOf(ext) >= 0
    property bool isText: ["txt","md","markdown","log","py","sh","c","cpp","h","rs","go","js","ts","html","css","json","yaml","yml","toml","ini","cfg","conf","xml","csv","tex","org","rst","sql","gitignore","env"].indexOf(ext) >= 0

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 6

        Label { text: "Info"; color: th.fg; font.bold: true; font.pixelSize: 14 }

        // preview thumbnail + snippet (T6)
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 90
            visible: controller.selectedName() !== ""
            color: th.hover
            radius: 6
            clip: true
            Image {
                id: infoImg
                anchors.fill: parent
                anchors.margins: 4
                fillMode: Image.PreserveAspectFit
                source: (isImage || ext === "pdf") ? controller.previewImageUriProp : ""
                visible: status === Image.Ready && source !== ""
            }
            Text {
                anchors.fill: parent
                anchors.margins: 8
                visible: infoImg.status !== Image.Ready && isText
                text: controller.previewTextProp
                color: th.fg
                font.pixelSize: 11
                elide: Text.ElideRight
                wrapMode: Text.Wrap
                maximumLineCount: 4
            }
            Label {
                anchors.centerIn: parent
                visible: !isText && infoImg.status !== Image.Ready
                text: controller.selectedName()
                color: th.fg; opacity: 0.6
                elide: Text.ElideMiddle
                width: parent.width - 20
                horizontalAlignment: Text.AlignHCenter
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 80
            radius: 6
            color: th.hover
            Text {
                anchors.centerIn: parent
                text: controller.selectedName() === "" ? "No selection" : controller.selectedName()
                color: th.fg
                font.pixelSize: 16
                elide: Text.ElideMiddle
                width: parent.width - 20
                horizontalAlignment: Text.AlignHCenter
            }
        }

        GridLayout {
            columns: 2
            columnSpacing: 8
            rowSpacing: 4
            Layout.fillWidth: true

            property var rows: [
                ["Name", controller.selectedName()],
                ["Path", controller.currentPathProp],
                ["Size", fsModel.selectedCount ? fsModel.data(fsModel.index(fsModel.selectedRows[0],0), fsModel.R_SIZETXT) : ""],
                ["Modified", fsModel.selectedCount ? fsModel.data(fsModel.index(fsModel.selectedRows[0],0), fsModel.R_MODTXT) : ""],
                ["Type", fsModel.selectedCount ? fsModel.data(fsModel.index(fsModel.selectedRows[0],0), fsModel.R_TYPE) : ""],
                ["Permissions", fsModel.selectedCount ? fsModel.data(fsModel.index(fsModel.selectedRows[0],0), fsModel.R_PERMS) : ""],
                ["Owner", fsModel.selectedCount ? fsModel.data(fsModel.index(fsModel.selectedRows[0],0), fsModel.R_OWNER) : ""],
                ["Group", fsModel.selectedCount ? fsModel.data(fsModel.index(fsModel.selectedRows[0],0), fsModel.R_GROUP) : ""]
            ]

            Repeater {
                model: parent.rows
                Row {
                    Label { text: modelData[0] + ":"; color: th.fg; opacity: 0.6; width: 90 }
                    Label { text: modelData[1]; color: th.fg; elide: Text.ElideMiddle; width: 120 }
                }
            }
        }
    }
}
