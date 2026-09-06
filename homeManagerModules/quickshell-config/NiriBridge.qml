import QtQuick
import Quickshell
import Quickshell.Io

// Screen-context bridge for the bar's critical toggle. Captures focused-window
// metadata via niri IPC; the screenshot is taken with `niri msg action
// screenshot-window` (lands in clipboard) and read back through wl-paste.
QtObject {
  id: bridge

  property bool capturing: false

  // Focused-window context line, or "" when nothing is focused / niri is down.
  function contextLine() {
    return _focusedTitle !== "" || _focusedApp !== ""
      ? "Focused window: '" + _focusedTitle + "' (app: " + _focusedApp + ")"
      : ""
  }

  property string _focusedTitle: ""
  property string _focusedApp: ""

  readonly property Component focusProcComp: Component {
    Process {
      command: ["niri", "msg", "--json", "focused-window"]
      stdout: StdioCollector {
        onStreamFinished: {
          try {
            const w = JSON.parse(this.text)
            bridge._focusedTitle = (w && w.title) || ""
            bridge._focusedApp = (w && w.app_id) || ""
          } catch (e) {
            bridge._focusedTitle = ""
            bridge._focusedApp = ""
          }
        }
      }
    }
  }

  property var _focusProc: null

  // Refresh focus info; cheap enough to run on toggle-on and before each send.
  function refreshFocus() {
    _focusProc.running = true
  }

  // Capture the focused window screenshot to a temp file and call onDone(path).
  // Uses niri's screenshot action (clipboard) + wl-paste to read it back.
  function captureWindow(onDone) {
    _captureProc.running = true
    // wl-paste consumes the clipboard after niri wrote it; chain via a poll.
    _pasteTimer.repeat = true
    _pasteTimer.restart()
    pasteDone = onDone
  }

  property var pasteDone: null
  property int pasteTries: 0

  readonly property Component pastePollComp: Component {
    Timer {
      interval: 300
      repeat: true
      property bool runningState: false
      onTriggered: bridge._pasteProc.running = true
    }
  }

  readonly property Component pasteProcComp: Component {
    Process {
      command: ["/bin/sh", "-c", "wl-paste --no-newline --type image/png > /tmp/hermes-bar-shot.png 2>/dev/null && echo ok || echo fail"]
      stdout: StdioCollector {
        onStreamFinished: {
          if (this.text.trim() === "ok" && bridge.pasteDone) {
            bridge._pasteTimer.repeat = false
            const cb = bridge.pasteDone
            bridge.pasteDone = null
            cb("/tmp/hermes-bar-shot.png")
          } else {
            bridge.pasteTries++
            if (bridge.pasteTries > 10) {
              bridge._pasteTimer.repeat = false
              bridge.pasteTries = 0
              if (bridge.pasteDone) { bridge.pasteDone(""); bridge.pasteDone = null }
            }
          }
        }
      }
    }
  }

  property var _pasteTimer: null
  property var _pasteProc: null

  Component.onCompleted: {
    _focusProc = focusProcComp.createObject(bridge)
    _captureProc = captureProcComp.createObject(bridge)
    _pasteTimer = pastePollComp.createObject(bridge)
    _pasteProc = pasteProcComp.createObject(bridge)
  }

  readonly property Component captureProcComp: Component {
    Process {
      command: ["niri", "msg", "action", "screenshot-window"]
    }
  }
  property var _captureProc: null
}
