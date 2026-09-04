// Model.js under node: the file has no Qt in it, so it loads into a bare
// context and every top-level function becomes a property of that context.
//
//   node test/model.test.js

process.env.TZ = "Europe/Copenhagen"

const assert = require("assert")
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma.*$/m, "")
const M = {}
vm.createContext(M)
vm.runInContext(source, M)

// Values built inside the vm context carry that context's Array prototype,
// which deepStrictEqual treats as a different type. Compare plain JSON.
function plain(value) {
  return JSON.parse(JSON.stringify(value))
}

let passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
  } catch (error) {
    console.error("FAIL " + name)
    console.error(error && error.stack ? error.stack : error)
    process.exitCode = 1
  }
}

// Friday 4 September 2026, 14:00 local (CEST, UTC+2).
const NOW = new Date(2026, 8, 4, 14, 0, 0).getTime()
const MIN = 60 * 1000
const HOUR = 60 * MIN

test("plainLabel strips control characters, brackets and length", () => {
  assert.strictEqual(M.plainLabel("a\u0000b\u001bc"), "a b c")
  assert.strictEqual(M.plainLabel("  spaced   out  "), "spaced out")
  assert.strictEqual(M.plainLabel('<img src="x">'), '‹img src="x"›')
  assert.strictEqual(M.plainLabel("x".repeat(500)).length, M.MAX_LABEL)
  assert.strictEqual(M.plainLabel("x".repeat(500), 10), "x".repeat(9) + "…")
  assert.strictEqual(M.plainLabel(null), "")
  assert.strictEqual(M.plainLabel("Wake up — gym"), "Wake up — gym")
})

test("parseDuration accepts the ways people write a timer", () => {
  assert.strictEqual(M.parseDuration("5"), 5 * MIN)
  assert.strictEqual(M.parseDuration("0.5"), 30 * 1000)
  assert.strictEqual(M.parseDuration("90s"), 90 * 1000)
  assert.strictEqual(M.parseDuration("1h30m"), 90 * MIN)
  assert.strictEqual(M.parseDuration("1h 30m 10s"), 90 * MIN + 10 * 1000)
  assert.strictEqual(M.parseDuration("1.5h"), 90 * MIN)
  assert.strictEqual(M.parseDuration("2 hours"), 2 * HOUR)
  assert.strictEqual(M.parseDuration("12:30"), 12 * MIN + 30 * 1000)
  assert.strictEqual(M.parseDuration("1:02:03"), HOUR + 2 * MIN + 3 * 1000)
  assert.strictEqual(M.parseDuration("  10 min "), 10 * MIN)
})

test("parseDuration refuses what is not a duration", () => {
  for (const bad of ["", "abc", "5x", "1h30", "12:75", "0", "0s", "100h", "-5", "1e3", "5m 3q", null]) {
    assert.strictEqual(M.parseDuration(bad), 0, JSON.stringify(bad))
  }
})

test("formatClock, formatRemaining and humanDuration", () => {
  assert.strictEqual(M.formatClock(0), "00:00")
  assert.strictEqual(M.formatClock(12345), "00:12")
  assert.strictEqual(M.formatClock(12345, { tenths: true }), "00:12.3")
  assert.strictEqual(M.formatClock(HOUR + 4 * MIN + 59 * 1000), "1:04:59")
  assert.strictEqual(M.formatClock(59 * 1000, { forceHours: true }), "0:00:59")
  assert.strictEqual(M.formatRemaining(5 * MIN), "05:00")
  assert.strictEqual(M.formatRemaining(5 * MIN - 1), "05:00")
  assert.strictEqual(M.formatRemaining(999), "00:01")
  assert.strictEqual(M.formatRemaining(0), "00:00")
  assert.strictEqual(M.humanDuration(5 * MIN), "5 min")
  assert.strictEqual(M.humanDuration(90 * MIN), "1 h 30 min")
  assert.strictEqual(M.humanDuration(45 * 1000), "45 s")
  assert.strictEqual(M.humanDuration(HOUR), "1 h")
  assert.strictEqual(M.humanDuration(0), "0 s")
})

test("relativeTime", () => {
  assert.strictEqual(M.relativeTime(NOW, NOW), "now")
  assert.strictEqual(M.relativeTime(NOW, NOW + 45 * 1000), "in 45 s")
  assert.strictEqual(M.relativeTime(NOW, NOW + 5 * MIN), "in 5 min")
  assert.strictEqual(M.relativeTime(NOW, NOW + 8 * HOUR + 12 * MIN), "in 8 h 12 min")
  assert.strictEqual(M.relativeTime(NOW, NOW + 2 * HOUR), "in 2 h")
  assert.strictEqual(M.relativeTime(NOW, NOW + 26 * HOUR), "in 1 day 2 h")
  assert.strictEqual(M.relativeTime(NOW, NOW - 5 * MIN), "5 min ago")
})

