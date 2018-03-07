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

// ========================================

ReactDOM.render(
  <CorePlayer queue={ soundFiles } />,
  document.getElementById('player')
);
