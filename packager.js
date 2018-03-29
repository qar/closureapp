const path = require('path');
const fs = require('fs');
const packager = require('electron-packager');

fs.writeFileSync('MODE', 'production');

const options = {
  // required, the source directory
  dir: path.resolve(__dirname),

  // The base directory where the finished package(s) are created.
  out: path.resolve(__dirname, 'build'),

  platform: 'darwin',

  ignore: [
    /node_modules/,
    /^\/assets/,
    /^\/buildconfig/,
    /^\/components/,
    /^\/src/,
    /^\/styles/,
    /^\/utils/,
    /^\/LICENSE/,
    /^\/packager\.js/,
    /^\/yarn\.lock/,
    /^\/README\.md/,
  ],

  afterCopy: [function(buildPath, electronVersion, platform, arch, callback) {
    console.log('DEBUG afterCopy ', buildPath, electronVersion, platform, arch);
    callback();
  }],

  afterExtract: [function(buildPath, electronVersion, platform, arch, callback) {
    console.log('DEBUG afterExtract ', buildPath, electronVersion, platform, arch);
    callback();
  }],

  afterPrune: [function(buildPath, electronVersion, platform, arch, callback) {
    console.log('DEBUG afterPrune ', buildPath, electronVersion, platform, arch);
    callback();
  }],

  packageManager: 'yarn',
};

packager(options, function done_callback (err, appPaths) {
  console.log('DEBUG DONE ! ', err, appPaths);
  fs.unlinkSync('MODE');
});