test("parseTime accepts common spellings and refuses nonsense", () => {
  assert.deepStrictEqual(plain(M.parseTime("7:30")), { hour: 7, minute: 30 })
  assert.deepStrictEqual(plain(M.parseTime("07:30")), { hour: 7, minute: 30 })
  assert.deepStrictEqual(plain(M.parseTime("730")), { hour: 7, minute: 30 })
  assert.deepStrictEqual(plain(M.parseTime("7")), { hour: 7, minute: 0 })
  assert.deepStrictEqual(plain(M.parseTime("19.30")), { hour: 19, minute: 30 })
  assert.deepStrictEqual(plain(M.parseTime("7:30 pm")), { hour: 19, minute: 30 })
  assert.deepStrictEqual(plain(M.parseTime("7pm")), { hour: 19, minute: 0 })
  assert.deepStrictEqual(plain(M.parseTime("12am")), { hour: 0, minute: 0 })
  assert.deepStrictEqual(plain(M.parseTime("12:15 PM")), { hour: 12, minute: 15 })
  assert.deepStrictEqual(plain(M.parseTime("0:00")), { hour: 0, minute: 0 })
  assert.deepStrictEqual(plain(M.parseTime("23:59")), { hour: 23, minute: 59 })
  assert.deepStrictEqual(plain(M.parseTime("1234")), { hour: 12, minute: 34 })
  for (const bad of ["", "24:00", "7:60", "13pm", "0pm", "x", "7:3", "12345", "7:30:00", null]) {
    assert.strictEqual(M.parseTime(bad), null, JSON.stringify(bad))
  }
})

test("maskTime puts the colon in as the hour completes", () => {
  // Typed one key at a time.
  assert.strictEqual(M.maskTime(""), "")
  assert.strictEqual(M.maskTime("0"), "0")
  assert.strictEqual(M.maskTime("07"), "07:")
  assert.strictEqual(M.maskTime("07:3"), "07:3")
  assert.strictEqual(M.maskTime("07:30"), "07:30")
  assert.strictEqual(M.maskTime("07:305"), "07:30", "nothing past the minutes")
  assert.strictEqual(M.maskTime("7"), "7:", "a 7 can only be a whole hour")
  assert.strictEqual(M.maskTime("7:3"), "7:3")
  assert.strictEqual(M.maskTime("7:30"), "7:30")
  assert.strictEqual(M.maskTime("1"), "1")
  assert.strictEqual(M.maskTime("12"), "12:")
  assert.strictEqual(M.maskTime("2"), "2")
  assert.strictEqual(M.maskTime("23"), "23:")
  assert.strictEqual(M.maskTime("24"), "2:4", "24 is not an hour, so 2 was the hour")
  assert.strictEqual(M.maskTime("2:40"), "2:40")
  // Pasted or prefilled.
  assert.strictEqual(M.maskTime("0730"), "07:30")
  assert.strictEqual(M.maskTime("730"), "7:30")
  assert.strictEqual(M.maskTime("19.30"), "19:30")
  // 12-hour suffixes ride along.
  assert.strictEqual(M.maskTime("7:30p"), "7:30 p")
  assert.strictEqual(M.maskTime("7:30 pm"), "7:30 pm")
  assert.strictEqual(M.maskTime("12:15 AM"), "12:15 am")
  assert.strictEqual(M.maskTime("p"), "", "letters alone are nothing")
  // Everything the mask produces is something parseTime accepts once complete.
  for (const typed of ["0730", "730", "1200", "2359", "24", "7:30pm", "1215am"]) {
    const masked = M.maskTime(typed)
    assert.ok(M.parseTime(masked) !== null || masked.length < 4, typed + " -> " + masked)
  }
  assert.deepStrictEqual(plain(M.parseTime(M.maskTime("24"))), null, "2:4 is still incomplete")
  assert.deepStrictEqual(plain(M.parseTime(M.maskTime("240"))), { hour: 2, minute: 40 })
})

test("formatTime in 24 h and 12 h", () => {
  assert.strictEqual(M.formatTime(7, 5, false), "07:05")
  assert.strictEqual(M.formatTime(7, 5, true), "7:05 AM")
  assert.strictEqual(M.formatTime(0, 0, true), "12:00 AM")
  assert.strictEqual(M.formatTime(12, 30, true), "12:30 PM")
  assert.strictEqual(M.formatTime(19, 30, true), "7:30 PM")
  assert.strictEqual(M.formatTimeMs(NOW, false), "14:00")
})

