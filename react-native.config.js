module.exports = {
  dependency: {
    platforms: {
      ios: {},
      android: {
        sourceDir: './react-native/android',
        packageImportPath: 'import dev.mediacache.alphavideo.ffmpegkit.reactnative.FFmpegKitAlphaPackage;',
        packageInstance: 'new FFmpegKitAlphaPackage()',
      },
    },
  },
};
