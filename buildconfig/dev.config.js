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

  resolve: {
    alias: {
      components: path.resolve(__dirname, '../components'),
      styles: path.resolve(__dirname, '../styles'),
      assets: path.resolve(__dirname, '../assets')
    }
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
          {
            loader: "css-loader",
            options: {
              // https://github.com/webpack-contrib/css-loader#modules
              modules: true,
              localIdentName: '[name]__[local]___[hash:base64:5]',
            }
          },
          { loader: 'sass-loader' }
        ],
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
