pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Chime's popup: four tabs — Alarm, World, Timer, Stopwatch — with a
// banner above them only while something rings. Every list keeps one cursor
// that the keyboard and the mouse share (see CursorSurface): Up/Down pick a
// row, Enter acts on it (alarm on/off, pin a clock, pause a timer), x
// removes it, Left/Right or 1–4 change tab, n starts something new. Inline
// editors take the keyboard while they are open and hand it back on
// Enter/Escape.
//
// BarWidget.qml owns the bar readout and hands this panel the button to
// anchor against, plus the plugin's service singleton that holds the state.
Panel {
  id: root
  moduleName: "io.github.nousd.chime"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  // The bar tracks the widget mounted in its slot, not this nested panel:
  // the popout coordinator and switchPanelFrom both identify a panel by it.
  readonly property var barIdentity: hostWidget || root

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property color faint: Qt.darker(fg, 1.9)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool hour12: service ? service.hour12 : false
  // Frozen while the panel is closed: its rows and rails otherwise re-run
  // their bindings on every tick behind a window nobody can see.
  property double closedNowMs: Date.now()
  readonly property double nowMs: opened && service ? service.nowMs : closedNowMs
  readonly property var alarms: service ? Model.sortAlarms(service.alarms) : []
  // Sorted against a fixed instant: running timers keep their relative order
  // as they tick, and re-sorting every second would rebuild the list.
  readonly property var timers: service ? Model.sortTimers(service.timers, 0) : []
  readonly property var stopwatch: service ? service.stopwatch : Model.emptyStopwatch()
  readonly property bool stopwatchRunning: !!stopwatch && stopwatch.running === true
  readonly property var clocks: service ? service.clocks : []
  readonly property var offsets: service ? service.offsets : ({})
  readonly property int localOffsetMin: service ? service.localOffsetMin : 0

  // A rename whose clock is gone — removed from this panel or another
  // surface's — would otherwise keep the keys blocked for a field that no
  // longer exists.
  onClocksChanged: {
    if (renamingClock === "" || !service) return
    if (service.clockIndex(renamingClock) < 0) cancelRename()
  }
  readonly property var laps: Model.lapRows(stopwatch ? stopwatch.laps : [])
  readonly property bool ringing: !!service && service.ringing !== null

  // Tenths for the stopwatch need a faster clock than the service's second;
  // it only runs while the panel shows a running stopwatch.
  property double fastNowMs: Date.now()
  readonly property double stopwatchElapsedMs: Model.stopwatchElapsed(stopwatch, stopwatchRunning ? fastNowMs : nowMs)

  property string tab: "alarm"
  readonly property var tabs: [
    { value: "alarm", label: "Alarm", icon: Model.ICON_ALARM },
    { value: "world", label: "World", icon: Model.ICON_WORLD },
    { value: "timer", label: "Timer", icon: Model.ICON_TIMER },
    { value: "stopwatch", label: "Stopwatch", icon: Model.ICON_STOPWATCH }
  ]

  // ---- Cursor: a row index within the list of the current tab.
  property int cursor: -1
  readonly property int rowCount: tab === "alarm" ? alarms.length
    : tab === "world" ? clocks.length
    : tab === "timer" ? timers.length
    : 0
  property bool swallowActivate: false

  // ---- Inline editors.
  property string editingAlarm: ""
  property var editDays: []
  property string alarmError: ""
  property string timerError: ""
  property string renamingClock: ""
  // The text being typed lives here, not in the row: the list rebuilds its
  // rows whenever a clock changes, and a rebuilt field would come up empty.
  property string renameDraft: ""
  property double pickerClosedAt: 0
  // The rename field lives in a list delegate that the list can rebuild under
  // it, so the block follows the rename state rather than that field's focus.
  readonly property bool editorFocused: timeField.activeFocus || labelField.activeFocus
    || customField.activeFocus || timerLabelField.activeFocus
  readonly property bool keysBlocked: editorFocused || renamingClock !== "" || zonePicker.popupOpen

  function tabIndex() {
    for (var i = 0; i < tabs.length; i++) if (tabs[i].value === tab) return i
    return 0
  }

  function pickTab() {
    if (!service) return
    if (service.ringing && service.ringing.events.length > 0) {
      tab = service.ringing.events[0].kind === "alarm" ? "alarm" : "timer"
      return
    }
    if (timers.some(function(t) { return t.running })) tab = "timer"
    else if (stopwatchRunning) tab = "stopwatch"
  }

  function setTab(value) {
    if (value === tab) return
    cancelEditors()
    tab = value
    cursor = rowCount > 0 ? 0 : -1
    if (value === "world" && service) service.loadZones()
  }

  function moveTab(delta) {
    var n = tabs.length
    setTab(tabs[((tabIndex() + delta) % n + n) % n].value)
  }

  function setCursor(index) {
    cursor = index
  }

  function moveCursor(delta) {
    var n = rowCount
    if (n === 0) {
      cursor = -1
      return
    }
    var from = cursor < 0 ? (delta > 0 ? -1 : 0) : cursor
    cursor = ((from + delta) % n + n) % n
  }

  onRowCountChanged: if (cursor >= rowCount) cursor = rowCount - 1

  function activateCursor() {
    if (!service) return
    if (tab === "alarm") {
      if (cursor >= 0 && cursor < alarms.length) service.toggleAlarm(alarms[cursor].id)
      else startNewAlarm()
    } else if (tab === "world") {
      if (cursor >= 0 && cursor < clocks.length) service.toggleClockPinned(clocks[cursor].tz)
      else zonePicker.open()
    } else if (tab === "timer") {
      if (cursor >= 0 && cursor < timers.length) service.toggleTimer(timers[cursor].id)
      else focusLater(customField)
    } else {
      service.stopwatchToggle()
    }
  }

  // Same rule as the Reset button: a running stopwatch is paused first, so
  // a stray key cannot throw away laps.
  function resetStopwatch() {
    if (service && !stopwatchRunning && stopwatchElapsedMs > 0) service.stopwatchReset()
  }

  function deleteCursor() {
    if (!service) return
    if (tab === "alarm" && cursor >= 0 && cursor < alarms.length) service.removeAlarm(alarms[cursor].id)
    else if (tab === "world" && cursor >= 0 && cursor < clocks.length) service.removeClock(clocks[cursor].tz)
    else if (tab === "timer" && cursor >= 0 && cursor < timers.length) service.removeTimer(timers[cursor].id)
    else if (tab === "stopwatch") resetStopwatch()
  }

  function handleTextKey(t) {
    if (!service) return
    if (t >= "1" && t <= "4") {
      setTab(tabs[Number(t) - 1].value)
    } else if (t === "n" || t === "N" || t === "+") {
      if (tab === "alarm") startNewAlarm()
      else if (tab === "world") zonePicker.open()
      else if (tab === "timer") focusLater(customField)
      else service.stopwatchToggle()
    } else if (t === "r" || t === "R") {
      if (tab === "stopwatch") resetStopwatch()
      else if (tab === "timer" && cursor >= 0 && cursor < timers.length) service.resetTimer(timers[cursor].id)
    } else if (t === "p" || t === "P") {
      if (tab === "world" && cursor >= 0 && cursor < clocks.length) service.toggleClockPinned(clocks[cursor].tz)
    } else if (t === "s" || t === "S") {
      if (ringing) service.snoozeRing()
    }
  }

  // ---- Alarm editor.

  function focusLater(item) {
    Qt.callLater(function() {
      if (!item) return
      item.forceActiveFocus()
      if (typeof item.selectAll === "function") item.selectAll()
    })
  }

  function refocusKeys() {
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function startNewAlarm() {
    editingAlarm = "new"
    editDays = []
    alarmError = ""
    timeField.text = ""
    labelField.text = ""
    focusLater(timeField)
  }

  function startEditAlarm(alarm) {
    editingAlarm = alarm.id
    editDays = Model.normalizeDays(alarm.days)
    alarmError = ""
    timeField.text = Model.formatTime(alarm.hour, alarm.minute, false)
    labelField.text = alarm.label
    focusLater(timeField)
  }

  function cancelAlarmEditor() {
    if (editingAlarm === "") return
    editingAlarm = ""
    alarmError = ""
    refocusKeys()
  }

  function commitAlarm() {
    if (!service) return
    var t = Model.parseTime(timeField.text)
    if (!t) {
      alarmError = root.hour12 ? "Enter a time like 730 pm" : "Enter a time like 0730"
      return
    }
    var ok = editingAlarm === "new"
      ? service.addAlarm(t.hour, t.minute, labelField.text, editDays) !== ""
      : service.updateAlarm(editingAlarm, t.hour, t.minute, labelField.text, editDays)
    if (!ok) {
      alarmError = "Could not save the alarm"
      return
    }
    cancelAlarmEditor()
  }

  function toggleEditDay(day) {
    editDays = Model.toggleDay(editDays, day)
  }

  function editorKey(event, next) {
    if (event.key === Qt.Key_Escape) {
      cancelAlarmEditor()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      commitAlarm()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      next.forceActiveFocus()
      next.selectAll()
      event.accepted = true
    }
  }

  // ---- Timer entry.

  function startPreset(minutes) {
    if (!service) return
    timerError = service.startTimer(Number(minutes) * 60 * 1000, "") ? "" : "Too many timers"
  }

  function commitCustomTimer() {
    if (!service) return
    var ms = Model.parseDuration(customField.text)
    if (!ms) {
      timerError = "Try 5, 90s, 1h30m or 12:30"
      return
    }
    if (!service.startTimer(ms, timerLabelField.text)) {
      timerError = "Too many timers"
      return
    }
    customField.text = ""
    timerLabelField.text = ""
    timerError = ""
    refocusKeys()
  }

  function timerFieldKey(event, next) {
    if (event.key === Qt.Key_Escape) {
      timerError = ""
      refocusKeys()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      commitCustomTimer()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      next.forceActiveFocus()
      next.selectAll()
      event.accepted = true
    }
  }

  // ---- World clock rename.

  function startRename(tz) {
    var index = service ? service.clockIndex(tz) : -1
    renameDraft = index >= 0 ? clocks[index].label : ""
    renamingClock = tz
  }

  // The rename state goes first: renaming replaces the clock list, which
  // rebuilds the row holding the field.
  function commitRename() {
    var tz = renamingClock
    var text = renameDraft
    renamingClock = ""
    renameDraft = ""
    if (service && tz !== "") service.renameClock(tz, text)
    refocusKeys()
  }

  function cancelRename() {
    renamingClock = ""
    renameDraft = ""
    refocusKeys()
  }

  // A rename field lost the keyboard. If that was the list rebuilding its
  // rows, the replacement field takes the keyboard back within a frame; if
  // nobody has it a beat later, the user clicked away and the rename ends.
  function settleRename(tz) {
    renameSettle.tz = tz
    renameSettle.restart()
  }

  Timer {
    id: renameSettle
    property string tz: ""
    interval: 80
    repeat: false
    onTriggered: {
      if (root.renamingClock === "" || root.renamingClock !== tz) return
      var focused = keyCatcher.Window.activeFocusItem
      if (focused && focused.objectName === "chime-rename") return
      root.cancelRename()
    }
  }

  function cancelEditors() {
    var wasEditing = editingAlarm !== "" || renamingClock !== "" || zonePicker.popupOpen
      || customField.activeFocus || timerLabelField.activeFocus
    editingAlarm = ""
    alarmError = ""
    timerError = ""
    renamingClock = ""
    renameDraft = ""
    if (zonePicker.popupOpen) zonePicker.close()
    // A tab click while a field had the keyboard would otherwise leave no
    // one holding it.
    if (wasEditing && opened) refocusKeys()
  }

  // ---- Lifecycle.

  function open() {
    if (service) {
      pickTab()
      service.refreshOffsetsIfStale()
      if (tab === "world") service.loadZones()
    }
    fastNowMs = Date.now()
    closedNowMs = fastNowMs
    cursor = rowCount > 0 ? 0 : -1
    root.controller.show()
  }

  function close() {
    cancelEditors()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  onOpenedChanged: if (!opened) cancelEditors()

  Timer {
    interval: 100
    repeat: true
    running: root.opened && root.stopwatchRunning && root.tab === "stopwatch"
    onTriggered: root.fastNowMs = Date.now()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(450))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.keysBlocked
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveTab(dx)
        else if (dy !== 0) root.moveCursor(dy)
      }
      onReturnRequested: {
        if (root.tab === "stopwatch" && root.stopwatchRunning && root.service) {
          root.service.stopwatchLap()
          root.swallowActivate = true
        }
      }
      onActivateRequested: {
        if (root.swallowActivate) {
          root.swallowActivate = false
          return
        }
        root.activateCursor()
      }
      onCloseRequested: root.close()
      onDeleteRequested: root.deleteCursor()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.handleTextKey(t) }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(12)

        // Only while something rings: what it is, and the two ways out.
        BorderSurface {
          visible: root.ringing
          width: parent.width
          implicitHeight: ringRow.implicitHeight + Style.space(16)
          color: Util.alpha(root.urgent, 0.14)
          borderSpec: Border.flat(Util.alpha(root.urgent, 0.6), Style.normalBorderWidth)
          radius: Style.cornerRadius

          Row {
            id: ringRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(8)

            Text {
              id: ringIcon
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: Model.ICON_BELL
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(0, parent.width - parent.spacing * 3 - ringIcon.width - snoozeButton.width - stopButton.width)
              text: root.service ? root.service.ringTitle : ""
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }

            Button {
              id: snoozeButton
              anchors.verticalCenter: parent.verticalCenter
              text: root.service ? root.service.snoozeLabel : "Snooze"
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: if (root.service) root.service.snoozeRing()
            }

            Button {
              id: stopButton
              anchors.verticalCenter: parent.verticalCenter
              text: "Stop"
              bordered: true
              selected: true
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: if (root.service) root.service.stopRing()
            }
          }
        }

        // The service failed to load (see the shell log); the tabs below
        // would silently do nothing.
        Text {
          textFormat: Text.PlainText
          visible: !root.service
          width: parent.width
          text: "Chime's service is not loaded, so nothing here will work. Check `qs log` for the error."
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        ButtonGroup {
          anchors.horizontalCenter: parent.horizontalCenter
          options: root.tabs
          value: root.tab
          focusable: false
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onChanged: function(value) { root.setTab(value) }
        }

        PanelSeparator {
          foreground: root.fg
        }

        // ------------------------------------------------------------ alarms

        Column {
          visible: root.tab === "alarm"
          width: parent.width
          spacing: Style.space(8)

          ListView {
            id: alarmList
            visible: root.alarms.length > 0
            width: parent.width
            height: Math.min(contentHeight, Style.space(330))
            spacing: Style.space(4)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            keyNavigationEnabled: false

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            model: root.alarms
            currentIndex: root.tab === "alarm" ? root.cursor : -1
            onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
            function keepCurrentVisible() {
              if (currentIndex >= 0 && currentIndex < count) positionViewAtIndex(currentIndex, ListView.Contain)
            }

            delegate: AlarmRow {
              width: ListView.view.width
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.alarms.length === 0 && root.editingAlarm === ""
            width: parent.width
            text: "No alarms. The next one shows in the bar until it rings."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          BorderSurface {
            visible: root.editingAlarm !== ""
            width: parent.width
            implicitHeight: editorColumn.implicitHeight + Style.space(24)
            color: Style.normalFillFor(root.fg, Color.accent)
            borderSpec: Border.controlSpec("normal", root.fg, Color.accent)
            radius: Style.cornerRadius

            Column {
              id: editorColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(8)

              Row {
                width: parent.width
                spacing: Style.space(8)

                TextField {
                  id: timeField
                  width: Style.space(96)
                  placeholderText: root.hour12 ? "7:30 pm" : "07:30"
                  foreground: root.fg
                  font.family: root.fontFamily
                  inputMethodHints: Qt.ImhPreferNumbers

                  // The colon is typed for you: digits go in, the mask puts
                  // it after the hour. See Model.maskTime.
                  onTextChanged: {
                    var masked = Model.maskTime(text)
                    if (masked !== text) {
                      text = masked
                      cursorPosition = text.length
                    }
                  }

                  Keys.onPressed: function(event) {
                    // Backspace over an automatic colon takes the digit before
                    // it too; otherwise the mask would put the colon straight
                    // back.
                    if (event.key === Qt.Key_Backspace && timeField.selectedText === ""
                        && timeField.cursorPosition === timeField.text.length && /:$/.test(timeField.text)) {
                      timeField.text = timeField.text.slice(0, -2)
                      event.accepted = true
                      return
                    }
                    root.editorKey(event, labelField)
                  }
                }

                TextField {
                  id: labelField
                  width: parent.width - timeField.width - parent.spacing
                  placeholderText: "Label (optional)"
                  foreground: root.fg
                  font.family: root.fontFamily
                  Keys.onPressed: function(event) { root.editorKey(event, timeField) }
                }
              }

              Row {
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  rightPadding: Style.space(6)
                  text: "REPEAT"
                  color: root.faint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1
                }

                Repeater {
                  model: 7

                  Button {
                    required property int index
                    readonly property int day: Model.WEEK_ORDER[index]
                    text: Model.WEEK_LETTERS[index]
                    bordered: true
                    selected: root.editDays.indexOf(day) !== -1
                    foreground: root.fg
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    horizontalPadding: Style.space(7)
                    verticalPadding: Style.space(2)
                    tooltipText: Model.DAY_SHORT[day]
                    onClicked: root.toggleEditDay(day)
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  leftPadding: Style.space(6)
                  text: Model.daysLabel(root.editDays)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: root.alarmError !== ""
                width: parent.width
                text: root.alarmError
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(8)

                Button {
                  text: root.editingAlarm === "new" ? "Add alarm" : "Save"
                  bordered: true
                  selected: true
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  onClicked: root.commitAlarm()
                }

                Button {
                  text: "Cancel"
                  bordered: true
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  onClicked: root.cancelAlarmEditor()
                }
              }
            }
          }

          Button {
            visible: root.editingAlarm === ""
            anchors.horizontalCenter: parent.horizontalCenter
            iconText: Model.ICON_PLUS
            text: "Add alarm"
            bordered: true
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.startNewAlarm()
          }
        }

        // ------------------------------------------------------------- world

        Column {
          visible: root.tab === "world"
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            height: zonePicker.height

            SearchableDropdown {
              id: zonePicker
              width: parent.width
              // The shared dropdown subtracts two md margins from its search
              // header. Reserve the input's natural height including padding
              // and focus border, so the font is not clipped inside that box.
              popupRowHeight: Math.max(Style.spacing.popupRowHeight,
                Math.ceil(searchSizeProbe.implicitHeight) + 2 * Style.spacing.md - Style.spacing.controlPaddingX)
              TextField {
                id: searchSizeProbe
                visible: false
                text: "Ag"
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                hasCursor: true
              }
              showLabel: false
              options: root.service ? root.service.zoneOptions : []
              value: ""
              triggerLabel: "Add a city or time zone"
              placeholderText: "Search by city, country or zone"
              emptyText: root.service && root.service.zonesLoaded ? "No matches" : "Loading time zones…"
              foreground: root.fg
              fontFamily: root.fontFamily
              onPopupOpenChanged: if (!popupOpen) root.pickerClosedAt = Date.now()
              onChanged: function(zone) {
                if (root.service) root.service.addClock(zone)
                zonePicker.value = ""
                root.refocusKeys()
              }
            }

            // The popup closes on any press outside it before the trigger's
            // own click handler runs, so a second click on the trigger used
            // to close and immediately reopen it. This owns the click instead:
            // a press that just closed the popup is the whole gesture.
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (zonePicker.popupOpen) {
                  zonePicker.close()
                  return
                }
                if (Date.now() - root.pickerClosedAt < 300) return
                zonePicker.open()
              }
            }
          }

          // Tall enough for the picker's popup even with an empty list.
          Item {
            width: parent.width
            height: Math.max(Style.space(250), clockList.visible ? clockList.height : noClocks.implicitHeight)

            ListView {
              id: clockList
              visible: root.clocks.length > 0
              width: parent.width
              height: Math.min(contentHeight, Style.space(330))
              spacing: Style.space(4)
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height
              keyNavigationEnabled: false

              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              model: root.clocks
              currentIndex: root.tab === "world" ? root.cursor : -1
              onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
              function keepCurrentVisible() {
                if (currentIndex >= 0 && currentIndex < count) positionViewAtIndex(currentIndex, ListView.Contain)
              }

              delegate: ClockRow {
                width: ListView.view.width
              }
            }

            Text {
              id: noClocks
              textFormat: Text.PlainText
              visible: root.clocks.length === 0
              width: parent.width
              text: "No world clocks yet. Pinned cities show their time in the bar."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }
        }

        // ------------------------------------------------------------ timers

        Column {
          visible: root.tab === "timer"
          width: parent.width
          spacing: Style.space(8)

          GridLayout {
            width: parent.width
            columns: width < Style.space(390) ? 3 : 6
            columnSpacing: Style.space(6)
            rowSpacing: Style.space(6)

            Repeater {
              model: [1, 5, 10, 15, 30, 60]

              Button {
                required property var modelData
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                readonly property int minutes: Number(modelData)
                text: minutes >= 60 ? (minutes / 60) + " h" : minutes + " min"
                bordered: true
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.space(10)
                verticalPadding: Style.space(3)
                onClicked: root.startPreset(minutes)
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: customField
              width: Style.space(170)
              placeholderText: "Custom: 1h30m, 90s, 12:30"
              foreground: root.fg
              font.family: root.fontFamily
              Keys.onPressed: function(event) { root.timerFieldKey(event, timerLabelField) }
            }

            TextField {
              id: timerLabelField
              width: parent.width - customField.width - startButton.width - parent.spacing * 2
              placeholderText: "Label"
              foreground: root.fg
              font.family: root.fontFamily
              Keys.onPressed: function(event) { root.timerFieldKey(event, customField) }
            }

            Button {
              id: startButton
              text: "Start"
              bordered: true
              selected: true
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.commitCustomTimer()
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.timerError !== ""
            width: parent.width
            text: root.timerError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          ListView {
            id: timerList
            visible: root.timers.length > 0
            width: parent.width
            height: Math.min(contentHeight, Style.space(300))
            spacing: Style.space(4)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            keyNavigationEnabled: false

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            model: root.timers
            currentIndex: root.tab === "timer" ? root.cursor : -1
            onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
            function keepCurrentVisible() {
              if (currentIndex >= 0 && currentIndex < count) positionViewAtIndex(currentIndex, ListView.Contain)
            }

            delegate: TimerRow {
              width: ListView.view.width
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.timers.length === 0
            width: parent.width
            text: "No timers. Running ones count down in the bar."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
        }

        // --------------------------------------------------------- stopwatch

        Column {
          visible: root.tab === "stopwatch"
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: Model.formatClock(root.stopwatchElapsedMs, { tenths: true })
            color: root.stopwatchRunning || root.stopwatchElapsedMs > 0 ? root.fg : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge + Style.space(16)
            font.bold: true
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(8)

            Button {
              iconText: root.stopwatchRunning ? Model.ICON_PAUSE : Model.ICON_PLAY
              text: root.stopwatchRunning ? "Pause" : (root.stopwatchElapsedMs > 0 ? "Resume" : "Start")
              bordered: true
              selected: true
              foreground: root.fg
              fontFamily: root.fontFamily
              horizontalPadding: Style.space(16)
              onClicked: if (root.service) root.service.stopwatchToggle()
            }

            Button {
              iconText: Model.ICON_FLAG
              text: "Lap"
              bordered: true
              enabled: root.stopwatchRunning
              opacity: enabled ? 1 : 0.45
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: if (root.service) root.service.stopwatchLap()
            }

            Button {
              iconText: Model.ICON_REPLAY
              text: "Reset"
              bordered: true
              enabled: !root.stopwatchRunning && root.stopwatchElapsedMs > 0
              opacity: enabled ? 1 : 0.45
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: if (root.service) root.service.stopwatchReset()
            }
          }

          ListView {
            visible: root.laps.length > 0
            width: parent.width
            height: Math.min(contentHeight, Style.space(210))
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            keyNavigationEnabled: false

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            model: root.laps

            delegate: Item {
              id: lapRow
              required property var modelData
              width: ListView.view.width
              height: Style.space(24)

              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: "LAP " + lapRow.modelData.index
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
              }

              Text {
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                text: "+" + Model.formatClock(lapRow.modelData.split, { tenths: true })
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: Model.formatClock(lapRow.modelData.total, { tenths: true })
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }
        }

      }
    }
  }

  // One alarm: the time, its label and schedule, a switch, edit and delete.
  component AlarmRow: CursorSurface {
    id: arow
    required property var modelData
    required property int index

    readonly property bool isCursor: root.tab === "alarm" && root.cursor === index
    readonly property bool on: modelData.enabled === true || Number(modelData.snoozedUntil) > root.nowMs

    hasCursor: isCursor
    foreground: root.fg
    fill: Style.hoverFillFor(root.fg, Color.accent)
    implicitHeight: alarmContent.implicitHeight + Style.space(12)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.setCursor(arow.index)
      onClicked: root.startEditAlarm(arow.modelData)
    }

    Item {
      id: alarmContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      implicitHeight: Math.max(alarmLabels.implicitHeight, alarmActions.implicitHeight)

      Column {
        id: alarmLabels
        anchors.left: parent.left
        anchors.right: alarmActions.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: Model.formatTime(arow.modelData.hour, arow.modelData.minute, root.hour12)
          color: arow.on ? root.fg : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: Model.alarmSummary(arow.modelData, root.nowMs, root.hour12)
          color: arow.on ? root.dim : root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        id: alarmActions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        ToggleSwitch {
          anchors.verticalCenter: parent.verticalCenter
          checked: arow.on
          foreground: root.fg
          onToggled: if (root.service) root.service.toggleAlarm(arow.modelData.id)
        }

        PanelActionButton {
          iconText: Model.ICON_PENCIL
          tooltipText: "Edit alarm"
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.startEditAlarm(arow.modelData)
        }

        PanelActionButton {
          iconText: Model.ICON_CLOSE
          tooltipText: "Delete alarm"
          foreground: root.fg
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          onClicked: if (root.service) root.service.removeAlarm(arow.modelData.id)
        }
      }
    }
  }

  // One world clock: the city and its zone, the time and day there, and
  // rename, pin-to-bar and remove.
  component ClockRow: CursorSurface {
    id: crow
    required property var modelData
    required property int index

    readonly property bool isCursor: root.tab === "world" && root.cursor === index
    readonly property var info: root.offsets[modelData.tz] || null
    readonly property bool renaming: root.renamingClock === modelData.tz
    readonly property string zoneDetail: {
      var parts = []
      if (info) {
        if (info.abbr) parts.push(info.abbr)
        parts.push(Model.offsetLabel(info.offsetMin - root.localOffsetMin))
      }
      parts.push(modelData.tz)
      return parts.join("  ·  ")
    }

    hasCursor: isCursor
    foreground: root.fg
    fill: Style.hoverFillFor(root.fg, Color.accent)
    implicitHeight: clockContent.implicitHeight + Style.space(12)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.setCursor(crow.index)
      onClicked: if (root.service) root.service.toggleClockPinned(crow.modelData.tz)
    }

    Item {
      id: clockContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      implicitHeight: Math.max(clockLabels.implicitHeight, clockTime.implicitHeight, clockActions.implicitHeight)

      Column {
        id: clockLabels
        anchors.left: parent.left
        anchors.right: clockTime.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          visible: !crow.renaming
          width: parent.width
          text: crow.modelData.label
          color: crow.modelData.pinned ? root.fg : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
        }

        // The draft lives on the panel (root.renameDraft): this row can be
        // rebuilt mid-edit whenever the clock list changes, and a rebuilt
        // field picks the draft up from the same place it left it.
        TextField {
          id: renameField
          objectName: "chime-rename"
          visible: crow.renaming
          width: parent.width
          verticalPadding: Style.space(2)
          placeholderText: Model.zoneCity(crow.modelData.tz)
          foreground: root.fg
          font.family: root.fontFamily

          function takeUp() {
            text = root.renameDraft
            root.focusLater(renameField)
          }

          Component.onCompleted: if (visible) takeUp()
          onVisibleChanged: if (visible) takeUp()
          onTextChanged: if (crow.renaming && activeFocus) root.renameDraft = text
          // Clicking elsewhere drops an unfinished rename instead of leaving
          // the keys blocked behind a field nobody is typing in; a rebuild of
          // this row is told apart from that by settleRename.
          onActiveFocusChanged: if (!activeFocus && crow.renaming) root.settleRename(crow.modelData.tz)
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.cancelRename()
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.renameDraft = text
              root.commitRename()
              event.accepted = true
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: crow.zoneDetail
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Column {
        id: clockTime
        anchors.right: clockActions.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          text: crow.info ? Model.formatZoneTime(root.nowMs, crow.info.offsetMin, root.hour12) : "--:--"
          color: crow.modelData.pinned ? root.fg : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          text: crow.info ? Model.zoneDayLabel(root.nowMs, crow.info.offsetMin) + "  " + Model.zoneDateLabel(root.nowMs, crow.info.offsetMin) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Row {
        id: clockActions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        PanelActionButton {
          iconText: Model.ICON_PENCIL
          tooltipText: "Rename"
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.startRename(crow.modelData.tz)
        }

        PanelActionButton {
          iconText: crow.modelData.pinned ? Model.ICON_PIN : Model.ICON_PIN_OFF
          tooltipText: crow.modelData.pinned ? "Shown in the bar — click to hide" : "Show in the bar"
          foreground: crow.modelData.pinned ? root.fg : root.faint
          hoverColor: root.fg
          fontFamily: root.fontFamily
          onClicked: if (root.service) root.service.toggleClockPinned(crow.modelData.tz)
        }

        PanelActionButton {
          iconText: Model.ICON_CLOSE
          tooltipText: "Remove"
          foreground: root.fg
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          onClicked: if (root.service) root.service.removeClock(crow.modelData.tz)
        }
      }
    }
  }

  // One timer: title and status, the countdown, pause/resume or restart,
  // reset and remove, with a progress rail underneath.
  component TimerRow: CursorSurface {
    id: trow
    required property var modelData
    required property int index

    readonly property bool isCursor: root.tab === "timer" && root.cursor === index
    readonly property double remaining: Model.timerRemaining(modelData, root.nowMs)
    readonly property real progress: Model.timerProgress(modelData, root.nowMs)
    readonly property string status: modelData.done
      ? "Done " + Model.relativeTime(root.nowMs, modelData.doneAt)
      : (modelData.running ? "Ends at " + Model.formatTimeMs(root.nowMs + remaining, root.hour12) : "Paused")

    hasCursor: isCursor
    foreground: root.fg
    fill: Style.hoverFillFor(root.fg, Color.accent)
    implicitHeight: timerContent.implicitHeight + Style.space(14)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.setCursor(trow.index)
      onClicked: if (root.service) root.service.toggleTimer(trow.modelData.id)
    }

    Column {
      id: timerContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(6)

      Item {
        width: parent.width
        implicitHeight: Math.max(timerLabels.implicitHeight, timerActions.implicitHeight)

        Column {
          id: timerLabels
          anchors.left: parent.left
          anchors.right: remainingText.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: Model.timerTitle(trow.modelData)
            color: trow.modelData.done ? root.dim : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: trow.status
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Text {
          id: remainingText
          textFormat: Text.PlainText
          anchors.right: timerActions.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: trow.modelData.done ? Model.ICON_DONE : Model.formatRemaining(trow.remaining)
          color: trow.modelData.done ? root.dim : (trow.modelData.running ? root.fg : root.dim)
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Row {
          id: timerActions
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          PanelActionButton {
            iconText: trow.modelData.running ? Model.ICON_PAUSE : (trow.modelData.done ? Model.ICON_REPLAY : Model.ICON_PLAY)
            tooltipText: trow.modelData.running ? "Pause" : (trow.modelData.done ? "Run again" : "Resume")
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: if (root.service) root.service.toggleTimer(trow.modelData.id)
          }

          PanelActionButton {
            visible: !trow.modelData.done
            iconText: Model.ICON_REPLAY
            tooltipText: "Reset"
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: if (root.service) root.service.resetTimer(trow.modelData.id)
          }

          PanelActionButton {
            iconText: Model.ICON_CLOSE
            tooltipText: "Remove"
            foreground: root.fg
            hoverColor: root.urgent
            fontFamily: root.fontFamily
            onClicked: if (root.service) root.service.removeTimer(trow.modelData.id)
          }
        }
      }

      Rectangle {
        width: parent.width
        height: Style.space(4)
        radius: Style.cornerRadius > 0 ? height / 2 : 0
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)

        Rectangle {
          width: Math.round(parent.width * (trow.modelData.done ? 1 : trow.progress))
          height: parent.height
          radius: parent.radius
          color: Style.selectedStateColor(root.fg, Color.accent)
          opacity: trow.modelData.done ? 0.4 : 1

          // Only while on screen: the panel's tree stays loaded when closed,
          // and a re-triggered animation would keep the render loop awake.
          Behavior on width {
            enabled: root.opened
            NumberAnimation { duration: 400; easing.type: Easing.Linear }
          }
        }
      }
    }
  }
}
