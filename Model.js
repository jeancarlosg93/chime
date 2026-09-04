// Pure helpers for Chime: durations, alarm scheduling, stopwatch math,
// world-clock offsets, bar labels, and the persisted state's shape. Nothing
// in here touches Qt or Quickshell, so the whole file runs under node
// (test/model.test.js). The QML owns the clock, the files, and the windows.

var MAX_LABEL = 40
var MAX_ALARMS = 50
var MAX_TIMERS = 20
var MAX_CLOCKS = 30
var MAX_LAPS = 200
var MAX_STATE_BYTES = 1024 * 1024
var MAX_ZONE_TAB_BYTES = 4 * 1024 * 1024

// An alarm or timer that came due while the shell was down (or the machine
// asleep) still rings if it is this recent; older ones are reported as missed
// rather than going off hours late.
var GRACE_MS = 10 * 60 * 1000

var MIN_TIMER_MS = 1000
var MAX_TIMER_MS = 99 * 3600 * 1000
var TIMER_EXTEND_MS = 5 * 60 * 1000
var MAX_AUTO_SNOOZES = 3

var MINUTE_MS = 60 * 1000
var HOUR_MS = 3600 * 1000
var DAY_MS = 24 * HOUR_MS

// ---- Untrusted text. Labels are typed by the user, but they also arrive
// over IPC and from the state file, and they end up in tooltips and
// notification bodies drawn by components that treat text as rich text.
// Control characters become spaces, whitespace collapses, the result is
// capped, and angle brackets become their single-guillemet lookalikes.
function plainLabel(value, limit) {
  var cap = Number(limit) > 0 ? Number(limit) : MAX_LABEL
  var s = String(value === undefined || value === null ? "" : value)
  if (s.length > cap * 4) s = s.slice(0, cap * 4)
  s = s.replace(/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069]/g, " ")
  s = s.replace(/</g, "‹").replace(/>/g, "›")
  s = s.replace(/\s+/g, " ").replace(/^ | $/g, "")
  return s.length > cap ? s.slice(0, cap - 1).replace(/ $/, "") + "…" : s
}

function pad2(value) {
  var n = Math.floor(Math.abs(Number(value) || 0))
  return (n < 10 ? "0" : "") + n
}

function clampInt(value, min, max, fallback) {
  var n = Number(value)
  if (value === undefined || value === null || value === "" || !isFinite(n)) return fallback
  n = Math.round(n)
  return Math.max(min, Math.min(max, n))
}

function toBool(value, fallback) {
  if (value === undefined || value === null) return fallback
  if (typeof value === "boolean") return value
  var s = String(value).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (s === "true" || s === "1" || s === "yes" || s === "on") return true
  if (s === "false" || s === "0" || s === "no" || s === "off") return false
  return fallback
}

// The latest instant this app will believe: 2100-01-01. JSON can carry
// 1e999, which parses to Infinity and would freeze a timer for good.
var MAX_INSTANT_MS = 4102444800000

// A stored instant or span in milliseconds: finite, non-negative and
// bounded, else 0.
function finiteAt(value) {
  if (value === null || value === undefined || value === "" || typeof value === "boolean") return 0
  var n = Number(value)
  if (!isFinite(n) || n < 0) return 0
  return Math.min(n, MAX_INSTANT_MS)
}

// An integer-valued field: NaN for anything that is not a number or a
// numeric string, so "" and null cannot quietly become 0.
function intField(value) {
  if (typeof value === "number") return value
  if (typeof value === "string" && value.replace(/\s+/g, "") !== "") return Number(value)
  return NaN
}

var idCounter = 0

function newId(prefix, nowMs) {
  idCounter = (idCounter + 1) % 46656
  return String(prefix || "x") + Math.floor(Number(nowMs) || 0).toString(36) + idCounter.toString(36)
}

function safeId(value) {
  var s = String(value === undefined || value === null ? "" : value)
  return /^[A-Za-z0-9_-]{1,40}$/.test(s) ? s : ""
}

// ---- Durations ------------------------------------------------------------

// "5" is five minutes, the unit people mean when they type a bare number into
// a kitchen timer. Otherwise: "90s", "1h30m", "1h 30m 10s", "1.5h", "12:30"
// (m:ss), "1:02:03" (h:mm:ss). Returns milliseconds, or 0 when it is not a
// duration this function will vouch for.
function parseDuration(text) {
  var s = String(text === undefined || text === null ? "" : text).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (s === "") return 0
  var ms = 0

  if (/^\d+(\.\d+)?$/.test(s)) {
    ms = parseFloat(s) * MINUTE_MS
  } else if (/^\d{1,3}:\d{1,2}(:\d{1,2})?$/.test(s)) {
    var parts = s.split(":").map(function(p) { return parseInt(p, 10) })
    for (var i = 1; i < parts.length; i++) if (parts[i] >= 60) return 0
    if (parts.length === 2) ms = parts[0] * MINUTE_MS + parts[1] * 1000
    else ms = parts[0] * HOUR_MS + parts[1] * MINUTE_MS + parts[2] * 1000
  } else {
    var re = /(\d+(?:\.\d+)?)\s*(hours|hour|hrs|hr|h|minutes|minute|mins|min|m|seconds|second|secs|sec|s)(?![a-z])/g
    var consumed = 0
    var match
    while ((match = re.exec(s)) !== null) {
      var n = parseFloat(match[1])
      var unit = match[2].charAt(0)
      ms += n * (unit === "h" ? HOUR_MS : unit === "m" ? MINUTE_MS : 1000)
      consumed++
    }
    if (consumed === 0) return 0
    var leftover = s.replace(re, "").replace(/[\s,]/g, "")
    if (leftover !== "") return 0
  }

  ms = Math.round(ms)
  if (!isFinite(ms) || ms < MIN_TIMER_MS || ms > MAX_TIMER_MS) return 0
  return ms
}

