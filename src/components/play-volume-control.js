import React from 'react';

class PlayVolumeControl extends React.Component {
  constructor(props) {
    super(props);

    this.progressBar = null;
  }

  setPos(ev) {
    const offsetX = ev.nativeEvent.offsetX;
    const maxWidth = this.progressBar.offsetWidth;
    this.props.setVolume(offsetX / maxWidth * 100);
  }

  render() {
    return (
      <div className="progress-bar-container core-control-panel">
        <span className="glyphicon glyphicon-volume-up"></span> &nbsp;&nbsp;
        <div className="progress player-progress" ref={ ele => this.progressBar = ele } onClick={ (e) => this.setPos(e) }>
          <div className="progress-bar progress-bar-default"
               role="progressbar"
               style={{ width: this.props.volume + '%' }}>
          </div>
        </div>
      </div>
    );
  }
}

export default PlayVolumeControl;

