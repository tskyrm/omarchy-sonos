import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Sonos for the Omarchy bar: a pill with what the main room is playing and a
// popup controlling every room. All speaker I/O lives in bin/sonos-bar, a
// long-running SoCo daemon that prints a JSON snapshot whenever state changes
// and takes JSON commands on stdin.
Panel {
  id: root
  moduleName: "tskyrm.sonos"
  ipcTarget: "sonos"
  manageIpc: false

  // ------------------------------------------------------------------ theme

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  // --------------------------------------------------------------- settings

  readonly property string room: String(setting("room", ""))
  readonly property bool showLabel: setting("showLabel", true) !== false
  readonly property int maxLabelWidth: Number(setting("maxLabelWidth", 220)) || 220
  readonly property int volumeStep: Math.max(1, Number(setting("volumeStep", 2)) || 2)
  readonly property string pythonSetting: String(setting("python", ""))

  readonly property string home: Quickshell.env("HOME") || ""
  // bin/launch sets up its own venv with SoCo on first run unless a
  // python is configured.
  readonly property string launcher: Model.localPath(Qt.resolvedUrl("bin/launch"))
  readonly property var daemonCommand: pythonSetting !== ""
    ? [launcher, Model.expandPath(pythonSetting, home)]
    : [launcher]

  // ------------------------------------------------------------------- data

  property var groups: []
  property var speakers: []
  property var favorites: []
  property string errorText: ""
  property string commandError: ""
  property bool connected: false
  property double snapshotMs: Date.now()
  property double nowMs: Date.now()
  property string selectedGroupId: ""
  property string editingGroupId: ""

  // "rooms" or "sxm" (the SiriusXM channel picker).
  property string view: "rooms"
  property var sxmChannels: []
  property string sxmError: ""
  property bool sxmLoading: false
  property string sxmQuery: ""
  property string sxmCategory: "Music"

  readonly property var sxmCategories: {
    var seen = []
    for (var i = 0; i < sxmChannels.length; i++) {
      var c = sxmChannels[i].category
      if (c && seen.indexOf(c) < 0) seen.push(c)
    }
    return ["All"].concat(seen)
  }

  readonly property var sxmFiltered: {
    var q = sxmQuery.trim().toLowerCase()
    return sxmChannels.filter(function(c) {
      // A search looks across every category.
      if (q === "") return sxmCategory === "All" || c.category === sxmCategory
      return c.name.toLowerCase().indexOf(q) >= 0
        || c.genre.toLowerCase().indexOf(q) >= 0
        || String(c.number) === q
    })
  }

  function openSxm() {
    view = "sxm"
    if (sxmChannels.length === 0 && !sxmLoading) {
      sxmLoading = true
      sxmError = ""
      send({ cmd: "sxmlist" })
    }
    if (panelFlick) panelFlick.contentY = 0
  }

  function closeSxm() {
    view = "rooms"
    sxmQuery = ""
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function playSxm(channel) {
    if (!selectedGroup || !channel) return
    send({ cmd: "sxm", group: selectedGroup.id, uuid: channel.uuid, name: channel.name, number: channel.number })
  }

  // Repeaters are keyed on these id lists, which are only reassigned when
  // membership actually changes. Handing a Repeater the fresh snapshot
  // arrays would rebuild every card on every poll, killing slider drags.
  property var groupIds: []
  property var speakerIds: []

  function sameList(a, b) {
    return a.length === b.length && a.every(function(v, i) { return v === b[i] })
  }

  function speakerName(uid) {
    for (var i = 0; i < speakers.length; i++) if (speakers[i].uid === uid) return speakers[i].name
    return ""
  }

  readonly property var primary: Model.primaryGroup(groups, room)
  readonly property var selectedGroup: Model.findGroup(groups, selectedGroupId) || primary
  readonly property int playingCount: groups.filter(function(g) { return g.playing }).length
  readonly property string barLabel: Model.trackLine(primary)
  readonly property bool hasTrack: !!primary && barLabel !== ""
  readonly property string heroMeta: {
    if (!connected) return errorText !== "" ? errorText : "Looking for speakers"
    var parts = []
    if (playingCount > 0) parts.push(playingCount + " playing")
    parts.push(speakers.length + (speakers.length === 1 ? " speaker" : " speakers"))
    return parts.join(" · ")
  }

  function send(obj) {
    if (!daemon.running) return
    daemon.write(JSON.stringify(obj) + "\n")
  }

  // ---------------------------------------------------------------- volume
  //
  // A volume the user picked wins over polled values until the speaker
  // reports it back (or a few seconds pass), so sliders never snap to a
  // stale reading mid-drag or right after release. Writes are throttled to
  // the latest value per target.

  property var pendingVolumes: ({})
  property var queuedVolumes: ({})

  function groupVolumeKey(id) { return "group:" + id }
  function speakerVolumeKey(uid) { return "speaker:" + uid }

  function shownVolume(key, actual) {
    var p = pendingVolumes[key]
    return p ? p.value : actual
  }

  function groupVolume(group) {
    return group ? shownVolume(groupVolumeKey(group.id), group.volume) : 0
  }

  function setVolume(key, cmd, value) {
    var v = Math.max(0, Math.min(100, Math.round(value)))
    var pending = Object.assign({}, pendingVolumes)
    pending[key] = { value: v, expires: Date.now() + 4000 }
    pendingVolumes = pending
    var queued = Object.assign({}, queuedVolumes)
    queued[key] = Object.assign({}, cmd, { value: v })
    queuedVolumes = queued
    if (!volumeFlush.running) volumeFlush.start()
  }

  function setGroupVolume(group, value) {
    if (group) setVolume(groupVolumeKey(group.id), { cmd: "volume", group: group.id }, value)
  }

  function setSpeakerVolume(uid, value) {
    setVolume(speakerVolumeKey(uid), { cmd: "speakervolume", uid: uid }, value)
  }

  function nudgeGroupVolume(group, delta) {
    if (group) setGroupVolume(group, groupVolume(group) + delta)
  }

  // Drop pending values the speakers now agree with, or that timed out.
  function reconcileVolumes() {
    var keys = Object.keys(pendingVolumes)
    if (keys.length === 0) return
    var actual = {}
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i]
      actual[groupVolumeKey(g.id)] = g.volume
      for (var j = 0; j < g.members.length; j++) actual[speakerVolumeKey(g.members[j].uid)] = g.members[j].volume
    }
    var now = Date.now()
    var next = {}
    var changed = false
    for (var k = 0; k < keys.length; k++) {
      var p = pendingVolumes[keys[k]]
      if (queuedVolumes[keys[k]] || (p.expires > now && actual[keys[k]] !== p.value)) next[keys[k]] = p
      else changed = true
    }
    if (changed) pendingVolumes = next
  }

  Timer {
    id: volumeFlush
    interval: 120
    onTriggered: {
      var queued = root.queuedVolumes
      root.queuedVolumes = ({})
      for (var key in queued) root.send(queued[key])
      // Extend the hold from the moment the value actually went out.
      var pending = Object.assign({}, root.pendingVolumes)
      for (var k in queued) if (pending[k]) pending[k] = { value: pending[k].value, expires: Date.now() + 4000 }
      root.pendingVolumes = pending
    }
  }

  Timer {
    interval: 1000
    running: Object.keys(root.pendingVolumes).length > 0
    repeat: true
    onTriggered: root.reconcileVolumes()
  }

  function applyLine(line) {
    var obj = Model.parseLine(line)
    if (!obj) return
    if (obj.commandError !== undefined) {
      commandError = String(obj.commandError)
      errorClear.restart()
      return
    }
    if (obj.sxm !== undefined || obj.sxmError !== undefined) {
      sxmLoading = false
      if (obj.sxm) sxmChannels = obj.sxm
      sxmError = obj.sxmError ? String(obj.sxmError) : ""
      return
    }
    groups = obj.groups || []
    speakers = obj.speakers || []
    var nextFavorites = obj.favorites || []
    if (!sameList(favorites, nextFavorites)) favorites = nextFavorites
    var nextGroupIds = groups.map(function(g) { return g.id })
    if (!sameList(groupIds, nextGroupIds)) groupIds = nextGroupIds
    var nextSpeakerIds = speakers.map(function(s) { return s.uid })
    if (!sameList(speakerIds, nextSpeakerIds)) speakerIds = nextSpeakerIds
    if (editingGroupId !== "" && nextGroupIds.indexOf(editingGroupId) < 0) editingGroupId = ""
    connected = obj.ok === true
    errorText = obj.error ? String(obj.error) : ""
    snapshotMs = Date.now()
    nowMs = snapshotMs
    reconcileVolumes()
  }

  // Seconds into the track, extrapolated between polls while playing.
  function livePosition(group) {
    if (!group) return 0
    var pos = group.position || 0
    if (group.playing) pos += (nowMs - snapshotMs) / 1000
    return group.duration > 0 ? Math.min(pos, group.duration) : pos
  }

  Process {
    id: daemon
    command: root.daemonCommand
    running: true
    stdinEnabled: true

    stdout: SplitParser {
      onRead: function(line) { root.applyLine(line) }
    }

    stderr: SplitParser {
      onRead: function(line) { console.warn(String(line)) }
    }

    onStarted: root.send({ cmd: "active", value: root.opened })

    onExited: function(exitCode, exitStatus) {
      root.connected = false
      root.errorText = "sonos-bar exited (" + exitCode + "); restarting"
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 5000
    onTriggered: daemon.running = true
  }

  Timer {
    id: errorClear
    interval: 6000
    onTriggered: root.commandError = ""
  }

  Timer {
    interval: 1000
    running: root.opened && root.playingCount > 0
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  onOpenedChanged: {
    send({ cmd: "active", value: opened })
    if (opened) {
      send({ cmd: "refresh" })
      if (!Model.findGroup(groups, selectedGroupId)) selectedGroupId = primary ? primary.id : ""
      if (panelFlick) panelFlick.contentY = 0
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      view = "rooms"
      sxmQuery = ""
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function playpause(): void { if (root.primary) root.send({ cmd: "playpause", group: root.primary.id }) }
    function next(): void { if (root.primary) root.send({ cmd: "next", group: root.primary.id }) }
    function previous(): void { if (root.primary) root.send({ cmd: "previous", group: root.primary.id }) }
    function volumeUp(): void { root.nudgeGroupVolume(root.primary, root.volumeStep) }
    function volumeDown(): void { root.nudgeGroupVolume(root.primary, -root.volumeStep) }
    function pauseAll(): void { root.send({ cmd: "pauseall" }) }
    function siriusxm(): void { root.open(); root.openSxm() }
    function text(): string { return root.barLabel }
  }

  // -------------------------------------------------------------------- bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    dimmed: !root.primary || !root.primary.playing
    tooltipText: root.connected ? Model.tooltip(root.groups) : "Sonos: " + root.heroMeta
    fixedWidth: root.vertical ? -1 : Math.ceil(content.implicitWidth + button.scaledHorizontalMargin * 2)
    fixedHeight: root.vertical ? Math.ceil(content.implicitHeight + button.scaledVerticalPadding * 2) : -1

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) {
        if (root.primary) root.send({ cmd: "playpause", group: root.primary.id })
      } else {
        root.toggle()
      }
    }

    onWheelMoved: function(delta) {
      root.nudgeGroupVolume(root.primary, delta > 0 ? root.volumeStep : -root.volumeStep)
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: root.primary && root.primary.playing ? "󰓃" : "󰓄"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.bar.iconFont
        renderType: Text.NativeRendering
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.vertical && root.showLabel && root.hasTrack
        text: root.barLabel
        width: Math.min(implicitWidth, root.maxLabelWidth)
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
      }
    }
  }

  // ------------------------------------------------------------------ popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(960))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Typing goes to the channel search while it has focus.
      blocked: sxmSearch.activeFocus
      onCloseRequested: root.view === "sxm" ? root.closeSxm() : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: if (root.view === "rooms" && root.selectedGroup) root.send({ cmd: "playpause", group: root.selectedGroup.id })
      onMoveRequested: function(dx, dy) {
        if (root.view !== "rooms" || dy === 0 || root.groups.length === 0) return
        var idx = 0
        for (var i = 0; i < root.groups.length; i++) if (root.groups[i].id === root.selectedGroupId) idx = i
        idx = Math.max(0, Math.min(root.groups.length - 1, idx + dy))
        root.selectedGroupId = root.groups[idx].id
      }
      onTextKey: function(text) {
        var g = root.selectedGroup
        if (root.view === "sxm") {
          root.sxmQuery += text
          sxmSearch.forceActiveFocus()
          return
        }
        if (text === "s") root.openSxm()
        else if (text === "r") root.send({ cmd: "rescan" })
        else if (!g) return
        else if (text === " " || text === "p") root.send({ cmd: "playpause", group: g.id })
        else if (text === "n") root.send({ cmd: "next", group: g.id })
        else if (text === "b") root.send({ cmd: "previous", group: g.id })
        else if (text === "+" || text === "=") root.nudgeGroupVolume(g, root.volumeStep)
        else if (text === "-") root.nudgeGroupVolume(g, -root.volumeStep)
        else if (text === "m") root.send({ cmd: "mute", group: g.id, value: !g.muted })
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: panelColumn
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.view === "sxm" ? "SiriusXM" : "Sonos"
            meta: root.view === "sxm"
              ? (root.sxmLoading ? "Loading channels" : root.sxmFiltered.length + (root.sxmFiltered.length === 1 ? " channel" : " channels"))
              : root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.view === "sxm" ? "󰐹" : "󰓃"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.spacing.sm

                PanelActionButton {
                  iconText: "󰏤"
                  tooltipText: "Pause all rooms"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  visible: root.view === "rooms"
                  enabled: root.playingCount > 0
                  onClicked: root.send({ cmd: "pauseall" })
                }

                PanelActionButton {
                  iconText: "󰐹"
                  tooltipText: "SiriusXM channels (s)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  visible: root.view === "rooms"
                  enabled: root.groups.length > 0
                  onClicked: root.openSxm()
                }

                PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: root.view === "sxm" ? "Reload channel list from siriusxm.com" : "Find speakers again (r)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !root.sxmLoading
                  onClicked: {
                    if (root.view === "rooms") {
                      root.send({ cmd: "rescan" })
                    } else {
                      root.sxmLoading = true
                      root.send({ cmd: "sxmlist", force: true })
                    }
                  }
                }

                PanelActionButton {
                  iconText: "󰅖"
                  tooltipText: "Back to rooms (Esc)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  visible: root.view === "sxm"
                  onClicked: root.closeSxm()
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.commandError !== ""
            width: parent.width
            text: root.commandError
            color: root.bar ? root.bar.urgent : Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Column {
            id: roomsView
            visible: root.view === "rooms"
            width: parent.width
            spacing: Style.space(12)

          Repeater {
            model: root.groupIds

            GroupCard {
              required property var modelData
              width: panelColumn.width
              groupId: modelData
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.groups.length === 0
            width: parent.width
            text: root.connected ? "No rooms" : "Scanning the network for Sonos speakers…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            visible: root.favorites.length > 0
            foreground: root.foreground
          }

          PanelSectionHeader {
            visible: root.favorites.length > 0
            width: parent.width
            text: "FAVORITES" + (root.selectedGroup ? "  →  " + root.selectedGroup.name.toUpperCase() : "")
            foreground: root.foreground
            fontFamily: root.fontFamily
            elide: Text.ElideRight
          }

          Flow {
            visible: root.favorites.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.favorites

              Button {
                required property var modelData
                required property int index
                text: modelData
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                enabled: !!root.selectedGroup
                onClicked: root.send({ cmd: "favorite", group: root.selectedGroup.id, index: index })
              }
            }
          }
          }

          // ---------------------------------------------------- SiriusXM
          Column {
            id: sxmView
            visible: root.view === "sxm"
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              width: parent.width
              text: "PLAY ON"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.groupIds

                Button {
                  required property var modelData
                  readonly property var group: Model.findGroup(root.groups, modelData)
                  text: group ? group.name : ""
                  selected: !!root.selectedGroup && root.selectedGroup.id === modelData
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.selectedGroupId = modelData
                }
              }
            }

            TextField {
              id: sxmSearch
              width: parent.width
              placeholderText: "Search channels, genres or numbers"
              text: root.sxmQuery
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onTextEdited: root.sxmQuery = text
              Keys.onEscapePressed: {
                if (root.sxmQuery !== "") root.sxmQuery = ""
                else root.closeSxm()
              }
              Keys.onReturnPressed: if (root.sxmFiltered.length > 0) root.playSxm(root.sxmFiltered[0])
              Keys.onDownPressed: keyCatcher.forceActiveFocus()
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)
              visible: root.sxmQuery === "" && root.sxmCategories.length > 1

              Repeater {
                model: root.sxmCategories

                Button {
                  required property var modelData
                  text: modelData
                  selected: root.sxmCategory === modelData
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: {
                    root.sxmCategory = modelData
                    if (panelFlick) panelFlick.contentY = 0
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.sxmError !== "" ? root.sxmError
                : root.sxmLoading ? "Fetching the lineup from siriusxm.com…"
                : root.sxmFiltered.length === 0 ? "No matching channels" : ""
              color: root.sxmError !== "" ? (root.bar ? root.bar.urgent : Color.urgent) : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: root.view === "sxm" ? root.sxmFiltered : []

                ChannelRow {
                  required property var modelData
                  width: sxmView.width
                  channel: modelData
                }
              }
            }
          }
        }
      }
    }
  }

  // One SiriusXM channel: number, name, genre. Click to play on the
  // selected room; the channel that room is on is highlighted.
  component ChannelRow: CursorSurface {
    id: channelRow
    property var channel: null
    readonly property bool playingHere: !!channel && !!root.selectedGroup && root.selectedGroup.sxm === channel.uuid

    current: playingHere
    hasCursor: rowMouse.containsMouse
    foreground: root.foreground
    implicitHeight: Math.max(channelName.implicitHeight, channelNumber.implicitHeight) + Style.space(12)

    Text {
      id: channelNumber
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(34)
      text: channelRow.channel && channelRow.channel.number ? channelRow.channel.number : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      id: channelName
      textFormat: Text.PlainText
      anchors.left: channelNumber.right
      anchors.right: channelGenre.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: (channelRow.playingHere ? "󰓃 " : "") + (channelRow.channel ? channelRow.channel.name : "")
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: channelRow.playingHere
      elide: Text.ElideRight
    }

    Text {
      id: channelGenre
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, Style.space(120))
      text: channelRow.channel ? channelRow.channel.genre : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignRight
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.playSxm(channelRow.channel)
    }
  }

  // One room or group: art, track, transport, volume, membership.
  component GroupCard: CursorSurface {
    id: card
    property string groupId: ""
    readonly property var group: Model.findGroup(root.groups, groupId)

    readonly property bool selected: !!group && !!root.selectedGroup && root.selectedGroup.id === group.id
    readonly property bool multi: !!group && group.members.length > 1
    readonly property bool editing: root.editingGroupId === groupId
    property var memberIds: []

    onGroupChanged: {
      var next = group ? group.members.map(function(m) { return m.uid }) : []
      if (!root.sameList(memberIds, next)) memberIds = next
    }

    current: selected
    bordered: !selected
    foreground: root.foreground
    implicitHeight: cardColumn.implicitHeight + Style.space(20)

    MouseArea {
      anchors.fill: parent
      onClicked: if (card.group) root.selectedGroupId = card.group.id
    }

    Column {
      id: cardColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      spacing: Style.space(8)

      Row {
        width: parent.width
        spacing: Style.space(10)

        BorderSurface {
          id: art
          width: Style.space(56)
          height: Style.space(56)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(root.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

          Image {
            id: artImage
            anchors.fill: parent
            anchors.margins: Style.space(2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            sourceSize.width: 128
            sourceSize.height: 128
            source: card.group && card.group.art ? card.group.art : ""
            visible: status === Image.Ready
          }

          Text {
            anchors.centerIn: parent
            visible: artImage.status !== Image.Ready
            text: card.group && card.group.radio ? "󰐹" : (card.group && card.group.lineIn ? "󰡁" : "󰝚")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
          }
        }

        Column {
          width: parent.width - art.width - Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          PanelSectionHeader {
            width: parent.width
            text: card.group ? (card.group.name + "  ·  " + Model.stateLabel(card.group)).toUpperCase() : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: card.group && card.group.title ? card.group.title : "Nothing queued"
            color: card.group && card.group.title ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: text !== ""
            text: card.group ? [card.group.artist, card.group.album].filter(function(s) { return !!s }).join("  ·  ") : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      // Track progress; radio and line-in have no duration.
      Item {
        visible: !!card.group && card.group.duration > 0
        width: parent.width
        height: Style.space(14)

        Rectangle {
          id: progressTrack
          anchors.left: parent.left
          anchors.right: elapsed.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          height: Style.space(3)
          radius: height / 2
          color: root.track

          Rectangle {
            height: parent.height
            radius: parent.radius
            color: root.foreground
            width: card.group && card.group.duration > 0
              ? parent.width * Math.min(1, root.livePosition(card.group) / card.group.duration)
              : 0
          }
        }

        Text {
          id: elapsed
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: card.group ? Model.clock(root.livePosition(card.group)) + " / " + Model.clock(card.group.duration) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // Transport + group volume.
      Row {
        width: parent.width
        spacing: Style.space(4)

        PanelActionButton {
          iconText: "󰒮"
          tooltipText: "Previous"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !!card.group && !card.group.radio && !card.group.lineIn && !!card.group.title
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.send({ cmd: "previous", group: card.group.id })
        }

        PanelActionButton {
          iconText: card.group && card.group.playing ? "󰏤" : "󰐊"
          tooltipText: card.group && card.group.playing ? "Pause" : "Play"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !!card.group && !!card.group.title
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.send({ cmd: "playpause", group: card.group.id })
        }

        PanelActionButton {
          iconText: "󰒭"
          tooltipText: "Next"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !!card.group && !card.group.radio && !card.group.lineIn && !!card.group.title
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.send({ cmd: "next", group: card.group.id })
        }

        Item { width: Style.space(6); height: 1 }

        PanelActionButton {
          iconText: "󰌹"
          tooltipText: card.editing ? "Done grouping" : "Group speakers with this room"
          foreground: root.foreground
          fontFamily: root.fontFamily
          visible: root.speakers.length > 1
          bordered: card.editing
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.editingGroupId = card.editing ? "" : card.groupId
        }

        PanelActionButton {
          id: muteButton
          iconText: card.group && card.group.muted ? "󰝟" : "󰕾"
          tooltipText: card.group && card.group.muted ? "Unmute" : "Mute"
          foreground: root.foreground
          fontFamily: root.fontFamily
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.send({ cmd: "mute", group: card.group.id, value: !card.group.muted })
        }

        PanelSlider {
          id: groupSlider
          bar: root.bar
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - x - groupPct.width - Style.space(4)
          minimum: 0
          maximum: 100
          step: root.volumeStep
          integer: true
          value: root.groupVolume(card.group)
          opacity: card.group && card.group.muted ? 0.5 : 1.0
          onMoved: function(v) { root.setGroupVolume(card.group, v) }
          onReleased: function(v) { root.setGroupVolume(card.group, v) }
          onRightClicked: root.send({ cmd: "mute", group: card.group.id, value: !card.group.muted })
        }

        Text {
          id: groupPct
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(30)
          horizontalAlignment: Text.AlignRight
          text: Math.round(groupSlider.liveValue)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      // Per-speaker volume when grouped.
      Repeater {
        model: card.memberIds.length > 1 ? card.memberIds : []

        Row {
          id: memberRow
          required property var modelData
          readonly property var member: {
            var members = card.group ? card.group.members : []
            for (var i = 0; i < members.length; i++) if (members[i].uid === modelData) return members[i]
            return { uid: modelData, name: root.speakerName(modelData), volume: 0, muted: false }
          }
          width: cardColumn.width
          spacing: Style.space(8)

          Text {
            id: memberName
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(96)
            text: memberRow.member.name
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          PanelSlider {
            id: memberSlider
            bar: root.bar
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - memberName.width - memberPct.width - Style.space(16)
            minimum: 0
            maximum: 100
            step: root.volumeStep
            integer: true
            value: root.shownVolume(root.speakerVolumeKey(memberRow.modelData), memberRow.member.volume)
            onMoved: function(v) { root.setSpeakerVolume(memberRow.modelData, v) }
            onReleased: function(v) { root.setSpeakerVolume(memberRow.modelData, v) }
          }

          Text {
            id: memberPct
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(30)
            horizontalAlignment: Text.AlignRight
            text: Math.round(memberSlider.liveValue)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Membership chips, shown while this card's group button is on:
      // ✓ = in this group, + = elsewhere. Tap to pull a speaker in or send
      // it back to its own room.
      Flow {
        visible: root.speakers.length > 1 && card.editing
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: card.editing ? root.speakerIds : []

          Button {
            id: chip
            required property var modelData
            readonly property bool member: card.memberIds.indexOf(modelData) >= 0
            readonly property var otherGroup: member ? null : Model.groupOfSpeaker(root.groups, modelData)
            readonly property bool isCoordinator: modelData === card.groupId
            text: (member ? "󰄬 " : "󰐕 ") + root.speakerName(modelData)
            selected: member
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            // The room the card is named after stays put; ungroup the others.
            enabled: !isCoordinator
            tooltipText: isCoordinator ? "This room"
              : member ? "Remove from this group"
              : otherGroup && otherGroup.members.length > 1 ? "Move here from " + otherGroup.name
              : "Add to this group"
            onClicked: {
              if (chip.member) root.send({ cmd: "unjoin", uid: modelData })
              else root.send({ cmd: "join", uid: modelData, group: card.groupId })
            }
          }
        }
      }
    }
  }
}
