.pragma library

var defaults = {
  watchCap: 2000,
  cacheMb: 500,
  maxFiles: 500000,
  roots: [],
  extraExclude: []
}

var current = {
  watchCap: 2000,
  cacheMb: 500,
  maxFiles: 500000,
  roots: [],
  extraExclude: [],
  firstRunShown: false
}

function reset() {
  current = {
    watchCap: defaults.watchCap,
    cacheMb: defaults.cacheMb,
    maxFiles: defaults.maxFiles,
    roots: [],
    extraExclude: [],
    firstRunShown: false
  }
}

function expandHome(path, home) {
  var s = String(path || "")
  var h = String(home || "")
  if (!s.length)
    return s
  if (s === "~")
    return h || s
  if (s.indexOf("~/") === 0)
    return (h || "") + s.slice(1)
  return s
}

function asStringList(value) {
  if (!value)
    return []
  if (typeof value === "string") {
    var s = value.trim()
    if (!s.length)
      return []
    if (s.charAt(0) === "[") {
      try {
        return asStringList(JSON.parse(s))
      } catch (e) {
        return [s]
      }
    }
    return s.split(",").map(function(p) { return p.trim() }).filter(function(p) { return p.length })
  }
  if (typeof value.length === "number") {
    var out = []
    for (var i = 0; i < value.length; i++) {
      var item = String(value[i] || "").trim()
      if (item.length)
        out.push(item)
    }
    return out
  }
  return []
}

function applyInline(entry, home) {
  if (!entry || typeof entry !== "object")
    return snapshot()
  if (entry.watchCap !== undefined)
    current.watchCap = Math.max(16, Number(entry.watchCap) || defaults.watchCap)
  if (entry.cacheMb !== undefined)
    current.cacheMb = Math.max(16, Number(entry.cacheMb) || defaults.cacheMb)
  if (entry.maxFiles !== undefined)
    current.maxFiles = Math.max(1000, Number(entry.maxFiles) || defaults.maxFiles)
  if (entry.roots !== undefined) {
    current.roots = asStringList(entry.roots).map(function(p) {
      return expandHome(p, home)
    })
  }
  if (entry.extraExclude !== undefined)
    current.extraExclude = asStringList(entry.extraExclude)
  if (entry.firstRunShown !== undefined)
    current.firstRunShown = entry.firstRunShown === true || entry.firstRunShown === "true"
  return snapshot()
}

function snapshot() {
  return {
    watchCap: current.watchCap,
    cacheMb: current.cacheMb,
    maxFiles: current.maxFiles,
    roots: current.roots.slice(),
    extraExclude: current.extraExclude.slice(),
    firstRunShown: current.firstRunShown
  }
}

function markFirstRunShown() {
  current.firstRunShown = true
}

function serializeUi() {
  return JSON.stringify({ firstRunShown: !!current.firstRunShown }) + "\n"
}

function loadUi(text) {
  try {
    var obj = JSON.parse(String(text || "{}"))
    if (obj && (obj.firstRunShown === true || obj.firstRunShown === "true"))
      current.firstRunShown = true
  } catch (e) {}
  return snapshot()
}

function privacySentence(roots, home) {
  var r = roots && roots.length ? roots : [home || "~"]
  var shown = r.slice(0, 3).join(", ")
  if (r.length > 3)
    shown += ", +" + (r.length - 3) + " more"
  return "Indexes " + shown + " (skips .ssh, .gnupg, password-store, keyrings, node_modules, target, .git). Preview cache ≤ 500 MB in ~/.cache/quicklook."
}
