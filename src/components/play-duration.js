import React from 'react';

class PlayDuration extends React.Component {
  constructor(props) {
    super(props);
  }

  render() {
    return (
      <div className="core-control-panel player-duration text-center">
        <span className="pass-time" id="ctrl-pass-time">{ this.props.passTime || '00:00' }</span>&#47;
        <span className="total-time" id="ctrl-total-time">{ this.props.totalTime || '00:00' }</span>
      </div>
    );
  }
}

export default PlayDuration;
