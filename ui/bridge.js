// =====================================================================
// Whispers - what both pages share: the message bridge to Whispers.ahk,
// the theme, and a few helpers.
//
// The pages decide nothing about settings. They send what the user did
// ({op: ...}, see lib\Web.ahk for the full list) and show what comes
// back ({ev: ...}): a value the page sent may come back clamped, and the
// page then shows the value actually kept.
// =====================================================================
'use strict';

(function () {
  const wv = window.chrome && window.chrome.webview;
  const handlers = {};
  const root = document.documentElement;

  const ws = {
    send(op, fields) {
      const msg = Object.assign({ op: op }, fields || {});
      if (wv) wv.postMessage(msg);
    },
    on(ev, fn) {
      (handlers[ev] = handlers[ev] || []).push(fn);
    },
    receive(msg) {
      if (!msg || typeof msg.ev !== 'string') return;
      if (msg.ev === 'theme') applyTheme(msg);
      if (msg.ev === 'state' && msg.theme) applyTheme(msg.theme);
      (handlers[msg.ev] || []).forEach(function (fn) { fn(msg); });
    },
    toast: toast,
    esc: esc,
    fmtBytes: fmtBytes,
    keyLabel: keyLabel,
    captureKey: captureKey
  };
  window.ws = ws;

  if (wv) wv.addEventListener('message', function (e) { ws.receive(e.data); });

  function applyTheme(t) {
    root.dataset.theme = t.dark ? 'dark' : 'light';
    root.classList.toggle('mica', !!t.mica);
    root.style.setProperty('--accent', t.accent);
    root.style.setProperty('--on-accent', t.onAccent);
    document.body.classList.add('ready');
  }

  // Without WebView2 (the page opened in a browser while working on it)
  // there is nothing to wait for.
  document.addEventListener('DOMContentLoaded', function () {
    if (!root.dataset.theme) root.dataset.theme = 'dark';
    if (!wv) document.body.classList.add('ready');
    ws.send('hello', { page: document.body.dataset.page });
  });

  // An application window, not a browser: no dropped files opening in
  // place of the page, no text selection outside the fields.
  ['dragover', 'drop'].forEach(function (t) {
    window.addEventListener(t, function (e) { e.preventDefault(); });
  });

  let toastTimer = 0;
  function toast(text) {
    let el = document.getElementById('toast');
    if (!el) {
      el = document.createElement('div');
      el.id = 'toast';
      el.setAttribute('role', 'status');
      document.body.appendChild(el);
    }
    el.textContent = text;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.classList.remove('show'); }, 2600);
  }
  ws.on('notice', function (m) { toast(m.text); });

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function fmtBytes(b) {
    if (!b) return '';
    if (b >= 1e9) return (b / 1e9).toFixed(1) + ' GB';
    return Math.round(b / 1e6) + ' MB';
  }

  // AutoHotkey key syntax -> what the keycap shows: ^+Space -> Ctrl + Shift + Space
  function keyLabel(k) {
    if (!k) return '';
    const mods = { '^': 'Ctrl', '!': 'Alt', '+': 'Shift', '#': 'Win' };
    const parts = [];
    let i = 0;
    while (i < k.length - 1 && '^!+#<>'.indexOf(k[i]) >= 0) {
      if (mods[k[i]]) parts.push(mods[k[i]]);
      i++;
    }
    let key = k.slice(i);
    const names = { RCtrl: 'Right Ctrl', LCtrl: 'Left Ctrl', RAlt: 'Right Alt', LAlt: 'Left Alt',
      RShift: 'Right Shift', LShift: 'Left Shift', RWin: 'Right Win', LWin: 'Left Win',
      XButton1: 'Mouse back', XButton2: 'Mouse forward', MButton: 'Middle click',
      AppsKey: 'Menu', PgUp: 'Page Up', PgDn: 'Page Down' };
    if (names[key]) key = names[key];
    else if (/^vk[0-9A-F]{2}$/i.test(key)) key = 'Key ' + key.slice(2).toUpperCase();
    else if (key.length === 1) key = key.toUpperCase();
    parts.push(key);
    return parts.join(' + ');
  }

  // Records one key or combination as AutoHotkey writes it. Windows
  // virtual-key codes, not characters: the key that types "a" is vk41 on
  // AZERTY and QWERTY alike, and so is AutoHotkey's "a".
  // done(key) gets "" when cancelled with Escape; error(text) a refusal.
  function captureKey(done, error) {
    const special = { 8: 'Backspace', 9: 'Tab', 13: 'Enter', 19: 'Pause', 20: 'CapsLock', 32: 'Space',
      33: 'PgUp', 34: 'PgDn', 35: 'End', 36: 'Home', 37: 'Left', 38: 'Up', 39: 'Right', 40: 'Down',
      44: 'PrintScreen', 45: 'Insert', 46: 'Delete', 93: 'AppsKey', 106: 'NumpadMult', 107: 'NumpadAdd',
      109: 'NumpadSub', 110: 'NumpadDot', 111: 'NumpadDiv', 145: 'ScrollLock' };
    const typing = /^([a-z0-9]|Space|Enter|Tab|Backspace|vk[0-9A-F]{2})$/;
    let lastMod = '';

    function name(e) {
      const c = e.keyCode;
      if (c >= 65 && c <= 90) return String.fromCharCode(c).toLowerCase();
      if (c >= 48 && c <= 57) return String.fromCharCode(c);
      if (c >= 112 && c <= 135) return 'F' + (c - 111);
      if (c >= 96 && c <= 105) return 'Numpad' + (c - 96);
      if (special[c]) return special[c];
      if (c > 0 && c < 256) return 'vk' + ('0' + c.toString(16).toUpperCase()).slice(-2);
      return '';
    }
    function modName(e) {
      const side = e.location === 2 ? 'R' : 'L';
      return { 16: side + 'Shift', 17: side + 'Ctrl', 18: side + 'Alt', 91: 'LWin', 92: 'RWin' }[e.keyCode] || '';
    }
    function finish(key) {
      window.removeEventListener('keydown', down, true);
      window.removeEventListener('keyup', up, true);
      window.removeEventListener('mousedown', mouse, true);
      done(key);
    }
    function down(e) {
      e.preventDefault();
      e.stopPropagation();
      if (e.repeat) return;
      if (e.keyCode === 27 && !e.ctrlKey && !e.altKey && !e.shiftKey) return finish('');
      const m = modName(e);
      if (m) { lastMod = m; return; }
      lastMod = '';
      const k = name(e);
      if (!k) return;
      const prefix = (e.ctrlKey ? '^' : '') + (e.altKey ? '!' : '') + (e.shiftKey ? '+' : '') + (e.metaKey ? '#' : '');
      if (!prefix && typing.test(k)) {
        error('That key types text. Hold Ctrl, Alt or Shift with it, or pick a key such as F9.');
        return;
      }
      finish(prefix + k);
    }
    // A modifier pressed and released alone: Right Ctrl makes a good
    // dictation key on its own.
    function up(e) {
      e.preventDefault();
      const m = modName(e);
      if (m && m === lastMod) finish(m);
      lastMod = '';
    }
    function mouse(e) {
      const b = { 1: 'MButton', 3: 'XButton1', 4: 'XButton2' }[e.button];
      if (!b) return;
      e.preventDefault();
      finish(b);
    }
    window.addEventListener('keydown', down, true);
    window.addEventListener('keyup', up, true);
    window.addEventListener('mousedown', mouse, true);
    return function cancel() { finish(''); };
  }
})();
