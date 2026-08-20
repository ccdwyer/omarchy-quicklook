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
  const line = Config.privacySentence(snap.roots, "/home/chris")
  assert.ok(line.indexOf("Documents") >= 0)
  assert.ok(line.indexOf("500 MB") >= 0)
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
