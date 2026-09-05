// AskHermesDialog.qml — Pyre "Ask Hermes about selected file(s)".
// Invoked by Pyre's DetailsView context action with the EXACT selected paths
// passed via environment variables (INFERNIXOS_ASK_FILES, '\n'-joined;
// INFERNIXOS_ASK_QUESTION optional). Paths are passed to infernixos-ask as
// argv (no shell interpolation). The dialog previews what will be shared and
// requires the user to confirm before anything is sent.
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root

  readonly property string askBin: Quickshell.env("INFERNIXOS_ASK_BIN") || "infernixos-ask"
  readonly property string files: Quickshell.env("INFERNIXOS_ASK_FILES") || ""
  readonly property string question: Quickshell.env("INFERNIXOS_ASK_QUESTION") || "Explain this"

  Process {
    id: askProc
    command: (function () {
      const args = [root.askBin]
      for (const f of root.files.split("\n")) {
        if (f.trim().length > 0) args.push("--file", f)
      }
      args.push(root.question)
      return args
    })()
    running: root.files.length > 0
  }
}
