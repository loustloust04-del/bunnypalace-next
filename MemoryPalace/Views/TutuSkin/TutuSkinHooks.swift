#if PERSONAL_APPS
import SwiftUI

struct TutuSkinHooks: ViewModifier {
    let onDeathScaleUnlock: () -> Void
    let onReplay: () -> Void

    func body(content: Content) -> some View {
        content
            .modifier(OnNotify(.deathScaleUnlock) { onDeathScaleUnlock() })
            #if os(iOS)
            .modifier(OnNotify(.tutuSkinUnlock) { TutuUnlockPresentation.shared.unlock() })
            .modifier(OnNotify(.tutuSkinPlayUnlockAnimation) {
                TutuUnlockPresentation.shared.play(prepareConversation: onReplay)
            })
            #else
            .modifier(OnNotify(.tutuSkinUnlock) { SkinState.shared.unlock() })
            .modifier(OnNotify(.tutuSkinPlayUnlockAnimation) { onReplay() })
            #endif
    }
}
#endif
