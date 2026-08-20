.pragma library

var lastId = 0
var lastAcceptedQueryId = 0
var lastAcceptedPreviewId = 0
var inFlightPreview = 0
var inFlightPrefetch = 0

function reset() {
  lastId = 0
  lastAcceptedQueryId = 0
  lastAcceptedPreviewId = 0
  inFlightPreview = 0
  inFlightPrefetch = 0
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

function acceptPreview(msg) {
  if (!msg)
    return false
  if (msg.kind !== "preview")
    return false
  if (isStale(lastAcceptedPreviewId, msg.id))
    return false
  lastAcceptedPreviewId = Number(msg.id) || 0
  if (inFlightPreview === msg.id)
    inFlightPreview = 0
  if (inFlightPrefetch === msg.id)
    inFlightPrefetch = 0
  return true
}

function canStartPreview() {
  return inFlightPreview === 0
}

function canStartPrefetch() {
  return inFlightPrefetch === 0
}

function markPreview(id) {
  inFlightPreview = Number(id) || 0
}

function markPrefetch(id) {
  inFlightPrefetch = Number(id) || 0
}

function dropInFlight(id) {
  var n = Number(id) || 0
  if (inFlightPreview === n)
    inFlightPreview = 0
  if (inFlightPrefetch === n)
    inFlightPrefetch = 0
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
