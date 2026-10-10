// =====================================================================
// Whispers - the settings window.
//
// Every change is sent as it is made and applies at once; there is no
// Save button. The one exception is the tier, which downloads a model
// and so asks first, with its size.
// =====================================================================
'use strict';

(function () {
  const esc = ws.esc;
  const S = {
    page: 'general', config: {}, mics: [], tiers: [], recommended: '', status: {}, history: [], log: [],
    app: {}, levels: {}, capturing: null, keyError: '', pendingTier: '', download: null, search: '', micMenu: false
  };

  const ICONS = {
    general: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z',
    engine: 'M9 3v2M15 3v2M9 19v2M15 19v2M3 9h2M3 15h2M19 9h2M19 15h2M7 5h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2zM9 9h6v6H9z',
    history: 'M3 12a9 9 0 1 0 3-6.7L3 8M3 3v5h5M12 7v5l3 2',
    log: 'M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9zM14 3v6h6M8 13h8M8 17h5',
    about: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 16v-4M12 8h.01',
    mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0"/><path d="M12 18v3"/>',
    key: '<rect x="3" y="6" width="18" height="12" rx="2"/><path d="M7 10h.01M11 10h.01M15 10h.01M7 14h10"/>',
    globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 3 2.5 15 0 18M12 3c-2.5 3-2.5 15 0 18"/>',
    copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>',
    chevron: '<path d="M6 9l6 6 6-6"/>'
  };
  const NAV = [['general', 'General'], ['engine', 'Engine'], ['history', 'History'], ['log', 'Diagnostics'], ['about', 'About']];
  const TIER_TEXT = {
    fast: ['Fast', 'Smallest model. Runs on a modest GPU.'],
    balanced: ['Balanced', 'The best trade-off for most GPUs.'],
    max: ['Maximum accuracy', 'Largest model, fewest mistakes.'],
    cpu: ['CPU only', 'No NVIDIA GPU needed. Slower.']
  };
  const IDLE = [[5, '5 min'], [15, '15 min'], [60, '1 hour'], [480, '8 hours'], [1440, '1 day']];

  const $content = document.getElementById('content');

  // --- incoming --------------------------------------------------------
  ws.on('state', function (m) {
    Object.assign(S, { config: m.config, mics: m.mics, tiers: m.tiers, recommended: m.recommended,
      status: m.status, history: m.history.items, log: m.log.lines, app: m.app });
    renderNav();
    render();
    syncMeter();
  });
  ws.on('config', function (m) {
    S.config[m.key] = m.value;
    if (m.key === 'Tier') S.pendingTier = '';
    render();
    if (m.key === 'Mic') syncMeter();
  });
  ws.on('tiers', function (m) { S.tiers = m.tiers; render(); });
  ws.on('status', function (m) { S.status = m; render(); });
  ws.on('app', function (m) { S.app = m; render(); });
  ws.on('history', function (m) { S.history = m.items; if (S.page === 'history') renderHistoryList(); });
  ws.on('log', function (m) { S.log = m.lines; if (S.page === 'log') render(); });
  ws.on('logline', function (m) {
    S.log.push(m.line);
    if (S.log.length > 200) S.log.shift();
    const box = S.page === 'log' && document.querySelector('.log');
    if (!box) return;
    const atEnd = box.scrollTop + box.clientHeight >= box.scrollHeight - 4;
    box.textContent = S.log.join('\n');
    if (atEnd) box.scrollTop = box.scrollHeight;
  });
  ws.on('nav', function (m) { go(m.page); });
  ws.on('hotkey', function (m) {
    S.keyError = m.ok ? '' : m.error;
    if (m.ok) ws.toast('Dictation key: ' + ws.keyLabel(m.value));
    render();
  });
  ws.on('download', function (m) {
    if (m.phase === 'done' || m.phase === 'failed') {
      S.download = null;
      if (m.phase === 'failed') S.pendingTier = '';
    } else {
      S.download = Object.assign(S.download || {}, m.phase === 'info' ? { info: m.label } : m);
    }
    render();
  });
  ws.on('level', function (m) {
    S.levels = m.levels;
    const el = document.querySelector('[data-meter] > i');
    const v = m.levels[S.config.Mic];
    if (el) el.style.width = Math.round((v || 0) * 100) + '%';
  });

  // --- the microphone meter runs only while General is on screen --------
  function syncMeter() {
    const on = S.page === 'general' && document.visibilityState === 'visible';
    ws.send('meter', { on: on, all: false });
  }
  document.addEventListener('visibilitychange', syncMeter);

  // --- outgoing ----------------------------------------------------------
  function set(key, value) {
    S.config[key] = String(value);
    ws.send('set', { key: key, value: String(value) });
    render();
  }

  function go(page) {
    if (!NAV.some(function (n) { return n[0] === page; })) return;
    if (S.capturing) S.capturing();
    S.page = page;
    S.micMenu = false;
    renderNav();
    render();
    $content.scrollTop = 0;
    syncMeter();
    if (page === 'engine' || page === 'log' || page === 'history') ws.send('refresh');
  }

  // --- rendering -------------------------------------------------------
  function svg(inner, cls) {
    const body = inner.charAt(0) === '<' ? inner : '<path d="' + inner + '"/>';
    return '<svg aria-hidden="true" class="' + (cls || 'icon') + '" viewBox="0 0 24 24">' + body + '</svg>';
  }
  function sw(key, on, label) {
    return '<button class="switch" role="switch" aria-checked="' + (on ? 'true' : 'false') + '" aria-label="' + esc(label) +
      '" data-act="toggle" data-key="' + key + '"></button>';
  }
  function toggleRow(key, title, desc) {
    const on = String(S.config[key]) === '1';
    return '<div class="card"><div class="lines"><div class="title">' + esc(title) + '</div><div class="muted">' + esc(desc) +
      '</div></div><div class="switch-wrap"><span class="sub">' + (on ? 'On' : 'Off') + '</span>' + sw(key, on, title) + '</div></div>';
  }
  function seg(key, options, label) {
    return '<div class="seg" role="group" aria-label="' + esc(label) + '">' + options.map(function (o) {
      return '<button aria-pressed="' + (String(S.config[key]) === o[0]) + '" data-act="set" data-key="' + key + '" data-value="' +
        o[0] + '">' + esc(o[1]) + '</button>';
    }).join('') + '</div>';
  }

  function renderNav() {
    document.getElementById('nav').innerHTML = NAV.map(function (n) {
      return '<button class="nav-item" data-act="go" data-page="' + n[0] + '"' + (S.page === n[0] ? ' aria-current="page"' : '') +
        '>' + svg(ICONS[n[0]], '') + esc(n[1]) + '</button>';
    }).join('');
    document.getElementById('brand-sub').textContent = S.config.Hotkey ? 'Hold ' + ws.keyLabel(S.config.Hotkey) + ' to dictate' : '';
  }

  let lastPage = '';
  function render() {
    const fn = { general: general, engine: engine, history: history, log: diagnostics, about: about }[S.page];
    const keepScroll = $content.scrollTop;
    // A field being typed in survives a redraw caused by something else.
    const a = document.activeElement;
    const field = a && a.dataset && a.dataset.field ? [a.dataset.field, a.value, a.selectionStart, a.selectionEnd] : null;
    // Only a new section slides in; a redraw of the same one must not
    // replay the animation (a download redraws it several times a second).
    const enter = S.page !== lastPage ? ' class="enter"' : '';
    lastPage = S.page;
    $content.innerHTML = '<section' + enter + ' aria-label="' + esc(S.page) + '">' + fn() + '</section>';
    $content.scrollTop = keepScroll;
    if (field) {
      const f = $content.querySelector('[data-field="' + field[0] + '"]');
      if (f) { f.value = field[1]; f.focus(); try { f.setSelectionRange(field[2], field[3]); } catch (e) { /* search fields */ } }
    }
    if (S.page === 'history') renderHistoryList();
    if (S.page === 'log') { const l = document.querySelector('.log'); if (l) l.scrollTop = l.scrollHeight; }
    renderNav();
  }

  function general() {
    const c = S.config;
    const mic = c.Mic || '';
    let micMenu = '';
    if (S.micMenu) {
      micMenu = '<div class="menu" role="listbox" aria-label="Microphones">' + S.mics.map(function (d) {
        return '<button role="option" aria-selected="' + (d === mic) + '" data-act="mic" data-value="' + esc(d) + '">' + esc(d) + '</button>';
      }).join('') + '</div>';
    }
    let key;
    if (S.capturing) {
      key = '<div class="keycap listening">Press a key...</div><button class="btn" data-act="cancelKey">Cancel</button>';
    } else {
      key = '<div class="keycap">' + esc(ws.keyLabel(c.Hotkey)) + '</div><button class="btn" data-act="changeKey">Change</button>';
    }
    const keyDesc = S.capturing ? 'Press the key or combination to use - Esc cancels'
      : (S.keyError || 'Hold to record, release to transcribe');
    return '<h1>General</h1>' +
      '<h2>Voice</h2><div class="group">' +
        '<div class="card">' + svg(ICONS.mic) + '<div class="lines" style="gap:8px"><div><div class="title">Microphone</div>' +
          '<div class="muted">Speak to see the level move</div></div><div class="meter" data-meter style="width:260px;max-width:100%"><i></i></div></div>' +
          '<div class="picker"><button class="btn" data-act="micMenu" aria-haspopup="listbox" aria-expanded="' + S.micMenu + '"><span>' +
          esc(mic || 'No microphone selected') + '</span>' + svg(ICONS.chevron, '') + '</button>' + micMenu + '</div></div>' +
        '<div class="card row-indent" style="padding-top:12px;padding-bottom:12px"><div class="grow sub">Not sure which one? Whispers can listen to all of them and pick the one that hears you.</div>' +
          '<button class="btn" data-act="detect">Detect best microphone</button></div>' +
        '<div class="card">' + svg(ICONS.key) + '<div class="lines"><div class="title">Dictation key</div><div class="muted"' +
          (S.keyError && !S.capturing ? ' style="color:var(--bad-text)"' : '') + '>' + esc(keyDesc) + '</div></div>' + key + '</div>' +
        '<div class="card">' + svg(ICONS.globe) + '<div class="lines"><div class="title">Language you speak</div>' +
          '<div class="muted">Detecting is slower and can mix languages</div></div>' +
          seg('Language', [['fr', 'French'], ['en', 'English'], ['auto', 'Detect']], 'Language') + '</div>' +
      '</div>' +
      '<h2>Behaviour</h2><div class="group">' +
        toggleRow('AutoPaste', 'Paste automatically', 'Types the text where your cursor is. Off: it only goes to the clipboard.') +
        toggleRow('ShowIndicator', 'Show the floating indicator', 'The glass pill above the taskbar while you speak') +
        toggleRow('PlaySounds', 'Sounds', 'A soft tick when recording starts and stops') +
        toggleRow('TrimSilence', 'Trim silence', 'Cuts quiet starts and ends. Reduces invented words.') +
      '</div>';
  }

  function tierById(id) {
    return S.tiers.filter(function (t) { return t.id === id; })[0];
  }
  function vramText(t) {
    return t.gpu ? (t.vram / 1000).toFixed(1) + ' GB VRAM' : 'no GPU';
  }

  function engine() {
    const st = S.status, c = S.config;
    const cur = tierById(c.Tier) || {};
    const where = st.gpu ? st.gpu + (st.cuda ? ' - CUDA ' + st.cuda : '') : 'No NVIDIA GPU - runs on the CPU';
    let led = '', title = '', sub = '', btn = '';
    if (!st.modelInstalled) {
      led = 'warn'; title = 'The model is not installed'; sub = 'Pick a tier below to download it';
    } else if (st.policy === 'never') {
      title = 'The engine starts for each dictation'; sub = where + ' - ' + st.model;
    } else if (st.loaded) {
      led = 'on'; title = 'Ready - the model is loaded'; sub = where + ' - ' + st.model + (st.gpu ? ' in video memory' : ' in memory');
      btn = '<button class="btn" data-act="server" data-on="0">Unload now</button>';
    } else {
      title = 'The model loads on your first dictation'; sub = where + ' - ' + st.model;
      btn = '<button class="btn" data-act="server" data-on="1">Load now</button>';
    }
    const status = '<div class="card status" style="margin-bottom:20px"><span class="led ' + led + '"></span><div class="lines"><div class="title" style="font-weight:600">' +
      esc(title) + '</div><div class="muted">' + esc(sub) + '</div></div>' + btn + '</div>';

    const tiers = '<div class="tiers" role="radiogroup" aria-label="Accuracy">' + S.tiers.map(function (t) {
      const txt = TIER_TEXT[t.id] || [t.id, ''];
      const blocked = t.gpu && !st.gpu;
      let tag = '';
      if (t.installed && t.id === c.Tier) tag = '<span class="tag ok">In use</span>';
      else if (t.installed) tag = '<span class="tag ok">Installed</span>';
      else if (blocked) tag = '<span class="tag">Needs an NVIDIA GPU</span>';
      else if (t.id === S.recommended) tag = '<span class="tag">Recommended</span>';
      else if (t.id === 'cpu') tag = '<span class="tag">Any PC</span>';
      return '<button class="tier" role="radio" aria-checked="' + (t.id === (S.pendingTier || c.Tier)) + '" data-act="tier" data-value="' + t.id + '"' +
        (blocked || S.download ? ' disabled' : '') + '><span class="head"><span class="name">' + esc(txt[0]) + '</span>' + tag + '</span>' +
        '<span class="desc">' + esc(txt[1]) + '</span><span class="muted">' + esc(t.model) + ' - ' + ws.fmtBytes(t.bytes) + ' - ' + vramText(t) + '</span></button>';
    }).join('') + '</div>';

    let confirm = '';
    const p = tierById(S.pendingTier);
    if (S.download) {
      const d = S.download;
      const pct = d.total ? Math.min(100, Math.round(d.got / d.total * 100)) : 0;
      const info = d.info || (d.total ? Math.round(d.got / 1048576) + ' of ' + Math.round(d.total / 1048576) + ' MB' : 'Starting...');
      confirm = '<div class="card confirm"><div class="title">Downloading ' + esc(d.label || 'the model') + '</div>' +
        '<div class="progress' + (d.total ? '' : ' busy') + '"><i style="width:' + pct + '%"></i></div>' +
        '<div class="actions"><span class="muted grow">' + esc(info) + ' - dictation keeps working meanwhile</span>' +
        '<button class="btn" data-act="cancelDownload">Cancel download</button></div></div>';
    } else if (p && p.id !== c.Tier) {
      const name = (TIER_TEXT[p.id] || [p.id])[0];
      const what = p.installed
        ? p.model + ' is already on this PC.'
        : 'This downloads ' + p.model + ' (' + ws.fmtBytes(p.bytes) + '), then removes ' + (cur.model || 'the current model') + '. Until then, dictation keeps using the current model.';
      confirm = '<div class="card confirm"><div><div class="title" style="font-weight:600">Switch to ' + esc(name) + '?</div>' +
        '<div class="sub" style="margin-top:4px">' + esc(what) + '</div></div><div class="actions">' +
        '<button class="btn" data-act="tierCancel">Cancel</button><button class="btn primary" data-act="tierGo" data-value="' + p.id + '">' +
        (p.installed ? 'Switch' : 'Download and switch') + '</button></div></div>';
    }

    const vramGb = cur.vram ? (cur.vram / 1000).toFixed(1) + ' GB' : 'some';
    const pols = [
      ['idle', 'Load on demand', 'Frees the GPU when you stop dictating. The first dictation after a pause waits a few seconds.', 'Default'],
      ['resident', 'Always ready', 'Every dictation is instant. Keeps ' + vramGb + ' of video memory busy.', 'Fastest'],
      ['never', 'Never keep it loaded', 'Starts the engine for each dictation. No memory held, much slower.', '']
    ];
    let idle = '';
    if (c.VramPolicy === 'idle') {
      const opts = IDLE.slice();
      const v = parseInt(c.IdleMinutes, 10);
      if (!opts.some(function (o) { return o[0] === v; })) opts.push([v, v + ' min']);
      idle = '<div class="card row-indent" style="padding-top:12px;padding-bottom:14px"><span class="sub grow">Free the GPU after</span><div class="chips" role="group" aria-label="Unload delay">' +
        opts.map(function (o) {
          return '<button class="chip" aria-pressed="' + (o[0] === v) + '" data-act="set" data-key="IdleMinutes" data-value="' + o[0] + '">' + esc(o[1]) + '</button>';
        }).join('') + '</div></div>';
    }
    const policies = '<div class="group" role="radiogroup" aria-label="Keep the model in video memory">' + pols.map(function (p) {
      return '<button class="card policy" role="radio" aria-checked="' + (c.VramPolicy === p[0]) + '" data-act="set" data-key="VramPolicy" data-value="' + p[0] + '">' +
        '<span class="dot"></span><span class="lines"><span class="title">' + esc(p[1]) + '</span><span class="muted">' + esc(p[2]) + '</span></span>' +
        (p[3] ? '<span class="muted">' + p[3] + '</span>' : '') + '</button>';
    }).join('') + idle + '</div>';

    const fallback = String(c.CpuFallback) === '1';
    const advanced = '<div class="card advanced">' +
      '<label class="field">Server port<input class="input" data-field="Port" inputmode="numeric" value="' + esc(c.Port) + '"></label>' +
      '<label class="field">Load timeout (seconds)<input class="input" data-field="LoadTimeout" inputmode="numeric" value="' + esc(c.LoadTimeout) + '"></label>' +
      '<div class="field">Fall back to the CPU when the GPU runs out of memory<div class="switch-wrap" style="height:32px"><span class="sub" style="color:var(--text)">' +
      (fallback ? 'On' : 'Off') + '</span>' + sw('CpuFallback', fallback, 'Fall back to the CPU') + '</div></div></div>';

    return '<h1>Engine</h1>' + status + '<h2>Accuracy</h2>' + tiers + confirm +
      '<h2>Keep the model in video memory</h2>' + policies + '<h2>Advanced</h2>' + advanced;
  }

  function history() {
    return '<div class="head-row"><h1>History</h1><label style="font-size:0">Search history<input class="input" data-field="search" type="search" ' +
      'placeholder="Search what you said" style="width:280px" value="' + esc(S.search) + '"></label></div><div id="history-list"></div>';
  }
  function renderHistoryList() {
    const box = document.getElementById('history-list');
    if (!box) return;
    const q = S.search.trim().toLowerCase();
    const rows = S.history.map(function (h, i) { return [h, i + 1]; }).filter(function (r) {
      return !q || r[0].text.toLowerCase().indexOf(q) >= 0;
    });
    if (!rows.length) {
      box.innerHTML = '<div class="empty">' + (S.history.length ? 'Nothing you said matches.' : 'What you dictate appears here - the last 20.') + '</div>';
      return;
    }
    box.innerHTML = rows.map(function (r) {
      return '<div class="card history-item"><div class="time">' + esc(when(r[0].time)) + '</div><div class="text">' + esc(r[0].text) +
        '</div><button class="btn icon-btn" aria-label="Copy to the clipboard" title="Copy" data-act="copy" data-index="' + r[1] + '">' +
        svg(ICONS.copy, '') + '</button></div>';
    }).join('');
  }
  // "2026-10-10 14:32:05" -> "Today 14:32" / "Yesterday 09:10" / "8 Oct 14:32"
  function when(t) {
    const m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})/.exec(t || '');
    if (!m) return t || '';
    const d = new Date(+m[1], +m[2] - 1, +m[3]);
    const today = new Date(); today.setHours(0, 0, 0, 0);
    const days = Math.round((today - d) / 86400000);
    const hm = m[4] + ':' + m[5];
    if (days === 0) return 'Today ' + hm;
    if (days === 1) return 'Yesterday ' + hm;
    return d.getDate() + ' ' + ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.getMonth()] + ' ' + hm;
  }

  function diagnostics() {
    return '<div class="head-row"><h1>Diagnostics</h1><button class="btn" data-act="report">Copy for a bug report</button>' +
      '<button class="btn" data-act="openLogs">Open log folder</button></div>' +
      '<div class="log" aria-label="Recent log lines">' + esc(S.log.join('\n')) + '</div>' +
      '<h2>Windows</h2><div class="group">' +
      toggleRow('NativeWindows', 'Use the classic windows', 'The settings and setup windows of Whispers 2.2, without WebView2. Applies the next time a window opens.') +
      '</div>';
  }

  function about() {
    const a = S.app, c = S.config;
    let line, action = '';
    if (a.update) {
      line = 'Whispers ' + a.update + ' is ready to install';
      action = '<button class="btn primary" data-act="installUpdate">Install ' + esc(a.update) + '</button>';
    } else {
      if (a.updateState === 'current') line = 'You are up to date - checked at ' + a.checkedAt;
      else if (a.updateState === 'failed') line = 'GitHub could not be reached - try again later';
      else line = String(c.CheckUpdates) === '1' ? 'Checks for a new version when Whispers starts' : 'The update check is turned off';
      action = '<button class="btn" data-act="checkUpdate">Check for updates</button>';
    }
    const autostart = Number(c.Autostart) === 1;
    return '<h1>About</h1>' +
      '<div class="card" style="padding:20px;gap:18px;margin-bottom:20px"><div class="logo" style="width:64px;height:64px;border-radius:16px">' +
      '<svg aria-hidden="true" width="34" height="34" viewBox="0 0 24 24" stroke-width="2.4"><path d="M5 10v4"/><path d="M9.5 7v10"/><path d="M14.5 5v14"/><path d="M19 9v6"/></svg></div>' +
      '<div class="lines" style="gap:4px"><div class="display" style="font-size:20px;font-weight:600">' + esc(a.name) + ' ' + esc(a.version) + '</div>' +
      '<div class="sub">' + esc(line) + '</div></div>' + action +
      '<a href="https://github.com/mmmansouri/whispers/releases" style="font-size:13px;white-space:nowrap">Release notes</a></div>' +
      '<h2>Appearance</h2><div class="group"><div class="card"><div class="lines"><div class="title">Theme</div>' +
      '<div class="muted">System follows the Windows light or dark mode</div></div>' +
      seg('Theme', [['system', 'System'], ['light', 'Light'], ['dark', 'Dark']], 'Theme') + '</div></div>' +
      '<h2>Startup and updates</h2><div class="group">' +
      '<div class="card"><div class="lines"><div class="title">Start with Windows</div><div class="muted">Whispers waits in the tray, ready for ' +
      esc(ws.keyLabel(c.Hotkey)) + '</div></div><div class="switch-wrap"><span class="sub">' + (autostart ? 'On' : 'Off') + '</span>' +
      '<button class="switch" role="switch" aria-checked="' + autostart + '" aria-label="Start with Windows" data-act="autostart"></button></div></div>' +
      toggleRow('CheckUpdates', 'Check for updates', 'Asks GitHub once at startup. Never installs without asking.') +
      '</div><p class="muted" style="margin-top:20px">Everything runs on this PC: what you say never leaves it. ' +
      (a.runtime ? 'Shown with Microsoft Edge WebView2 ' + esc(a.runtime) + '.' : '') + '</p>';
  }

  // --- what the user does -----------------------------------------------
  document.addEventListener('click', function (e) {
    const t = e.target.closest('[data-act]');
    if (!t) {
      if (S.micMenu && !e.target.closest('.picker')) { S.micMenu = false; render(); }
      return;
    }
    if (t.disabled) return;
    const d = t.dataset;
    switch (d.act) {
      case 'go': go(d.page); break;
      case 'toggle': set(d.key, String(S.config[d.key]) === '1' ? '0' : '1'); break;
      case 'set': set(d.key, d.value); break;
      case 'micMenu': S.micMenu = !S.micMenu; render(); break;
      case 'mic': S.micMenu = false; set('Mic', d.value); syncMeter(); break;
      case 'detect': ws.send('detectMic'); break;
      case 'changeKey':
        S.keyError = '';
        ws.send('capture', { on: true });
        S.capturing = ws.captureKey(function (key) {
          S.capturing = null;
          ws.send('capture', { on: false });
          if (key) ws.send('hotkey', { value: key });
          render();
        }, function (msg) { S.keyError = msg; ws.toast(msg); });
        render();
        break;
      case 'cancelKey': if (S.capturing) S.capturing(); break;
      case 'tier':
        S.pendingTier = d.value === S.config.Tier ? '' : d.value;
        render();
        break;
      case 'tierCancel': S.pendingTier = ''; render(); break;
      case 'tierGo': ws.send('tier', { value: d.value }); break;
      case 'cancelDownload': ws.send('cancelDownload'); break;
      case 'server': ws.send('server', { on: d.on === '1' }); break;
      case 'copy': ws.send('copy', { index: parseInt(d.index, 10) }); break;
      case 'report': ws.send('report'); break;
      case 'openLogs': ws.send('openLogs'); break;
      case 'checkUpdate': ws.send('checkUpdate'); ws.toast('Checking for updates...'); break;
      case 'installUpdate': ws.send('installUpdate'); break;
      case 'autostart':
        S.config.Autostart = Number(S.config.Autostart) === 1 ? 0 : 1;
        ws.send('autostart', { value: S.config.Autostart === 1 });
        render();
        break;
    }
  });

  // Free fields are sent when left or confirmed, not on every keystroke;
  // the value that comes back is the one kept.
  document.addEventListener('change', function (e) {
    const f = e.target.dataset && e.target.dataset.field;
    if (f === 'Port' || f === 'LoadTimeout') set(f, e.target.value.trim());
  });
  document.addEventListener('input', function (e) {
    if (e.target.dataset && e.target.dataset.field === 'search') { S.search = e.target.value; renderHistoryList(); }
  });
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && e.target.classList && e.target.classList.contains('input')) e.target.blur();
    if (e.key === 'Escape' && S.micMenu) { S.micMenu = false; render(); }
  });
})();
