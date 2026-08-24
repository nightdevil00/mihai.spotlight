import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property int scanSerial: 0
  property var fileResults: []
  property var pathBins: ({})
  property var pendingBins: ({})

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(44), Style.font.heading + Style.spacing.controlPaddingY * 2)
  property int rowHeight: Style.space(46)
  property int footerHeight: Style.space(26)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(620), panel.width - Style.gapsOut * 2)
  readonly property int visibleRows: 8
  readonly property int maxApps: 8
  readonly property int maxFiles: 20
  readonly property int maxResults: 30

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.fileResults = []
    root.cancelScan()
    if (!binScan.running) binScan.running = true
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "mihai.spotlight")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function normalizeUrl(value) {
    var s = String(value || "").trim()
    if (!s || /\s/.test(s)) return ""
    if (/^https?:\/\/\S+$/i.test(s)) return s
    if (/^www\.[^\s]+\.[^\s]+$/i.test(s)) return "https://" + s
    if (/^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(:\d+)?([\/?#]\S*)?$/i.test(s))
      return "https://" + s
    return ""
  }

  function escapeRegex(value) {
    return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  }

  function fdPattern(value) {
    var s = String(value || "")
    var out = ""
    for (var i = 0; i < s.length; i++) {
      var c = s.charAt(i)
      if (c === "*" || c === " ") out += ".*"
      else if (c === "?") out += "."
      else out += escapeRegex(c)
    }
    return out
  }

  readonly property var actions: [
    { name: "Take screenshot", subtitle: "Smart capture", icon: "", cmd: "omarchy-capture-screenshot", keywords: "screenshot capture shot snip printscreen" },
    { name: "Screenshot region", subtitle: "Pick an area", icon: "", cmd: "omarchy capture screenshot region", keywords: "screenshot region area selection snip" },
    { name: "Screenshot fullscreen", subtitle: "Whole screen", icon: "", cmd: "omarchy capture screenshot fullscreen", keywords: "screenshot fullscreen entire monitor" },
    { name: "Record screen", subtitle: "Start a screen recording", icon: "󰑋", cmd: "omarchy capture screenrecord --fullscreen", keywords: "record screen video screencast recording" },
    { name: "Lock screen", subtitle: "Lock session", icon: "󰌾", cmd: "omarchy system lock", keywords: "lock screen password session" },
    { name: "Toggle night light", subtitle: "Blue light filter", icon: "󰖙", cmd: "omarchy toggle nightlight", keywords: "night light blue filter warm sunset" }
  ]

  function matchingActions(query) {
    var q = String(query || "").trim().toLowerCase()
    if (q.length < 3) return []
    var terms = q.split(/\s+/)
    var rows = []
    for (var i = 0; i < root.actions.length; i++) {
      var a = root.actions[i]
      var hay = (a.name + " " + a.subtitle + " " + a.keywords).toLowerCase()
      var all = true
      for (var t = 0; t < terms.length; t++) {
        if (hay.indexOf(terms[t]) < 0) { all = false; break }
      }
      if (all) rows.push({ kind: "action", name: a.name, subtitle: a.subtitle, icon: a.icon, arg: a.cmd })
    }
    return rows.slice(0, 4)
  }

  function calcValue(expr) {
    var s = String(expr || "").trim()
      .replace(/[×x]/gi, "*").replace(/÷/g, "/").replace(/,/g, "")
    if (!/^[\d\s+\-*/().]+$/.test(s)) return null
    if (!/[+\-*/]/.test(s.slice(1))) return null

    var tokens = []
    var i = 0
    while (i < s.length) {
      var c = s.charAt(i)
      if (c === " ") { i++; continue }
      if (c >= "0" && c <= "9" || c === ".") {
        var num = ""
        while (i < s.length && ((s.charAt(i) >= "0" && s.charAt(i) <= "9") || s.charAt(i) === ".")) num += s.charAt(i++)
        if ((num.match(/\./g) || []).length > 1) return null
        tokens.push({ t: "num", v: parseFloat(num) })
      } else if ("+-*/()".indexOf(c) >= 0) {
        tokens.push({ t: c })
        i++
      } else {
        return null
      }
    }
    if (tokens.length < 2) return null

    var pos = 0
    function peek() { return pos < tokens.length ? tokens[pos] : null }
    function nextTok() { return pos < tokens.length ? tokens[pos++] : null }
    function parseExpr() {
      var v = parseTerm()
      while (peek() && (peek().t === "+" || peek().t === "-")) {
        var op = nextTok().t
        var r = parseTerm()
        v = op === "+" ? v + r : v - r
      }
      return v
    }
    function parseTerm() {
      var v = parseUnary()
      while (peek() && (peek().t === "*" || peek().t === "/")) {
        var op = nextTok().t
        var r = parseUnary()
        if (op === "/") {
          if (r === 0) throw "div0"
          v = v / r
        } else v = v * r
      }
      return v
    }
    function parseUnary() {
      var tk = peek()
      if (tk && tk.t === "-") { nextTok(); return -parseUnary() }
      if (tk && tk.t === "+") { nextTok(); return parseUnary() }
      return parsePrimary()
    }
    function parsePrimary() {
      var tk = nextTok()
      if (!tk) throw "eof"
      if (tk.t === "num") return tk.v
      if (tk.t === "(") {
        var v = parseExpr()
        var cl = nextTok()
        if (!cl || cl.t !== ")") throw "paren"
        return v
      }
      throw "token"
    }

    try {
      var val = parseExpr()
      if (pos !== tokens.length || typeof val !== "number" || isNaN(val) || !isFinite(val)) return null
      return Math.round(val * 1e10) / 1e10
    } catch (e) {
      return null
    }
  }

  function formatNumber(n) {
    var s = String(n)
    if (Math.abs(n) >= 1e15 || (n !== 0 && Math.abs(n) < 1e-9)) return n.toExponential(6)
    return s
  }

  function extensionQuery(q) {
    var s = String(q || "").trim().toLowerCase()
    if (!/^\*?\.[a-z0-9]+(\.[a-z0-9]+)*$/.test(s)) return []
    return s.replace(/^\*\./, ".").split(".").filter(function(x) { return x.length > 0 })
  }

  function cdTarget(q) {
    var m = /^cd\s+(\S+)\s*$/i.exec(String(q || "").trim())
    if (!m) return ""
    var p = m[1]
    if (p === "~") p = Quickshell.env("HOME")
    else if (p.indexOf("~/") === 0) p = Quickshell.env("HOME") + p.slice(1)
    p = p.replace(/\/+$/, "")
    return p.length > 0 ? p : "/"
  }

  readonly property var fallbackWrappers: ["sudo", "doas", "env", "time", "watch", "nohup", "xargs", "strace"]

  function commandQuery(q) {
    var s = String(q || "").trim()
    if (!/\s/.test(s)) return ""
    var first = s.split(/\s+/)[0]
    if (first.indexOf("/") >= 0) return s
    if (root.pathBins[first] !== undefined) return s
    return root.fallbackWrappers.indexOf(first) >= 0 ? s : ""
  }

  readonly property var tuiCommands: [
    "vim", "nvim", "vi", "nano", "micro", "hx", "helix", "emacs",
    "less", "more", "top", "htop", "btop", "iotop", "iftop", "bottom",
    "lazygit", "lazydocker", "tig", "ranger", "nnn", "yazi", "mc",
    "nmtui", "alsamixer", "pulsemixer", "fzf", "cmus", "newsboat",
    "weechat", "irssi", "mutt", "neomutt", "aerc", "w3m", "lynx", "links",
    "cava", "gtop", "vtop", "s-tui", "bmon", "cmatrix"
  ]

  function termAt(dir) {
    return "uwsm-app -- xdg-terminal-exec --dir=" + Util.shellQuote(dir)
  }

  // Interactive TUIs own the screen and close when quit; everything else
  // (fastfetch, echo, pacman queries…) keeps the terminal open so output
  // stays readable.
  function termRun(cmd) {
    var s = String(cmd || "").trim()
    var first = (s.split(/\s+/)[0] || "").toLowerCase()
    var interactive = root.tuiCommands.indexOf(first) >= 0
    return "uwsm-app -- xdg-terminal-exec -- bash -lc "
      + Util.shellQuote(interactive ? s : s + "; exec bash")
  }

  readonly property var standardFolders: [
    { name: "Downloads", path: "~/Downloads" },
    { name: "Documents", path: "~/Documents" },
    { name: "Pictures", path: "~/Pictures" },
    { name: "Videos", path: "~/Videos" },
    { name: "Music", path: "~/Music" },
    { name: "Desktop", path: "~/Desktop" },
    { name: "Home", path: "~" },
    { name: "Omarchy config", path: "~/.config/omarchy" },
    { name: "Hyprland config", path: "~/.config/hypr" }
  ]

  function matchingFolders(q) {
    var s = String(q || "").trim().toLowerCase()
    if (s.length === 0) return []
    var rows = []
    for (var i = 0; i < root.standardFolders.length; i++) {
      var f = root.standardFolders[i]
      if (f.name.toLowerCase().indexOf(s) >= 0 || f.path.toLowerCase().indexOf(s) >= 0)
        rows.push({ kind: "folder", name: f.name, subtitle: f.path, icon: "󰉋", arg: f.path })
    }
    return rows.slice(0, 4)
  }

  function binaryMatches(q, takenNames) {
    var s = String(q || "").trim().toLowerCase()
    if (s.length === 0 || /\s/.test(s)) return []
    var rows = []
    for (var name in root.pathBins) {
      var sc = -1
      if (name === s) sc = 100
      else if (name.indexOf(s) === 0) sc = 80 - name.length
      else if (name.indexOf(s) > 0) sc = 60 - name.indexOf(s)
      if (sc < 0) continue
      if (takenNames && takenNames[name] !== undefined) continue
      rows.push({ score: sc, kind: "binary", name: "Run " + name, subtitle: root.pathBins[name], icon: "", arg: name })
    }
    rows.sort(function(a, b) { return b.score - a.score })
    return rows.slice(0, 4)
  }

  function appName(entry) {
    return String((entry && entry.name) || (entry && entry.id) || "")
  }

  function appSubtext(entry) {
    return String((entry && entry.genericName) || "")
  }

  function appKeywords(entry) {
    try {
      if (entry && entry.keywords && typeof entry.keywords.join === "function") return entry.keywords.join(" ")
    } catch (e) {}
    return ""
  }

  function appHaystack(entry) {
    return [entry.name, entry.genericName, entry.comment, appKeywords(entry), entry.id].join(" ").toLowerCase()
  }

  function appAcronym(entry) {
    var values = String([entry.name, entry.genericName, appKeywords(entry), entry.id].join(" "))
      .replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/[._:/\\-]+/g, " ").toLowerCase().split(/[^a-z0-9]+/)
    var out = ""
    for (var i = 0; i < values.length; i++) if (values[i]) out += values[i].charAt(0)
    return out
  }

  function appScore(entry, term) {
    var name = appName(entry).toLowerCase()
    var id = String((entry && entry.id) || "").toLowerCase()
    if (name.indexOf(term) === 0) return 10000 - name.length
    if (id.indexOf(term) === 0) return 9500 - id.length
    if (name.indexOf(term) > 0) return 8000 - name.indexOf(term) * 10 - name.length
    var hayIndex = appHaystack(entry).indexOf(term)
    if (hayIndex >= 0) return 6000 - hayIndex
    var acronymIndex = appAcronym(entry).indexOf(term)
    if (acronymIndex >= 0) return 4600 - acronymIndex * 10 - acronymIndex
    return -1
  }

  function sortedApps(query) {
    var values = DesktopEntries.applications.values || []
    var q = String(query || "").trim().toLowerCase()
    var terms = q ? q.split(/\s+/) : []
    var rows = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (!entry || entry.noDisplay) continue
      var name = appName(entry)
      if (!name) continue
      if (terms.length > 0) {
        var score = 0
        for (var t = 0; t < terms.length; t++) {
          var s = appScore(entry, terms[t])
          if (s < 0) { score = -1; break }
          score += s
        }
        if (score < 0) continue
      }
      rows.push({ entry: entry, name: name.toLowerCase(), score: score })
    }
    rows.sort(function(a, b) {
      if (q && a.score !== b.score) return b.score - a.score
      if (a.name < b.name) return -1
      if (a.name > b.name) return 1
      return 0
    })
    return rows.slice(0, root.maxApps)
  }

  function appIconSource(iconName) {
    var v = String(iconName || "")
    if (v.indexOf("/") === 0) return Util.fileUrl(v)
    if (v.length > 0) {
      var themed = Quickshell.iconPath(v, true)
      if (themed.length > 0) return themed
    }
    return Quickshell.iconPath("application-x-executable", true)
  }

  function cancelScan() {
    root.scanSerial++
    if (fileScan.running) fileScan.running = false
  }

  function startFileScan() {
    if (!root.opened) return
    var q = root.filterText.trim()
    root.scanSerial++
    if (q.length < 2) {
      root.fileResults = []
      root.rebuildDisplay()
      return
    }
    if (fileScan.running) fileScan.running = false
    var exts = extensionQuery(q)
    var head = "fd -p --hidden --absolute-path"
      + " --exclude .cache --exclude node_modules --exclude .local/share/Trash --exclude .git"
    var cmd
    if (exts.length > 0) {
      cmd = head + " --type f --print0 --max-results 80"
      for (var i = 0; i < exts.length; i++) cmd += " -e " + Util.shellQuote(exts[i])
      cmd += " -- " + Util.shellQuote("") + " " + Util.shellQuote(Quickshell.env("HOME"))
    } else {
      cmd = head + " --type f --type d --print0 --max-results 80"
        + " -- " + Util.shellQuote(fdPattern(q)) + " " + Util.shellQuote(Quickshell.env("HOME"))
    }
    cmd += " 2>/dev/null"
      + " | xargs -0 -r stat -c '%Y|%n' 2>/dev/null"
      + " | sort -t'|' -k1,1rn"
      + " | head -n " + root.maxFiles
      + " | cut -d'|' -f2-"
    fileScan.serial = root.scanSerial
    fileScan.command = ["bash", "-c", cmd]
    fileScan.running = true
  }

  function applyFileResults(buffer) {
    if (!root.opened) return
    var lines = String(buffer || "").split("\n")
    var rows = []
    for (var i = 0; i < lines.length && rows.length < root.maxFiles; i++) {
      var path = lines[i]
      if (!path) continue
      var slash = path.lastIndexOf("/")
      var base = slash >= 0 ? path.slice(slash + 1) : path
      var dir = slash >= 0 ? path.slice(0, slash) : "~"
      var dot = base.lastIndexOf(".")
      rows.push({
        kind: "file",
        name: base,
        subtitle: dir,
        icon: dot > 0 ? "󰈚" : "󰉋",
        arg: path
      })
    }
    root.fileResults = rows
    root.rebuildDisplay()
  }

  function rebuildDisplay() {
    displayModel.clear()

    var q = root.filterText.trim()
    if (q) {
      var calc = calcValue(q)
      if (calc !== null)
        displayModel.append({ kind: "calc", name: q + " = " + formatNumber(calc), subtitle: "Press ↵ to copy", icon: "", arg: String(calc) })

      var url = normalizeUrl(q)
      if (url)
        displayModel.append({ kind: "url", name: "Open in browser", subtitle: url, icon: "", arg: url })

      var cd = cdTarget(q)
      if (cd)
        displayModel.append({ kind: "term-dir", name: "Open terminal at " + cd, subtitle: q, icon: "", arg: cd })

      var cmd = commandQuery(q)
      if (cmd)
        displayModel.append({ kind: "term-cmd", name: "Run in terminal", subtitle: cmd, icon: "", arg: cmd })

      var taken = {}
      for (var t = 0; t < displayModel.count; t++) {
        var nm = String(displayModel.get(t).name || "").toLowerCase()
        if (nm) taken[nm] = true
      }

      var bins = binaryMatches(extensionQuery(q).length > 0 ? "" : q, taken)
      for (var b = 0; b < bins.length && displayModel.count < root.maxResults; b++)
        displayModel.append(bins[b])

      var acts = matchingActions(q)
      for (var a = 0; a < acts.length && displayModel.count < root.maxResults; a++)
        displayModel.append(acts[a])

      var folders = matchingFolders(q)
      for (var f = 0; f < folders.length && displayModel.count < root.maxResults; f++)
        displayModel.append(folders[f])
    }

    var apps = sortedApps(q)
    for (var i = 0; i < apps.length && displayModel.count < root.maxResults; i++) {
      var e = apps[i].entry
      displayModel.append({ kind: "app", name: appName(e), subtitle: appSubtext(e), icon: String(e.icon || ""), arg: String(e.id || "") })
    }

    for (var j = 0; j < root.fileResults.length && displayModel.count < root.maxResults; j++)
      displayModel.append(root.fileResults[j])

    if (displayModel.count === 0) root.selectedIndex = 0
    else if (root.selectedIndex >= displayModel.count) root.selectedIndex = displayModel.count - 1
  }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
    root.rebuildDisplay()
    fileDebounce.restart()
  }

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (!row.arg) return
    root.dismiss()
    if (row.kind === "app")
      Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(row.arg + ".desktop"))
    else if (row.kind === "calc")
      Util.execDetached("printf %s " + Util.shellQuote(row.arg) + " | wl-copy")
    else if (row.kind === "action")
      Util.execDetached(row.arg)
    else if (row.kind === "term-dir")
      Util.execDetached(termAt(row.arg))
    else if (row.kind === "binary" || row.kind === "term-cmd")
      Util.execDetached(termRun(row.arg))
    else if (row.kind === "folder")
      Util.execDetached("xdg-open " + Util.shellQuote(row.arg.indexOf("~/") === 0 ? Quickshell.env("HOME") + row.arg.slice(1) : row.arg))
    else
      Util.execDetached("xdg-open " + Util.shellQuote(row.arg))
  }

  function debugState() {
    return JSON.stringify({
      opened: root.opened,
      filter: root.filterText,
      fileResults: root.fileResults.length,
      pathBins: Object.keys(root.pathBins).length,
      rows: displayModel.count,
      delegates: resultList.count,
      listH: resultList.height,
      listW: resultList.width,
      cardH: card.height,
      serial: root.scanSerial
    })
  }

  ListModel { id: displayModel }

  Timer {
    id: fileDebounce
    interval: 180
    onTriggered: root.startFileScan()
  }

  Process {
    id: fileScan
    property string buffer: ""
    property int serial: 0
    command: []
    stdout: SplitParser {
      onRead: function(line) { fileScan.buffer += line + "\n" }
    }
    onStarted: fileScan.buffer = ""
    onExited: if (fileScan.serial === root.scanSerial) root.applyFileResults(fileScan.buffer)
  }

  Process {
    id: binScan
    command: ["bash", "-c", "IFS=:; for d in $PATH; do [[ -d $d ]] && find \"$d\" -maxdepth 1 -type f -executable -printf '%f\\t%p\\n' 2>/dev/null; done"]
    stdout: SplitParser {
      onRead: function(line) {
        var tab = line.indexOf("\t")
        if (tab <= 0) return
        var name = line.slice(0, tab)
        if (root.pendingBins[name] === undefined) root.pendingBins[name] = line.slice(tab + 1)
      }
    }
    onStarted: root.pendingBins = ({})
    onExited: root.pathBins = root.pendingBins
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "mihai-spotlight"
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
      height: root.headerHeight + root.contentSpacing
        + (displayModel.count > 0 ? Math.min(displayModel.count, root.visibleRows) * root.rowHeight : 0)
        + root.footerHeight + root.contentMargin * 2
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Math.max(Style.space(80), panel.height * 0.12)
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            if (displayModel.count > 0)
              root.selectedIndex = (root.selectedIndex - 1 + displayModel.count) % displayModel.count
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            if (displayModel.count > 0)
              root.selectedIndex = (root.selectedIndex + 1) % displayModel.count
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            if (displayModel.count > 0) root.selectedIndex = 0
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            if (displayModel.count > 0) root.selectedIndex = displayModel.count - 1
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activateIndex(root.selectedIndex)
            event.accepted = true
          } else if ((event.modifiers & ~Qt.ShiftModifier) === 0
                     && event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          color: "transparent"

          Row {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Text {
              text: "󰍉"
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              width: parent.width - 40
              text: root.filterText || "Search apps, files, extensions, commands, math, URLs…"
              color: root.foreground
              opacity: root.filterText ? 1 : 0.58
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              elide: Text.ElideRight
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: root.foreground
          opacity: 0.08
        }

        Item {
          width: parent.width
          height: Math.max(0, parent.height - root.headerHeight - root.footerHeight - root.contentSpacing * 2 - 1)

          ListView {
            id: resultList
            anchors.fill: parent
            model: displayModel
            clip: true
            interactive: false
            boundsBehavior: Flickable.StopAtBounds

            Connections {
              target: root
              function onSelectedIndexChanged() {
                resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
              }
            }

            delegate: Rectangle {
              id: rowDelegate
              required property int index
              required property string kind
              required property string name
              required property string subtitle
              required property string icon
              required property string arg

              readonly property bool hasCursor: index === root.selectedIndex

              width: resultList.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) root.selectedIndex = rowDelegate.index
                onClicked: root.activateIndex(rowDelegate.index)
              }

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(10)

                Item {
                  width: Style.space(30)
                  height: parent.height

                  Image {
                    visible: rowDelegate.kind === "app"
                    anchors.centerIn: parent
                    width: Style.space(24)
                    height: Style.space(24)
                    source: visible ? root.appIconSource(rowDelegate.icon) : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                  }

                  Text {
                    visible: rowDelegate.kind !== "app"
                    anchors.centerIn: parent
                    text: rowDelegate.kind === "url" ? "" : rowDelegate.icon
                    color: root.foreground
                    opacity: 0.75
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                  }
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(48)
                  spacing: 1

                  Text {
                    width: parent.width
                    text: rowDelegate.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    visible: rowDelegate.subtitle.length > 0
                    text: rowDelegate.subtitle
                    color: root.foreground
                    opacity: 0.55
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                }
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: displayModel.count === 0 && root.filterText.length > 0
            text: "No results for “" + root.filterText + "”"
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
        }

        Item {
          width: parent.width
          height: root.footerHeight

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "↵ open   ·   ↑↓ navigate   ·   *.ext files   ·   cd dir   ·   esc close"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
