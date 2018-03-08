import React from 'react';

class PlayQueue extends React.Component {
  constructor(props) {
    super(props);

    this.playList = props.queue;
  }

  renderListItem(obj, i) {
    return (
      <li className={ "list-group-item " + (obj.path === this.props.currentSound ? "active" : "") }
          onClick={ () => this.props.play(obj.path) }
          key={ i }>
        {obj.name}
      </li>
    );
  }

  render() {
    return (
      <ul className="list-group">
        { this.playList.map((obj, i) => this.renderListItem(obj, i)) }
      </ul>
    );
  }
}

export default PlayQueue;

