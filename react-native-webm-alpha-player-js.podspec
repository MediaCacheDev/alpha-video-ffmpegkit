require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name         = "react-native-webm-alpha-player-js"
  s.version      = package['version']
  s.summary      = package['description']
  s.homepage     = package['repository']['url']
  s.authors      = package['author']

  s.license      = {
    :type => package['license'],
    :file => 'LICENSE'
  }

  s.platforms    = { :ios => "13.0" }
  s.source       = {
    :git => package['repository']['url'],
    :tag => "v#{s.version}"
  }

  # React Native source files
  s.source_files = [
    "ios/WebMAlphaCPUViewManager.{h,m,swift}",
    "ios/WebMAlphaGPUViewManager.{m,swift}",
    "ios/WebMAlphaCPUView.swift",
    "ios/WebMAlphaGPUView.swift",
    "ios/WebMSourceResolver.swift",
    "ios/WebMAlphaPlayer-Bridging-Header.h"
  ]
  s.swift_version = "5.0"

  s.static_framework = true

  # FFmpegKit with a VP9-only FFmpeg, built by scripts/build-ffmpeg-ios.sh. These are dynamic
  # frameworks (LGPL: users can replace them); CocoaPods embeds them in the app.
  s.vendored_frameworks = [
    "ios/Frameworks/ffmpegkit.xcframework",
    "ios/Frameworks/libavcodec.xcframework",
    "ios/Frameworks/libavformat.xcframework",
    "ios/Frameworks/libavutil.xcframework",
    "ios/Frameworks/libswresample.xcframework",
    "ios/Frameworks/libswscale.xcframework",
    "ios/Frameworks/libavfilter.xcframework",
    "ios/Frameworks/libavdevice.xcframework"

  ]

  s.frameworks = [
    "Foundation",
    "UIKit",
    "AVFoundation",
    "CoreMedia",
    "CoreVideo",
    "VideoToolbox",
    "AudioToolbox"
  ]

  s.libraries = [
    "z",
    "bz2",
    "iconv",
    "c++"
  ]

  s.dependency "React-Core"

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 armv7 armv7s'
  }
end
