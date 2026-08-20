#!/usr/bin/env node
"use strict"

const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

const ROOT = path.resolve(__dirname, "..")
const JS = path.join(ROOT, "js")
const FIX = path.join(__dirname, "fixtures")
const SAMPLES = path.join(ROOT, "samples")

function loadEngine(file) {
  const src = fs
    .readFileSync(path.join(JS, file), "utf8")
    .replace(/^\.pragma library\s*\n/, "")
  const sandbox = {
    console,
    Date,
    Math,
    JSON,
    String,
    Number,
    Array,
    Object,
    parseInt,
    isNaN,
    exports: {},
    module: { exports: {} }
  }
  vm.createContext(sandbox)
  vm.runInContext(src, sandbox, { filename: file })
  const exported = {}
  for (const key of Object.keys(sandbox)) {
    if (["console", "Date", "Math", "JSON", "String", "Number", "Array", "Object", "parseInt", "isNaN", "exports", "module"].indexOf(key) >= 0)
      continue
    exported[key] = sandbox[key]
  }
  return exported
}

const Protocol = loadEngine("Protocol.js")
const Format = loadEngine("Format.js")
const Theme = loadEngine("Theme.js")
const Config = loadEngine("Config.js")
const Fallback = loadEngine("Fallback.js")
const Binds = loadEngine("Binds.js")

let passed = 0
let failed = 0

function test(name, fn) {
  try {
    Protocol.reset()
    Config.reset()
    fn()
    passed += 1
    process.stdout.write("ok  " + name + "\n")
  } catch (err) {
    failed += 1
    process.stderr.write("FAIL " + name + "\n" + (err && err.stack ? err.stack : err) + "\n")
  }
}

test("protocol: ids are monotonic", () => {
  const a = Protocol.nextId()
  const b = Protocol.nextId()
  const c = Protocol.nextId()
  assert.strictEqual(a + 1, b)
  assert.strictEqual(b + 1, c)
})

test("protocol: stale responses drop", () => {
  assert.strictEqual(Protocol.isStale(10, 9), true)
  assert.strictEqual(Protocol.isStale(10, 10), false)
  assert.strictEqual(Protocol.isStale(10, 11), false)
  const first = Protocol.parseLine('{"id":10,"kind":"results","results":[]}')
  assert.strictEqual(Protocol.acceptQuery(first), true)
  const stale = Protocol.parseLine('{"id":9,"kind":"results","results":[]}')
  assert.strictEqual(Protocol.acceptQuery(stale), false)
  const fresh = Protocol.parseLine('{"id":11,"kind":"results","results":[{"path":"/a"}]}')
  assert.strictEqual(Protocol.acceptQuery(fresh), true)
  assert.strictEqual(Protocol.acceptedQueryId(), 11)
})

test("protocol: createSession isolates slots from the module", () => {
  const a = Protocol.createSession()
  const b = Protocol.createSession()
  a.markPreview(7, "/a")
  assert.strictEqual(a.canStartPreview(), false)
  assert.strictEqual(b.canStartPreview(), true)
  assert.strictEqual(Protocol.canStartPreview(), true)
  assert.strictEqual(a.previewRequest("/x.png").id, 1)
  assert.strictEqual(b.previewRequest("/y.png").id, 1)
})

test("protocol: preview backpressure slots", () => {
  assert.strictEqual(Protocol.canStartPreview(), true)
  assert.strictEqual(Protocol.canStartPrefetch(), true)
  Protocol.markPreview(4)
  Protocol.markPrefetch(5)
  assert.strictEqual(Protocol.canStartPreview(), false)
  assert.strictEqual(Protocol.canStartPrefetch(), false)
  const msg = Protocol.parseLine('{"id":4,"kind":"preview","preview":{"kind":"image"}}')
  assert.strictEqual(Protocol.acceptPreview(msg), true)
  assert.strictEqual(Protocol.previewSlot(), 0)
})

