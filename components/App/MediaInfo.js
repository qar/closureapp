import React from 'react';
import styles from 'components/App/MediaInfo.scss';
import { remote } from 'electron';
import path from 'path';
const soundsDb = remote.getGlobal('soundsDb');

class MediaInfo extends React.Component {
  constructor(props) {
    super(props);

    this.state = { media: {}, id: this.props.media };
  }

  componentWillReceiveProps(nextProps) {
    if (!nextProps.media || this.state.id === nextProps.media) return;

    soundsDb.findOne({ _id: nextProps.media }, (err, sound) => {
      if (err) {
        // handle error
        return
      }

      if (!sound) return;

      this.setState({ media: sound, id: nextProps.media });
    });

  }

  render() {
    return (
      <div className={ styles.container }>
        <ul className={ styles.media_info }>
            <li className={ styles.media_name }>{ this.state.media.artist }</li>
            <li className={ styles.artist }>{ this.state.media.artist } / { this.state.media.album }</li>
        </ul>
      </div>
    );
  }
}

export default MediaInfo;
