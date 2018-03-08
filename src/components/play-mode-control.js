import React from 'react';

class PlayModeControl extends React.Component {
  renderRepeatBtn(isListRepeat) {
    if (isListRepeat) {
      return (
        <li className="control-btn" onClick={() => this.props.onListRepeatClicked()}>
          <span className="glyphicon glyphicon-retweet"></span>
        </li>
      );
    } else {
      // is paused or simply not playing, render play icon
      return (
        <li className="control-btn" onClick={() => this.props.onItemRepeatClicked()}>
          <span className="glyphicon glyphicon-repeat"></span>
        </li>
      );
    }
  }

  render() {
    return (
      <ul className="player-controls">
        {this.renderRepeatBtn(this.props.isListRepeat)}
      </ul>
    );
  }
}

export default PlayModeControl;
