import QtQuick
import Quickshell
import Quickshell.Io

// Hermes gateway API-server client for the quickshell bar.
// Talks to the OpenAI-compatible API server (127.0.0.1:8642 by default):
//   GET  /health/detailed            - active agent count (agents pill)
//   GET  /api/sessions               - pinned/recent session list
//   GET  /api/sessions/{id}/messages - chat log for the popup
//   POST /api/sessions/{id}/chat     - send one message, get the reply
// Bearer key read at startup from the seeded runtime key file.
QtObject {
  id: client

  readonly property string baseUrl: "http://127.0.0.1:" + (Quickshell.env("QUICKSHELL_HERMES_API_PORT") || "8642")
  readonly property string keyPath: "/var/lib/hermes/.hermes/api-server-key"
  property string apiKey: ""
  // true once /health/detailed answered - drives the "gateway down" state.
  property bool connected: false
  // Gateway-reported active agent count (agents pill).
  property int activeAgents: 0
  // Session list for the HUD dropdown: [{id, title, pinned, updatedAt}]
  property var sessions: []
  // Currently selected session id ("" = none; next message creates one).
  property string currentSessionId: ""
  property string currentSessionTitle: ""
  // Chat log of the selected session: [{role, text}]
  property var messages: []
  property bool busy: false
  // True when the next send should attach workspace context (critical toggle).
  property bool captureContext: false

  // Optional callbacks set by the shell: a context string for the critical
  // capture toggle (focused-window metadata) and an async screenshot capture
  // (onDone(path)) used to attach the image to the message.
  property var contextProvider: null
  property var captureProvider: null

  signal sendFailed(string error)
  signal sessionsUpdated()
  signal messagesUpdated()

  // QtObject has no default child property, so FileView/Timer children are
  // created dynamically at startup.
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

  // Poll gateway health for the agents pill. Light: every 5s.
  function pollHealth() {
    _jsonXhr("GET", "/health/detailed", null, function (status, data) {
      client.connected = status === 200 && !!data
      if (client.connected && data && data.active_agents !== undefined) {
        client.activeAgents = typeof data.active_agents === "number"
          ? data.active_agents
          : (typeof data.active_agents === "object" ? Object.keys(data.active_agents).length : 0)
      } else if (!client.connected) {
        client.activeAgents = 0
      }
    })
  }

  // Refresh the session list for the HUD dropdown.
  function refreshSessions() {
    _jsonXhr("GET", "/api/sessions?limit=30", null, function (status, data) {
      if (status !== 200 || !data) { client.sessions = []; client.sessionsUpdated(); return }
      const rows = (data.sessions || []).map(function (s) {
        return {
          id: s.id || s.session_id || "",
          title: (s.title || "").trim() || "Untitled",
          pinned: !!s.pinned,
          updatedAt: s.updated_at || s.last_active || ""
        }
      }).filter(function (s) { return s.id !== "" })
      client.sessions = rows
      client.sessionsUpdated()
    })
  }

  // Load the selected session's chat log.
  function loadMessages(sessionId) {
    if (!sessionId) { client.messages = []; client.messagesUpdated(); return }
    _jsonXhr("GET", "/api/sessions/" + encodeURIComponent(sessionId) + "/messages", null, function (status, data) {
      if (status !== 200 || !data) { client.messages = []; client.messagesUpdated(); return }
      const rows = (data.messages || []).map(function (m) {
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

  // Send the HUD input. With no selected session, creates one first.
  // Workspace context: when captureContext is on, grabs the focused-window
  // metadata (niri) and attaches it ahead of the message text.
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
          const reply = data.choices && data.choices[0] && data.choices[0].message
            ? (typeof data.choices[0].message.content === "string"
                ? data.choices[0].message.content
                : JSON.stringify(data.choices[0].message.content))
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
      onDone(data.id || data.session_id)
    })
  }

  function appendLocal(role, text) {
    const rows = client.messages.slice()
    rows.push({ role: role, text: text })
    client.messages = rows
    client.messagesUpdated()
  }
}
