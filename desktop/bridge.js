window.bicdopReady = new Promise(resolve => {
  new QWebChannel(qt.webChannelTransport, channel => {
    const terminal = channel.objects.terminal;
    const invoke = (action, ...args) => new Promise((resolveRequest, reject) => {
      terminal.request(action, args, response => {
        if (response.error) reject(new Error(response.error));
        else resolveRequest(response.value);
      });
    });
    resolve({
      profiles: () => invoke('profiles'),
      setDefault: id => invoke('setDefault', id),
      open: (...args) => invoke('open', ...args),
      write: (id, data) => invoke('write', id, data),
      resize: (id, cols, rows) => invoke('resize', id, cols, rows),
      close: id => invoke('close', id),
      readClipboard: () => invoke('readClipboard'),
      writeClipboard: text => invoke('writeClipboard', text),
      onEvent: callback => terminal.event.connect(callback),
    });
  });
});
