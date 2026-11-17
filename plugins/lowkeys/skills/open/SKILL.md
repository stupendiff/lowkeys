---
name: open
description: Open the Lowkeys writing page right now, full screen, as if the menu bar icon had been clicked. Use when "open lowkeys", "open the typewriter", "I want to write", "start a writing session", "/lowkeys:open".
---

# Lowkeys open

```bash
python3 "${CLAUDE_SKILL_DIR}/../../scripts/lowkeys.py" run
```

The screen becomes the page and takes the keyboard, so say this *before* running it, in one line: Esc closes it, and everything is saved as they type. Then run it and say nothing more; they are writing.

- **"isn't set up on this Mac yet":** offer `/lowkeys:setup`.
- **"Mac-only":** Lowkeys can't run here.

It picks up the page that was open last time. ⌘N inside it starts a clean one.
