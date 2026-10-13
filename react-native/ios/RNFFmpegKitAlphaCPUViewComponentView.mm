//
//  RNFFmpegKitAlphaCPUViewComponentView.mm
//  Fabric component view for FFmpegKitAlphaCPUView (new architecture)
//

#ifdef RCT_NEW_ARCH_ENABLED

#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>

#import <React/RCTConversions.h>
#import <React/RCTViewComponentView.h>
#import "RNFFmpegKitAlpha-Bridging-Header.h"

#import <react/renderer/components/RNFFmpegKitAlphaSpec/ComponentDescriptors.h>
#import <react/renderer/components/RNFFmpegKitAlphaSpec/EventEmitters.h>
#import <react/renderer/components/RNFFmpegKitAlphaSpec/Props.h>
#import <react/renderer/components/RNFFmpegKitAlphaSpec/RCTComponentViewHelpers.h>

// The Swift views. The header's own module imports are skipped in Objective-C++, hence the
// UIKit, MetalKit and React imports above.
#if __has_include(<react_native_alpha_video_ffmpegkit/react_native_alpha_video_ffmpegkit-Swift.h>)
#import <react_native_alpha_video_ffmpegkit/react_native_alpha_video_ffmpegkit-Swift.h>
#else
#import "react_native_alpha_video_ffmpegkit-Swift.h"
#endif

using namespace facebook::react;

static const std::shared_ptr<const RNFFmpegKitAlphaCPUViewProps> &RNFFmpegKitAlphaCPUViewDefaultProps()
{
  static const auto defaultProps = std::make_shared<const RNFFmpegKitAlphaCPUViewProps>();
  return defaultProps;
}

@interface RNFFmpegKitAlphaCPUViewComponentView : RCTViewComponentView <RCTRNFFmpegKitAlphaCPUViewViewProtocol>
@end

@implementation RNFFmpegKitAlphaCPUViewComponentView {
  FFmpegKitAlphaCPUView *_player;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<RNFFmpegKitAlphaCPUViewComponentDescriptor>();
}

// A player holds its decoder and frames, so each mount gets a new one.
+ (BOOL)shouldBeRecycled
{
  return NO;
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    _props = RNFFmpegKitAlphaCPUViewDefaultProps();
    [self createPlayer];
  }
  return self;
}

- (void)createPlayer
{
  _player = [[FFmpegKitAlphaCPUView alloc] initWithFrame:self.bounds];
  [self forwardEvents];
  self.contentView = _player;
}

// Older React Native versions ignore shouldBeRecycled and recycle every component view.
- (void)prepareForRecycle
{
  [super prepareForRecycle];
  [self createPlayer];
  _props = RNFFmpegKitAlphaCPUViewDefaultProps();
}

// Removing the player from its superview stops it, as it did under the old architecture.
- (void)invalidate
{
  [_player removeFromSuperview];
}

// Only the props that changed, as the old architecture sets them: changing mode restarts
// playback, for one. The player's defaults match the spec's.
- (void)updateProps:(const Props::Shared &)props oldProps:(const Props::Shared &)oldProps
{
  const auto &previous = *std::static_pointer_cast<const RNFFmpegKitAlphaCPUViewProps>(_props);
  const auto &next = *std::static_pointer_cast<const RNFFmpegKitAlphaCPUViewProps>(props);

  if (previous.autoPlay != next.autoPlay) _player.autoPlay = next.autoPlay;
  if (previous.loop != next.loop) _player.loop = next.loop;
  if (previous.paused != next.paused) _player.paused = next.paused;
  if (previous.verbose != next.verbose) _player.verbose = next.verbose;
  if (previous.mode != next.mode) _player.mode = RCTNSStringFromString(toString(next.mode));
  if (previous.streamBufferFrames != next.streamBufferFrames) _player.streamBufferFrames = next.streamBufferFrames;

  // A cacheKey inside source is the same as the cacheKey prop, which wins.
  const auto &cacheKey = next.cacheKey.empty() ? next.source.cacheKey : next.cacheKey;
  const auto &previousCacheKey = previous.cacheKey.empty() ? previous.source.cacheKey : previous.cacheKey;
  if (previousCacheKey != cacheKey) _player.cacheKey = RCTNSStringFromStringNilIfEmpty(cacheKey);
  if (previous.source.uri != next.source.uri) _player.source = RCTNSStringFromStringNilIfEmpty(next.source.uri);

  [super updateProps:props oldProps:oldProps];
}

- (std::shared_ptr<const RNFFmpegKitAlphaCPUViewEventEmitter>)playerEventEmitter
{
  return std::static_pointer_cast<const RNFFmpegKitAlphaCPUViewEventEmitter>(_eventEmitter);
}

- (void)forwardEvents
{
  __weak RNFFmpegKitAlphaCPUViewComponentView *weakSelf = self;
  _player.onLoad = ^(NSInteger totalFrames, NSInteger width, NSInteger height) {
    auto emitter = [weakSelf playerEventEmitter];
    if (emitter) emitter->onLoad({.totalFrames = (int)totalFrames, .width = (int)width, .height = (int)height});
  };
  _player.onError = ^(NSString *error) {
    auto emitter = [weakSelf playerEventEmitter];
    if (emitter) emitter->onError({.error = RCTStringFromNSString(error)});
  };
  _player.onEnd = ^{
    auto emitter = [weakSelf playerEventEmitter];
    if (emitter) emitter->onEnd({});
  };
}

#pragma mark - Commands

- (void)handleCommand:(const NSString *)commandName args:(const NSArray *)args
{
  RCTRNFFmpegKitAlphaCPUViewHandleCommand(self, commandName, args);
}

- (void)seekToFrame:(NSInteger)frame
{
  [_player seekToFrame:frame];
}

- (void)seekToTime:(double)seconds
{
  [_player seekToTime:seconds];
}

@end

// Older React Native versions look the class up by this name instead of codegenConfig.ios.componentProvider.
extern "C" Class<RCTComponentViewProtocol> RNFFmpegKitAlphaCPUViewCls(void)
{
  return RNFFmpegKitAlphaCPUViewComponentView.class;
}

#endif