test("protocol: latest preview replaces queued work", () => {
  const a = Protocol.previewRequest("/a.pdf")
  const first = Protocol.queueOrStartPreview(a)
  assert.ok(first)
  assert.strictEqual(Protocol.canStartPreview(), false)
  const b = Protocol.previewRequest("/b.pdf")
  const c = Protocol.previewRequest("/c.pdf")
  assert.strictEqual(Protocol.queueOrStartPreview(b), null)
  assert.strictEqual(Protocol.queueOrStartPreview(c), null)
  assert.strictEqual(Protocol.pendingPreviewId(), c.id)
  Protocol.acceptPreview({ id: a.id, kind: "preview", preview: { kind: "pdf" } })
  const next = Protocol.takeReadyPreview()
  assert.ok(next)
  assert.strictEqual(next.path, "/c.pdf")
  assert.strictEqual(Protocol.pendingPreviewId(), 0)
})

test("protocol: prefetch is a separate slot", () => {
  const p = Protocol.previewRequest("/sel.rs")
  assert.ok(Protocol.queueOrStartPreview(p))
  const f = Protocol.prefetchRequest("/top.rs")
  assert.ok(Protocol.queueOrStartPrefetch(f))
  assert.strictEqual(Protocol.canStartPreview(), false)
  assert.strictEqual(Protocol.canStartPrefetch(), false)
  const f2 = Protocol.prefetchRequest("/other.rs")
  assert.strictEqual(Protocol.queueOrStartPrefetch(f2), null)
  assert.strictEqual(Protocol.slotClass(f.id), "prefetch")
  assert.strictEqual(Protocol.acceptPreview({ id: f.id, kind: "preview", preview: { kind: "code" } }), false)
  const next = Protocol.takeReadyPrefetch()
  assert.ok(next)
  assert.strictEqual(next.path, "/other.rs")
  assert.strictEqual(Protocol.slotClass(p.id), "preview")
})

test("protocol: abandonInFlight clears both slots", () => {
  const p = Protocol.previewRequest("/sel.rs")
  const f = Protocol.prefetchRequest("/top.rs")
  assert.ok(Protocol.queueOrStartPreview(p))
  assert.ok(Protocol.queueOrStartPrefetch(f))
  const extra = Protocol.previewRequest("/queued.rs")
  assert.strictEqual(Protocol.queueOrStartPreview(extra), null)
  const snap = Protocol.abandonInFlight()
  assert.strictEqual(Protocol.canStartPreview(), true)
  assert.strictEqual(Protocol.canStartPrefetch(), true)
  assert.strictEqual(snap.previewPath, "/sel.rs")
  assert.ok(snap.queuedPreview)
  assert.strictEqual(snap.queuedPreview.path, "/queued.rs")
})

test("protocol: prefetch completion is not a foreground accept", () => {
  const sel = Protocol.previewRequest("/selected.csv")
  assert.ok(Protocol.queueOrStartPreview(sel))
  const top = Protocol.prefetchRequest("/top.png")
  assert.ok(Protocol.queueOrStartPrefetch(top))
  assert.strictEqual(Protocol.slotClass(top.id), "prefetch")
  assert.strictEqual(Protocol.classifyAndClear(top.id), "prefetch")
  assert.strictEqual(Protocol.slotClass(top.id), "")
  assert.strictEqual(Protocol.slotClass(sel.id), "preview")
})

test("protocol: implicit query request shape", () => {
  const req = Protocol.queryRequest("invo")
  assert.strictEqual(req.cmd, "query")
  assert.strictEqual(req.q, "invo")
  assert.ok(req.id > 0)
})

test("protocol: garbage line is null", () => {
  assert.strictEqual(Protocol.parseLine(""), null)
  assert.strictEqual(Protocol.parseLine("not-json"), null)
  assert.ok(Protocol.parseLine('{"id":1,"kind":"ok"}'))
})

test("protocol: out-of-order preview is dropped", () => {
  const newer = Protocol.parseLine('{"id":8,"kind":"preview","preview":{"kind":"image"}}')
  assert.strictEqual(Protocol.acceptPreview(newer), true)
  const older = Protocol.parseLine('{"id":7,"kind":"preview","preview":{"kind":"hex"}}')
  assert.strictEqual(Protocol.acceptPreview(older), false)
  assert.strictEqual(Protocol.acceptedPreviewId(), 8)
})

