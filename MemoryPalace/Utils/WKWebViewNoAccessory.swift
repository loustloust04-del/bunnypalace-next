#if canImport(UIKit)
import UIKit
import WebKit
import ObjectiveC.runtime

/// 干掉 WKWebView 键盘上方的 ⌃⌄✓ input accessory bar。
/// WKWebView 自己不暴露 inputAccessoryView setter——真正持有键盘焦点的是内层 WKContentView。
/// 动态 subclass WKContentView，override inputAccessoryView 让它返回 nil。
/// 经典 iOS hack 但稳——同一个 base class 只生成一次新 class，object_setClass 切换。
extension WKWebView {
    func disableKeyboardInputAccessory() {
        guard let target = scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }) else { return }

        let baseClassName = String(describing: type(of: target))
        let newClassName = "_MP_NoInputAccessory_" + baseClassName

        // 已经生成过就直接切类
        if let existing = NSClassFromString(newClassName) {
            object_setClass(target, existing)
            return
        }

        guard let baseClass = object_getClass(target) else { return }
        guard let newClass = objc_allocateClassPair(baseClass, newClassName, 0) else { return }

        // override inputAccessoryView getter → nil
        let imp: @convention(block) (Any) -> UIView? = { _ in nil }
        let sel = #selector(getter: UIResponder.inputAccessoryView)
        let method = class_getInstanceMethod(UIResponder.self, sel)
        let types = method.flatMap { String(cString: method_getTypeEncoding($0)!) } ?? "@@:"
        class_addMethod(newClass,
                        sel,
                        imp_implementationWithBlock(imp),
                        types)

        objc_registerClassPair(newClass)
        object_setClass(target, newClass)
    }
}
#endif
