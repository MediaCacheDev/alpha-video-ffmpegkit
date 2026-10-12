require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name         = "react-native-alpha-video-ffmpegkit"
  s.version      = package['version']
  s.summary      = package['description']
  s.homepage     = package['homepage']
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

  # The iOS library (ios/Sources/AlphaVideoFFmpegKit, also the Swift package) and the React
  # Native views, which subclass its views
  s.source_files = [
    "ios/Sources/AlphaVideoFFmpegKit/**/*.swift",
    "react-native/ios/**/*.{h,m,swift}"
  ]
  s.public_header_files = "react-native/ios/RNFFmpegKitAlpha-Bridging-Header.h"
  s.swift_version = "5.0"

  s.static_framework = true

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
  # FFmpegKit with a VP9-only FFmpeg (github.com/MediaCacheDev/ffmpegkit-vp9). Dynamic frameworks
  # (LGPL: users can replace them), embedded in the app. 6.0.0 is the last version on CocoaPods
  # trunk, which is read-only from 2 December 2026.
  s.dependency "ffmpegkit-vp9", "6.0.0"

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 armv7 armv7s'
  }
end
