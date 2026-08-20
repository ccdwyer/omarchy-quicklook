.pragma library

function clampByte(n) {
  var v = Math.round(Number(n) || 0)
  if (v < 0)
    return 0
  if (v > 255)
    return 255
  return v
}

function parseColor(value) {
  var s = String(value || "").trim()
  if (!s.length)
    return { r: 26, g: 26, b: 26, a: 255 }
  if (s.indexOf("#") === 0) {
    var hex = s.slice(1)
    if (hex.length === 8)
      hex = hex.slice(2)
    if (hex.length === 3) {
      return {
        r: parseInt(hex.charAt(0) + hex.charAt(0), 16),
        g: parseInt(hex.charAt(1) + hex.charAt(1), 16),
        b: parseInt(hex.charAt(2) + hex.charAt(2), 16),
        a: 255
      }
    }
    if (hex.length === 6) {
      return {
        r: parseInt(hex.slice(0, 2), 16),
        g: parseInt(hex.slice(2, 4), 16),
        b: parseInt(hex.slice(4, 6), 16),
        a: 255
      }
    }
  }
  var m = s.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/)
  if (m) {
    return { r: Number(m[1]), g: Number(m[2]), b: Number(m[3]), a: 255 }
  }
  return { r: 26, g: 26, b: 26, a: 255 }
}

function toHex(c) {
  function h(n) {
    var s = clampByte(n).toString(16)
    return s.length === 1 ? "0" + s : s
  }
  return "#" + h(c.r) + h(c.g) + h(c.b)
}

function mix(a, b, t) {
  var u = Number(t)
  if (isNaN(u))
    u = 0.5
  return {
    r: clampByte(a.r + (b.r - a.r) * u),
    g: clampByte(a.g + (b.g - a.g) * u),
    b: clampByte(a.b + (b.b - a.b) * u),
    a: 255
  }
}

function paletteFromTokens(bg, fg, accent, surface) {
  var pbg = parseColor(bg)
  var pfg = parseColor(fg)
  var pac = parseColor(accent)
  var psu = surface ? parseColor(surface) : mix(pbg, pfg, 0.08)
  return {
    bg: toHex(pbg),
    fg: toHex(pfg),
    accent: toHex(pac),
    surface: toHex(psu),
    zebra: toHex(mix(pbg, pfg, 0.06)),
    zebraAlt: toHex(mix(pbg, pfg, 0.12)),
    comment: toHex(mix(pfg, pbg, 0.55)),
    string: toHex(mix(pac, { r: 232, g: 176, b: 96, a: 255 }, 0.45)),
    keyword: toHex(pac),
    number: toHex(mix(pac, { r: 140, g: 210, b: 180, a: 255 }, 0.35)),
    func: toHex(mix(pfg, pac, 0.28)),
    checkerA: toHex(mix(pbg, pfg, 0.08)),
    checkerB: toHex(mix(pbg, pfg, 0.16))
  }
}

function defaultPalette() {
  return paletteFromTokens("#1a1b26", "#c0caf5", "#7aa2f7", "#24283b")
}
