---
name: remove
description: Remove Lowkeys from this Mac for good: the menu bar app and its login item. Your writing is never touched, and your settings stay unless you ask. Use when "remove lowkeys", "uninstall the typewriter", "get lowkeys out of my menu bar", "I don't want lowkeys anymore".
---

# Lowkeys remove

Below, `LK` means `python3 "${CLAUDE_SKILL_DIR}/../../scripts/lowkeys.py"`.

1. If they only want it out of the way, offer the lighter options once, and don't push: right-click the **k** and Quit closes it until the next login, and `LK install --login off` stops it starting by itself.
2. Confirm in one line: *"That removes the Lowkeys app and its login item from this Mac. Your writing and your settings stay. Go ahead?"*
3. On a yes, run `LK uninstall`. If the page is open, it is saved and closed first. If they want the settings gone too, run `LK uninstall --all`.
4. Relay what it printed, including where their writing still is, and say `/lowkeys:setup` brings it back.

Never delete, move or edit anything in the writing folder as part of this.
