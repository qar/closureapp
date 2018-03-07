import React from 'react';
import PlayControl from '../components/play-control';
import PlayQueue from '../components/play-queue';
import PlayProgressBar from '../components/play-progressbar';
import PlayDuration from '../components/play-duration';

class CorePlayer extends React.Component {
  constructor(props) {
    super(props);

    this.queue = props.queue;

    this.state = {
      passTime: 0,
      totalTime: 0,
      isPlaying: false,
    };

    this.currentSong = null;

    this.playerSetup();
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

  prepareSong(path) {
    const globalState = this.state;
    const _this = this;

    this.currentSong = soundManager.createSound({
      url: path,

      onplay: function() {
        _this.setState({ isPlaying: true });
      },

      onresume: function() {
        _this.setState({ isPlaying: true });
      },

      onpause: function() {
        _this.setState({ isPlaying: false });
      },

      whileplaying: function() {
        var width,
            passMinutes,
            passSeconds,
            totalMinutes,
            totalSeconds;

        passMinutes = Math.floor(this.position / 1000 / 60);
        passSeconds = Math.ceil(this.position / 1000 - passMinutes * 60);
        var passTime = (passMinutes >= 10 ? passMinutes.toString() : '0' + passMinutes) +
                        ':' +
                        (passSeconds >= 10 ? passSeconds.toString() : '0' + passSeconds);

        globalState.passTime = passTime;
        _this.setState({ passTime });

        if (!globalState.totalTime) {
          totalMinutes = Math.floor(this.durationEstimate / 1000 / 60);
          totalSeconds = Math.ceil(this.duration / 1000 - totalMinutes * 60);
          var totalTime = (totalMinutes >= 10 ? totalMinutes.toString() : '0' + totalMinutes) +
                          ':' +
                          (totalSeconds >= 10 ? totalSeconds.toString() : '0' + totalSeconds);
          _this.setState({ totalTime });
        }

        // _this.durationEstimate = this.durationEstimate;
        globalState.durationEstimate = this.durationEstimate;
        _this.setState({ durationEstimate: this.durationEstimate });

        width = Math.min(100, Math.max(0, (100 * this.position / this.durationEstimate))) + '%';

        if (this.duration) {
          _this.setState({ width });
        }
      },

      onstop: function() {
        _this.setState({
          passTime: 0,
          width: '0%',
          isPlaying: false
        });
      },

      onfinish: function() {
        _this.setState({
          width: '0%',
          isPlaying: false,
          passTime: 0,
        });
      }
    });
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
    /* TODO */
  }

  next() {
    /* TODO */
  }

  stop() {
    if (!this.currentSong) return;

    this.currentSong.stop();
  }

  setPos(rate) {
    this.currentSong.setPosition(this.currentSong.durationEstimate * rate);
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

        <div className="col-md-8">
          <PlayProgressBar barProgress={this.state.width} setPos={ this.setPos.bind(this) } />
        </div>
        <div className="col-md-2">
          <PlayDuration passTime={ this.state.passTime } totalTime={ this.state.totalTime } />
        </div>

        <div className="col-md-12">
          <PlayQueue play={ (path) => this.playItem(path) } queue={ this.queue }/>
        </div>
      </div>
    );
  }
}

export default CorePlayer;

