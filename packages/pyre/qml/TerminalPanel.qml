import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// pyre embedded terminal panel — a real PTY-backed shell rendered lazily.
//
// session is a TerminalSession (from terminal_session.py) bridged as a Qt
// context property; the shell's output lands on its `output(str)` signal and
// is appended as flowing monospace text; the bottom field sends each entered
// line to the shell's PTY. v1 is deliberately minimal (no colors/line
// discipline) — the "Open in kitty" button is the escape hatch for a full
// terminal. Dark background and fg come from the wallust palette via `th`.
Pane {
    id: root
    property QtObject session: terminal
    property string path: controller.currentPathProp
    property QtObject th: theme.theme

    background: Rectangle { color: th.sidebarBg }

    onVisibleChanged: if (visible && session) session.start()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 4
        spacing: 4

        Row {
            spacing: 8
            Label { text: "Terminal — " + root.path; color: th.fg; elide: Text.ElideMiddle; Layout.preferredWidth: parent.width * 0.7 }
            Item { Layout.fillWidth: true }
            Button { text: "Open in kitty"; onClicked: Qt.openUrlExternally("file://" + root.path) }
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            TextArea {
                id: termOutput
                readOnly: true
                wrapMode: TextEdit.NoWrap
                font.family: "monospace"
                font.pixelSize: 12
                color: th.fg
                selectByMouse: true
                background: Rectangle { color: th.bg }
                Component.onCompleted: termOutput.append("") // reserve a line
            }
        }

        TextField {
            id: termInput
            Layout.fillWidth: true
            placeholderText: "type a command and press Enter"
            font.family: "monospace"
            color: th.fg
            onAccepted: {
                if (session) session.writeInput(text + "\n")
                text = ""
            }
        }
    }

    Connections {
        target: session
        function onOutput(s) {
            // accumulate into the buffer, then jump to the tail
            termOutput.text += s
            termOutput.cursorPosition = termOutput.length
        }
    }
}
