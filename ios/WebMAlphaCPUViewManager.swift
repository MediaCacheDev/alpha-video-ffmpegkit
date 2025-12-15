import Foundation

/**
 * View Manager for the CPU-based WebM Alpha Player (iOS)
 */
@objc(WebMAlphaCPUViewManager)
class WebMAlphaCPUViewManager: RCTViewManager {
    
    override func view() -> UIView! {
        return WebMAlphaCPUView()
    }
    
    override static func requiresMainQueueSetup() -> Bool {
        return true
    }
}
