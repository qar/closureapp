const { app, BrowserWindow, dialog, ipcMain }  = require('electron');
const path = require('path');
const url = require('url');
const fs = require('fs');
const jsmediatags = require('jsmediatags');
const md5File = require('md5-file');
const Datastore = require('nedb');

ipcMain.on('addFileToLibrary', openFileDialog);

const SOUNDS_DB_DIR = path.resolve(app.getPath('userData'), 'app_data', 'sounds.db');
const SETTINGS_DB_DIR = path.resolve(app.getPath('userData'), 'app_data', 'settings.db');
const MEDIA_DIR = path.resolve(app.getPath('home'), 'my_music_repo');
let  MODE;
try {
  MODE = fs.readFileSync('./.MODE', 'utf-8').replace(/\s/, '');
} catch(e) {
  MODE = 'development';
}

if (!fs.existsSync(MEDIA_DIR)) fs.mkdirSync(MEDIA_DIR)

global.soundsDb = new Datastore({ filename: SOUNDS_DB_DIR, autoload: true });
global.settingsDb = new Datastore({ filename: SETTINGS_DB_DIR, autoload: true });
global.MODE = MODE;

let willQuit = false;

// 保持一个对于 window 对象的全局引用，如果你不这样做，
// 当 JavaScript 对象被垃圾回收， window 会被自动地关闭
let win

function createWindow () {
  // 创建浏览器窗口。
  win = new BrowserWindow({width: 1300, height: 800, titleBarStyle: 'hidden' })

  // 然后加载应用的 index.html。
  win.loadURL(`file://${__dirname}/index.html`);

  win.openDevTools();

  win.on('close', (ev) => {
    if (!willQuit) {
      ev.preventDefault();
      win.hide();
    } else {
      win = null;
    }
  });

  // 当 window 被关闭，这个事件会被触发。
  win.on('closed', () => {
    // 取消引用 window 对象，如果你的应用支持多窗口的话，
    // 通常会把多个 window 对象存放在一个数组里面，
    // 与此同时，你应该删除相应的元素。
    win = null
  })

  win.on('show', (ev) => {
    win.show();
  });
}

app.on('before-quit', () => { willQuit = true });

// Electron 会在初始化后并准备
// 创建浏览器窗口时，调用这个函数。
// 部分 API 在 ready 事件触发后才能使用。
app.on('ready', createWindow)

// 当全部窗口关闭时退出。
app.on('window-all-closed', () => {
  // 在 macOS 上，除非用户用 Cmd + Q 确定地退出，
  // 否则绝大部分应用及其菜单栏会保持激活。
  if (process.platform !== 'darwin') {
    app.quit()
  }
})

app.on('activate', () => {
  // 在macOS上，当单击dock图标并且没有其他窗口打开时，
  // 通常在应用程序中重新创建一个窗口。
  if (win === null) {
    createWindow()
  } else {
    if (!win.isVisible()) {
      win.restore();
    }
  }
})

// 在这文件，你可以续写应用剩下主进程代码。
// 也可以拆分成几个文件，然后用 require 导入。
function openFileDialog() {
  dialog.showOpenDialog({
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
      const dest = path.resolve(app.getPath('home'), 'my_music_repo', [hash, path.extname(f)].join(''));
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
                if (err) {
                  // handle error
                  return
                }

                win.webContents.send('addNewItem', result);
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



