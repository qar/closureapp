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
      </tr>
    );
  }

  render() {
    return (
      <div className="row table-responsive">
        <table className="table">
          <tbody>
          { this.props.queue.map((obj, i) => this.renderListItem(obj, i)) }
          </tbody>
        </table>
      </div>
    );
  }
}

export default PlayQueue;

