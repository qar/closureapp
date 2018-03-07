import React from 'react';

class PlayControl extends React.Component {
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

export default PlayControl;
