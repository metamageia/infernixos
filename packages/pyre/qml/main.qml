import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl
import QtQuick.Layouts
import QtQuick.Dialogs

// pyre main window — near-1:1 Dolphin chrome
ApplicationWindow {
    id: win
    visible: true
    title: controller.currentPathProp

    // ---- window geometry: persist real size/pos (debounced), restore on launch.
    // No live binding to settings (that caused refreshes to reset the size);
    // geometry is applied once on startup and saved on resize/move. ----
    property bool _geomReady: false
    function saveGeom() {
        settings.winXProp = win.x
        settings.winYProp = win.y
        settings.winWProp = win.width
        settings.winHProp = win.height
        settings.save()
    }
    Timer {
        id: geomTimer
        interval: 250
        onTriggered: win.saveGeom()
    }
    onWidthChanged: if (_geomReady) geomTimer.restart()
    onHeightChanged: if (_geomReady) geomTimer.restart()
    onXChanged: if (_geomReady) geomTimer.restart()
    onYChanged: if (_geomReady) geomTimer.restart()

    // ------- theme (wallust-generated Theme.qml, live-reloadable) -------
    property QtObject th: theme.theme

    Connections {
        target: controller
        function onCurrentPathChanged(p) {
            if (terminalPanel.visible) terminal.cd(p)  // cd-sync the shell
        }
        function onStatusChanged(s) { status.text = s }
        function onTabChanged(i) { tabRepeater.model = controller.tabPathsProp }
        // No default app for a file → raise the Open-With chooser (friendly
        // for newcomers: never a silent no-op, and it can remember the choice).
        function onOpenWithRequested(path, mime) {
            openWithDlg.targetPath = path
            openWithDlg.targetMime = mime
            openWithAppModel.clear()
            var apps = controller.appsForMime(mime)
            for (var i = 0; i < apps.length; i++) openWithAppModel.append(apps[i])
            openWithDlg.title = "Open " + path.split("/").pop() + " with…"
            openWithDlg.open()
        }
    }

    // ============ MENU BAR ============
    menuBar: MenuBar {
        visible: settings.menuVisibleProp
        background: Rectangle { color: th.bg }
        // theme the top-level bar items (File, Tabs, Edit...) — app palette
        // doesn't reach MenuBar titles, so color them explicitly
        delegate: MenuBarItem {
            contentItem: Text { text: parent.text; color: th.fg; verticalAlignment: Text.AlignVCenter }
            background: Rectangle { color: parent.highlighted ? th.hover : "transparent" }
        }
        Menu {
            title: "File"
            Action { text: "New Folder"; shortcut: "Ctrl+Shift+N"; onTriggered: view.newFolder() }
            Action { text: "New Tab"; shortcut: "Ctrl+T"; onTriggered: controller.newTab() }
            MenuSeparator {}
            Action { text: "Close Tab"; shortcut: "Ctrl+W"; onTriggered: controller.closeTab(controller.activeIndex) }
            Action { text: "Reopen Closed Tab"; shortcut: "Ctrl+Shift+T"; onTriggered: controller.reopenTab() }
            MenuSeparator {}
            Action { text: "Quit"; shortcut: "Ctrl+Q"; onTriggered: win.close() }
        }
        Menu {
            title: "Tabs"
            Action { text: "Next Tab"; shortcut: "Ctrl+Tab"; onTriggered: controller.nextTab() }
            Action { text: "Previous Tab"; shortcut: "Ctrl+Shift+Tab"; onTriggered: controller.prevTab() }
        }
        Menu {
            title: "Edit"
            Action { text: "Copy"; shortcut: "Ctrl+C"; onTriggered: controller.copySelection() }
            Action { text: "Cut"; shortcut: "Ctrl+X"; onTriggered: controller.cutSelection() }
            Action { text: "Paste"; shortcut: "Ctrl+V"; onTriggered: controller.paste() }
            Action { text: "Undo"; shortcut: "Ctrl+Z"; onTriggered: controller.undo() }
            MenuSeparator {}
            Action { text: "Select All"; shortcut: "Ctrl+A"; onTriggered: view.selectAll() }
            Action { text: "Invert Selection"; shortcut: "Ctrl+E"; onTriggered: view.invertSelection() }
        }
        Menu {
            title: "View"
            Action { text: "Menu Bar"; checkable: true; checked: settings.menuVisibleProp; onTriggered: settings.menuVisibleProp = !settings.menuVisibleProp }
            MenuSeparator {}
            Action { text: "Icons"; checkable: true; checked: settings.viewModeProp==="icons"; onTriggered: settings.viewModeProp="icons" }
            Action { text: "Compact"; checkable: true; checked: settings.viewModeProp==="compact"; onTriggered: settings.viewModeProp="compact" }
            Action { text: "Details"; checkable: true; checked: settings.viewModeProp==="details"; onTriggered: settings.viewModeProp="details" }
            Action { text: "Grouped"; checkable: true; checked: settings.viewModeProp==="grouped"; shortcut: "Ctrl+5"; onTriggered: settings.viewModeProp="grouped" }
            Menu {
                title: "Group By"
                enabled: settings.viewModeProp==="grouped"
                Action { text: "Letter"; checkable: true; checked: fsModel.groupMode==="letter"; onTriggered: fsModel.groupMode="letter" }
                Action { text: "Type"; checkable: true; checked: fsModel.groupMode==="type"; onTriggered: fsModel.groupMode="type" }
                Action { text: "Date"; checkable: true; checked: fsModel.groupMode==="date"; onTriggered: fsModel.groupMode="date" }
            }
            Action { text: "Preview"; checkable: true; checked: settings.viewModeProp==="preview"; onTriggered: settings.viewModeProp="preview" }
            MenuSeparator {}
            Action { text: "Show Hidden Files"; shortcut: "Alt+."; checkable: true; checked: fsModel.hiddenProp; onTriggered: fsModel.hiddenProp = checked }
            Action { text: "Refresh"; shortcut: "F5"; onTriggered: controller.refresh() }
            MenuSeparator {}
            Action { text: "Split View"; shortcut: "F3"; onTriggered: controller.toggleSplit() }
        }
        Menu {
            title: "Go"
            Action { text: "Back"; shortcut: "Alt+Left"; onTriggered: controller.goBack() }
            Action { text: "Forward"; shortcut: "Alt+Right"; onTriggered: controller.goForward() }
            Action { text: "Up"; shortcut: "Alt+Up"; onTriggered: controller.goUp() }
            Action { text: "Home"; shortcut: "Alt+Home"; onTriggered: controller.goHome() }
            Action { text: "Root"; shortcut: "Alt+/"; onTriggered: controller.goRoot() }
            Action { text: "Location"; shortcut: "Ctrl+L"; onTriggered: nav.editing = true }
        }
        Menu {
            title: "Tools"
            Action { text: "Terminal"; shortcut: "F4"; onTriggered: terminalPanel.visible = !terminalPanel.visible }
            Action { text: "Info"; shortcut: "F11"; onTriggered: settings.infoVisibleProp = !settings.infoVisibleProp }
            Action { text: "Advanced Search…"; shortcut: "Ctrl+Shift+F"; onTriggered: advDlg.open() }
        }
    }

    // ============ TOOLBAR ============
    header: ToolBar {
        id: toolbar
        visible: settings.toolbarVisibleProp
        background: Rectangle { color: th.bg }
        RowLayout {
            width: parent.width
            ToolButton { icon.source: "image://theme/go-previous"; onClicked: controller.goBack(); ToolTip.text: "Back (Alt+Left)" }
            ToolButton { icon.source: "image://theme/go-next"; onClicked: controller.goForward(); ToolTip.text: "Forward (Alt+Right)" }
            ToolButton { icon.source: "image://theme/go-up"; onClicked: controller.goUp(); ToolTip.text: "Up (Alt+Up)" }
            ToolButton { icon.source: "image://theme/go-home"; onClicked: controller.goHome(); ToolTip.text: "Home (Alt+Home)" }
            Rectangle { width: 1; height: 24; color: th.border }

            BreadcrumbBar {
                id: nav
                Layout.fillWidth: true
                Layout.preferredHeight: 32
                currentPath: controller.currentPathProp
                onNavigate: (p) => controller.openPath(p)
                onSubmitted: (p) => controller.openPath(p)
            }

            Rectangle { width: 1; height: 24; color: th.border }
            TextField {
                id: liveSearch
                placeholderText: "Filter…"
                implicitWidth: 160
                text: fsModel.filterText
                color: th.fg
                placeholderTextColor: th.border
                onTextChanged: fsModel.filterText = text
                ToolTip.text: "Live filter current folder (cleared on navigation)"
                background: Rectangle {
                    color: th.bg
                    border.color: th.border
                    radius: 4
                }
            }
            ToolButton { icon.source: "image://theme/system-search"; onClicked: searchDlg.open(); ToolTip.text: "Search (Ctrl+F)" }
            ToolButton { icon.source: "image://theme/view-search"; onClicked: advDlg.open(); ToolTip.text: "Advanced Search (Ctrl+Shift+F)" }
            ToolButton { icon.source: "image://theme/application-menu"; onClicked: settings.menuVisibleProp = !settings.menuVisibleProp; ToolTip.text: "Toggle menu bar" }
        }
    }

    // ============ CENTRAL AREA ============
    SplitView {
        id: rootSplit
        anchors.fill: parent
        orientation: Qt.Horizontal

        // ------- sidebar -------
        Pane {
            id: sidebar
            SplitView.preferredWidth: 150
            SplitView.minimumWidth: 120
            visible: settings.sidebarVisibleProp
            padding: 0
            // explicit themed background (default Pane paints a light/white bg)
            background: Rectangle { color: th.sidebarBg }
            ColumnLayout { spacing: 0; anchors.fill: parent
                // Places on top, Folders below (Dolphin order)
                Label { text: "Places"; color: th.accent; font.bold: true; topPadding: 6; bottomPadding: 6; leftPadding: 8; rightPadding: 0 }
                ListView {
                    id: placesList
                    Layout.fillWidth: true
                    // size to content so there's no dead space before Folders
                    Layout.preferredHeight: placesList.contentHeight
                    model: placesModel
                    // drop target: dragging a folder from the file view pins it
                    DropArea {
                        id: placesDrop
                        anchors.fill: parent
                        keys: ["text/uri-list"]
                        onDropped: (drop) => {
                            const p = drop.mimeData["text/uri-list"]
                            if (!p) return
                            placesModel.add_place(p.split("/").pop(), p)
                        }
                    }
                    delegate: SidebarRow {
                        width: placesList.width
                        iconSource: "image://theme/" + model.iconName + "?accent"
                        label: model.label
                        onClicked: controller.openPath(model.path)
                        onRemoveRequested: placesModel.remove_place(index)
                    }
                }
                Rectangle { width: parent.width; height: 1; color: th.border }
                Label { text: "Folders"; color: th.accent; font.bold: true; topPadding: 8; bottomPadding: 4; leftPadding: 8; rightPadding: 0 }
                ListView {
                    id: folderList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: folderModel
                    delegate: SidebarRow {
                        width: folderList.width
                        iconSource: "image://theme/folder"
                        label: model.label
                        selected: model.path === controller.currentPath
                        onClicked: controller.openPath(model.path)
                    }
                }
            }
        }

        // ------- main view -------
        Pane {
            id: viewArea
            SplitView.fillWidth: true
            padding: 0
            background: Rectangle { color: th.bg }
            ColumnLayout { spacing: 0; anchors.fill: parent
                // tab bar
                Row {
                    id: tabRow
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    property int tabWidth: 140
                    // drop target for drag-reorder: map drop x -> target index
                    DropArea {
                        anchors.fill: parent
                        onDropped: (drop) => {
                            const src = drop.source
                            if (!src || src.tabIndex === undefined) return
                            const from = src.tabIndex
                            const to = Math.max(0, Math.min(
                                Math.round(drop.x / tabRow.tabWidth), tabRepeater.count - 1))
                            controller.moveTab(from, to)
                        }
                    }
                    Repeater {
                        id: tabRepeater
                        model: controller.tabPathsProp
                        delegate: Item {
                            id: tabItem
                            width: tabRow.tabWidth
                            height: 32
                            property int tabIndex: index
                            // lift state for Drag/Drop reorder
                            Drag.active: tabMouse.drag.active
                            Drag.hotSpot.x: width / 2
                            Drag.hotSpot.y: height / 2
                            Drag.source: tabItem
                            z: tabMouse.drag.active ? 10 : 0

                            Rectangle {
                                anchors.fill: parent
                                color: index === controller.activeIndexProp
                                       ? th.accent
                                       : (tabMouse.containsMouse ? th.hover : "transparent")
                                border.color: th.border
                                border.width: 1
                            }
                            Text {
                                anchors.fill: parent
                                anchors.leftMargin: 8; anchors.rightMargin: 8
                                verticalAlignment: Text.AlignVCenter
                                elide: Text.ElideRight
                                text: (modelData ? modelData.split("/").pop() : "") || "/"
                                color: index === controller.activeIndexProp ? th.selectionFg : th.fg
                            }
                            MouseArea {
                                id: tabMouse
                                anchors.fill: parent
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                hoverEnabled: true
                                drag.target: parent
                                drag.threshold: 10
                                drag.axis: Drag.XAxis
                                onDoubleClicked: controller.closeTab(index)
                                onClicked: (mouse) => {
                                    if (mouse.button === Qt.MiddleButton)
                                        controller.closeTab(index)
                                    else if (index !== controller.activeIndexProp)
                                        controller.setActiveTab(index)
                                }
                            }
                        }
                    }
                    ToolButton { icon.source: "image://theme/list-add"; onClicked: controller.newTab(); ToolTip.text: "New Tab (Ctrl+T)" }
                }

                SplitView {
                    id: viewSplit
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    orientation: Qt.Horizontal
                    FileView {
                        id: view
                        SplitView.fillWidth: true
                        onOpenTerminalRequested: terminalPanel.visible = true
                    }
                    FileView {
                        id: view2
                        SplitView.fillWidth: true
                        model: controller.splitModel
                        visible: controller.splitVisibleProp
                        onOpenTerminalRequested: terminalPanel.visible = true
                    }
                }
            }
        }

        // ------- info panel -------
        Pane {
            id: infoPanel
            SplitView.preferredWidth: 240
            visible: settings.infoVisibleProp
            background: Rectangle { color: th.bg }
            InfoPanel { anchors.fill: parent }
        }
    }

    // ============ TERMINAL PANEL (bottom) ============
    // Real PTY-backed shell (TerminalSession) rendered as flowing text.
    TerminalPanel {
        id: terminalPanel
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 200
        visible: false
        function toggle() { visible = !visible }
    }

    // ============ STATUS BAR ============
        footer: Rectangle {
            height: 32
            color: th.sidebarBg
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                Label { id: status; Layout.fillWidth: true; color: th.fg }
            ProgressBar {
                id: opsBar
                Layout.preferredWidth: 140
                visible: controller.busyProp
                from: 0; to: 100; value: opsBarVal
                property int opsBarVal: 0
            }
            ToolButton {
                text: "Cancel"; visible: controller.busyProp
                onClicked: controller.cancelOp()
            }
            Connections {
                target: controller
                function onOpsProgress(done, total) { opsBar.opsBarVal = total > 0 ? done * 100 / total : 0 }
            }
            Slider {
                id: sizeSlider
                Layout.preferredWidth: 120
                from: 16; to: 96; value: fsModel.iconSizeProp
                onValueChanged: fsModel.iconSizeProp = value
                background: Rectangle {
                    x: sizeSlider.leftPadding; y: sizeSlider.topPadding + sizeSlider.availableHeight/2 - height/2
                    width: sizeSlider.availableWidth; height: 4; radius: 2
                    color: th.border
                }
                handle: Rectangle {
                    x: sizeSlider.leftPadding + sizeSlider.visualPosition * (sizeSlider.availableWidth - width)
                    y: sizeSlider.topPadding + sizeSlider.availableHeight/2 - height/2
                    width: 14; height: 14; radius: 7
                    // give the control a real implicit size: a bare Rectangle handle
                    // reports implicitHeight 0, so the themed Slider collapsed to
                    // height 0 and became un-grabbable (theme commit 89ec162).
                    implicitWidth: 14; implicitHeight: 14
                    color: th.accent
                }
            }
            ToolButton {
                id: foldersBtn
                text: "Folders"; checkable: true; checked: settings.sidebarVisibleProp
                onToggled: settings.sidebarVisibleProp = checked
                contentItem: Text { text: parent.text; color: foldersBtn.checked ? th.selectionFg : th.fg; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: foldersBtn.checked ? th.accent : "transparent"; radius: 3 }
            }
            ToolButton {
                id: infoBtn
                text: "Info"; checkable: true; checked: settings.infoVisibleProp
                onToggled: settings.infoVisibleProp = checked
                contentItem: Text { text: parent.text; color: infoBtn.checked ? th.selectionFg : th.fg; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: infoBtn.checked ? th.accent : "transparent"; radius: 3 }
            }
        }
    }

    // ============ DIALOGS ============
    Dialog {
        id: searchDlg
        title: "Search"
        modal: true
        width: 500
        ColumnLayout {
            TextField { id: searchField; placeholderText: "Search in current folder + subfolders…"; Layout.fillWidth: true; onAccepted: searchModel.search(controller.currentPathProp, text) }
            ListView {
                id: results
                Layout.fillWidth: true
                Layout.preferredHeight: 300
                model: searchModel
                delegate: ItemDelegate {
                    width: results.width
                    text: model.path
                    onClicked: controller.revealPath(model.path)
                }
            }
            Label { text: searchModel.resultsProp + " results"; color: th.fg }
        }
    }

    AdvancedSearchDialog {
        id: advDlg
        th: th
    }

    // ---- Open With… chooser: no default app for a file type, ask the user ----
    Dialog {
        id: openWithDlg
        property string targetPath: ""
        property string targetMime: ""
        modal: true
        width: 460
        height: 420
        standardButtons: Dialog.Open | Dialog.Cancel
        // friendly copy so a newcomer isn't met with a bare list
        header: Label {
            text: "Which application should open this file?"
            color: th.fg
            font.bold: true
            leftPadding: 20
            topPadding: 12
            bottomPadding: 6
        }
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8
            ListView {
                id: openWithList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: ListModel { id: openWithAppModel }
                currentIndex: 0
                focus: true
                delegate: ItemDelegate {
                    width: openWithList.width
                    highlighted: ListView.isCurrentItem
                    onClicked: openWithList.currentIndex = index
                    onDoubleClicked: openWithDlg.accept()
                    contentItem: RowLayout {
                        spacing: 10
                        Image {
                            source: model.icon !== "" ? "image://theme/" + model.icon : "image://theme/application-x-executable"
                            Layout.preferredWidth: 22
                            Layout.preferredHeight: 22
                            fillMode: Image.PreserveAspectFit
                        }
                        Text {
                            text: model.name
                            color: th.fg
                            elide: Text.ElideMiddle
                            Layout.fillWidth: true
                        }
                    }
                }
                // friendly empty state instead of a bare blank dialog
                Rectangle {
                    anchors.fill: parent
                    visible: openWithAppModel.count === 0
                    color: th.hover
                    radius: 6
                    Label {
                        anchors.centerIn: parent
                        text: "No applications found for this file type."
                        color: th.fg
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                    }
                }
            }
            CheckBox {
                id: rememberChk
                text: "Always open this file type with the selected application"
                checked: true
            }
            RowLayout {
                TextField {
                    id: customCmd
                    placeholderText: "or type a command (%f = file)"
                    Layout.fillWidth: true
                    color: th.fg
                    onAccepted: openWithDlg.accept()
                }
            }
        }
        onAccepted: {
            if (customCmd.text !== "") {
                controller.openWithCommand(openWithDlg.targetPath, customCmd.text)
                return
            }
            if (openWithList.currentIndex >= 0 && openWithAppModel.count > 0) {
                var app = openWithAppModel.get(openWithList.currentIndex)
                controller.openWith(openWithDlg.targetPath, app.id, rememberChk.checked)
            }
        }
    }

    Component.onCompleted: {
        if (settings.winHProp > 0 && settings.winWProp > 0) {
            // restore previously persisted geometry
            win.x = settings.winXProp
            win.y = settings.winYProp
            win.width = settings.winWProp
            win.height = settings.winHProp
        } else {
            // first run (no saved geometry): fill the screen vertically
            win.width = Math.min(1000, Screen.availableWidth)
            win.height = Screen.availableHeight
            saveGeom()
        }
        _geomReady = true
        folderModel.reveal(controller.currentPath)
    }
}
