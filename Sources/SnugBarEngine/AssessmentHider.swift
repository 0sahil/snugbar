import Foundation
import ObjectiveC

/// Hides menu bar items per app with the system's assessment-mode assertion.
///
/// PRIVATE API. This is the only file that uses it. macOS 27's private `MenuBarClientCore.framework` provides
/// `MBAssessmentModeAssertion`, which, while active, removes every status item whose app is not in the
/// configuration's allow-list (`MBAssessmentModeConfiguration initWithAllowedSystemItems:allowedBundleIdentifiers:`).
/// `allowedSystemItems` are indices of Apple's own items; unknown indices are ignored, so `0..<64` keeps them all and
/// an empty list hides them too. The framework is loaded at runtime with `dlopen`, every class and selector is checked
/// before use, and anything missing makes the hider report itself unavailable instead of crashing. The system ends
/// the assertion when this process exits, so the bar can't stay hidden after a crash.
@MainActor
public final class AssessmentHider: Hider {
    public let backend: HiderBackend = .assessment
    public let supportsAllowList = true
    public private(set) var lastError: String?
    public private(set) var isHiding = false
    /// True while hiding is requested but temporarily lifted (see `suspend()`).
    public private(set) var isSuspended = false

    /// Apple item indices kept visible. `0..<64` keeps all of them.
    public var allowedSystemItems: [Int] = Array(0..<64)

    private var baseAllowed: Set<String> = []
    private var temporarilyAllowed: Set<String> = []
    private var assertion: NSObject?
    private let api: API?

    public var isAvailable: Bool { api != nil }

    /// Called after the assertion is activated, replaced or dropped: items are about to move.
    public var onChange: (() -> Void)?

    /// The bundle IDs currently allowed (base plus temporary, or only the focused app while focusing).
    public var allowedBundleIDs: Set<String> { focusAllowed ?? baseAllowed.union(temporarilyAllowed) }

    /// While set, only these apps (plus Apple's items) are shown, regardless of the base allow-list.
    private var focusAllowed: Set<String>?
    public var isFocusing: Bool { focusAllowed != nil }

    /// Shows only `bundleIDs` (plus Apple's items) so an item that would otherwise be hidden or squeezed into macOS's
    /// overflow row lands in the visible bar right of the notch. Works whether or not a hide is active.
    public func focus(on bundleIDs: Set<String>) throws {
        focusAllowed = bundleIDs
        try activate()
    }

    /// Ends `focus(on:)`, restoring the regular hide (or showing everything if none is active).
    public func endFocus() {
        guard focusAllowed != nil else { return }
        focusAllowed = nil
        if isHiding, !isSuspended { try? activate() } else { invalidate() }
    }

    public init() {
        switch API.load() {
        case let .success(api):
            self.api = api
        case let .failure(error):
            self.api = nil
            lastError = error.description
        }
    }

    public func hide(allowing allowedBundleIDs: Set<String>) throws {
        guard api != nil else { throw HiderError.unavailable(lastError ?? "MenuBarClientCore not loaded") }
        baseAllowed = allowedBundleIDs
        isHiding = true
        isSuspended = false
        try activate()
    }

    public func show() {
        isHiding = false
        isSuspended = false
        temporarilyAllowed = []
        invalidate()
    }

    /// Lifts the hide without forgetting it (used so a click can reach Notification Center).
    public func suspend() {
        guard isHiding, !isSuspended else { return }
        isSuspended = true
        invalidate()
    }

    /// Re-applies a suspended hide at once.
    public func resume() {
        guard isHiding, isSuspended else { return }
        isSuspended = false
        try? activate()
    }

    /// Lets one more app through while hiding (to open its menu), without changing the base allow-list.
    public func allowTemporarily(_ bundleID: String) {
        guard !allowedBundleIDs.contains(bundleID) else { return }
        temporarilyAllowed.insert(bundleID)
        if isHiding, !isSuspended { try? activate() }
    }

    public func endTemporaryAllowance(_ bundleID: String) {
        guard temporarilyAllowed.remove(bundleID) != nil else { return }
        if isHiding, !isSuspended { try? activate() }
    }

    // MARK: - Assertion

