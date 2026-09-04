import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The central file view. Four modes (PRD §5): icons (grid, zoomable),
// compact (dense list), details (columnar, sortable), preview (details +
// preview pane). Selection/sort/zoom bind to the Python fsModel.
Item {
    id: root
    property string mode: settings.viewModeProp
    property var model: fsModel

    // type-aware preview (T6): ext + derived flags on the root so every child
    // (preview pane, etc.) resolves them without ReferenceErrors.
    property string prevExt: controller.selectedExtProp.toLowerCase()
    property bool isText: ["txt","md","markdown","log","py","sh","c","cpp","h","rs","go","js","ts","html","css","json","yaml","yml","toml","ini","cfg","conf","xml","csv","tex","org","rst","sql","gitignore","env"].indexOf(prevExt) >= 0
    property bool isImage: ["png","jpg","jpeg","gif","bmp","webp","svg","ico"].indexOf(prevExt) >= 0
    property bool isVideo: ["mp4","mkv","webm","mov","avi","m4v","flv","wmv","ogv","mpeg","mpg"].indexOf(prevExt) >= 0
    property bool isPdf: prevExt === "pdf"
    property bool isAudio: ["mp3","wav","ogg","flac","m4a","aac","opus","wma"].indexOf(prevExt) >= 0
    property bool hasSel: controller.selectedName() !== ""

    signal openTerminalRequested()

    function selectAll() { model.select_all() }
    function invertSelection() {
        for (var i = 0; i < model.rowCount; i++) model.set_selected(i, !model.data(model.index(i,0), 0x0101 + 10))
    }
    function openContext(row) {
        model.set_selected(row, true)
        ctxMenu.popup()
    }
    function newFolder() { newFolderDlg.open() }

    // map model.iconName (folder/image/audio/video/pdf/archive/code/text) -> Breeze icon
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

    // ---------------- PREVIEW MODE ----------------
    SplitView {
        anchors.fill: parent
        visible: mode === "preview"
        orientation: Qt.Horizontal
        DetailsView { SplitView.fillWidth: true }
        Rectangle {
            SplitView.preferredWidth: 300
            color: th.sidebarBg
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 8

                // ---- type-aware preview (T6); flags live on root ----
                // media preview (image / video-poster / pdf first-page)
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 220
                    Layout.fillHeight: (isImage || isVideo || isPdf) && hasSel ? true : false
                    Layout.minimumHeight: 60
                    visible: hasSel && (isImage || isVideo || isPdf)
                    color: th.hover
                    radius: 6
                    clip: true
                    Image {
                        id: prevImg
                        anchors.fill: parent
                        anchors.margins: 6
                        fillMode: Image.PreserveAspectFit
                        source: controller.previewImageUriProp
                        visible: status !== Image.Error && source !== ""
                    }
                    Label {
                        anchors.centerIn: parent
                        visible: prevImg.status === Image.Error || prevImg.source === ""
                        text: "Preview unavailable"
                        color: th.fg; opacity: 0.6
                    }
                }

                // text preview
                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: hasSel && isText
                    color: th.hover
                    radius: 6
                    clip: true
                    Flickable {
                        id: txtScroll
                        anchors.fill: parent
                        anchors.margins: 6
                        contentWidth: parent.width - 12
                        contentHeight: txtBody.implicitHeight
                        clip: true
                        TextEdit {
                            id: txtBody
                            width: txtScroll.width - 6
                            readOnly: true
                            selectByMouse: true
                            text: controller.previewTextProp
                            color: th.fg
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }
                        ScrollBar.vertical: ScrollBar {}
                    }
                }

                // audio: backend-limited note
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 220
                    visible: hasSel && isAudio
                    color: th.hover
                    radius: 6
                    Column {
                        anchors.centerIn: parent
                        spacing: 6
                        Image {
                            anchors.horizontalCenter: parent.horizontalCenter
                            source: "image://theme/audio-x-generic"
                            width: 64; height: 64
                        }
                        Label {
                            text: "Audio preview is backend-limited.\nOpen in an external player."
                            color: th.fg; opacity: 0.7
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                }

                // empty state
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 220
                    visible: !hasSel
                    color: th.hover
                    radius: 6
                    Label {
                        anchors.centerIn: parent
                        text: "No selection"
                        color: th.fg; opacity: 0.5
                    }
                }

                Label {
                    Layout.fillWidth: true
                    text: controller.selectedName()
                    color: th.fg
                    font.pixelSize: 13
                    wrapMode: Text.Wrap
                }
                Label {
                    Layout.fillWidth: true
                    text: fsModel.selectedCount ? fsModel.data(fsModel.index(fsModel.selectedRows[0],0), fsModel.R_SIZETXT) : ""
                    color: th.fg
                }
                Button {
                    text: "Open"
                    visible: controller.selectedName() !== ""
                    onClicked: controller.openRow(controller.selectedRow())
                }
            }
        }
    }

    // ---------------- ICONS MODE ----------------
    Item {
        id: iconsRoot
        anchors.fill: parent
        visible: mode === "icons"
        clip: true
        focus: true

        GridView {
            id: grid
            anchors.fill: parent
            model: root.model
            cellWidth: fsModel.iconSizeProp + 44
            cellHeight: fsModel.iconSizeProp + 50
            clip: true
            focus: true
            delegate: Rectangle {
                width: grid.cellWidth
                height: grid.cellHeight
                radius: 6
                color: model.selected ? th.selection : (ma.containsMouse ? th.hover : "transparent")
                Column {
                    anchors.top: parent.top
                    anchors.topMargin: 6
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: grid.cellWidth - 14
                    spacing: 4
                    Rectangle {
                        width: fsModel.iconSizeProp; height: fsModel.iconSizeProp
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: "transparent"
                        Image {
                            anchors.fill: parent
                            source: model.thumbUrl !== ""
                                ? model.thumbUrl
                                : "image://theme/" + root.typeIcon(model.isDir, model.iconName)
                            fillMode: Image.PreserveAspectFit
                            clip: true
                        }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: grid.cellWidth - 14
                        text: model.fileName
                        color: model.selected ? th.selectionFg : th.fg
                        font.pixelSize: 12
                        elide: Text.ElideMiddle
                        horizontalAlignment: Text.AlignHCenter
                        maximumLineCount: 1
                        wrapMode: Text.NoWrap
                    }
                }
                // right-click (context) + hover only; left-click handled by marquee overlay
                MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.RightButton
                    onClicked: (mouse) => { if (mouse.button === Qt.RightButton) root.openContext(index) }
                }
            }
        }

        // ---- rubber-band marquee + click/double-click on top of the grid ----
        MouseArea {
            id: marea
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            focus: true
            property bool marquee: false
            property int pressRow: -1
            property point pressPt: Qt.point(0,0)
            // drag-to-pin: pressing a folder and dragging starts a Drag whose
            // mimeData carries the folder path (consumed by the Places DropArea)
            property bool _drag: false
            property string _dragPath: ""
            readonly property int _dragThreshold: 10

            // GridView has no `columns` property (it returns null/undefined in
            // QML), and the marquee geometry maths NEED the real column count
            // to map cells. Derive it from the grid's viewport width / cell
            // width the same way GridView lays cells out left-to-right.
            function colCount() {
                return Math.max(1, Math.floor(grid.width / grid.cellWidth))
            }

            // Map a mouse point from THIS MouseArea's coordinates into the
            // grid's own space before hit-testing: marea and grid are siblings
            // under iconsRoot, and grid.indexAt expects grid-local coords —
            // passing raw marea coords hit-tests rows 1-2 too high (the grid
            // origin offset), making every click "empty space".
            function gridPt(mx, my) {
                return marea.mapToItem(grid, mx, my)
            }

            onPressed: (mouse) => {
                var gp = gridPt(mouse.x, mouse.y)
                var r = grid.indexAt(gp.x, gp.y)
                pressPt = Qt.point(mouse.x, mouse.y)
                if (r >= 0) { pressRow = r; marquee = false
                    _drag = fsModel.isDirAt(r)
                    _dragPath = _drag ? fsModel.pathAt(r) : ""
                }
                else { pressRow = -1; marquee = true; _drag = false
                       marqueeRect.x = mouse.x; marqueeRect.y = mouse.y
                       marqueeRect.width = 0; marqueeRect.height = 0; marqueeRect.visible = true
                       fsModel.clear_selection() }
            }
            onPositionChanged: (mouse) => {
                if (_drag && !marea.Drag.active &&
                    (Math.abs(mouse.x - pressPt.x) > _dragThreshold ||
                     Math.abs(mouse.y - pressPt.y) > _dragThreshold)) {
                    marea.Drag.active = true
                    marea.Drag.source = marea
                    marea.Drag.mimeData = { "text/uri-list": _dragPath }
                    marea.Drag.keys = ["text/uri-list"]
                    return
                }
                if (!marquee) return
                var x = Math.min(pressPt.x, mouse.x), y = Math.min(pressPt.y, mouse.y)
                marqueeRect.x = x; marqueeRect.y = y
                marqueeRect.width = Math.abs(mouse.x - pressPt.x)
                marqueeRect.height = Math.abs(mouse.y - pressPt.y)
                // live rubber-band: highlight follows the box while dragging
                // (set_band replaces the selection; rows_in_rect shares the
                // geometry maths with the headless tests)
                fsModel.set_band(fsModel.rows_in_rect(
                    x, y, marqueeRect.width, marqueeRect.height,
                    grid.cellWidth, grid.cellHeight, marea.colCount(),
                    grid.contentX, grid.contentY))
            }
            onReleased: (mouse) => {
                if (marea.Drag.active) { marea.Drag.active = false; _drag = false; return }
                if (marquee) {
                    marqueeRect.visible = false
                    marquee = false
                    // selection already applied live during the drag
                    return
                }
                if (pressRow >= 0) {
                    fsModel.select_click(pressRow, mouse.modifiers & Qt.ControlModifier, mouse.modifiers & Qt.ShiftModifier)
                }
            }
            onDoubleClicked: (mouse) => {
                var gp = gridPt(mouse.x, mouse.y)
                var r = grid.indexAt(gp.x, gp.y)
                if (r >= 0) {
                    fsModel.isDirAt(r) ? controller.enterDir(r) : controller.openRow(r)
                }
            }
            // arrow-key navigation + type-ahead
            Keys.onPressed: (event) => {
                var cur = fsModel.currentRow
                var cols = marea.colCount()
                var target = -1
                if (event.key === Qt.Key_Left)  target = cur - 1
                else if (event.key === Qt.Key_Right) target = cur + 1
                else if (event.key === Qt.Key_Up)   target = cur - cols
                else if (event.key === Qt.Key_Down) target = cur + cols
                else if (event.key === Qt.Key_Home) target = 0
                else if (event.key === Qt.Key_End)  target = fsModel.rowCount - 1
                if (target >= 0) { fsModel.navigate(target, event.modifiers & Qt.ShiftModifier); event.accepted = true; return }
                // type-ahead: printable, non-modifier single char
                var text = event.text
                if (text.length === 1 && text >= " " && text !== " " &&
                    !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
                    taBuf = (taBuf + text).slice(-64)
                    fsModel.typeahead(taBuf)
                    event.accepted = true
                }
            }
            property string taBuf: ""
        }

        Rectangle {
            id: marqueeRect
            visible: false
            color: "transparent"
            border.color: th.accent
            border.width: 1
            opacity: 0.7
            z: 10
        }
    }

    // ---------------- DETAILS MODE ----------------
    DetailsView {
        anchors.fill: parent
        visible: mode === "details"
        onRowContext: (row) => root.openContext(row)
    }

    // ---------------- GROUPED DETAILS MODE (T10) ----------------
    GroupedDetailsView {
        anchors.fill: parent
        visible: mode === "grouped"
        onRowContext: (row) => root.openContext(row)
    }

    // ---------------- COMPACT MODE ----------------
    Item {
        id: compactRoot
        anchors.fill: parent
        visible: mode === "compact"
        clip: true
        focus: true
        ListView {
            id: cview
            anchors.fill: parent
            model: root.model
            clip: true
            focus: true
            delegate: Item {
                width: cview.width
                height: 24
                Rectangle {
                    anchors.fill: parent
                    color: model.selected ? th.selection : (dragma.containsMouse ? th.hover : "transparent")
                    Row {
                        spacing: 8
                        anchors.verticalCenter: parent.verticalCenter
                        Image {
                            source: "image://theme/" + root.typeIcon(model.isDir, model.iconName)
                            width: 16; height: 16
                            fillMode: Image.PreserveAspectFit
                        }
                        Text { text: model.fileName; color: model.selected ? th.selectionFg : th.fg; elide: Text.ElideMiddle; width: cview.width - 32 }
                    }
                }
                // click/double-click + drag-to-pin (drag a folder onto Places)
                MouseArea {
                    id: dragma
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    property bool _drag: false
                    property real _px: 0
                    property real _py: 0
                    readonly property int _dragThreshold: 10
                    onPressed: (mouse) => { _drag = model.isDir; _px = mouse.x; _py = mouse.y }
                    onPositionChanged: (mouse) => {
                        if (!_drag || dragma.Drag.active) return
                        if (Math.abs(mouse.x - _px) > _dragThreshold || Math.abs(mouse.y - _py) > _dragThreshold) {
                            dragma.Drag.active = true
                            dragma.Drag.source = dragma
                            dragma.Drag.mimeData = { "text/uri-list": model.filePath }
                            dragma.Drag.keys = ["text/uri-list"]
                        }
                    }
                    onClicked: (mouse) => {
                        if (mouse.button === Qt.RightButton) root.openContext(index)
                        else fsModel.select_click(index, mouse.modifiers & Qt.ControlModifier, mouse.modifiers & Qt.ShiftModifier)
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
                compBuf = (compBuf + text).slice(-64)
                fsModel.typeahead(compBuf)
                event.accepted = true
            }
        }
        property string compBuf: ""
    }

    // ---------------- shared context menu ----------------
    Menu {
        id: ctxMenu
        MenuItem {
                    text: "Open"
                    onTriggered: { var r = controller.selectedRow(); r >= 0 && controller.openRow(r) }
                }
        MenuItem { text: "Open Terminal Here"; onTriggered: root.openTerminalRequested() }
        MenuItem { text: "Rename…"; onTriggered: renameDlg.open() }
                MenuItem { text: "Move to Trash"; onTriggered: { var r = controller.selectedRow(); r >= 0 && controller.trashRow(r) } }
                MenuSeparator {}
                MenuItem { text: "Copy"; onTriggered: controller.copySelection() }
                MenuItem { text: "Cut"; onTriggered: controller.cutSelection() }
                MenuItem { text: "Paste"; onTriggered: controller.paste() }
                MenuSeparator {}
                MenuItem { text: "New Folder…"; onTriggered: newFolderDlg.open() }
        MenuSeparator {}
        MenuItem { text: "Properties"; onTriggered: settings.infoVisibleProp = true }
    }

    Dialog {
        id: newFolderDlg
        title: "New Folder"
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        TextField { id: nf; placeholderText: "Folder name"; onAccepted: newFolderDlg.accept() }
        onAccepted: controller.newFolder(nf.text === "" ? "New Folder" : nf.text)
    }

    Dialog {
        id: renameDlg
        title: "Rename"
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        TextField {
            id: rf
            text: controller.selectedName()
            onAccepted: renameDlg.accept()
        }
        onAccepted: { var r = controller.selectedRow(); r >= 0 && controller.renameRow(r, rf.text) }
    }
}
