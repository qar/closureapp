import React from 'react';
// import 'bootstrap/dist/css/bootstrap.css';
import './index.css';
import ReactDOM from 'react-dom';
import 'soundmanager2';
import path from 'path';
import fs from 'fs';
import { remote } from 'electron';
import App from './components/app';
import events from './events';
import { soundsDb } from './store';
import jsmediatags from 'jsmediatags';
import md5File from 'md5-file';

const soundManager = window.soundManager;

function setMainMenu() {
  const template = [
    {
      label: 'File',
      submenu: [
        {
          label: 'Add to Library',
          click: openFileDialog,
        },
      ]
    },

    {
      label: 'View',
      submenu: [
        {role: 'reload'},
        {role: 'forcereload'},
        {role: 'toggledevtools'},
        {type: 'separator'},
        {role: 'resetzoom'},
        {role: 'zoomin'},
        {role: 'zoomout'},
        {type: 'separator'},
        {role: 'togglefullscreen'}
      ]
    },
    {
      role: 'window',
      submenu: [
        {role: 'minimize'},
        {role: 'close'}
      ]
    },
    {
      role: 'help',
      submenu: [
        {
          label: 'Learn More',
          click () { require('electron').shell.openExternal('https://electronjs.org/docs/api') }
        }
      ]
    }
  ]

  if (process.platform === 'darwin') {
    template.unshift({
      label: remote.app.getName(),
      submenu: [
        {role: 'about'},
        {type: 'separator'},

        {
          label: 'Preferences',
          click () { events.emit('goto:settings') }
        },

        {type: 'separator'},

        {role: 'services', submenu: []},
        {type: 'separator'},
        {role: 'hide'},
        {role: 'hideothers'},
        {role: 'unhide'},
        {type: 'separator'},
        {role: 'quit'}
      ]
    })

    template[3].submenu = [
      {role: 'close'},
      {role: 'minimize'},
      {role: 'zoom'},
      {type: 'separator'},
      {role: 'front'}
    ]
  }

  const menu = remote.Menu.buildFromTemplate(template)
  remote.Menu.setApplicationMenu(menu)
}

function openFileDialog() {
  remote.dialog.showOpenDialog({
    properties: [ 'openFile', 'openDirectory', 'multiSelections' ],
    filters: [
      { name: 'Music', extensions: ['mp3'] }
    ]
  }, function(filepaths) {
    if (!filepaths) {
      return;
    }
    filepaths.forEach(f => {
      const hash = md5File.sync(f);
      const name = path.basename(f);
      const dest = path.resolve(remote.app.getPath('home'), 'my_music_repo', [hash, path.extname(f)].join(''));
      fs.createReadStream(f).pipe(fs.createWriteStream(dest));
      jsmediatags.read(f, {
        onSuccess: tag => {
          const item = {
            _id: hash,
            fileExt: path.extname(f), // with the dot, like .mp3
            fileSize: tag.size,
            album: tag.tags.album,
            artist: tag.tags.artist,
            title: tag.tags.title,
            track: tag.tags.track,
          };

          soundsDb.findOne({ _id: hash }, function(err, result) {
            if (!err && !result) { // noexist
              soundsDb.insert(item, function(err, result) {
                // handle error
              });
            } else {
              // handle error
            }
          });
        },

        onError: error => {
          // handle error
        },
      });
    });
  });
}

setMainMenu();

// ========================================

ReactDOM.render(
  <App />,
  document.getElementById('player')
);
