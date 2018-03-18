import React from 'react';

class PlayControl extends React.Component {
  renderPlayBtn(isPlaying) {
    if (isPlaying) {
      // render paused icon
      return (
        <li className="control-btn" onClick={() => this.props.onPauseBtnClicked()}>
          <span className="icon-pause"></span>
        </li>
      );
    } else {
      // is paused or simply not playing, render play icon
      return (
        <li className="control-btn" onClick={() => this.props.onPlayBtnClicked()}>
          <span className="icon-play-button"></span>
        </li>
      );
    }
  }

  render() {
    return (
      <ul className="player-controls core-control-panel">
        <li className="control-btn" onClick={() => this.props.onPrevBtnClicked()}><span className="icon-previous"></span></li>

        {this.renderPlayBtn(this.props.isPlaying)}

        <li className="control-btn" onClick={() => this.props.onNextBtnClicked()}><span className="icon-next"></span></li>
        <li className="control-btn" onClick={() => this.props.onStopBtnClicked()}><span className="icon-stop"></span></li>
      </ul>
    );
  }
}

export default PlayControl;
