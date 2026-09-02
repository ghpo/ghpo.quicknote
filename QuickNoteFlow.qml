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

  // Crypto / storage-daemon state.
  property bool cryptoEnabled: false
  property bool cryptoUnlocked: false
  property string gitRemote: ""
  property string cryptoDir: ""
  property bool cryptoPlain: false
  property bool cryptoStarted: false
  // Encrypted notes are not decrypted yet: hide editing/search/footer and
  // show a LOCKED screen with an Unlock button instead.
  readonly property bool isLocked: root.cryptoEnabled && !root.cryptoPlain && !root.cryptoUnlocked
  property var cryptoQueue: []
  property var cryptoWaiting: null
  property int cryptoReqSeq: 0
  property bool passwordOpen: false
  property string passwordError: ""
  property bool changeOpen: false
  property string changeError: ""
  property bool changeBusy: false

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

  function daemonCommand() {
    var args = [root.quicknoteScript, "--dir", root.notesDir]
    if (!root.cryptoEnabled) args.push("--plain")
    // setsid: own session/process group so the daemon is isolated.
    return ["setsid"].concat(args)
  }

  // Serialize requests to the storage daemon: one JSON request per line on
  // stdin, one JSON response per line on stdout (SplitParser). Requests with
  // `priority` (the unlock sent from the password modal) jump the queue so a
  // request deferred on "locked" can never starve the unlock behind it.
  function cryptoSend(req, cb, priority) {
    root.cryptoReqSeq += 1
    req.id = root.cryptoReqSeq
    var item = { req: req, cb: cb || null }
    if (priority) cryptoQueue.unshift(item)
    else cryptoQueue.push(item)
    root.cryptoPump()
  }

  function cryptoPump() {
    if (!root.cryptoStarted || root.cryptoWaiting) return
    if (cryptoQueue.length === 0) return
    var item = cryptoQueue.shift()
    cryptoWaiting = item
    cryptoWatchdog.restart()
    cryptoProc.write(JSON.stringify(item.req) + "\n")
  }

  function onCryptoLine(raw) {
    cryptoWatchdog.stop()
    var res = ({})
    try { res = JSON.parse(String(raw || "")) } catch (e) { res = ({ ok: false, error: "bad response" }) }
    var item = cryptoWaiting

    // Ignore stale/out-of-order responses (match by request id).
    if (item && Number(res.id) !== Number(item.req.id)) {
      cryptoWaiting = item   // keep waiting for the matching response
      cryptoWatchdog.restart()
      return
    }
    cryptoWaiting = null

    if (!item) { return }

    if (item.req.op === "unlock") {
      if (res.ok) {
        root.cryptoUnlocked = true
        root.passwordOpen = false
        root.passwordError = ""
        if (item.cb) item.cb(res)
      } else {
        root.passwordError = res.error || "Unable to unlock"
        if (item.cb) item.cb(res)
      }
    } else if (!res.ok && res.error === "locked") {
      // Daemon is locked (encrypted + no key yet). Hold the request at the
      // front of the queue and prompt, but do NOT re-send it now — re-pumping
      // it immediately would spin: the request would be rejected again and
      // again while any unlock queued behind it could never be sent.
      if (item.cb) item.cb(res)
      if (!root.cryptoPlain) {
        cryptoQueue.unshift(item)
        root.promptPassword()
      }
      return
    } else {
      if (res.ok && item.req.op !== "ping") root.cryptoUnlocked = true
      if (item.cb) item.cb(res)
    }
    root.cryptoPump()
  }

  // Bring the daemon up for the current notesDir/encryption mode.
  function ensureCrypto(readyCb) {
    var plainMode = !root.cryptoEnabled
    if (cryptoProc.running && root.cryptoDir === root.notesDir
        && root.cryptoPlain === plainMode && root.cryptoStarted) {
      if (readyCb) readyCb()
      return
    }
    cryptoQueue = []
    cryptoWaiting = null
    root.cryptoStarted = false
    cryptoProc.running = false
    root.cryptoDir = root.notesDir
    root.cryptoPlain = plainMode
    cryptoProc.command = root.daemonCommand()
    cryptoProc.running = true
    if (readyCb) readyCb()
  }

  function promptPassword() {
    if (root.cryptoPlain || root.cryptoUnlocked) return
    root.passwordOpen = true
    root.passwordError = ""
    Qt.callLater(function() { passwordField.forceActiveFocus() })
  }

  function submitPassword() {
    var pw = passwordField.text
    if (!pw) return
    passwordField.text = ""
    root.cryptoUnlocked = false
    // Priority: jump ahead of any request already deferred on "locked", or
    // the unlock would never be sent.
    root.cryptoSend({ op: "unlock", password: pw }, function(res) {
      if (res.ok) root.reloadNotes()
    }, true)
  }

  function openChangePass() {
    root.changeError = ""
    root.changeOpen = true
    Qt.callLater(function() { chgOldField.forceActiveFocus() })
  }

  function closeChangePass() {
    if (root.changeBusy) return
    chgOldField.text = ""
    chgNewField.text = ""
    chgConfirmField.text = ""
    root.changeOpen = false
    root.changeError = ""
  }

  function submitChangePass() {
    if (root.changeBusy) return
    var o = chgOldField.text
    var n = chgNewField.text
    var c = chgConfirmField.text
    if (!o) { root.changeError = "Type your current password"; return }
    if (n.length < 6) { root.changeError = "New password must have at least 6 characters"; return }
    if (n !== c) { root.changeError = "New passwords do not match"; return }
    chgOldField.text = ""
    chgNewField.text = ""
    chgConfirmField.text = ""
    root.changeError = ""
    root.changeBusy = true
    root.cryptoSend({ op: "changepass", old: o, new: n }, function(res) {
      root.changeBusy = false
      if (res.ok) {
        root.changeOpen = false
        Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
          "Password changed", "All notes were re-encrypted"])
        if (root.gitRemote !== "") root.openSync()
      } else {
        root.changeError = res.error || "Failed to change password"
      }
    })
  }

  function lockCrypto() {
    root.cryptoSend({ op: "lock" }, function() {
      root.cryptoUnlocked = false
      notesModel.clear()
      noteList.currentIndex = -1
    })
  }

  // Git sync (manual): pull, commit, push. The dialog shows the live script
  // output so the user can see exactly what succeeded or failed.
  property bool syncOpen: false
  property bool syncBusy: false
  property string syncOutput: ""
  property string syncStatus: ""     // "", "ok", "error"
  property string syncRemoteEdit: ""
  property bool syncSshOpen: false
  property bool keyBackupOpen: false

  function syncLogAdd(extra) {
    if (extra) root.syncOutput = root.syncOutput + String(extra) + "\n"
    else root.syncOutput = root.syncOutput + "\n"
    Qt.callLater(function() {
      syncLogFlick.contentY = Math.max(0, syncLogText.height - syncLogFlick.height)
    })
  }

  function openSync() {
    if (root.syncBusy) return
    root.syncRemoteEdit = root.gitRemote
    root.syncOutput = ""
    root.syncStatus = ""
    root.syncOpen = true
    Qt.callLater(function() { root.startSync() })
  }

  function closeSync() {
    if (root.syncBusy) return
    root.syncOpen = false
  }

  function startSync() {
    if (root.syncBusy) return
    root.syncRemoteEdit = (root.syncRemoteEdit || "").trim()
    root.syncOutput = ""
    root.syncStatus = ""
    root.syncBusy = true
    root.syncLogAdd("▶ syncing notes (" + root.syncRemoteEdit + ") ...")
    var args = [root.sourceDir + "/quicknote-git.sh", root.notesDir]
    if (root.syncRemoteEdit) args.push(root.syncRemoteEdit)
    args.push("sync")
    gitProc.command = args
    gitProc.running = true
  }

  function onSyncFinished(outputText) {
    root.syncBusy = false
    var out = String(outputText || "").trim()
    root.syncOutput = out
    if (out.indexOf("quicknote: OK") !== -1) {
      root.syncStatus = "ok"
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
        "Notes synced", "Pulled and pushed from/to " + root.syncRemoteEdit])
    } else {
      root.syncStatus = "error"
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
        "Sync failed", "See the log for details"])
    }
    root.reloadNotes()
  }

  // Persist the remote back into shell.json so the bar button uses it too.
  function saveRemote() {
    var v = (root.syncRemoteEdit || "").trim()
    root.syncRemoteEdit = v
    root.gitRemote = v
    var saved = false
    try {
      if (root.shell && typeof root.shell.updateEntryInline === "function") {
        var id = (root.manifest && root.manifest.id) || "ghpo.quicknote"
        var next = { encryption: root.cryptoEnabled }
        next.gitRemote = v
        saved = root.shell.updateEntryInline(id, next) === true
      }
    } catch (e) { saved = false }
    Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
      saved ? "Remote saved" : "Remote updated for this session only",
      v ? v : "(empty = no sync)"])
    if (v && !root.syncBusy) Qt.callLater(function() { root.startSync() })
  }

  // Copy the public half of the SSH key so the user can paste it into GitHub.
  function copyPubKey() {
    var cmd = "k=$HOME/.ssh/id_ed25519.pub; if [[ -f $k ]]; then wl-copy < \"$k\" && echo copied; else echo missing; fi"
    pubKeyProc.command = ["bash", "-c", cmd]
    pubKeyProc.running = true
  }

  function onPubKeyCopied(out) {
    var text = String(out || "").trim()
    if (text.indexOf("copied") !== -1) {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
        "Public key copied", "Paste it on GitHub under Settings → SSH keys"])
    } else {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
        "No SSH key found", "Generate one: ssh-keygen -t ed25519"])
    }
  }

  // Backup the .quicknote-seal (salt + verification blob) — needed to unlock
  // the same notes on another machine. Not a secret, but losing it is annoying.
  function exportSeal() {
    if (sealProc.running) return
    // The Quick Notes overlay is a top layer surface, so the portal file
    // chooser would open behind it. Hide the dialog first, then export.
    root.dismiss()
    var seal = root.expandedNotesDir() + "/.quicknote-seal"
    var cmd = "dest=$(omarchy-file-select --title 'Backup .quicknote-seal' --directory 2>/dev/null) && "
      + "[[ -n $dest && -f " + Util.shellQuote(seal) + " ]] && "
      + "cp " + Util.shellQuote(seal) + " \"$dest/quicknote-seal\" && echo \"$dest\""
    sealProc.command = ["bash", "-lc", cmd]
    sealProc.running = true
  }

  function onSealExported(out) {
    var dest = String(out || "").trim()
    if (dest) {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
        "Seal backed up", dest + "/quicknote-seal"])
    } else {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
        "Export cancelled", "Nothing was saved"])
    }
  }

  // Restore a backed-up seal: pick the file and copy it into the notes folder
  // as .quicknote-seal. Do this BEFORE the first unlock on a new machine, or
  // the daemon would create a fresh salt and old notes could not decrypt.
  function importSeal() {
    if (importSealProc.running) return
    // Hide the dialog so the portal file chooser is not behind the overlay.
    root.dismiss()
    var seal = root.expandedNotesDir() + "/.quicknote-seal"
    var cmd = "src=$(omarchy-file-select --title 'Select your quicknote-seal backup' 2>/dev/null); "
      + "if [[ -n $src && -f \"$src\" ]]; then "
      + "mkdir -p " + Util.shellQuote(root.expandedNotesDir())
      + " && cp \"$src\" " + Util.shellQuote(seal)
      + " && chmod 600 " + Util.shellQuote(seal)
      + " && echo restored; else echo cancelled; fi"
    importSealProc.command = ["bash", "-lc", cmd]
    importSealProc.running = true
  }

  function onSealImported(out) {
    var text = String(out || "").trim()
    if (text === "restored") {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
        "Seal restored", "Now reopen Quick Notes and unlock with your password"])
    } else {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
        "Import cancelled", "No seal was copied"])
    }
  }

  function expandedNotesDir() {
    var d = root.notesDir
    if (d.indexOf("~") === 0) return root.home + d.slice(1)
    return d
  }

  function open(payloadJson) {
    root.keyBackupOpen = false
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
    root.cryptoEnabled = !!payload.encryption
    if (payload.gitRemote) root.gitRemote = String(payload.gitRemote).slice(0, 512)

    root.opened = true
    root.startNewNote()
    searchField.text = ""
    root.searchText = ""
    root.cursorActive = false

    // Start the storage daemon, then load notes (prompts for the password
    // automatically if encryption is on and the key is not in RAM).
    root.ensureCrypto(function() {
      root.cryptoSend({ op: "ping" }, function(res) {
        root.cryptoUnlocked = !!res.unlocked || root.cryptoPlain
        if (root.cryptoUnlocked) root.reloadNotes()
        else Qt.callLater(function() { if (lockedView.visible) lockedView.forceActiveFocus() })
        // Encrypted + locked: keep the dialog on the LOCKED view; the Unlock
        // button opens the password prompt instead of auto-popping it.
      })
    })

    Qt.callLater(function() { noteEditor.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    root.keyBackupOpen = false
    if (root.passwordOpen) root.passwordOpen = false
    if (root.helpOpen) root.closeHelp()
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

  function reloadNotes() {
    root.cryptoSend({ op: "list", limit: root.listLimit }, function(res) {
      if (res.ok && res.notes) root.applyNotes(res.notes)
      else if (res.error !== "locked") console.warn("quicknote: list failed", res.error)
    })
  }

  function runSearch(query) {
    var q = String(query || "")
    if (q.length > root.maxQueryChars) q = q.slice(0, root.maxQueryChars)
    if (!q) { root.reloadNotes(); return }
    root.cryptoSend({ op: "search", query: q }, function(res) {
      if (res.ok && res.notes) root.applyNotes(res.notes)
      else if (res.error !== "locked") console.warn("quicknote: search failed", res.error)
    })
  }

  function applyFilter() {
    var q = root.searchText.trim()
    root.cursorActive = false
    noteList.currentIndex = -1
    if (q) root.runSearch(q)
    else root.reloadNotes()
  }

  function applyNotes(entries) {
    notesModel.clear()
    // Bounded, schema-validated ingestion: cap every field length, cap tag
    // count, and never append more than listLimit rows.
    var list = Array.isArray(entries) ? entries : []
    var max = Math.min(list.length, root.listLimit)
    for (var i = 0; i < max; i++) {
      var e = list[i]
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
    root.cryptoSend({ op: "copy", content: String(text) })
  }

  function openIndex(index) {
    if (index < 0 || index >= noteList.count) return
    var row = notesModel.get(index)
    root.openFile(row.path)
  }

  function openFile(path) {
    if (!path) return
    if (root.cryptoEnabled) {
      // Encrypted notes can't be handed to an external editor safely; copy.
      root.copyText(root.note)
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
        "Note copied", "Encrypted notes can't be opened externally; copied to clipboard"])
      root.dismiss()
      return
    }
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
    root.pendingDeleteTitle = row.title || "Untitled"
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

    // Supervised: only refresh after the daemon confirms deletion.
    root.cryptoSend({ op: "delete", file: path.split("/").pop() }, function(res) {
      if (res.ok) {
        if (root.editingFile === path) root.startNewNote()
        root.reloadNotes()
      } else if (res.error !== "locked") {
        Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
          "Error deleting", "The helper failed"])
      }
    })
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
    root.startMusic()
  }

  function closeHelp() {
    root.helpOpen = false
    root.stopMusic()
  }

  // Embedded MIDI (Darude - Sandstorm) synthesized via timidity. Starts when
  // the help overlay opens and stops when it closes.
  function startMusic() {
    if (musicProc.running) musicProc.running = false
    musicProc.command = [root.sourceDir + "/play-music.sh"]
    musicProc.running = true
  }

  function stopMusic() {
    // play-music.sh execs timidity, so the tracked child IS the player.
    musicProc.running = false
  }

  // Unified modal key routing: help first, then the delete confirm.
  function modalKey(event) {
    if (root.passwordOpen) {
      if (event.key === Qt.Key_Escape) {
        root.passwordOpen = false
        event.accepted = true
        return true
      }
      return true
    }
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
        "Note too long", "Maximum of " + root.maxNoteChars + " characters"])
      return
    }

    // Supervised: only report success / refresh after the daemon confirms.
    root.cryptoSend({
      op: "save",
      content: text,
      edit: root.editingFile ? root.editingFile.split("/").pop() : null
    }, function(res) {
      if (res.ok) {
        Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
          "Quick note saved", "Your note was saved in " + root.notesDir])
        root.dismiss()
        root.reloadNotes()
      } else if (res.error !== "locked") {
        Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
          "Error saving", "The helper failed"])
      }
    })
  }

  ListModel { id: notesModel }

  // Single long-lived storage daemon: holds the key (encryption) or runs in
  // plain mode. JSON requests on stdin, JSON responses (one per line) here.
  Process {
    id: cryptoProc
    command: ["setsid"]
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(data) { root.onCryptoLine(String(data)) }
    }
    onStarted: {
      root.cryptoStarted = true
      root.cryptoPump()
    }
    onExited: {
      root.cryptoStarted = false
      root.cryptoWaiting = null
      cryptoQueue = []
    }
  }

  // Request watchdog: if the daemon stops answering, restart it rather than
  // leaving the UI hung.
  Timer {
    id: cryptoWatchdog
    interval: 30000
    repeat: false
    onTriggered: {
      if (!root.cryptoWaiting) return
      console.warn("quicknote: crypto daemon stalled, restarting")
      var failed = root.cryptoWaiting
      root.cryptoWaiting = null
      cryptoQueue = []
      cryptoProc.running = false
      Qt.callLater(function() { root.ensureCrypto(null) })
      if (failed.cb) failed.cb({ ok: false, error: "daemon restart" })
    }
  }

  // Watchdog: a list/search that stalls past its budget gets a TERM, then
  // KILL, signalled to the helper's whole process group (negative pid, valid
  // because the helper runs under setsid as a session/group leader).
  // Help-overlay background music (play-music.sh -> native player).
  Process {
    id: musicProc
    command: []
  }

  // Git sync helper (pull + commit + push). Its whole output is shown in the
  // sync window so the user can read exactly what happened.
  Process {
    id: gitProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSyncFinished(text)
    }
  }

  // Copy the SSH public key to the clipboard.
  Process {
    id: pubKeyProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onPubKeyCopied(text)
    }
  }

  // Seal backup helper (file chooser -> copy).
  Process {
    id: sealProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSealExported(text)
    }
  }

  // Seal restore helper (file chooser -> copy into the notes dir).
  Process {
    id: importSealProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSealImported(text)
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
            text: "Quick Notes"
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
          visible: !root.isLocked

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
                  text: row.title || "Untitled"
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
                text: root.searchText ? "No results for \"" + root.searchText + "\"" : "No notes yet"
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
              }

              Text {
                width: parent.width
                visible: !root.searchText
                text: "Save your first note in the editor on the right"
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
                placeholderText: "Search notes…"
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
                  placeholderText: "Type your note...  (Enter saves, Shift+Enter new line)"
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

                // Manual placeholder: the QQC placeholder is broken by the
                // transparent-background override, so render it ourselves.
                Text {
                  id: editorPlaceholder
                  anchors.fill: noteEditor
                  anchors.leftMargin: noteEditor.leftPadding
                  anchors.topMargin: noteEditor.topPadding
                  anchors.rightMargin: noteEditor.rightPadding
                  anchors.bottomMargin: noteEditor.bottomPadding
                  text: "Type your note...  (Enter saves, Shift+Enter new line)"
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                  visible: root.note.trim() === ""
                  z: 2
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

      // Locked screen (encryption on, key not in memory): replace the editor
      // pane with a LOCKED notice + Unlock so nothing hints at the content.
      Item {
        id: lockedView
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: root.isLocked
        activeFocusOnTab: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.modalKey(event)) return
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
          }
        }

        ColumnLayout {
          anchors.centerIn: parent
          spacing: Style.spacing.lg
          Layout.alignment: Qt.AlignHCenter

          Text {
            Layout.alignment: Qt.AlignHCenter
            text: "LOCKED"
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.space(64)
            font.bold: true
          }

          Text {
            Layout.alignment: Qt.AlignHCenter
            text: "Your notes are encrypted. Unlock to read or write them."
            color: Qt.darker(root.foreground, 1.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Button {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Style.spacing.sm
            text: "Unlock"
            fontFamily: root.fontFamily
            active: true
            onClicked: root.promptPassword()
          }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.controlGap

        Text {
          Layout.preferredWidth: implicitWidth
          text: "v" + ((root.manifest && root.manifest.version) || "")
          color: Qt.darker(root.foreground, 1.8)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          verticalAlignment: Text.AlignVCenter
        }

        Button {
          text: "?"
          fontFamily: root.fontFamily
          tooltipText: "How it works"
          onClicked: root.openHelp()
        }

        Button {
          text: "Lock"
          fontFamily: root.fontFamily
          visible: root.cryptoEnabled && root.cryptoUnlocked
          tooltipText: "Forget the encryption key (asks for the password again)"
          onClicked: root.lockCrypto()
        }

        Button {
          text: "Pass"
          fontFamily: root.fontFamily
          visible: root.cryptoEnabled && root.cryptoUnlocked
          tooltipText: "Change the password (re-encrypts every note)"
          onClicked: root.openChangePass()
        }

        Item {
          width: backupBtn.implicitWidth
          height: backupBtn.implicitHeight
          visible: root.cryptoEnabled

          Button {
            id: backupBtn
            anchors.fill: parent
            text: "Key Backup"
            fontFamily: root.fontFamily
            active: root.keyBackupOpen
            tooltipText: "Back up or restore the .quicknote-seal (needed to unlock on other machines)"
            onClicked: root.keyBackupOpen = !root.keyBackupOpen
          }

          BorderSurface {
            id: backupPop
            visible: root.keyBackupOpen
            anchors.right: parent.right
            anchors.bottom: parent.top
            anchors.bottomMargin: Style.spacing.xs
            width: Math.max(parent.width, Style.space(230))
            height: backupPop.contentTopInset + backupPop.contentBottomInset
                  + backupCol.implicitHeight + Style.space(12)
            z: 90
            color: root.background
            borderSpec: Border.flat(root.neonColor, Style.normalBorderWidth)
            radius: root.cornerRadius
            padding: Style.space(8)

            ColumnLayout {
              id: backupCol
              anchors.fill: parent
              anchors.topMargin: backupPop.contentTopInset
              anchors.rightMargin: backupPop.contentRightInset
              anchors.bottomMargin: backupPop.contentBottomInset
              anchors.leftMargin: backupPop.contentLeftInset
              spacing: Style.spacing.xs

              Button {
                Layout.fillWidth: true
                text: "Export .quicknote-seal"
                fontFamily: root.fontFamily
                tooltipText: "Save the seal to a folder you choose (needed to unlock on another machine)"
                onClicked: {
                  root.keyBackupOpen = false
                  root.exportSeal()
                }
              }

              Button {
                Layout.fillWidth: true
                text: "Import .quicknote-seal"
                fontFamily: root.fontFamily
                tooltipText: "Restore a backed-up seal BEFORE unlocking on a new machine"
                onClicked: {
                  root.keyBackupOpen = false
                  root.importSeal()
                }
              }
            }
          }
        }

        Button {
          text: "Sync"
          fontFamily: root.fontFamily
          visible: root.cryptoEnabled && root.cryptoUnlocked
          enabled: !root.syncBusy
          tooltipText: "Pull + push notes to a git remote"
          onClicked: root.openSync()
        }

        Item { Layout.fillWidth: true }

        Button {
          text: "New"
          fontFamily: root.fontFamily
          visible: root.editingFile !== "" && !root.isLocked
          onClicked: root.startNewNote()
        }

        Button {
          text: "Close"
          fontFamily: root.fontFamily
          visible: !root.isLocked
          onClicked: root.dismiss()
        }

        Button {
          text: "Save"
          fontFamily: root.fontFamily
          active: true
          visible: !root.isLocked
          onClicked: root.saveAndClose()
        }
      }
      }

        ConfirmDialog {
          id: deleteConfirm
          anchors.fill: parent
          z: 30
          opened: root.deleteConfirmOpen
          message: "Delete the note \"" + root.pendingDeleteTitle + "\"?"
          cancelText: "Cancel"
          confirmText: "Delete"
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
                text: "How it works"
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
                  text: "<b style='color:" + root.foreground + "'>Quick Notes</b><br/><br/>" +
                        "Type in the editor and press <b>Enter</b> (or Save) to save the note as a timestamped .md file in ~/Documents/QuickNotes/. <b>Shift+Enter</b> starts a new line.<br/><br/>" +
                        "<b style='color:" + root.foreground + "'>Left panel — recent notes</b><br/>" +
                        "· <b>Enter</b> — loads the note into the editor (Save overwrites)<br/>" +
                        "· <b>Alt+Enter</b> — copies the note<br/>" +
                        "· <b>Ctrl+Enter</b> — opens the note in your text editor<br/>" +
                        "· <b>Delete</b> (or the trash icon) — deletes, with confirmation<br/><br/>" +
                        "<b style='color:" + root.foreground + "'>Search</b><br/>" +
                        "The field above the editor filters by text or by #tag. <b>Esc</b> clears it.<br/><br/>" +
                        "<b style='color:" + root.foreground + "'>Categorizing with # (tags)</b><br/>" +
                        "Write #word anywhere in the note text (e.g. #idea, #shopping). The word becomes a tag automatically, shows in blue in the list, and works as a filter: click it or type it in the search to see only the notes with that tag.<br/><br/>" +
                        "<b style='color:" + root.foreground + "'>Shortcuts</b><br/>" +
                        "· <b>Esc</b> — closes without saving<br/>" +
                        "· <b>Shift+Enter</b> — new line"
                }
              }

              RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.spacing.sm
                Item { Layout.fillWidth: true }
                Text {
                  text: "X: ghpo2k - 2026"
                  color: Util.alpha(root.foreground, 0.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  verticalAlignment: Text.AlignVCenter
                }
                Button {
                  text: "Close"
                  fontFamily: root.fontFamily
                  active: true
                  onClicked: root.closeHelp()
                }
              }
            }
          }
        }

        Item {
          id: passwordModal
          anchors.fill: parent
          z: 60
          visible: root.passwordOpen

          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.55)
            MouseArea { anchors.fill: parent; onClicked: {} }
          }

          BorderSurface {
            id: passCard
            width: Math.min(parent.width - Style.space(48), Style.space(400))
            height: passCard.contentTopInset + passCard.contentBottomInset + passCol.implicitHeight + Style.space(28)
            anchors.centerIn: parent
            color: root.background
            borderSpec: Border.flat(root.neonColor, Style.normalBorderWidth)
            padding: Style.space(18)
            radius: root.cornerRadius

            MouseArea { anchors.fill: parent; onClicked: {} }

            ColumnLayout {
              id: passCol
              anchors.fill: parent
              anchors.topMargin: passCard.contentTopInset
              anchors.rightMargin: passCard.contentRightInset
              anchors.bottomMargin: passCard.contentBottomInset
              anchors.leftMargin: passCard.contentLeftInset
              spacing: Style.spacing.sm

              Text {
                Layout.fillWidth: true
                text: "Unlock notes"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }

              Text {
                Layout.fillWidth: true
                text: "Your notes are encrypted. Enter the password to decrypt them. The key stays in memory until you press Lock."
                color: Qt.darker(root.foreground, 1.3)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              TextField {
                id: passwordField
                Layout.fillWidth: true
                Layout.topMargin: Style.spacing.sm
                password: true
                placeholderText: "Password"
                foreground: root.foreground
                accent: Color.accent
                onAccepted: root.submitPassword()

                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    root.passwordOpen = false
                    event.accepted = true
                  }
                }
              }

              Text {
                Layout.fillWidth: true
                visible: root.passwordError !== ""
                text: root.passwordError
                color: Color.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.spacing.sm
                Item { Layout.fillWidth: true }
                Button {
                  text: "Cancel"
                  fontFamily: root.fontFamily
                  onClicked: root.passwordOpen = false
                }
                Button {
                  text: "Unlock"
                  fontFamily: root.fontFamily
                  active: true
                  onClicked: root.submitPassword()
                }
              }
            }
          }
        }

        Item {
          id: changeModal
          anchors.fill: parent
          z: 70
          visible: root.changeOpen

          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.55)
            MouseArea { anchors.fill: parent; onClicked: {} }
          }

          BorderSurface {
            id: chgCard
            width: Math.min(parent.width - Style.space(48), Style.space(420))
            height: chgCard.contentTopInset + chgCard.contentBottomInset + chgCol.implicitHeight + Style.space(28)
            anchors.centerIn: parent
            color: root.background
            borderSpec: Border.flat(root.neonColor, Style.normalBorderWidth)
            padding: Style.space(18)
            radius: root.cornerRadius

            MouseArea { anchors.fill: parent; onClicked: {} }

            ColumnLayout {
              id: chgCol
              anchors.fill: parent
              anchors.topMargin: chgCard.contentTopInset
              anchors.rightMargin: chgCard.contentRightInset
              anchors.bottomMargin: chgCard.contentBottomInset
              anchors.leftMargin: chgCard.contentLeftInset
              spacing: Style.spacing.sm

              Text {
                Layout.fillWidth: true
                text: "Change password"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }

              Text {
                Layout.fillWidth: true
                text: "Every note is decrypted and re-encrypted with a new key derived from the new password. The current key is only needed to unlock first."
                color: Qt.darker(root.foreground, 1.3)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              TextField {
                id: chgOldField
                Layout.fillWidth: true
                Layout.topMargin: Style.spacing.sm
                password: true
                placeholderText: "Current password"
                foreground: root.foreground
                accent: Color.accent
                onAccepted: chgNewField.forceActiveFocus()

                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    root.closeChangePass()
                    event.accepted = true
                  }
                }
              }

              TextField {
                id: chgNewField
                Layout.fillWidth: true
                password: true
                placeholderText: "New password (at least 6 characters)"
                foreground: root.foreground
                accent: Color.accent
                onAccepted: chgConfirmField.forceActiveFocus()

                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    root.closeChangePass()
                    event.accepted = true
                  }
                }
              }

              TextField {
                id: chgConfirmField
                Layout.fillWidth: true
                password: true
                placeholderText: "Repeat the new password"
                foreground: root.foreground
                accent: Color.accent
                onAccepted: root.submitChangePass()

                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    root.closeChangePass()
                    event.accepted = true
                  }
                }
              }

              Text {
                Layout.fillWidth: true
                visible: root.changeError !== ""
                text: root.changeError
                color: Color.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.spacing.sm
                Item { Layout.fillWidth: true }
                Button {
                  text: "Cancel"
                  fontFamily: root.fontFamily
                  enabled: !root.changeBusy
                  onClicked: root.closeChangePass()
                }
                Button {
                  text: "Apply"
                  fontFamily: root.fontFamily
                  active: true
                  enabled: !root.changeBusy
                  onClicked: root.submitChangePass()
                }
              }
            }

          }
        }
        Item {
          id: syncModal
          anchors.fill: parent
          z: 80
          visible: root.syncOpen

          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.55)
            MouseArea { anchors.fill: parent; onClicked: {} }
          }

          BorderSurface {
            id: syncCard
            width: Math.min(parent.width - Style.space(48), Style.space(600))
            height: syncCard.contentTopInset + syncCard.contentBottomInset + syncCol.implicitHeight + Style.space(24)
            anchors.centerIn: parent
            color: root.background
            borderSpec: Border.flat(root.neonColor, Style.normalBorderWidth)
            padding: Style.space(16)
            radius: root.cornerRadius

            MouseArea { anchors.fill: parent; onClicked: {} }

            ColumnLayout {
              id: syncCol
              anchors.fill: parent
              anchors.topMargin: syncCard.contentTopInset
              anchors.rightMargin: syncCard.contentRightInset
              anchors.bottomMargin: syncCard.contentBottomInset
              anchors.leftMargin: syncCard.contentLeftInset
              spacing: Style.spacing.sm

              Text {
                Layout.fillWidth: true
                text: "Sync notes"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }

              Text {
                Layout.fillWidth: true
                visible: root.syncStatus !== ""
                text: root.syncStatus === "ok" ? "Sync OK — notes pushed to the remote."
                     : root.syncStatus === "error" ? "Sync FAILED — see the log below."
                     : "Working..."
                color: root.syncStatus === "error" ? Color.urgent : "#77b877"
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              // Live log panel.
              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 170
                color: Qt.rgba(0, 0, 0, 0.28)
                radius: textBoxRadius
                clip: true

                Flickable {
                  id: syncLogFlick
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  contentWidth: width
                  contentHeight: syncLogText.height
                  clip: true

                  Text {
                    id: syncLogText
                    text: root.syncOutput
                    width: syncLogFlick.width
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                  }
                }
              }

              // Remote repository editor.
              RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.spacing.xs
                Text {
                  text: "Git remote"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Item { Layout.fillWidth: true }
              }
              TextField {
                id: syncRemoteField
                Layout.fillWidth: true
                text: root.syncRemoteEdit
                placeholderText: "git@github.com:user/notes.git  (empty = no sync)"
                foreground: root.foreground
                accent: Color.accent
                onTextEdited: root.syncRemoteEdit = text
                onAccepted: root.saveRemote()
              }

              // Actions.
              RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.spacing.xs
                Button {
                  text: "Copy public key"
                  fontFamily: root.fontFamily
                  tooltipText: "Copies ~/.ssh/id_ed25519.pub to paste into GitHub"
                  onClicked: root.copyPubKey()
                }
                Button {
                  text: "SSH key help"
                  fontFamily: root.fontFamily
                  active: root.syncSshOpen
                  tooltipText: "How to generate and register an SSH key"
                  onClicked: root.syncSshOpen = !root.syncSshOpen
                }
                Item { Layout.fillWidth: true }
                Button {
                  text: "Save remote"
                  fontFamily: root.fontFamily
                  tooltipText: "Save this remote into the Quick Notes settings"
                  onClicked: root.saveRemote()
                }
                Button {
                  text: "Sync now"
                  fontFamily: root.fontFamily
                  active: true
                  enabled: !root.syncBusy
                  onClicked: root.startSync()
                }
                Button {
                  text: "Close"
                  fontFamily: root.fontFamily
                  enabled: !root.syncBusy
                  onClicked: root.closeSync()
                }
              }

              // SSH setup guide.
              Rectangle {
                Layout.fillWidth: true
                visible: root.syncSshOpen
                Layout.preferredHeight: root.syncSshOpen ? 150 : 0
                color: Qt.rgba(0, 0, 0, 0.18)
                radius: textBoxRadius
                clip: true

                Flickable {
                  id: syncHelpFlick
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  contentWidth: width
                  contentHeight: syncHelpText.height
                  clip: true
                  Text {
                    id: syncHelpText
                    width: syncHelpFlick.width
                    color: Qt.darker(root.foreground, 1.25)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                    text: "Setting up the SSH key for GitHub:\n\n"
                      + "1.  Generate a key on this machine (skip if you already have one):\n"
                      + "    ssh-keygen -t ed25519 -C \"you@example.com\"\n"
                      + "    Press Enter for the default location and no passphrase.\n\n"
                      + "2.  Make sure the agent has it:\n    ssh-add ~/.ssh/id_ed25519\n\n"
                      + "3.  Copy the PUBLIC key (ends in .pub) — the button above does it.\n\n"
                      + "4.  On github.com: Settings → SSH and GPG keys → New SSH key →\n"
                      + "    paste the key → Add SSH key.\n\n"
                      + "5.  Test the connection:\n    ssh -T git@github.com\n"
                      + "    You should see: \"Hi ghpo! You've successfully authenticated.\"\n\n"
                      + "6.  The remote must use the SSH form git@github.com:user/repo.git\n"
                      + "    (not the https:// form) for the agent key to be used."
                  }
                }
              }
            }
          }
        }
    }
  }
}
