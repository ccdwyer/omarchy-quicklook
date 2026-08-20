import QtQuick
import Quickshell
import Quickshell.Io
import "js/Protocol.js" as Protocol
import "js/Config.js" as Config
import "js/Fallback.js" as Fallback
import "js/Format.js" as Format

// Overlay-owned helper. Documented NDJSON stdin/stdout (or --oneshot).
// No pluginRegistry.serviceFor / shell.serviceFor — Overlay talks to this Item.
Item {
  id: root

  property var pluginSettings: null
  property var roots: []
  property int watchCap: 2000
  property int cacheMb: 500
  property int maxFiles: 500000
  property var extraExclude: []

  property string pluginDir: ""
  property string home: Quickshell.env("HOME") || "/tmp"
  property string pluginId: "io.github.chris.quicklook"

  readonly property string stateDir: {
    var xdg = Quickshell.env("XDG_STATE_HOME")
    if (xdg && xdg.length)
      return xdg + "/quicklook"
    return home + "/.local/state/quicklook"
  }
  readonly property string helperBin: pluginDir + "/bin/quicklookd"
  readonly property string helperSh: pluginDir + "/compat/quicklookd.sh"

  property string helperCmd: helperSh
  property bool helperIsBinary: false
  property bool helperReady: false
  property bool helperDead: false
  property bool usingFallback: false
  property bool oneshotMode: false
  property int restarts: 0
  property bool shuttingDown: false
  property string lastStatus: "starting"
  property string lastLine: ""
  property var lastResults: []
  property var lastPreview: ({})
  property var lastCaps: ({})
  property int resultsRevision: 0
  property int previewRevision: 0
  property int statusRevision: 0
  property bool indexing: false
  property real indexProgress: 0
  property string backend: "demo"
  property bool stdinWorks: false
  property bool pingSent: false
  property var sendQueue: []
  property var proto: null
  property var oneshotQueue: []
  property var oneshotCurrent: null

  function session() {
    if (!root.proto)
      root.proto = Protocol.createSession()
    return root.proto
  }

  function applyHostSettings() {
    var entry = {
      roots: root.roots,
      watchCap: root.watchCap,
      cacheMb: root.cacheMb,
      maxFiles: root.maxFiles,
      extraExclude: root.extraExclude
    }
    if (root.pluginSettings && typeof root.pluginSettings === "object") {
      var keys = Object.keys(root.pluginSettings)
      for (var i = 0; i < keys.length; i++)
        entry[keys[i]] = root.pluginSettings[keys[i]]
    }
    Config.applyInline(entry, root.home)
  }

  function helperCommand() {
    return root.helperIsBinary ? root.helperBin : root.helperSh
  }

  function writeLine(line) {
    try {
      if (typeof helper.write === "function") {
        helper.write(line)
        return true
      }
    } catch (e) {}
    try {
      if (helper.stdin && typeof helper.stdin.write === "function") {
        helper.stdin.write(line)
        return true
      }
    } catch (e2) {}
    return false
  }

  function send(obj) {
    if (!obj)
      return 0
    var P = root.session()
    if (!obj.id)
      obj.id = P.nextId()
    var line = JSON.stringify(obj) + "\n"
    if (root.oneshotMode || !helper.running) {
      root.enqueueOneshot(obj)
      return obj.id
    }
    if (!root.writeLine(line)) {
      root.sendQueue.push(obj)
      if (!root.oneshotMode && root.pingSent)
        root.oneshotMode = true
      root.flushSendQueue()
    }
    return obj.id
  }

  function flushSendQueue() {
    var leftover = []
    for (var i = 0; i < root.sendQueue.length; i++) {
      var job = root.sendQueue[i]
      if (root.oneshotMode || !helper.running) {
        root.enqueueOneshot(job)
      } else if (!root.writeLine(JSON.stringify(job) + "\n")) {
        leftover.push(job)
      }
    }
    root.sendQueue = leftover
  }

  function enterCompatFallback() {
    root.helperDead = true
    root.usingFallback = true
    root.oneshotMode = true
    root.helperIsBinary = false
    root.helperCmd = root.helperSh
    root.lastStatus = "compat"
    helper.running = false
    var abandoned = root.session().abandonInFlight()
    root.flushSendQueue()
    if (abandoned.queuedPreview)
      root.enqueueOneshot(abandoned.queuedPreview)
    if (abandoned.previewId && abandoned.previewPath) {
      root.applyLocalPreview(abandoned.previewId, abandoned.previewPath)
      root.enqueueOneshot({
        id: root.session().nextId(),
        cmd: "preview",
        path: abandoned.previewPath
      })
    }
    if (abandoned.queuedPrefetch)
      root.enqueueOneshot(abandoned.queuedPrefetch)
  }

  function enqueueOneshot(obj) {
    if (obj && (obj.cmd === "preview" || obj.cmd === "prefetch" || obj.cmd === "page")) {
      var kept = []
      for (var i = 0; i < oneshotQueue.length; i++) {
        var c = oneshotQueue[i].cmd
        var same = obj.cmd === "prefetch" ? c === "prefetch" : (c === "preview" || c === "page")
        if (!same)
          kept.push(oneshotQueue[i])
      }
      oneshotQueue = kept
    }
    oneshotQueue.push(obj)
    runOneshot()
  }

  function dispatchPending() {
    var P = root.session()
    var nextPrev = P.takeReadyPreview()
    if (nextPrev)
      root.send(nextPrev)
    var nextPref = P.takeReadyPrefetch()
    if (nextPref)
      root.send(nextPref)
  }

  function applyLocalPreview(id, path) {
    root.session().dropInFlight(id)
    root.lastPreview = Format.localPreview(path)
    root.previewRevision += 1
    root.dispatchPending()
  }

  function runOneshot() {
    if (oneshotProc.running || root.oneshotCurrent)
      return
    if (!oneshotQueue.length)
      return
    root.oneshotCurrent = oneshotQueue.shift()
    oneshotProc.command = [root.helperCommand(), "--oneshot", JSON.stringify(root.oneshotCurrent)]
    oneshotProc.running = true
  }

  function onHelperLine(line) {
    root.lastLine = String(line || "")
    var P = root.session()
    var msg = P.parseLine(line)
    if (!msg)
      return
    root.stdinWorks = true
    if (msg.kind === "results") {
      if (!P.acceptQuery(msg))
        return
      root.lastResults = msg.results || []
      if (msg.indexing !== undefined)
        root.indexing = !!msg.indexing
      if (msg.progress !== undefined)
        root.indexProgress = Number(msg.progress) || 0
      if (msg.backend)
        root.backend = String(msg.backend)
      root.resultsRevision += 1
    } else if (msg.kind === "preview") {
      var cls = P.slotClass(msg.id)
      var inflightPath = P.pathForInFlight(msg.id)
      P.classifyAndClear(msg.id)
      root.dispatchPending()
      if (cls === "prefetch")
        return
      if (msg.error === "stale" && !msg.preview)
        return
      if (!P.acceptForegroundPreview(msg))
        return
      root.lastPreview = msg.preview || Format.localPreview(inflightPath)
      root.previewRevision += 1
    } else if (msg.kind === "status") {
      root.lastCaps = msg.status || {}
      if (msg.indexing !== undefined)
        root.indexing = !!msg.indexing
      if (msg.status && msg.status.indexing !== undefined)
        root.indexing = !!msg.status.indexing
      if (msg.progress !== undefined)
        root.indexProgress = Number(msg.progress) || 0
      if (msg.status && msg.status.progress !== undefined)
        root.indexProgress = Number(msg.status.progress) || 0
      if (msg.backend)
        root.backend = String(msg.backend)
      else if (msg.status && msg.status.backend)
        root.backend = String(msg.status.backend)
      root.statusRevision += 1
    } else if (msg.kind === "error") {
      var errPath = P.pathForInFlight(msg.id)
      var errClass = P.slotClass(msg.id)
      P.dropInFlight(msg.id)
      root.lastStatus = "error:" + String(msg.error || "")
      if (errClass === "preview")
        root.applyLocalPreview(msg.id, errPath)
      else
        root.dispatchPending()
    } else if (msg.kind === "ok") {
      root.lastStatus = "ok"
    }
  }

  function localQuery(q) {
    var items = Fallback.defaultSamples(root.pluginDir)
    var hits = Fallback.search(items, q, 40)
    root.lastResults = hits
    root.backend = "local"
    root.indexing = false
    root.indexProgress = 1
    root.resultsRevision += 1
    return hits
  }

  function query(q) {
    if (root.helperDead && !helper.running && root.oneshotMode === false && !root.helperReady) {
      return root.localQuery(q)
    }
    var req = root.session().queryRequest(q)
    root.send(req)
    return req.id
  }

  function preview(path, page) {
    var req = root.session().previewRequest(path, page)
    var ready = root.session().queueOrStartPreview(req)
    if (ready)
      root.send(ready)
    return req.id
  }

  function prefetch(path) {
    var req = root.session().prefetchRequest(path)
    var ready = root.session().queueOrStartPrefetch(req)
    if (ready)
      root.send(ready)
    return req.id
  }

  function openPath(path) {
    if (path)
      root.send(root.session().selectRequest(path))
    return root.send(root.session().openRequest(path))
  }

  function reveal(path) {
    return root.send(root.session().revealRequest(path))
  }

  function select(path) {
    return root.send(root.session().selectRequest(path))
  }

  function setTheme(palette) {
    return root.send(root.session().themeRequest(palette))
  }

  function pushConfig() {
    return root.send(root.session().configRequest(Config.snapshot()))
  }

  function warmup() {
    return root.send(root.session().warmupRequest())
  }

  function requestStatus() {
    return root.send(root.session().statusRequest())
  }

  function markFirstRun() {
    Config.markFirstRunShown()
    uiFile.setText(Config.serializeUi())
    return "ok"
  }

  function startHelper() {
    helper.command = [root.helperCommand()]
    helper.running = true
    root.lastStatus = "starting"
    root.pingSent = false
    handshakeTimer.restart()
  }

  Process {
    id: helper
    running: false
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(data) { root.onHelperLine(data) }
    }
    stderr: SplitParser {
      onRead: function(data) { console.warn("quicklookd:", data) }
    }
    onExited: {
      if (root.shuttingDown)
        return
      if (root.restarts < 3) {
        root.restarts += 1
        root.lastStatus = "restart " + root.restarts
        restartTimer.interval = 300 * root.restarts
        restartTimer.start()
      } else {
        root.enterCompatFallback()
      }
    }
    onRunningChanged: {
      if (running) {
        root.lastStatus = "running"
        Qt.callLater(function() {
          root.pushConfig()
          root.requestStatus()
          root.pingSent = true
          root.flushSendQueue()
        })
      }
    }
  }

  Process {
    id: oneshotProc
    running: false
    stdout: StdioCollector {
      id: oneshotOut
      waitForEnd: true
    }
    onExited: {
      var text = oneshotOut.text
      var job = root.oneshotCurrent
      root.oneshotCurrent = null
      if (text && String(text).trim().length) {
        root.onHelperLine(String(text).trim().split("\n").pop())
      } else if (job && job.cmd === "query") {
        root.localQuery(job.q || "")
      } else if (job && job.cmd === "prefetch") {
        root.session().dropInFlight(job.id)
        root.dispatchPending()
      } else if (job && (job.cmd === "preview" || job.cmd === "page")) {
        root.applyLocalPreview(job.id, job.path)
      }
      root.runOneshot()
    }
  }

  Process {
    id: whichProc
    command: ["sh", "-c", "test -x \"$1\" && echo binary || echo missing", "sh", root.helperBin]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(text || "").trim()
        if (out === "binary") {
          root.helperIsBinary = true
          root.helperCmd = root.helperBin
          root.usingFallback = false
        } else {
          root.helperIsBinary = false
          root.helperCmd = root.helperSh
          root.usingFallback = true
        }
        root.helperReady = true
        root.startHelper()
      }
    }
  }

  Timer {
    id: restartTimer
    interval: 300
    repeat: false
    onTriggered: {
      if (!root.shuttingDown)
        root.startHelper()
    }
  }

  Timer {
    id: handshakeTimer
    interval: 2000
    repeat: false
    onTriggered: {
      if (!root.stdinWorks && helper.running) {
        root.oneshotMode = true
        root.lastStatus = "oneshot"
      }
    }
  }

  Timer {
    id: healthyTimer
    interval: 30000
    repeat: true
    running: true
    onTriggered: {
      if (helper.running && root.stdinWorks)
        root.restarts = 0
    }
  }

  FileView {
    id: uiFile
    path: root.stateDir + "/ui.json"
    atomicWrites: true
    printErrors: false
    watchChanges: false
    onLoaded: Config.loadUi(text())
    onLoadFailed: {}
  }

  Process {
    id: mkdirState
    command: ["mkdir", "-p", root.stateDir]
    running: false
    onExited: uiFile.reload()
  }

  Component.onCompleted: {
    root.proto = Protocol.createSession()
    root.applyHostSettings()
    mkdirState.running = true
    whichProc.running = true
  }

  Component.onDestruction: {
    root.shuttingDown = true
    helper.running = false
  }
}
