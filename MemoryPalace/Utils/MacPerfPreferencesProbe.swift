#if (DEBUG || PERF_BENCH) && os(macOS)
import Foundation
import ObjectiveC
import Darwin

/// Counts outermost calls to the nine NSUserDefaults mutators below, not changed keys or disk writes.
/// Excludes register(defaults:), volatile domains, direct CFPreferences C calls, and subclass overrides
/// that do not reach these NSUserDefaults implementations. Never inspects keys, values, or domains.
/// The caller must establish the enabled/isolation gates before installing during app initialization.
enum MacPerfPreferencesProbe {
    private static let installLock = NSLock()
    nonisolated(unsafe) private static var installed = false

    private enum MacPerfInstallError: LocalizedError {
        case missingSelector(String)
        case threadLocal(Int32)

        var errorDescription: String? {
            switch self {
            case .missingSelector(let name): return "NSUserDefaults probe missing selector: \(name)"
            case .threadLocal(let code): return "NSUserDefaults probe TLS unavailable: \(code)"
            }
        }
    }

    /// Process-lifetime installation; repeated calls keep the first callback and do not stack wrappers.
    /// All selectors and TLS are checked before replacing any implementation. Install before workloads;
    /// replacing nine independent Objective-C methods is not an atomic runtime operation.
    static func install(count: @escaping @Sendable () -> Void) throws {
        installLock.lock()
        defer { installLock.unlock() }
        guard !installed else { return }

        func required(_ name: String) throws -> (Method, Selector) {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(UserDefaults.self, selector) else {
                throw MacPerfInstallError.missingSelector(name)
            }
            return (method, selector)
        }
        let (objectMethod, objectSelector) = try required("setObject:forKey:")
        let (boolMethod, boolSelector) = try required("setBool:forKey:")
        let (integerMethod, integerSelector) = try required("setInteger:forKey:")
        let (floatMethod, floatSelector) = try required("setFloat:forKey:")
        let (doubleMethod, doubleSelector) = try required("setDouble:forKey:")
        let (urlMethod, urlSelector) = try required("setURL:forKey:")
        let (removeMethod, removeSelector) = try required("removeObjectForKey:")
        let (domainMethod, domainSelector) = try required("setPersistentDomain:forName:")
        let (removeDomainMethod, removeDomainSelector) = try required("removePersistentDomainForName:")

        var key = pthread_key_t()
        let createResult = pthread_key_create(&key, nil)
        guard createResult == 0 else { throw MacPerfInstallError.threadLocal(createResult) }
        let probeResult = pthread_setspecific(key, UnsafeMutableRawPointer(bitPattern: 1))
        let clearResult = pthread_setspecific(key, nil)
        guard probeResult == 0, clearResult == 0 else {
            pthread_key_delete(key)
            throw MacPerfInstallError.threadLocal(probeResult != 0 ? probeResult : clearResult)
        }
        let context = MacPerfContext(key: key, count: count)

        // Object arguments stay Objective-C objects: no String/URL/dictionary conversion or copying.
        typealias MacPerfObjectsIMP = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject) -> Void
        // BOOL is one byte on both macOS ABIs; Int8 also preserves noncanonical x86_64 BOOL bits.
        typealias MacPerfBoolIMP = @convention(c) (AnyObject, Selector, Int8, AnyObject) -> Void
        typealias MacPerfIntegerIMP = @convention(c) (AnyObject, Selector, Int, AnyObject) -> Void
        typealias MacPerfFloatIMP = @convention(c) (AnyObject, Selector, Float, AnyObject) -> Void
        typealias MacPerfDoubleIMP = @convention(c) (AnyObject, Selector, Double, AnyObject) -> Void
        typealias MacPerfNameIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void

