import React from 'react';
import './index.scss';
import ReactDOM from 'react-dom';
import 'soundmanager2';
import path from 'path';
import fs from 'fs';
import { ipcRenderer, remote } from 'electron';
import App from './components/app';
import events from './events';
const soundsDb = remote.getGlobal('soundsDb');

const soundManager = window.soundManager;

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

setMainMenu();

// ========================================

ReactDOM.render(
  <App />,
  document.getElementById('player')
);
