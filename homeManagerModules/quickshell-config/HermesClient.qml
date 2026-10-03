import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
  id: client

  readonly property string baseUrl: Quickshell.env("QUICKSHELL_HERMES_API_URL") || ""
  readonly property string keyPath: Quickshell.env("QUICKSHELL_HERMES_API_KEY_PATH") || ""
  property string apiKey: ""
  
  property bool connected: false
  
  property int activeAgents: 0
  
  property var sessions: []
  
  property string currentSessionId: ""
  property string currentSessionTitle: ""
  
  property var messages: []
  property bool busy: false
  
  property bool captureContext: false

  property var contextProvider: null
  property var captureProvider: null

  signal sendFailed(string error)
  signal sessionsUpdated()
  signal messagesUpdated()

  Component.onCompleted: {
    const fv = keyViewComp.createObject(client)
    fv.path = client.keyPath
    fv.reload()
    healthTimerComp.createObject(client)
  }

  readonly property Component keyViewComp: Component {
    FileView {
      watchChanges: true
      onFileChanged: reload()
      onLoaded: client.apiKey = text().trim()
    }
  }

  readonly property Component base64ProcComp: Component {
    Process {
      property string shotPath: ""
      property var onDone: null
      command: ["/bin/sh", "-c", 'base64 -w0 "$1" 2>/dev/null || true', "sh", shotPath]
      stdout: StdioCollector {
        onStreamFinished: {
          const t = this.text.trim()
          if (t && parent.onDone) parent.onDone("data:image/png;base64," + t)
          else if (parent.onDone) parent.onDone(null)
          parent.destroy()
        }
      }
      onRunningChanged: {
        if (!running && !stdout.text && onDone) { onDone(null); onDone = null; destroy() }
      }
    }
  }

  readonly property Component healthTimerComp: Component {
    Timer {
      interval: 5000
      running: true
      repeat: true
      triggeredOnStart: true
      onTriggered: client.pollHealth()
    }
  }

  function _jsonXhr(method, path, body, onDone) {
    const xhr = new XMLHttpRequest()
    xhr.open(method, client.baseUrl + path)
    xhr.setRequestHeader("Authorization", "Bearer " + client.apiKey)
    if (body) xhr.setRequestHeader("Content-Type", "application/json")
    xhr.timeout = 15000
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) return
      let data = null
      try { data = JSON.parse(xhr.responseText) } catch (e) {}
      onDone(xhr.status, data)
    }
    try {
      xhr.send(body ? JSON.stringify(body) : null)
    } catch (e) {
      onDone(0, null)
    }
  }

  function pollHealth() {
    client.refreshSessions()
  }

  function refreshSessions() {
    _jsonXhr("GET", "/api/sessions?limit=50", null, function (status, data) {
      if (status !== 200 || !data) {
        client.connected = false
        client.sessions = []
        client.activeAgents = 0
        client.sessionsUpdated()
        return
      }
      client.connected = true
      const list = data.data || []
      const rows = list.map(function (s) {
        return {
          id: s.id || s.session_id || "",
          title: (s.title || "").trim() || "Untitled",
          pinned: !!s.pinned,
          updatedAt: s.last_active || "",
          endedAt: s.ended_at || null,
          archived: !!s.archived
        }
      }).filter(function (s) { return s.id !== "" })
      client.sessions = rows
      client.activeAgents = rows.filter(function (s) { return !s.endedAt && !s.archived }).length
      client.sessionsUpdated()
    })
  }

  function loadMessages(sessionId) {
    if (!sessionId) { client.messages = []; client.messagesUpdated(); return }
    _jsonXhr("GET", "/api/sessions/" + encodeURIComponent(sessionId) + "/messages", null, function (status, data) {
      if (status !== 200 || !data) { client.messages = []; client.messagesUpdated(); return }
      const rows = (data.data || []).map(function (m) {
        let text = ""
        if (typeof m.content === "string") text = m.content
        else if (Array.isArray(m.content)) {
          text = m.content.filter(function (p) { return typeof p === "object" && p.text })
            .map(function (p) { return p.text }).join("\n")
        }
        return { role: m.role || "user", text: text }
      })
      client.messages = rows
      client.messagesUpdated()
    })
  }

  function selectSession(id, title) {
    client.currentSessionId = id || ""
    client.currentSessionTitle = title || ""
    client.loadMessages(client.currentSessionId)
  }

  function newSession() {
    client.selectSession("", "")
  }

  function send(text) {
    if (client.busy || !text.trim()) return
    client.busy = true
    const doSend = function (sessionId) {
      const ctx = client.contextProvider ? client.contextProvider() : ""
      const prefix = client.captureContext && ctx ? "[screen context] " + ctx + "\n\n" : ""
      const finish = function (imageDataUrl) {
        let message = prefix + text
        if (imageDataUrl) {
          message = [
            { type: "text", text: prefix + text },
            { type: "image_url", image_url: { url: imageDataUrl } }
          ]
        }
        const body = { message: message }
        _jsonXhr("POST", "/api/sessions/" + encodeURIComponent(sessionId) + "/chat", body, function (status, data) {
          client.busy = false
          if (status !== 200 || !data) {
            client.sendFailed(data && data.error && data.error.message ? data.error.message : "HTTP " + status)
            return
          }
          const reply = data.message && data.message.content
            ? (typeof data.message.content === "string"
                ? data.message.content
                : JSON.stringify(data.message.content))
            : ""
          if (reply) client.appendLocal("assistant", reply)
          client.loadMessages(sessionId)
        })
      }
      if (client.captureContext && client.captureProvider) {
        client.captureProvider(function (path) {
          if (!path) { finish(null); return }
          const b64 = base64ProcComp.createObject(client, { shotPath: path })
          b64.onDone = finish
          b64.running = true
        })
      } else {
        finish(null)
      }
    }
    if (client.currentSessionId) {
      doSend(client.currentSessionId)
    } else {
      _createSession(function (id) {
        client.selectSession(id, "bar-hud")
        doSend(id)
      })
    }
  }

  function _createSession(onDone) {
    _jsonXhr("POST", "/api/sessions", { title: "bar-hud" }, function (status, data) {
      if (status !== 200 && status !== 201) {
        client.busy = false
        client.sendFailed("Could not create session (HTTP " + status + ")")
        return
      }
      const s = data.session || data
      onDone(s.id || s.session_id)
    })
  }

  function appendLocal(role, text) {
    const rows = client.messages.slice()
    rows.push({ role: role, text: text })
    client.messages = rows
    client.messagesUpdated()
  }
}