        let objectOriginal = unsafeBitCast(method_getImplementation(objectMethod), to: MacPerfObjectsIMP.self)
        let objectBlock: @convention(block) (AnyObject, AnyObject?, AnyObject) -> Void = { receiver, value, name in
            let outermost = context.enter()
            defer { context.leave(outermost) }
            objectOriginal(receiver, objectSelector, value, name)
        }
        let boolOriginal = unsafeBitCast(method_getImplementation(boolMethod), to: MacPerfBoolIMP.self)
        let boolBlock: @convention(block) (AnyObject, Int8, AnyObject) -> Void = { receiver, value, name in
            let outermost = context.enter()
            defer { context.leave(outermost) }
            boolOriginal(receiver, boolSelector, value, name)
        }
        let integerOriginal = unsafeBitCast(method_getImplementation(integerMethod), to: MacPerfIntegerIMP.self)
        let integerBlock: @convention(block) (AnyObject, Int, AnyObject) -> Void = { receiver, value, name in
            let outermost = context.enter()
            defer { context.leave(outermost) }
            integerOriginal(receiver, integerSelector, value, name)
        }
        let floatOriginal = unsafeBitCast(method_getImplementation(floatMethod), to: MacPerfFloatIMP.self)
        let floatBlock: @convention(block) (AnyObject, Float, AnyObject) -> Void = { receiver, value, name in
            let outermost = context.enter()
            defer { context.leave(outermost) }
            floatOriginal(receiver, floatSelector, value, name)
        }
        let doubleOriginal = unsafeBitCast(method_getImplementation(doubleMethod), to: MacPerfDoubleIMP.self)
        let doubleBlock: @convention(block) (AnyObject, Double, AnyObject) -> Void = { receiver, value, name in
            let outermost = context.enter()
            defer { context.leave(outermost) }
            doubleOriginal(receiver, doubleSelector, value, name)
        }
        let urlOriginal = unsafeBitCast(method_getImplementation(urlMethod), to: MacPerfObjectsIMP.self)
        let urlBlock: @convention(block) (AnyObject, AnyObject?, AnyObject) -> Void = { receiver, value, name in
            let outermost = context.enter()
            defer { context.leave(outermost) }
            urlOriginal(receiver, urlSelector, value, name)
        }
        let removeOriginal = unsafeBitCast(method_getImplementation(removeMethod), to: MacPerfNameIMP.self)
        let removeBlock: @convention(block) (AnyObject, AnyObject) -> Void = { receiver, name in
            let outermost = context.enter()
            defer { context.leave(outermost) }
            removeOriginal(receiver, removeSelector, name)
        }
        let domainOriginal = unsafeBitCast(method_getImplementation(domainMethod), to: MacPerfObjectsIMP.self)
        let domainBlock: @convention(block) (AnyObject, AnyObject?, AnyObject) -> Void = { receiver, value, name in
            let outermost = context.enter()
            defer { context.leave(outermost) }
            domainOriginal(receiver, domainSelector, value, name)
        }
        let removeDomainOriginal = unsafeBitCast(method_getImplementation(removeDomainMethod), to: MacPerfNameIMP.self)
        let removeDomainBlock: @convention(block) (AnyObject, AnyObject) -> Void = { receiver, name in
            let outermost = context.enter()
            defer { context.leave(outermost) }
            removeDomainOriginal(receiver, removeDomainSelector, name)
        }

        // Materialize every block IMP before the first replacement. Captures retain the original IMPs
        // and the TLS context for process lifetime; no uninstallation races with active setters.
        let replacements: [(Method, IMP)] = [
            (objectMethod, imp_implementationWithBlock(objectBlock)),
            (boolMethod, imp_implementationWithBlock(boolBlock)),
            (integerMethod, imp_implementationWithBlock(integerBlock)),
            (floatMethod, imp_implementationWithBlock(floatBlock)),
            (doubleMethod, imp_implementationWithBlock(doubleBlock)),
            (urlMethod, imp_implementationWithBlock(urlBlock)),
            (removeMethod, imp_implementationWithBlock(removeBlock)),
            (domainMethod, imp_implementationWithBlock(domainBlock)),
            (removeDomainMethod, imp_implementationWithBlock(removeDomainBlock)),
        ]
        for (method, replacement) in replacements {
            method_setImplementation(method, replacement)
        }
        installed = true
    }

    private final class MacPerfContext: @unchecked Sendable {
        private let key: pthread_key_t
        private let count: @Sendable () -> Void

        init(key: pthread_key_t, count: @escaping @Sendable () -> Void) {
            self.key = key
            self.count = count
        }

        // An occupied TLS slot denotes any nesting depth. Only its outermost owner clears it.
        // No Thread.threadDictionary, NSNumber, per-call closure, or heap-allocated depth storage.
        @inline(__always) func enter() -> Bool {
            guard pthread_getspecific(key) == nil else { return false }
            guard pthread_setspecific(key, UnsafeMutableRawPointer(bitPattern: 1)) == 0 else {
                fatalError("NSUserDefaults probe lost TLS; refusing inaccurate counts")
            }
            count()
            return true
        }

        @inline(__always) func leave(_ outermost: Bool) {
            if outermost {
                guard pthread_setspecific(key, nil) == 0 else {
                    fatalError("NSUserDefaults probe could not clear TLS")
                }
            }
        }
    }
}
#endif
