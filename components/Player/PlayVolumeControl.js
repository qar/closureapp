import React from 'react';
import playerStyles from './Player.scss';
import iconStyles from 'styles/icon.scss';

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
      <div className={ `${playerStyles.progress_bar_container} ${playerStyles.core_ctrl_panel}` }>
        <span className={ `${iconStyles.icon} ${iconStyles.icon_volume}` }></span> &nbsp;&nbsp;
        <div className={ `${playerStyles.progress} ${playerStyles.player_progress}` } ref={ ele => this.progressBar = ele } onClick={ (e) => this.setPos(e) }>
          <div className={ playerStyles.progress_bar }
               role="progressbar"
               style={{ width: this.props.volume + '%' }}>
          </div>
        </div>
      </div>
    );
  }
}

export default PlayVolumeControl;
