.pragma library

// Detect live Hyprland binds and plan a bindings.lua snippet.
// Lua binds show up as dispatcher "__lua" with a description, not the
// omarchy-shell command in `arg`, so "ours" is plugin-id in arg OR our
// descriptions.
//
// Writes happen only when the bar chip's "Set hotkey" (or Remove) is
// clicked. Never auto-assign on first load. Never hl.unbind others.
// Super+Shift+P (Google Photos) and Super+Ctrl+. (Transcode) are never
// candidates.

var PLUGIN_ID = "io.github.chris.quicklook"
var SUPER = 64
var SHIFT = 1
var CTRL = 4
var ALT = 8

var CANDIDATES = [
    {
        keys: "SUPER + PERIOD",
        modmask: SUPER,
        key: "PERIOD",
        desc: "QuickLook",
        cmd: "omarchy-shell shell toggle io.github.chris.quicklook '{}'",
        alternates: [
            { keys: "SUPER + ALT + PERIOD", modmask: SUPER + ALT, key: "PERIOD" }
        ]
    }
]

var offer = {
    needed: true,
    note: "",
    installed: 0,
    hotkeyLabel: "",
    canSet: false,
    toAdd: [],
    skipped: []
}

function setOffer(next) {
    offer = next || offer
}

function parseBinds(raw) {
    if (!raw)
        return []
    var data = raw
    if (typeof raw === "string") {
        try {
            data = JSON.parse(raw)
        } catch (e) {
            return []
        }
    }
    return data && data.length ? data : []
}

function keyOf(bind) {
    return String((bind && bind.key) || "").toUpperCase()
}

function keysMatch(a, b) {
    var x = String(a || "").toUpperCase()
    var y = String(b || "").toUpperCase()
    if (x === y)
        return true
    function isPeriod(k) { return k === "PERIOD" || k === "." }
    return isPeriod(x) && isPeriod(y)
}

function isOurs(bind) {
    if (!bind)
        return false
    var arg = String(bind.arg || "")
    var desc = String(bind.description || "")
    if (arg.indexOf(PLUGIN_ID) >= 0)
        return true
    for (var i = 0; i < CANDIDATES.length; i++) {
        if (desc === CANDIDATES[i].desc)
            return true
    }
    return false
}

function oursCount(binds) {
    var n = 0
    var list = binds || []
    for (var i = 0; i < list.length; i++) {
        if (isOurs(list[i]))
            n++
    }
    return n
}

function comboFromBind(bind) {
    if (!bind)
        return ""
    var m = Number(bind.modmask) || 0
    var parts = []
    if (m & SUPER)
        parts.push("SUPER")
    if (m & CTRL)
        parts.push("CTRL")
    if (m & SHIFT)
        parts.push("SHIFT")
    if (m & ALT)
        parts.push("ALT")
    var k = keyOf(bind)
    if (k === ".")
        k = "PERIOD"
    if (!k)
        return ""
    parts.push(k)
    return parts.join(" + ")
}

function oursCombos(binds) {
    var out = []
    var seen = {}
    var list = binds || []
    for (var i = 0; i < list.length; i++) {
        if (!isOurs(list[i]))
            continue
        var keys = comboFromBind(list[i])
        if (!keys || seen[keys])
            continue
        seen[keys] = true
        out.push(keys)
    }
    return out
}

function prettyCombo(keys) {
    var s = String(keys || "")
    s = s.replace(/SUPER/gi, "Super")
    s = s.replace(/CONTROL/gi, "Ctrl")
    s = s.replace(/CTRL/gi, "Ctrl")
    s = s.replace(/SHIFT/gi, "Shift")
    s = s.replace(/ALT/gi, "Alt")
    s = s.replace(/PERIOD/gi, ".")
    s = s.replace(/ \+ /g, "+")
    return s
}

function prettyList(keysList) {
    var list = keysList || []
    var out = []
    for (var i = 0; i < list.length; i++)
        out.push(prettyCombo(list[i]))
    return out.join(", ")
}

