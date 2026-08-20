import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "js/Binds.js" as Binds

BarWidget {
  id: root
  moduleName: "io.github.chris.quicklook"

  readonly property string pluginId: "io.github.chris.quicklook"
  property var shell: bar && bar.shell ? bar.shell : null
  property var manifest: null
  property var pluginRegistry: null

  property bool offerBinds: true
  property bool canSetHotkey: false
  property string offerNote: ""
  property string hotkeyLabel: ""
  property var workQueue: []
  property var workCurrent: null

  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    if (u.indexOf("file://") === 0)
      u = u.slice(7)
    if (u.length > 1 && u.charAt(u.length - 1) === "/")
      u = u.slice(0, u.length - 1)
    return u
  }

  readonly property string chipText: root.hotkeyLabel.length
                                     ? ("QuickLook  " + root.hotkeyLabel)
                                     : "QuickLook"
  readonly property string chipTooltip: {
    if (root.hotkeyLabel.length)
      return "QuickLook " + root.hotkeyLabel + " — click to open, Remove to drop the bind"
    if (root.offerNote.length)
      return "QuickLook — click to open. " + root.offerNote
    return "QuickLook — click to open. No hotkey yet — use Set hotkey"
  }

  function toggleOverlay() {
    if (root.shell && typeof root.shell.toggle === "function") {
      root.shell.toggle(root.pluginId, "{}")
      return
    }
    Quickshell.execDetached(["omarchy-shell", "shell", "toggle", root.pluginId, "{}"])
  }

  function applyBindPlan(plan) {
    var p = plan || Binds.offer
    root.offerBinds = !!p.needed
    root.canSetHotkey = !!p.canSet
    root.offerNote = String(p.note || "")
    root.hotkeyLabel = String(p.hotkeyLabel || "")
    Binds.setOffer(p)
  }

  function enqueueWork(command, done) {
    workQueue.push({ command: command, done: done || null })
    runWork()
  }

  function runWork() {
    if (workProc.running || root.workCurrent)
      return
    if (!workQueue.length)
      return
    root.workCurrent = workQueue.shift()
    workProc.command = root.workCurrent.command
    workProc.running = true
  }

  function scanBinds() {
    enqueueWork(["hyprctl", "-j", "binds"], function(text, code) {
      if (Number(code) !== 0)
        return
      root.applyBindPlan(Binds.applyScan(text))
    })
  }

  function notifyNewBinds(plan) {
    var body = Binds.notifyBody(plan.toAdd, plan.skipped)
    if (!body)
      return
    Quickshell.execDetached(Binds.notifyArgv("QuickLook", "QuickLook keybindings", body))
  }

  // Only the Set hotkey chip calls this. First load never writes bindings.lua.
  function installBinds() {
    enqueueWork(["hyprctl", "-j", "binds"], function(text, code) {
      if (Number(code) !== 0) {
        root.offerNote = "could not read keybinds"
        return
      }
      var plan = Binds.applyScan(text)
      if (!plan.toAdd || !plan.toAdd.length) {
        root.applyBindPlan(plan)
        return
      }
      var lua = Binds.luaBlock(plan.toAdd)
      enqueueWork(["python3", root.pluginDir + "/compat/install-binds.py", root.pluginId, lua], function(out, instCode) {
        if (Number(instCode) !== 0) {
          root.offerNote = "could not write ~/.config/hypr/bindings.lua"
          return
        }
        root.notifyNewBinds(plan)
        Qt.callLater(root.scanBinds)
      })
    })
  }

  function removeBinds() {
    enqueueWork(["python3", root.pluginDir + "/compat/install-binds.py", "--remove", root.pluginId], function(out, rmCode) {
      if (Number(rmCode) !== 0) {
        root.offerNote = "could not update ~/.config/hypr/bindings.lua"
        return
      }
      Qt.callLater(root.scanBinds)
    })
  }

  implicitWidth: row.implicitWidth
  implicitHeight: row.implicitHeight

  Row {
    id: row
    spacing: Style.space(4)

    WidgetButton {
      id: button
      bar: root.bar
      text: root.chipText
      tooltipText: root.chipTooltip
      onPressed: function(buttonCode) {
        if (buttonCode === Qt.LeftButton || buttonCode === Qt.RightButton)
          root.toggleOverlay()
      }
    }

    WidgetButton {
      visible: root.offerBinds && root.canSetHotkey
      bar: root.bar
      text: "Set hotkey"
      tooltipText: root.offerNote.length ? root.offerNote : "Write Super+. (or Super+Alt+.) to bindings.lua"
      onPressed: function(buttonCode) {
        if (buttonCode === Qt.LeftButton)
          root.installBinds()
      }
    }

    WidgetButton {
      visible: !root.offerBinds && root.hotkeyLabel.length > 0
      bar: root.bar
      text: "Remove"
      tooltipText: "Remove " + root.hotkeyLabel + " from bindings.lua"
      onPressed: function(buttonCode) {
        if (buttonCode === Qt.LeftButton)
          root.removeBinds()
      }
    }
  }

  Process {
    id: workProc
    running: false
    stdout: StdioCollector {
      id: workOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var text = workOut.text
      var job = root.workCurrent
      root.workCurrent = null
      if (job && job.done) {
        try {
          job.done(text, exitCode)
        } catch (e) {
          console.warn("quicklook: bar bind callback failed", e)
        }
      }
      root.runWork()
    }
  }

  Timer {
    interval: 3000
    repeat: true
    running: true
    onTriggered: root.scanBinds()
  }

  Component.onCompleted: Qt.callLater(root.scanBinds)
}
