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

  // Omarchy menu integration: parsed + merged JSONC sources (default menu
  // + the user extension at ~/.config/omarchy/extensions/omarchy-menu.jsonc),
  // plus the batched `when:`/`checked:` guard results.
  property var defaultMenuItems: []
  property var userMenuItems: []
  property var menuItems: ({})
  property var menuOrder: []
  property var whenResults: ({})
  property var checkedResults: ({})
  property bool menuRowsLoaded: false
  property bool menuGuardsPending: false
  readonly property string defaultMenuPath: root.omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
  readonly property string userMenuPath: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
  readonly property int maxMenuRows: 8
  readonly property int maxMenuListRows: 200
  property string activeMenu: "root"
  property var menuNav: []
  property bool fontRowsLoaded: false
  property var fontRows: []
  readonly property string fontProviderScript: "current=$(omarchy-font-current 2>/dev/null); omarchy-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done"

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
    root.activeMenu = "root"
    root.menuNav = []
    root.fileResults = []
    root.cancelScan()
    if (!binScan.running) binScan.running = true
    if (!root.menuRowsLoaded) {
      defaultMenuFile.reload()
      userMenuFile.reload()
    } else {
      root.evaluateMenuGuards()
    }
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

  // ------------------------------------------------------------------
  // Omarchy menu integration. Parses the same JSONC sources the
  // `omarchy.menu` plugin uses, merges user overrides on top of the
  // defaults, evaluates every `when:`/`checked:` guard in one batch, and
  // exposes the whole tree in Spotlight itself: submenu rows drill into
  // their section right here (no external menu summons), action rows run
  // their command directly, and the provider-backed menus (Apps, Fonts)
  // surface their rows natively.
  // ------------------------------------------------------------------

  function stripMenuJsonc(raw) {
    return String(raw || "")
      .replace(/^\s*\/\/[^\n]*(\n|$)/gm, "")
      .replace(/,(\s*[}\]])/g, "$1")
  }

  function normalizeMenuAliases(value) {
    if (Array.isArray(value)) return value.filter(function(v) { return v })
    if (typeof value === "string" && value) return [value]
    return []
  }

  function normalizeMenuItem(id, raw) {
    var value = raw || {}
    var aliases = root.normalizeMenuAliases(value.aliases)
    var parent = value.parent
    if (parent === undefined)
      parent = id.indexOf(".") >= 0 ? id.split(".").slice(0, -1).join(".") : "root"
    if (id === "root") parent = ""
    var kind = value.action ? "action" : (value.target ? "link" : "menu")
    return {
      id: id,
      parent: parent,
      kind: kind,
      icon: value.icon || "",
      label: value.label || id,
      target: value.target || "",
      description: value.description || "",
      action: value.action || "",
      provider: value.provider || "",
      aliases: aliases,
      when: value.when || "",
      checked: value.checked || ""
    }
  }

  function parseMenuJsonc(raw) {
    var stripped = root.stripMenuJsonc(raw)
    if (!stripped.trim()) return []
    var parsed
    try { parsed = JSON.parse(stripped) } catch (e) { return [] }
    if (typeof parsed !== "object" || parsed === null) return []
    var source = (parsed.items && typeof parsed.items === "object" && !Array.isArray(parsed.items))
      ? parsed.items
      : parsed
    var out = []
    for (var id in source) {
      var entry = source[id]
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue
      out.push(root.normalizeMenuItem(id, entry))
    }
    return out
  }

  function mergeMenuSources(defaultItems, userItems) {
    var nextItems = ({})
    var nextOrder = []
    var sources = [defaultItems || [], userItems || []]
    for (var s = 0; s < sources.length; s++) {
      var src = sources[s]
      for (var i = 0; i < src.length; i++) {
        var entry = src[i]
        if (!entry || !entry.id) continue
        if (!nextItems[entry.id]) nextOrder.push(entry.id)
        var prior = nextItems[entry.id] || {}
        var merged = {}
        for (var k in prior) merged[k] = prior[k]
        for (var k2 in entry) merged[k2] = entry[k2]
        merged.id = entry.id
        nextItems[entry.id] = merged
      }
    }
    if (!nextItems.root) {
      nextItems.root = { id: "root", parent: "", kind: "menu", icon: "", label: "Go", target: "", description: "", action: "", provider: "", aliases: [], when: "", checked: "" }
      nextOrder.unshift("root")
    }
    for (var k3 = 0; k3 < nextOrder.length; k3++) nextItems[nextOrder[k3]].order = k3
    return { items: nextItems, itemOrder: nextOrder }
  }

  function rebuildMenuItems() {
    var merged = root.mergeMenuSources(root.defaultMenuItems, root.userMenuItems)
    root.menuItems = merged.items
    root.menuOrder = merged.itemOrder
    root.menuRowsLoaded = true
    root.evaluateMenuGuards()
    if (root.opened) root.rebuildDisplay()
  }

  function menuItemById(id) {
    return root.menuItems[id] || null
  }

  function menuDepth(id) {
    var depth = 0
    var current = root.menuItemById(id)
    var guard = 0
    while (current && current.parent && current.parent !== "root" && guard < 24) {
      depth += 1
      current = root.menuItemById(current.parent)
      guard += 1
    }
    return depth
  }

  function menuParentPath(id) {
    var labels = []
    var current = root.menuItemById(id)
    if (!current || !current.parent || current.parent === "root") return ""
    current = root.menuItemById(current.parent)
    var guard = 0
    while (current && current.id !== "root" && guard < 24) {
      labels.unshift(current.label)
      current = root.menuItemById(current.parent)
      guard += 1
    }
    return labels.join(" › ")
  }

  function menuHasVisibleChild(targetId, depth) {
    if (depth === undefined) depth = 0
    if (depth >= 16) return false
    for (var i = 0; i < root.menuOrder.length; i++) {
      var child = root.menuItemById(root.menuOrder[i])
      if (child && child.parent === targetId && root.menuItemVisible(child, depth + 1)) return true
    }
    return false
  }

  function menuItemVisible(entry, depth) {
    if (!entry) return false
    if (entry.when && root.whenResults[entry.id] === false) return false
    if (entry.kind !== "menu" && entry.kind !== "link") return true
    if (entry.provider) return true
    var target = entry.kind === "link" ? entry.target : entry.id
    return root.menuHasVisibleChild(target, depth || 0)
  }

  function menuSearchText(entry) {
    var aliases = ""
    var values = Array.isArray(entry.aliases) ? entry.aliases : []
    for (var i = 0; i < values.length; i++)
      if (values[i]) aliases += " " + String(values[i]).replace(/[._-]+/g, " ")
    var leaf = String(entry.id.split(".").pop() || "").replace(/[._-]+/g, " ")
    return (entry.label + " " + leaf + aliases).toLowerCase()
  }

  function menuDescriptionHasTerm(term, text) {
    var words = String(text || "").toLowerCase().split(/\s+/)
    for (var i = 0; i < words.length; i++) if (words[i] === term) return true
    return false
  }

  function menuMatches(entry, terms) {
    var nameText = root.menuSearchText(entry)
    var descriptionText = String(entry.description || "").toLowerCase()
    for (var i = 0; i < terms.length; i++) {
      if (!terms[i]) continue
      if (nameText.indexOf(terms[i]) >= 0) continue
      if (root.menuDescriptionHasTerm(terms[i], descriptionText)) continue
      return false
    }
    return true
  }

  function menuSearchScore(entry, query) {
    var needle = String(query || "").toLowerCase().trim()
    var label = entry.label.toLowerCase()
    var nameText = root.menuSearchText(entry)
    var descriptionText = String(entry.description || "").toLowerCase()
    var score = 80
    if (label === needle) score = entry.parent === "root" ? 2 : 0
    else if (label.indexOf(needle) === 0) score = 10
    else if (label.indexOf(needle) >= 0) score = 30
    else if (nameText.indexOf(needle) >= 0) score = 40
    else if (root.menuDescriptionHasTerm(needle, descriptionText)) score = 60
    if (entry.kind === "menu" || entry.kind === "link") score -= 2
    return score * 1000 + root.menuDepth(entry.id) * 25 + entry.order
  }

  function matchingMenuRows(query, taken) {
    var q = String(query || "").trim().toLowerCase()
    if (q.length < 2) return []
    var terms = q.split(/\s+/)
    var rows = []
    for (var i = 0; i < root.menuOrder.length; i++) {
      var entry = root.menuItemById(root.menuOrder[i])
      if (!entry || entry.id === "root") continue
      if (!root.menuItemVisible(entry)) continue
      if (!root.menuInScope(entry.id)) continue
      if (!root.menuMatches(entry, terms)) continue
      var label = entry.checked && root.checkedResults[entry.id] ? entry.label + " ✓" : entry.label
      var takenName = label.toLowerCase()
      if (taken && taken[takenName] !== undefined) continue
      var parent = root.menuParentPath(entry.id)
      var row = {
        kind: entry.action ? "action" : "menu",
        name: label,
        subtitle: parent || entry.description || "Omarchy menu",
        icon: entry.icon || "",
        arg: entry.action || "",
        menuId: entry.id
      }
      row.menuScore = root.menuSearchScore(entry, q)
      if (taken) taken[takenName] = true
      rows.push(row)
    }
    rows.sort(function(a, b) { return a.menuScore - b.menuScore })
    return rows.slice(0, root.maxMenuRows)
  }

  // The root view of the Omarchy menu: its top-level sections (Apps, Learn,
  // Trigger, Style, ...) listed in menu order, guards applied. This is what
  // Spotlight shows when it opens, so it starts exactly like the real menu.
  function menuRootRows(taken) {
    var rows = []
    for (var i = 0; i < root.menuOrder.length; i++) {
      var entry = root.menuItemById(root.menuOrder[i])
      if (!entry || entry.id === "root" || entry.parent !== "root") continue
      if (!root.menuItemVisible(entry)) continue
      var label = entry.checked && root.checkedResults[entry.id] ? entry.label + " ✓" : entry.label
      var takenName = label.toLowerCase()
      if (taken && taken[takenName] !== undefined) continue
      rows.push({
        kind: "menu",
        name: label,
        subtitle: entry.description || "Omarchy menu",
        icon: entry.icon || "",
        arg: "",
        menuId: entry.id
      })
      if (taken) taken[takenName] = true
    }
    return rows
  }

  // ---- in-Spotlight menu navigation -------------------------------------
  //
  // Spotlight is the menu: activating a submenu row drills into its section
  // here, action rows run their command, links follow their target, and the
  // external menu plugin is never summoned.

  function menuEntryTarget(id) {
    var entry = root.menuItemById(id)
    return entry && entry.kind === "link" && entry.target ? entry.target : id
  }

  function menuGoTo(id) {
    var target = root.menuEntryTarget(id)
    if (!root.menuItems[target]) return
    root.menuNav = root.menuNav.concat([root.activeMenu])
    root.activeMenu = target
    root.filterText = ""
    root.selectedIndex = 0
    if (target === "style.font") root.startFontProvider()
    root.rebuildDisplay()
  }

  function menuGoBack() {
    if (root.activeMenu === "root") return
    var previous = "root"
    if (root.menuNav.length > 0) {
      previous = root.menuNav[root.menuNav.length - 1]
      root.menuNav = root.menuNav.slice(0, root.menuNav.length - 1)
    } else {
      var cur = root.menuItemById(root.activeMenu)
      previous = cur && cur.parent ? cur.parent : "root"
    }
    root.activeMenu = previous
    root.filterText = ""
    root.selectedIndex = 0
    root.rebuildDisplay()
  }

  function menuBreadcrumb() {
    if (root.activeMenu === "root") return ""
    var labels = []
    var cur = root.menuItemById(root.activeMenu)
    var guard = 0
    while (cur && cur.id !== "root" && guard < 24) {
      labels.unshift(cur.label)
      cur = root.menuItemById(cur.parent)
      guard += 1
    }
    return labels.join(" › ")
  }

  function headerHint() {
    if (root.filterText) return root.filterText
    if (root.activeMenu === "root")
      return "Search apps, files, extensions, commands, math, URLs…"
    return "‹ " + root.menuBreadcrumb()
  }

  // Search is scoped to the current menu, mirroring the real menu: at the
  // root it covers the whole tree; inside a submenu only that subtree.
  function menuInScope(id) {
    if (root.activeMenu === "root") return true
    var cur = root.menuItemById(id)
    while (cur && cur.id !== "root") {
      if (cur.id === root.activeMenu) return true
      cur = root.menuItemById(cur.parent)
    }
    return false
  }

  function menuChildRows(taken) {
    var rows = []
    for (var i = 0; i < root.menuOrder.length; i++) {
      var entry = root.menuItemById(root.menuOrder[i])
      if (!entry || entry.parent !== root.activeMenu) continue
      if (!root.menuItemVisible(entry)) continue
      var label = entry.checked && root.checkedResults[entry.id] ? entry.label + " ✓" : entry.label
      var takenName = label.toLowerCase()
      if (taken && taken[takenName] !== undefined) continue
      var isAction = entry.kind === "action" && entry.action
      rows.push({
        kind: isAction ? "action" : "menu",
        name: label,
        subtitle: entry.description || (entry.provider ? "Opening…" : ""),
        icon: entry.icon || "",
        arg: entry.action || "",
        menuId: entry.id
      })
      if (taken) taken[takenName] = true
    }
    return rows
  }

  function appRows(query, taken) {
    var apps = root.sortedApps(query || "")
    var rows = []
    for (var i = 0; i < apps.length; i++) {
      var e = apps[i].entry
      var name = root.appName(e)
      var takenName = name.toLowerCase()
      if (taken && taken[takenName] !== undefined) continue
      rows.push({ kind: "app", name: name, subtitle: root.appSubtext(e), icon: String(e.icon || ""), arg: String(e.id || "") })
      if (taken) taken[takenName] = true
    }
    return rows
  }

  // The font list is a shell provider in the real menu; mirror it so Style ›
  // Font stays functional inside Spotlight.
  function parseFontRows(output) {
    var lines = String(output || "").split("\n")
    var rows = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var parts = line.split("\t")
      var label = parts[0] || ""
      var value = parts[1] || parts[0] || ""
      var current = parts[2] || ""
      if (!label) continue
      rows.push({
        kind: "action",
        name: label,
        subtitle: value === current ? "Current font" : "Set as default",
        icon: value === current ? "✓" : "",
        arg: value === current ? "" : "omarchy-font-set " + Util.shellQuote(value)
      })
    }
    return rows
  }

  function startFontProvider() {
    if (root.fontRowsLoaded || fontProc.running) return
    fontProc.collected = ""
    fontProc.command = ["bash", "-lc", root.fontProviderScript]
    fontProc.running = true
  }

  function matchingFontRows(query, taken) {
    var q = String(query || "").trim().toLowerCase()
    var rows = []
    for (var i = 0; i < root.fontRows.length; i++) {
      var row = root.fontRows[i]
      if (q && row.name.toLowerCase().indexOf(q) < 0) continue
      var takenName = row.name.toLowerCase()
      if (taken && taken[takenName] !== undefined) continue
      rows.push(row)
      if (taken) taken[takenName] = true
    }
    return rows.slice(0, root.maxMenuRows)
  }

  // ---- when:/checked: guards, batched into one bash process like the menu.

  readonly property var menuGuardReaders: [
    "omarchy-channel-current",
    "omarchy-default-agent",
    "omarchy-default-browser",
    "omarchy-default-editor",
    "omarchy-default-terminal",
    "omarchy-dns"
  ]

  function menuGuardReaderSlot(index) {
    return "${__omarchy_read_" + index + "}"
  }

  function menuSubstituteGuardReaders(expression) {
    for (var i = 0; i < root.menuGuardReaders.length; i++)
      expression = expression.split("$(" + root.menuGuardReaders[i] + ")").join(root.menuGuardReaderSlot(i))
    return expression
  }

  function menuGuardHelpers() {
    return 'declare -A __omarchy_pkgs=()\n'
      + 'mapfile -t __omarchy_pkg_names < <({ pacman -Qq; LC_ALL=C pacman -Qi'
      + " | awk '/^[A-Za-z]/ { provides = ($0 ~ /^Provides/); sub(/^[^:]*: /, \"\") }"
      + ' provides && $0 != "None" { n = split($0, p, " ");'
      + ' for (i = 1; i <= n; i++) { sub(/[<>=].*/, "", p[i]); print p[i] } }\'; } 2>/dev/null)\n'
      + 'for __omarchy_pkg in "${__omarchy_pkg_names[@]}"; do __omarchy_pkgs[$__omarchy_pkg]=1; done\n'
      + '__omarchy_pkg_has() { [[ -n ${__omarchy_pkgs[$1]-} ]] && return 0; '
      + '[[ $1 == *[\\<\\>=]* ]] && { pacman -Q "$1" &>/dev/null; return; }; return 1; }\n'
      + 'omarchy-pkg-present() { local p; for p in "$@"; do __omarchy_pkg_has "$p" || return 1; done; return 0; }\n'
      + 'omarchy-pkg-missing() { local p; for p in "$@"; do __omarchy_pkg_has "$p" || return 0; done; return 1; }\n'
      + 'omarchy-cmd-present() { local c; for c in "$@"; do command -v "$c" &>/dev/null || return 1; done; return 0; }\n'
      + 'omarchy-cmd-missing() { local c; for c in "$@"; do command -v "$c" &>/dev/null || return 0; done; return 1; }\n'
  }

  function menuGuardPrelude(guards) {
    var prelude = root.menuGuardHelpers()
    for (var i = 0; i < root.menuGuardReaders.length; i++) {
      if (guards.indexOf(root.menuGuardReaderSlot(i)) < 0) continue
      prelude += "__omarchy_read_" + i + "=$(" + root.menuGuardReaders[i] + " 2>/dev/null) || :\n"
    }
    return prelude
  }

  function menuGuardLine(id, tag, expression) {
    return "if { " + root.menuSubstituteGuardReaders(expression) + "; } >/dev/null 2>&1; then echo "
      + id + ":" + tag + ":1; else echo " + id + ":" + tag + ":0; fi\n"
  }

  function menuGuardScript() {
    var guards = ""
    var ids = Object.keys(root.menuItems || {})
    for (var i = 0; i < ids.length; i++) {
      var entry = root.menuItems[ids[i]]
      if (!entry) continue
      if (entry.when) guards += root.menuGuardLine(ids[i], "w", entry.when)
      if (entry.checked) guards += root.menuGuardLine(ids[i], "c", entry.checked)
    }
    return guards ? root.menuGuardPrelude(guards) + guards : ""
  }

  function evaluateMenuGuards() {
    if (menuGuardProc.running) {
      root.menuGuardsPending = true
      return
    }
    root.menuGuardsPending = false
    var script = root.menuGuardScript()
    if (!script) {
      root.whenResults = ({})
      root.checkedResults = ({})
      return
    }
    menuGuardProc.collected = ""
    menuGuardProc.command = ["bash", "-lc", script]
    menuGuardProc.running = true
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
    var activeEntry = root.menuItemById(root.activeMenu)
    var activeProvider = activeEntry && activeEntry.provider ? activeEntry.provider : ""

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

      if (activeProvider === "apps") {
        var appSearch = root.appRows(q, taken)
        for (var as2 = 0; as2 < appSearch.length && displayModel.count < root.maxResults; as2++)
          displayModel.append(appSearch[as2])
      } else if (activeProvider === "fonts") {
        var fontSearch = root.matchingFontRows(q, taken)
        for (var fs2 = 0; fs2 < fontSearch.length && displayModel.count < root.maxResults; fs2++)
          displayModel.append(fontSearch[fs2])
      } else {
        var bins = binaryMatches(extensionQuery(q).length > 0 ? "" : q, taken)
        for (var b = 0; b < bins.length && displayModel.count < root.maxResults; b++)
          displayModel.append(bins[b])

        var acts = matchingActions(q)
        for (var a = 0; a < acts.length && displayModel.count < root.maxResults; a++)
          displayModel.append(acts[a])

        for (var t2 = 0; t2 < displayModel.count; t2++) {
          var nm2 = String(displayModel.get(t2).name || "").toLowerCase()
          if (nm2) taken[nm2] = true
        }

        var menuRows = matchingMenuRows(q, taken)
        for (var m = 0; m < menuRows.length && displayModel.count < root.maxResults; m++)
          displayModel.append(menuRows[m])

        if (root.activeMenu === "root") {
          var folders = matchingFolders(q)
          for (var f = 0; f < folders.length && displayModel.count < root.maxResults; f++)
            displayModel.append(folders[f])

          var appRowsSearch = root.appRows(q, taken)
          for (var ap2 = 0; ap2 < appRowsSearch.length && displayModel.count < root.maxResults; ap2++)
            displayModel.append(appRowsSearch[ap2])
        }
      }
    } else if (root.activeMenu === "root") {
      var takenRoot = {}
      var menuRoots = root.menuRootRows(takenRoot)
      for (var mr = 0; mr < menuRoots.length && displayModel.count < root.maxResults; mr++)
        displayModel.append(menuRoots[mr])
    } else if (activeProvider === "apps") {
      var appList = root.appRows("", {})
      for (var al = 0; al < appList.length && displayModel.count < root.maxMenuListRows; al++)
        displayModel.append(appList[al])
    } else if (activeProvider === "fonts") {
      if (root.fontRowsLoaded) {
        for (var fr = 0; fr < root.fontRows.length && displayModel.count < root.maxMenuListRows; fr++)
          displayModel.append(root.fontRows[fr])
      } else {
        displayModel.append({ kind: "action", name: "Loading fonts…", subtitle: "", icon: "", arg: "" })
        root.startFontProvider()
      }
    } else {
      var takenChild = {}
      var children = root.menuChildRows(takenChild)
      for (var mc = 0; mc < children.length && displayModel.count < root.maxMenuListRows; mc++)
        displayModel.append(children[mc])
    }

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
    if (!row.arg && !row.menuAction && row.kind !== "menu") return
    if (row.kind === "menu") {
      if (row.menuAction) {
        root.dismiss()
        Util.execDetached(row.menuAction)
      } else {
        root.menuGoTo(row.menuId || "")
      }
      return
    }
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

  Process {
    id: fontProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { fontProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0 && exitStatus === 0) {
        root.fontRows = root.parseFontRows(fontProc.collected)
        root.fontRowsLoaded = true
        if (root.opened) root.rebuildDisplay()
      }
    }
  }

  FileView {
    id: defaultMenuFile
    path: root.defaultMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.defaultMenuItems = root.parseMenuJsonc(text()); root.rebuildMenuItems() }
    onFileChanged: reload()
  }

  FileView {
    id: userMenuFile
    path: root.userMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.userMenuItems = root.parseMenuJsonc(text()); root.rebuildMenuItems() }
    onLoadFailed: { root.userMenuItems = []; root.rebuildMenuItems() }
    onFileChanged: reload()
  }

  Process {
    id: menuGuardProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { menuGuardProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      var healthy = exitCode === 0 && exitStatus === 0
      if (!healthy) {
        if (root.menuGuardsPending) Qt.callLater(function() { root.evaluateMenuGuards() })
        return
      }
      var nextWhen = ({})
      var nextChecked = ({})
      var lines = menuGuardProc.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (!line) continue
        var colon = line.lastIndexOf(":")
        if (colon < 0) continue
        var value = line.substring(colon + 1) === "1"
        var rest = line.substring(0, colon)
        var tagAt = rest.lastIndexOf(":")
        if (tagAt < 0) continue
        var id = rest.substring(0, tagAt)
        var tag = rest.substring(tagAt + 1)
        if (tag === "w") nextWhen[id] = value
        else if (tag === "c") nextChecked[id] = value
      }
      root.whenResults = nextWhen
      root.checkedResults = nextChecked
      if (root.opened) root.rebuildDisplay()
      if (root.menuGuardsPending) Qt.callLater(function() { root.evaluateMenuGuards() })
    }
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
            else if (root.activeMenu !== "root") root.menuGoBack()
            else root.dismiss()
            event.accepted = true
          } else if ((event.key === Qt.Key_Backspace || event.key === Qt.Key_Left) && !root.filterText) {
            root.menuGoBack()
            event.accepted = true
          } else if (event.key === Qt.Key_Right) {
            if (displayModel.count > 0) {
              var rightRow = displayModel.get(root.selectedIndex)
              if (rightRow.kind === "menu") root.menuGoTo(rightRow.menuId || "")
            }
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
              text: root.filterText || root.headerHint()
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
            text: "↵ open   ·   ← back   ·   ↑↓ navigate   ·   *.ext files   ·   cd dir   ·   esc close"
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
