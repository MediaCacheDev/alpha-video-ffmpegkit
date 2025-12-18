import Foundation

/**
 * View Manager for the Metal-accelerated WebM Alpha Player (iOS)
 */
@objc(WebMAlphaGPUViewManager)
class WebMAlphaGPUViewManager: RCTViewManager {
    
    override func view() -> UIView! {
        return WebMAlphaGPUView()
    }
    
    override static func requiresMainQueueSetup() -> Bool {
        return true
    }
}
