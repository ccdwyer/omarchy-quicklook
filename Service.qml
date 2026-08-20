import QtQuick
import Quickshell
import Quickshell.Io
import "js/Protocol.js" as Protocol
import "js/Config.js" as Config
import "js/Fallback.js" as Fallback
import "js/Theme.js" as Theme
import "js/Format.js" as Format

Item {
  id: root

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var pluginSettings: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || ""

  readonly property string pluginId: "io.github.chris.quicklook"
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    if (u.indexOf("file://") === 0)
      u = u.slice(7)
    if (u.length > 1 && u.charAt(u.length - 1) === "/")
      u = u.slice(0, u.length - 1)
    return u
  }

  // Inline shell.json fields. The host may assign these from the plugins[] entry.
  property var roots: []
  property int watchCap: 2000
  property int cacheMb: 500
  property int maxFiles: 500000
  property var extraExclude: []

  readonly property string home: Quickshell.env("HOME") || "/tmp"
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
    if (!obj.id)
      obj.id = Protocol.nextId()
    var line = JSON.stringify(obj) + "\n"
    if (root.oneshotMode || !helper.running) {
      root.enqueueOneshot(obj)
      return obj.id
    }
    if (!root.writeLine(line)) {
      root.sendQueue.push(obj)
      if (!root.oneshotMode && root.pingSent)
        root.oneshotMode = true
      root.enqueueOneshot(obj)
    }
    return obj.id
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
    var nextPrev = Protocol.takeReadyPreview()
    if (nextPrev)
      root.send(nextPrev)
    var nextPref = Protocol.takeReadyPrefetch()
    if (nextPref)
      root.send(nextPref)
  }

  function applyLocalPreview(id, path) {
    Protocol.dropInFlight(id)
    root.lastPreview = Format.localPreview(path)
    root.previewRevision += 1
    root.dispatchPending()
  }

  property var oneshotQueue: []
  property var oneshotCurrent: null

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
    var msg = Protocol.parseLine(line)
    if (!msg)
      return
    root.stdinWorks = true
    if (msg.kind === "results") {
      if (!Protocol.acceptQuery(msg))
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
      var inflightPath = Protocol.pathForInFlight(msg.id)
      var accepted = Protocol.acceptPreview(msg)
      root.dispatchPending()
      if (!accepted)
        return
      if (msg.error === "stale" && !msg.preview)
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
      var errPath = Protocol.pathForInFlight(msg.id)
      var wasPreview = Protocol.isInFlight(msg.id)
      Protocol.dropInFlight(msg.id)
      root.lastStatus = "error:" + String(msg.error || "")
      if (wasPreview)
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
    var req = Protocol.queryRequest(q)
    root.send(req)
    return req.id
  }

  function preview(path, page) {
    var req = Protocol.previewRequest(path, page)
    var ready = Protocol.queueOrStartPreview(req)
    if (ready)
      root.send(ready)
    return req.id
  }

  function prefetch(path) {
    var req = Protocol.prefetchRequest(path)
    var ready = Protocol.queueOrStartPrefetch(req)
    if (ready)
      root.send(ready)
    return req.id
  }

  function openPath(path) {
    if (path)
      root.send(Protocol.selectRequest(path))
    return root.send(Protocol.openRequest(path))
  }

  function reveal(path) {
    return root.send(Protocol.revealRequest(path))
  }

  function select(path) {
    return root.send(Protocol.selectRequest(path))
  }

  function setTheme(palette) {
    return root.send(Protocol.themeRequest(palette))
  }

  function pushConfig() {
    var snap = Config.snapshot()
    return root.send(Protocol.configRequest(snap))
  }

  function warmup() {
    return root.send(Protocol.warmupRequest())
  }

  function requestStatus() {
    return root.send(Protocol.statusRequest())
  }

  function statusJson() {
    return JSON.stringify({
      id: root.pluginId,
      helper: root.helperCmd,
      helperIsBinary: root.helperIsBinary,
      helperDead: root.helperDead,
      oneshot: root.oneshotMode,
      backend: root.backend,
      indexing: root.indexing,
      progress: root.indexProgress,
      results: root.lastResults.length,
      caps: root.lastCaps,
      status: root.lastStatus
    })
  }

  function summonOverlay(payload) {
    var body = payload || "{}"
    if (shell && typeof shell.summon === "function") {
      shell.summon(root.pluginId, body)
      return "ok"
    }
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", root.pluginId, body])
    return "ok"
  }

  function hideOverlay() {
    if (shell && typeof shell.hide === "function") {
      shell.hide(root.pluginId)
      return "ok"
    }
    Quickshell.execDetached(["omarchy-shell", "shell", "hide", root.pluginId])
    return "ok"
  }

  function toggleOverlay(payload) {
    if (shell && typeof shell.toggle === "function") {
      shell.toggle(root.pluginId, payload || "{}")
      return "ok"
    }
    Quickshell.execDetached(["omarchy-shell", "shell", "toggle", root.pluginId, payload || "{}"])
    return "ok"
  }

  function ping() { return "ok" }
  function status() { return root.statusJson() }
  function open(path) { return String(root.openPath(path)) }
  function previewPath(path) { return String(root.preview(path, 1)) }
  function search(q) { return String(root.query(q)) }

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
        root.helperDead = true
        root.usingFallback = true
        root.oneshotMode = true
        root.lastStatus = "compat"
      }
    }
    onRunningChanged: {
      if (running) {
        root.lastStatus = "running"
        Qt.callLater(function() {
          root.pushConfig()
          root.requestStatus()
          root.pingSent = true
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
      } else if (job && (job.cmd === "preview" || job.cmd === "prefetch" || job.cmd === "page")) {
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

  IpcHandler {
    target: "io.github.chris.quicklook"

    function ping(): string { return "ok" }
    function status(): string { return root.statusJson() }
    function query(q: string): string { return String(root.query(q)) }
    function preview(path: string): string { return String(root.preview(path, 1)) }
    function open(path: string): string { return String(root.openPath(path)) }
    function reveal(path: string): string { return String(root.reveal(path)) }
    function warmup(): string { root.warmup(); return "ok" }
    function summon(): string { return root.summonOverlay("{}") }
    function hide(): string { return root.hideOverlay() }
    function toggle(): string { return root.toggleOverlay("{}") }
    function configure(json: string): string {
      try {
        Config.applyInline(JSON.parse(json), root.home)
        root.pushConfig()
      } catch (e) {}
      return "ok"
    }
    function markFirstRun(): string { return root.markFirstRun() }
  }

  function markFirstRun() {
    Config.markFirstRunShown()
    uiFile.setText(Config.serializeUi())
    return "ok"
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
    root.applyHostSettings()
    Protocol.reset()
    mkdirState.running = true
    whichProc.running = true
  }

  Component.onDestruction: {
    root.shuttingDown = true
    helper.running = false
  }
}