test("days: normalize, label, toggle", () => {
  assert.deepStrictEqual(plain(M.normalizeDays([5, 1, 1, 9, "3", -1, 2.5])), [1, 3, 5])
  assert.deepStrictEqual(plain(M.normalizeDays("1,2,3")), [1, 2, 3])
  assert.deepStrictEqual(plain(M.normalizeDays("")), [], "an empty IPC argument means no days, not Sunday")
  assert.deepStrictEqual(plain(M.normalizeDays("  ")), [])
  assert.deepStrictEqual(plain(M.normalizeDays([""])), [])
  assert.deepStrictEqual(plain(M.normalizeDays(null)), [])
  assert.strictEqual(M.daysLabel([]), "Once")
  assert.strictEqual(M.daysLabel([0, 1, 2, 3, 4, 5, 6]), "Every day")
  assert.strictEqual(M.daysLabel([1, 2, 3, 4, 5]), "Weekdays")
  assert.strictEqual(M.daysLabel([0, 6]), "Weekends")
  assert.strictEqual(M.daysLabel([1, 3, 5]), "Mon, Wed, Fri")
  assert.strictEqual(M.daysLabel([0, 1]), "Mon, Sun")
  assert.deepStrictEqual(plain(M.toggleDay([1, 2], 3)), [1, 2, 3])
  assert.deepStrictEqual(plain(M.toggleDay([1, 2], 2)), [1])
})

function alarm(patch) {
  return Object.assign({ id: "a1", hour: 7, minute: 30, label: "", enabled: true, days: [], snoozedUntil: 0, lastFiredAt: 0, armedAt: 0, autoSnoozes: 0 }, patch)
}

function at(dayOffset, hour, minute) {
  return new Date(2026, 8, 4 + dayOffset, hour, minute, 0, 0).getTime()
}

test("alarm occurrences walk the schedule in local time", () => {
  const once = alarm({ hour: 7, minute: 30 })
  assert.strictEqual(M.occurrenceAfter(once, NOW), at(1, 7, 30), "07:30 has passed today, so tomorrow")
  assert.strictEqual(M.occurrenceAfter(alarm({ hour: 15, minute: 0 }), NOW), at(0, 15, 0))
  assert.strictEqual(M.occurrenceAtOrBefore(once, NOW), at(0, 7, 30))
  assert.strictEqual(M.occurrenceAtOrBefore(alarm({ hour: 15, minute: 0 }), NOW), at(-1, 15, 0))
  // Friday 4 Sep; weekdays only: next after Friday 07:30 is Monday.
  const weekdays = alarm({ days: [1, 2, 3, 4, 5] })
  assert.strictEqual(M.occurrenceAfter(weekdays, NOW), at(3, 7, 30))
  assert.strictEqual(M.occurrenceAtOrBefore(alarm({ days: [0, 6] }), NOW), at(-5, 7, 30), "last Sunday")
  assert.strictEqual(M.occurrenceAfter(alarm({ days: [6] }), NOW), at(1, 7, 30), "Saturday")
})

test("a freshly created alarm never fires for an occurrence already behind it", () => {
  const created = alarm({ armedAt: NOW })
  assert.strictEqual(M.alarmDue(created, NOW), null)
  assert.strictEqual(M.alarmDue(created, NOW + 5 * MIN), null)
  assert.strictEqual(M.alarmNextAt(created, NOW), at(1, 7, 30))
  const due = M.alarmDue(created, at(1, 7, 30))
  assert.deepStrictEqual(plain(due), { at: at(1, 7, 30), kind: "scheduled" })
  // Created thirty seconds before its own time: rings on time.
  const soon = alarm({ hour: 14, minute: 1, armedAt: NOW + 30 * 1000 })
  assert.strictEqual(M.alarmDue(soon, NOW + 45 * 1000), null)
  assert.deepStrictEqual(plain(M.alarmDue(soon, at(0, 14, 1))), { at: at(0, 14, 1), kind: "scheduled" })
})

test("an occurrence fires once, then the schedule moves on", () => {
  const fired = alarm({ days: [1, 2, 3, 4, 5], armedAt: at(-3, 12, 0), lastFiredAt: at(0, 7, 30) })
  assert.strictEqual(M.alarmDue(fired, NOW), null)
  assert.strictEqual(M.alarmNextAt(fired, NOW), at(3, 7, 30))
  const missed = alarm({ days: [1, 2, 3, 4, 5], armedAt: at(-3, 12, 0), lastFiredAt: at(-1, 7, 30) })
  assert.deepStrictEqual(plain(M.alarmDue(missed, NOW)), { at: at(0, 7, 30), kind: "scheduled" }, "today's ring is still owed")
  assert.strictEqual(NOW - M.alarmDue(missed, NOW).at > M.GRACE_MS, true, "and it is too old to ring now")
})

