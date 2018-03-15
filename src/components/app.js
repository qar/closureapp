import React from 'react';
import PlayControl from '../components/play-control';
import PlayQueue from '../components/play-queue';
import PlayProgressBar from '../components/play-progressbar';
import PlayDuration from '../components/play-duration';
import PlayModeControl from '../components/play-mode-control';
import PlayVolumeControl from '../components/play-volume-control';
import AccountSettings from '../components/account-settings';
import events from '../events';
import path from 'path';
import { remote } from 'electron';
import { soundsDb } from '../store';

const MEDIA_DIR = path.resolve(remote.app.getPath('home'), 'my_music_repo');

class App extends React.Component {
  constructor(props) {
    super(props);

    this.state = {
      queue: [],
      passTime: 0,
      totalTime: 0,
      isPlaying: false,
      isListRepeat: true,
      volume: 40,
      showSettings: false,
    };

    this.playerSetup();
    this.currentSong = null;

    events.on('goto:settings', () => {
      this.setState({ showSettings: true });
    });

    soundsDb.find({}, (err, items) => {
      if (err) {
        // handle error
        return;
      }

      items.forEach(item => {
        item.path = path.resolve(MEDIA_DIR, [item._id, item.fileExt].join(''))
      });

      this.setState({ queue: items });
    });
  }

  _findNextSound(currentSoundPth) {
    const idx = this.state.queue.findIndex(i => i.path === currentSoundPth);
    if (idx + 1 === this.state.queue.length) {
      return this.state.queue[0]; // return to the begining
    } else {
      return this.state.queue[idx + 1];
    }
  }

  _findPrevSound(currentSoundPth) {
    const idx = this.state.queue.findIndex(i => i.path === currentSoundPth);
    if (idx === 0) {
      return this.state.queue[0]; // remain at the beginning
    } else {
      return this.state.queue[idx - 1];
    }
  }

  playerSetup() {
    soundManager.setup({
      url: '/node_modules/soundmanager2/swf/soundmanager2.swf',
      useHighPerformance: true,
      onready: function() {
      },

      ontimeout: function() {
        // Hrmm, SM2 could not start. Missing SWF? Flash blocked? Show an error, etc.?
      }
    });
  }

  _updatePlayProgress(position, durationEstimate, duration) {
    var width,
        passMinutes,
        passSeconds,
        totalMinutes,
        totalSeconds;

    passMinutes = Math.floor(position / 1000 / 60);
    passSeconds = Math.ceil(position / 1000 - passMinutes * 60);
    var passTime = (passMinutes >= 10 ? passMinutes.toString() : '0' + passMinutes) +
                    ':' +
                    (passSeconds >= 10 ? passSeconds.toString() : '0' + passSeconds);

    this.state.passTime = passTime;
    this.setState({ passTime });

    if (!this.state.totalTime) {
      totalMinutes = Math.floor(durationEstimate / 1000 / 60);
      totalSeconds = Math.ceil(duration / 1000 - totalMinutes * 60);
      var totalTime = (totalMinutes >= 10 ? totalMinutes.toString() : '0' + totalMinutes) +
                      ':' +
                      (totalSeconds >= 10 ? totalSeconds.toString() : '0' + totalSeconds);
      this.setState({ totalTime });
    }

    this.state.durationEstimate = durationEstimate;
    this.setState({ durationEstimate });

    width = Math.min(100, Math.max(0, (100 * position / durationEstimate))) + '%';

    if (duration) {
      this.setState({ width });
    }
  }

  _createSoundOpts() {
    const _this = this;

    return {
      volume: this.state.volume,

      onplay: () => {
        this.setState({ isPlaying: true });
      },

      onresume: () => {
        this.setState({ isPlaying: true });
      },

      onpause: () => {
        this.setState({ isPlaying: false });
      },

      whileplaying: function() {
        _this._updatePlayProgress(this.position, this.durationEstimate, this.duration);
      },

      onstop: () => {
        this.setState({
          passTime: 0,
          totalTime: 0,
          width: '0%',
          isPlaying: false
        });
      },
    };
  }

