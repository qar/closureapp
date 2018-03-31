import React from 'react';
import styles from './PlayQueue.scss';
import defaultCover from 'assets/default-cover.png';

class PlayQueue extends React.Component {
  constructor(props) {
    super(props);
  }

  renderListItem(obj, i) {
    const itemClass = `${(obj.path === this.props.currentSound ? styles.active : '')} ${styles.row}`;
    return (
      <ul className={ itemClass } onDoubleClick={ () => this.props.play(obj.path) } key={ i }>
        <li className={ styles.media_cover }><img src={ obj.cover || defaultCover } /></li>
        <li className={ styles.media_detail }>
          <span>{obj.title } </span>
          <span>{obj.artist} / {obj.album}</span>
        </li>
      </ul>
    );
  }

  render() {
    return (
      <div className={ styles.queue }>
        { this.props.queue.map((obj, i) => this.renderListItem(obj, i)) }
      </div>
    );
  }
}

export default PlayQueue;

