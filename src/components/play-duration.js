import React from 'react';

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

export default PlayDuration;