  _playCount() {
    const id = path.parse(this.currentSong.url).name;
    soundsDb.findOne({ _id: id }, (err, sound) => {
      if (err) {
        // handle error
        return
      }

      if (!sound.playCount) {
        sound.playCount = 0;
      }

      sound.playCount += 1;

      soundsDb.update({ _id: id }, { $set: { playCount: sound.playCount }}, (err, sound) => {
        if (err) {
          // handle error
        }
      });

      this.state.queue.forEach(i => {
        if (i._id === id) {
          i.playCount = sound.playCount;
        }
      });

      this.setState({ queue: this.state.queue });

    });
  }

  prepareSong(path) {
    const globalState = this.state;
    const _this = this;

    const nextSoundPath = this._findNextSound(path).path;

    const opts = Object.assign({}, this._createSoundOpts(),  {
      url: path,
      onfinish: () => {
        this.setState({
          width: '0%',
          isPlaying: false,
          passTime: 0,
          totalTime: 0,
        });

        this._playCount();

        if (!this.state.isListRepeat) {
          this.currentSong.play();
        } else {
          this.prepareSong(nextSoundPath).play();
        }
      }
    });

    this.currentSong = soundManager.createSound(opts);
    return this.currentSong;
  }

  play() {
    if (!this.currentSong) return;

    if (!this.state.isPlaying && this.state.passTime) {
      // is paused
      this.currentSong.resume();
    } else {
      this.currentSong.play();
    }
  }

  // switch song
  playItem(path) {
    this.stop();

    this.prepareSong(path);

    this.play();
  }

  pause() {
    this.currentSong.pause();
  }

  prev() {
    if (!this.currentSong) return;
    const prevSoundPath = this._findPrevSound(this.currentSong.url).path;
    this.currentSong.stop();
    this.prepareSong(prevSoundPath).play();
  }

  next() {
    if (!this.currentSong) return;
    const prevSoundPath = this._findNextSound(this.currentSong.url).path;
    this.currentSong.stop();
    this.prepareSong(prevSoundPath).play();
  }

  stop() {
    if (!this.currentSong) return;

    this.currentSong.stop();
  }

  setVolume(volume) {
    this.setState({ volume });
    soundManager.setVolume(volume);
  }

  setPos(rate) {
    this.currentSong.setPosition(this.currentSong.durationEstimate * rate);
  }

  repeatList() {
    this.setState({ isListRepeat: true });
  }

  repeatItem() {
    this.setState({ isListRepeat: false });
  }

  _renderMainZone() {
    if (this.state.showSettings) {
      return <AccountSettings />
    } else {
      return <div className="col-md-12">
          <PlayQueue play={ (path) => this.playItem(path) } queue={ this.state.queue } currentSound={ this.currentSong ? this.currentSong.url : '' } />
        </div>
    }
  }

  render() {
    return (
      <div className="row">
        <div className="col-md-2">
          <PlayControl onPlayBtnClicked={ () => this.play() }
                       onPauseBtnClicked={ () => this.pause() }
                       onPrevBtnClicked={ () => this.prev() }
                       onNextBtnClicked={ () => this.next() }
                       onStopBtnClicked={ () => this.stop() }
                       isPlaying={ this.state.isPlaying } />
        </div>

        <div className="col-md-2">
          <PlayVolumeControl volume={ this.state.volume } setVolume={ this.setVolume.bind(this) } />
        </div>
        <div className="col-md-5">
          <PlayProgressBar barProgress={this.state.width} setPos={ this.setPos.bind(this) } />
        </div>
        <div className="col-md-2">
          <PlayDuration passTime={ this.state.passTime } totalTime={ this.state.totalTime } />
        </div>
        <div className="col-md-1">
          <PlayModeControl isListRepeat={ this.state.isListRepeat } onListRepeatClicked={ this.repeatItem.bind(this) } onItemRepeatClicked={ this.repeatList.bind(this) } />
        </div>

        <div className="col-md-12">
          <PlayQueue play={ (path) => this.playItem(path) } queue={ this.state.queue } currentSound={ this.currentSong ? this.currentSong.url : '' } />
        </div>
      </div>
    );
  }
}

export default App;

