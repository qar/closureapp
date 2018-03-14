import path from 'path';
import fs from 'fs';
import { remote } from 'electron';
import Datastore from 'nedb';

const SOUNDS_DB_DIR = path.resolve(remote.app.getPath('userData'), 'app_data', 'sounds.db');
const SETTINGS_DB_DIR = path.resolve(remote.app.getPath('userData'), 'app_data', 'settings.db');

// Load Database
const soundsDb = new Datastore({ filename: SOUNDS_DB_DIR, autoload: true });
const settingsDb = new Datastore({ filename: SETTINGS_DB_DIR, autoload: true });

export {
  soundsDb,
  settingsDb
};
