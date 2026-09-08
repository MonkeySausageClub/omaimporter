import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "omaimporter"
  ipcTarget: "omaimporter"

  property string currentDir: ""
  property var breadcrumb: []
  property string destDir: ""
  property string renamePrefix: ""
  property string status: ""
  property string statusMessage: ""
  property bool picking: false

  readonly property color fg: bar ? bar.barForeground : Color.foreground
  readonly property color dim: Util.alpha(fg, 0.62)
  readonly property color bg: Color.popups.background

  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/omaimporter"

  function scriptPath(name) {
    return pluginDir + "/" + name
  }

  readonly property string mediaRoot: {
    var home = Quickshell.env("HOME")
    return "/run/media/" + (home.split("/").pop() || "")
  }

  property var mounts: []
  property var knownMountPaths: []
  property bool autoOpenPending: false

  readonly property bool isPrimaryMonitor: Screen.name === (Quickshell.screens[0] || {}).name

  ListModel {
    id: entriesModel
  }

  function selectedCount() {
    var n = 0
    for (var i = 0; i < entriesModel.count; i++)
      if (entriesModel.get(i).selected) n++
    return n
  }

  function selectedPaths() {
    var out = []
    for (var i = 0; i < entriesModel.count; i++)
      if (entriesModel.get(i).selected) out.push(entriesModel.get(i).path)
    return out
  }

  function openOverlay() {
    open()
    scanMounts()
  }

  function closeOverlay() {
    close()
    picking = false
    status = ""
    statusMessage = ""
  }

  function restoreOverlay() {
    picking = false
    open()
  }

  function scanMounts() {
    autoOpenPending = false
    mountsProc.running = true
  }

  function scanMountsForAutoOpen() {
    autoOpenPending = true
    mountsProc.running = true
  }

  Timer {
    id: mediaRootDebounce
    interval: 400
    onTriggered: root.scanMountsForAutoOpen()
  }

  FileView {
    path: root.mediaRoot
    watchChanges: true
    printErrors: false
    onFileChanged: mediaRootDebounce.restart()
  }

  function pathLabel(p) {
    if (!p) return ""
    var parts = String(p).split("/")
    return parts[parts.length - 1] || p
  }

  function clearModel() {
    entriesModel.clear()
  }

  function pushDir(p) {
    if (!p) return
    currentDir = p
    breadcrumb.push({ label: pathLabel(p), path: p })
    scanDir(p)
  }

  function up() {
    var parts = String(currentDir).split("/")
    parts.pop()
    var parent = parts.join("/")
    if (!parent || parent === "") return
    if (breadcrumb.length) breadcrumb.pop()
    currentDir = parent
    scanDir(parent)
  }

  function goRoot() {
    pushDir(mediaRoot)
  }

  function goBreadcrumb(index) {
    if (index < 0 || index >= breadcrumb.length) return
    var target = breadcrumb[index].path
    if (target === currentDir) return
    currentDir = target
    breadcrumb = breadcrumb.slice(0, index + 1)
    scanDir(target)
  }

  function goAddr(path) {
    var p = String(path === undefined ? addressField.text : path).replace(/^\s+|\s+$/g, "")
    if (!p) return
    pushDir(p)
  }

  function scanDir(p) {
    status = "scanning"
    statusMessage = ""
    entriesModel.clear()
    scanProc.command = [scriptPath("list-images.sh"), p]
    scanProc.running = true
  }

  function addScanRow(line) {
    if (!line) return
    var cols = line.split("\t")
    var p = cols[0]
    if (!p) return
    var ext = String(p).toLowerCase().split(".").pop()
    var isRaw = ["raw","cr2","cr3","crw","nef","nrw","arw","srw","orf","raf","rw2","pef","dng","3fr","dcr","kdc","mdc","mrw","mos","erf","iiq","fff","mef"].indexOf(ext) !== -1
    entriesModel.append({
      path: p,
      thumb: cols.length > 1 && cols[1] ? cols[1] : p,
      fileName: p.split("/").pop(),
      kind: isRaw ? "raw" : "jpeg",
      selected: false
    })
  }

  function toggleItem(index) {
    if (index < 0 || index >= entriesModel.count) return
    entriesModel.setProperty(index, "selected", !entriesModel.get(index).selected)
  }

  function toggleAll() {
    var all = selectedCount()
    var shouldSelect = all < entriesModel.count
    for (var i = 0; i < entriesModel.count; i++)
      entriesModel.setProperty(i, "selected", shouldSelect)
  }

  function clearSelection() {
    for (var i = 0; i < entriesModel.count; i++)
      entriesModel.setProperty(i, "selected", false)
  }

  function pickDestDir() {
    var title = "Choose destination folder"
    picking = true
    close()
    destProc.command = ["bash", "-c", "omarchy file select --directory --title " + Util.shellQuote(title)]
    destProc.running = true
  }

  function runImport() {
    if (!destDir || selectedCount() === 0) return
    var paths = selectedPaths()
    if (paths.length === 0) return
    status = "copying"
    statusMessage = ""
    copyProc.copiedCount = 0
    copyProc.errorCount = 0
    copyProc.command = [scriptPath("copy-files.sh"), destDir, renamePrefix].concat(paths)
    copyProc.running = true
  }

  Process {
    id: mountsProc
    command: ["bash", "-c", "ls -1 " + Util.shellQuote(root.mediaRoot) + " 2>/dev/null || true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var m = []
        for (var i = 0; i < lines.length; i++) {
          var l = lines[i]
          if (!l) continue
          m.push({ name: l, path: root.mediaRoot + "/" + l })
        }
        var previous = root.knownMountPaths
        root.knownMountPaths = []
        for (var k = 0; k < m.length; k++) root.knownMountPaths.push(m[k].path)

        if (root.picking) {
          root.autoOpenPending = false
          root.mounts = m
          return
        }

        if (root.autoOpenPending && root.isPrimaryMonitor) {
          root.autoOpenPending = false
          var fresh = []
          for (var a = 0; a < m.length; a++) if (previous.indexOf(m[a].path) === -1) fresh.push(m[a].path)
          if (fresh.length > 0) {
            var target = fresh[0]
            root.open()
            root.currentDir = ""
            root.breadcrumb = []
            root.status = ""
            root.statusMessage = ""
            root.pushDir(target)
            return
          }
        }

        root.mounts = m
        if (m.length > 0) {
          var auto = m[0].path
          var alreadyHere = false
          for (var j = 0; j < m.length; j++) {
            if (m[j].path === root.currentDir) { alreadyHere = true; break }
          }
          if (!alreadyHere) {
            root.currentDir = ""
            root.breadcrumb = []
            entriesModel.clear()
            root.pushDir(auto)
          }
        } else {
          root.currentDir = root.mediaRoot
          root.breadcrumb = []
          entriesModel.clear()
          root.status = "error"
          root.statusMessage = "No removable drives found under " + root.mediaRoot + ". Insert an SD card and try again."
        }
      }
    }
  }

  Process {
    id: scanProc
    stdout: SplitParser {
      onRead: function(line) {
        root.addScanRow(String(line))
      }
    }
    onExited: {
      if (root.status === "scanning") {
        root.status = entriesModel.count === 0 ? "error" : ""
        root.statusMessage = entriesModel.count === 0 ? "No supported image files here" : ""
      }
    }
  }

  Process {
    id: destProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var p = String(text || "").replace(/^\s+|\s+$/g, "")
        if (p) root.destDir = p
        if (root.picking) root.restoreOverlay()
      }
    }
  }

  Process {
    id: copyProc
    property int copiedCount: 0
    property int errorCount: 0
    stdout: SplitParser {
      onRead: function(line) {
        var cols = String(line).split("\t")
        if (cols[0] === "copied") copyProc.copiedCount++
        else if (cols[0] === "error") copyProc.errorCount++
      }
    }
    onExited: {
      root.status = "done"
      var c = copyProc.copiedCount
      var e = copyProc.errorCount
      root.statusMessage = "Copied " + c + " file" + (c === 1 ? "" : "s")
        + (e > 0 ? " · " + e + " failed" : "")
        + " to " + root.destDir
    }
  }

  // ------------------------------------------------------------------ UI --

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    bar: root.bar
    text: "\u{F02CA}"
    useActiveColor: true
    tooltipText: "omaImporter"

    onPressed: root.toggle()
  }

  Text {
    anchors.centerIn: button
    anchors.horizontalCenterOffset: Style.space(10)
    anchors.verticalCenterOffset: -Style.space(10)
    text: root.selectedCount() > 0 ? String(root.selectedCount()) : ""
    visible: root.selectedCount() > 0
    color: Color.accent
    font.family: bar ? bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    font.italic: root.opened
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(1040))
    contentHeight: panel.fittedContentHeight(Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: addressField.activeFocus
      onCloseRequested: root.closeOverlay()

      // Card
      Rectangle {
        id: card
        anchors.fill: parent
        radius: Style.cornerRadius
        color: root.bg
        border.width: 1
        border.color: Color.popups.border

        MouseArea { anchors.fill: parent }

        Item {
          id: layout
          anchors.fill: parent
          anchors.margins: Style.space(14)

          // ---------- fixed header ----------
          Column {
            id: header
            width: parent.width
            spacing: Style.space(10)

            Text {
              text: "omaImporter"
              color: root.fg
              font.family: bar ? bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              text: "Preview files on the card, then copy the ones you pick. Sources are never modified. Optionally set a name to rename files as they copy (Name_001, Name_002, \u2026)."
              color: root.dim
              font.family: bar ? bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }

            Row {
              width: parent.width
              spacing: Style.space(6)
              visible: root.mounts.length > 0
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Drive:"
                color: root.dim
                font.family: bar ? bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
              Repeater {
                model: root.mounts
                Button {
                  required property var modelData
                  text: String(modelData.name)
                  fontFamily: bar ? bar.fontFamily : Style.font.family
                  fontSize: Style.font.caption
                  selected: String(modelData.path) === root.currentDir
                  onClicked: root.pushDir(String(modelData.path))
                }
              }
              Button {
                text: "Refresh"
                fontFamily: bar ? bar.fontFamily : Style.font.family
                fontSize: Style.font.caption
                onClicked: root.scanMounts()
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(6)
              Button {
                text: "Home"
                fontFamily: bar ? bar.fontFamily : Style.font.family
                fontSize: Style.font.caption
                onClicked: root.goRoot()
              }
              Button {
                text: "\u2191 Up"
                fontFamily: bar ? bar.fontFamily : Style.font.family
                fontSize: Style.font.caption
                onClicked: root.up()
              }
              Repeater {
                model: root.breadcrumb
                Button {
                  required property var modelData
                  text: String(modelData.label)
                  fontFamily: bar ? bar.fontFamily : Style.font.family
                  fontSize: Style.font.caption
                  selected: String(modelData.path) === root.currentDir
                  onClicked: root.goBreadcrumb(index)
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(6)
              Rectangle {
                width: parent.width - Style.space(140) - Style.space(6) * 3
                height: Style.space(28)
                radius: Style.cornerRadius > 0 ? height / 4 : 0
                color: Util.alpha(root.fg, 0.06)
                border.width: 1
                border.color: Util.alpha(root.fg, 0.22)
                TextInput {
                  id: addressField
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  verticalAlignment: TextInput.AlignVCenter
                  color: root.fg
                  selectionColor: Color.accent
                  selectedTextColor: Color.background
                  font.family: bar ? bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  text: root.currentDir
                  onAccepted: root.goAddr()
                }
              }
              Button {
                id: goButton
                width: Style.space(140)
                text: "Go"
                fontFamily: bar ? bar.fontFamily : Style.font.family
                fontSize: Style.font.caption
                bordered: false
                onClicked: root.goAddr()
              }
            }

            Row {
              id: destRow
              width: parent.width
              spacing: Style.space(6)
              Text {
                id: destLabel
                anchors.verticalCenter: parent.verticalCenter
                text: "Copy to:"
                color: root.dim
                font.family: bar ? bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
              Rectangle {
                width: destRow.width - destLabel.width - destPick.width - destCur.width - destSel.width - Style.space(6) * 6
                height: Style.space(28)
                radius: Style.cornerRadius > 0 ? height / 4 : 0
                color: Util.alpha(root.fg, 0.06)
                border.width: 1
                border.color: root.destDir ? Util.alpha(root.fg, 0.22) : Color.urgent
                TextInput {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  verticalAlignment: TextInput.AlignVCenter
                  color: root.fg
                  selectionColor: Color.accent
                  selectedTextColor: Color.background
                  font.family: bar ? bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  text: root.destDir
                  onTextChanged: root.destDir = text
                }
              }
              Button {
                id: destPick
                text: "Pick\u2026"
                fontFamily: bar ? bar.fontFamily : Style.font.family
                fontSize: Style.font.caption
                onClicked: root.pickDestDir()
              }
              Button {
                id: destCur
                text: "Use current"
                fontFamily: bar ? bar.fontFamily : Style.font.family
                fontSize: Style.font.caption
                onClicked: root.destDir = root.currentDir
              }
              Button {
                id: destSel
                text: "Import selected \u2192"
                fontFamily: bar ? bar.fontFamily : Style.font.family
                fontSize: Style.font.body
                foreground: Color.background
                background: root.destDir && root.selectedCount() > 0
                  ? Color.accent
                  : Util.alpha(root.fg, 0.25)
                enabled: root.destDir && root.selectedCount() > 0 && root.status !== "copying"
                onClicked: root.runImport()
              }
            }

            Row {
              id: renameRow
              width: parent.width
              spacing: Style.space(6)
              Text {
                id: renameLabel
                anchors.verticalCenter: parent.verticalCenter
                text: "Rename:"
                color: root.dim
                font.family: bar ? bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
              Rectangle {
                width: renameRow.width - Style.space(360)
                height: Style.space(28)
                radius: Style.cornerRadius > 0 ? height / 4 : 0
                color: Util.alpha(root.fg, 0.06)
                border.width: 1
                border.color: Util.alpha(root.fg, 0.22)
                TextInput {
                  id: renameField
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  verticalAlignment: TextInput.AlignVCenter
                  color: root.fg
                  selectionColor: Color.accent
                  selectedTextColor: Color.background
                  font.family: bar ? bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  text: root.renamePrefix
                  onTextChanged: root.renamePrefix = text
                  onActiveFocusChanged: if (activeFocus) selectAll()
                }
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  visible: root.renamePrefix === ""
                  text: "e.g. Danny Birthday Party"
                  color: root.dim
                  font.family: bar ? bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.renamePrefix
                  ? String(root.renamePrefix) + "_001.jpg \u2026"
                  : "Leave blank to keep original names"
                color: root.dim
                font.family: bar ? bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: Style.space(220)
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(10)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.selectedCount() + " selected"
                color: root.selectedCount() > 0 ? root.fg : root.dim
                font.family: bar ? bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: root.selectedCount() > 0
              }
              Button {
                text: "Select all"
                fontFamily: bar ? bar.fontFamily : Style.font.family
                fontSize: Style.font.caption
                onClicked: root.toggleAll()
              }
              Button {
                text: "Clear"
                fontFamily: bar ? bar.fontFamily : Style.font.family
                fontSize: Style.font.caption
                onClicked: root.clearSelection()
              }
              Item { width: Style.space(8); height: 1 }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.status === "scanning" ? "Scanning\u2026"
                    : root.status === "copying" ? "Copying\u2026"
                    : root.statusMessage
                color: root.status === "error" ? Color.urgent
                    : root.status === "done" ? Color.accent
                    : root.dim
                font.family: bar ? bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                visible: root.status !== "" && root.status !== "scanning" && root.status !== "copying"
                width: parent.width - Style.space(220)
                elide: Text.ElideMiddle
              }
            }
          }

          // ---------- thumbnail grid fills the rest ----------
          Rectangle {
            id: gridHost
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: header.bottom
            anchors.topMargin: Style.space(12)
            anchors.bottom: parent.bottom
            radius: Style.cornerRadius > 0 ? Style.space(6) : 0
            color: Util.alpha(root.fg, 0.03)
            border.width: 1
            border.color: Util.alpha(root.fg, 0.08)

            Flickable {
              id: flick
              anchors.fill: parent
              anchors.margins: Style.space(8)
              clip: true
              contentWidth: grid.width
              contentHeight: grid.height
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              Grid {
                id: grid
                width: flick.width
                columns: 5
                columnSpacing: Style.space(8)
                rowSpacing: Style.space(8)

                Repeater {
                  model: entriesModel

                  Item {
                    id: cell
                    required property int index

                    readonly property var cellData: entriesModel.get(index)
                    readonly property bool selected: cellData ? cellData.selected : false
                    readonly property string thumbPath: cellData ? String(cellData.thumb || "") : ""
                    readonly property string fileName: cellData ? String(cellData.fileName || "") : ""
                    readonly property bool isRaw: cellData ? String(cellData.kind || "") === "raw" : false

                    width: (grid.width - grid.columnSpacing * (grid.columns - 1)) / grid.columns
                    height: width + Style.space(22)

                    Rectangle {
                      anchors.fill: parent
                      radius: Style.space(4)
                      color: cell.selected ? Util.alpha(Color.accent, 0.16) : Util.alpha(root.fg, 0.04)
                      border.width: cell.selected ? 2 : 1
                      border.color: cell.selected ? Color.accent : Util.alpha(root.fg, 0.14)

                      Column {
                        anchors.fill: parent
                        anchors.margins: Style.space(3)
                        spacing: Style.space(3)

                        Image {
                          width: parent.width
                          height: cell.width - Style.space(4)
                          fillMode: Image.PreserveAspectCrop
                          source: cell.thumbPath ? Util.fileUrl(cell.thumbPath) : ""
                          asynchronous: true
                          smooth: true
                          clip: true
                        }

                        Row {
                          width: parent.width
                          spacing: Style.space(3)
                          Text {
                            text: cell.isRaw ? "RAW" : "JPG"
                            color: cell.isRaw ? Color.urgent : root.dim
                            font.family: bar ? bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            width: Style.space(28)
                          }
                          Text {
                            width: parent.width - Style.space(28)
                            text: cell.fileName
                            color: root.fg
                            font.family: bar ? bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideMiddle
                          }
                        }
                      }

                      Rectangle {
                        anchors.top: parent.top
                        anchors.left: parent.left
                        width: Style.space(18)
                        height: Style.space(18)
                        radius: Style.space(9)
                        color: cell.selected ? Color.accent : Util.alpha(root.fg, 0.18)
                        border.width: 1
                        border.color: Util.alpha(root.fg, 0.4)
                        Text {
                          anchors.centerIn: parent
                          text: "\u2713"
                          visible: cell.selected
                          color: Color.background
                          font.family: bar ? bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.caption
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleItem(index)
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  Component.onCompleted: scanMounts()
}
