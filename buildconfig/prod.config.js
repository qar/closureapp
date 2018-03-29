const path = require('path');
const devConfig = require('./dev.config.js');

module.exports = Object.assign(devConfig, {
  mode: 'production',
  devtool: false,
});
