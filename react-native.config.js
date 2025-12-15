module.exports = {
  dependency: {
    platforms: {
      android: {
        sourceDir: './android',
        packageImportPath: 'import com.webmalphaplayer.WebMAlphaPlayerPackage;',
        packageInstance: 'new WebMAlphaPlayerPackage()',
      },
      ios: {
        project: './ios',
      },
    },
  },
};