// "04:59", "1:04:59", or with tenths "00:12.3". Countdowns round up so a
// five-minute timer reads 05:00 on its first second and 00:01 on its last.
function formatClock(ms, opts) {
  var o = opts || {}
  var total = Math.max(0, Number(ms) || 0)
  var seconds = o.ceil ? Math.ceil(total / 1000) : Math.floor(total / 1000)
  var hours = Math.floor(seconds / 3600)
  var minutes = Math.floor((seconds % 3600) / 60)
  var secs = seconds % 60
  var out = (hours > 0 || o.forceHours ? hours + ":" + pad2(minutes) : pad2(minutes)) + ":" + pad2(secs)
  if (o.tenths) out += "." + Math.floor((total % 1000) / 100)
  return out
}

function formatRemaining(ms) {
  return formatClock(ms, { ceil: true })
}

// "5 min", "1 h 30 min", "45 s", "1 h".
function humanDuration(ms) {
  var total = Math.max(0, Math.round((Number(ms) || 0) / 1000))
  var hours = Math.floor(total / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  var seconds = total % 60
  var parts = []
  if (hours > 0) parts.push(hours + " h")
  if (minutes > 0) parts.push(minutes + " min")
  if (seconds > 0 && hours === 0) parts.push(seconds + " s")
  if (parts.length === 0) return "0 s"
  return parts.join(" ")
}

// "in 8 h 12 min", "in 45 s", "now"; past times read "5 min ago".
function relativeTime(fromMs, toMs) {
  var delta = Math.round(((Number(toMs) || 0) - (Number(fromMs) || 0)) / 1000)
  if (Math.abs(delta) < 1) return "now"
  var abs = Math.abs(delta)
  var text
  if (abs < 60) text = abs + " s"
  else if (abs < 3600) text = Math.round(abs / 60) + " min"
  else if (abs < DAY_MS / 1000) {
    var h = Math.floor(abs / 3600)
    var m = Math.round((abs % 3600) / 60)
    if (m === 60) { h++; m = 0 }
    text = h + " h" + (m > 0 ? " " + m + " min" : "")
  } else {
    var d = Math.floor(abs / (DAY_MS / 1000))
    var rh = Math.round((abs % (DAY_MS / 1000)) / 3600)
    if (rh === 24) { d++; rh = 0 }
    text = d + (d === 1 ? " day" : " days") + (rh > 0 ? " " + rh + " h" : "")
  }
  return delta > 0 ? "in " + text : text + " ago"
}

// ---- Times of day ---------------------------------------------------------

// "7:30", "07:30", "730", "7", "7:30 pm", "7pm", "19.30". Null when it is not
// a time.
function parseTime(text) {
  var s = String(text === undefined || text === null ? "" : text).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (s === "") return null
  var m = s.match(/^(\d{1,2})(?:[:.h]?(\d{2}))?\s*(am|pm|a|p)?$/)
  if (!m) return null
  var hour = parseInt(m[1], 10)
  var minute = m[2] === undefined ? 0 : parseInt(m[2], 10)
  var meridiem = m[3] ? m[3].charAt(0) : ""
  if (minute > 59) return null
  if (meridiem) {
    if (hour < 1 || hour > 12) return null
    if (meridiem === "p" && hour < 12) hour += 12
    if (meridiem === "a" && hour === 12) hour = 0
  } else if (hour > 23) {
    return null
  }
  return { hour: hour, minute: minute }
}

// What the alarm time field shows for whatever was typed into it: the digits
// with the colon put in by itself once the hour is complete. "7" is a whole
// hour on its own, so it becomes "7:" at once; "0" or "1" could start a
// two-digit hour, so they wait for the next digit ("07:", "12:"); "25" cannot
// be an hour, so it reads as "2:5". Trailing a/p/am/pm letters ride along
// for 12-hour times.
function maskTime(raw) {
  var s = String(raw === undefined || raw === null ? "" : raw)
  var digits = s.replace(/[^0-9]/g, "").slice(0, 4)
  var letters = (s.toLowerCase().match(/[ap]m?\s*$/) || [""])[0].replace(/\s+$/, "")
  var out = ""
  if (digits.length > 0) {
    var first = digits.charAt(0)
    if (first >= "3") {
      out = first + ":" + digits.slice(1, 3)
    } else if (digits.length === 1) {
      out = first
    } else if (parseInt(digits.slice(0, 2), 10) <= 23) {
      out = digits.slice(0, 2) + ":" + digits.slice(2, 4)
    } else {
      out = first + ":" + digits.slice(1, 3)
    }
  }
  if (letters !== "" && digits.length > 0) out += " " + letters
  return out
}

function formatTime(hour, minute, hour12) {
  var h = clampInt(hour, 0, 23, 0)
  var m = clampInt(minute, 0, 59, 0)
  if (!hour12) return pad2(h) + ":" + pad2(m)
  var suffix = h >= 12 ? "PM" : "AM"
  var shown = h % 12
  if (shown === 0) shown = 12
  return shown + ":" + pad2(m) + " " + suffix
}

function formatTimeMs(ms, hour12) {
  var d = new Date(Number(ms) || 0)
  return formatTime(d.getHours(), d.getMinutes(), hour12)
}

var DAY_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
// Monday-first order for the weekday picker, as JS getDay() indices.
var WEEK_ORDER = [1, 2, 3, 4, 5, 6, 0]
var WEEK_LETTERS = ["M", "T", "W", "T", "F", "S", "S"]

function normalizeDays(days) {
  var list = []
  var source = days
  if (typeof source === "string") source = source.split(/[\s,]+/)
  if (!source || typeof source.length !== "number") return list
  for (var i = 0; i < source.length; i++) {
    // Number("") is 0, which would quietly turn "no days" into Sunday.
    if (source[i] === null || source[i] === undefined || String(source[i]).replace(/\s+/g, "") === "") continue
    var n = Number(source[i])
    if (!isFinite(n) || Math.round(n) !== n || n < 0 || n > 6) continue
    if (list.indexOf(n) === -1) list.push(n)
  }
  list.sort(function(a, b) { return a - b })
  return list
}

function daysLabel(days) {
  var list = normalizeDays(days)
  if (list.length === 0) return "Once"
  if (list.length === 7) return "Every day"
  var key = list.join(",")
  if (key === "1,2,3,4,5") return "Weekdays"
  if (key === "0,6") return "Weekends"
  var ordered = []
  for (var i = 0; i < WEEK_ORDER.length; i++) if (list.indexOf(WEEK_ORDER[i]) !== -1) ordered.push(DAY_SHORT[WEEK_ORDER[i]])
  return ordered.join(", ")
}

function toggleDay(days, day) {
  var list = normalizeDays(days)
  var n = Number(day)
  var at = list.indexOf(n)
  if (at === -1) list.push(n)
  else list.splice(at, 1)
  return normalizeDays(list)
}

// ---- Alarms ---------------------------------------------------------------
//
// An alarm is { id, hour, minute, label, enabled, days, snoozedUntil,
// lastFiredAt, armedAt, autoSnoozes }. Occurrences are computed in local time
// from a day offset so daylight-saving changes land where the wall clock
// says, and nothing is ever decremented: the same functions answer "is it
// due?" after a restart or a night asleep.

function occurrenceAfter(alarm, afterMs) {
  var days = normalizeDays(alarm.days)
  var base = new Date(Number(afterMs) || 0)
  for (var offset = 0; offset <= 8; offset++) {
    var c = new Date(base.getFullYear(), base.getMonth(), base.getDate() + offset, alarm.hour, alarm.minute, 0, 0)
    if (c.getTime() <= afterMs) continue
    if (days.length === 0 || days.indexOf(c.getDay()) !== -1) return c.getTime()
  }
  return 0
}

function occurrenceAtOrBefore(alarm, beforeMs) {
  var days = normalizeDays(alarm.days)
  var base = new Date(Number(beforeMs) || 0)
  for (var offset = 0; offset >= -8; offset--) {
    var c = new Date(base.getFullYear(), base.getMonth(), base.getDate() + offset, alarm.hour, alarm.minute, 0, 0)
    if (c.getTime() > beforeMs) continue
    if (days.length === 0 || days.indexOf(c.getDay()) !== -1) return c.getTime()
  }
  return 0
}

// When the alarm rings next, or 0. A snooze outranks the schedule.
function alarmNextAt(alarm, nowMs) {
  if (!alarm) return 0
  if (Number(alarm.snoozedUntil) > nowMs) return Number(alarm.snoozedUntil)
  if (!alarm.enabled) return 0
  var after = Math.max(nowMs, Number(alarm.lastFiredAt) || 0, Number(alarm.armedAt) || 0)
  return occurrenceAfter(alarm, after)
}

// The occurrence the alarm owes a ring for, or null. `armedAt` keeps an alarm
// created at 15:00 for 07:30 from going off on the spot: only occurrences
// after it was armed count, and each one fires once (lastFiredAt).
function alarmDue(alarm, nowMs) {
  if (!alarm) return null
  var snoozed = Number(alarm.snoozedUntil) || 0
  if (snoozed > 0 && snoozed <= nowMs) return { at: snoozed, kind: "snooze" }
  if (!alarm.enabled) return null
  var occ = occurrenceAtOrBefore(alarm, nowMs)
  if (occ <= 0) return null
  var floor = Math.max(Number(alarm.lastFiredAt) || 0, Number(alarm.armedAt) || 0)
  if (occ <= floor) return null
  return { at: occ, kind: "scheduled" }
}

function isRepeating(alarm) {
  return !!alarm && normalizeDays(alarm.days).length > 0
}

// The soonest ring among all alarms: { alarm, at } or null.
function nextAlarm(alarms, nowMs) {
  var best = null
  var list = alarms || []
  for (var i = 0; i < list.length; i++) {
    var at = alarmNextAt(list[i], nowMs)
    if (at > 0 && (!best || at < best.at)) best = { alarm: list[i], at: at }
  }
  return best
}

function alarmSummary(alarm, nowMs, hour12) {
  var parts = []
  if (alarm.label) parts.push(alarm.label)
  parts.push(daysLabel(alarm.days))
  var at = alarmNextAt(alarm, nowMs)
  if (Number(alarm.snoozedUntil) > nowMs) parts.push("snoozed until " + formatTimeMs(alarm.snoozedUntil, hour12))
  else if (at > 0) parts.push(relativeTime(nowMs, at))
  else if (!alarm.enabled) parts.push("off")
  return parts.join("  ·  ")
}

function sortAlarms(list) {
  var out = (list || []).slice()
  out.sort(function(a, b) {
    var byTime = (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute)
    if (byTime !== 0) return byTime
    return String(a.id).localeCompare(String(b.id))
  })
  return out
}

// ---- Timers ---------------------------------------------------------------
//
// A timer is { id, label, durationMs, endsAt, remainingMs, running, done,
// doneAt, createdAt }. A running timer is defined by its end instant, so a
// shell restart or a suspend does not stretch it.

function newTimer(durationMs, label, nowMs) {
  var ms = Number(durationMs) || 0
  return {
    id: newId("t", nowMs),
    label: plainLabel(label),
    durationMs: ms,
    endsAt: nowMs + ms,
    remainingMs: ms,
    running: true,
    done: false,
    doneAt: 0,
    createdAt: nowMs
  }
}

function timerRemaining(timer, nowMs) {
  if (!timer) return 0
  if (timer.running) return Math.max(0, (Number(timer.endsAt) || 0) - nowMs)
  return Math.max(0, Number(timer.remainingMs) || 0)
}

function timerProgress(timer, nowMs) {
  if (!timer || !(Number(timer.durationMs) > 0)) return 0
  return Math.max(0, Math.min(1, 1 - timerRemaining(timer, nowMs) / Number(timer.durationMs)))
}

function withTimer(timer, patch) {
  var next = {}
  for (var k in timer) next[k] = timer[k]
  for (var p in patch) next[p] = patch[p]
  return next
}

function pausedTimer(timer, nowMs) {
  if (!timer.running) return timer
  return withTimer(timer, { running: false, remainingMs: timerRemaining(timer, nowMs), endsAt: 0 })
}

function resumedTimer(timer, nowMs) {
  if (timer.running || timer.done) return timer
  var remaining = Math.max(0, Number(timer.remainingMs) || 0)
  if (remaining <= 0) return timer
  return withTimer(timer, { running: true, endsAt: nowMs + remaining })
}

function resetTimer(timer) {
  return withTimer(timer, { running: false, done: false, doneAt: 0, endsAt: 0, remainingMs: Number(timer.durationMs) || 0 })
}

function restartedTimer(timer, nowMs) {
  var ms = Number(timer.durationMs) || 0
  return withTimer(timer, { running: true, done: false, doneAt: 0, endsAt: nowMs + ms, remainingMs: ms })
}

function finishedTimer(timer) {
  return withTimer(timer, { running: false, done: true, doneAt: Number(timer.endsAt) || 0, endsAt: 0, remainingMs: 0 })
}

// "+5 min" on a ringing or finished timer runs it for five more minutes; on
// a live one it pushes the end out.
function extendedTimer(timer, nowMs, extraMs) {
  var extra = Number(extraMs) > 0 ? Number(extraMs) : TIMER_EXTEND_MS
  if (timer.done) return withTimer(timer, { running: true, done: false, doneAt: 0, durationMs: extra, endsAt: nowMs + extra, remainingMs: extra })
  if (timer.running) return withTimer(timer, { durationMs: (Number(timer.durationMs) || 0) + extra, endsAt: (Number(timer.endsAt) || nowMs) + extra })
  return withTimer(timer, { durationMs: (Number(timer.durationMs) || 0) + extra, remainingMs: (Number(timer.remainingMs) || 0) + extra })
}

// Running first, soonest to finish on top; then paused, then done.
function sortTimers(list, nowMs) {
  var out = (list || []).slice()
  out.sort(function(a, b) {
    var ra = a.done ? 2 : (a.running ? 0 : 1)
    var rb = b.done ? 2 : (b.running ? 0 : 1)
    if (ra !== rb) return ra - rb
    if (ra === 2) return (Number(b.doneAt) || 0) - (Number(a.doneAt) || 0)
    var byRemaining = timerRemaining(a, nowMs) - timerRemaining(b, nowMs)
    if (byRemaining !== 0) return byRemaining
    return (Number(a.createdAt) || 0) - (Number(b.createdAt) || 0)
  })
  return out
}

function timerTitle(timer) {
  return timer && timer.label ? timer.label : humanDuration(timer ? timer.durationMs : 0) + " timer"
}

// ---- Stopwatch ------------------------------------------------------------

function emptyStopwatch() {
  return { running: false, startedAt: 0, accumulatedMs: 0, laps: [] }
}

function stopwatchElapsed(sw, nowMs) {
  if (!sw) return 0
  var acc = Math.max(0, Number(sw.accumulatedMs) || 0)
  if (sw.running) return acc + Math.max(0, nowMs - (Number(sw.startedAt) || nowMs))
  return acc
}

function stopwatchStarted(sw, nowMs) {
  if (sw.running) return sw
  return { running: true, startedAt: nowMs, accumulatedMs: Math.max(0, Number(sw.accumulatedMs) || 0), laps: (sw.laps || []).slice() }
}

function stopwatchPaused(sw, nowMs) {
  if (!sw.running) return sw
  return { running: false, startedAt: 0, accumulatedMs: stopwatchElapsed(sw, nowMs), laps: (sw.laps || []).slice() }
}

function stopwatchLapped(sw, nowMs) {
  var laps = (sw.laps || []).slice()
  laps.push(stopwatchElapsed(sw, nowMs))
  while (laps.length > MAX_LAPS) laps.shift()
  return { running: sw.running, startedAt: sw.startedAt, accumulatedMs: sw.accumulatedMs, laps: laps }
}

// Newest first: { index, split, total }.
function lapRows(laps) {
  var list = laps || []
  var out = []
  for (var i = list.length - 1; i >= 0; i--) {
    var total = Number(list[i]) || 0
    var previous = i > 0 ? Number(list[i - 1]) || 0 : 0
    out.push({ index: i + 1, split: Math.max(0, total - previous), total: total })
  }
  return out
}

// ---- World clocks ---------------------------------------------------------

var ZONE_RE = /^[A-Za-z][A-Za-z0-9_+\-]*(\/[A-Za-z0-9_+\-]+){0,2}$/

// A zone name is handed to `TZ=` in a subprocess and used as a file name
// under /usr/share/zoneinfo, so only the characters real zone names use
// pass.
function validZone(tz) {
  var s = String(tz === undefined || tz === null ? "" : tz)
  return s.length > 0 && s.length <= 64 && ZONE_RE.test(s) && s.indexOf("..") === -1
}

// "America/Argentina/Buenos_Aires" -> "Buenos Aires".
function zoneCity(tz) {
  var s = String(tz || "")
  var last = s.slice(s.lastIndexOf("/") + 1)
  return plainLabel(last.replace(/_/g, " "))
}

function parseCountries(text) {
  var out = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line || line.charAt(0) === "#") continue
    var parts = line.split("\t")
    if (parts.length < 2) continue
    out[parts[0].replace(/^\s+|\s+$/g, "")] = plainLabel(parts[1], 60)
  }
  return out
}

