const path = require('path');

module.exports = {
  mode: 'development',
  devtool: 'inline-source-map',
  target: 'electron-renderer',
  entry: './src/index.js',
  output: {
    filename: 'bundle.js',
    path: path.resolve(__dirname, '../dist')
  },

  module: {
    rules: [
      {
        test: /\.css$/,
        use: [
          { loader: "style-loader" },
          { loader: "css-loader" }
        ]
      },

      {
        test: /\.scss$/,
        use: [
          { loader: "style-loader" },
          { loader: "css-loader" },
          { loader: 'sass-loader' }
        ]
      },

      {
        test: /\.woff($|\?)|\.woff2($|\?)|\.ttf($|\?)|\.eot($|\?)|\.svg($|\?)|\.jpg($|\?)/,
        loader: 'url-loader'
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
