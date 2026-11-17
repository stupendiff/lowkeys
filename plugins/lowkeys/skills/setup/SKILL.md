---
name: setup
description: Set up or change Lowkeys, the typewriter writing mode in the Mac menu bar. Builds the app on this Mac, then sets where the writing is saved, the hotkey that opens it, an optional goal for each sitting, the sounds, and whether it starts at login. Use when "set up lowkeys", "install the typewriter", "change where lowkeys saves", "change the lowkeys hotkey", "set a word goal", "turn the typewriter sounds off", "use a different font in lowkeys". Re-runnable: it shows what's installed first. To take it away for good, that's /lowkeys:remove.
---

# Lowkeys setup

Lowkeys puts a small **k** in the menu bar. Click it, or press the hotkey, and the whole screen becomes paper. The line being typed sits near the bottom and slides left under a fixed typing point; at the margin a bell rings and the carriage returns. Backspace doesn't erase: it strikes the letter through. There is no mouse and nothing to click.

The writing is saved as plain `.md` files on this Mac only, with the struck letters left out.

Everything goes through one script. Below, `LK` means:

```bash
python3 "${CLAUDE_SKILL_DIR}/../../scripts/lowkeys.py"
```

Ask one question at a time, and keep each one short. Most people want the defaults, so offer them first.

## 1. Check the machine

Run `LK check`.

- **`macos: false`:** Lowkeys is Mac-only. Say that, then stop.
- **`swiftc: false`:** the app is built on their Mac, which needs the Xcode Command Line Tools. Ask them to run `xcode-select --install` (a system dialog, a few minutes), then come back. Stop here until it's done.
- **`installed: true`:** show the current setup in two lines (folder, hotkey, goal, sounds, starts at login) and ask what to change. Then go only to the step for that change, and install with only the flags that changed. Install keeps everything else.

| They want | Do |
|---|---|
| A different folder | Step 2 |
| A different hotkey, or none | Step 3 |
| A goal, or no goal | Step 4 |
| Sounds off, quieter, or their own | Step 5 |
| Not to start at login | `LK install --login off` (`on` brings it back) |
| A different font or line length | Step 6 |
| Never see it again | That's `/lowkeys:remove` |

## 2. Where the writing goes

The default is `~/Documents/Lowkeys/`. Each page is one file named by when it was started, like `2026-11-17-0930.md`, and its PDF sits beside it. Offer the default; if they name another folder, pass it as `--save-dir`. A synced folder (iCloud Drive, Dropbox) works.

Changing the folder later doesn't move pages already written.

## 3. The hotkey

The default is ⌃⌥L (`--hotkey ctrl+opt+l`). It opens the page from anywhere.

- Write it as modifiers and one key joined by `+`: `ctrl`, `opt`, `shift`, `cmd`, then a letter, a digit or `space`.
- It must include `ctrl` or `cmd`. macOS refuses hotkeys made of Option or Shift alone.
- `--hotkey off` leaves only the menu bar click.

If the hotkey does nothing after install, another app already holds it. Pick another.

## 4. A goal for each sitting

Off by default. Ask if they want one, and which kind:

- **Words:** `--goal-words 500`
- **Minutes:** `--goal-minutes 20`
- **None:** `--goal off`

Nothing is shown while writing. When the goal is reached, two bells ring, once. A sitting is from opening the page to closing it.

## 5. The sounds

On by default: a click per key, a duller one for space, a tap for backspace, a bell six columns before the margin, and the carriage coming back.

- `--sounds off` makes it silent. `--volume 0.5` makes it quieter (0 to 1; the default is 0.8).
- The bundled sounds are synthesized, not recorded. Recordings of a real machine sound better. If they have some, `--sounds-dir /path/to/folder` uses them: files named `key1`, `key2`, … (picked at random), `space`, `strike`, `return`, `bell`, `goal`, as `.wav`, `.aiff`, `.m4a` or `.mp3`. Anything missing falls back to the bundled one. `--sounds-dir none` goes back.

## 6. Font and line length

- `--font "American Typewriter"` uses any font installed on the Mac. `--font none` goes back to the bundled Courier Prime. A monospaced font moves the paper one even step per letter, which is the point; a proportional one works but feels less like a machine.
- `--margin 62` is how many columns a line runs before the carriage returns by itself (20 to 200).

## 7. Install and show it

1. Run `LK install [flags] --dry-run`. Sum it up in one line: the folder, the hotkey, the goal.
2. On a yes, run it again without `--dry-run`. The first time takes about ten seconds while it compiles. It needs no internet.
3. Tell them what just changed on the Mac: the app is in `~/Library/Application Support/lowkeys/`, and (unless they said no) a login item at `~/Library/LaunchAgents/com.stupendiff.lowkeys.plist` starts it when they log in.
4. Run `LK run` so they see it now, and give them the keys:

| Key | What it does |
|---|---|
| Esc, ⌘Q or ⌘W | Close the page. It is always saved first. |
| ⌘S | Save now (it also saves by itself as you type) |
| ⌘P | Write a PDF beside the text file, in an ordinary reading font |
| ⌘N | Put this page away and start a clean one |
| ⌫ | Strike the last letter. ⌥⌫ strikes the last word. |
| Hold ⌥ | Show the word count and minutes until you let go |

Reopening Lowkeys picks up the page that was open, until ⌘N starts a new one. Right-click the **k** for New page, Show writing folder, Sounds and Quit.

## If something's off

- **The k isn't in the menu bar:** run `LK run`. If the menu bar is crowded, macOS hides items behind the notch; quit another menu bar app or use the hotkey.
- **The page opens but typing does nothing, then it closes:** macOS didn't let it take the keyboard. Open it again from the menu bar icon rather than the hotkey. `~/Library/Logs/lowkeys/lowkeys.log` says so when this happens.
- **Accents typed with dead keys (⌥E then E) and non-Latin keyboards don't work.** Lowkeys reads raw keys, which is also what keeps paste and dictation out. Say so if asked.
- **The build failed:** the install prints the compiler's error. Usually the Command Line Tools are missing or very old; `xcode-select --install`, or Software Update, fixes it.
