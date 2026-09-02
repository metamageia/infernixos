import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Niri

// QuickShell bar themed from wallust, with a native fade-out / fade-in
//
// Layout (single full-width PanelWindow, flush to screen edges, no side
// margins, no rounded corners, no dividers):
//   LEFT   : niri workspaces (qml-niri WorkspaceModel)
//   CENTER : clock
//   RIGHT  : wifi, volume, system tray
//
//
// Theme: every color — including the SVG icon tints — is driven by the wallust
// palette (keys bg/fg/accent/gold/muted/urgent/green/blue) via the FileView +
// centralized palette props below — NO hex literals. Opacity 0.93 matches
// niri's window-rule opacity (a style constant, not a theme color).
//
// Typography: smooth UI sans "Inter" for ALL text (clock, workspace numbers,
// volume %, wifi label). The Iosevka Nerd Font Mono glyphs were replaced with
// monochrome themeable SVG icons (Phase 4c).
//
// Icons (Phase 4c): clean monochrome SVGs under ./icons/, tinted to a palette
// color at runtime via Qt5Compat.GraphicalEffects.ColorOverlay. ColorOverlay
// multiplies source pixels by `color`, so the SVGs are authored WHITE on
// transparent and tinted to barXxx. The tint binding is a `root.barXxx` property
// that the staged crossfade (4a) re-adopts on theme change, so Mod+W recolors
// every icon. No font-glyph / Nerd Font icons remain anywhere in the bar.
//
// Icon path resolution: the QML ships both in the nix store derivation and at
// ~/.config/quickshell/bar. Resolve ./icons/<name>.svg against the directory
// the running config is loaded from via Quickshell.shellRoot, so it works in
// both locations without a hardcoded store path.
//
// Crossfade: on a palette change the whole bar surface fades out (opacity), the
// pending palette is adopted into every color prop, then it fades back in.
// Because every widget binds to `root.<color>`, staging ALL 8 keys (not just
// bg+accent) generalizes the confirmed-working fade to the new widgets.
//
// NOTE (checked against QuickShell 0.3.0 typeinfo): PanelWindow does NOT have
// an `opacity` property (WindowInterface -> Reloadable -> QObject, not Item),
// so the fade animates the inner Rectangle (a real QQuickItem).
//
// NOTE (checked against QuickShell 0.3.0 qt5compat closure): ColorOverlay lives
// in Qt5Compat.GraphicalEffects, which is NOT in QuickShell's default QML import
// path. The launcher wrapper (default.nix) appends qt5compat's qml dir to
// QML2_IMPORT_PATH so `import Qt5Compat.GraphicalEffects` resolves.
ShellRoot {
  id: root

  // Resolve the palette path (launcher exports QUICKSHELL_WALLUST_PALETTE).
  readonly property string palettePath: (Quickshell.env("QUICKSHELL_WALLUST_PALETTE") || "").length > 0
    ? Quickshell.env("QUICKSHELL_WALLUST_PALETTE")
    : ((Quickshell.env("XDG_CONFIG_HOME") || "").length > 0
        ? Quickshell.env("XDG_CONFIG_HOME") + "/quickshell/wallust-palette.json"
        : Quickshell.env("HOME") + "/.config/quickshell/wallust-palette.json")

  // Smooth UI sans for all text. Verified installed: `Inter` / `Inter Variable`.
  readonly property string uiFont: "Inter"

  // Directory the running config is loaded from — used to resolve the local
  // ./icons/*.svg set (works in both the nix store derivation and
  // ~/.config/quickshell/bar).
  readonly property string iconDir: Quickshell.shellRoot + "/icons"

  // Phase 6 — diamond wallpaper picker.
  // pickerStatePath: the toggle script flips this file open/closed; we watch it
  //   via FileView and bind the picker window's `visible` to it.
  // wallpapersDir: git-tracked wallpaper source (exported by the launcher
  //   wrapper as QUICKSHELL_WALLPAPERS_DIR).
  // lastWallpaperPath: the current wallpaper (from wallust's last-wallpaper) so
  //   we can mark the active tile in the hive.
  readonly property string pickerStatePath: (Quickshell.env("XDG_CONFIG_HOME") || "").length > 0
    ? Quickshell.env("XDG_CONFIG_HOME") + "/quickshell/picker-state"
    : Quickshell.env("HOME") + "/.config/quickshell/picker-state"
  readonly property string wallpapersDir: Quickshell.env("QUICKSHELL_WALLPAPERS_DIR") || ""
  property bool pickerOpen: false
  property string lastWallpaperPath: ""
  // Phase 7 — the keybind popup's toggle state file (written by keybind-popup-toggle,
  // watched below;flips hotkeysOpen). Same XDG-config dir as picker-state.

  readonly property string hotkeysStatePath: (Quickshell.env("XDG_CONFIG_HOME") || "").length > 0
    ? Quickshell.env("XDG_CONFIG_HOME") + "/quickshell/hotkeys-state"
    : Quickshell.env("HOME") + "/.config/quickshell/hotkeys-state"
  property bool hotkeysOpen: false

  // Phase 6 — the wallpaper list model for the hive. Filled by the scan Process.
  ListModel { id: wpModel }

  // Phase 6 — watch the picker state file; flip root.pickerOpen on change.
  FileView {
    id: pickerStateView
    path: root.pickerStatePath
    watchChanges: true
    onFileChanged: pickerStateView.reload()
    onLoaded: {
      root.pickerOpen = (text().trim() === "open")
    }
  }

  // Phase 7 — watch the keybind popup state file;flip root.hotkeysOpen on change.

  FileView {
 id: hotkeysStateView
    path: root.hotkeysStatePath
    watchChanges: true
    onFileChanged: hotkeysStateView.reload()
    onLoaded: {
      root.hotkeysOpen = (text().trim() === "open")
    }
  }

  // Phase 6 — watch the current wallpaper so the hive can mark the active tile.
  FileView {
    id: lastWallpaperView
    path: (Quickshell.env("XDG_CONFIG_HOME") || "").length > 0
      ? Quickshell.env("XDG_CONFIG_HOME") + "/wallust/last-wallpaper"
      : Quickshell.env("HOME") + "/.config/wallust/last-wallpaper"
    watchChanges: true
    onFileChanged: lastWallpaperView.reload()
    onLoaded: root.lastWallpaperPath = text().trim()
  }

  // Phase 6 — enumerate wallpapers (find | sort) into wpModel, marking the
  // active one. Re-run on every open so newly committed wallpapers appear.
  function scanWallpapers() {
    if (root.wallpapersDir.length === 0) return
    scanProc.running = true
  }
  Process {
    id: scanProc
    command: ["/bin/sh", "-c",
      "find \"$1\" -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \\) -printf '%f\\n' | sort",
      "sh", root.wallpapersDir]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        wpModel.clear()
        const names = this.text.split("\n").filter(function (n) { return n.trim().length > 0 })
        // and how many items did we append?
        for (const name of names) {
          const file = root.wallpapersDir + "/" + name
          wpModel.append({
            file: file,
            name: name,
            isActive: (file === root.lastWallpaperPath)
          })
        }
        // In-place clear+append on a ListModel does NOT fire the model's
        // onModelChanged, so the hive would never recompute its layout. Call
        hive.rebuild()
      }
    }
  }

  // Live mute state, driven by the volume poll. Lets the volume icon tint bind
  // to a palette key (so the 4a crossfade still recolors it on theme change).
  property bool volMuted: false

  // Current (visible) theme colors — all from the wallust palette. NO literals.
  property string barBg: "#0d0d14"
  property string barFg: "#e8e6f0"
  property string barAccent: "#7b68ab"
  property string barGold: "#d4a017"
  property string barMuted: "#8b8bab"
  property string barUrgent: "#ff5555"
  property string barGreen: "#5e7a5e"
  property string barBlue: "#6b8e9f"

  // Pending (next) colors staged when wallust rewrites the palette.
  property string pendingBg: "#0d0d14"
  property string pendingFg: "#e8e6f0"
  property string pendingAccent: "#7b68ab"
  property string pendingGold: "#d4a017"
  property string pendingMuted: "#8b8bab"
  property string pendingUrgent: "#ff5555"
  property string pendingGreen: "#5e7a5e"
  property string pendingBlue: "#6b8e9f"

  // Skip the fade on the very first load (no previous theme to transition from).
  property bool firstLoad: true
  // Bumped on each staged theme change; the bar fades when it changes.
  property int themeRevision: 0

  // ---- qml-niri IPC singleton (verified against imiric/qml-niri README) ----
  // Must be instantiated and connect()'d; there is no global `niri`.
  Niri {
    id: niri
    Component.onCompleted: connect()
    onErrorOccurred: function (e) { console.error("qml-niri:", e) }
  }

  FileView {
    id: palette
    path: palettePath
    watchChanges: true
    onFileChanged: palette.reload()
    onLoaded: {
      try {
        const p = JSON.parse(text());
        if (root.firstLoad) {
          // Adopt the first palette immediately — no transition to run.
          if (p.bg) root.barBg = p.bg;
          if (p.fg) root.barFg = p.fg;
          if (p.accent) root.barAccent = p.accent;
          if (p.gold) root.barGold = p.gold;
          if (p.muted) root.barMuted = p.muted;
          if (p.urgent) root.barUrgent = p.urgent;
          if (p.green) root.barGreen = p.green;
          if (p.blue) root.barBlue = p.blue;
          root.firstLoad = false;
        } else {
          // Stage the new colors and let the bar fade old -> new.
          root.pendingBg = p.bg || root.barBg;
          root.pendingFg = p.fg || root.barFg;
          root.pendingAccent = p.accent || root.barAccent;
          root.pendingGold = p.gold || root.barGold;
          root.pendingMuted = p.muted || root.barMuted;
          root.pendingUrgent = p.urgent || root.barUrgent;
          root.pendingGreen = p.green || root.barGreen;
          root.pendingBlue = p.blue || root.barBlue;
          root.themeRevision++;
        }
      } catch (e) {
        // Keep current colors if the JSON is unreadable / malformed.
      }
    }
  }

  // Reusable monochrome icon: a white SVG tinted to the palette via ColorOverlay.
  // tint is a `root.barXxx` binding so the staged crossfade recolors it.
  component ThemeIcon: Item {
    property string source
    property color tint
    property int size: 14
    width: size
    height: size

    Image {
      id: ic
      anchors.fill: parent
      source: "file://" + root.iconDir + "/" + source
      sourceSize.width: size
      sourceSize.height: size
      fillMode: Image.PreserveAspectFit
      visible: false
    }
    ColorOverlay {
      anchors.fill: ic
      source: ic
      color: tint
    }
  }

  PanelWindow {
    id: bar
    // Layer-shell namespace so niri's layer-rule can match this bar for the
    // drop shadow (see modules/niri/home.nix extraConfig). Must be set before
    // the window connects; PanelWindow is backed by WlrLayershell.
    WlrLayershell.namespace: "quickshell-bar"
    anchors {
      top: true
      left: true
      right: true
    }
    implicitHeight: 27
    color: "transparent"

    // The bar's visual surface. Solid, full-width, no radius, no border.
    // This Rectangle IS a QQuickItem, so it has a real `opacity` property —
    // the fade targets it, not the PanelWindow.
    Rectangle {
      id: surface
      anchors.fill: parent
      color: root.barBg
      opacity: 0.93
      radius: 0

      // LEFT — niri workspaces
      RowLayout {
        id: left
        spacing: 6
        anchors {
          left: parent.left
          leftMargin: 8
          verticalCenter: parent.verticalCenter
        }
        ThemeIcon {
          source: "workspace.svg"
          tint: root.barMuted
          size: 13
        }
        Repeater {
          model: niri.workspaces
          Rectangle {
            width: 20
            height: 20
            radius: 0
            color: model.isFocused ? root.barGold
              : (model.isActive ? root.barAccent : "transparent")
            border.color: model.isUrgent ? root.barUrgent : "transparent"
            border.width: model.isUrgent ? 2 : 0

            Text {
              anchors.centerIn: parent
              // Show niri's workspace `index` (sequential position on the
              // output: 1, 2, 3...), NOT `id` — niri keeps workspace ids stable
              // across shuffling, so id can read 7, 1, 6 while index is always
              // re-enumerated 1, 2, 3. Fall back to name if one is set.
              text: model.name !== "" ? model.name : model.index
              color: (model.isFocused || model.isActive) ? root.barBg : root.barMuted
              font.family: root.uiFont
              font.pixelSize: 11
              font.bold: true
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: niri.focusWorkspaceById(model.id)
            }
          }
        }
      }

      // CENTER — clock
      Text {
        id: clock
        anchors {
          horizontalCenter: parent.horizontalCenter
          verticalCenter: parent.verticalCenter
        }
        text: Qt.formatDateTime(new Date(), "ddd HH:mm:ss")
        color: root.barAccent
        font.family: root.uiFont
        font.pixelSize: 13
        Timer {
          interval: 1000
          running: true
          repeat: true
          onTriggered: clock.text = Qt.formatDateTime(new Date(), "ddd HH:mm:ss")
        }
      }
      ThemeIcon {
        source: "clock.svg"
        tint: root.barAccent
        size: 13
        anchors {
          right: clock.left
          rightMargin: 5
          verticalCenter: parent.verticalCenter
        }
      }

      // RIGHT — wifi, volume
      RowLayout {
        id: right
        spacing: 12
        anchors {
          right: parent.right
          rightMargin: 8
          verticalCenter: parent.verticalCenter
        }

        // wifi via NetworkManager `nmcli` (no compositor dependency).
        // Click opens networkmanager_dmenu — the existing fuzzel/rofi picker
        // already in the package set (modules/networking). No new picker built.
        Text {
          id: wifi
          color: root.barAccent
          font.family: root.uiFont
          font.pixelSize: 13
          text: "net --"
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: Quickshell.execDetached(["networkmanager_dmenu"])
          }
        }
        ThemeIcon {
          source: "wifi.svg"
          tint: root.barAccent
          size: 14
          anchors.verticalCenter: parent.verticalCenter
        }
        Process {
          id: wifiProc
          command: ["nmcli", "-t", "-f", "active,ssid", "dev", "wifi"]
          running: true
          stdout: StdioCollector {
            onStreamFinished: {
              const lines = this.text.split("\n")
              let ssid = ""
              for (const l of lines) {
                const p = l.split(":")
                if (p[0] === "yes" && p[1]) { ssid = p[1]; break }
              }
              wifi.text = ssid ? ("net " + ssid) : "net off"
            }
          }
        }
        Timer {
          interval: 10000
          running: true
          repeat: true
          onTriggered: wifiProc.running = true
        }

        // volume via PipeWire/wireplumber `wpctl`. Scroll = step volume by 5%,
        // click = toggle mute. Both fired through Quickshell.execDetached (a
        // detached shell command). Numeric % + mute state kept visible; the icon
        // + color bind to the palette so the 4a crossfade still recolors them.
        Text {
          id: vol
          color: root.volMuted ? root.barUrgent : root.barAccent
          font.family: root.uiFont
          font.pixelSize: 13
          text: "vol --"
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
              volProc.running = true
            }
            onWheel: (wheel) => {
              const step = wheel.angleDelta.y > 0 ? "5%+" : "5%-"
              Quickshell.execDetached(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", step])
              volProc.running = true
            }
          }
        }
        ThemeIcon {
          id: volIcon
          source: "volume.svg"
          tint: root.volMuted ? root.barUrgent : root.barAccent
          size: 14
          anchors.verticalCenter: parent.verticalCenter
        }
        Process {
          id: volProc
          command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]
          running: true
          stdout: StdioCollector {
            onStreamFinished: {
              const t = this.text.trim()
              const m = t.match(/Volume:\s*([\d.]+)/)
              const muted = /MUTED/.test(t)
              root.volMuted = muted
              if (m) {
                const pct = Math.round(parseFloat(m[1]) * 100)
                vol.text = (muted ? "MUTE " : "") + pct + "%"
                volIcon.source = muted ? "volume-muted.svg" : "volume.svg"
              } else {
                vol.text = "vol ?"
              }
            }
          }
        }
        Timer {
          interval: 1000
          running: true
          repeat: true
          onTriggered: volProc.running = true
        }
      }

      // Fade out, adopt the staged palette into EVERY color, fade back in.
      SequentialAnimation on opacity {
        id: fadeSeq
        running: false
        NumberAnimation { to: 0.0; duration: 200; easing.type: Easing.InOutQuad }
        ScriptAction {
          script: {
            root.barBg = root.pendingBg
            root.barFg = root.pendingFg
            root.barAccent = root.pendingAccent
            root.barGold = root.pendingGold
            root.barMuted = root.pendingMuted
            root.barUrgent = root.pendingUrgent
            root.barGreen = root.pendingGreen
            root.barBlue = root.pendingBlue
          }
        }
        NumberAnimation { to: 0.93; duration: 200; easing.type: Easing.InOutQuad }
      }
    }
  }

  // Phase 6 — the diamond wallpaper picker. A second centered layer-shell window
  // in the SAME QuickShell process as the bar, so it inherits the palette
  // FileView + root.barXxx crossfade for free (styles itself to the active
  // theme, no literals). `visible` is bound to root.pickerOpen — WindowInterface
  // does expose `visible` (verified in the installed .qmltypes).
  // The window is TRANSPARENT: only the diamonds paint, so they hover over the
  // in a box"). `color: transparent` on the window is valid (WindowInterface
  // exposes `color`).
  PanelWindow {
    id: picker
    visible: root.pickerOpen
    color: "transparent"
    // focusable so the picker receives keyboard input (ESC closes it).
    focusable: true
    WlrLayershell.namespace: "quickshell-wallpaper-picker"
    // No anchors: a wlr-layer-shell surface with no anchors is centered on the
    // output. The panel Anchors type only has left/right/top/bottom — there is
    // NO `center`, so we must NOT set anchors.center (invalid; would fail load).
    exclusiveZone: 0
    width: 900
    height: 600

    onVisibleChanged: {
      if (visible) {
        root.scanWallpapers()
        // Grab keyboard focus so ESC is caught by the hive's Keys handler
        // (run after the window finishes mapping).
        Qt.callLater(hive.forceActiveFocus)
      }
    }

    // The hive: honeycomb of diamonds, themed by the palette props, panning
    // via Flickable when it overflows. Apply hides the picker + calls
    // wallust-apply (the shared apply script).
    WallpaperHive {
      id: hive
      anchors.fill: parent
      model: wpModel
      accent: root.barAccent
      muted: root.barMuted
      focus: true
      // ESC closes the picker with no change — runs the same toggle Mod+W
      // spawns, so the state file and root.pickerOpen stay in sync.
      Keys.onEscapePressed: Quickshell.execDetached(["wallpaper-picker-toggle"])
      // Keep keyboard focus on the hive: if selecting a tile steals it, ESC
      // would stop firing. Re-grab whenever the hive loses focus while open.
      onActiveFocusChanged: {
        if (!activeFocus && root.pickerOpen) Qt.callLater(forceActiveFocus)
      }
      onApply: function (file) {
        root.pickerOpen = false
        Quickshell.execDetached(["wallust-apply", file])
      }
    }
  }

  // Phase 7 — keybind/hotkey popup (replaces niri's unstyleable show-hotkey-overlay:
  // Mod+Shift+/ is now bound to keybind-popup-toggle toggling the state file above.

  // A second centered layer-shell window in the SAME QuickShell process as the bar, so
  // it inherits the palette FileView + root.barXxx crossfade for free (styles itself
  // to the active theme, no hex literals). The keybind list mirrors
  // modules/niri/home.nix `binds` (keep in sync when bindings change). Drop shadow
  // comes from the niri layer-rule (namespace quickshell-hotkeys, same params as the bar).
  //
  // The window is transparent: only the solid panel paints, tinted to the bar bg
  // at the bar's opacity, flush/radius-full-width-consistent with the bar (no radius).
  PanelWindow {
    id: hotkeys
    visible: root.hotkeysOpen
    color: "transparent"
    // focusable so ESC closes it (like the wallpaper picker).
    focusable: true
    WlrLayershell.namespace: "quickshell-hotkeys"
    // No anchors — a layer-shell surface with no anchors is centered on the output,
    // and the panel fits tight to the window so the shadow (niri layer-rule in
    // modules/niri/home.nix) draws around the panel.
    exclusiveZone: 0
    width: 540
    height: 620

    onVisibleChanged: if (visible) Qt.callLater(hotkeysPanel.forceActiveFocus)

    Rectangle {
      id: hotkeysPanel
      anchors.fill: parent
      color: root.barBg
      opacity: 0.93
      radius: 0
      // ESC closes the popup via the same toggle Mod+Shift+/ spawns, so the state
      // file and root.hotkeysOpen stay in sync.
      Keys.onEscapePressed: Quickshell.execDetached(["keybind-popup-toggle"])
      onActiveFocusChanged: {
        // Keep keyboard focus here — if anything steals it, ESC stops firing.
        if (!activeFocus && root.hotkeysOpen) Qt.callLater(hotkeysPanel.forceActiveFocus)
      }

      // Scrollable list (34+ bindings exceed the window height; the Flickable pans).
      Flickable {
        id: kbFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: kbCol.height + 32
        clip: true

        // A QtQuick `Column` POSITIONER (not ColumnLayout) because a positioner
        // correctly lays out Repeater's delegate items vertically; a ColumnLayout
        // does not manage Repeater children. Each delegate row sets its own width.
        Column {
          id: kbCol
          x: 16
          y: 16
          width: kbFlick.width - 32
          spacing: 6

          // Header row: gold title + keyboard glyph + close hint.
          RowLayout {
            width: kbCol.width
            spacing: 8
            ThemeIcon {
              source: "keybind.svg"
              tint: root.barGold
              size: 14
            }
            Text {
              text: "KEYBINDS"
              color: root.barGold
              font.family: root.uiFont
              font.pixelSize: 13
              font.bold: true
              Layout.fillWidth: true
            }
            Text {
              text: "Mod+Shift+/ to close"
              color: root.barMuted
              font.family: root.uiFont
              font.pixelSize: 11
            }
          }

          // List model of the niri keybindings (mirror of modules/niri/home.nix binds).
          ListModel {
            id: kbModel
            // ---- Windows / Workspaces ----
            ListElement { key: "Mod+Shift+E";             desc: "Quit" }
            ListElement { key: "Mod+Q";                   desc: "Close window" }
            ListElement { key: "Mod+D";                   desc: "Launcher (fuzzel)" }
            ListElement { key: "Mod+T";                   desc: "Terminal (kitty)" }
            ListElement { key: "Mod+P";                   desc: "Screenshot" }
            ListElement { key: "Mod+W";                   desc: "Wallpaper picker" }
            ListElement { key: "Mod+Left/Right";          desc: "Focus column" }
            ListElement { key: "Mod+Up/Down";             desc: "Focus window" }
            ListElement { key: "Mod+H/L";                 desc: "Focus column (vim)" }
            ListElement { key: "Mod+K/J";                 desc: "Focus window (vim)" }
            ListElement { key: "Mod+Ctrl+Arrows";         desc: "Move window/column" }
            ListElement { key: "Mod+Ctrl+HJKL";           desc: "Move (vim)" }
            ListElement { key: "Mod+Home/End";            desc: "Focus first/last column" }
            ListElement { key: "Mod+Ctrl+Home/End";       desc: "Move column to edges" }
            ListElement { key: "Mod+Shift+Arrows";        desc: "Focus monitor" }
            ListElement { key: "Mod+Shift+Ctrl+Arrows";   desc: "Move column to monitor" }
            ListElement { key: "Mod+PgUp/PgDn";           desc: "Focus workspace" }
            ListElement { key: "Mod+U/I";                 desc: "Focus workspace (vim)" }
            ListElement { key: "Mod+Ctrl+PgUp/PgDn";      desc: "Move column to workspace" }
            ListElement { key: "Mod+Ctrl+U/I";            desc: "Move column to workspace (vim)" }
            ListElement { key: "Mod+Shift+PgUp/PgDn";     desc: "Move workspace" }
            ListElement { key: "Mod+Shift+U/I";           desc: "Move workspace (vim)" }
            ListElement { key: "Mod+1..9";                desc: "Focus workspace by number" }
            // ---- Columns ----
            ListElement { key: "Mod+[ / ]";               desc: "Consume/expel window" }
            ListElement { key: "Mod+, / .";               desc: "Consume/expel into/from column" }
            ListElement { key: "Mod+R";                   desc: "Switch preset column width" }
            ListElement { key: "Mod+Shift+R";             desc: "Switch preset window height" }
            ListElement { key: "Mod+Ctrl+R";              desc: "Reset window height" }
            ListElement { key: "Mod+F";                   desc: "Maximize column" }
            ListElement { key: "Mod+Shift+F";             desc: "Fullscreen window" }
            ListElement { key: "Mod+Ctrl+F";              desc: "Expand column to width" }
            ListElement { key: "Mod+C";                   desc: "Center column" }
            // ---- Audio ----
            ListElement { key: "XF86AudioRaiseVol";       desc: "Volume up" }
            ListElement { key: "XF86AudioLowerVol";       desc: "Volume down" }
          }

          Repeater {
            model: kbModel
            delegate: RowLayout {
              width: kbCol.width
              spacing: 8
              Text {
                text: model.key
                color: root.barAccent
                font.family: root.uiFont
                font.pixelSize: 12
                font.bold: true
                Layout.preferredWidth: 200
                elide: Text.ElideRight
              }
              Text {
                text: model.desc
                color: root.barFg
                font.family: root.uiFont
                font.pixelSize: 12
                Layout.fillWidth: true
                elide: Text.ElideRight
              }
            }
          }

          // Footer divider + hint.
          Rectangle {
            width: kbCol.width
            height: 1
            color: root.barMuted
            opacity: 0.4
          }
          Text {
            width: kbCol.width
            text: "Hotkey popup seeded from the wallust palette, matching the bar"
            color: root.barMuted
            font.family: root.uiFont
            font.pixelSize: 10
          }
        }
      }
    }
  }


  // Mirror themeRevision locally so the handler fires where it's declared.
  onThemeRevisionChanged: {
    if (root.firstLoad) return
    fadeSeq.restart()
  }
}