test("snooze outranks the schedule and works on a disabled one-shot", () => {
  const snoozed = alarm({ enabled: false, snoozedUntil: NOW + 9 * MIN, lastFiredAt: at(0, 7, 30) })
  assert.strictEqual(M.alarmNextAt(snoozed, NOW), NOW + 9 * MIN)
  assert.strictEqual(M.alarmDue(snoozed, NOW), null)
  assert.deepStrictEqual(plain(M.alarmDue(snoozed, NOW + 9 * MIN)), { at: NOW + 9 * MIN, kind: "snooze" })
  assert.strictEqual(M.alarmNextAt(alarm({ enabled: false }), NOW), 0)
})

test("nextAlarm picks the soonest across alarms", () => {
  const list = [alarm({ id: "a", hour: 22, minute: 0, armedAt: NOW }), alarm({ id: "b", hour: 16, minute: 45, armedAt: NOW }), alarm({ id: "c", enabled: false })]
  const next = M.nextAlarm(list, NOW)
  assert.strictEqual(next.alarm.id, "b")
  assert.strictEqual(next.at, at(0, 16, 45))
  assert.strictEqual(M.nextAlarm([], NOW), null)
  assert.strictEqual(M.alarmSummary(list[1], NOW, false), "Once  ·  in 2 h 45 min")
  assert.strictEqual(M.alarmSummary(alarm({ label: "Gym", days: [1, 3, 5], armedAt: NOW }), NOW, false), "Gym  ·  Mon, Wed, Fri  ·  in 2 days 18 h")
})

test("timers are defined by their end instant", () => {
  const t = M.newTimer(5 * MIN, "Tea", NOW)
  assert.strictEqual(t.running, true)
  assert.strictEqual(t.endsAt, NOW + 5 * MIN)
  assert.strictEqual(M.timerRemaining(t, NOW + 2 * MIN), 3 * MIN)
  assert.strictEqual(M.timerRemaining(t, NOW + 9 * MIN), 0)
  assert.strictEqual(M.timerProgress(t, NOW + 2 * MIN), 0.4)
  const paused = M.pausedTimer(t, NOW + 2 * MIN)
  assert.strictEqual(paused.running, false)
  assert.strictEqual(paused.remainingMs, 3 * MIN)
  assert.strictEqual(M.timerRemaining(paused, NOW + HOUR), 3 * MIN, "a paused timer does not move")
  const resumed = M.resumedTimer(paused, NOW + HOUR)
  assert.strictEqual(resumed.endsAt, NOW + HOUR + 3 * MIN)
  const finished = M.finishedTimer(resumed)
  assert.strictEqual(finished.done, true)
  assert.strictEqual(finished.doneAt, NOW + HOUR + 3 * MIN)
  assert.strictEqual(M.timerRemaining(finished, NOW + 2 * HOUR), 0)
  const reset = M.resetTimer(finished)
  assert.strictEqual(reset.remainingMs, 5 * MIN)
  assert.strictEqual(reset.done, false)
  const restarted = M.restartedTimer(finished, NOW + 3 * HOUR)
  assert.strictEqual(restarted.endsAt, NOW + 3 * HOUR + 5 * MIN)
  assert.strictEqual(M.timerTitle(t), "Tea")
  assert.strictEqual(M.timerTitle(M.newTimer(90 * MIN, "", NOW)), "1 h 30 min timer")
})

test("extending a timer", () => {
  const t = M.newTimer(5 * MIN, "", NOW)
  assert.strictEqual(M.extendedTimer(t, NOW + MIN).endsAt, NOW + 10 * MIN)
  const done = M.finishedTimer(t)
  const again = M.extendedTimer(done, NOW + HOUR)
  assert.strictEqual(again.running, true)
  assert.strictEqual(again.durationMs, M.TIMER_EXTEND_MS)
  assert.strictEqual(again.endsAt, NOW + HOUR + M.TIMER_EXTEND_MS)
  const paused = M.pausedTimer(t, NOW + MIN)
  assert.strictEqual(M.extendedTimer(paused, NOW + MIN, 2 * MIN).remainingMs, 6 * MIN)
})

test("sortTimers: running by remaining, then paused, then done", () => {
  const a = Object.assign(M.newTimer(10 * MIN, "", NOW), { id: "a" })
  const b = Object.assign(M.newTimer(2 * MIN, "", NOW), { id: "b" })
  const c = Object.assign(M.pausedTimer(M.newTimer(1 * MIN, "", NOW), NOW), { id: "c" })
  const d = Object.assign(M.finishedTimer(M.newTimer(1 * MIN, "", NOW)), { id: "d" })
  assert.deepStrictEqual(plain(M.sortTimers([d, c, a, b], NOW).map(t => t.id)), ["b", "a", "c", "d"])
})

