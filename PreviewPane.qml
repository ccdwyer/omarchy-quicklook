import QtQuick
import qs.Commons
import qs.Ui
import "js/Format.js" as Format
import "js/Theme.js" as Theme

Item {
  id: root

  property var preview: ({})
  property string emptyReason: ""
  property string emptyDetail: ""
  property bool loading: false
  property var palette: Theme.defaultPalette()
  property color foreground: "#c0caf5"
  property color accent: "#7aa2f7"
  property string fontFamily: "sans-serif"
  property string monoFamily: "monospace"
  property int pinPage: 1

  readonly property string kind: String(preview && preview.kind ? preview.kind : "")
  readonly property bool needPoppler: preview && preview.need_poppler === true
  readonly property bool renderError: preview && preview.render_error === true
  readonly property bool pdfRaster: {
    if (root.kind !== "pdf" || root.needPoppler || root.renderError)
      return false
    if (!preview || !preview.path)
      return false
    return Format.isRasterPath(preview.path)
  }
  readonly property bool largeFile: preview && (preview.large === true || preview.capped === true)

  function cellText(row, col) {
    if (!preview || !preview.rows || col >= preview.rows[row].length)
      return ""
    return String(preview.rows[row][col] || "")
  }

  Rectangle {
    anchors.fill: parent
    color: "transparent"

    // loading
    Column {
      anchors.centerIn: parent
      spacing: Style.space(8)
      visible: root.loading && root.kind === ""
      Text {
        text: "rendering…"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        opacity: 0.7
      }
    }

    // designed empty states
    Column {
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(40), Style.space(420))
      spacing: Style.space(10)
      visible: !root.loading && root.kind === "" && root.emptyReason.length > 0

      Text {
        width: parent.width
        text: root.emptyReason
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
      }
      Text {
        width: parent.width
        text: root.emptyDetail
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
      }
    }

    // image / pdf raster / video poster
    Item {
      anchors.fill: parent
      visible: (root.kind === "image" || root.pdfRaster) && !root.loading

      Canvas {
        id: checker
        anchors.fill: parent
        visible: root.kind === "image"
        onPaint: {
          var ctx = getContext("2d")
          var s = 14
          var a = root.palette.checkerA || "#2a2a2a"
          var b = root.palette.checkerB || "#3a3a3a"
          for (var y = 0; y < height; y += s) {
            for (var x = 0; x < width; x += s) {
              ctx.fillStyle = ((x / s + y / s) % 2 === 0) ? a : b
              ctx.fillRect(x, y, s, s)
            }
          }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
      }

      Rectangle {
        id: pdfShadow
        visible: root.pdfRaster
        anchors.centerIn: parent
        width: raster.paintedWidth + 8
        height: raster.paintedHeight + 8
        color: "#66000000"
        radius: 4
      }

      AnimatedImage {
        id: anim
        anchors.fill: parent
        anchors.margins: Style.space(12)
        visible: root.kind === "image" && preview.animated === true
        source: preview.path ? Format.fileUrl(preview.path) : ""
        fillMode: Image.PreserveAspectFit
        playing: visible
        asynchronous: true
      }

      Image {
        id: raster
        anchors.fill: parent
        anchors.margins: Style.space(12)
        visible: !anim.visible
        source: preview.path ? Format.fileUrl(preview.path) : ""
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: false
        smooth: true
      }

      Text {
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: Style.space(8)
        visible: root.pdfRaster && preview.page_count
        text: "page " + (preview.page || 1) + " / " + preview.page_count + "   j/k to turn"
        color: root.foreground
        opacity: 0.65
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // poppler missing / render error
    Column {
      anchors.centerIn: parent
      width: parent.width - Style.space(48)
      spacing: Style.space(10)
      visible: root.kind === "pdf" && (root.needPoppler || root.renderError) && !root.pdfRaster

      Text {
        width: parent.width
        text: root.needPoppler ? "install poppler for PDF previews" : (preview.label || "couldn't render this page")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
      }
      Text {
        width: parent.width
        text: root.needPoppler
              ? "pacman -S poppler  ·  then rescan plugins. The file is still openable with Enter."
              : "Enter still opens the file in the default app."
        color: root.foreground
        opacity: 0.6
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        width: parent.width
        visible: !!preview.hex
        text: preview.hex || ""
        color: root.foreground
        opacity: 0.7
        wrapMode: Text.NoWrap
        font.family: root.monoFamily
        font.pixelSize: Style.font.caption
      }
    }

    // code / text
    Flickable {
      id: codeFlick
      anchors.fill: parent
      anchors.margins: Style.space(14)
      visible: root.kind === "code"
      clip: true
      contentWidth: codeText.implicitWidth
      contentHeight: codeText.implicitHeight
      boundsBehavior: Flickable.StopAtBounds

      Text {
        id: codeText
        text: preview.html || ""
        textFormat: Text.RichText
        color: root.foreground
        font.family: root.monoFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.NoWrap
      }
    }

    Text {
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.space(10)
      visible: root.kind === "code" && root.largeFile
      text: "large file"
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // csv table
    Column {
      anchors.fill: parent
      anchors.margins: Style.space(10)
      spacing: 0
      visible: root.kind === "csv"
      clip: true

      Row {
        width: parent.width
        height: Style.space(28)
        Repeater {
          model: preview.headers || []
          delegate: Rectangle {
            width: Math.max(80, (parent.width / Math.max(1, (preview.headers || []).length)))
            height: parent.height
            color: root.palette.surface || "transparent"
            Text {
              anchors.fill: parent
              anchors.margins: 6
              text: String(modelData || "")
              textFormat: Text.PlainText
              color: root.accent
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
        }
      }

      ListView {
        width: parent.width
        height: parent.height - Style.space(28)
        clip: true
        model: preview.rows || []
        boundsBehavior: Flickable.StopAtBounds
        delegate: Rectangle {
          required property int index
          required property var modelData
          property var row: modelData
          width: ListView.view ? ListView.view.width : 100
          height: Style.space(26)
          color: index % 2 === 0 ? (root.palette.zebra || "transparent") : (root.palette.zebraAlt || "transparent")
          Row {
            anchors.fill: parent
            Repeater {
              model: preview.headers ? preview.headers.length : 0
              delegate: Text {
                required property int index
                width: Math.max(80, parent.width / Math.max(1, (preview.headers || []).length))
                height: parent.height
                text: (row && index < row.length) ? String(row[index]) : ""
                textFormat: Text.PlainText
                color: root.foreground
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
                leftPadding: 6
                font.family: root.monoFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      Text {
        visible: preview.truncated === true
        text: "first 500 rows"
        color: root.foreground
        opacity: 0.5
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // directory
    ListView {
      anchors.fill: parent
      anchors.margins: Style.space(12)
      visible: root.kind === "dir"
      clip: true
      model: preview.entries || []
      header: Text {
        width: parent.width
        text: "folder · " + Format.humanSize(preview.total_size || 0) + (preview.truncated ? " (partial)" : "")
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        padding: 6
      }
      delegate: Row {
        required property var modelData
        width: parent ? parent.width : 100
        height: Style.space(24)
        spacing: Style.space(8)
        Text {
          text: Format.glyphFor(modelData.kind)
          color: root.accent
          width: Style.space(18)
          font.family: root.fontFamily
        }
        Text {
          text: modelData.name
          textFormat: Text.PlainText
          color: root.foreground
          width: parent.width - Style.space(100)
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          text: modelData.kind === "dir" ? "" : Format.humanSize(modelData.size)
          color: root.foreground
          opacity: 0.5
          font.family: root.monoFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // hex / unknown
    Flickable {
      anchors.fill: parent
      anchors.margins: Style.space(14)
      visible: root.kind === "hex" || root.kind === "video"
      clip: true
      contentWidth: hexCol.implicitWidth
      contentHeight: hexCol.implicitHeight

      Column {
        id: hexCol
        spacing: Style.space(8)
        Text {
          text: preview.label || (root.kind === "video" ? "video metadata only" : "can't render this — hex view")
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          text: preview.magic || ""
          color: root.foreground
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          text: preview.hex || ""
          color: root.foreground
          font.family: root.monoFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