// zone1970.tab rows are "CC[,CC...]<tab>coords<tab>TZ[<tab>comment]".
// Produces picker options sorted by city, with the country and the zone's
// own comment in the description so a search for "eastern" or "india" lands.
function parseZoneTab(text, countries) {
  var raw = String(text || "")
  if (raw.length > MAX_ZONE_TAB_BYTES) raw = raw.slice(0, MAX_ZONE_TAB_BYTES)
  var lines = raw.split("\n")
  var names = countries || {}
  var out = []
  var seen = {}
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line || line.charAt(0) === "#") continue
    var parts = line.split("\t")
    if (parts.length < 3) continue
    var tz = parts[2].replace(/^\s+|\s+$/g, "")
    if (!validZone(tz) || seen[tz]) continue
    seen[tz] = true
    var codes = parts[0].split(",")
    var countryNames = []
    for (var c = 0; c < codes.length && c < 3; c++) {
      var name = names[codes[c]]
      if (name) countryNames.push(name)
    }
    var description = [tz]
    if (countryNames.length > 0) description.push(countryNames.join(", "))
    if (parts[3]) description.push(plainLabel(parts[3], 80))
    out.push({ value: tz, label: zoneCity(tz), description: description.join("  ·  ") })
  }
  if (!seen["UTC"]) out.push({ value: "UTC", label: "UTC", description: "Coordinated Universal Time" })
  out.sort(function(a, b) { return a.label.localeCompare(b.label) || a.value.localeCompare(b.value) })
  return out
}