test("stopwatch", () => {
  let sw = M.emptyStopwatch()
  assert.strictEqual(M.stopwatchElapsed(sw, NOW), 0)
  sw = M.stopwatchStarted(sw, NOW)
  assert.strictEqual(M.stopwatchElapsed(sw, NOW + 12345), 12345)
  sw = M.stopwatchLapped(sw, NOW + 5000)
  sw = M.stopwatchLapped(sw, NOW + 12000)
  sw = M.stopwatchPaused(sw, NOW + 20000)
  assert.strictEqual(sw.running, false)
  assert.strictEqual(M.stopwatchElapsed(sw, NOW + HOUR), 20000)
  sw = M.stopwatchStarted(sw, NOW + HOUR)
  assert.strictEqual(M.stopwatchElapsed(sw, NOW + HOUR + 1000), 21000)
  assert.deepStrictEqual(plain(M.lapRows(sw.laps)), [
    { index: 2, split: 7000, total: 12000 },
    { index: 1, split: 5000, total: 5000 }
  ])
  let many = M.emptyStopwatch()
  many = M.stopwatchStarted(many, NOW)
  for (let i = 0; i < M.MAX_LAPS + 5; i++) many = M.stopwatchLapped(many, NOW + i * 1000)
  assert.strictEqual(many.laps.length, M.MAX_LAPS)
})

test("zone names are validated before they reach TZ= or a file path", () => {
  for (const ok of ["UTC", "Europe/Copenhagen", "America/Argentina/Buenos_Aires", "Etc/GMT+3", "America/Port-au-Prince"]) {
    assert.strictEqual(M.validZone(ok), true, ok)
  }
  for (const bad of ["", "../etc/passwd", "Europe/../x", "/etc/localtime", "a b", "x;y", "Europe/Copenhagen/x/y", "x".repeat(70), "$(id)", null]) {
    assert.strictEqual(M.validZone(bad), false, JSON.stringify(bad))
  }
  assert.strictEqual(M.zoneCity("America/New_York"), "New York")
  assert.strictEqual(M.zoneCity("America/Argentina/Buenos_Aires"), "Buenos Aires")
  assert.strictEqual(M.zoneCity("UTC"), "UTC")
})

test("zone tables become picker options with country and comment", () => {
  const countries = M.parseCountries("# comment\nUS\tUnited States\nCA\tCanada\nDK\tDenmark\n")
  const tab = [
    "# zone1970.tab",
    "US\t+404251-0740023\tAmerica/New_York\tEastern (most areas)",
    "CA,BS\t+4339-07923\tAmerica/Toronto\tEastern - ON & QC (most areas)",
    "DK\t+5541+01235\tEurope/Copenhagen",
    "XX\t+0000+00000\t../evil",
    "bad line"
  ].join("\n")
  const options = M.parseZoneTab(tab, countries)
  assert.deepStrictEqual(plain(options.map(o => o.value)), ["Europe/Copenhagen", "America/New_York", "America/Toronto", "UTC"])
  assert.strictEqual(options[1].label, "New York")
  assert.strictEqual(options[1].description, "America/New_York  ·  United States  ·  Eastern (most areas)")
  assert.strictEqual(options[2].description, "America/Toronto  ·  Canada  ·  Eastern - ON & QC (most areas)")
  assert.strictEqual(options[0].description, "Europe/Copenhagen  ·  Denmark")
  const list = M.parseZoneList("Europe/Oslo\nbad name\nAsia/Tokyo\n")
  assert.deepStrictEqual(plain(list.map(o => o.value)), ["Europe/Oslo", "Asia/Tokyo"])
})

test("offsets from the date script", () => {
  assert.strictEqual(M.offsetMinutes("+0530"), 330)
  assert.strictEqual(M.offsetMinutes("-0400"), -240)
  assert.strictEqual(M.offsetMinutes("+0000"), 0)
  assert.strictEqual(M.offsetMinutes("0530"), null)
  const parsed = M.parseOffsets("America/New_York\t-0400\tEDT\nAsia/Kolkata\t+0530\tIST\nEtc/GMT+3\t-0300\t-03\n../x\t+0000\tX\njunk\n")
  assert.deepStrictEqual(plain(parsed), {
    "America/New_York": { offsetMin: -240, abbr: "EDT" },
    "Asia/Kolkata": { offsetMin: 330, abbr: "IST" },
    "Etc/GMT+3": { offsetMin: -180, abbr: "" }
  })
})