test("format: kinds from extensions", () => {
  assert.strictEqual(Format.kindOf("/tmp/invoice.pdf"), "pdf")
  assert.strictEqual(Format.kindOf("/tmp/photo.png"), "image")
  assert.strictEqual(Format.kindOf("/tmp/sales.csv"), "csv")
  assert.strictEqual(Format.kindOf("/tmp/themed.rs"), "code")
  assert.strictEqual(Format.kindOf("/tmp/clip.webm"), "video")
  assert.strictEqual(Format.kindOf("/tmp/a", true), "dir")
  assert.strictEqual(Format.kindOf("/tmp/blob.bin"), "hex")
  assert.strictEqual(Format.isAnimated("/tmp/x.gif"), true)
  assert.strictEqual(Format.fileUrl("/tmp/a"), "file:///tmp/a")
  assert.strictEqual(Format.fileUrl("/tmp/a#b"), "file:///tmp/a%23b")
  assert.strictEqual(Format.fileUrl("/tmp/a?b"), "file:///tmp/a%3Fb")
  assert.strictEqual(Format.fileUrl("/tmp/a%b"), "file:///tmp/a%25b")
})

test("theme: palette from tokens uses font-safe hex", () => {
  const pal = Theme.paletteFromTokens("#1a1b26", "#c0caf5", "#7aa2f7")
  assert.ok(/^#[0-9a-f]{6}$/.test(pal.bg))
  assert.ok(/^#[0-9a-f]{6}$/.test(pal.keyword))
  assert.ok(/^#[0-9a-f]{6}$/.test(pal.zebra))
  const argb = Theme.parseColor("#ff112233")
  assert.strictEqual(argb.r, 0x11)
})

test("config: inline shell.json fields, expand ~", () => {
  const snap = Config.applyInline({
    roots: ["~/Documents", "~/Downloads"],
    watchCap: 100,
    cacheMb: 64,
    extraExclude: "Secrets,tmp"
  }, "/home/chris")
  assert.strictEqual(JSON.stringify(snap.roots), JSON.stringify(["/home/chris/Documents", "/home/chris/Downloads"]))
  assert.strictEqual(snap.watchCap, 100)
  assert.strictEqual(snap.cacheMb, 64)
  assert.ok(snap.extraExclude.indexOf("Secrets") >= 0)
  const line = Config.privacySentence(snap.roots, "/home/chris", snap.cacheMb)
  assert.ok(line.indexOf("Documents") >= 0)
  assert.ok(line.indexOf("64 MB") >= 0)
  assert.ok(line.indexOf("500 MB") < 0)
})

test("fallback: empty query is demo corpus", () => {
  const demo = Fallback.defaultSamples("/plugin")
  assert.strictEqual(demo.length, 5)
  assert.strictEqual(demo[0].name, "invoice.pdf")
  const hits = Fallback.search(demo, "", 10)
  assert.strictEqual(hits[0].name, "invoice.pdf")
})

test("fallback: invo ranks invoice.pdf first", () => {
  const demo = Fallback.defaultSamples("/plugin")
  const hits = Fallback.search(demo, "inv", 10)
  assert.ok(hits.length >= 1)
  assert.strictEqual(hits[0].name, "invoice.pdf")
})

test("fallback: csv parser sniffs delimiter and caps rows", () => {
  const lines = ["a,b"]
  for (let i = 0; i < 600; i++)
    lines.push("x,y")
  const parsed = Fallback.parseCsvText(lines.join("\n"), 500)
  assert.strictEqual(JSON.stringify(parsed.headers), JSON.stringify(["a", "b"]))
  assert.strictEqual(parsed.rows.length, 500)
  assert.strictEqual(parsed.truncated, true)
  const tsv = Fallback.parseCsvText("h1\th2\nv1\tv2\n", 500)
  assert.strictEqual(tsv.headers[1], "h2")
})

test("fallback: html escape for local code path", () => {
  const html = Fallback.plainHtml("<script>alert(1)</script>", false)
  assert.ok(html.html.indexOf("&lt;script&gt;") >= 0)
  assert.ok(html.html.indexOf("<script>") < 0)
})

test("samples: demo corpus files exist", () => {
  for (const name of ["invoice.pdf", "photo.png", "sales.csv", "themed.rs", "README.md"]) {
    const p = path.join(SAMPLES, name)
    assert.ok(fs.existsSync(p), "missing " + name)
    assert.ok(fs.statSync(p).size > 20, name + " too small")
  }
  const csv = fs.readFileSync(path.join(SAMPLES, "sales.csv"), "utf8").trim().split("\n")
  assert.ok(csv.length >= 5001, "csv should have header + 5000 rows")
  const pdf = fs.readFileSync(path.join(SAMPLES, "invoice.pdf"))
  assert.ok(pdf.slice(0, 5).toString() === "%PDF-")
})

test("golden: query invoice fixture shape", () => {
  const fix = JSON.parse(fs.readFileSync(path.join(FIX, "query-invoice.json"), "utf8"))
  assert.strictEqual(fix.id, 41)
  assert.strictEqual(fix.kind, "results")
  assert.strictEqual(fix.results[0].name, "invoice.pdf")
  assert.strictEqual(fix.results[0].kind, "pdf")
})

test("binds: empty live list offers SUPER+PERIOD", () => {
  const p = Binds.plan([])
  assert.strictEqual(p.needed, true)
  assert.strictEqual(p.toAdd.length, 1)
  assert.strictEqual(p.toAdd[0].chosen, "SUPER + PERIOD")
  assert.ok(Binds.luaBlock(p.toAdd).indexOf("o.bind(\"SUPER + PERIOD\"") === 0)
  assert.ok(p.toAdd[0].chosen !== "SUPER + SHIFT + P")
})

test("binds: SUPER+CTRL+PERIOD transcode is not a collision", () => {
  const live = [
    { modmask: 68, key: "PERIOD", dispatcher: "__lua", arg: "194", description: "Transcode" }
  ]
  const p = Binds.plan(live)
  assert.strictEqual(p.needed, true)
  assert.strictEqual(p.toAdd[0].chosen, "SUPER + PERIOD")
})

test("binds: lowercase period key matches SUPER+PERIOD", () => {
  const live = [
    { modmask: 64, key: "period", dispatcher: "exec", arg: "other", description: "taken" }
  ]
  const p = Binds.plan(live)
  assert.strictEqual(p.needed, true)
  assert.strictEqual(p.toAdd[0].chosen, "SUPER + ALT + PERIOD")
})

test("binds: period as '.' also matches", () => {
  const live = [
    { modmask: 64, key: ".", dispatcher: "exec", arg: "other", description: "taken" }
  ]
  const p = Binds.plan(live)
  assert.strictEqual(p.toAdd[0].chosen, "SUPER + ALT + PERIOD")
})

test("binds: SUPER+SHIFT+P stock photos is not used as an alternate", () => {
  const live = [
    { modmask: 64, key: "PERIOD", dispatcher: "exec", arg: "other", description: "taken" },
    { modmask: 65, key: "P", dispatcher: "__lua", arg: "322", description: "Google Photos" }
  ]
  const p = Binds.plan(live)
  assert.strictEqual(p.toAdd[0].chosen, "SUPER + ALT + PERIOD")
  assert.ok(p.toAdd.every((x) => x.chosen !== "SUPER + SHIFT + P"))
})

test("binds: already-ours via lua description hides the offer", () => {
  const live = [
    { modmask: 64, key: "PERIOD", dispatcher: "__lua", arg: "15", description: "QuickLook" }
  ]
  const p = Binds.plan(live)
  assert.strictEqual(p.needed, false)
  assert.strictEqual(p.already, 1)
  assert.strictEqual(p.toAdd.length, 0)
})

test("binds: already-ours via plugin id in arg hides the offer", () => {
  const live = [
    { modmask: 72, key: "PERIOD", dispatcher: "exec", arg: "omarchy-shell shell toggle io.github.chris.quicklook '{}'", description: "" }
  ]
  const p = Binds.plan(live)
  assert.strictEqual(p.needed, false)
  assert.strictEqual(p.toAdd.length, 0)
})

test("config: firstRun persist roundtrip", () => {
  assert.strictEqual(Config.snapshot().firstRunShown, false)
  Config.markFirstRunShown()
  const raw = Config.serializeUi()
  Config.reset()
  assert.strictEqual(Config.snapshot().firstRunShown, false)
  Config.loadUi(raw)
  assert.strictEqual(Config.snapshot().firstRunShown, true)
})

test("format: local preview never hands a raw pdf to Image", () => {
  const img = Format.localPreview("/tmp/a.png")
  assert.strictEqual(img.kind, "image")
  const pdf = Format.localPreview("/tmp/invoice.pdf")
  assert.strictEqual(pdf.kind, "pdf")
  assert.strictEqual(pdf.need_poppler, true)
  assert.ok(!pdf.path)
  assert.strictEqual(Format.isRasterPath("/cache/page.png"), true)
  assert.strictEqual(Format.isRasterPath("/docs/invoice.pdf"), false)
})

test("compat python rasterizes PDFs with resource limits", () => {
  const src = fs.readFileSync(path.join(ROOT, "compat/quicklookd.py"), "utf8")
  assert.ok(src.indexOf("pdftoppm") >= 0)
  assert.ok(src.indexOf("_limit_child") >= 0)
  assert.ok(src.indexOf("RLIMIT_AS") >= 0)
  assert.ok(src.indexOf("compat mode does not rasterize") < 0)
})

test("overlay uses documented IPC and does not launch a helper", () => {
  const qml = fs.readFileSync(path.join(ROOT, "Overlay.qml"), "utf8")
  assert.ok(qml.indexOf("HelperClient") < 0)
  assert.ok(qml.indexOf("firstPartyServiceFor") < 0)
  assert.ok(qml.indexOf("omarchy-shell") >= 0)
  assert.ok(qml.indexOf('"shell", "call"') < 0)
  assert.ok(qml.indexOf("io.github.chris.quicklook") >= 0)
  assert.ok(qml.indexOf("function query(arg)") >= 0)
  assert.ok(qml.indexOf("function preview(arg)") >= 0)
  assert.ok(qml.indexOf("function serviceRef()") >= 0)
  assert.ok(qml.indexOf("snapshot") >= 0)
  assert.ok(qml.indexOf("CtrlModifier") < 0 || !/Key_J.*ControlModifier/.test(qml))
  assert.ok(/root\.pinned && event\.key === Qt\.Key_J/.test(qml))
  const svc = fs.readFileSync(path.join(ROOT, "Service.qml"), "utf8")
  assert.ok(svc.indexOf("--plugin-dir") >= 0)
  assert.ok(/function status\(arg: string\)/.test(svc))
  assert.ok(/function snapshot\(arg: string\)/.test(svc))
  assert.ok(/function summon\(arg: string\)/.test(svc))
  assert.ok(svc.indexOf("shell.summon") < 0)
  assert.ok(svc.indexOf("helperLaunch") >= 0)
  const helperGone = !fs.existsSync(path.join(ROOT, "HelperClient.qml"))
  assert.ok(helperGone)
})

test("pdfinfo is isolated; posix timeout is mandatory; build.sh does not mask failures", () => {
  const preview = fs.readFileSync(path.join(ROOT, "src/quicklookd/src/preview.rs"), "utf8")
  assert.ok(preview.indexOf("pdfinfo_page_count") >= 0)
  assert.ok(preview.indexOf("run_limited") >= 0)
  assert.ok(!/Command::new\(info\)\.arg\(path\)\.output\(\)/.test(preview))
  const sh = fs.readFileSync(path.join(ROOT, "compat/quicklookd.sh"), "utf8")
  assert.ok(sh.indexOf("--kill-after") >= 0)
  assert.ok(sh.indexOf("watchdog_ok") >= 0)
  assert.ok(sh.indexOf("kill -KILL") >= 0)
  const build = fs.readFileSync(path.join(ROOT, "build.sh"), "utf8")
  assert.ok(build.indexOf("cargo build FAILED") >= 0)
  assert.ok(!/cp "\$ROOT\/compat\/quicklookd.sh" "\$OUT\/quicklookd"/.test(build))
})

test("no unbounded subprocesses on untrusted files; json escape; cache rejects empty", () => {
  const search = fs.readFileSync(path.join(ROOT, "src/quicklookd/src/search.rs"), "utf8")
  assert.ok(search.indexOf("run_limited") >= 0)
  assert.ok(!/\.output\(\)/.test(search))
  const preview = fs.readFileSync(path.join(ROOT, "src/quicklookd/src/preview.rs"), "utf8")
  assert.ok(preview.indexOf("usable_cache_file") >= 0)
  assert.ok(!/args\(\["-b"[\s\S]{0,80}\.output\(\)/.test(preview))
  assert.ok(preview.indexOf("with_path_lock") >= 0)
  const limits = fs.readFileSync(path.join(ROOT, "src/quicklookd/src/limits.rs"), "utf8")
  assert.ok(limits.indexOf("with_path_lock") >= 0)
  const sh = fs.readFileSync(path.join(ROOT, "compat/quicklookd.sh"), "utf8")
  assert.ok(sh.indexOf("--kill-after") >= 0)
  assert.ok(sh.indexOf("kill -KILL") >= 0)
  assert.ok(sh.indexOf("run_watchdog 8 gio open") >= 0)
  assert.ok(sh.indexOf("gio open \"$target\" >/dev/null 2>&1 &") < 0)
  assert.ok(sh.indexOf("perl -e") < 0)
  assert.ok(sh.indexOf("od -An -t u1") >= 0)
  const py = fs.readFileSync(path.join(ROOT, "compat/quicklookd.py"), "utf8")
  assert.ok(py.indexOf("run_killable") >= 0)
  assert.ok(py.indexOf("start_new_session") >= 0)
  assert.ok(!/subprocess\.Popen\(\[opener/.test(py))
  const bin = fs.readFileSync(path.join(ROOT, "bin/quicklook"), "utf8")
  assert.ok(bin.indexOf("od -An -t u1") >= 0)
})

test("TERM-ignoring fallback children are reaped by KILL", () => {
  const { spawnSync } = require("child_process")
  const r = spawnSync("sh", [path.join(ROOT, "tests/killable.test.sh")], {
    encoding: "utf8",
    timeout: 40000
  })
  if (r.status !== 0) {
    process.stderr.write(r.stdout || "")
    process.stderr.write(r.stderr || "")
  }
  assert.strictEqual(r.status, 0)
  // Both shell backends (host-default and forced-portable) and the Python
  // production branch must reap TERM-ignoring descendants, and flooding output
  // must stay bounded.
  assert.ok((r.stdout || "").indexOf("shell watchdog (host-default) KILL") >= 0)
  assert.ok((r.stdout || "").indexOf("shell watchdog (forced-portable) KILL") >= 0)
  assert.ok((r.stdout || "").indexOf("python process-group KILL") >= 0)
  assert.ok((r.stdout || "").indexOf("[limits=production]") >= 0)
  assert.ok((r.stdout || "").indexOf("flooding output bounded") >= 0)
})

test("manifest: id, kinds, entryPoints", () => {
  const man = JSON.parse(fs.readFileSync(path.join(ROOT, "manifest.json"), "utf8"))
  assert.strictEqual(man.schemaVersion, 1)
  assert.strictEqual(man.id, "io.github.chris.quicklook")
  assert.strictEqual(man.version, "1.0.0")
  assert.strictEqual(man.author, "chris")
  assert.strictEqual(man.license, "MIT")
  assert.deepStrictEqual(man.kinds, ["overlay", "service"])
  assert.strictEqual(man.entryPoints.overlay, "Overlay.qml")
  assert.strictEqual(man.entryPoints.service, "Service.qml")
  assert.strictEqual(man.keepLoaded, true)
  assert.ok(man.id.indexOf("omarchy.") < 0)
})

if (failed) {
  process.stderr.write("\n" + failed + " failed, " + passed + " passed\n")
  process.exit(1)
}
process.stdout.write("\n" + passed + " passed\n")
