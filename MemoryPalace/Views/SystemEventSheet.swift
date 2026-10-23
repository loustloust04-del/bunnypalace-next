#if os(iOS)
import SwiftUI
import EventKit
import EventKitUI

/// 系统原生事件卡（`EKEventViewController`，公开 API）。
/// 点设备工具卡片时当场弹出**苹果自己画的**事件详情——视觉 100% 是系统的，
/// 因为那本来就是系统 UI；还自带编辑/删除/加提醒。比跳出去到日历 app 更轻，
/// 也比自绘"像系统"的界面诚实（拿不到别家 app 图标是沙箱的有意限制，不该绕）。
struct SystemEventSheet: UIViewControllerRepresentable {
    let eventIdentifier: String
    let occurrenceDate: Date?
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let store = EventKitService.shared.store
        let vc = EKEventViewController()
        vc.event = resolveEvent(store: store)
        vc.allowsEditing = true
        vc.allowsCalendarPreview = true
        vc.delegate = context.coordinator
        let nav = UINavigationController(rootViewController: vc)
        vc.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: context.coordinator, action: #selector(Coordinator.done))
        return nav
    }

    func updateUIViewController(_ nav: UINavigationController, context: Context) {}

    /// 重复事件：在 ±1 天窗口里找最接近 occurrenceDate 的那次实例（与 calendar_delete 同款语义）。
    private func resolveEvent(store: EKEventStore) -> EKEvent? {
        if let occ = occurrenceDate {
            let pred = store.predicateForEvents(withStart: occ.addingTimeInterval(-86400),
                                                end: occ.addingTimeInterval(86400), calendars: nil)
            if let hit = store.events(matching: pred)
                .filter({ $0.eventIdentifier == eventIdentifier })
                .min(by: { abs($0.startDate.timeIntervalSince(occ)) < abs($1.startDate.timeIntervalSince(occ)) }) {
                return hit
            }
        }
        return store.event(withIdentifier: eventIdentifier)
    }

    final class Coordinator: NSObject, EKEventViewDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
        @objc func done() { onDismiss() }
        func eventViewController(_ controller: EKEventViewController, didCompleteWith action: EKEventViewAction) {
            onDismiss()   // 用户在系统卡里删了/改了/关了，都收起 sheet
        }
    }
}
#endif
