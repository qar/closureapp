const path = require('path');

module.exports = {
  entry: './src/index.js',
  output: {
    filename: 'bundle.js',
    path: path.resolve(__dirname, '../dist')
  },

  module: {
    rules: [
      {
        test: /\.css$/,
        use: "css-loader"
      },

      {
        test: /\.js$/,
        exclude: /node_modules/,
        use: "babel-loader"
      },

      {
        test: /\.jsx?$/,
        exclude: /node_modules/,
        use: "babel-loader"
      }
    ],
  }
};