test("zone time is the wall clock there, read off UTC", () => {
  // Local is UTC+2 at NOW; New York is UTC-4: six hours behind.
  assert.strictEqual(-new Date(NOW).getTimezoneOffset(), 120)
  assert.strictEqual(M.formatZoneTime(NOW, -240, false), "08:00")
  assert.strictEqual(M.formatZoneTime(NOW, -240, true), "8:00 AM")
  assert.strictEqual(M.zoneDayLabel(NOW, -240), "Today")
  assert.strictEqual(M.zoneDateLabel(NOW, -240), "Fri 4 Sep")
  assert.strictEqual(M.formatZoneTime(NOW, 540, false), "21:00")
  assert.strictEqual(M.formatZoneTime(NOW, 720, false), "00:00")
  assert.strictEqual(M.zoneDayLabel(NOW, 720), "Tomorrow")
  assert.strictEqual(M.zoneDateLabel(NOW, 720), "Sat 5 Sep")
  const morning = new Date(2026, 8, 4, 8, 0).getTime()
  assert.strictEqual(M.zoneDayLabel(morning, -600), "Yesterday")
  assert.deepStrictEqual(plain(M.zoneClock(NOW, 330)), { hour: 17, minute: 30, weekday: 5, day: 4, month: 8, year: 2026, dayKey: 20260904 })
  assert.strictEqual(M.offsetLabel(0), "same time")
  assert.strictEqual(M.offsetLabel(-360), "−6 h")
  assert.strictEqual(M.offsetLabel(210), "+3 h 30 min")
  assert.strictEqual(M.offsetLabel(30), "+30 min")
  assert.deepStrictEqual(plain(M.newClock("Asia/Tokyo")), { tz: "Asia/Tokyo", label: "Tokyo", pinned: true })
})

test("zone times are right around the local daylight-saving changes", () => {
  // Copenhagen springs forward on Sun 29 Mar 2026 (CET -> CEST) and falls
  // back on Sun 25 Oct 2026. Reading a shifted instant back through local
  // getters used to be an hour off whenever the shift crossed those.
  const springMorning = new Date(2026, 2, 29, 8, 0).getTime()      // CEST, UTC+2
  assert.strictEqual(M.formatZoneTime(springMorning, -240, false), "02:00", "New York (EDT) while Copenhagen is on CEST")
  const springEve = new Date(2026, 2, 28, 20, 0).getTime()          // CET, UTC+1
  assert.strictEqual(M.formatZoneTime(springEve, 540, false), "04:00", "Tokyo the night before the change")
  assert.strictEqual(M.zoneDayLabel(springEve, 540), "Tomorrow")
  const autumnMidnight = new Date(2026, 9, 25, 0, 0).getTime()      // CEST, UTC+2, hours before the fall back
  assert.strictEqual(M.formatZoneTime(autumnMidnight, 540, false), "07:00", "Tokyo across the autumn change")
  const summer = new Date(2026, 6, 1, 12, 0).getTime()
  assert.strictEqual(M.formatZoneTime(summer, -240, false), "06:00")
})