function parseZoneList(text) {
  var lines = String(text || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var tz = lines[i].replace(/^\s+|\s+$/g, "")
    if (!validZone(tz)) continue
    out.push({ value: tz, label: zoneCity(tz), description: tz })
  }
  out.sort(function(a, b) { return a.label.localeCompare(b.label) || a.value.localeCompare(b.value) })
  return out
}

// "+0530" -> 330, "-0400" -> -240.
function offsetMinutes(text) {
  var m = String(text || "").match(/^([+-])(\d{2})(\d{2})$/)
  if (!m) return null
  var minutes = parseInt(m[2], 10) * 60 + parseInt(m[3], 10)
  return m[1] === "-" ? -minutes : minutes
}

// Lines of "zone<tab>+0200<tab>CEST" as the offsets script prints them.
function parseOffsets(text) {
  var out = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts.length < 2) continue
    var tz = parts[0].replace(/^\s+|\s+$/g, "")
    var offset = offsetMinutes(parts[1].replace(/^\s+|\s+$/g, ""))
    if (!validZone(tz) || offset === null) continue
    var abbr = parts.length > 2 ? plainLabel(parts[2], 8) : ""
    // `date +%Z` echoes the zone name back when it has no abbreviation.
    if (abbr === tz || /^[+-]\d/.test(abbr)) abbr = ""
    out[tz] = { offsetMin: offset, abbr: abbr }
  }
  return out
}

