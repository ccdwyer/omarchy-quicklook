import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "js/Config.js" as Config
import "js/Theme.js" as Theme
import "js/Format.js" as Format
import "js/Binds.js" as Binds

Item {
  id: root

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var pluginSettings: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || ""
  property var roots: []
  property int watchCap: 2000
  property int cacheMb: 500
  property int maxFiles: 500000
  property var extraExclude: []
  property bool opened: false
  property bool pinned: false
  property bool firstRun: false
  property bool showInfo: false
  property bool bindCollision: false
  property string pluginId: "io.github.chris.quicklook"
  property string queryText: ""
  property int selectedIndex: 0
  property var results: []
  property var preview: ({})
  property bool previewLoading: false
  property string emptyReason: ""
  property string emptyDetail: ""
  property int lastQueryRev: 0
  property int lastPreviewRev: 0
  property int pdfPage: 1
  property string directPath: ""

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color accent: Color.accent
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property string monoFamily: {
    try {
      if (Style.font.monoFamily)
        return Style.font.monoFamily
    } catch (e) {}
    try {
      if (Style.font.mono)
        return Style.font.mono
    } catch (e2) {}
    return "monospace"
  }

  readonly property bool reduceMotion: {
    try {
      if (Style && Style.reduceMotion)
        return true
    } catch (e) {}
    try {
      if (Quickshell.env("OMARCHY_REDUCED_MOTION") === "1")
        return true
    } catch (e2) {}
    return false
  }
  readonly property int motionMs: reduceMotion ? 0 : 150

  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    if (u.indexOf("file://") === 0)
      u = u.slice(7)
    if (u.length > 1 && u.charAt(u.length - 1) === "/")
      u = u.slice(0, u.length - 1)
    return u
  }

  readonly property var palette: Theme.paletteFromTokens(background, foreground, accent, background)
  readonly property string privacyLine: {
    var snap = Config.snapshot()
    return Config.privacySentence(snap.roots, Quickshell.env("HOME") || "~", snap.cacheMb)
  }

  function open(payloadJson) {
    root.opened = true
    root.pinned = false
    root.showInfo = false
    root.pdfPage = 1
    root.directPath = ""
    root.firstRun = !Config.current.firstRunShown
    root.pushTheme()
    var payload = {}
    try {
      payload = payloadJson && String(payloadJson).length ? JSON.parse(payloadJson) : {}
    } catch (e) {
      payload = {}
    }
    if (payload && payload.firstRun)
      root.firstRun = true
    if (payload && payload.path) {
      root.directPath = String(payload.path)
      root.queryText = Format.basename(root.directPath)
      searchField.text = root.queryText
      root.results = [{
        path: root.directPath,
        name: Format.basename(root.directPath),
        kind: Format.kindOf(root.directPath, false),
        score: 1000,
        mtime: 0,
        size: 0
      }]
      root.selectedIndex = 0
      root.requestPreview(root.directPath, 1)
    } else if (payload && payload.q) {
      root.queryText = String(payload.q)
      searchField.text = root.queryText
      debounce.restart()
    } else {
      root.queryText = ""
      searchField.text = ""
      root.requestQuery("")
    }
    Qt.callLater(function() { searchField.forceActiveFocus() })
    bindCheck.running = true
  }

  function close() {
    root.opened = false
    root.pinned = false
  }

  function toggle() {
    if (root.opened)
      root.close()
    else
      root.open("{}")
  }

  HelperClient {
    id: helper
    pluginDir: root.pluginDir
    home: Quickshell.env("HOME") || "/tmp"
    pluginSettings: root.pluginSettings
    roots: root.roots
    watchCap: root.watchCap
    cacheMb: root.cacheMb
    maxFiles: root.maxFiles
    extraExclude: root.extraExclude
  }

  function pushTheme() {
    helper.setTheme(root.palette)
  }

  function requestQuery(q) {
    helper.query(q)
  }

  function requestPreview(path, page) {
    root.previewLoading = true
    root.pdfPage = page || 1
    helper.preview(path, root.pdfPage)
  }

  function requestPrefetch(path) {
    helper.prefetch(path)
  }

  function currentHit() {
    if (!root.results || root.selectedIndex < 0 || root.selectedIndex >= root.results.length)
      return null
    return root.results[root.selectedIndex]
  }

  function selectIndex(i) {
    if (!root.results.length)
      return
    var n = i
    if (n < 0)
      n = 0
    if (n >= root.results.length)
      n = root.results.length - 1
    if (n === root.selectedIndex && root.preview && root.preview.path)
      return
    root.selectedIndex = n
    var hit = root.results[n]
    root.requestPreview(hit.path, 1)
  }

  function openCurrent() {
    var hit = root.currentHit()
    if (!hit)
      return
    helper.openPath(hit.path)
    root.close()
  }

  function revealCurrent() {
    var hit = root.currentHit()
    if (!hit)
      return
    helper.reveal(hit.path)
  }

  function pinToggle() {
    if (!root.currentHit())
      return
    root.pinned = !root.pinned
    if (!root.pinned)
      Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function turnPage(delta) {
    var hit = root.currentHit()
    if (!hit || hit.kind !== "pdf")
      return
    var count = Number(root.preview.page_count) || 1
    var next = root.pdfPage + delta
    if (next < 1)
      next = 1
    if (next > count)
      next = count
    if (next === root.pdfPage)
      return
    root.requestPreview(hit.path, next)
  }

  function dismissFirstRun() {
    Config.markFirstRunShown()
    root.firstRun = false
    helper.markFirstRun()
  }

  function setEmpty(reason, detail) {
    root.emptyReason = reason
    root.emptyDetail = detail || ""
    root.preview = ({})
    root.previewLoading = false
  }

  function pullService() {
    if (helper.resultsRevision !== root.lastQueryRev) {
      root.lastQueryRev = helper.resultsRevision
      var list = helper.lastResults || []
      root.results = list
      if (!list.length) {
        if (root.queryText.length)
          root.setEmpty("no matches", "The index will keep warming; try a shorter query.")
        else
          root.setEmpty("no matches", "")
      } else {
        root.emptyReason = ""
        if (root.selectedIndex >= list.length)
          root.selectedIndex = 0
        var hit = list[root.selectedIndex] || list[0]
        if (hit)
          root.requestPreview(hit.path, 1)
        var top = list[0]
        if (top && hit && top.path !== hit.path)
          root.requestPrefetch(top.path)
      }
    }
    if (helper.previewRevision !== root.lastPreviewRev) {
      root.lastPreviewRev = helper.previewRevision
      root.preview = helper.lastPreview || {}
      root.previewLoading = false
      if (root.preview && root.preview.page)
        root.pdfPage = Number(root.preview.page) || 1
    }
  }

  function escapeOut() {
    if (root.firstRun) {
      root.dismissFirstRun()
      return
    }
    if (root.showInfo) {
      root.showInfo = false
      return
    }
    if (root.pinned) {
      root.pinned = false
      return
    }
    root.close()
  }

  function indexingCaption() {
    if (helper.indexing) {
      var pct = Math.round((Number(helper.indexProgress) || 0) * 100)
      return "indexing… " + pct + "%"
    }
    if (helper.backend)
      return String(helper.backend)
    return ""
  }

  Process {
    id: bindCheck
    running: false
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.bindCollision = Binds.superPeriodBound(text)
      }
    }
  }

  Timer {
    interval: root.opened ? 80 : 400
    running: root.opened
    repeat: true
    onTriggered: root.pullService()
  }

  Timer {
    id: debounce
    interval: 30
    repeat: false
    onTriggered: {
      root.selectedIndex = 0
      root.requestQuery(root.queryText)
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "quicklook"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      opacity: root.opened ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: root.motionMs } }
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.escapeOut()
    }

    // finder chrome
    BorderSurface {
      id: frame
      visible: !root.pinned
      width: Math.min(Style.space(1120), panel.width - Style.gapsOut * 2)
      height: Math.min(Style.space(680), panel.height - Style.gapsOut * 2)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      opacity: root.opened && !root.pinned ? 1 : 0
      scale: root.opened && !root.pinned ? 1 : 0.98
      Behavior on opacity { NumberAnimation { duration: root.motionMs } }
      Behavior on scale { NumberAnimation { duration: root.motionMs } }

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        spacing: Style.spacing.md

        Row {
          width: parent.width
          spacing: Style.space(12)

          Text {
            text: "QuickLook"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: root.indexingCaption()
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }

          Item { width: 1; height: 1 }

          Text {
            text: "?"
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
            MouseArea {
              anchors.fill: parent
              anchors.margins: -6
              cursorShape: Qt.PointingHandCursor
              onClicked: root.showInfo = !root.showInfo
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Style.space(40)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor ? Style.normalFillFor(root.foreground, root.accent) : "transparent"
          border.color: searchField.activeFocus ? root.accent : root.border
          border.width: 1

          TextInput {
            id: searchField
            anchors.fill: parent
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            verticalAlignment: Text.AlignVCenter
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            selectionColor: root.accent
            selectedTextColor: root.selectedText
            clip: true
            focus: true
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.escapeOut()
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                root.selectIndex(root.selectedIndex + 1)
                event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                root.selectIndex(root.selectedIndex - 1)
                event.accepted = true
              } else if (event.key === Qt.Key_Space) {
                root.pinToggle()
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (event.modifiers & Qt.ControlModifier)
                  root.revealCurrent()
                else
                  root.openCurrent()
                event.accepted = true
              } else if (event.key === Qt.Key_Question) {
                root.showInfo = !root.showInfo
                event.accepted = true
              } else if (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier)) {
                root.turnPage(1)
                event.accepted = true
              } else if (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier)) {
                root.turnPage(-1)
                event.accepted = true
              }
            }
            onTextChanged: {
              root.queryText = text
              debounce.restart()
            }
          }
        }

        Row {
          width: parent.width
          height: parent.height - Style.space(120)
          spacing: Style.space(12)

          ListView {
            id: results
            width: Math.min(Style.space(340), parent.width * 0.36)
            height: parent.height
            clip: true
            model: root.results
            currentIndex: root.selectedIndex
            boundsBehavior: Flickable.StopAtBounds
            highlightMoveDuration: root.motionMs
            delegate: Rectangle {
              required property int index
              required property var modelData
              width: ListView.view.width
              height: Style.space(44)
              radius: Style.spacing.labelGap
              color: index === root.selectedIndex
                     ? (Style.selectedFillFor ? Style.selectedFillFor(root.foreground, root.accent) : root.selectedBackground)
                     : "transparent"
              Row {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(8)
                Text {
                  text: Format.glyphFor(modelData.kind)
                  color: index === root.selectedIndex ? root.selectedText : root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  width: Style.space(18)
                  anchors.verticalCenter: parent.verticalCenter
                }
                Column {
                  width: parent.width - Style.space(26)
                  anchors.verticalCenter: parent.verticalCenter
                  Text {
                    width: parent.width
                    text: modelData.name
                    color: index === root.selectedIndex ? root.selectedText : root.foreground
                    elide: Text.ElideMiddle
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: index === root.selectedIndex
                  }
                  Text {
                    width: parent.width
                    text: Format.dirname(modelData.path)
                    color: index === root.selectedIndex ? root.selectedText : root.foreground
                    opacity: 0.55
                    elide: Text.ElideMiddle
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
              MouseArea {
                anchors.fill: parent
                onClicked: root.selectIndex(index)
                onDoubleClicked: root.openCurrent()
              }
            }

            Text {
              anchors.centerIn: parent
              visible: root.results.length === 0
              text: root.queryText.length ? "no matches" : "type to search"
              color: root.foreground
              opacity: 0.45
              font.family: root.fontFamily
            }
          }

          PreviewPane {
            width: parent.width - results.width - Style.space(12)
            height: parent.height
            preview: root.preview
            loading: root.previewLoading
            emptyReason: root.emptyReason
            emptyDetail: root.emptyDetail
            palette: root.palette
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            monoFamily: root.monoFamily
            pinPage: root.pdfPage
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(16)
          Text {
            text: "↑↓ navigate  ·  Space pin  ·  Enter open  ·  Ctrl+Enter reveal  ·  Esc close"
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    // pinned fullscreen preview
    Item {
      anchors.fill: parent
      visible: root.pinned
      focus: root.pinned

      MouseArea {
        anchors.fill: parent
        onClicked: {}
      }

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.escapeOut()
          event.accepted = true
        } else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
          root.turnPage(1)
          event.accepted = true
        } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
          root.turnPage(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Space) {
          root.pinToggle()
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.openCurrent()
          event.accepted = true
        }
      }

      PreviewPane {
        anchors.fill: parent
        anchors.margins: Style.space(24)
        preview: root.preview
        loading: root.previewLoading
        emptyReason: root.emptyReason
        emptyDetail: root.emptyDetail
        palette: root.palette
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        monoFamily: root.monoFamily
        pinPage: root.pdfPage
      }
    }

    // first-run + info card
    BorderSurface {
      visible: root.opened && (root.firstRun || root.showInfo) && !root.pinned
      width: Math.min(Style.space(560), panel.width - Style.gapsOut * 2)
      height: infoCol.implicitHeight + Style.spacing.panelPadding * 2
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.gapsOut + Style.space(24)
      color: root.background
      borderSpec: root.borderSpec
      z: 20

      Column {
        id: infoCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.spacing.panelPadding
        spacing: Style.space(10)

        Text {
          text: root.firstRun ? "QuickLook is local" : "Indexed roots"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Text {
          width: parent.width
          text: root.privacyLine
          color: root.foreground
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          visible: root.bindCollision
          text: "SUPER+. looks already bound. Use SUPER+SHIFT+P (snippet in bindings.lua / README)."
          color: root.accent
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          visible: !root.bindCollision
          text: "Default hotkey SUPER+.  ·  alternate SUPER+SHIFT+P  ·  the plugin does not write Hyprland config."
          color: root.foreground
          opacity: 0.7
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          text: {
            var caps = helper.lastCaps || {}
            var roots = (caps.roots && caps.roots.length) ? caps.roots.join(", ") : (Quickshell.env("HOME") || "~")
            var watches = (caps.watchCount || 0) + " / " + (caps.watchCap || 2000)
            var cache = Format.humanSize(caps.cacheBytes || 0) + " / " + Format.humanSize(caps.cacheBudget || 524288000)
            return "roots  " + roots + "\nwatches  " + watches + "   (raise fs.inotify.max_user_watches if a future inotify build needs it)\ncache  " + cache + "\npoppler  " + (caps.poppler ? "yes" : "no") + "   plocate  " + (caps.plocate ? "yes" : "no") + "   helper  " + (caps.helper || helper.helperCmd || "—")
          }
          color: root.foreground
          wrapMode: Text.WordWrap
          font.family: root.monoFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          text: "Enter / click to dismiss"
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      MouseArea {
        anchors.fill: parent
        onClicked: {
          root.dismissFirstRun()
          root.showInfo = false
        }
      }
    }
  }
}