test("bar segments show only what is live, in order", () => {
  const local = 120
  const input = {
    nowMs: NOW,
    timers: [M.newTimer(5 * MIN, "Tea", NOW - MIN), M.pausedTimer(M.newTimer(10 * MIN, "", NOW), NOW), M.finishedTimer(M.newTimer(MIN, "", NOW - HOUR))],
    stopwatch: M.stopwatchStarted(M.emptyStopwatch(), NOW - 83 * 1000),
    alarms: [alarm({ hour: 16, minute: 45, label: "Call", armedAt: NOW - HOUR })],
    clocks: [M.newClock("America/New_York"), Object.assign(M.newClock("Asia/Tokyo"), { pinned: false }), M.newClock("Europe/Nowhere")],
    offsets: { "America/New_York": { offsetMin: -240, abbr: "EDT" }, "Asia/Tokyo": { offsetMin: 540, abbr: "JST" } },
    localOffsetMin: local,
    hour12: false,
    showNextAlarm: true
  }
  const segments = M.barSegments(input)
  assert.deepStrictEqual(plain(segments.map(s => s.kind)), ["timer", "timer", "stopwatch", "alarm", "clock"])
  assert.deepStrictEqual(plain(segments.map(s => s.text)), ["04:00", "10:00", "01:23", "16:45", "New York 08:00"])
  assert.strictEqual(segments[0].icon, M.ICON_TIMER)
  assert.strictEqual(segments[1].icon, M.ICON_PAUSE)
  assert.strictEqual(segments[1].dim, true)
  assert.strictEqual(segments[3].detail, "Call at 16:45 (in 2 h 45 min)")
  assert.strictEqual(M.barText(segments), M.ICON_TIMER + " 04:00   " + M.ICON_PAUSE + " 10:00   " + M.ICON_STOPWATCH + " 01:23   " + M.ICON_ALARM + " 16:45   " + M.ICON_WORLD + " New York 08:00")
  assert.deepStrictEqual(plain(M.barLines(segments)), [M.ICON_TIMER, "04", "00", M.ICON_PAUSE, "10", "00", M.ICON_STOPWATCH, "01", "23", M.ICON_ALARM, "16", "45", M.ICON_WORLD, "08", "00"])

  const quiet = M.barSegments({ nowMs: NOW, timers: [], stopwatch: M.emptyStopwatch(), alarms: [], clocks: [], offsets: {}, localOffsetMin: local })
  assert.strictEqual(quiet.length, 0)
  const noAlarm = M.barSegments(Object.assign({}, input, { showNextAlarm: false }))
  assert.strictEqual(noAlarm.some(s => s.kind === "alarm"), false)
  const tomorrow = M.barSegments({ nowMs: NOW, alarms: [alarm({ hour: 7, minute: 30, armedAt: NOW })], timers: [], clocks: [], offsets: {}, localOffsetMin: local })
  assert.strictEqual(tomorrow[0].text, "Sat 07:30")
  const paused = M.barSegments({ nowMs: NOW, stopwatch: M.stopwatchPaused(M.stopwatchStarted(M.emptyStopwatch(), NOW - 5000), NOW), timers: [], alarms: [], clocks: [], offsets: {}, localOffsetMin: local })
  assert.strictEqual(paused[0].icon, M.ICON_PAUSE)
  assert.strictEqual(paused[0].text, "00:05")

  // A vertical bar in 12-hour mode still gets the digits: the time rides on
  // the segment rather than being cut back out of the label.
  const twelve = M.barSegments(Object.assign({}, input, { hour12: true }))
  assert.deepStrictEqual(plain(twelve.map(s => s.text)), ["04:00", "10:00", "01:23", "4:45 PM", "New York 8:00 AM"])
  assert.deepStrictEqual(plain(M.barLines(twelve)), [M.ICON_TIMER, "04", "00", M.ICON_PAUSE, "10", "00", M.ICON_STOPWATCH, "01", "23", M.ICON_ALARM, "4", "45", M.ICON_WORLD, "8", "00"])
  const tomorrow12 = M.barSegments({ nowMs: NOW, alarms: [alarm({ hour: 7, minute: 30, armedAt: NOW })], timers: [], clocks: [], offsets: {}, localOffsetMin: local, hour12: true })
  assert.strictEqual(tomorrow12[0].text, "Sat 7:30 AM")
  assert.deepStrictEqual(plain(M.barLines(tomorrow12)), [M.ICON_ALARM, "7", "30"])
})

test("state round-trips and survives garbage", () => {
  const alarms = [alarm({ id: "a1", label: "Up", days: [1, 2, 3, 4, 5], armedAt: NOW })]
  const timers = [M.newTimer(5 * MIN, "Tea", NOW)]
  const sw = M.stopwatchLapped(M.stopwatchStarted(M.emptyStopwatch(), NOW), NOW + 1000)
  const clocks = [M.newClock("Asia/Tokyo")]
  const text = M.serializeState(alarms, timers, sw, clocks)
  const back = M.parseState(text)
  assert.deepStrictEqual(plain(back.alarms), plain(alarms))
  assert.deepStrictEqual(plain(back.timers), plain(timers))
  assert.deepStrictEqual(plain(back.stopwatch), plain(sw))
  assert.deepStrictEqual(plain(back.clocks), plain(clocks))

  assert.deepStrictEqual(plain(M.parseState("")), plain(M.emptyState()))
  assert.deepStrictEqual(plain(M.parseState("   \n")), plain(M.emptyState()))
  assert.strictEqual(M.parseState("not json"), null)
  assert.strictEqual(M.parseState('{"version":2}'), null)
  assert.strictEqual(M.parseState("[1]"), null)
  assert.strictEqual(M.parseState('{"version":1,"alarms":' + JSON.stringify(new Array(2000000).fill(1)) + "}"), null, "oversized state is refused")

  const messy = M.normalizeState({
    alarms: [
      { id: "ok", hour: "7", minute: 30, label: "<b>x</b>", enabled: "false", days: "1,2,9" },
      { id: "bad id!", hour: 7, minute: 30 },
      { id: "late", hour: 25, minute: 0 },
      { id: "ok", hour: 8, minute: 0 },
      null
    ],
    timers: [
      { id: "t1", durationMs: 60000, running: "true", endsAt: NOW + 1000, remainingMs: 999999 },
      { id: "t2", durationMs: 60000, done: true, running: true, endsAt: NOW + 1000 },
      { id: "t3", durationMs: 10 },
      { id: "t4", durationMs: 60000, remainingMs: "x" },
      { id: "t5", durationMs: 60000, running: true },
      "junk"
    ],
    stopwatch: { running: true, startedAt: 0, accumulatedMs: -5, laps: [3, 2, 5, "x"] },
    clocks: [{ tz: "Asia/Tokyo", label: "", pinned: "no" }, { tz: "../x" }, { tz: "Asia/Tokyo" }]
  })
  assert.strictEqual(messy.alarms.length, 1)
  assert.deepStrictEqual(plain(messy.alarms[0]), { id: "ok", hour: 7, minute: 30, label: "‹b›x‹/b›", enabled: false, days: [1, 2], snoozedUntil: 0, lastFiredAt: 0, armedAt: 0, autoSnoozes: 0 })
  assert.deepStrictEqual(plain(messy.timers.map(t => t.id)), ["t1", "t2", "t4", "t5"])
  assert.strictEqual(messy.timers[0].running, true)
  assert.strictEqual(messy.timers[0].remainingMs, 60000, "remaining is capped at the duration")
  assert.strictEqual(messy.timers[1].done, false, "running wins over done")
  assert.strictEqual(messy.timers[2].remainingMs, 60000, "a paused timer with no remaining is full")
  assert.strictEqual(messy.timers[3].running, false, "running without an end instant is kept as paused")
  assert.strictEqual(messy.timers[3].remainingMs, 60000)
  assert.deepStrictEqual(plain(messy.stopwatch), { running: false, startedAt: 0, accumulatedMs: 0, laps: [3, 5] })
  assert.deepStrictEqual(plain(messy.clocks), [{ tz: "Asia/Tokyo", label: "Tokyo", pinned: false }])
})