var MONTH_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// The wall clock in a zone `offsetMin` east of UTC, read off UTC getters.
// Shifting the instant and reading it back with local getters would be
// wrong for hours around every local daylight-saving change, because the
// local offset at the shifted instant is not the one at `nowMs`.
function zoneClock(nowMs, offsetMin) {
  var d = new Date((Number(nowMs) || 0) + (Number(offsetMin) || 0) * MINUTE_MS)
  return {
    hour: d.getUTCHours(),
    minute: d.getUTCMinutes(),
    weekday: d.getUTCDay(),
    day: d.getUTCDate(),
    month: d.getUTCMonth(),
    year: d.getUTCFullYear(),
    dayKey: d.getUTCFullYear() * 10000 + (d.getUTCMonth() + 1) * 100 + d.getUTCDate()
  }
}

function formatZoneTime(nowMs, offsetMin, hour12) {
  var z = zoneClock(nowMs, offsetMin)
  return formatTime(z.hour, z.minute, hour12)
}

// "Fri 4 Sep", in the zone's own calendar.
function zoneDateLabel(nowMs, offsetMin) {
  var z = zoneClock(nowMs, offsetMin)
  return DAY_SHORT[z.weekday] + " " + z.day + " " + MONTH_SHORT[z.month]
}

function localDayKey(ms) {
  var d = new Date(Number(ms) || 0)
  return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate()
}

