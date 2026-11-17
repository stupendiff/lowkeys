// Lowkeys text model. No DOM, no clock: the page and the tests both use it.
//
// A page is a list of lines. A line is the characters typed on it, each
// either standing or struck, and how the line ended: null (still being
// typed), 'soft' (the carriage returned by itself at the margin) or 'hard'
// (the Return key). The typing point is always the end of the last line.
// Once a line has returned it is never re-wrapped: the paper keeps what
// was typed.
(function (root) {
  'use strict';

  var DEFAULTS = { margin: 62, slack: 12, bellAt: 6 };

  function newLine() { return { chars: [], end: null }; }

  function create(opts) {
    opts = opts || {};
    var margin = opts.margin > 0 ? Math.floor(opts.margin) : DEFAULTS.margin;
    return {
      margin: margin,
      slack: opts.slack >= 0 ? Math.floor(opts.slack) : DEFAULTS.slack,
      bellAt: Math.min(opts.bellAt > 0 ? Math.floor(opts.bellAt) : DEFAULTS.bellAt, margin - 1),
      lines: [newLine()]
    };
  }

  function current(s) { return s.lines[s.lines.length - 1]; }

  function carriageReturn(s, kind, events) {
    current(s).end = kind;
    s.lines.push(newLine());
    events.push({ e: 'return', soft: kind === 'soft' });
  }

  // Types text at the typing point. Returns what happened, in order:
  //   {e:'char', c}            a character landed on the current line
  //   {e:'bell'}               the line is 'bellAt' columns from the margin
  //   {e:'return', soft}       the carriage returned (soft = by itself)
  function type(s, text) {
    var events = [];
    var chars = Array.from(String(text));
    for (var i = 0; i < chars.length; i++) {
      var ch = chars[i];
      if (ch === '\n' || ch === '\r') { carriageReturn(s, 'hard', events); continue; }
      var line = current(s);
      line.chars.push({ c: ch, struck: false });
      events.push({ e: 'char', c: ch });
      // Columns count struck letters too: they still take up paper.
      var col = line.chars.length;
      if (col === s.margin - s.bellAt) events.push({ e: 'bell' });
      if (ch === ' ' && col >= s.margin) carriageReturn(s, 'soft', events);
      else if (col >= s.margin + s.slack) carriageReturn(s, 'soft', events);
    }
    return events;
  }

  function lastStanding(line, from) {
    for (var i = from; i >= 0; i--) if (!line.chars[i].struck) return i;
    return -1;
  }

  // Backspace: strikes the nearest standing character leftwards on the
  // current line. Returns its index, or -1 when there is nothing to strike.
  function strike(s) {
    var line = current(s);
    var i = lastStanding(line, line.chars.length - 1);
    if (i >= 0) line.chars[i].struck = true;
    return i;
  }

  // Option-backspace: strikes trailing spaces, then the word before them.
  // Returns the indexes struck, nearest first.
  function strikeWord(s) {
    var line = current(s);
    var hit = [];
    var i = lastStanding(line, line.chars.length - 1);
    while (i >= 0 && line.chars[i].c === ' ') {
      line.chars[i].struck = true; hit.push(i);
      i = lastStanding(line, i - 1);
    }
    while (i >= 0 && line.chars[i].c !== ' ') {
      line.chars[i].struck = true; hit.push(i);
      i = lastStanding(line, i - 1);
    }
    return hit;
  }

  // What gets saved, counted and printed: standing characters only. A soft
  // return adds nothing (the space that caused it is already on the line);
  // a hard return is a newline. Spaces left hanging before a newline go.
  function cleanText(s) {
    var out = '';
    for (var i = 0; i < s.lines.length; i++) {
      var line = s.lines[i];
      for (var j = 0; j < line.chars.length; j++) {
        if (!line.chars[j].struck) out += line.chars[j].c;
      }
      if (line.end === 'hard') out = out.replace(/[ \t]+$/, '') + '\n';
    }
    return out.replace(/[ \t]+$/, '');
  }

  // Rebuilds a page from saved text, as if it had been typed again.
  function fromText(text, opts) {
    var s = create(opts);
    type(s, String(text || '').replace(/\r\n?/g, '\n'));
    return s;
  }

  function wordCount(text) {
    var m = String(text || '').match(/\S+/g);
    return m ? m.length : 0;
  }

  // goal: null, {words: N} or {minutes: N}. Counts are for this sitting.
  function goalReached(goal, sessionWords, sessionMinutes) {
    if (!goal) return false;
    if (goal.words > 0) return sessionWords >= goal.words;
    if (goal.minutes > 0) return sessionMinutes >= goal.minutes;
    return false;
  }

  var api = {
    DEFAULTS: DEFAULTS, create: create, type: type, strike: strike,
    strikeWord: strikeWord, cleanText: cleanText, fromText: fromText,
    wordCount: wordCount, goalReached: goalReached
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.LowkeysModel = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
