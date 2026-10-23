import Foundation
#if os(macOS)
import Security
#endif

/// 老 ElevenLabs 配置 → 语音服务（plan-voice-providers V1c），零感知：
/// 钥匙串老 account `elevenlabs` 有 key → 生成 ElevenLabs 服务（key 拷到 `voice.<id>`，老 key 留着），
/// 有 `elevenVoiceId` 的楼层挂到它下面，语音条 / 通话模型都记 `eleven_v3`（行为不变）。
/// 幂等：服务 id 固定 + 完成标记；楼层只挂还没选服务的。没老 key 不生成、不落标记（下次启动再看）。
/// 完成标记只在「新 key 写成功且读得回来 + 改过的楼层全部落盘成功」后才写；任何一步失败都不落标记，下次启动重试。
enum VoiceServiceMigration {
    static let doneKey = "voiceServiceMigrationV1Done"
    static let legacyServiceId = "elevenlabs-legacy"
    static let legacyModel = "eleven_v3"

    enum Outcome: Equatable {
        /// 迁完了（含「没有要挂的楼层」），已落标记
        case done(migrated: [String])
        /// 已经迁过 / 没老 key：什么都没做
        case skipped
        /// key 没写进去或读不回来：楼层没动，没落标记
        case keyFailed
        /// 楼层落盘失败：没落标记，下次只补没迁上的楼层
        case saveFailed
    }

    /// - writeKey: 把 key 写进新服务（测试注入失败）；默认 `store.setKey(…, mirrorLegacy: false)`
    /// - persist: 把改好的楼层落盘，全部成功返回 true
    @discardableResult
    static func run(profiles: [Profile], store: VoiceServiceStore, legacyKey: String?, defaults: UserDefaults,
                    writeKey: ((String, VoiceService) -> Bool)? = nil,
                    persist: ([Profile]) -> Bool) -> Outcome {
        guard !defaults.bool(forKey: doneKey) else { return .skipped }
        guard let key = legacyKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return .skipped }

        let service = store.service(id: legacyServiceId)
            ?? VoiceService(id: legacyServiceId, name: "ElevenLabs", kind: .elevenLabs)
        if store.service(id: legacyServiceId) == nil { store.add(service) }
        if store.key(for: legacyServiceId) == nil {
            let wrote = writeKey?(key, service) ?? store.setKey(key, for: service, mirrorLegacy: false)
            guard wrote, store.key(for: legacyServiceId) != nil else { return .keyFailed }
        }

        var changed: [Profile] = []
        for var p in profiles where p.voiceServiceId == nil {
            guard let voiceId = p.elevenVoiceId, !voiceId.isEmpty else { continue }
            p.voiceServiceId = legacyServiceId
            p.voiceId = voiceId
            p.voiceName = p.elevenVoiceName
            p.messageModel = legacyModel
            p.callModel = legacyModel
            changed.append(p)
        }
        if !changed.isEmpty, !persist(changed) { return .saveFailed }
        defaults.set(true, forKey: doneKey)
        return .done(migrated: changed.map(\.id))
    }

    /// 启动时跑（测试宿主不跑，别动真数据）
    static func runAtLaunch(profileManager: ProfileManager) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let outcome = run(profiles: profileManager.profiles, store: .shared,
                          legacyKey: readLegacyKeySilently(), defaults: .standard,
                          persist: { profileManager.updateProfilesPersisting($0) })
        switch outcome {
        case .done(let ids) where !ids.isEmpty: print("[voice-migration] \(ids.count) 个楼层挂到 ElevenLabs 服务")
        case .keyFailed: print("[voice-migration] key 没写进新服务，下次启动重试")
        case .saveFailed: print("[voice-migration] 楼层落盘失败，下次启动重试")
        case .done, .skipped: break
        }
    }

    /// mac 上关掉钥匙串交互再读：外来签名的条目读不到就算没有，别在启动时弹密码框
    private static func readLegacyKeySilently() -> String? {
        #if os(macOS)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        #endif
        return KeychainStore.get(account: VoiceTuning.keychainAccount)
    }
}