function comboOwner(binds, modmask, key) {
    var want = String(key || "").toUpperCase()
    var list = binds || []
    for (var i = 0; i < list.length; i++) {
        var b = list[i]
        if (Number(b.modmask) !== Number(modmask))
            continue
        if (!keysMatch(keyOf(b), want))
            continue
        if (isOurs(b))
            return { ours: true, desc: String(b.description || "") }
        return { ours: false, desc: String(b.description || b.dispatcher || "already bound") }
    }
    return null
}

function pickCombo(binds, candidate) {
    var owner = comboOwner(binds, candidate.modmask, candidate.key)
    if (!owner)
        return { keys: candidate.keys, modmask: candidate.modmask, key: candidate.key, desc: candidate.desc, cmd: candidate.cmd, chosen: candidate.keys }
    if (owner.ours)
        return { already: true, keys: candidate.keys, desc: candidate.desc }
    var alts = candidate.alternates || []
    for (var i = 0; i < alts.length; i++) {
        var a = alts[i]
        if (!comboOwner(binds, a.modmask, a.key))
            return {
                keys: a.keys,
                modmask: a.modmask,
                key: a.key,
                desc: candidate.desc,
                cmd: candidate.cmd,
                chosen: a.keys,
                preferred: candidate.keys,
                conflict: owner.desc
            }
    }
    return { skipped: true, keys: candidate.keys, desc: candidate.desc, conflict: owner.desc }
}

function plan(binds) {
    var toAdd = []
    var skipped = []
    var already = 0
    for (var i = 0; i < CANDIDATES.length; i++) {
        var pick = pickCombo(binds, CANDIDATES[i])
        if (pick.already)
            already++
        else if (pick.skipped)
            skipped.push(pick)
        else
            toAdd.push(pick)
    }
    var liveOurs = oursCount(binds)
    if (liveOurs > 0)
        already = Math.max(already, liveOurs)
    var needed = already === 0
    if (!needed)
        toAdd = []
    var installedKeys = oursCombos(binds)
    var note = ""
    if (!needed)
        note = ""
    else if (!toAdd.length && skipped.length)
        note = skipped.map(function(s) { return s.keys + " is " + (s.conflict || "taken") }).join("; ")
    else if (toAdd.length) {
        var bits = toAdd.map(function(p) { return p.chosen || p.keys })
        note = "Add " + bits.join(", ")
        for (var s = 0; s < skipped.length; s++)
            note += " — skipped " + skipped[s].keys + " (" + skipped[s].conflict + ")"
    }
    return {
        needed: needed,
        already: already,
        toAdd: toAdd,
        skipped: skipped,
        note: note,
        installed: installedKeys,
        hotkeyLabel: prettyList(installedKeys),
        canSet: needed && toAdd.length > 0
    }
}

function luaLine(item) {
    var keys = String(item.chosen || item.keys || "").replace(/"/g, "")
    var desc = String(item.desc || "").replace(/"/g, "")
    var cmd = String(item.cmd || "").replace(/"/g, '\\"')
    return "o.bind(\"" + keys + "\", \"" + desc + "\", \"" + cmd + "\")"
}

function luaBlock(items) {
    var lines = []
    var list = items || []
    for (var i = 0; i < list.length; i++)
        lines.push(luaLine(list[i]))
    return lines.join("\n")
}

function applyScan(raw) {
    var p = plan(parseBinds(raw))
    setOffer(p)
    return p
}

function notifyBody(items, skipped) {
    var lines = []
    var list = items || []
    for (var i = 0; i < list.length; i++) {
        var it = list[i]
        lines.push((it.chosen || it.keys) + " — " + it.desc)
    }
    var miss = skipped || []
    for (var s = 0; s < miss.length; s++)
        lines.push("skipped " + miss[s].keys + " (" + (miss[s].conflict || "taken") + ")")
    return lines.join("\n")
}

function notifyArgv(appName, headline, body) {
    return ["omarchy", "notification", "send", "--app-name", String(appName || PLUGIN_ID), "-g", "󰌌", String(headline || "Keybindings"), String(body || "")]
}
