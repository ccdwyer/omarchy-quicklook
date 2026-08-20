.pragma library

function sampleBasename(path) {
  var s = String(path || "")
  var slash = s.lastIndexOf("/")
  return slash >= 0 ? s.slice(slash + 1) : s
}

function defaultSamples(pluginDir) {
  var root = String(pluginDir || "")
  if (root.length && root.charAt(root.length - 1) === "/")
    root = root.slice(0, root.length - 1)
  var base = root + "/samples"
  return [
    { path: base + "/invoice.pdf", name: "invoice.pdf", kind: "pdf", score: 900, mtime: 0, size: 0 },
    { path: base + "/photo.png", name: "photo.png", kind: "image", score: 880, mtime: 0, size: 0 },
    { path: base + "/sales.csv", name: "sales.csv", kind: "csv", score: 860, mtime: 0, size: 0 },
    { path: base + "/themed.rs", name: "themed.rs", kind: "code", score: 840, mtime: 0, size: 0 },
    { path: base + "/README.md", name: "README.md", kind: "code", score: 820, mtime: 0, size: 0 }
  ]
}

function fuzzyScore(hay, needle) {
  var h = String(hay || "").toLowerCase()
  var n = String(needle || "").toLowerCase()
  if (!n.length)
    return 1
  if (h === n)
    return 1000
  var idx = h.indexOf(n)
  if (idx === 0)
    return 800 - Math.min(h.length, 80)
  if (idx > 0)
    return 600 - idx
  var hi = 0
  var streak = 0
  var score = 0
  for (var ni = 0; ni < n.length; ni++) {
    var found = -1
    for (var j = hi; j < h.length; j++) {
      if (h.charAt(j) === n.charAt(ni)) {
        found = j
        break
      }
    }
    if (found < 0)
      return 0
    if (found === hi)
      streak += 1
    else
      streak = 1
    score += 8 + streak * 4
    if (found === 0 || h.charAt(found - 1) === "/" || h.charAt(found - 1) === "." || h.charAt(found - 1) === "_" || h.charAt(found - 1) === "-")
      score += 20
    hi = found + 1
  }
  return score
}

function search(items, query, limit) {
  var q = String(query || "")
  var cap = Number(limit) || 40
  var src = items || []
  if (!q.length)
    return src.slice(0, cap)
  var scored = []
  for (var i = 0; i < src.length; i++) {
    var it = src[i]
    var s = Math.max(fuzzyScore(it.name, q), fuzzyScore(it.path, q))
    if (s <= 0)
      continue
    scored.push({
      path: it.path,
      name: it.name || sampleBasename(it.path),
      kind: it.kind || "hex",
      score: s,
      mtime: it.mtime || 0,
      size: it.size || 0
    })
  }
  scored.sort(function(a, b) {
    if (b.score !== a.score)
      return b.score - a.score
    if (a.name < b.name)
      return -1
    if (a.name > b.name)
      return 1
    return 0
  })
  return scored.slice(0, cap)
}

function parseCsvText(text, maxRows) {
  var raw = String(text || "")
  var delim = ","
  var first = raw.split("\n")[0] || ""
  if (first.indexOf("\t") >= 0 && first.split("\t").length > first.split(",").length)
    delim = "\t"
  else if (first.indexOf(";") >= 0 && first.split(";").length > first.split(",").length)
    delim = ";"
  else if (first.indexOf("|") >= 0 && first.split("|").length > first.split(",").length)
    delim = "|"
  var lines = raw.split(/\r?\n/)
  var rows = []
  var cap = Number(maxRows) || 500
  for (var i = 0; i < lines.length && rows.length <= cap; i++) {
    if (!lines[i].length && i === lines.length - 1)
      continue
    rows.push(splitCsvLine(lines[i], delim))
  }
  var headers = rows.length ? rows[0] : []
  var body = rows.length ? rows.slice(1, 1 + cap) : []
  return {
    kind: "csv",
    headers: headers,
    rows: body,
    truncated: lines.length - 1 > cap
  }
}

function splitCsvLine(line, delim) {
  var out = []
  var cur = ""
  var quoted = false
  for (var i = 0; i < line.length; i++) {
    var ch = line.charAt(i)
    if (quoted) {
      if (ch === "\"") {
        if (line.charAt(i + 1) === "\"") {
          cur += "\""
          i += 1
        } else {
          quoted = false
        }
      } else {
        cur += ch
      }
    } else if (ch === "\"") {
      quoted = true
    } else if (ch === delim) {
      out.push(cur)
      cur = ""
    } else {
      cur += ch
    }
  }
  out.push(cur)
  return out
}

function escapeHtml(s) {
  return String(s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

function plainHtml(text, large) {
  return {
    kind: "code",
    html: "<pre>" + escapeHtml(text) + "</pre>",
    lang: "text",
    capped: !!large,
    large: !!large,
    label: large ? "large file" : ""
  }
}

function hexHead(bytesText) {
  return {
    kind: "hex",
    hex: String(bytesText || ""),
    magic: "unknown"
  }
}
