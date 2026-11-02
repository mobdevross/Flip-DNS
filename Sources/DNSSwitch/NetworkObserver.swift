import Foundation
import SystemConfiguration

final class NetworkObserver {
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    var onChange: (() -> Void)?

    init() {
        var context = SCDynamicStoreContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "Flip" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkObserver>.fromOpaque(info).takeUnretainedValue().onChange?()
        }, &context)
        guard let store else { return }
        let patterns = ["Setup:/Network/.*", "State:/Network/Global/.*", "State:/Network/Service/.*/DNS"]
        guard SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray),
              let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else { return }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
