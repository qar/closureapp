import React from 'react';

class PlayQueue extends React.Component {
  constructor(props) {
    super(props);
  }

  renderListItem(obj, i) {
    return (
      <tr className={ (obj.path === this.props.currentSound ? "success" : "") }
          onDoubleClick={ () => this.props.play(obj.path) }
          key={ i }>
        <td> {obj.title} </td>
        <td> {obj.artist} </td>
        <td> {obj.album} </td>
        <td> {obj.playCount || 0} </td>
      </tr>
    );
  }

  render() {
    return (
      <div className="row table-responsive">
        <table className="table">
          <thead>
            <tr>
              <th>Title</th>
              <th>Artist</th>
              <th>Album</th>
              <th>Plays</th>
            </tr>
          </thead>
          <tbody>
          { this.props.queue.map((obj, i) => this.renderListItem(obj, i)) }
          </tbody>
        </table>
      </div>
    );
  }
}

export default PlayQueue;

