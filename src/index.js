import React from 'react';
import './index.css';
import ReactDOM from 'react-dom';
import 'soundmanager2';
import path from 'path';
import fs from 'fs';
import { remote } from 'electron';
import CorePlayer from './components/play-core';

const MEDIA_DIR = path.resolve(remote.app.getPath('home'), 'my_music_repo');
const soundFiles = fs.readdirSync(MEDIA_DIR).map(f => {
  return {
    name: f,
    path: path.resolve(MEDIA_DIR, f)
  };
});

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
    filepaths.forEach(f => {
      const name = path.basename(f);
      const dest = path.resolve(remote.app.getPath('home'), 'my_music_repo', name);
      fs.createReadStream(f).pipe(fs.createWriteStream(dest));
    });
  });
}

setMainMenu();

// ========================================

ReactDOM.render(
  <CorePlayer queue={ soundFiles } />,
  document.getElementById('player')
);