// The zone's calendar day against the local one.
function zoneDayLabel(nowMs, offsetMin) {
  var here = localDayKey(nowMs)
  var there = zoneClock(nowMs, offsetMin).dayKey
  if (here === there) return "Today"
  return there > here ? "Tomorrow" : "Yesterday"
}

// "same time", "+6 h", "-4 h 30 min".
function offsetLabel(deltaMin) {
  var n = Math.round(Number(deltaMin) || 0)
  if (n === 0) return "same time"
  var sign = n > 0 ? "+" : "−"
  var abs = Math.abs(n)
  var h = Math.floor(abs / 60)
  var m = abs % 60
  return sign + (h > 0 ? h + " h" : "") + (h > 0 && m > 0 ? " " : "") + (m > 0 ? m + " min" : "")
}

function newClock(tz) {
  return { tz: String(tz), label: zoneCity(tz), pinned: true }
}

// ---- Bar label ------------------------------------------------------------
//
// One segment per live thing, in the order they matter: timers counting
// down, the stopwatch, the next alarm, the pinned world clocks. Nothing
// idle gets a segment, which is what makes the widget read as "something is
// going on" at a glance.

var ICON_CLOCK = "󰅐"      // nf-md-clock (outline)
var ICON_ALARM = "󰀠"      // nf-md-alarm
var ICON_SNOOZE = "󰚎"     // nf-md-alarm_snooze
var ICON_TIMER = "󰔟"      // nf-md-timer_sand
var ICON_STOPWATCH = "󱎫"  // nf-md-timer_outline
var ICON_PAUSE = "󰏤"      // nf-md-pause
var ICON_PLAY = "󰐊"       // nf-md-play
var ICON_DONE = "󰄬"       // nf-md-check
var ICON_WORLD = "󰇧"      // nf-md-earth
var ICON_BELL = "󰂓"       // nf-md-bell_ring
var ICON_PIN = "󰐃"        // nf-md-pin
var ICON_PIN_OFF = "󰐄"    // nf-md-pin_off
var ICON_FLAG = "󰈻"       // nf-md-flag
var ICON_REPLAY = "󰑙"     // nf-md-replay
var ICON_CLOSE = "󰅖"      // nf-md-close
var ICON_PENCIL = "󰏫"     // nf-md-pencil
var ICON_PLUS = "󰐕"       // nf-md-plus

// Each segment carries `text` for the horizontal bar and `time` — just the
// clock reading — for the vertical one, which has no room for a name or a
// weekday.
function barSegments(input) {
  var nowMs = Number(input.nowMs) || 0
  var segments = []
  var timers = sortTimers(input.timers || [], nowMs)
  for (var i = 0; i < timers.length; i++) {
    var t = timers[i]
    if (t.done) continue
    var left = formatRemaining(timerRemaining(t, nowMs))
    segments.push({
      kind: "timer",
      id: t.id,
      icon: t.running ? ICON_TIMER : ICON_PAUSE,
      text: left,
      time: left,
      detail: timerTitle(t) + (t.running ? " — " + left + " left" : " — paused at " + left),
      dim: !t.running
    })
  }

  var sw = input.stopwatch
  if (sw && (sw.running || stopwatchElapsed(sw, nowMs) > 0)) {
    var elapsed = formatClock(stopwatchElapsed(sw, nowMs))
    segments.push({
      kind: "stopwatch",
      id: "stopwatch",
      icon: sw.running ? ICON_STOPWATCH : ICON_PAUSE,
      text: elapsed,
      time: elapsed,
      detail: "Stopwatch " + (sw.running ? "running" : "paused") + " — " + elapsed,
      dim: !sw.running
    })
  }

  if (input.showNextAlarm !== false) {
    var next = nextAlarm(input.alarms || [], nowMs)
    if (next) {
      var snoozed = Number(next.alarm.snoozedUntil) > nowMs
      var sameDay = localDayKey(next.at) === localDayKey(nowMs)
      var timeText = formatTimeMs(next.at, input.hour12)
      segments.push({
        kind: "alarm",
        id: next.alarm.id,
        icon: snoozed ? ICON_SNOOZE : ICON_ALARM,
        text: sameDay ? timeText : DAY_SHORT[new Date(next.at).getDay()] + " " + timeText,
        time: timeText,
        detail: (next.alarm.label ? next.alarm.label + " " : "Alarm ") + (snoozed ? "snoozed until " : "at ") + timeText + " (" + relativeTime(nowMs, next.at) + ")",
        dim: false
      })
    }
  }

  var clocks = input.clocks || []
  var offsets = input.offsets || {}
  var first = true
  for (var c = 0; c < clocks.length; c++) {
    var clock = clocks[c]
    if (!clock.pinned) continue
    var info = offsets[clock.tz]
    if (!info) continue
    var shown = formatZoneTime(nowMs, info.offsetMin, input.hour12)
    segments.push({
      kind: "clock",
      id: clock.tz,
      icon: first ? ICON_WORLD : "",
      text: clock.label + " " + shown,
      time: shown,
      detail: clock.label + " " + shown + " (" + offsetLabel(info.offsetMin - (Number(input.localOffsetMin) || 0)) + ")",
      dim: false
    })
    first = false
  }
  return segments
}

