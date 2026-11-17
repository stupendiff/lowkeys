// Run with: node --test plugins/lowkeys/tests/model.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const M = require('../app/web/model.js');

const kinds = (events) => events.map((e) => e.e);
const lineText = (line) => line.chars.map((c) => c.c).join('');

test('typing lands on one line and comes back as clean text', () => {
  const s = M.create();
  const ev = M.type(s, 'hello there');
  assert.equal(ev.length, 11);
  assert.ok(ev.every((e) => e.e === 'char'));
  assert.equal(s.lines.length, 1);
  assert.equal(M.cleanText(s), 'hello there');
});

test('Return is a hard break and saves as a newline', () => {
  const s = M.create();
  M.type(s, 'one');
  const ev = M.type(s, '\n');
  assert.deepEqual(ev, [{ e: 'return', soft: false }]);
  M.type(s, 'two');
  assert.equal(s.lines.length, 2);
  assert.equal(s.lines[0].end, 'hard');
  assert.equal(M.cleanText(s), 'one\ntwo');
});

test('a blank line between paragraphs survives', () => {
  const s = M.create();
  M.type(s, 'one\n\ntwo');
  assert.equal(M.cleanText(s), 'one\n\ntwo');
});

test('the bell rings once, bellAt columns before the margin', () => {
  const s = M.create({ margin: 20, bellAt: 6 });
  const ev = M.type(s, 'abcdefghijklmnopqr');
  const bells = ev.map((e, i) => (e.e === 'bell' ? i : -1)).filter((i) => i >= 0);
  assert.deepEqual(bells, [14]); // straight after the 14th character
});

test('the carriage returns at the first space at or past the margin', () => {
  const s = M.create({ margin: 10, slack: 12 });
  const ev = M.type(s, 'aaaa bbbb cccc dddd');
  // 'aaaa bbbb ' is 10 columns: the space at column 10 returns the carriage.
  assert.equal(lineText(s.lines[0]), 'aaaa bbbb ');
  assert.equal(s.lines[0].end, 'soft');
  assert.equal(lineText(s.lines[1]), 'cccc dddd');
  assert.equal(kinds(ev).filter((k) => k === 'return').length, 1);
  assert.equal(M.cleanText(s), 'aaaa bbbb cccc dddd');
});

test('a space before the margin does not return the carriage', () => {
  const s = M.create({ margin: 10 });
  M.type(s, 'aaa bbb ');
  assert.equal(s.lines.length, 1);
});

test('a word that runs past margin + slack is broken without adding a space', () => {
  const s = M.create({ margin: 10, slack: 3 });
  const word = 'abcdefghijklmnopqrst';
  M.type(s, word);
  assert.equal(lineText(s.lines[0]), 'abcdefghijklm');
  assert.equal(s.lines[0].end, 'soft');
  assert.equal(M.cleanText(s), word);
});

test('a returned line is never re-wrapped', () => {
  const s = M.create({ margin: 10 });
  M.type(s, 'aaaa bbbb cccc');
  const first = lineText(s.lines[0]);
  M.type(s, ' dddd eeee ffff');
  assert.equal(lineText(s.lines[0]), first);
});

test('backspace strikes leftwards, one letter a press, and typing carries on', () => {
  const s = M.create();
  M.type(s, 'helo');
  assert.equal(M.strike(s), 3);
  M.type(s, 'lo');
  assert.equal(lineText(s.lines[0]), 'helolo');
  assert.deepEqual(s.lines[0].chars.map((c) => c.struck), [false, false, false, true, false, false]);
  assert.equal(M.cleanText(s), 'hello');
  assert.equal(M.strike(s), 5);
  assert.equal(M.strike(s), 4);
  assert.equal(M.strike(s), 2); // skips the letter already struck
});

test('backspace stops at the start of the line and never crosses to the one above', () => {
  const s = M.create();
  M.type(s, 'ab\nc');
  assert.equal(M.strike(s), 0);
  assert.equal(M.strike(s), -1);
  assert.equal(M.cleanText(s), 'ab\n');
});

test('struck spaces are left out too', () => {
  const s = M.create();
  M.type(s, 'the quick ');
  for (let i = 0; i < 6; i++) M.strike(s);
  M.type(s, 'slow');
  assert.equal(M.cleanText(s), 'the slow');
});

test('option-backspace strikes trailing spaces and the word before them', () => {
  const s = M.create();
  M.type(s, 'one two  ');
  const hit = M.strikeWord(s);
  assert.deepEqual(hit, [8, 7, 6, 5, 4]);
  assert.equal(M.cleanText(s), 'one');
  assert.deepEqual(M.strikeWord(s), [3, 2, 1, 0]);
  assert.deepEqual(M.strikeWord(s), []);
});

test('struck letters still take up paper, so they count towards the margin', () => {
  const s = M.create({ margin: 10 });
  M.type(s, 'aaaa');
  M.strikeWord(s);
  M.type(s, 'bbbb ');
  assert.equal(s.lines.length, 1); // 9 columns
  M.type(s, 'c ');
  assert.equal(s.lines.length, 2); // the space at column 11 returns
  assert.equal(M.cleanText(s), 'bbbb c');
});

test('spaces left hanging before a newline or at the end are dropped', () => {
  const s = M.create();
  M.type(s, 'one  \ntwo ');
  assert.equal(M.cleanText(s), 'one\ntwo');
});

test('fromText rebuilds a page that saves back to the same text', () => {
  const text = 'A first paragraph that is long enough to wrap more than once at a narrow margin.\n\nSecond one.\nThird.';
  const s = M.fromText(text, { margin: 20 });
  assert.ok(s.lines.length > 6);
  assert.equal(M.cleanText(s), text);
  assert.equal(s.lines[s.lines.length - 1].end, null);
});

test('fromText copes with nothing and with Windows line endings', () => {
  assert.equal(M.cleanText(M.fromText('')), '');
  assert.equal(M.cleanText(M.fromText(null)), '');
  assert.equal(M.cleanText(M.fromText('a\r\nb')), 'a\nb');
});

test('characters outside the basic plane stay whole', () => {
  const s = M.create();
  M.type(s, 'a😀b');
  assert.equal(s.lines[0].chars.length, 3);
  M.strike(s); M.strike(s);
  assert.equal(M.cleanText(s), 'a');
});

test('wordCount', () => {
  assert.equal(M.wordCount(''), 0);
  assert.equal(M.wordCount('  one  two\nthree '), 3);
});

test('goalReached', () => {
  assert.equal(M.goalReached(null, 999, 999), false);
  assert.equal(M.goalReached({ words: 100 }, 99, 50), false);
  assert.equal(M.goalReached({ words: 100 }, 100, 0), true);
  assert.equal(M.goalReached({ minutes: 20 }, 5000, 19.9), false);
  assert.equal(M.goalReached({ minutes: 20 }, 0, 20), true);
});

test('odd settings fall back to the defaults', () => {
  const s = M.create({ margin: -4, slack: -1, bellAt: 0 });
  assert.equal(s.margin, M.DEFAULTS.margin);
  assert.equal(s.slack, M.DEFAULTS.slack);
  assert.equal(s.bellAt, M.DEFAULTS.bellAt);
  assert.equal(M.create({ margin: 4, bellAt: 6 }).bellAt, 3);
});
