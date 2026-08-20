.pragma library

var IMAGE_EXT = {
  png: 1, jpg: 1, jpeg: 1, webp: 1, svg: 1, gif: 1, bmp: 1, ico: 1, tif: 1, tiff: 1
}
var PDF_EXT = { pdf: 1 }
var CSV_EXT = { csv: 1, tsv: 1 }
var VIDEO_EXT = { mp4: 1, webm: 1, mkv: 1, mov: 1, avi: 1, m4v: 1 }
var CODE_EXT = {
  rs: 1, js: 1, jsx: 1, ts: 1, tsx: 1, mjs: 1, cjs: 1, py: 1, go: 1, c: 1, h: 1,
  cc: 1, cpp: 1, hpp: 1, hh: 1, java: 1, kt: 1, kts: 1, rb: 1, php: 1, sh: 1,
  bash: 1, zsh: 1, fish: 1, lua: 1, qml: 1, json: 1, yaml: 1, yml: 1, toml: 1,
  md: 1, html: 1, htm: 1, css: 1, scss: 1, xml: 1, sql: 1, swift: 1, cs: 1,
  scala: 1, ex: 1, exs: 1, hs: 1, elm: 1, zig: 1, nim: 1, r: 1, pl: 1, pm: 1,
  vim: 1, dockerfile: 1, makefile: 1, mk: 1, txt: 1, conf: 1, ini: 1, log: 1,
  env: 1, lock: 1, gradle: 1, cmake: 1, s: 1, asm: 1, proto: 1, graphql: 1,
  vue: 1, svelte: 1, nix: 1, tf: 1, hcl: 1
}

function extOf(path) {
  var s = String(path || "")
  var slash = s.lastIndexOf("/")
  var base = slash >= 0 ? s.slice(slash + 1) : s
  var lower = base.toLowerCase()
  if (lower === "makefile" || lower === "dockerfile" || lower === "cmakelists.txt")
    return lower === "cmakelists.txt" ? "cmake" : lower
  var dot = lower.lastIndexOf(".")
  if (dot < 0)
    return ""
  return lower.slice(dot + 1)
}

function basename(path) {
  var s = String(path || "")
  var slash = s.lastIndexOf("/")
  return slash >= 0 ? s.slice(slash + 1) : s
}

function dirname(path) {
  var s = String(path || "")
  var slash = s.lastIndexOf("/")
  if (slash <= 0)
    return slash === 0 ? "/" : ""
  return s.slice(0, slash)
}

function kindOf(path, isDir) {
  if (isDir)
    return "dir"
  var ext = extOf(path)
  if (IMAGE_EXT[ext])
    return "image"
  if (PDF_EXT[ext])
    return "pdf"
  if (CSV_EXT[ext])
    return "csv"
  if (VIDEO_EXT[ext])
    return "video"
  if (CODE_EXT[ext])
    return "code"
  return "hex"
}

function glyphFor(kind) {
  if (kind === "image")
    return "▣"
  if (kind === "pdf")
    return "▤"
  if (kind === "csv")
    return "▦"
  if (kind === "code")
    return "⌘"
  if (kind === "dir")
    return "▢"
  if (kind === "video")
    return "▶"
  return "⬡"
}

function labelFor(kind) {
  if (kind === "image")
    return "image"
  if (kind === "pdf")
    return "pdf"
  if (kind === "csv")
    return "table"
  if (kind === "code")
    return "code"
  if (kind === "dir")
    return "folder"
  if (kind === "video")
    return "video"
  return "binary"
}

function isAnimated(path) {
  return extOf(path) === "gif"
}

function fileUrl(path) {
  var s = String(path || "")
  if (!s.length)
    return ""
  if (s.indexOf("file:") === 0)
    return s
  return "file://" + s
}

function humanSize(n) {
  var v = Number(n) || 0
  if (v < 1024)
    return v + " B"
  if (v < 1024 * 1024)
    return (v / 1024).toFixed(1) + " KB"
  if (v < 1024 * 1024 * 1024)
    return (v / (1024 * 1024)).toFixed(1) + " MB"
  return (v / (1024 * 1024 * 1024)).toFixed(2) + " GB"
}