    private func activate() throws {
        guard let api else { throw HiderError.unavailable(lastError ?? "MenuBarClientCore not loaded") }
        guard let configuration = api.makeConfiguration(systemItems: allowedSystemItems, bundleIDs: Array(allowedBundleIDs).sorted()) else {
            lastError = "MBAssessmentModeConfiguration init returned nil"
            throw HiderError.unavailable(lastError!)
        }
        let previous = assertion
        let next = api.makeAssertion()
        assertion = next
        api.activate(next, configuration: configuration) { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let error {
                        self.lastError = "activate failed: \(error.localizedDescription)"
                    } else if self.assertion === next {
                        self.lastError = nil
                    }
                }
            }
        }
        // Replace rather than stack: drop the old assertion once the new one is in place.
        if let previous { api.invalidate(previous) }
        onChange?()
    }

    private func invalidate() {
        guard let assertion else { return }
        api?.invalidate(assertion)
        self.assertion = nil
        onChange?()
    }

    // MARK: - Runtime binding

    /// Resolved classes and method implementations of the private framework.
    private struct API {
        static let frameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"

        typealias InitFn = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> AnyObject?
        typealias ActivateFn = @convention(c) (AnyObject, Selector, AnyObject, @escaping @convention(block) (NSError?) -> Void) -> Void
        typealias InvalidateFn = @convention(c) (AnyObject, Selector) -> Void

        static let initSelector = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
        static let activateSelector = NSSelectorFromString("activateWithConfiguration:completionHandler:")
        static let invalidateSelector = NSSelectorFromString("invalidate")

        let configurationClass: NSObject.Type
        let assertionClass: NSObject.Type
        let initImp: InitFn
        let activateImp: ActivateFn
        let invalidateImp: InvalidateFn

        struct LoadError: Error, CustomStringConvertible { let description: String }

        static func load() -> Result<API, LoadError> {
            guard dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL) != nil else {
                let reason = dlerror().map { String(cString: $0) } ?? "unknown"
                return .failure(LoadError(description: "dlopen MenuBarClientCore failed: \(reason)"))
            }
            guard let cfg = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type else {
                return .failure(LoadError(description: "class MBAssessmentModeConfiguration missing"))
            }
            guard let assertion = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type else {
                return .failure(LoadError(description: "class MBAssessmentModeAssertion missing"))
            }
            guard let initMethod = class_getInstanceMethod(cfg, initSelector) else {
                return .failure(LoadError(description: "MBAssessmentModeConfiguration lacks initWithAllowedSystemItems:allowedBundleIdentifiers:"))
            }
            guard let activateMethod = class_getInstanceMethod(assertion, activateSelector) else {
                return .failure(LoadError(description: "MBAssessmentModeAssertion lacks activateWithConfiguration:completionHandler:"))
            }
            guard let invalidateMethod = class_getInstanceMethod(assertion, invalidateSelector) else {
                return .failure(LoadError(description: "MBAssessmentModeAssertion lacks invalidate"))
            }
            // Check the argument shapes the casts below rely on: id return / two object args; void / object + block.
            guard typeEncoding(initMethod).hasPrefix("@"), method_getNumberOfArguments(initMethod) == 4,
                  typeEncoding(activateMethod).hasPrefix("v"), method_getNumberOfArguments(activateMethod) == 4,
                  method_getNumberOfArguments(invalidateMethod) == 2
            else {
                return .failure(LoadError(description: "MenuBarClientCore method signatures changed"))
            }
            return .success(API(
                configurationClass: cfg,
                assertionClass: assertion,
                initImp: unsafeBitCast(method_getImplementation(initMethod), to: InitFn.self),
                activateImp: unsafeBitCast(method_getImplementation(activateMethod), to: ActivateFn.self),
                invalidateImp: unsafeBitCast(method_getImplementation(invalidateMethod), to: InvalidateFn.self)
            ))
        }

        private static func typeEncoding(_ method: Method) -> String {
            method_getTypeEncoding(method).map { String(cString: $0) } ?? ""
        }

        func makeConfiguration(systemItems: [Int], bundleIDs: [String]) -> AnyObject? {
            guard let allocated = configurationClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else {
                return nil
            }
            let items = systemItems.map { NSNumber(value: $0) } as NSArray
            return initImp(allocated, Self.initSelector, items, bundleIDs as NSArray)
        }

        func makeAssertion() -> NSObject {
            assertionClass.init()
        }

        func activate(_ assertion: NSObject, configuration: AnyObject, completion: @escaping (NSError?) -> Void) {
            activateImp(assertion, Self.activateSelector, configuration) { error in completion(error) }
        }

        func invalidate(_ assertion: NSObject) {
            invalidateImp(assertion, Self.invalidateSelector)
        }
    }
}
