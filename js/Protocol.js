.pragma library

var lastId = 0
var lastAcceptedQueryId = 0
var lastAcceptedPreviewId = 0
var inFlightPreview = 0
var inFlightPrefetch = 0
var inFlightPreviewPath = ""
var inFlightPrefetchPath = ""
var pendingPreview = null
var pendingPrefetch = null

function reset() {
  lastId = 0
  lastAcceptedQueryId = 0
  lastAcceptedPreviewId = 0
  inFlightPreview = 0
  inFlightPrefetch = 0
  inFlightPreviewPath = ""
  inFlightPrefetchPath = ""
  pendingPreview = null
  pendingPrefetch = null
}

function nextId() {
  lastId += 1
  return lastId
}

function parseLine(line) {
  var s = String(line || "").trim()
  if (!s.length)
    return null
  try {
    var obj = JSON.parse(s)
    if (!obj || typeof obj !== "object")
      return null
    if (obj.id === undefined || obj.id === null)
      obj.id = 0
    obj.id = Number(obj.id) || 0
    obj.kind = String(obj.kind || "")
    return obj
  } catch (e) {
    return null
  }
}

function isStale(acceptedId, incomingId) {
  return Number(incomingId) < Number(acceptedId)
}

function acceptQuery(msg) {
  if (!msg)
    return false
  if (msg.kind !== "results")
    return false
  if (isStale(lastAcceptedQueryId, msg.id))
    return false
  lastAcceptedQueryId = Number(msg.id) || 0
  return true
}

function slotClass(id) {
  var n = Number(id) || 0
  if (n > 0 && inFlightPreview === n)
    return "preview"
  if (n > 0 && inFlightPrefetch === n)
    return "prefetch"
  return ""
}

function classifyAndClear(id) {
  var cls = slotClass(id)
  clearSlot(id)
  return cls
}

function acceptForegroundPreview(msg) {
  if (!msg)
    return false
  if (msg.kind !== "preview")
    return false
  if (isStale(lastAcceptedPreviewId, msg.id))
    return false
  lastAcceptedPreviewId = Number(msg.id) || 0
  return true
}

function acceptPreview(msg) {
  if (!msg)
    return false
  if (msg.kind !== "preview")
    return false
  var cls = classifyAndClear(msg.id)
  if (cls === "prefetch")
    return false
  return acceptForegroundPreview(msg)
}

function canStartPreview() {
  return inFlightPreview === 0
}

function canStartPrefetch() {
  return inFlightPrefetch === 0
}

function markPreview(id, path) {
  inFlightPreview = Number(id) || 0
  inFlightPreviewPath = String(path || "")
}

function markPrefetch(id, path) {
  inFlightPrefetch = Number(id) || 0
  inFlightPrefetchPath = String(path || "")
}

function clearSlot(id) {
  var n = Number(id) || 0
  if (inFlightPreview === n) {
    inFlightPreview = 0
    inFlightPreviewPath = ""
  }
  if (inFlightPrefetch === n) {
    inFlightPrefetch = 0
    inFlightPrefetchPath = ""
  }
}

function dropInFlight(id) {
  clearSlot(id)
}

function isInFlight(id) {
  var n = Number(id) || 0
  return n > 0 && (inFlightPreview === n || inFlightPrefetch === n)
}

function pathForInFlight(id) {
  var n = Number(id) || 0
  if (inFlightPreview === n)
    return inFlightPreviewPath
  if (inFlightPrefetch === n)
    return inFlightPrefetchPath
  return ""
}

function queueOrStartPreview(req) {
  if (!req)
    return null
  if (inFlightPreview === 0) {
    markPreview(req.id, req.path)
    return req
  }
  pendingPreview = req
  return null
}

function queueOrStartPrefetch(req) {
  if (!req)
    return null
  if (inFlightPrefetch === 0) {
    markPrefetch(req.id, req.path)
    return req
  }
  pendingPrefetch = req
  return null
}

function takeReadyPreview() {
  if (inFlightPreview !== 0 || !pendingPreview)
    return null
  var req = pendingPreview
  pendingPreview = null
  markPreview(req.id, req.path)
  return req
}

function takeReadyPrefetch() {
  if (inFlightPrefetch !== 0 || !pendingPrefetch)
    return null
  var req = pendingPrefetch
  pendingPrefetch = null
  markPrefetch(req.id, req.path)
  return req
}

function pendingPreviewId() {
  return pendingPreview ? pendingPreview.id : 0
}

function pendingPrefetchId() {
  return pendingPrefetch ? pendingPrefetch.id : 0
}

function acceptedQueryId() {
  return lastAcceptedQueryId
}

function acceptedPreviewId() {
  return lastAcceptedPreviewId
}

function previewSlot() {
  return inFlightPreview
}

function prefetchSlot() {
  return inFlightPrefetch
}

function queryRequest(q) {
  return { id: nextId(), cmd: "query", q: String(q || "") }
}

function previewRequest(path, page) {
  var req = { id: nextId(), cmd: "preview", path: String(path || "") }
  if (page !== undefined && page !== null)
    req.page = Number(page) || 1
  return req
}

function prefetchRequest(path) {
  return { id: nextId(), cmd: "prefetch", path: String(path || "") }
}

function statusRequest() {
  return { id: nextId(), cmd: "status" }
}

function themeRequest(palette) {
  return { id: nextId(), cmd: "theme", palette: palette || {} }
}

function configRequest(cfg) {
  var req = { id: nextId(), cmd: "config" }
  if (!cfg)
    return req
  if (cfg.roots)
    req.roots = cfg.roots
  if (cfg.watchCap !== undefined)
    req.watchCap = cfg.watchCap
  if (cfg.cacheMb !== undefined)
    req.cacheMb = cfg.cacheMb
  if (cfg.maxFiles !== undefined)
    req.maxFiles = cfg.maxFiles
  if (cfg.extraExclude)
    req.extraExclude = cfg.extraExclude
  return req
}

function openRequest(path) {
  return { id: nextId(), cmd: "open", path: String(path || "") }
}

function revealRequest(path) {
  return { id: nextId(), cmd: "reveal", path: String(path || "") }
}

function selectRequest(path) {
  return { id: nextId(), cmd: "select", path: String(path || "") }
}

function warmupRequest() {
  return { id: nextId(), cmd: "warmup" }
}
