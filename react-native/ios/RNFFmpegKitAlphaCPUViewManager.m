#import <React/RCTViewManager.h>

@interface RCT_EXTERN_MODULE(RNFFmpegKitAlphaCPUViewManager, RCTViewManager)

RCT_REMAP_VIEW_PROPERTY(source, reactSource, NSDictionary)
RCT_EXPORT_VIEW_PROPERTY(cacheKey, NSString)
RCT_EXPORT_VIEW_PROPERTY(autoPlay, BOOL)
RCT_EXPORT_VIEW_PROPERTY(loop, BOOL)
RCT_EXPORT_VIEW_PROPERTY(paused, BOOL)
RCT_EXPORT_VIEW_PROPERTY(verbose, BOOL)
RCT_EXPORT_VIEW_PROPERTY(mode, NSString)
RCT_EXPORT_VIEW_PROPERTY(streamBufferFrames, NSInteger)
RCT_REMAP_VIEW_PROPERTY(onLoad, reactOnLoad, RCTDirectEventBlock)
RCT_REMAP_VIEW_PROPERTY(onError, reactOnError, RCTDirectEventBlock)
RCT_REMAP_VIEW_PROPERTY(onEnd, reactOnEnd, RCTDirectEventBlock)

RCT_EXTERN_METHOD(seekToFrame:(nonnull NSNumber *)reactTag frame:(nonnull NSNumber *)frame)
RCT_EXTERN_METHOD(seekToTime:(nonnull NSNumber *)reactTag seconds:(nonnull NSNumber *)seconds)

@end
