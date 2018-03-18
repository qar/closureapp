import React from 'react';

class PlayModeControl extends React.Component {
  renderRepeatBtn(isListRepeat) {
    if (isListRepeat) {
      return (
        <li className="control-btn" onClick={() => this.props.onListRepeatClicked()}>
          <span className="icon-repeat"></span>
        </li>
      );
    } else {
      // is paused or simply not playing, render play icon
      return (
        <li className="control-btn" onClick={() => this.props.onItemRepeatClicked()}>
          <span className="icon-musical-note"></span>
        </li>
      );
    }
  }

  render() {
    return (
      <ul className="player-controls core-control-panel">
        {this.renderRepeatBtn(this.props.isListRepeat)}
      </ul>
    );
  }
}

export default PlayModeControl;
