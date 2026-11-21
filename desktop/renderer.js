window.bicdopReady.then(api => {
  const tabs = document.querySelector('#tabs');
  const terminalArea = document.querySelector('#terminal');
  const empty = document.querySelector('#empty');
  const emptyMessage = document.querySelector('#empty-message');
  const status = document.querySelector('#status');
  const dimensions = document.querySelector('#dimensions');
  const picker = document.querySelector('#profile');
  const newButton = document.querySelector('#new');
  const sessions = new Map();
  let activeId;

  function report(error) {
    status.textContent = error.message;
  }

  function updateStatus(session) {
    status.textContent = session.state;
    dimensions.textContent = `${session.terminal.cols} × ${session.terminal.rows}`;
  }

  function fitActive() {
    const session = sessions.get(activeId);
    if (!session) return;
    session.fit.fit();
    updateStatus(session);
  }

  function select(id, focus = true) {
    activeId = id;
    const active = sessions.get(id);
    for (const session of sessions.values()) {
      const selected = session === active;
      session.pane.hidden = !selected;
      session.tab.classList.toggle('active', selected);
      session.button.setAttribute('aria-selected', String(selected));
      session.button.tabIndex = selected ? 0 : -1;
    }
    empty.hidden = Boolean(active);
    if (active) {
      active.tab.scrollIntoView({ block: 'nearest', inline: 'nearest' });
      fitActive();
      if (focus) active.terminal.focus();
    } else {
      emptyMessage.textContent = 'Open a terminal with + or Alt+Shift+T.';
      status.textContent = 'No active session';
      dimensions.textContent = '';
    }
  }

  function close(id) {
    const session = sessions.get(id);
    if (!session) return;
    const order = [...sessions.keys()];
    const index = order.indexOf(id);
    sessions.delete(id);
    api.close(id).catch(report);
    session.terminal.dispose();
    session.tab.remove();
    session.pane.remove();
    if (activeId === id) select(order[index + 1] ?? order[index - 1]);
  }

  async function open() {
    if (newButton.disabled || sessions.size >= 24) return;
    const id = crypto.randomUUID();
    const profile = picker.value;
    const label = picker.selectedOptions[0].textContent;
    const tab = document.createElement('div');
    tab.className = 'tab';
    tab.setAttribute('role', 'presentation');

    const button = document.createElement('button');
    button.id = `tab-${id}`;
    button.textContent = label;
    button.setAttribute('role', 'tab');
    button.setAttribute('aria-controls', `pane-${id}`);
    button.onclick = () => select(id);

    const closeButton = document.createElement('button');
    closeButton.className = 'close';
    closeButton.textContent = '×';
    closeButton.setAttribute('aria-label', `Close ${label} terminal`);
    closeButton.onclick = () => close(id);
    tab.append(button, closeButton);
    tabs.append(tab);

    const pane = document.createElement('section');
    pane.id = `pane-${id}`;
    pane.className = 'pane';
    pane.setAttribute('role', 'tabpanel');
    pane.setAttribute('aria-labelledby', button.id);
    terminalArea.append(pane);

    const terminal = new Terminal({
      fontFamily: '"Cascadia Mono", Consolas, "DejaVu Sans Mono", monospace',
      fontSize: 14,
      cursorBlink: true,
      scrollback: 5000,
      theme: { background: '#16151b', foreground: '#eeeaf2', cursor: '#c9a6ff', selectionBackground: '#514267' },
    });
    const fit = new FitAddon.FitAddon();
    terminal.loadAddon(fit);
    terminal.open(pane);
    const session = { terminal, fit, tab, button, pane, state: 'Starting', running: false };
    sessions.set(id, session);
    select(id);

    terminal.onData(data => {
      if (session.running) api.write(id, data).catch(report);
    });
    terminal.onResize(({ cols, rows }) => {
      if (session.running) api.resize(id, cols, rows).catch(report);
      if (activeId === id) updateStatus(session);
    });
    terminal.attachCustomKeyEventHandler(event => {
      if (event.type !== 'keydown' || !event.ctrlKey || !event.shiftKey || event.altKey) return true;
      switch (event.code) {
        case 'KeyC':
          if (terminal.hasSelection()) api.writeClipboard(terminal.getSelection()).catch(report);
          break;
        case 'KeyV':
          api.readClipboard().then(text => {
            if (sessions.has(id)) terminal.paste(text);
          }).catch(report);
          break;
        default:
          return true;
      }
      event.preventDefault();
      return false;
    });

    try {
      session.running = true;
      session.state = label;
      await api.open(id, profile, terminal.cols, terminal.rows);
    } catch (error) {
      session.running = false;
      session.state = 'Failed to start';
      terminal.writeln(error.message);
    }
    if (activeId === id) updateStatus(session);
  }

  api.onEvent(({ id, data, exitCode }) => {
    const session = sessions.get(id);
    if (!session) return;
    if (data !== undefined) {
      session.terminal.write(data);
      return;
    }
    session.running = false;
    session.state = `Exited (${exitCode})`;
    session.terminal.writeln(`\r\n[Process exited with code ${exitCode}]`);
    if (activeId === id) updateStatus(session);
  });

  new ResizeObserver(fitActive).observe(terminalArea);
  newButton.onclick = open;
  picker.onchange = () => api.setDefault(picker.value).catch(report);
  tabs.addEventListener('keydown', event => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key) || event.target.getAttribute('role') !== 'tab') return;
    const ids = [...sessions.keys()];
    const current = ids.indexOf(activeId);
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? ids.length - 1
      : (current + (event.key === 'ArrowRight' ? 1 : -1) + ids.length) % ids.length;
    event.preventDefault();
    select(ids[next], false);
    sessions.get(ids[next]).button.focus();
  });
  document.addEventListener('keydown', event => {
    if (!event.altKey || !event.shiftKey || event.ctrlKey || event.metaKey) return;
    if (event.code === 'KeyT') {
      event.preventDefault();
      open();
    } else if (event.code === 'KeyW') {
      event.preventDefault();
      close(activeId);
    }
  }, true);

  api.profiles().then(({ profiles, defaultProfile }) => {
    if (!profiles.length) {
      emptyMessage.textContent = 'No supported shell was found.';
      status.textContent = 'No shell available';
      return;
    }
    for (const profile of profiles) picker.add(new Option(profile.label, profile.id));
    picker.value = defaultProfile;
    picker.disabled = false;
    newButton.disabled = false;
    open();
  }).catch(error => {
    emptyMessage.textContent = 'Unable to initialize the terminal.';
    report(error);
  });
});