function barText(segments) {
  var parts = []
  for (var i = 0; i < segments.length; i++) {
    var s = segments[i]
    parts.push(s.icon ? s.icon + " " + s.text : s.text)
  }
  return parts.join("   ")
}

// A vertical bar stacks one short line per glyph slot: the icon, then the
// time split at its colons, with no AM/PM. World clocks drop their name and
// share one globe; there is no room.
function barLines(segments) {
  var lines = []
  for (var i = 0; i < segments.length; i++) {
    var s = segments[i]
    if (s.kind === "clock") {
      if (lines.indexOf(ICON_WORLD) === -1) lines.push(ICON_WORLD)
    } else if (s.icon) {
      lines.push(s.icon)
    }
    var pieces = String(s.time || "").replace(/\s*(AM|PM)$/, "").split(":")
    for (var p = 0; p < pieces.length; p++) if (pieces[p] !== "") lines.push(pieces[p])
  }
  return lines
}

// ---- Persisted state -------------------------------------------------------

function emptyState() {
  return { version: 1, alarms: [], timers: [], stopwatch: emptyStopwatch(), clocks: [] }
}

function normalizeAlarm(raw) {
  if (!raw || typeof raw !== "object") return null
  var id = safeId(raw.id)
  var hour = intField(raw.hour)
  var minute = intField(raw.minute)
  if (!id || !isFinite(hour) || !isFinite(minute)) return null
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59 || Math.round(hour) !== hour || Math.round(minute) !== minute) return null
  return {
    id: id,
    hour: hour,
    minute: minute,
    label: plainLabel(raw.label),
    enabled: toBool(raw.enabled, true),
    days: normalizeDays(raw.days),
    snoozedUntil: finiteAt(raw.snoozedUntil),
    lastFiredAt: finiteAt(raw.lastFiredAt),
    armedAt: finiteAt(raw.armedAt),
    autoSnoozes: clampInt(raw.autoSnoozes, 0, 99, 0)
  }
}

function normalizeTimer(raw) {
  if (!raw || typeof raw !== "object") return null
  var id = safeId(raw.id)
  var duration = Number(raw.durationMs) || 0
  if (!id || duration < MIN_TIMER_MS || duration > MAX_TIMER_MS) return null
  var running = toBool(raw.running, false)
  var endsAt = finiteAt(raw.endsAt)
  // A running timer with no end instant cannot count; keep it as a paused
  // one rather than reporting it missed at the first tick.
  if (running && endsAt <= 0) running = false
  var done = toBool(raw.done, false) && !running
  var remaining = Number(raw.remainingMs)
  if (!isFinite(remaining)) remaining = duration
  return {
    id: id,
    label: plainLabel(raw.label),
    durationMs: Math.round(duration),
    endsAt: running ? endsAt : 0,
    remainingMs: done ? 0 : Math.max(0, Math.min(duration, remaining)),
    running: running,
    done: done,
    doneAt: done ? finiteAt(raw.doneAt) : 0,
    createdAt: finiteAt(raw.createdAt)
  }
}

function normalizeStopwatch(raw) {
  var sw = emptyStopwatch()
  if (!raw || typeof raw !== "object") return sw
  sw.running = toBool(raw.running, false)
  sw.startedAt = sw.running ? finiteAt(raw.startedAt) : 0
  sw.accumulatedMs = finiteAt(raw.accumulatedMs)
  var laps = raw.laps && typeof raw.laps.length === "number" ? raw.laps : []
  var previous = 0
  for (var i = 0; i < laps.length && sw.laps.length < MAX_LAPS; i++) {
    var n = finiteAt(laps[i])
    if (n < previous || (n === 0 && laps[i] !== 0)) continue
    sw.laps.push(n)
    previous = n
  }
  if (sw.running && sw.startedAt === 0) sw.running = false
  return sw
}

function normalizeClock(raw) {
  if (!raw || typeof raw !== "object") return null
  var tz = String(raw.tz || "")
  if (!validZone(tz)) return null
  var label = plainLabel(raw.label)
  return { tz: tz, label: label || zoneCity(tz), pinned: toBool(raw.pinned, true) }
}

function normalizeState(raw) {
  var state = emptyState()
  if (!raw || typeof raw !== "object") return state
  var alarms = raw.alarms && typeof raw.alarms.length === "number" ? raw.alarms : []
  var seen = {}
  for (var a = 0; a < alarms.length && state.alarms.length < MAX_ALARMS; a++) {
    var alarm = normalizeAlarm(alarms[a])
    if (alarm && !seen[alarm.id]) { seen[alarm.id] = true; state.alarms.push(alarm) }
  }
  var timers = raw.timers && typeof raw.timers.length === "number" ? raw.timers : []
  var seenTimers = {}
  for (var t = 0; t < timers.length && state.timers.length < MAX_TIMERS; t++) {
    var timer = normalizeTimer(timers[t])
    if (timer && !seenTimers[timer.id]) { seenTimers[timer.id] = true; state.timers.push(timer) }
  }
  state.stopwatch = normalizeStopwatch(raw.stopwatch)
  var clocks = raw.clocks && typeof raw.clocks.length === "number" ? raw.clocks : []
  var seenZones = {}
  for (var c = 0; c < clocks.length && state.clocks.length < MAX_CLOCKS; c++) {
    var clock = normalizeClock(clocks[c])
    if (clock && !seenZones[clock.tz]) { seenZones[clock.tz] = true; state.clocks.push(clock) }
  }
  return state
}

