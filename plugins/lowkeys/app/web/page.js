// Lowkeys: draws the paper and moves it. The app sends every key in through
// window.lk; nothing here listens to the keyboard unless the page is opened
// in a plain browser, where it runs as a silent harness for tuning the feel.
(function () {
  'use strict';

  var M = window.LowkeysModel;
  var boot = window.__LK || {};
  var cfg = boot.config || {};
  var gen = boot.gen || 0;
  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lk;

  function post(msg) {
    msg.gen = gen;
    if (bridge) bridge.postMessage(msg);
    else if (msg.t !== 'save') console.log('[lowkeys]', msg);
  }

  var sheet = document.getElementById('sheet');
  var noteEl = document.getElementById('note');
  var statsEl = document.getElementById('stats');
  var probe = document.getElementById('probe');

  if (cfg.theme) document.documentElement.dataset.theme = cfg.theme;
  if (cfg.zoom) document.documentElement.style.setProperty('--zoom', cfg.zoom);
  if (cfg.font) {
    document.documentElement.style.setProperty(
      '--font', '"' + String(cfg.font).replace(/["\\]/g, '') + '", "Courier Prime", "Courier", monospace');
  }

  // How much of each older line is left, nearest first. Past the end: gone.
  var FADE = [1, 0.5, 0.32, 0.19, 0.1, 0.04];
  var SAVE_AFTER_MS = 800;

  var state, lineEls, session, saveTimer = null, noteTimer = null, peeking = false;

  function modelOpts() { return { margin: cfg.margin, slack: cfg.slack, bellAt: cfg.bell_at }; }

  function start(text) {
    text = String(text || '');
    // Picking a page back up: leave a space so the next word doesn't run
    // into the last one. It is dropped again on save if nothing follows.
    if (text && !/\s$/.test(text)) text += ' ';
    state = M.fromText(text, modelOpts());
    session = { words0: M.wordCount(M.cleanText(state)), t0: null, rung: false };
    rebuild();
  }

  // ---- drawing ----------------------------------------------------------

  function lineHeight() { return probe.getBoundingClientRect().height; }

  // Uneven ink: each letter lands a touch lighter, higher or more tilted
  // than the last, as on a ribbon.
  function span(ch, fresh) {
    var el = document.createElement('span');
    el.className = fresh ? 'c new' : 'c';
    el.textContent = ch.c;
    if (ch.c === ' ') el.classList.add('sp');
    else {
      el.style.setProperty('--o', (0.8 + Math.random() * 0.2).toFixed(2));
      el.style.setProperty('--dy', (Math.random() * 1.2 - 0.6).toFixed(2) + 'px');
      el.style.setProperty('--r', (Math.random() * 1.2 - 0.6).toFixed(2) + 'deg');
    }
    if (ch.struck) el.classList.add('struck');
    return el;
  }

  function lineEl(index, empty) {
    var el = document.createElement('div');
    el.className = 'line';
    el.style.top = (index * lineHeight()) + 'px';
    var chars = empty ? [] : state.lines[index].chars;
    for (var i = 0; i < chars.length; i++) el.appendChild(span(chars[i], false));
    sheet.appendChild(el);
    lineEls[index] = el;
    return el;
  }

  function fade() {
    var cur = state.lines.length - 1;
    for (var key in lineEls) {
      var i = Number(key), d = cur - i;
      if (d >= FADE.length) { lineEls[i].remove(); delete lineEls[i]; }
      else lineEls[i].style.opacity = FADE[d];
    }
  }

  // Slides the sheet so the end of the current line sits at the typing point.
  function place(how) {
    var cur = state.lines.length - 1;
    var el = lineEls[cur];
    var x = window.innerWidth * 0.5 - el.getBoundingClientRect().width;
    var y = window.innerHeight * 0.72 - (cur + 1) * lineHeight();
    sheet.classList.toggle('ret', how === 'ret');
    sheet.classList.toggle('still', how === 'still');
    sheet.style.transform = 'translate(' + x.toFixed(2) + 'px,' + y.toFixed(2) + 'px)';
    if (how === 'still') { void sheet.offsetWidth; sheet.classList.remove('still'); }
  }

  function rebuild() {
    sheet.textContent = '';
    lineEls = {};
    var cur = state.lines.length - 1;
    for (var i = Math.max(0, cur - FADE.length + 1); i <= cur; i++) lineEl(i);
    fade();
    place('still');
  }

  // ---- what a key does --------------------------------------------------

  // The line the next drawn character belongs to. The model has already
  // taken the whole batch, so drawing follows the events, not the model:
  // letters before a return go on the old line, letters after it on a new,
  // empty one.
  var cursorLine = 0;

  function apply(events) {
    var returned = false;
    for (var i = 0; i < events.length; i++) {
      var ev = events[i];
      if (ev.e === 'char') {
        lineEls[cursorLine].appendChild(span({ c: ev.c, struck: false }, true));
      } else if (ev.e === 'bell') {
        post({ t: 'sound', n: 'bell' });
      } else if (ev.e === 'return') {
        cursorLine += 1;
        lineEl(cursorLine, true);
        returned = true;
        post({ t: 'sound', n: 'return' });
      }
    }
    if (returned) fade();
    place(returned ? 'ret' : 'type');
    return returned;
  }

  function changed(returned, spaced) {
    if (!session.t0) session.t0 = Date.now();
    if (returned || spaced) checkGoal();
    clearTimeout(saveTimer);
    if (returned) save(); else saveTimer = setTimeout(save, SAVE_AFTER_MS);
    if (peeking) showStats();
  }

  function save() {
    clearTimeout(saveTimer); saveTimer = null;
    post({ t: 'save', text: M.cleanText(state) });
  }

  function sitting() {
    var words = M.wordCount(M.cleanText(state));
    return {
      words: words,
      here: Math.max(0, words - session.words0),
      minutes: session.t0 ? (Date.now() - session.t0) / 60000 : 0
    };
  }

  function checkGoal() {
    if (session.rung || !cfg.goal) return;
    var s = sitting();
    if (M.goalReached(cfg.goal, s.here, s.minutes)) {
      session.rung = true;
      post({ t: 'sound', n: 'goal' });
    }
  }
  setInterval(function () { if (session && session.t0) checkGoal(); }, 5000);

  function showStats() {
    var s = sitting();
    var parts = [s.words + (s.words === 1 ? ' word' : ' words')];
    if (s.here !== s.words) parts.push(s.here + ' this sitting');
    parts.push(Math.floor(s.minutes) + ' min');
    statsEl.textContent = parts.join('  ·  ');
  }

  // ---- the shelf (⌘O) --------------------------------------------------
  // The app decides what the keys mean while it is open and keeps track of
  // which row is chosen; this only draws.

  var shelfEl = document.getElementById('shelf');
  var rowsEl = document.getElementById('rows');
  var readIn = document.getElementById('read-in');
  var readTitle = document.getElementById('read-title');
  var readText = document.getElementById('read-text');
  var hintEl = document.getElementById('hint');
  var findEl = document.getElementById('find');
  var keysEl = document.getElementById('keys');
  var ROW_FADE = [1, 0.5, 0.36, 0.25, 0.16, 0.1, 0.06];
  var LIST_HINT = 'arrows  choose   ·   type  to find   ·   return  read   ·   esc  back';
  var READ_HINT = 'arrows  scroll   ·   return  write on   ·   esc  back';
  var shelfSel = 0, readY = 0;

  function cell(cls, text) {
    var el = document.createElement('span');
    el.className = cls;
    el.textContent = text;
    return el;
  }

  function placeRows(still) {
    var rows = rowsEl.children;
    if (!rows.length) return;
    for (var i = 0; i < rows.length; i++) {
      var d = Math.abs(i - shelfSel);
      rows[i].classList.toggle('sel', d === 0);
      rows[i].style.opacity = d < ROW_FADE.length ? ROW_FADE[d] : 0;
    }
    var h = rows[0].getBoundingClientRect().height;
    var y = window.innerHeight * 0.46 - (shelfSel + 0.5) * h;
    rowsEl.style.transition = still ? 'none' : '';
    rowsEl.style.transform = 'translateY(' + y.toFixed(2) + 'px)';
    if (still) { void rowsEl.offsetWidth; rowsEl.style.transition = ''; }
  }

  function placeRead(still) {
    var most = Math.max(0, readIn.offsetHeight - window.innerHeight);
    readY = Math.max(0, Math.min(most, readY));
    readIn.style.transition = still ? 'none' : '';
    readIn.style.transform = 'translateY(' + (-readY).toFixed(2) + 'px)';
    if (still) { void readIn.offsetWidth; readIn.style.transition = ''; }
  }

  function closeShelf() {
    shelfEl.classList.remove('on', 'reading');
  }

  // ---- the app's way in -------------------------------------------------

  window.lk = {
    // rows: [{when, first, words}], newest first.
    shelf: function (rows, sel, query) {
      rowsEl.textContent = '';
      findEl.textContent = query ? 'find: ' + query : '';
      if (!rows.length) {
        var none = document.createElement('div');
        none.className = 'row';
        none.appendChild(cell('mark', ''));
        none.appendChild(cell('when', ''));
        none.appendChild(cell('first', 'no page has those words'));
        rowsEl.appendChild(none);
      }
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i], el = document.createElement('div');
        el.className = 'row';
        el.appendChild(cell('mark', '>'));
        el.appendChild(cell('when', r.when));
        el.appendChild(cell('first', r.first));
        el.appendChild(cell('words', r.words + (r.words === 1 ? ' word' : ' words')));
        rowsEl.appendChild(el);
      }
      shelfSel = sel || 0;
      hintEl.textContent = LIST_HINT;
      noteEl.classList.remove('on');
      shelfEl.classList.remove('reading');
      shelfEl.classList.add('on');
      placeRows(true);
    },
    shelfSelect: function (i) { shelfSel = i; placeRows(false); },
    read: function (title, text) {
      readTitle.textContent = title;
      readText.textContent = '';
      var paras = String(text).split('\n');
      for (var i = 0; i < paras.length; i++) {
        var p = document.createElement('p');
        p.textContent = paras[i];
        readText.appendChild(p);
      }
      hintEl.textContent = READ_HINT;
      shelfEl.classList.add('reading');
      readY = 0;
      placeRead(true);
    },
    readScroll: function (how) {
      var line = parseFloat(getComputedStyle(readIn).lineHeight) || 30;
      var page = window.innerHeight * 0.7;
      if (how === 'up') readY -= line * 3;
      else if (how === 'down') readY += line * 3;
      else if (how === 'pgup') readY -= page;
      else if (how === 'pgdn') readY += page;
      else if (how === 'home') readY = 0;
      else if (how === 'end') readY = Infinity;
      placeRead(false);
    },
    readClose: function () {
      hintEl.textContent = LIST_HINT;
      shelfEl.classList.remove('reading');
      placeRows(true);
    },
    shelfClose: closeShelf,
    // Puts another page on the paper to carry on writing it.
    open: function (text, newGen) {
      clearTimeout(saveTimer); saveTimer = null;
      if (newGen) gen = newGen;
      start(text);
      closeShelf();
    },
    type: function (text) {
      cursorLine = state.lines.length - 1;
      var returned = apply(M.type(state, text));
      changed(returned, /\s/.test(text));
    },
    ret: function () {
      cursorLine = state.lines.length - 1;
      apply(M.type(state, '\n'));
      changed(true, true);
    },
    back: function () {
      var cur = state.lines.length - 1;
      var i = M.strike(state);
      if (i < 0) return false;
      var el = lineEls[cur].children[i];
      el.classList.add('struck');
      // A space has no ink to strike: it is taken back and the gap closes.
      post({ t: 'sound', n: el.classList.contains('sp') ? 'space' : 'strike' });
      place('type');
      changed(false, true);
      return true;
    },
    backWord: function () {
      var cur = state.lines.length - 1;
      var hit = M.strikeWord(state);
      if (!hit.length) return false;
      for (var k = 0; k < hit.length; k++) lineEls[cur].children[hit[k]].classList.add('struck');
      post({ t: 'sound', n: 'strike' });
      place('type');
      changed(false, true);
      return true;
    },
    text: function () { return M.cleanText(state); },
    // Starts a clean page. Returns the text of the one being put away.
    fresh: function (newGen) {
      var old = M.cleanText(state);
      clearTimeout(saveTimer); saveTimer = null;
      if (newGen) gen = newGen;
      start('');
      closeShelf();
      return old;
    },
    note: function (msg) {
      noteEl.textContent = msg;
      noteEl.classList.add('on');
      shelfEl.classList.add('quiet');     // the hint sits in the same place
      clearTimeout(noteTimer);
      noteTimer = setTimeout(function () {
        noteEl.classList.remove('on');
        shelfEl.classList.remove('quiet');
      }, 1400);
    },
    theme: function (name) { document.documentElement.dataset.theme = name; },
    keys: function (on) { keysEl.classList.toggle('on', !!on); },
    zoom: function (z) {
      document.documentElement.style.setProperty('--zoom', z);
      rebuild(); placeRows(true); placeRead(true);
    },
    peek: function (on) {
      peeking = !!on;
      if (peeking) { showStats(); noteEl.classList.remove('on'); }
      statsEl.classList.toggle('on', peeking);
    }
  };

  window.addEventListener('resize', function () { rebuild(); placeRows(true); placeRead(true); });
  window.addEventListener('contextmenu', function (e) { e.preventDefault(); });
  window.addEventListener('dragstart', function (e) { e.preventDefault(); });

  // Fonts change the width of a line, so place once more when they are in.
  function ready() { rebuild(); post({ t: 'ready' }); }
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(ready, ready);
  else setTimeout(ready, 0);

  // Plain-browser harness: no app, so read the keyboard here.
  if (!bridge) {
    window.addEventListener('keydown', function (e) {
      if (e.key === 'Alt') { window.lk.peek(true); return; }
      if (e.metaKey || e.ctrlKey) return;
      e.preventDefault();
      if (e.key === 'Enter') window.lk.ret();
      else if (e.key === 'Backspace') { if (e.altKey) window.lk.backWord(); else window.lk.back(); }
      else if (e.key === 'Tab') window.lk.type('    ');
      else if (e.key.length === 1 || Array.from(e.key).length === 1) window.lk.type(e.key);
    });
    window.addEventListener('keyup', function (e) { if (e.key === 'Alt') window.lk.peek(false); });
  }

  start(boot.text);
})();
