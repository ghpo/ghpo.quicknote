import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "ghpo.quicknote"

  readonly property string iconGlyph: setting("icon", "󰎚")
  readonly property string notesDir: setting("notesDir", "~/Documents/QuickNotes")

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function summon() {
    var payload = JSON.stringify({ notesDir: root.notesDir })
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "ghpo.quicknote", payload])
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconGlyph
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: "Quick Note"
    onPressed: root.summon()
  }
}
