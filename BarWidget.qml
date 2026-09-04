pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar entry for Chime. It behaves like one of the bar's hidden
// indicators: while nothing is going on it takes no room and only peeks
// out, dimmed, when the pointer is over the center section. The moment
// something is live it is simply there — every running timer counting down,
// the stopwatch, the next alarm, the pinned world clocks.
//
// A single entry does both in one place. Two entries around the built-in
// indicators (see Service.splitLayout) do it the way the indicators
// themselves do: the entry before them carries the idle icon into the
// hidden group, the entry after them carries the readout up next to the
// clock. Each instance works out its own side from the layout. One of these
// lives on every bar surface; the state behind them is the plugin's service.
//
// Left click opens the panel, right click pauses or resumes whatever is
// counting, middle click starts the quick timer. While an alarm rings, any
// click stops it.
BarWidget {
  id: root
  moduleName: "io.github.nousd.chime"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null

  // Settings come from the service, which merges every bar entry of this
  // widget the same way for every surface; this instance's own entry is only
  // the fallback while the service is not up.
  function effective(name, fallback) {
    return service ? service.setting(name, fallback) : setting(name, fallback)
  }

  readonly property bool alwaysShow: Model.toBool(effective("alwaysShow", false), false)
  readonly property bool showNextAlarm: Model.toBool(effective("showNextAlarm", true), true)
  readonly property bool hour12: Model.toBool(effective("hour12", false), false)

  readonly property var segments: service ? Model.barSegments({
    nowMs: service.nowMs,
    timers: service.timers,
    stopwatch: service.stopwatch,
    alarms: service.alarms,
    clocks: service.clocks,
    offsets: service.offsets,
    localOffsetMin: service.localOffsetMin,
    hour12: hour12,
    showNextAlarm: showNextAlarm
  }) : []
  readonly property bool ringing: !!service && service.ringing !== null
  readonly property bool idle: segments.length === 0 && !ringing

  // ---- Which side of the indicators this instance is on: "solo" for the
  //      ordinary single entry, "idle" or "active" for the two halves of a
  //      split layout. Re-evaluated whenever the bar lays out or a slot
  //      registers, which is when the answer can change.
  property int completedTick: 0
  readonly property var placement: computePlacement(bar ? bar.barConfigSerial : 0, bar ? bar.moduleSlots : null, completedTick)
  readonly property string role: placement.role
  readonly property bool idleRole: role === "idle"
  readonly property bool activeRole: role === "active"

  function ownSlot() {
    var item = root.parent
    for (var depth = 0; item && depth < 4; depth++) {
      if ("moduleName" in item && "region" in item && "activeItem" in item) return item
      item = item.parent
    }
    return null
  }

  function computePlacement(serial, slots, tick) {
    var out = { role: "solo", region: "" }
    if (!bar || typeof bar.layoutEntries !== "function" || typeof bar.entryId !== "function") return out
    var slot = ownSlot()
    if (!slot) return out
    var region = String(slot.region || "")
    out.region = region
    var entries = bar.layoutEntries(region)
    var mine = []
    var indicators = -1
    for (var i = 0; i < entries.length; i++) {
      var id = bar.entryId(entries[i])
      if (id === root.moduleName) mine.push(i)
      else if (id === "omarchy.indicators" && indicators < 0) indicators = i
    }
    if (mine.length < 2 || indicators < 0) return out
    var before = false
    var after = false
    for (var m = 0; m < mine.length; m++) {
      if (mine[m] < indicators) before = true
      else if (mine[m] > indicators) after = true
    }
    if (!before || !after) return out
    // Which entry is this instance: its ordinal among same-id slots on this
    // bar surface, which register in layout order.
    var list = slots || []
    var window = bar.slotWindow(slot)
    var ordinal = 0
    var found = false
    for (var s = 0; s < list.length; s++) {
      var other = list[s]
      if (!other || other.region !== region || other.moduleName !== root.moduleName) continue
      if (!bar.sameWindow(bar.slotWindow(other), window)) continue
      if (other === slot) {
        found = true
        break
      }
      ordinal++
    }
    if (!found) return out
    var myIndex = mine[Math.min(ordinal, mine.length - 1)]
    out.role = myIndex < indicators ? "idle" : "active"
    return out
  }

  // The same peek the built-in indicators use: the center section is hovered
  // and no keyboard-summoned panel has asked for the reveal to stay down.
  readonly property bool centerRevealed: !!bar && bar.centerSectionRevealHeld === true && bar.centerHoverRevealSuppressed !== true

  // What this instance paints: the idle glyph or the live readout. The idle
  // half of a split never shows the readout; while its panel is open it keeps
  // its glyph so the panel has something to hang from.
  readonly property bool showsIcon: idle || idleRole
  readonly property bool revealed: {
    if (opened) return true
    if (idleRole) return idle && (alwaysShow || centerRevealed)
    if (activeRole) return !idle
    return !idle || alwaysShow || centerRevealed
  }

  readonly property bool showsRing: ringing && !showsIcon
  readonly property string label: showsRing
    ? Model.ICON_BELL + " " + service.ringTitle
    : (showsIcon ? Model.ICON_CLOCK : Model.barText(segments))
  readonly property var verticalLines: showsRing ? [Model.ICON_BELL] : (showsIcon ? [Model.ICON_CLOCK] : Model.barLines(segments))

  visible: revealed
  implicitWidth: revealed ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  // ---- Panel. Shape contract for shell summon/hide/toggle routing:
  //      Bar.findPanelWidget requires open/close/opened on the widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function quickTimer() {
    if (service) service.startTimer(service.quickTimerMinutes * 60 * 1000, "")
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("service" in target) target.service = root.service
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onServiceChanged: injectPanel()

  Component.onCompleted: Qt.callLater(function() { root.completedTick++ })

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.label
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    // As a glyph it is indicator-sized in an indicator-sized slot, so it
    // lines up with the hidden indicators it sits among.
    fontSize: root.showsIcon ? Style.font.caption : Style.font.body
    fixedWidth: root.showsIcon && !root.vertical ? Style.bar.statusSlot : -1
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: root.showsIcon ? 5 : 8.5
    active: root.showsRing
    dimmed: root.showsIcon
    tooltipText: "Chime"

    onPressed: function(buttonCode) {
      if (root.ringing) {
        root.service.stopRing()
        return
      }
      if (buttonCode === Qt.RightButton) {
        if (root.service) root.service.toggleRunning()
      } else if (buttonCode === Qt.MiddleButton) {
        root.quickTimer()
      } else {
        root.toggle()
      }
    }

    // A vertical bar stacks the icon and the digits, the way the built-in
    // clock does.
    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 3 ? button.fontSize * 0.9 : button.fontSize
          color: button.foreground
        }
      }
    }
  }
}
