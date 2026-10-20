# The iOS library without React Native, for CocoaPods. (React Native apps use
# react-native-alpha-video-ffmpegkit.podspec, which autolinking finds in the npm package.)
#
# 1.0.0 goes on CocoaPods trunk, which is read-only from 2 December 2026. Later versions are used
# through the podspec at their tag:
#   pod 'alpha-video-ffmpegkit', :podspec => 'https://raw.githubusercontent.com/MediaCacheDev/alpha-video-ffmpegkit/v<version>/alpha-video-ffmpegkit.podspec'

Pod::Spec.new do |s|
  s.name          = 'alpha-video-ffmpegkit'
  s.module_name   = 'AlphaVideoFFmpegKit'
  s.version       = '1.0.0'
  s.summary       = 'Transparent video for iOS: VP9 WebM with alpha, decoded by FFmpegKit and drawn with Metal or UIKit.'
  s.homepage      = 'https://github.com/MediaCacheDev/alpha-video-ffmpegkit'
  s.license       = { :type => 'MIT', :file => 'LICENSE' }
  s.author        = { 'Daniel Kasprowicz' => '9932671+danielkpl2@users.noreply.github.com' }
  s.platform      = :ios, '13.0'
  s.source        = { :git => 'https://github.com/MediaCacheDev/alpha-video-ffmpegkit.git', :tag => "v#{s.version}" }
  s.swift_version = '5.0'

  s.source_files  = 'ios/Sources/AlphaVideoFFmpegKit/**/*.swift'
  s.frameworks    = 'AVFoundation', 'Metal', 'MetalKit', 'UIKit'
  # Dynamic XCFrameworks (LGPL: apps can replace them). The last version on trunk.
  s.dependency 'ffmpegkit-vp9', '6.0.0'
end
