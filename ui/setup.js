// =====================================================================
// Whispers - the first-run setup, one step at a time.
//
// Microphone and language apply as soon as they are picked, so the "Try
// it" step dictates with what the page shows. The dictation key is
// registered when the user leaves its step, not on every key press, and
// the step does not move on until Windows has accepted it. Closing the
// window at any step keeps what was applied and ends the setup.
// =====================================================================
'use strict';

(function () {
  const esc = ws.esc;
  const S = {
    step: 0, steps: [], config: {}, mics: [], virtualMics: [], tiers: [], status: {}, app: {},
    levels: {}, peaks: {}, capturing: null, pendingKey: '', keyErr: '', waitingKey: false,
    download: null, downloadErr: '', rec: { state: 'idle' }, recT0: 0, heard: '', holding: false
  };
  const LABELS = { welcome: 'Welcome', mic: 'Microphone', key: 'Key and language', model: 'Model', 'try': 'Try it', done: 'Done' };
  const TIER_NAMES = { fast: 'Fast', balanced: 'Balanced', max: 'Maximum accuracy', cpu: 'CPU only' };
  const MIC_SVG = '<svg aria-hidden="true" viewBox="0 0 24 24"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0"/><path d="M12 18v3"/></svg>';
  const BARS = 18;

  const $page = document.getElementById('page');
  const $next = document.getElementById('next');
  const $back = document.getElementById('back');

  // --- incoming --------------------------------------------------------
  ws.on('state', function (m) {
    const first = !S.steps.length;
    Object.assign(S, { config: m.config, mics: m.mics, virtualMics: m.virtualMics || [], tiers: m.tiers, status: m.status, app: m.app });
    if (first) {
      // A missing model gets a step of its own before "Try it", decided
      // once: the rail does not change under the user once it is there.
      S.steps = ['welcome', 'mic', 'key'];
      if (!m.status.modelInstalled) S.steps.push('model');
      S.steps.push('try', 'done');
    }
    render();
  });
  ws.on('config', function (m) { S.config[m.key] = m.value; render(); });
  ws.on('status', function (m) { S.status = m; render(); });
  ws.on('tiers', function (m) { S.tiers = m.tiers; render(); });
  ws.on('hotkey', function (m) {
    S.waitingKey = false;
    if (m.ok) {
      S.pendingKey = '';
      S.keyErr = '';
      S.config.Hotkey = m.value;
      move(1);
    } else {
      S.keyErr = m.error || 'Windows would not register that key.';
      render();
    }
  });
  ws.on('download', function (m) {
    if (m.phase === 'done' || m.phase === 'failed') {
      S.download = null;
      S.downloadErr = m.phase === 'failed' ? 'The download did not complete. Try again, or skip for now.' : '';
    } else {
      S.download = Object.assign(S.download || {}, m.phase === 'info' ? { info: m.label } : m);
    }
    render();
  });
  ws.on('level', function (m) {
    S.levels = m.levels;
    Object.keys(m.levels).forEach(function (d) {
      S.peaks[d] = Math.max(m.levels[d], (S.peaks[d] || 0) * 0.96);
    });
    paintLevels();
  });
  ws.on('rec', function (m) {
    S.rec = m;
    if (m.state === 'rec') S.recT0 = Date.now();
    if (cur() === 'try') renderStage();
  });
  ws.on('heard', function (m) { S.heard = String(m.text).trim(); if (cur() === 'try') renderStage(); });

  // --- steps -------------------------------------------------------------
  function cur() { return S.steps[S.step]; }

  function move(delta) {
    if (S.capturing) S.capturing();
    S.step = Math.max(0, Math.min(S.steps.length - 1, S.step + delta));
    render();
    $page.scrollTop = 0;
    $page.focus();
  }

  let meterSent = '';
  function syncMeter() {
    const step = cur();
    const on = document.visibilityState === 'visible' && (step === 'mic' || step === 'try');
    const all = step === 'mic';
    if (meterSent === on + '/' + all) return;
    meterSent = on + '/' + all;
    ws.send('meter', { on: on, all: all });
  }
  document.addEventListener('visibilitychange', syncMeter);

  function tierName() { return TIER_NAMES[S.config.Tier] || S.config.Tier; }
  function curTier() { return S.tiers.filter(function (t) { return t.id === S.config.Tier; })[0] || {}; }

  let lastStep = -1;
  function render() {
    if (!S.steps.length) return;
    const step = cur();
    document.getElementById('steps').innerHTML = S.steps.map(function (s, i) {
      const state = i < S.step ? ' class="done"' : (i === S.step ? ' aria-current="step"' : '');
      return '<li' + state + '><span class="mark">' + (i < S.step ? '&#10003;' : (i + 1)) + '</span><span>' + LABELS[s] + '</span></li>';
    }).join('');
    const t = curTier();
    document.getElementById('rail-note').textContent = (t.model ? 'Model: ' + t.model + ' (' + tierName() + ')' +
      (S.status.modelInstalled ? ' is installed. ' : ' is not installed yet. ') : '') + 'Everything runs on this PC - nothing you say leaves it.';

    const enter = S.step !== lastStep ? ' class="enter"' : '';
    lastStep = S.step;
    $page.innerHTML = '<div' + enter + '>' + ({ welcome: welcome, mic: mic, key: key, model: model, 'try': tryIt, done: done }[step])() + '</div>';
    if (step === 'try') renderStage();
    paintLevels();

    const last = S.steps.length - 1;
    document.getElementById('progress').textContent = S.step === 0 ? 'About a minute' : (S.step < last ? 'Step ' + S.step + ' of ' + (last - 1) : '');
    $back.classList.toggle('hidden', S.step === 0 || S.step === last);
    let label = 'Next';
    if (S.step === 0) label = 'Get started';
    else if (step === 'done') label = 'Finish';
    else if (step === 'try' && !S.heard) label = 'Skip';
    else if (step === 'model' && !S.status.modelInstalled) label = 'Skip for now';
    $next.textContent = label;
    $next.disabled = S.waitingKey || !!S.download || !!S.capturing;
    syncMeter();
  }

  function welcome() {
    const gpu = S.status.gpu ? 'Runs on your GPU' : 'Runs on this PC';
    return '<div class="hero display">Hold a key.<br>Speak.<br>Let go - it\'s typed.</div>' +
      '<p class="lead" style="max-width:520px">Three quick checks and you\'re dictating in any app: your microphone, your key, and a first sentence.</p>' +
      '<div class="chips" style="margin-top:8px"><span class="pill-chip">Works offline</span><span class="pill-chip">' + gpu +
      '</span><span class="pill-chip">French and English</span></div>';
  }

  function mic() {
    const best = bestMic();
    return '<h1 class="display">Which microphone?</h1><p class="lead">Say anything out loud. The one that moves is the one that hears you.</p>' +
      '<div role="radiogroup" aria-label="Microphones" style="display:flex;flex-direction:column;gap:8px">' +
      S.mics.map(function (d) {
        const on = d === S.config.Mic;
        const note = d === best ? '<span class="note best">Hears you best</span>' :
          (S.virtualMics.indexOf(d) >= 0 ? '<span class="note">Virtual device</span>' : '<span class="note"></span>');
        return '<button class="choice" role="radio" aria-checked="' + on + '" data-act="mic" data-value="' + esc(d) + '">' +
          '<span class="dot' + (on ? ' on' : '') + '"></span><span class="lines"><span style="display:flex;justify-content:space-between;gap:8px">' +
          '<span class="name">' + esc(d) + '</span>' + note + '</span>' +
          '<span class="meter tall' + (d === best ? ' best' : '') + '" data-dev="' + esc(d) + '"><i></i></span></span></button>';
      }).join('') + '</div>' +
      '<p class="muted">Not listed? Plug it in, then close and reopen this window.</p>';
  }

  // The device that has carried the most sound lately, clearly ahead of
  // the others - never a virtual one, which can be loud for the wrong
  // reason (a cable carrying music). Nothing is named until someone speaks.
  function bestMic() {
    let best = '', top = 0, second = 0;
    S.mics.forEach(function (d) {
      if (S.virtualMics.indexOf(d) >= 0) return;
      const p = S.peaks[d] || 0;
      if (p > top) { second = top; top = p; best = d; } else if (p > second) second = p;
    });
    return top >= 0.3 && top - second >= 0.15 ? best : '';
  }

  let lastBest = '';
  function paintLevels() {
    document.querySelectorAll('[data-dev]').forEach(function (el) {
      const v = S.levels[el.dataset.dev] || 0;
      el.firstChild.style.width = Math.round(v * 100) + '%';
    });
    if (cur() === 'mic') {
      const b = bestMic();
      if (b !== lastBest) { lastBest = b; render(); }
    }
    if (cur() === 'try') paintBars();
  }

  function key() {
    const shown = S.pendingKey || S.config.Hotkey;
    let line, sub;
    if (S.capturing) { line = 'Press the key to use'; sub = 'A key or a combination, such as F9 or Ctrl + Space. Esc cancels.'; }
    else if (S.keyErr) { line = 'That key cannot be used'; sub = S.keyErr; }
    else if (S.pendingKey) { line = ws.keyLabel(S.pendingKey) + ' will be your dictation key'; sub = 'Press Next to use it.'; }
    else { line = ws.keyLabel(shown) + ' is your dictation key'; sub = 'Press another key or combination to change it.'; }
    const langs = [['fr', 'French', 'Fran&#231;ais'], ['en', 'English', 'English'], ['auto', 'Both', 'Detected per dictation']];
    return '<h1 class="display">Your dictation key</h1><p class="lead">Hold it while you speak, release to paste. Pick a key you never use for anything else.</p>' +
      '<div class="keybox"><div class="bigkey' + (S.capturing ? ' listening' : '') + '">' + (S.capturing ? 'Listening...' : esc(ws.keyLabel(shown))) + '</div>' +
      '<div class="lines grow" style="display:flex;flex-direction:column;gap:6px"><div style="font-size:15px;font-weight:600">' + esc(line) + '</div>' +
      '<div class="' + (S.keyErr && !S.capturing ? 'error-text' : 'muted') + '" style="font-size:13px">' + esc(sub) + '</div></div>' +
      (S.capturing ? '<button class="btn big" data-act="cancelKey">Cancel</button>' : '<button class="btn big" data-act="captureKey">Record a new key</button>') + '</div>' +
      '<div class="display" style="font-size:18px;font-weight:600;margin-top:10px">You speak</div>' +
      '<div class="langs" role="group" aria-label="Language">' + langs.map(function (l) {
        return '<button aria-pressed="' + (S.config.Language === l[0]) + '" data-act="lang" data-value="' + l[0] + '"><span style="font-weight:600">' +
          l[1] + '</span><span class="muted">' + l[2] + '</span></button>';
      }).join('') + '</div>';
  }

  function model() {
    const t = curTier();
    let body;
    if (S.status.modelInstalled) {
      body = '<div class="card"><span class="tag ok">Installed</span><div class="lines"><div class="title">' + esc(t.model) + ' is on this PC</div></div></div>';
    } else if (S.download) {
      const d = S.download;
      const pct = d.total ? Math.min(100, Math.round(d.got / d.total * 100)) : 0;
      const info = d.info || (d.total ? Math.round(d.got / 1048576) + ' of ' + Math.round(d.total / 1048576) + ' MB' : 'Starting...');
      body = '<div class="card" style="flex-direction:column;align-items:stretch;gap:12px"><div class="title">Downloading ' + esc(t.model) + '</div>' +
        '<div class="progress' + (d.total ? '' : ' busy') + '"><i style="width:' + pct + '%"></i></div>' +
        '<div style="display:flex;align-items:center"><span class="muted grow">' + esc(info) + '</span><button class="btn" data-act="cancelDownload">Cancel</button></div></div>';
    } else {
      body = '<div class="card"><div class="lines"><div class="title">' + esc(t.model || 'The model') + ' - ' + ws.fmtBytes(t.bytes) + '</div>' +
        '<div class="muted">Checked against its published SHA-256 before it is used.</div></div>' +
        '<button class="btn primary big" data-act="getModel">Download</button></div>' +
        (S.downloadErr ? '<div class="error-text">' + esc(S.downloadErr) + '</div>' : '');
    }
    return '<h1 class="display">The speech model</h1><p class="lead">Whispers turns your voice into text with a model that runs on this PC. ' +
      'The ' + esc(tierName()) + ' tier needs it before you can dictate.</p>' + body;
  }

  function tryIt() {
    return '<h1 class="display">Try it</h1><p class="lead">Hold ' + esc(ws.keyLabel(S.config.Hotkey)) +
      ' - or press and hold the button below - and say a sentence. Nothing is pasted anywhere yet.</p>' +
      '<div class="stage" id="stage"></div>' +
      '<div style="display:flex;align-items:center;gap:14px"><button class="btn hold" id="hold">Hold to talk</button>' +
      '<span class="muted" id="try-hint"></span></div>';
  }

  function renderStage() {
    const st = document.getElementById('stage');
    if (!st) return;
    const r = S.rec;
    let cls = '', inner = '';
    if (r.state === 'rec') {
      cls = 'rec';
      let bars = '';
      for (let i = 0; i < BARS; i++) bars += '<i></i>';
      inner = '<span class="bars" id="bars">' + bars + '</span><span id="timer">0:00</span>';
    } else if (r.state === 'work') {
      inner = '<span class="spin"></span><span>Transcribing...</span>';
    } else if (r.state === 'done') {
      cls = 'done';
      inner = '<span>' + esc(r.title || 'Heard you') + '</span><span class="small">' + esc(r.sub || '') + '</span>';
    } else if (r.state === 'error') {
      cls = 'error';
      inner = '<span>' + esc(r.title) + '</span>' + (r.sub ? '<span class="small">' + esc(r.sub) + '</span>' : '');
    } else {
      inner = '<span>Hold ' + esc(ws.keyLabel(S.config.Hotkey)) + '</span>';
    }
    st.innerHTML = (S.heard && r.state !== 'rec' && r.state !== 'work'
      ? '<div class="heard">&#8220;' + esc(S.heard) + '&#8221;</div>'
      : (r.state === 'rec' || r.state === 'work' ? '' : '<div class="waiting">Your words will appear here</div>')) +
      '<div class="glass ' + cls + '"><span class="orb">' + MIC_SVG + '</span>' + inner + '</div>';
    const hint = document.getElementById('try-hint');
    if (hint) hint.textContent = S.heard ? 'It works. Try again, or go on.' : 'Speak for a few seconds, then let go.';
    $next.textContent = S.heard ? 'Next' : 'Skip';
  }

  // The bars follow the real microphone level, newest on the right.
  const recent = [];
  function paintBars() {
    const bars = document.getElementById('bars');
    if (!bars) return;
    recent.push(S.levels[S.config.Mic] || 0);
    while (recent.length > BARS) recent.shift();
    for (let i = 0; i < BARS; i++) {
      const v = recent[i - (BARS - recent.length)] || 0;
      bars.children[i].style.height = Math.round(4 + v * 24) + 'px';
    }
    const t = document.getElementById('timer');
    if (t) {
      const s = Math.floor((Date.now() - S.recT0) / 1000);
      t.textContent = Math.floor(s / 60) + ':' + ('0' + (s % 60)).slice(-2);
    }
  }

  function done() {
    const on = Number(S.config.Autostart) === 1;
    return '<div class="check" style="margin-top:24px"><svg aria-hidden="true" viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></div>' +
      '<h1 class="display" style="font-size:34px">You\'re all set</h1>' +
      '<p class="lead" style="max-width:540px">Whispers now waits in the tray, next to the clock. Hold ' + esc(ws.keyLabel(S.config.Hotkey)) +
      ' in any app - a mail, a chat, a document - and speak.</p>' +
      '<div class="card" style="max-width:560px"><div class="lines"><span class="title">Start with Windows</span>' +
      '<span class="muted">So ' + esc(ws.keyLabel(S.config.Hotkey)) + ' works right after you sign in</span></div>' +
      '<div class="switch-wrap"><span class="sub">' + (on ? 'On' : 'Off') + '</span><button class="switch" role="switch" aria-checked="' + on +
      '" aria-label="Start with Windows" data-act="autostart"></button></div></div>';
  }

  // --- what the user does -----------------------------------------------
  document.addEventListener('click', function (e) {
    const t = e.target.closest('[data-act]');
    if (!t || t.disabled) return;
    const d = t.dataset;
    switch (d.act) {
      case 'next':
        if (cur() === 'done') { ws.send('finish'); return; }
        if (cur() === 'key' && S.pendingKey && S.pendingKey !== S.config.Hotkey) {
          S.waitingKey = true;
          render();
          ws.send('hotkey', { value: S.pendingKey });
          return;
        }
        move(1);
        break;
      case 'back': move(-1); break;
      case 'mic':
        S.config.Mic = d.value;
        ws.send('set', { key: 'Mic', value: d.value });
        render();
        break;
      case 'lang':
        S.config.Language = d.value;
        ws.send('set', { key: 'Language', value: d.value });
        render();
        break;
      case 'captureKey':
        S.keyErr = '';
        ws.send('capture', { on: true });
        S.capturing = ws.captureKey(function (k) {
          S.capturing = null;
          ws.send('capture', { on: false });
          if (k) S.pendingKey = k === S.config.Hotkey ? '' : k;
          render();
        }, function (msg) { S.keyErr = msg; ws.toast(msg); });
        render();
        break;
      case 'cancelKey': if (S.capturing) S.capturing(); break;
      case 'getModel': S.downloadErr = ''; ws.send('getModel'); break;
      case 'cancelDownload': ws.send('cancelDownload'); break;
      case 'autostart':
        S.config.Autostart = Number(S.config.Autostart) === 1 ? 0 : 1;
        ws.send('autostart', { value: S.config.Autostart === 1 });
        render();
        break;
    }
  });

  // Hold to talk: the button stands in for the dictation key. Pointer
  // capture keeps the release even when the pointer has left the button.
  document.addEventListener('pointerdown', function (e) {
    if (e.target.id !== 'hold' || e.button !== 0 || S.holding) return;
    S.holding = true;
    try { e.target.setPointerCapture(e.pointerId); } catch (err) { /* window blur still ends it */ }
    e.target.classList.add('pressed');
    ws.send('talk', { down: true });
  });
  function release() {
    if (!S.holding) return;
    S.holding = false;
    const b = document.getElementById('hold');
    if (b) b.classList.remove('pressed');
    ws.send('talk', { down: false });
  }
  document.addEventListener('pointerup', release);
  document.addEventListener('pointercancel', release);
  window.addEventListener('blur', release);
})();
