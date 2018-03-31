import React from 'react';
import styles from 'components/App/GenresMenu.scss';
import { remote } from 'electron';
import path from 'path';
const soundsDb = remote.getGlobal('soundsDb');

class GenresMenu extends React.Component {
  constructor(props) {
    super(props);
  }

  render() {
    return (
      <div className={ styles.container }>
        <div className={ styles.header }>GENRES</div>

        <ul className={ styles.genres_list }>
          <li>Pop</li>
          <li className={ styles.active }>Blues</li>
        </ul>
      </div>
    );
  }
}

export default GenresMenu;
