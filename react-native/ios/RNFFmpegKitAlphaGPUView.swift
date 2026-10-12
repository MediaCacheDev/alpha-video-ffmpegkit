import UIKit

/// FFmpegKitAlphaGPUView with React props: the `{ uri, cacheKey? }` source, and the callbacks
/// sent as direct events.
@objc(RNFFmpegKitAlphaGPUView)
class RNFFmpegKitAlphaGPUView: FFmpegKitAlphaGPUView {

    /// A cacheKey here is the same as the cacheKey prop.
    @objc var reactSource: NSDictionary? {
        didSet {
            if let key = reactSource?["cacheKey"] as? String, !key.isEmpty {
                cacheKey = key
            }
            let uri = reactSource?["uri"] as? String
            source = uri?.isEmpty == false ? uri : nil
        }
    }
    @objc var reactOnLoad: RCTDirectEventBlock?
    @objc var reactOnError: RCTDirectEventBlock?
    @objc var reactOnEnd: RCTDirectEventBlock?

    override init(frame: CGRect) {
        super.init(frame: frame)
        forwardEvents()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        forwardEvents()
    }

    private func forwardEvents() {
        onLoad = { [weak self] totalFrames, width, height in
            self?.reactOnLoad?(["totalFrames": totalFrames, "width": width, "height": height])
        }
        onError = { [weak self] error in
            self?.reactOnError?(["error": error])
        }
        onEnd = { [weak self] in
            self?.reactOnEnd?([:])
        }
    }
}

@objc(RNFFmpegKitAlphaGPUViewManager)
class RNFFmpegKitAlphaGPUViewManager: RCTViewManager {

    override func view() -> UIView! {
        return RNFFmpegKitAlphaGPUView()
    }

    override static func requiresMainQueueSetup() -> Bool {
        return true
    }
}
