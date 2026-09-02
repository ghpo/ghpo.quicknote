import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property string home: Quickshell.env("HOME")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string note: ""
  property string notesDir: "~/Documents/QuickNotes"
  property string fontFamily: Style.font.menuFamily

  // Path of the note currently being edited ("" = composing a fresh note).
  property string editingFile: ""

  // Delete-confirmation state.
  property bool deleteConfirmOpen: false
  property string pendingDeletePath: ""
  property string pendingDeleteTitle: ""

  // Notes-list state.
  property string searchText: ""
  property bool cursorActive: false
  property int listLimit: 50
  property int maxNoteChars: 50000
  property int maxQueryChars: 200

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color tagColor: Color.accent
  property color neonColor: Color.accent
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  readonly property int cardWidth: Math.min(Style.space(860), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(540), panel.height - Style.gapsOut * 2)
  readonly property int listPaneWidth: Math.max(Style.space(280), Math.min(Style.space(360), root.cardWidth * 0.42))
  readonly property int noteRowHeight: Math.max(Style.space(52), Style.font.body + Style.font.caption + Style.spacing.xxl)
  readonly property int textBoxRadius: Math.max(14, Style.cornerRadius)

  // Helper scripts ship inside the plugin, so a checkout works anywhere.
  readonly property string sourceDir: {
    if (manifest && manifest.__sourceDir) return manifest.__sourceDir
    return root.home + "/.config/omarchy/plugins/ghpo.quicknote"
  }
  readonly property string quicknoteScript: root.sourceDir + "/quicknote.sh"

  function scriptCommand(args) {
    // setsid puts the helper in its own session/process group so a watchdog
    // TERM/KILL on it never bleeds into the shell's own process group.
    return ["setsid", root.quicknoteScript, "--dir", root.notesDir].concat(args)
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.fontFamily) {
      var fam = String(payload.fontFamily)
      if (fam.length <= 64) root.fontFamily = fam
    }
    if (payload.notesDir) {
      var dir = String(payload.notesDir)
      if (dir.length > 0 && dir.length <= 1024 && dir.indexOf("\u0000") === -1)
        root.notesDir = dir
    }

    root.opened = true
    root.startNewNote()
    searchField.text = ""
    root.searchText = ""
    root.cursorActive = false
    root.reloadNotes()

    Qt.callLater(function() { noteEditor.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "ghpo.quicknote")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function startNewNote() {
    root.editingFile = ""
    root.note = ""
    Qt.callLater(function() { noteEditor.forceActiveFocus() })
  }

  function runNotes(args) {
    notesProc.running = false
    killTimer.stop()
    notesProc.command = root.scriptCommand(args)
    notesWatchdog.restart()
    notesProc.running = true
  }

  function reloadNotes() {
    root.runNotes(["list", String(root.listLimit)])
  }

  function runSearch(query) {
    var q = String(query || "")
    if (q.length > root.maxQueryChars) q = q.slice(0, root.maxQueryChars)
    if (!q) {
      root.reloadNotes()
      return
    }
    // Query travels on stdin (NUL-terminated), never in argv.
    notesProc.payload = q
    root.runNotes(["search", String(root.listLimit)])
  }

  function applyFilter() {
    var q = root.searchText.trim()
    root.cursorActive = false
    noteList.currentIndex = -1
    if (q) root.runSearch(q)
    else root.reloadNotes()
  }

  function applyNotesOutput(raw) {
    var entries = []
    try {
      var parsed = JSON.parse(String(raw || "[]"))
      if (Array.isArray(parsed)) entries = parsed
    } catch (e) {
      entries = []
    }

    notesModel.clear()
    // Bounded, schema-validated ingestion: ignore anything that isn't a plain
    // object, cap every field length, cap tag count, and never append more
    // than listLimit rows.
    var max = Math.min(entries.length, root.listLimit)
    for (var i = 0; i < max; i++) {
      var e = entries[i]
      if (!e || typeof e !== "object") continue
      var path = String(e.path || "").slice(0, 1024)
      if (!path) continue
      var file = String(e.file || "").slice(0, 256)
      var title = String(e.title || "").slice(0, 512)
      var content = String(e.content || "").slice(0, 131072)
      var stamp = String(e.stamp || "").slice(0, 64)
      var tags = []
      if (Array.isArray(e.tags)) {
        for (var t = 0; t < e.tags.length && t < 6; t++) {
          var tg = String(e.tags[t]).slice(0, 128)
          if (tg) tags.push(tg)
        }
      }
      notesModel.append({ path: path, file: file, title: title, content: content, stamp: stamp, tags: tags })
    }

    noteList.currentIndex = noteList.count > 0 ? 0 : -1
    if (noteList.count > 0) noteList.positionViewAtIndex(0, ListView.Contain)
  }

  function activateIndex(index) {
    if (index < 0 || index >= noteList.count) return
    var row = notesModel.get(index)
    root.editingFile = row.path
    root.note = row.content
    root.cursorActive = true
    noteList.currentIndex = index
    Qt.callLater(function() { noteEditor.forceActiveFocus() })
  }

  function copyIndex(index) {
    if (index < 0 || index >= noteList.count) return
    var row = notesModel.get(index)
    root.copyText(row.content)
    root.dismiss()
  }

  function copyText(text) {
    if (!text) return
    // Copy via the helper (stdin -> wl-copy): no temp files, no argv content.
    copyProc.command = root.scriptCommand(["copy"])
    copyProc.payload = text
    copyProc.running = true
  }

  function openIndex(index) {
    if (index < 0 || index >= noteList.count) return
    var row = notesModel.get(index)
    root.openFile(row.path)
  }

  function openFile(path) {
    if (!path) return
    Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-launch-editor", path])
    root.dismiss()
  }

  function selectFromPointer(index) {
    root.cursorActive = true
    noteList.currentIndex = index
  }

  function setSearchFromTag(tag) {
    searchField.text = tag
    root.searchText = tag
    root.applyFilter()
    searchField.forceActiveFocus()
  }

  function requestDelete(index) {
    if (index < 0 || index >= noteList.count) return
    var row = notesModel.get(index)
    root.pendingDeletePath = row.path
    root.pendingDeleteTitle = row.title || "Sem título"
    root.deleteConfirmOpen = true
  }

  function cancelDelete() {
    root.deleteConfirmOpen = false
    root.pendingDeletePath = ""
  }

  function confirmDelete() {
    var path = root.pendingDeletePath
    root.deleteConfirmOpen = false
    root.pendingDeletePath = ""
    if (!path) return

    // Supervised: only refresh after the helper confirms deletion.
    mutationProc.command = root.scriptCommand(["delete", path.split("/").pop()])
    mutationProc.payload = ""
    mutationProc.kind = "delete"
    mutationProc.running = true
  }

  // While the delete confirm is open, key events go to the modal.
  function confirmHandleKey(event) {
    if (!root.deleteConfirmOpen) return false
    if (deleteConfirm.handleKey(event)) {
      event.accepted = true
      return true
    }
    return false
  }

  // Help modal state.
  property bool helpOpen: false

  function openHelp() {
    root.helpOpen = true
  }

  function closeHelp() {
    root.helpOpen = false
  }

  // Unified modal key routing: help first, then the delete confirm.
  function modalKey(event) {
    if (root.helpOpen) {
      if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return
          || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        root.closeHelp()
        event.accepted = true
        return true
      }
      event.accepted = true
      return true
    }
    return root.confirmHandleKey(event)
  }

  // ListModel roles come back as QVariantList, which QML exposes without the
  // JS Array methods — rebuild a plain array so Repeater/UI code can trust it.
  function tagSlice(tags, n) {
    var out = []
    if (tags && tags.length) {
      for (var i = 0; i < tags.length && i < n; i++) out.push(tags[i])
    }
    return out
  }

  function tagCount(tags) {
    return tags && tags.length ? tags.length : 0
  }

  function saveAndClose() {
    var text = root.note
    if (!text.trim()) {
      root.dismiss()
      return
    }
    if (text.length > root.maxNoteChars) {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
        "Nota muito longa", "Máximo de " + root.maxNoteChars + " caracteres"])
      return
    }

    // Supervised: wait for the helper's exit before reporting + refreshing.
    var args = ["save"]
    if (root.editingFile) args.push("--edit", root.editingFile.split("/").pop())
    mutationProc.command = root.scriptCommand(args)
    mutationProc.payload = text
    mutationProc.kind = "save"
    mutationProc.running = true
  }

  // Called when a supervised save/delete finishes.
  function onMutationFinished(exitCode) {
    var kind = mutationProc.kind
    mutationProc.kind = ""
    if (kind === "save") {
      if (exitCode === 0) {
        Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
          "Nota rápida salva", "Sua nota foi salva em " + root.notesDir])
        root.dismiss()
        root.reloadNotes()
      } else {
        Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
          "Erro ao salvar", "O helper falhou (código " + exitCode + ")"])
      }
    } else if (kind === "delete") {
      if (exitCode === 0) {
        if (root.editingFile === root.pendingDeletePath) root.startNewNote()
        root.reloadNotes()
      } else {
        Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
          "Erro ao apagar", "O helper falhou (código " + exitCode + ")"])
      }
    }
  }

  ListModel { id: notesModel }

  Process {
    id: notesProc
    command: root.scriptCommand(["list", "50"])
    stdinEnabled: true
    property var payload: undefined
    onStarted: {
      if (notesProc.payload !== undefined) {
        notesProc.write(String(notesProc.payload) + "\u0000")
        notesProc.payload = undefined
      }
    }
    onExited: {
      notesWatchdog.stop()
      killTimer.stop()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyNotesOutput(text)
    }
  }

  // Watchdog: a list/search that stalls past its budget gets a TERM, then
  // KILL, signalled to the helper's whole process group (negative pid, valid
  // because the helper runs under setsid as a session/group leader).
  Timer {
    id: notesWatchdog
    interval: 15000
    repeat: false
    onTriggered: {
      if (!notesProc.running) return
      var pid = Number(notesProc.processId)
      console.warn("quicknote: notesProc watchdog TERM group", pid)
      if (pid > 0) notesProc.signal(-pid)
      killTimer.start()
    }
  }

  Timer {
    id: killTimer
    interval: 2000
    repeat: false
    onTriggered: {
      if (!notesProc.running) return
      var pid = Number(notesProc.processId)
      console.warn("quicknote: notesProc watchdog KILL group", pid)
      if (pid > 0) notesProc.signal(-pid)
      notesProc.running = false
    }
  }

  // Supervised save/delete helper: stdin carries the note (NUL-terminated),
  // exit status drives success/failure handling.
  Process {
    id: mutationProc
    stdinEnabled: true
    property var payload: undefined
    property string kind: ""
    onStarted: {
      if (mutationProc.payload !== undefined) {
        mutationProc.write(String(mutationProc.payload) + "\u0000")
        mutationProc.payload = undefined
      }
    }
    onExited: root.onMutationFinished(exitCode)
  }

  // Clipboard helper: note text over stdin -> wl-copy, no temp files.
  Process {
    id: copyProc
    stdinEnabled: true
    property var payload: undefined
    onStarted: {
      if (copyProc.payload !== undefined) {
        copyProc.write(String(copyProc.payload) + "\u0000")
        copyProc.payload = undefined
      }
    }
  }

  Timer {
    id: searchTimer
    interval: 150
    repeat: false
    onTriggered: root.applyFilter()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-quicknote"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.panelGap

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.panelGap

          Text {
            Layout.fillWidth: true
            text: "Nota rápida"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            elide: Text.ElideRight
          }
        }

        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.spacing.panelGap

          Item {
            Layout.preferredWidth: root.listPaneWidth
            Layout.fillHeight: true
            clip: true

            Rectangle {
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              anchors.right: parent.right
              width: Style.hairline
              color: Util.alpha(root.border, 0.28)
            }

            ListView {
              id: noteList
              anchors.fill: parent
              anchors.rightMargin: Style.spacing.lg
              clip: true
              spacing: Style.space(4)
              boundsBehavior: Flickable.StopAtBounds
              model: notesModel
              currentIndex: -1
              keyNavigationEnabled: false
              activeFocusOnTab: false

              onCurrentIndexChanged: {
                if (currentIndex >= 0 && currentIndex < count)
                  positionViewAtIndex(currentIndex, ListView.Contain)
              }

              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (root.modalKey(event)) return
                if (event.key === Qt.Key_Escape) {
                  if (root.searchText) {
                    searchField.text = ""
                    root.searchText = ""
                    root.applyFilter()
                    searchField.forceActiveFocus()
                  } else {
                    root.dismiss()
                  }
                  event.accepted = true
                } else if (event.key === Qt.Key_Delete) {
                  root.requestDelete(noteList.currentIndex)
                  event.accepted = true
                } else if (event.key === Qt.Key_Down || event.text === "j") {
                  if (noteList.count > 0) {
                    if (noteList.currentIndex < noteList.count - 1) noteList.currentIndex += 1
                    root.cursorActive = true
                  }
                  event.accepted = true
                } else if (event.key === Qt.Key_Up || event.text === "k") {
                  if (noteList.count === 0) {
                    event.accepted = true
                    return
                  }
                  if (noteList.currentIndex <= 0) {
                    searchField.forceActiveFocus()
                  } else {
                    noteList.currentIndex -= 1
                    root.cursorActive = true
                  }
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if (event.modifiers & Qt.AltModifier) root.copyIndex(noteList.currentIndex)
                  else if (event.modifiers & Qt.ControlModifier) root.openIndex(noteList.currentIndex)
                  else root.activateIndex(noteList.currentIndex)
                  event.accepted = true
                }
              }

              delegate: Rectangle {
                id: row
                required property int index
                required property string path
                required property string title
                required property string stamp
                required property var tags

                readonly property bool hasCursor: root.cursorActive && index === noteList.currentIndex

                width: noteList.width
                height: root.noteRowHeight
                radius: Style.cornerRadius
                color: hasCursor ? root.selectedBackground : "transparent"

                // Title — sits in the upper part of the row.
                Text {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(34)
                  anchors.topMargin: Style.spacing.sm
                  textFormat: Text.PlainText
                  text: row.title || "Sem título"
                  color: hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  elide: Text.ElideRight
                  wrapMode: Text.NoWrap
                }

                // Row activation — covers the whole row, but the bottom band
                // below is declared after it, so tags/trash clicks win.
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: root.selectFromPointer(row.index)
                  onClicked: root.activateIndex(row.index)
                }

                // Bottom band overlay: tags + stamp + trash, above the row
                // MouseArea so their clicks are not swallowed.
                RowLayout {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(6)
                  anchors.bottomMargin: Style.spacing.sm
                  spacing: Style.spacing.xs

                  Repeater {
                    model: root.tagSlice(row.tags, 3)

                    delegate: Text {
                      required property string modelData
                      textFormat: Text.PlainText
                      text: modelData
                      color: hasCursor ? root.selectedText : root.tagColor
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      opacity: hasCursor ? 1 : 0.85

                      MouseArea {
                        anchors.fill: parent
                        anchors.margins: -Style.spacing.xs
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.setSearchFromTag(text)
                      }
                    }
                  }

                  Text {
                    visible: root.tagCount(row.tags) > 3
                    textFormat: Text.PlainText
                    text: "+" + (root.tagCount(row.tags) - 3)
                    color: hasCursor ? root.selectedText : Qt.darker(root.foreground, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Item { Layout.fillWidth: true }

                  Text {
                    textFormat: Text.PlainText
                    text: row.stamp
                    color: hasCursor ? root.selectedText : Qt.darker(root.foreground, 1.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    opacity: hasCursor ? 1 : 0.8
                  }

                  Text {
                    id: trashIcon
                    text: ""
                    color: trashHover.hovered
                      ? Color.urgent
                      : (hasCursor ? root.selectedText : Util.alpha(root.foreground, 0.7))
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                    opacity: hasCursor || trashHover.hovered ? 1 : 0.8

                    HoverHandler { id: trashHover }

                    MouseArea {
                      anchors.fill: parent
                      anchors.margins: -Style.spacing.xs
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.requestDelete(row.index)
                    }
                  }
                }
              }
            }

            Column {
              anchors.centerIn: parent
              spacing: Style.spacing.sm
              visible: noteList.count === 0

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.searchText ? "Sem resultados para \"" + root.searchText + "\"" : "Sem notas ainda"
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
              }

              Text {
                width: parent.width
                visible: !root.searchText
                text: "Salve a primeira nota no editor ao lado"
                color: Qt.darker(root.foreground, 1.7)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
              }
            }
          }

          Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ColumnLayout {
              id: editorPane
              anchors.fill: parent
              spacing: Style.spacing.panelGap

              TextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: "Buscar notas…"
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                color: root.foreground
                placeholderTextColor: Qt.darker(root.foreground, 1.6)
                selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
                selectedTextColor: root.foreground

                leftPadding: Style.spacing.controlPaddingX + Border.left(_borderSpec)
                rightPadding: Style.spacing.controlPaddingX + Border.right(_borderSpec)
                topPadding: Style.spacing.inputPaddingY + Border.top(_borderSpec)
                bottomPadding: Style.spacing.inputPaddingY + Border.bottom(_borderSpec)

                readonly property bool _focused: activeFocus
                readonly property bool _hot: hovered
                readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : (_hot ? "hover-cursor" : "normal"), root.foreground, Color.accent)

                background: BorderSurface {
                  color: Style.controlFill(searchField._focused, searchField._hot, root.foreground, Color.accent)
                  borderSpec: searchField._borderSpec
                  radius: root.textBoxRadius
                }

                onTextEdited: {
                  if (!root.opened) return
                  root.searchText = searchField.text
                  searchTimer.restart()
                }

                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                  if (root.modalKey(event)) return
                  if (event.key === Qt.Key_Escape) {
                    if (searchField.text) {
                      searchField.text = ""
                      root.searchText = ""
                      root.applyFilter()
                    } else {
                      root.dismiss()
                    }
                    event.accepted = true
                  } else if (event.key === Qt.Key_Down) {
                    if (noteList.count > 0) {
                      noteList.currentIndex = 0
                      root.cursorActive = true
                      noteList.forceActiveFocus()
                      noteList.positionViewAtIndex(0, ListView.Contain)
                    }
                    event.accepted = true
                  } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (searchTimer.running) {
                      // Search is still pending — run it now and let the user
                      // confirm once the results land.
                      searchTimer.stop()
                      root.applyFilter()
                    } else if (noteList.count > 0) {
                      root.activateIndex(0)
                    }
                    event.accepted = true
                  }
                }
              }

              Item {
                id: editorSlot
                Layout.fillWidth: true
                Layout.fillHeight: true

                // Solid box behind the editor (TextArea background doesn't
                // paint reliably, so the fill lives here as a sibling). The
                // thin neon border also lives here, not on the comet overlay.
                BorderSurface {
                  id: editorBox
                  anchors.fill: parent
                  radius: root.textBoxRadius
                  color: Qt.darker(root.background, noteEditor._focused ? 1.5 : 1.3)
                  borderSpec: Border.flat(
                    Qt.rgba(root.neonColor.r, root.neonColor.g, root.neonColor.b,
                            noteEditor._focused ? 0.85 : 0.4),
                    Math.max(1, Style.hairline))
                }

                TextArea {
                  id: noteEditor
                  anchors.fill: parent
                  clip: true

                  text: root.note
                  placeholderText: "Digite sua nota...  (Enter salva, Shift+Enter nova linha)"
                  placeholderTextColor: Qt.darker(root.foreground, 1.6)

                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  color: root.foreground
                  selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
                  selectedTextColor: root.foreground

                  wrapMode: TextEdit.Wrap

                  leftPadding: Style.spacing.controlPaddingX + Border.left(_borderSpec)
                  rightPadding: Style.spacing.controlPaddingX + Border.right(_borderSpec)
                  topPadding: Style.spacing.inputPaddingY + Border.top(_borderSpec)
                  bottomPadding: Style.spacing.inputPaddingY + Border.bottom(_borderSpec)

                  readonly property bool _focused: activeFocus
                  readonly property bool _hot: hovered
                  readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : (_hot ? "hover-cursor" : "normal"), root.foreground, Color.accent)

                  background: Rectangle { color: "transparent" }

                  onTextChanged: root.note = noteEditor.text

                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                  if (root.modalKey(event)) return
                  if (event.key === Qt.Key_Escape) {
                    root.dismiss()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (event.modifiers & Qt.AltModifier) {
                      // Copy what's in the editor (the loaded note).
                      root.copyText(root.note)
                      event.accepted = true
                    } else if (event.modifiers & Qt.ControlModifier) {
                      // Open the file being edited in the external editor.
                      root.openFile(root.editingFile)
                      event.accepted = true
                    } else if (!(event.modifiers & Qt.ShiftModifier)) {
                      root.saveAndClose()
                      event.accepted = true
                    }
                  }
                }

                NeonBorder {
                  id: editorNeon
                  anchors.fill: parent
                  radius: root.textBoxRadius
                  neonColor: root.neonColor
                  baseOpacity: noteEditor._focused ? 1.0 : 0.5
                }
              }
            }
          }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.controlGap

        Button {
          text: "?"
            fontFamily: root.fontFamily
            tooltipText: "Como funciona"
            onClicked: root.openHelp()
          }

          Item { Layout.fillWidth: true }

          Button {
            text: "Nova"
            fontFamily: root.fontFamily
            visible: root.editingFile !== ""
            onClicked: root.startNewNote()
          }

          Button {
            text: "Fechar"
            fontFamily: root.fontFamily
            onClicked: root.dismiss()
          }

          Button {
            text: "Salvar"
            fontFamily: root.fontFamily
            active: true
            onClicked: root.saveAndClose()
          }
        }
      }

        ConfirmDialog {
          id: deleteConfirm
          anchors.fill: parent
          z: 30
          opened: root.deleteConfirmOpen
          message: "Apagar a nota \"" + root.pendingDeleteTitle + "\"?"
          cancelText: "Cancelar"
          confirmText: "Apagar"
          background: root.background
          foreground: root.foreground
          scrim: Qt.rgba(0, 0, 0, 0.55)
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelDelete()
          onConfirmed: root.confirmDelete()
        }

        Item {
          id: helpModal
          anchors.fill: parent
          z: 40
          visible: root.helpOpen

          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.55)
            MouseArea { anchors.fill: parent; onClicked: root.closeHelp() }
          }

          BorderSurface {
            id: helpCard
            width: Math.min(parent.width - Style.space(48), Style.space(440))
            height: Math.min(parent.height - Style.space(40), Style.space(460))
            anchors.centerIn: parent
            color: root.background
            borderSpec: Border.flat(root.neonColor, Style.normalBorderWidth)
            padding: Style.space(18)
            radius: root.cornerRadius

            MouseArea { anchors.fill: parent; onClicked: {} }

            ColumnLayout {
              anchors.fill: parent
              anchors.topMargin: helpCard.contentTopInset
              anchors.rightMargin: helpCard.contentRightInset
              anchors.bottomMargin: helpCard.contentBottomInset
              anchors.leftMargin: helpCard.contentLeftInset
              spacing: Style.spacing.sm

              Text {
                Layout.fillWidth: true
                text: "Como funciona"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }

              Flickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: helpBody.implicitHeight
                boundsBehavior: Flickable.StopAtBounds

                Text {
                  id: helpBody
                  width: parent.width
                  textFormat: Text.RichText
                  color: Qt.darker(root.foreground, 1.25)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  lineHeight: 1.45
                  wrapMode: Text.WordWrap
                  text: "<b style='color:" + root.foreground + "'>Notas rápidas</b><br/><br/>" +
                        "Escreva no editor e pressione <b>Enter</b> (ou Salvar) para salvar a nota como um arquivo .md com data/hora em ~/Documents/QuickNotes/. <b>Shift+Enter</b> faz nova linha.<br/><br/>" +
                        "<b style='color:" + root.foreground + "'>Painel esquerdo — notas recentes</b><br/>" +
                        "· <b>Enter</b> — carrega a nota no editor (Salvar sobrescreve)<br/>" +
                        "· <b>Alt+Enter</b> — copia a nota<br/>" +
                        "· <b>Ctrl+Enter</b> — abre a nota no seu editor de texto<br/>" +
                        "· <b>Delete</b> (ou a lixeira) — apaga, com confirmação<br/><br/>" +
                        "<b style='color:" + root.foreground + "'>Busca</b><br/>" +
                        "O campo acima do editor filtra por texto ou por #tag. <b>Esc</b> limpa.<br/><br/>" +
                        "<b style='color:" + root.foreground + "'>Categorizar com # (tags)</b><br/>" +
                        "Escreva #palavra no texto da nota (ex.: #ideia, #compras). A palavra vira uma tag automaticamente, aparece em azul na lista e serve de filtro: clique nela ou digite-a na busca para ver só as notas com essa tag.<br/><br/>" +
                        "<b style='color:" + root.foreground + "'>Atalhos</b><br/>" +
                        "· <b>Esc</b> — fecha sem salvar<br/>" +
                        "· <b>Shift+Enter</b> — nova linha"
                }
              }

              RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.spacing.sm
                Item { Layout.fillWidth: true }
                Button {
                  text: "Fechar"
                  fontFamily: root.fontFamily
                  active: true
                  onClicked: root.closeHelp()
                }
              }
            }
          }
        }
    }
  }
}
