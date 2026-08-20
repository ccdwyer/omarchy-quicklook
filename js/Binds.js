.pragma library

var SUPER = 64
var SHIFT = 1
var CTRL = 4
var ALT = 8

function keyIsPeriod(key) {
  var k = String(key || "").toLowerCase()
  return k === "period" || k === "."
}

function hasBit(mask, bit) {
  return (Number(mask) & bit) === bit
}

function isSuperPeriod(bind) {
  if (!bind || typeof bind !== "object")
    return false
  if (!keyIsPeriod(bind.key))
    return false
  var mask = Number(bind.modmask)
  if (isNaN(mask))
    return false
  if (!hasBit(mask, SUPER))
    return false
  if (hasBit(mask, SHIFT) || hasBit(mask, CTRL) || hasBit(mask, ALT))
    return false
  return true
}

function parseBinds(jsonText) {
  var s = String(jsonText || "").trim()
  if (!s.length)
    return []
  try {
    var arr = JSON.parse(s)
    if (arr && typeof arr.length === "number")
      return arr
  } catch (e) {}
  return []
}

function superPeriodBound(jsonText) {
  var binds = parseBinds(jsonText)
  for (var i = 0; i < binds.length; i++) {
    if (isSuperPeriod(binds[i]))
      return true
  }
  return false
}
