import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "ghpo.quicknote"

  readonly property string iconGlyph: setting("icon", "󰎚")

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function summon() {
    // Read settings at click time: readonly bindings are evaluated before the
    // shell injects `settings`, so they would cache stale values.
    var payload = JSON.stringify({
      notesDir: root.setting("notesDir", "~/Documents/QuickNotes"),
      encryption: root.setting("encryption", false),
      gitRemote: root.setting("gitRemote", "")
    })
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