test("non-finite and empty numbers cannot get into the state", () => {
  // 1e999 is valid JSON and parses to Infinity; JSON.stringify would fold
  // it to null, so this goes through the text path like a real file would.
  const text = '{"version":1,' +
    '"alarms":[{"id":"a","hour":7,"minute":30,"armedAt":1e999,"snoozedUntil":1e999,"lastFiredAt":-1e999},{"id":"e","hour":"","minute":""},{"id":"n","hour":null,"minute":5},{"id":"b","hour":false,"minute":0}],' +
    '"timers":[{"id":"t","durationMs":60000,"running":true,"endsAt":1e999},{"id":"u","durationMs":1e999}],' +
    '"stopwatch":{"running":true,"startedAt":1e999,"accumulatedMs":1e999,"laps":[1000,1e999,2000]},' +
    '"clocks":[]}'
  const state = M.parseState(text)
  assert.deepStrictEqual(plain(state.alarms.map(a => a.id)), ["a"], '"", null and false are not hours')
  assert.strictEqual(state.alarms[0].armedAt, 0)
  assert.strictEqual(state.alarms[0].snoozedUntil, 0)
  assert.strictEqual(state.alarms[0].lastFiredAt, 0)
  assert.ok(M.alarmNextAt(state.alarms[0], NOW) > NOW, "the alarm still has a next ring")
  assert.deepStrictEqual(plain(state.timers.map(t => t.id)), ["t"])
  assert.strictEqual(state.timers[0].running, false, "an infinite end instant leaves the timer paused, not immortal")
  assert.strictEqual(state.timers[0].remainingMs, 60000)
  assert.strictEqual(state.stopwatch.running, false)
  assert.strictEqual(state.stopwatch.accumulatedMs, 0)
  assert.deepStrictEqual(plain(state.stopwatch.laps), [1000, 2000])
  assert.strictEqual(M.finiteAt(NaN), 0)
  assert.strictEqual(M.finiteAt(-5), 0)
  assert.strictEqual(M.finiteAt("12"), 12)
  assert.strictEqual(M.finiteAt(true), 0)
  assert.strictEqual(M.finiteAt(1e300), M.MAX_INSTANT_MS)
  assert.strictEqual(M.normalizeAlarm({ id: "x", hour: "07", minute: "30" }).hour, 7, "numeric strings are still fine")
  assert.strictEqual(M.normalizeAlarm({ id: "x", hour: "", minute: "" }), null)
})

test("ids and caps", () => {
  const a = M.newId("t", NOW)
  const b = M.newId("t", NOW)
  assert.notStrictEqual(a, b)
  assert.strictEqual(M.safeId(a), a)
  assert.strictEqual(M.safeId("has space"), "")
  assert.strictEqual(M.safeId("x".repeat(41)), "")
  assert.strictEqual(M.clampInt("7", 1, 5, 3), 5)
  assert.strictEqual(M.clampInt("", 1, 5, 3), 3)
  assert.strictEqual(M.clampInt("abc", 1, 5, 3), 3)
  assert.strictEqual(M.toBool("yes", false), true)
  assert.strictEqual(M.toBool("0", true), false)
  assert.strictEqual(M.toBool("maybe", true), true)
})

if (process.exitCode) {
  console.error(`${passed} passed, some failed`)
} else {
  console.log(`ok - ${passed} tests passed`)
}
