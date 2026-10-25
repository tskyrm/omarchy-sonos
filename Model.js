.pragma library

function localPath(url) {
  var s = String(url || "")
  return s.indexOf("file://") === 0 ? decodeURIComponent(s.slice(7)) : s
}

function expandPath(path, home) {
  var s = String(path || "")
  return s.indexOf("~/") === 0 ? home + s.slice(1) : s
}

function parseLine(line) {
  try {
    var obj = JSON.parse(String(line || ""))
    return obj && typeof obj === "object" ? obj : null
  } catch (e) {
    return null
  }
}

// The group the bar follows: the configured room's group, else the first
// playing group, else anything with a track.
function primaryGroup(groups, room) {
  if (!groups || groups.length === 0) return null
  var wanted = String(room || "").toLowerCase()
  if (wanted !== "") {
    for (var i = 0; i < groups.length; i++) {
      var names = groups[i].names || []
      for (var j = 0; j < names.length; j++)
        if (String(names[j]).toLowerCase() === wanted) return groups[i]
    }
  }
  for (var k = 0; k < groups.length; k++) if (groups[k].playing) return groups[k]
  for (var m = 0; m < groups.length; m++) if (groups[m].title) return groups[m]
  return groups[0]
}

function findGroup(groups, id) {
  if (!groups) return null
  for (var i = 0; i < groups.length; i++) if (groups[i].id === id) return groups[i]
  return null
}

function groupOfSpeaker(groups, uid) {
  if (!groups) return null
  for (var i = 0; i < groups.length; i++) {
    var members = groups[i].members || []
    for (var j = 0; j < members.length; j++) if (members[j].uid === uid) return groups[i]
  }
  return null
}

function trackLine(group) {
  if (!group || !group.title) return ""
  return group.title + (group.artist ? "  ·  " + group.artist : "")
}

function stateLabel(group) {
  if (!group) return ""
  if (group.playing) return "Playing"
  if (group.state === "PAUSED_PLAYBACK") return "Paused"
  return group.title ? "Stopped" : "Idle"
}

function clock(seconds) {
  var s = Math.max(0, Math.floor(seconds || 0))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var r = s % 60
  var mm = h > 0 && m < 10 ? "0" + m : String(m)
  return (h > 0 ? h + ":" : "") + mm + ":" + (r < 10 ? "0" + r : r)
}

function tooltip(groups) {
  if (!groups || groups.length === 0) return "Sonos: no speakers"
  var lines = []
  for (var i = 0; i < groups.length; i++) {
    var g = groups[i]
    var line = g.name + " — " + stateLabel(g)
    if (g.title) line += ": " + trackLine(g).replace("  ·  ", " · ")
    lines.push(line)
  }
  return lines.join("\n")
}