// The state file, or an empty state for a blank/missing file. Null means the
// file is present but not something to trust (oversized, not JSON, wrong
// version); the caller keeps what it has rather than overwrite it.
function parseState(text) {
  var raw = String(text === undefined || text === null ? "" : text)
  if (raw.replace(/^\s+|\s+$/g, "") === "") return emptyState()
  if (raw.length > MAX_STATE_BYTES) return null
  var parsed
  try { parsed = JSON.parse(raw) } catch (e) { return null }
  if (!parsed || typeof parsed !== "object" || parsed.version !== 1) return null
  return normalizeState(parsed)
}

function serializeState(alarms, timers, stopwatch, clocks) {
  return JSON.stringify({
    version: 1,
    alarms: alarms || [],
    timers: timers || [],
    stopwatch: stopwatch || emptyStopwatch(),
    clocks: clocks || []
  }, null, 2) + "\n"
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_LABEL: MAX_LABEL, MAX_ALARMS: MAX_ALARMS, MAX_TIMERS: MAX_TIMERS, MAX_CLOCKS: MAX_CLOCKS, MAX_LAPS: MAX_LAPS,
    MAX_STATE_BYTES: MAX_STATE_BYTES, MAX_INSTANT_MS: MAX_INSTANT_MS, GRACE_MS: GRACE_MS, MIN_TIMER_MS: MIN_TIMER_MS, MAX_TIMER_MS: MAX_TIMER_MS,
    TIMER_EXTEND_MS: TIMER_EXTEND_MS, MAX_AUTO_SNOOZES: MAX_AUTO_SNOOZES,
    WEEK_ORDER: WEEK_ORDER, WEEK_LETTERS: WEEK_LETTERS, DAY_SHORT: DAY_SHORT,
    ICON_CLOCK: ICON_CLOCK, ICON_ALARM: ICON_ALARM, ICON_SNOOZE: ICON_SNOOZE, ICON_TIMER: ICON_TIMER,
    ICON_STOPWATCH: ICON_STOPWATCH, ICON_PAUSE: ICON_PAUSE, ICON_PLAY: ICON_PLAY, ICON_DONE: ICON_DONE,
    ICON_WORLD: ICON_WORLD, ICON_BELL: ICON_BELL, ICON_PIN: ICON_PIN, ICON_PIN_OFF: ICON_PIN_OFF, ICON_FLAG: ICON_FLAG,
    ICON_REPLAY: ICON_REPLAY, ICON_CLOSE: ICON_CLOSE, ICON_PENCIL: ICON_PENCIL, ICON_PLUS: ICON_PLUS,
    plainLabel: plainLabel, pad2: pad2, clampInt: clampInt, toBool: toBool, finiteAt: finiteAt, intField: intField, newId: newId, safeId: safeId,
    parseDuration: parseDuration, formatClock: formatClock, formatRemaining: formatRemaining, humanDuration: humanDuration,
    relativeTime: relativeTime, parseTime: parseTime, maskTime: maskTime, formatTime: formatTime, formatTimeMs: formatTimeMs,
    normalizeDays: normalizeDays, daysLabel: daysLabel, toggleDay: toggleDay,
    occurrenceAfter: occurrenceAfter, occurrenceAtOrBefore: occurrenceAtOrBefore, alarmNextAt: alarmNextAt, alarmDue: alarmDue,
    isRepeating: isRepeating, nextAlarm: nextAlarm, alarmSummary: alarmSummary, sortAlarms: sortAlarms,
    newTimer: newTimer, timerRemaining: timerRemaining, timerProgress: timerProgress, pausedTimer: pausedTimer,
    resumedTimer: resumedTimer, resetTimer: resetTimer, restartedTimer: restartedTimer, finishedTimer: finishedTimer,
    extendedTimer: extendedTimer, sortTimers: sortTimers, timerTitle: timerTitle,
    emptyStopwatch: emptyStopwatch, stopwatchElapsed: stopwatchElapsed, stopwatchStarted: stopwatchStarted,
    stopwatchPaused: stopwatchPaused, stopwatchLapped: stopwatchLapped, lapRows: lapRows,
    validZone: validZone, zoneCity: zoneCity, parseCountries: parseCountries, parseZoneTab: parseZoneTab, parseZoneList: parseZoneList,
    offsetMinutes: offsetMinutes, parseOffsets: parseOffsets, zoneClock: zoneClock, formatZoneTime: formatZoneTime,
    zoneDateLabel: zoneDateLabel, localDayKey: localDayKey, zoneDayLabel: zoneDayLabel, offsetLabel: offsetLabel, newClock: newClock,
    barSegments: barSegments, barText: barText, barLines: barLines,
    emptyState: emptyState, normalizeAlarm: normalizeAlarm, normalizeTimer: normalizeTimer, normalizeStopwatch: normalizeStopwatch,
    normalizeClock: normalizeClock, normalizeState: normalizeState, parseState: parseState, serializeState: serializeState
  }
}
