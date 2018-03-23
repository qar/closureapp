import React from 'react';
import styles from './PlayControl.scss';
import playerStyles from './Player.scss';
import iconStyles from '../../src/styles/icon.scss';

class PlayModeControl extends React.Component {
  renderRepeatBtn(isListRepeat) {
    if (isListRepeat) {
      return (
        <li className={ styles.control_btn } onClick={() => this.props.onListRepeatClicked()}>
          <span className={ `${iconStyles.icon} ${iconStyles.icon_repeat}` }></span>
        </li>
      );
    } else {
      // is paused or simply not playing, render play icon
      return (
        <li className={ styles.control_btn }  onClick={() => this.props.onItemRepeatClicked()}>
          <span className={ `${iconStyles.icon} ${iconStyles.icon_musical_note}` }></span>
        </li>
      );
    }
  }

  render() {
    return (
      <ul className={ `${styles.player_controls} ${playerStyles.core_ctrl_panel}` }>
        {this.renderRepeatBtn(this.props.isListRepeat)}
      </ul>
    );
  }
}

export default PlayModeControl;
