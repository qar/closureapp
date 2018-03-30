import React from 'react';
import styles from './PlayControl.scss';
import playerStyles from './Player.scss';
import iconStyles from 'styles/icon.scss';

class PlayControl extends React.Component {
  renderPlayBtn(isPlaying) {
    if (isPlaying) {
      // render paused icon
      return (
        <li className={ styles.control_btn } onClick={() => this.props.onPauseBtnClicked()}>
          <span className={ `${iconStyles.icon} ${iconStyles.icon_pause}` }></span>
        </li>
      );
    } else {
      // is paused or simply not playing, render play icon
      return (
        <li className={ styles.control_btn } onClick={() => this.props.onPlayBtnClicked()}>
          <span className={ `${iconStyles.icon} ${iconStyles.icon_play_button}` }></span>
        </li>
      );
    }
  }

  render() {
    return (
      <ul className={ `${styles.player_controls} ${playerStyles.core_ctrl_panel}` }>
        <li className={ styles.control_btn } onClick={() => this.props.onPrevBtnClicked()}><span className={ `${iconStyles.icon} ${iconStyles.icon_previous}` }></span></li>

        {this.renderPlayBtn(this.props.isPlaying)}

        <li className={ styles.control_btn } onClick={() => this.props.onNextBtnClicked()}><span className={ `${iconStyles.icon} ${iconStyles.icon_next}` }></span></li>
      </ul>
    );
  }
}

export default PlayControl;
