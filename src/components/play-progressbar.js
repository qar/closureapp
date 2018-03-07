import React from 'react';

class PlayProgressBar extends React.Component {
  constructor(props) {
    super(props);

    this.progressBar = null;
  }

  setPos(ev) {
    const offsetX = ev.nativeEvent.offsetX;
    const maxWidth = this.progressBar.offsetWidth;
    this.props.setPos(offsetX / maxWidth);
  }

  render() {
    return (
      <div className="progress player-progress" ref={ ele => this.progressBar = ele } onClick={ (e) => this.setPos(e) }>
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

export default PlayProgressBar;

