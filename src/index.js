import React from 'react';
import './index.css';
import ReactDOM from 'react-dom';
import 'soundmanager2';
const soundManager = window.soundManager;

const fullPath = 'http://freshly-ground.com/data/audio/sm2/Figub%20Brazlevi%C4%8D%20-%20Bosnian%20Syndicate.mp3';

class PlayControl extends React.Component {
  constructor(props) {
    super(props);
  }

  renderPlayBtn(isPlaying) {
    if (isPlaying) {
      // render paused icon
      return (
        <li className="control-btn" onClick={() => this.props.onPauseBtnClicked()}>
          <span className="glyphicon glyphicon-pause"></span>
        </li>
      );
    } else {
      // is paused or simply not playing, render play icon
      return (
        <li className="control-btn" onClick={() => this.props.onPlayBtnClicked()}>
          <span className="glyphicon glyphicon-play"></span>
        </li>
      );
    }
  }

  render() {
    return (
      <ul className="player-controls">
        <li className="control-btn" onClick={() => this.props.onPrevBtnClicked()}><span className="glyphicon glyphicon-step-backward"></span></li>

        {this.renderPlayBtn(this.props.isPlaying)}

        <li className="control-btn" onClick={() => this.props.onNextBtnClicked()}><span className="glyphicon glyphicon-step-forward"></span></li>
        <li className="control-btn" onClick={() => this.props.onStopBtnClicked()}><span className="glyphicon glyphicon-stop"></span></li>
      </ul>
    );
  }
}

class PlayProgressBar extends React.Component {
  constructor(props) {
    super(props);
  }

  render() {
    return (
      <div className="progress player-progress" id="ctrl-progress-wrapper">
        <div className="progress-bar progress-bar-default"
             role="progressbar"
             aria-valuenow="40"
             aria-valuemin="0"
             aria-valuemax="100"
             style={{ width: this.props.barProgress }}>
          <span className="sr-only">40% Complete (success)</span>
        </div>
      </div>
    );
  }
}

class PlayDuration extends React.Component {
  render() {
    return (
      <div className="player-duration text-center">
        <span className="pass-time" id="ctrl-pass-time">{ this.props.passTime || '--:--' }</span> |
        <span className="total-time" id="ctrl-total-time">{ this.props.totalTime || '--:--' }</span>
      </div>
    );
  }
}

class CorePlayer extends React.Component {
  constructor(props) {
    super(props);

    this.state = {
      passTime: 0,
      totalTime: 0,
      isPlaying: false,
    };

    this.playerSetup();
  }

  playerSetup() {
    const globalState = this.state;
    const _this = this;

    soundManager.setup({
      url: '/node_modules/soundmanager2/swf/soundmanager2.swf',
      useHighPerformance: true,
      onready: function() {
        this.mySound = soundManager.createSound({
          id: 'aSound',
          url: fullPath,

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
            var progressMaxLeft = 100,
                left,
                width,
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

            left = Math.min(progressMaxLeft, Math.max(0, (progressMaxLeft * (this.position / this.durationEstimate)))) + '%';
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
              isPlaying: false
            });
          }
        });
      },

      ontimeout: function() {
        // Hrmm, SM2 could not start. Missing SWF? Flash blocked? Show an error, etc.?
      }
    });
  }

  play() {
    if (!this.state.isPlaying && this.state.passTime) {
      // is paused
      soundManager.resume('aSound');
    } else {
      soundManager.play('aSound');
    }
  }

  pause() {
    soundManager.pause('aSound');
  }

  prev() {
    /* TODO */
  }

  next() {
    /* TODO */
  }

  stop() {
    /* TODO */
    soundManager.stop('aSound');
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
          <PlayProgressBar barProgress={this.state.width} />
        </div>
        <div className="col-md-2">
          <PlayDuration passTime={ this.state.passTime } totalTime={ this.state.totalTime } />
        </div>
      </div>
    );
  }
}

// ========================================

ReactDOM.render(
  <CorePlayer />,
  document.getElementById('player')
);
