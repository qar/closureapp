import React from 'react';
import playerStyles from './Player.scss';


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
      <div className={ `${playerStyles.progress_bar_container} ${playerStyles.core_ctrl_panel}` }>
        <div className={ `${playerStyles.progress } ${playerStyles.player_progress}` } ref={ ele => this.progressBar = ele } onClick={ (e) => this.setPos(e) }>
          <div className={ playerStyles.progress_bar } role="progressbar" style={{ width: this.props.barProgress }}> </div>
        </div>
      </div>
    );
  }
}

export default PlayProgressBar;

