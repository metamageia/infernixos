// infernixos extension loader.
// Reads the runtime registry (extensions/registry.json written by
// `infernixos ext install`) and instantiates each enabled widget extension
// inside the SAME QuickShell process/ShellRoot, so extensions share the
// palette. An extension whose QML fails to load fails independently: the
// Loader logs and skips it without taking the bar down. Registry changes are
// watched and applied live. Disabled extensions are skipped.
import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
  id: loader

  required property ShellRoot shellRoot
  property string statePath: (Quickshell.env("XDG_STATE_HOME") || "")
    ? (Quickshell.env("XDG_STATE_HOME") + "/infernixos/extensions/registry.json")
    : ((Quickshell.env("HOME") || "") + "/.local/state/infernixos/extensions/registry.json")
  property var widgets: []
  property int registryRevision: 0

  function _data(text) {
    try { return JSON.parse(text) } catch (e) { return null }
  }

  function _apply(registry) {
    if (!registry || !registry.extensions) return
    const entries = []
    for (const name in registry.extensions) {
      const ext = registry.extensions[name]
      if (ext.disabled) continue
      if (ext.entry && ext.entry.qml && ext.package && ext.package.out) {
        entries.push({
          name: name,
          qml: "file://" + ext.package.out + "/share/quickshell/" + ext.entry.qml,
          fallbackQml: ext.source && ext.source.path
            ? "file://" + ext.source.path + "/" + ext.entry.qml : ""
        })
      }
    }
    loader.widgets = entries
  }

  property var registryView: null

  function reload() {
    if (registryView) registryView.reload()
  }

  readonly property Component registryViewComp: Component {
    FileView {
      path: loader.statePath
      watchChanges: true
      onFileChanged: reload()
      onLoaded: loader._apply(loader._data(text()))
    }
  }

  Component.onCompleted: registryView = registryViewComp.createObject(loader)

  // One Loader per enabled widget extension. Each fails independently:
  // a broken QML sets Loader status Error for that loader only.
  property list<Loader> loaders: widgets.map(function (w) {
    return loaderComponent.createObject(null, { widget: w })
  })

  readonly property Component loaderComponent: Component {
    Loader {
      id: extLoader
      required property var widget
      source: widget.qml
      onStatusChanged: {
        if (status === Loader.Error) {
          console.error("infernixos extension failed to load:", widget.name,
                        "- falling back to source" + (widget.fallbackQml ? "" : " (none)"))
          if (widget.fallbackQml && widget.fallbackQml !== source) {
            source = widget.fallbackQml
          }
        } else if (status === Loader.Ready) {
          console.log("infernixos extension loaded:", widget.name)
        }
      }
    }
  }
}
