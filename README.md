# Lowkeys

A typewriter writing mode for your Mac. It sits in the menu bar as a small **k**. Click it, or press a hotkey, and the whole screen becomes paper.

- **The paper moves, not the caret.** The line you're typing sits near the bottom of the screen and slides left under a fixed typing point. Near the margin a bell rings; then the carriage returns and the line rises.
- **Backspace doesn't erase.** It strikes the letter through and you carry on. The struck letters stay on the page while you write and are left out of what's saved.
- **Keyboard only.** No pointer, nothing to click, no paste, no dictation. Other displays go dark.
- **Nothing to lose.** The page is saved as you type, as a plain `.md` file. ⌘P writes a PDF beside it in an ordinary reading font.
- **Sounds.** A click per key, a duller one for space, the bell, the carriage coming back.

It is a Claude Code plugin: Claude builds the app on your Mac and sets it up.

## Install

```
/plugin marketplace add stupendiff/lowkeys
/plugin install lowkeys@lowkeys
```

Then run `/lowkeys:setup`. It asks where to save your writing, which hotkey you want, and whether you want a goal for each sitting, then builds the app (about ten seconds, no internet needed).

| Command | What it does | Or just say |
|---|---|---|
| `/lowkeys:setup` | Install, or change the folder, hotkey, goal, sounds, font | "set up lowkeys", "change the lowkeys hotkey" |
| `/lowkeys:open` | Open the page now | "open the typewriter" |
| `/lowkeys:remove` | Remove the app and its login item | "uninstall lowkeys" |

## Keys

| Key | What it does |
|---|---|
| ⌃⌥L (or click the **k**) | Open the page |
| Esc, ⌘Q or ⌘W | Close the page. It is always saved first. |
| ⌘S | Save now |
| ⌘P | Write a PDF beside the text file |
| ⌘N | Put this page away and start a clean one |
| ⌫ | Strike the last letter |
| ⌥⌫ | Strike the last word |
| Hold ⌥ | Show the word count and minutes until you let go |

Switching to another app also closes the page (saved). Opening Lowkeys again picks up the page you left, until ⌘N starts a new one. Right-click the **k** for New page, Show writing folder, Sounds and Quit.

## A goal for each sitting

Optional: a number of words or minutes, set in `/lowkeys:setup`. Nothing is shown while you write. When you get there, two bells ring, once.

## Requirements

- macOS 13 or newer.
- Xcode Command Line Tools (`xcode-select --install`), because the app is compiled on your Mac. If you have `git`, you almost certainly have them.
- Python 3.9 or newer for the setup script. Nothing is installed with pip.

## Where things go

| What | Where | Change it |
|---|---|---|
| Your writing (`.md` and `.pdf`) | `~/Documents/Lowkeys/` | `/lowkeys:setup`, or `--save-dir` |
| The app, `config.json`, `state.json` | `~/Library/Application Support/lowkeys/` | |
| Start at login | `~/Library/LaunchAgents/com.stupendiff.lowkeys.plist` | `--login off` |
| Logs | `~/Library/Logs/lowkeys/` | |

Nothing leaves your Mac. To remove it by hand: `python3 plugins/lowkeys/scripts/lowkeys.py uninstall --all`. Your writing is never deleted.

`config.json` can be edited by hand:

```json
{
  "save_dir": "~/Documents/Lowkeys",
  "hotkey": "ctrl+opt+l",
  "goal": { "words": 500 },
  "sounds": true,
  "volume": 0.8,
  "sounds_dir": null,
  "font": null,
  "margin": 62,
  "login": true
}
```

- `goal` is `null`, `{"words": N}` or `{"minutes": N}`.
- `font` is any font installed on your Mac; `null` is the bundled Courier Prime.
- `margin` is how many columns a line runs before the carriage returns by itself.
- `sounds_dir` is a folder of your own recordings (below).

## Your own sounds

The bundled sounds are synthesized by `tools/make_sounds.py`, so the repo carries no recordings. Recordings of a real machine sound better. Put files with these names in a folder and point `sounds_dir` at it:

`key1`, `key2`, … (one is picked at random for each letter), `space`, `strike`, `return`, `bell`, `goal`, as `.wav`, `.aiff`, `.m4a` or `.mp3`. Anything you leave out falls back to the bundled sound.

## What it doesn't do

- Accents typed with dead keys (⌥E then E) and non-Latin input methods. Lowkeys reads raw keys; that is also what keeps paste and dictation out.
- Backspace across lines. Once the carriage has returned, that line is on the paper.
- Dark mode. It is paper.

## Development

```
plugins/lowkeys/
  app/Lowkeys.swift       the whole native app (menu bar, window, keys, sounds, files, PDF)
  app/build.sh            swiftc → Lowkeys.app, ad-hoc signed
  app/web/model.js        the text model: lines, margin, strikes, clean text
  app/web/page.*          the paper; draws what the model says
  scripts/lowkeys.py      check | install | run | sync | uninstall
  tools/make_sounds.py    writes app/sounds/*.wav
```

```bash
node --test plugins/lowkeys/tests/model.test.mjs
python3 -m unittest discover plugins/lowkeys/tests
```

- Open `plugins/lowkeys/app/web/page.html` in a browser to tune the look and motion. It reads the keyboard itself there, silently, and saves nothing.
- `app/build.sh /tmp/lk 0.0.0` builds a copy without installing it. `Lowkeys --selftest <folder>` on that copy types a few lines by itself, saves, prints, closes and reopens, then writes `report.json` and three screenshots to the folder. Point `LOWKEYS_HOME` at a scratch folder first so it uses its own config.

## Credits

- [Courier Prime](https://github.com/quoteunquoteapps/CourierPrime) by Alan Dague-Greene for Quote-Unquote Apps, under the SIL Open Font License 1.1 (`app/fonts/OFL.txt`).
