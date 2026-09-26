pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "." as Local

// Headless singleton behind the Chime bar widget. The shell mounts one of
// these however many bar surfaces (monitors) carry the widget, so alarms,
// timers, the stopwatch and the world clocks have a single owner, the
// `chime` IPC target is registered exactly once, and a ring plays once.
//
// Everything is stored as instants, never as counters: a timer is its end
// time, the stopwatch is when it last started plus what it had banked, an
// alarm is a time of day plus the occurrence it last fired for. The clock
// tick only asks "is anything due?", which is the same question after a
// restart or a night asleep — and anything more than a few minutes overdue
// is reported as missed instead of going off late.
//
// State lives in $XDG_STATE_HOME/chime/state.json, written atomically a
// beat after every change. The ring is a layer-shell card on every screen
// plus a looping sound; both stop together.
Item {
  id: root

  // Injected by the shell host.
  property var shell: null

  readonly property string pluginId: "io.github.nousd.chime"
  readonly property string ipcTarget: "chime"

  // ---- Settings. They live inline on the widget's bar entries in shell.json,
  //      read here from the shell's own config so every surface sees one
  //      answer. A split layout has two entries: the first one's values win,
  //      which is also the entry `omarchy bar set` writes, so what is set is
  //      what runs.
  readonly property var settingsMerged: mergeSettings(shell ? shell.barConfig : null)

  function mergeSettings(config) {
    var out = {}
    var layout = Util.isPlainObject(config) && Util.isPlainObject(config.layout) ? config.layout : null
    if (!layout) return out
    var regions = ["left", "center", "right"]
    for (var r = 0; r < regions.length; r++) {
      var entries = Array.isArray(layout[regions[r]]) ? layout[regions[r]] : []
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i]
        if (!Util.isPlainObject(entry) || rawEntryId(entry) !== pluginId) continue
        for (var key in entry) {
          if (key !== "id" && out[key] === undefined) out[key] = entry[key]
        }
      }
    }
    return out
  }

  function setting(name, fallback) {
    var value = settingsMerged[name]
    return value === undefined || value === null || value === "" ? fallback : value
  }

  readonly property bool hour12: Model.toBool(setting("hour12", false), false)
  readonly property int snoozeMinutes: Model.clampInt(setting("snoozeMinutes", 9), 1, 180, 9)
  readonly property int ringSeconds: Model.clampInt(setting("ringSeconds", 300), 5, 3600, 300)
  readonly property int quickTimerMinutes: Model.clampInt(setting("quickTimerMinutes", 5), 1, 720, 5)
  readonly property bool muted: Model.toBool(setting("mute", false), false)
  readonly property string defaultSound: "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"
  readonly property string soundPath: String(setting("sound", defaultSound))

  // ---- State. Arrays are reassigned, never mutated, so bindings notice.
  property var alarms: []
  property var timers: []
  property var stopwatch: Model.emptyStopwatch()
  property var clocks: []
  property bool stateLoaded: false
  property bool dirReady: false
  property bool saveWanted: false
  // Set while an unreadable state file is being moved aside, so nothing is
  // written over it in the meantime.
  property bool saveBlocked: false
  property bool saveFailureReported: false

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
  readonly property string stateDir: stateHome + "/chime"
  readonly property string statePath: stateDir + "/state.json"

  // ---- Time. `nowMs` moves with the system clock: every second while
  //      something counts, every minute otherwise, which is all an alarm or
  //      a world clock needs.
  property double nowMs: Date.now()
  readonly property int localOffsetMin: -new Date(nowMs).getTimezoneOffset()
  readonly property bool anyTimerRunning: timers.some(function(t) { return t.running === true })
  readonly property bool anyRunning: anyTimerRunning || stopwatch.running === true
  readonly property var nextAlarm: Model.nextAlarm(alarms, nowMs)

  // The clock only moves on ticks; an action that starts something counting
  // wants the readout right from this instant, not from the last tick.
  function touchNow() {
    nowMs = Date.now()
  }

  // ---- World clocks. Offsets come from `date` under TZ=, refreshed on the
  //      half hour and whenever the list changes; the shell's JavaScript has
  //      no Intl, so this is the honest way to know what time it is in
  //      Kolkata. The zone picker's options load lazily from tzdata's own
  //      tables the first time the world tab opens.
  property var offsets: ({})
  property double offsetsAt: 0
  property bool offsetsPending: false
  property var zoneOptions: []
  property bool zonesLoaded: false
  property bool zonesRequested: false
  property string zoneTabText: ""
  property string countryText: ""

  // ---- Ringing. { events: [{ kind, id, title, subtitle, icon }], startedAt }
  //      or null. One card, however many things came due together.
  property var ringing: null
  property bool soundBroken: false

  readonly property string offsetsScript: 'for tz in "$@"; do [[ -f "/usr/share/zoneinfo/$tz" ]] || continue; printf "%s\\t%s\\t%s\\n" "$tz" "$(TZ=$tz date +%z)" "$(TZ=$tz date +%Z)"; done'

  // Whichever player is installed; exit 3 means "nothing can play this", which
  // stops the retry loop instead of spinning.
  readonly property string soundScript: 'f="$1"; [[ -f "$f" && -r "$f" ]] || { sleep 2; exit 3; }; '
    + 'if command -v pw-play >/dev/null 2>&1; then exec pw-play -- "$f"; fi; '
    + 'if command -v paplay >/dev/null 2>&1; then exec paplay -- "$f"; fi; '
    + 'if command -v mpv >/dev/null 2>&1; then exec mpv --no-video --no-terminal --really-quiet -- "$f"; fi; '
    + 'if command -v ffplay >/dev/null 2>&1; then exec ffplay -nodisp -autoexit -loglevel quiet "$f"; fi; '
    + 'sleep 2; exit 3'

  // ------------------------------------------------------------ persistence

  function loadState(text) {
    if (stateLoaded) return
    var parsed = Model.parseState(text)
    if (!parsed) {
      // Present but not trustworthy (truncated, hand-edited, a newer
      // version). It is moved aside rather than written over, and said so.
      console.warn("chime: state file is not usable, keeping it as state.json.bad: " + statePath)
      notify(Model.ICON_ALARM, "Chime could not read its saved alarms", "Starting empty. The old file is kept as state.json.bad in " + stateDir)
      saveBlocked = true
      quarantineProc.running = true
      parsed = Model.emptyState()
    }
    alarms = parsed.alarms
    timers = parsed.timers
    stopwatch = parsed.stopwatch
    clocks = parsed.clocks
    stateLoaded = true
    // Settle whatever came due while the shell was down.
    tick(Date.now())
    refreshOffsets()
  }

  function scheduleSave() {
    if (!stateLoaded) return
    saveWanted = true
    if (dirReady && !saveBlocked) saveTimer.restart()
  }

  function flushState() {
    if (!stateLoaded || !dirReady || saveBlocked) return
    saveWanted = false
    stateFile.setText(Model.serializeState(alarms, timers, stopwatch, clocks))
  }

  function reportSaveFailure(detail) {
    console.warn("chime: could not write " + statePath + ": " + detail)
    if (saveFailureReported) return
    saveFailureReported = true
    notify(Model.ICON_ALARM, "Chime cannot save its state", "Alarms, timers and cities will be lost on restart. Check " + stateDir)
  }

  // ------------------------------------------------------------------- tick

  function tick(now) {
    nowMs = now
    if (!stateLoaded) return
    checkTimers(now)
    checkAlarms(now)
    if (ringing) expireRing(now)
    if (clocks.length > 0) {
      var minute = new Date(now).getMinutes()
      var age = now - offsetsAt
      if (age > 20 * 60 * 1000 || (minute % 30 === 0 && age > 60 * 1000)) refreshOffsets()
    }
  }

  function checkTimers(now) {
    var list = timers.slice()
    var changed = false
    var events = []
    var missed = []
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      if (!t.running || Number(t.endsAt) > now) continue
      var late = now - Number(t.endsAt)
      list[i] = Model.finishedTimer(t)
      changed = true
      if (late <= Model.GRACE_MS) events.push(timerEvent(list[i]))
      else missed.push(Model.timerTitle(t) + " ended " + Model.relativeTime(now, Number(t.endsAt)))
    }
    if (changed) {
      timers = list
      scheduleSave()
    }
    notifyMissed(Model.ICON_TIMER, "timer", missed)
    if (events.length > 0) startRing(events, now)
  }

  function checkAlarms(now) {
    var list = alarms.slice()
    var changed = false
    var events = []
    var missed = []
    for (var i = 0; i < list.length; i++) {
      var a = list[i]
      var due = Model.alarmDue(a, now)
      if (!due) continue
      var patch = { snoozedUntil: 0 }
      if (due.kind === "scheduled") {
        patch.lastFiredAt = due.at
        patch.autoSnoozes = 0
        if (!Model.isRepeating(a)) patch.enabled = false
      }
      list[i] = withAlarm(a, patch)
      changed = true
      if (now - due.at <= Model.GRACE_MS) events.push(alarmEvent(list[i], due.at))
      else missed.push(alarmTitle(a) + " was due " + Model.relativeTime(now, due.at))
    }
    if (changed) {
      alarms = list
      scheduleSave()
    }
    notifyMissed(Model.ICON_ALARM, "alarm", missed)
    if (events.length > 0) startRing(events, now)
  }

  // One toast for whatever was missed in a tick: after a night asleep that
  // can be several, and a notification each would be a wall of them.
  function notifyMissed(glyph, kind, missed) {
    if (missed.length === 0) return
    if (missed.length === 1) notify(glyph, "Missed " + kind, missed[0])
    else notifyLines(glyph, missed.length + " missed " + kind + "s", missed)
  }

  // ----------------------------------------------------------------- alarms

  function withAlarm(alarm, patch) {
    var next = {}
    for (var k in alarm) next[k] = alarm[k]
    for (var p in patch) next[p] = patch[p]
    return next
  }

  function alarmIndex(id) {
    var key = Model.safeId(id)
    if (!key) return -1
    for (var i = 0; i < alarms.length; i++) if (alarms[i].id === key) return i
    return -1
  }

  function alarmById(id) {
    var index = alarmIndex(id)
    return index >= 0 ? alarms[index] : null
  }

  function patchAlarm(id, patch) {
    var index = alarmIndex(id)
    if (index < 0) return false
    var list = alarms.slice()
    list[index] = withAlarm(list[index], patch)
    alarms = list
    scheduleSave()
    return true
  }

  function alarmTitle(alarm) {
    return alarm.label ? alarm.label : "Alarm " + Model.formatTime(alarm.hour, alarm.minute, hour12)
  }

  function addAlarm(hour, minute, label, days) {
    if (alarms.length >= Model.MAX_ALARMS) return ""
    var now = Date.now()
    var alarm = Model.normalizeAlarm({
      id: Model.newId("a", now),
      hour: hour,
      minute: minute,
      label: label,
      enabled: true,
      days: days,
      armedAt: now
    })
    if (!alarm) return ""
    touchNow()
    alarms = alarms.concat([alarm])
    scheduleSave()
    return alarm.id
  }

  // Editing the time or days re-arms the alarm: an alarm moved to a time
  // earlier today must not go off on the spot.
  function updateAlarm(id, hour, minute, label, days) {
    var current = alarmById(id)
    if (!current) return false
    var checked = Model.normalizeAlarm({ id: current.id, hour: hour, minute: minute, label: label, days: days })
    if (!checked) return false
    var now = Date.now()
    var schedule = checked.hour !== current.hour || checked.minute !== current.minute
      || checked.days.join(",") !== Model.normalizeDays(current.days).join(",")
    var patch = { hour: checked.hour, minute: checked.minute, label: checked.label, days: checked.days }
    if (schedule) {
      patch.armedAt = now
      patch.snoozedUntil = 0
      patch.enabled = true
    }
    return patchAlarm(id, patch)
  }

  function removeAlarm(id) {
    var index = alarmIndex(id)
    if (index < 0) return false
    var list = alarms.slice()
    list.splice(index, 1)
    alarms = list
    dropRingEvents("alarm", id)
    scheduleSave()
    return true
  }

  // Switching an alarm off also takes it out of a ring in progress.
  function setAlarmEnabled(id, enabled) {
    var on = Model.toBool(enabled, true)
    if (!on) dropRingEvents("alarm", Model.safeId(id))
    return patchAlarm(id, on ? { enabled: true, armedAt: Date.now(), snoozedUntil: 0, autoSnoozes: 0 } : { enabled: false, snoozedUntil: 0 })
  }

  function toggleAlarm(id) {
    var alarm = alarmById(id)
    if (!alarm) return false
    return setAlarmEnabled(id, !(alarm.enabled || Number(alarm.snoozedUntil) > nowMs))
  }

  function snoozeAlarm(id, minutes, automatic) {
    var span = Model.clampInt(minutes, 1, 180, snoozeMinutes)
    var alarm = alarmById(id)
    if (!alarm) return false
    return patchAlarm(id, {
      snoozedUntil: Date.now() + span * 60 * 1000,
      autoSnoozes: automatic ? (Number(alarm.autoSnoozes) || 0) + 1 : 0
    })
  }

  // ----------------------------------------------------------------- timers

  function timerIndex(id) {
    var key = Model.safeId(id)
    if (!key) return -1
    for (var i = 0; i < timers.length; i++) if (timers[i].id === key) return i
    return -1
  }

  function timerById(id) {
    var index = timerIndex(id)
    return index >= 0 ? timers[index] : null
  }

  function replaceTimer(id, fn) {
    var index = timerIndex(id)
    if (index < 0) return false
    touchNow()
    var list = timers.slice()
    list[index] = fn(list[index], nowMs)
    timers = list
    scheduleSave()
    return true
  }

  function startTimer(durationMs, label) {
    var ms = Math.round(Number(durationMs) || 0)
    if (ms < Model.MIN_TIMER_MS || ms > Model.MAX_TIMER_MS) return ""
    var list = timers.slice()
    // Finished timers nobody restarted make room rather than blocking.
    while (list.length >= Model.MAX_TIMERS) {
      var doneAt = -1
      for (var i = 0; i < list.length; i++) if (list[i].done) { doneAt = i; break }
      if (doneAt < 0) return ""
      list.splice(doneAt, 1)
    }
    touchNow()
    var timer = Model.newTimer(ms, label, nowMs)
    timers = list.concat([timer])
    scheduleSave()
    return timer.id
  }

  function startTimerText(spec, label) {
    return startTimer(Model.parseDuration(spec), label)
  }

  function pauseTimer(id) { return replaceTimer(id, function(t, now) { return Model.pausedTimer(t, now) }) }
  function resumeTimer(id) { return replaceTimer(id, function(t, now) { return Model.resumedTimer(t, now) }) }
  function resetTimer(id) { return replaceTimer(id, function(t) { return Model.resetTimer(t) }) }
  function restartTimer(id) { return replaceTimer(id, function(t, now) { return Model.restartedTimer(t, now) }) }
  function extendTimer(id, extraMs) { return replaceTimer(id, function(t, now) { return Model.extendedTimer(t, now, extraMs) }) }

  // Running pauses, paused resumes, done runs again.
  function toggleTimer(id) {
    var timer = timerById(id)
    if (!timer) return false
    if (timer.running) return pauseTimer(id)
    if (timer.done) return restartTimer(id)
    return resumeTimer(id)
  }

  function removeTimer(id) {
    var index = timerIndex(id)
    if (index < 0) return false
    var list = timers.slice()
    list.splice(index, 1)
    timers = list
    dropRingEvents("timer", id)
    scheduleSave()
    return true
  }

  function clearDoneTimers() {
    var list = timers.filter(function(t) { return !t.done })
    var removed = timers.length - list.length
    if (removed > 0) {
      timers = list
      scheduleSave()
    }
    return removed
  }

  function cancelTimers() {
    var count = timers.length
    if (count > 0) {
      timers = []
      dropRingEvents("timer", "")
      scheduleSave()
    }
    return count
  }

  // The bar icon's right click: pause what is counting, else resume what is
  // paused. Timers before the stopwatch, soonest first.
  function toggleRunning() {
    var sorted = Model.sortTimers(timers, nowMs)
    for (var i = 0; i < sorted.length; i++) if (sorted[i].running) return pauseTimer(sorted[i].id)
    if (stopwatch.running) return stopwatchPause()
    for (var j = 0; j < sorted.length; j++) if (!sorted[j].done) return resumeTimer(sorted[j].id)
    if (Model.stopwatchElapsed(stopwatch, nowMs) > 0) return stopwatchStart()
    return false
  }

  // -------------------------------------------------------------- stopwatch

  function stopwatchStart() {
    if (stopwatch.running) return false
    touchNow()
    stopwatch = Model.stopwatchStarted(stopwatch, nowMs)
    scheduleSave()
    return true
  }

  function stopwatchPause() {
    if (!stopwatch.running) return false
    touchNow()
    stopwatch = Model.stopwatchPaused(stopwatch, nowMs)
    scheduleSave()
    return true
  }

  function stopwatchToggle() {
    return stopwatch.running ? stopwatchPause() : stopwatchStart()
  }

  function stopwatchLap() {
    if (!stopwatch.running) return false
    stopwatch = Model.stopwatchLapped(stopwatch, Date.now())
    scheduleSave()
    return true
  }

  function stopwatchReset() {
    stopwatch = Model.emptyStopwatch()
    scheduleSave()
    return true
  }

  // ----------------------------------------------------------- world clocks

  function clockIndex(tz) {
    var key = String(tz || "")
    for (var i = 0; i < clocks.length; i++) if (clocks[i].tz === key) return i
    return -1
  }

  function addClock(tz) {
    var zone = String(tz || "")
    if (!Model.validZone(zone) || clockIndex(zone) >= 0 || clocks.length >= Model.MAX_CLOCKS) return false
    clocks = clocks.concat([Model.newClock(zone)])
    scheduleSave()
    refreshOffsets()
    return true
  }

  function removeClock(tz) {
    var index = clockIndex(tz)
    if (index < 0) return false
    var list = clocks.slice()
    list.splice(index, 1)
    clocks = list
    scheduleSave()
    return true
  }

  function patchClock(tz, patch) {
    var index = clockIndex(tz)
    if (index < 0) return false
    var list = clocks.slice()
    var next = {}
    for (var k in list[index]) next[k] = list[index][k]
    for (var p in patch) next[p] = patch[p]
    list[index] = next
    clocks = list
    scheduleSave()
    return true
  }

  function setClockPinned(tz, pinned) { return patchClock(tz, { pinned: Model.toBool(pinned, true) }) }

  function toggleClockPinned(tz) {
    var index = clockIndex(tz)
    return index < 0 ? false : setClockPinned(tz, !clocks[index].pinned)
  }

  function renameClock(tz, label) {
    var text = Model.plainLabel(label)
    return patchClock(tz, { label: text || Model.zoneCity(tz) })
  }

  function refreshOffsets() {
    var zones = []
    for (var i = 0; i < clocks.length; i++) if (Model.validZone(clocks[i].tz)) zones.push(clocks[i].tz)
    if (zones.length === 0) {
      offsets = ({})
      offsetsAt = Date.now()
      return
    }
    if (offsetsProc.running) {
      offsetsPending = true
      return
    }
    offsetsPending = false
    offsetsProc.command = ["bash", "-c", offsetsScript, "chime-offsets"].concat(zones)
    offsetsProc.running = true
  }

  function refreshOffsetsIfStale() {
    if (Date.now() - offsetsAt > 60 * 1000) refreshOffsets()
  }

  function applyOffsets(text) {
    var raw = String(text || "")
    if (raw.length > 64 * 1024) raw = ""
    offsets = Model.parseOffsets(raw)
    offsetsAt = Date.now()
  }

  function loadZones() {
    if (zonesRequested) return
    zonesRequested = true
    countryFile.path = "/usr/share/zoneinfo/iso3166.tab"
    zoneTabFile.path = "/usr/share/zoneinfo/zone1970.tab"
  }

  function buildZoneOptions() {
    if (zoneTabText === "") return
    var options = Model.parseZoneTab(zoneTabText, Model.parseCountries(countryText))
    // UTC is always appended, so one entry means the table had nothing in it.
    if (options.length <= 1) {
      zoneTabFailed()
      return
    }
    zoneOptions = options
    zonesLoaded = true
  }

  // tzdata's tables are missing or empty: fall back to the list systemd keeps.
  function zoneTabFailed() {
    if (!zonesRequested || zonesLoaded || zoneListProc.running) return
    zoneListProc.running = true
  }

  function applyZoneList(text) {
    if (zonesLoaded) return
    var raw = String(text || "")
    if (raw.length > 256 * 1024) raw = ""
    zoneOptions = Model.parseZoneList(raw)
    zonesLoaded = true
  }

  // ---------------------------------------------------------- bar placement
  //
  // Two entries of the widget around the built-in indicators make it behave
  // like one of them: the entry before shows the idle icon among the hidden
  // indicators, the entry after shows the readout next to the clock. Each
  // BarWidget works out which side it is on; the config side lives here so
  // one owner rewrites the layout, from the panel's button or over IPC.

  readonly property var layoutInfo: layoutInfoFor(shell ? shell.barConfig : null)

  function rawEntryId(entry) {
    if (typeof entry === "string") return Util.canonicalWidgetId(entry)
    return Util.isPlainObject(entry) ? Util.canonicalWidgetId(String(entry.id || "")) : ""
  }

  function layoutInfoFor(config) {
    var out = { region: "", mine: [], indicators: -1, split: false, canSplit: false }
    var layout = Util.isPlainObject(config) && Util.isPlainObject(config.layout) ? config.layout : null
    if (!layout) return out
    var regions = ["left", "center", "right"]
    for (var r = 0; r < regions.length; r++) {
      var entries = Array.isArray(layout[regions[r]]) ? layout[regions[r]] : []
      var mine = []
      var indicators = -1
      for (var i = 0; i < entries.length; i++) {
        var id = rawEntryId(entries[i])
        if (id === pluginId) mine.push(i)
        else if (id === "omarchy.indicators" && indicators < 0) indicators = i
      }
      if (mine.length === 0) continue
      var before = false
      var after = false
      for (var m = 0; m < mine.length; m++) {
        if (mine[m] < indicators) before = true
        else if (mine[m] > indicators) after = true
      }
      out.region = regions[r]
      out.mine = mine
      out.indicators = indicators
      out.split = indicators >= 0 && before && after
      out.canSplit = indicators >= 0 && !out.split
      return out
    }
    return out
  }

  // Rebuilds this widget's entries in its section: every existing one is
  // dropped (the first one's settings are kept as the template) and `place`
  // decides where the template goes back in.
  function rewriteLayout(place) {
    if (!shell || typeof shell.mutateShellConfig !== "function") return false
    var info = layoutInfoFor(shell.barConfig)
    if (!info.region) return false
    var done = false
    shell.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar) || !Util.isPlainObject(config.bar.layout)) return
      var section = config.bar.layout[info.region]
      if (!Array.isArray(section)) return
      var template = null
      var firstIndex = -1
      var kept = []
      for (var i = 0; i < section.length; i++) {
        if (rawEntryId(section[i]) === pluginId) {
          if (!template) {
            template = Util.isPlainObject(section[i]) ? Util.cloneJson(section[i]) : { id: pluginId }
            firstIndex = kept.length
          }
          continue
        }
        kept.push(section[i])
      }
      if (!template) template = { id: pluginId }
      template.id = pluginId
      var indicators = -1
      for (var k = 0; k < kept.length; k++) {
        if (rawEntryId(kept[k]) === "omarchy.indicators") { indicators = k; break }
      }
      config.bar.layout[info.region] = place(kept, template, indicators, Math.max(0, firstIndex))
      done = true
    })
    return done
  }

  function splitLayout() {
    if (!layoutInfoFor(shell ? shell.barConfig : null).canSplit) return false
    return rewriteLayout(function(kept, template, indicators, firstIndex) {
      if (indicators < 0) {
        kept.splice(firstIndex, 0, template)
        return kept
      }
      kept.splice(indicators, 0, Util.cloneJson(template))
      kept.splice(indicators + 2, 0, Util.cloneJson(template))
      return kept
    })
  }

  function mergeLayout() {
    // One entry is already merged; rewriting would only rebuild the bar.
    if (layoutInfoFor(shell ? shell.barConfig : null).mine.length <= 1) return false
    return rewriteLayout(function(kept, template, indicators, firstIndex) {
      kept.splice(indicators >= 0 ? indicators + 1 : firstIndex, 0, template)
      return kept
    })
  }

  // ------------------------------------------------------------------- ring

  function timerEvent(timer) {
    return {
      kind: "timer",
      id: timer.id,
      icon: Model.ICON_TIMER,
      title: Model.timerTitle(timer),
      subtitle: Model.humanDuration(timer.durationMs) + " is up"
    }
  }

  // An unlabeled alarm's title already carries its time, so the subtitle
  // says how it repeats instead of repeating the time.
  function alarmEvent(alarm, at) {
    return {
      kind: "alarm",
      id: alarm.id,
      icon: Model.ICON_ALARM,
      title: alarmTitle(alarm),
      subtitle: alarm.label ? Model.formatTimeMs(at, hour12) : Model.daysLabel(alarm.days)
    }
  }

  // Every event keeps its own start, so one joining a card that has been up
  // for a while still gets its full ring.
  function startRing(events, now) {
    var list = ringing ? ringing.events.slice() : []
    for (var i = 0; i < events.length; i++) {
      var duplicate = false
      for (var j = 0; j < list.length; j++) {
        if (list[j].kind === events[i].kind && list[j].id === events[i].id) { duplicate = true; break }
      }
      if (duplicate) continue
      events[i].startedAt = now
      list.push(events[i])
    }
    ringing = { events: list, startedAt: ringing ? ringing.startedAt : now }
    soundBroken = false
    soundFailures = 0
    ensureSound()
  }

  function stopRing() {
    if (!ringing) return false
    ringing = null
    stopSound()
    return true
  }

  // Alarms in the card get a snooze, timers get five more minutes.
  function snoozeRing() {
    if (!ringing) return false
    var events = ringing.events
    for (var i = 0; i < events.length; i++) {
      if (events[i].kind === "alarm") snoozeAlarm(events[i].id, snoozeMinutes, false)
      else extendTimer(events[i].id, Model.TIMER_EXTEND_MS)
    }
    stopRing()
    return true
  }

  // Nobody answered an event for `ringSeconds`. Alarms snooze themselves a
  // few times so a ring that went unheard comes back; timers just drop off.
  // The card stays up for whatever is still within its time.
  function expireRing(now) {
    if (!ringing) return
    var keep = []
    var expired = []
    for (var i = 0; i < ringing.events.length; i++) {
      var e = ringing.events[i]
      if (now - (Number(e.startedAt) || ringing.startedAt) >= ringSeconds * 1000) expired.push(e)
      else keep.push(e)
    }
    if (expired.length === 0) return
    for (var x = 0; x < expired.length; x++) {
      if (expired[x].kind !== "alarm") continue
      var alarm = alarmById(expired[x].id)
      if (alarm && (Number(alarm.autoSnoozes) || 0) < Model.MAX_AUTO_SNOOZES) snoozeAlarm(alarm.id, snoozeMinutes, true)
    }
    if (keep.length === 0) stopRing()
    else ringing = { events: keep, startedAt: ringing.startedAt }
  }

  // Take one event (or, with an empty id, every event of a kind) out of the
  // card; the card goes away with its last event.
  function dropRingEvents(kind, id) {
    if (!ringing) return
    var left = ringing.events.filter(function(e) { return !(e.kind === kind && (id === "" || e.id === id)) })
    if (left.length === ringing.events.length) return
    if (left.length === 0) stopRing()
    else ringing = { events: left, startedAt: ringing.startedAt }
  }

  readonly property bool ringHasAlarm: !!ringing && ringing.events.some(function(e) { return e.kind === "alarm" })
  readonly property bool ringHasTimer: !!ringing && ringing.events.some(function(e) { return e.kind === "timer" })
  readonly property string ringTitle: ringing && ringing.events.length > 0
    ? (ringing.events.length === 1 ? ringing.events[0].title : ringing.events.length + " things are due")
    : ""
  readonly property string snoozeLabel: ringHasAlarm && ringHasTimer ? "Snooze"
    : ringHasAlarm ? "Snooze " + snoozeMinutes + " min"
    : "+" + Math.round(Model.TIMER_EXTEND_MS / 60000) + " min"

  property double soundStartedAt: 0
  property int soundFailures: 0

  function ensureSound() {
    if (!ringing || muted || soundBroken) return
    if (soundProc.running) return
    var file = soundPath
    if (file === "" || file.charAt(0) === "-") {
      soundBroken = true
      return
    }
    soundStartedAt = Date.now()
    soundProc.command = ["bash", "-c", soundScript, "chime-sound", file]
    soundProc.running = true
  }

  function stopSound() {
    soundRestart.stop()
    if (soundProc.running) soundProc.running = false
  }

  // The loop restarts the player when a play-through ends. A player that
  // fails at once — a file it cannot decode — must not be restarted hundreds
  // of times a minute, so a few quick failures in a row latch it off.
  function soundExited(exitCode) {
    if (!ringing) return
    var quickFailure = exitCode !== 0 && Date.now() - soundStartedAt < 1500
    if (exitCode === 3 || (quickFailure && ++soundFailures >= 3)) {
      soundBroken = true
      console.warn("chime: cannot play " + soundPath + " (missing, unreadable, undecodable, or no pw-play/paplay/mpv/ffplay); ringing silently")
      return
    }
    if (!quickFailure) soundFailures = 0
    soundRestart.restart()
  }

  // ---------------------------------------------------------- notifications

  function notify(glyph, title, body) {
    Quickshell.execDetached(["omarchy-notification-send", "-g", glyph, Model.plainLabel(title, 80), Model.plainLabel(body, 200)])
  }

  // One line per item, each cleaned on its own so the line breaks survive.
  function notifyLines(glyph, title, lines) {
    var body = []
    for (var i = 0; i < lines.length && i < 12; i++) body.push(Model.plainLabel(lines[i], 120))
    if (lines.length > 12) body.push("… and " + (lines.length - 12) + " more")
    Quickshell.execDetached(["omarchy-notification-send", "-g", glyph, Model.plainLabel(title, 80), body.join("\n")])
  }

  // ------------------------------------------------------------------ panel

  function summonPanel(method) {
    if (!shell || typeof shell[method] !== "function") return false
    return shell[method](pluginId, "{}") === true
  }

  function statusJson() {
    var now = Date.now()
    return JSON.stringify({
      ringing: ringing ? ringing.events : [],
      nextAlarm: nextAlarm ? { id: nextAlarm.alarm.id, at: nextAlarm.at, time: Model.formatTimeMs(nextAlarm.at, hour12), label: nextAlarm.alarm.label } : null,
      alarms: alarms.map(function(a) {
        return { id: a.id, time: Model.formatTime(a.hour, a.minute, false), label: a.label, enabled: a.enabled, days: a.days, nextAt: Model.alarmNextAt(a, now) }
      }),
      timers: timers.map(function(t) {
        return { id: t.id, label: t.label, durationMs: t.durationMs, remainingMs: Model.timerRemaining(t, now), running: t.running, done: t.done }
      }),
      stopwatch: { running: stopwatch.running, elapsedMs: Model.stopwatchElapsed(stopwatch, now), laps: stopwatch.laps },
      clocks: clocks.map(function(c) {
        var info = offsets[c.tz]
        return { tz: c.tz, label: c.label, pinned: c.pinned, time: info ? Model.formatZoneTime(now, info.offsetMin, hour12) : "", offsetMin: info ? info.offsetMin : null }
      })
    })
  }

  // ----------------------------------------------------------------- wiring

  SystemClock {
    id: clock
    precision: root.anyRunning || root.ringing !== null ? SystemClock.Seconds : SystemClock.Minutes
    onDateChanged: root.tick(date.getTime())
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("")
    onSaveFailed: function(error) { root.reportSaveFailure(String(error)) }
  }

  Process {
    id: ensureDir
    command: ["mkdir", "-p", root.stateDir]
    onExited: function(exitCode) {
      if (exitCode !== 0) root.reportSaveFailure("mkdir exited with " + exitCode)
      root.dirReady = true
      if (root.saveWanted) saveTimer.restart()
    }
  }

  // Moves an unreadable state file out of the way before the first save.
  Process {
    id: quarantineProc
    command: ["mv", "-f", root.statePath, root.statePath + ".bad"]
    onExited: {
      root.saveBlocked = false
      if (root.saveWanted) saveTimer.restart()
    }
  }

  Timer {
    id: saveTimer
    interval: 250
    repeat: false
    onTriggered: root.flushState()
  }

  Process {
    id: offsetsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyOffsets(text)
    }
    onExited: if (root.offsetsPending) Qt.callLater(root.refreshOffsets)
  }

  // Both start without a path and only get one from loadZones(), so their
  // handlers ignore anything that fires before the world tab asked.
  FileView {
    id: zoneTabFile
    printErrors: false
    onLoaded: {
      if (!root.zonesRequested) return
      root.zoneTabText = text()
      if (root.zoneTabText === "") root.zoneTabFailed()
      else root.buildZoneOptions()
    }
    onLoadFailed: root.zoneTabFailed()
  }

  FileView {
    id: countryFile
    printErrors: false
    onLoaded: {
      if (!root.zonesRequested) return
      root.countryText = text()
      root.buildZoneOptions()
    }
    onLoadFailed: if (root.zonesRequested) root.buildZoneOptions()
  }

  Process {
    id: zoneListProc
    command: ["timedatectl", "list-timezones"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyZoneList(text)
    }
  }

  Process {
    id: soundProc
    onExited: function(exitCode) { root.soundExited(exitCode) }
  }

  Timer {
    id: soundRestart
    interval: 350
    repeat: false
    onTriggered: root.ensureSound()
  }

  Component.onCompleted: {
    Local.ChimeRuntime.service = root
    ensureDir.running = true
  }

  // A plugin reload while ringing must not leave the sound loop behind.
  Component.onDestruction: {
    if (Local.ChimeRuntime.service === root) Local.ChimeRuntime.service = null
    stopSound()
  }

  // ---- The ring: a card on every screen, over everything, with the keys
  //      anyone would press at an alarm. Escape, Enter and Space stop it;
  //      S snoozes.
  Variants {
    model: root.ringing ? Quickshell.screens : []

    delegate: Component {
      PanelWindow {
        id: ringWindow
        required property var modelData

        screen: modelData
        visible: root.ringing !== null
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "chime-ring"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        anchors {
          top: true
          bottom: true
          left: true
          right: true
        }

        readonly property color fg: Color.menu.text
        readonly property string fontFamily: Style.font.family

        Rectangle {
          anchors.fill: parent
          color: Color.menu.scrim
        }

        Item {
          id: ringKeys
          anchors.fill: parent
          focus: true
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
              root.stopRing()
              event.accepted = true
            } else if (event.text === "s" || event.text === "S") {
              root.snoozeRing()
              event.accepted = true
            }
          }
        }

        BorderSurface {
          id: ringCard
          anchors.centerIn: parent
          width: Math.min(Style.space(420), parent.width - Style.gapsOut * 4)
          height: ringColumn.implicitHeight + contentTopInset + contentBottomInset
          radius: Style.cornerRadius
          color: Color.menu.background
          borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
          padding: Style.space(26)

          MouseArea { anchors.fill: parent; onClicked: {} }

          Column {
            id: ringColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: ringCard.contentLeftInset
            anchors.rightMargin: ringCard.contentRightInset
            anchors.topMargin: ringCard.contentTopInset
            spacing: Style.space(14)

            Text {
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.ringing && root.ringing.events.length > 0 ? root.ringing.events[0].icon : Model.ICON_BELL
              color: ringWindow.fg
              font.family: ringWindow.fontFamily
              font.pixelSize: Style.font.displayLarge * 2
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.ringTitle
              color: ringWindow.fg
              font.family: ringWindow.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              wrapMode: Text.WordWrap
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.ringing ? root.ringing.events : []

                Text {
                  required property var modelData
                  textFormat: Text.PlainText
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: (root.ringing && root.ringing.events.length > 1 ? modelData.icon + "  " + modelData.title + "  ·  " : "") + modelData.subtitle
                  color: Qt.darker(ringWindow.fg, 1.4)
                  font.family: ringWindow.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
              }
            }

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(10)

              Button {
                text: root.snoozeLabel
                bordered: true
                foreground: ringWindow.fg
                fontFamily: ringWindow.fontFamily
                horizontalPadding: Style.space(16)
                verticalPadding: Style.space(8)
                onClicked: root.snoozeRing()
              }

              Button {
                text: "Stop"
                bordered: true
                selected: true
                foreground: ringWindow.fg
                fontFamily: ringWindow.fontFamily
                horizontalPadding: Style.space(22)
                verticalPadding: Style.space(8)
                onClicked: root.stopRing()
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "Enter or Esc stops  ·  S snoozes"
              color: Qt.darker(ringWindow.fg, 1.9)
              font.family: ringWindow.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  // -------------------------------------------------------------------- IPC

  IpcHandler {
    target: root.ipcTarget

    function ping(): string { return "ok" }
    function status(): string { return root.statusJson() }

    function timer(spec: string, label: string): string {
      var id = root.startTimerText(spec, label)
      return id ? id : "invalid"
    }
    function pauseTimer(id: string): string { return root.pauseTimer(id) ? "ok" : "unknown" }
    function resumeTimer(id: string): string { return root.resumeTimer(id) ? "ok" : "unknown" }
    function toggleTimer(id: string): string { return root.toggleTimer(id) ? "ok" : "unknown" }
    function resetTimer(id: string): string { return root.resetTimer(id) ? "ok" : "unknown" }
    function cancelTimer(id: string): string { return root.removeTimer(id) ? "ok" : "unknown" }
    function cancelTimers(): string { return String(root.cancelTimers()) }

    function stopwatch(action: string): string {
      var verb = String(action || "toggle")
      if (verb === "start") return root.stopwatchStart() ? "ok" : "running"
      if (verb === "pause" || verb === "stop") return root.stopwatchPause() ? "ok" : "paused"
      if (verb === "lap") return root.stopwatchLap() ? "ok" : "not running"
      if (verb === "reset") return root.stopwatchReset() ? "ok" : "unknown"
      if (verb === "toggle") return root.stopwatchToggle() ? "ok" : "unknown"
      return "unknown action"
    }

    function alarm(time: string, label: string, days: string): string {
      var parsed = Model.parseTime(time)
      if (!parsed) return "invalid time"
      var id = root.addAlarm(parsed.hour, parsed.minute, label, Model.normalizeDays(days))
      return id ? id : "full"
    }
    function removeAlarm(id: string): string { return root.removeAlarm(id) ? "ok" : "unknown" }
    function enableAlarm(id: string): string { return root.setAlarmEnabled(id, true) ? "ok" : "unknown" }
    function disableAlarm(id: string): string { return root.setAlarmEnabled(id, false) ? "ok" : "unknown" }
    function toggleAlarm(id: string): string { return root.toggleAlarm(id) ? "ok" : "unknown" }

    function addClock(zone: string): string { return root.addClock(zone) ? "ok" : "invalid" }
    function removeClock(zone: string): string { return root.removeClock(zone) ? "ok" : "unknown" }
    function pinClock(zone: string, pinned: string): string { return root.setClockPinned(zone, pinned) ? "ok" : "unknown" }

    function stop(): string { return root.stopRing() ? "ok" : "quiet" }
    function snooze(): string { return root.snoozeRing() ? "ok" : "quiet" }
    function toggleRunning(): string { return root.toggleRunning() ? "ok" : "nothing" }

    function open(): string { return root.summonPanel("summon") ? "ok" : "unknown" }
    function hide(): string { return root.summonPanel("hide") ? "ok" : "unknown" }
    function toggle(): string { return root.summonPanel("toggle") ? "ok" : "unknown" }

    function layout(action: string): string {
      var verb = String(action || "status")
      if (verb === "split") return root.splitLayout() ? "ok" : "cannot"
      if (verb === "merge") return root.mergeLayout() ? "ok" : "cannot"
      return JSON.stringify(root.layoutInfo)
    }
  }
}
