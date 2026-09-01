import Quickshell
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

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  readonly property int cardWidth: Math.min(Style.space(400), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(300), panel.height - Style.gapsOut * 2)

  // The save helper ships inside the plugin, so a checkout works anywhere.
  readonly property string saveScript: {
    if (manifest && manifest.__sourceDir) return manifest.__sourceDir + "/save-note.sh"
    return root.home + "/.config/omarchy/quicknote/save-note.sh"
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.fontFamily) root.fontFamily = payload.fontFamily
    if (payload.notesDir) root.notesDir = payload.notesDir

    root.opened = true
    root.note = ""

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

  function saveAndClose() {
    var text = root.note
    if (!text.trim()) {
      root.dismiss()
      return
    }

    Quickshell.execDetached([root.saveScript, text])
    Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send", "Nota rápida salva", text.split("\n")[0]])
    root.dismiss()
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

        Text {
          Layout.fillWidth: true
          text: "Nota rápida"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
          elide: Text.ElideRight
        }

        TextArea {
          id: noteEditor
          Layout.fillWidth: true
          Layout.fillHeight: true

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

          background: BorderSurface {
            color: Style.controlFill(noteEditor._focused, noteEditor._hot, root.foreground, Color.accent)
            borderSpec: noteEditor._borderSpec
            radius: Style.cornerRadius
          }

          onTextChanged: root.note = noteEditor.text

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.dismiss()
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if (!(event.modifiers & Qt.ShiftModifier)) {
                root.saveAndClose()
                event.accepted = true
              }
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.controlGap

          Item { Layout.fillWidth: true }

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
    }
  }
}
