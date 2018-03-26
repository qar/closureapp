const jsmediatags = require('jsmediatags');

export default function getCoverFromMP3File(filePath, callback) {
  jsmediatags.read(filePath, {
    onSuccess: tag => {
      const image = tag.tags.picture;
      if (image) {
        let base64String = '';
        for (let i = 0; i < image.data.length; i++) {
            base64String += String.fromCharCode(image.data[i]);
        }
        const base64 = 'data:' + image.format + ';base64,' + window.btoa(base64String);
        callback(base64);
      }
    },

    onError: error => {
      // handle error
      callback('');
    },
  });
};
