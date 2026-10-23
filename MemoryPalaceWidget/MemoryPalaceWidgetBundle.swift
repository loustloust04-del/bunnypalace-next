import SwiftUI
import WidgetKit

@main
struct MemoryPalaceWidgetBundle: WidgetBundle {
    var body: some Widget {
        CCLiveActivityView()
        UsageWidget()
        CalendarWidget()
    }
}
