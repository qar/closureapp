import React from 'react';
import 'styles/global.scss';
import ReactDOM from 'react-dom';
import 'soundmanager2';
import path from 'path';
import fs from 'fs';
import { ipcRenderer, remote } from 'electron';
import App from 'components/app';
const events =  remote.getGlobal('events');
const playlistsDb = remote.getGlobal('playlistsDb');
const MODE = remote.getGlobal('MODE');

const soundManager = window.soundManager;
let rightClickPosition = null;

function setMainMenu() {
  const template = [
    {
      label: 'File',
      submenu: [
        {
          label: 'Add File to Library',
          click () { ipcRenderer.send('addFileToLibrary') }
        },
      ]
    },

    {
      label: 'View',
      submenu: [
        {role: 'reload'},
        {role: 'forcereload'},
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

  if (MODE === 'development') {
    template[1].submenu.splice(2, 0, {role: 'toggledevtools'});
  }

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

function popupContextMenu(ev) {
  const playlistMenus = [];

  playlistsDb.find({}, (err, results) => {
  });

  const template = [
    {
      label: 'Play',
      click: () => { events.emit('play:current') }
    },

    {
      label: 'Stop',
      click: () => { events.emit('play:stop') }
    },

    {
      label: 'Add to Playlist',
      submenu: [
        {
          label: 'New Playlist',
          click: () => { events.emit('playlist:new') }
        }
      ]
    }
  ];

  const menu = remote.Menu.buildFromTemplate(template)
  rightClickPosition = {x: ev.x, y: ev.y}
  menu.popup(remote.getCurrentWindow())
}

window.addEventListener('contextmenu', (e) => {
  e.preventDefault()
  popupContextMenu(e);
}, false)

setMainMenu();

// ========================================

ReactDOM.render(
  <App />,
  document.getElementById('player')
);
