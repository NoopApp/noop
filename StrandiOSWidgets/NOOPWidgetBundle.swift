import WidgetKit
import SwiftUI

/// The widget extension entry point. Bundles the glanceable widget and the live-HR Live Activity.
@main
struct NOOPWidgetBundle: WidgetBundle {
    var body: some Widget {
        NOOPWidget()
        NOOPLiveActivity()
    }
}
