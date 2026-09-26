pragma Singleton
import QtQuick

// Plugin-owned connection shared by our service and bar widgets. Custom
// bars intentionally do not expose other plugins' services through their API.
QtObject {
  property var service: null
}
