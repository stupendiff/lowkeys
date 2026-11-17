#!/usr/bin/env python3
"""Sets up, changes and removes Lowkeys, the typewriter writing mode.

    lowkeys.py check
    lowkeys.py install [--save-dir DIR] [--hotkey ctrl+opt+l|off]
                       [--goal-words N | --goal-minutes N | --goal off]
                       [--sounds on|off] [--volume 0..1] [--sounds-dir DIR|none]
                       [--font NAME|none] [--margin N] [--login on|off]
                       [--rebuild] [--dry-run]
    lowkeys.py run
    lowkeys.py sync [--quiet]
    lowkeys.py uninstall [--all]

Stdlib only. install copies the app's source out of the plugin (the plugin
cache path changes with every version), builds it there with swiftc, and
starts it. A re-run changes only what it is told: `install --hotkey off`
touches nothing else.

Where things go:
    your writing      ~/Documents/Lowkeys/                  (--save-dir)
    app and settings  ~/Library/Application Support/lowkeys/
    start at login    ~/Library/LaunchAgents/com.stupendiff.lowkeys.plist
    logs              ~/Library/Logs/lowkeys/

For tests: LOWKEYS_HOME, LOWKEYS_PLIST and LOWKEYS_LOGS move everything it
writes, and LOWKEYS_NO_SYSTEM=1 stops it compiling, calling launchctl or
starting anything.
"""
import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_APP = os.path.normpath(os.path.join(HERE, "..", "app"))
PLUGIN_JSON = os.path.normpath(os.path.join(HERE, "..", ".claude-plugin", "plugin.json"))

LABEL = "com.stupendiff.lowkeys"
HOME = os.environ.get("LOWKEYS_HOME") or os.path.expanduser("~/Library/Application Support/lowkeys")
PLIST = os.environ.get("LOWKEYS_PLIST") or os.path.expanduser("~/Library/LaunchAgents/%s.plist" % LABEL)
LOGS = os.environ.get("LOWKEYS_LOGS") or os.path.expanduser("~/Library/Logs/lowkeys")
SYSTEM = os.environ.get("LOWKEYS_NO_SYSTEM") != "1"

APP_DIR = os.path.join(HOME, "app")                 # the source, copied out of the plugin
APP = os.path.join(HOME, "Lowkeys.app")             # what build.sh makes from it
BINARY = os.path.join(APP, "Contents", "MacOS", "Lowkeys")
CONFIG = os.path.join(HOME, "config.json")
VERSION = os.path.join(HOME, "VERSION")
LOCK = os.path.join(HOME, "writing.lock")           # present while the page is open

DEFAULTS = {
    "save_dir": "~/Documents/Lowkeys",
    "hotkey": "ctrl+opt+l",
    "goal": None,            # None, {"words": N} or {"minutes": N}
    "sounds": True,
    "volume": 0.8,
    "sounds_dir": None,      # a folder of your own recordings; see tools/make_sounds.py
    "font": None,            # any installed font; None is the bundled Courier Prime
    "margin": 62,            # columns before the carriage returns by itself
    "login": True,
}

MODIFIERS = {"ctrl": "ctrl", "control": "ctrl", "opt": "opt", "option": "opt", "alt": "opt",
             "cmd": "cmd", "command": "cmd", "shift": "shift"}
MOD_ORDER = ["ctrl", "opt", "shift", "cmd"]


# ---- small things ---------------------------------------------------------

def plugin_version():
    try:
        with open(PLUGIN_JSON) as f:
            return json.load(f).get("version", "0.0.0")
    except (OSError, ValueError):
        return "0.0.0"


def installed_version():
    try:
        with open(VERSION) as f:
            return f.read().strip() or None
    except OSError:
        return None


def _newer(a, b):
    """True when version a is newer than b. A missing b counts as older."""
    def parts(v):
        out = []
        for p in str(v).replace("-", ".").replace("+", ".").split("."):
            out.append(int(p) if p.isdigit() else 0)
        return out
    if not b:
        return True
    return parts(a) > parts(b)


def installed():
    return os.path.exists(BINARY) and os.path.exists(CONFIG)


def load_config():
    cfg = dict(DEFAULTS)
    try:
        with open(CONFIG) as f:
            saved = json.load(f)
        if isinstance(saved, dict):
            cfg.update(saved)
    except (OSError, ValueError):
        pass
    return cfg


def save_config(cfg):
    os.makedirs(HOME, exist_ok=True)
    tmp = CONFIG + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, CONFIG)


def parse_hotkey(text):
    """Tidies a hotkey such as 'Control+Option+L' to 'ctrl+opt+l'. 'off' turns it off.

    macOS refuses global hotkeys made of Option or Shift alone, so one of
    Control or Command has to be in it.
    """
    text = str(text).strip().lower()
    if text in ("off", "none", ""):
        return "off"
    mods, key = set(), None
    for part in text.replace(" ", "").split("+"):
        if part in MODIFIERS:
            mods.add(MODIFIERS[part])
        elif key is None and (part == "space" or (len(part) == 1 and (part.isalpha() or part.isdigit()) and part.isascii())):
            key = part
        else:
            raise ValueError("can't read the hotkey %r. Use something like ctrl+opt+l: "
                             "modifiers (ctrl, opt, shift, cmd) and one letter, digit or 'space'." % text)
    if key is None:
        raise ValueError("the hotkey %r has no key in it. Try ctrl+opt+l." % text)
    if not mods & {"ctrl", "cmd"}:
        raise ValueError("the hotkey needs ctrl or cmd in it: macOS won't take %r." % text)
    return "+".join([m for m in MOD_ORDER if m in mods] + [key])


def show_hotkey(hk):
    if hk == "off":
        return "off"
    signs = {"ctrl": "⌃", "opt": "⌥", "shift": "⇧", "cmd": "⌘"}
    parts = hk.split("+")
    return "".join(signs[p] for p in parts[:-1]) + ("Space" if parts[-1] == "space" else parts[-1].upper())


def show_goal(goal):
    if not goal:
        return "off"
    if goal.get("words"):
        return "%d words a sitting" % goal["words"]
    return "%d minutes a sitting" % goal["minutes"]


def merge_config(old, args):
    """The saved settings with only the flags that were given laid over them."""
    cfg = dict(old)
    if args.save_dir is not None:
        cfg["save_dir"] = args.save_dir
    if args.hotkey is not None:
        cfg["hotkey"] = parse_hotkey(args.hotkey)
    if args.goal_words is not None:
        if args.goal_words < 1:
            raise ValueError("--goal-words needs a number above zero.")
        cfg["goal"] = {"words": args.goal_words}
    elif args.goal_minutes is not None:
        if args.goal_minutes < 1:
            raise ValueError("--goal-minutes needs a number above zero.")
        cfg["goal"] = {"minutes": args.goal_minutes}
    elif args.goal is not None:
        cfg["goal"] = None
    if args.sounds is not None:
        cfg["sounds"] = args.sounds == "on"
    if args.volume is not None:
        if not 0 <= args.volume <= 1:
            raise ValueError("--volume goes from 0 to 1.")
        cfg["volume"] = args.volume
    if args.sounds_dir is not None:
        cfg["sounds_dir"] = None if args.sounds_dir.lower() == "none" else args.sounds_dir
    if args.font is not None:
        cfg["font"] = None if args.font.lower() == "none" else args.font
    if args.margin is not None:
        if not 20 <= args.margin <= 200:
            raise ValueError("--margin goes from 20 to 200 columns.")
        cfg["margin"] = args.margin
    if args.login is not None:
        cfg["login"] = args.login == "on"
    return cfg


def plist_xml():
    """Starts the menu bar app at login. It is not kept alive: Quit means quit."""
    def esc(s):
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array><string>%s</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict>
</plist>
""" % (LABEL, esc(BINARY), esc(os.path.join(LOGS, "out.log")), esc(os.path.join(LOGS, "err.log")))


# ---- things that touch the Mac --------------------------------------------

def domain():
    return "gui/%d" % os.getuid()


def launchctl(*args):
    if not SYSTEM:
        return subprocess.CompletedProcess(args, 0, "", "")
    return subprocess.run(["launchctl"] + list(args), capture_output=True, text=True)


def have_swiftc():
    return shutil.which("swiftc") is not None


def is_running():
    if not SYSTEM:
        return False
    r = subprocess.run(["pgrep", "-f", BINARY], capture_output=True, text=True)
    return r.returncode == 0


def writing():
    """True while the page is open. A lock left by a crash doesn't count."""
    return os.path.exists(LOCK) and is_running()


def copy_app():
    if os.path.isdir(APP_DIR):
        shutil.rmtree(APP_DIR)
    shutil.copytree(SRC_APP, APP_DIR, ignore=shutil.ignore_patterns("build", ".DS_Store"))


def build(version):
    """Compiles Lowkeys.app in HOME. Returns an error string, or None."""
    if not SYSTEM:
        os.makedirs(os.path.dirname(BINARY), exist_ok=True)
        with open(BINARY, "w") as f:
            f.write("")
        return None
    r = subprocess.run(["bash", os.path.join(APP_DIR, "build.sh"), HOME, version],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return (r.stderr or r.stdout).strip() or "build.sh failed"
    return None


def stop_app():
    """Asks the app to save and quit, and makes sure it has."""
    launchctl("bootout", "%s/%s" % (domain(), LABEL))
    if not SYSTEM or not is_running():
        return
    subprocess.run([BINARY, "--quit"], capture_output=True)
    for _ in range(30):
        if not is_running():
            return
        time.sleep(0.1)
    subprocess.run(["pkill", "-f", BINARY], capture_output=True)


def start_app(login):
    """Starts the menu bar app, through launchd when it should also start at login."""
    if login:
        os.makedirs(os.path.dirname(PLIST), exist_ok=True)
        os.makedirs(LOGS, exist_ok=True)
        with open(PLIST, "w") as f:
            f.write(plist_xml())
        launchctl("bootout", "%s/%s" % (domain(), LABEL))
        launchctl("enable", "%s/%s" % (domain(), LABEL))
        r = launchctl("bootstrap", domain(), PLIST)
        if r.returncode != 0:
            return "launchd wouldn't load it: %s" % (r.stderr.strip() or r.returncode)
    else:
        if os.path.exists(PLIST):
            launchctl("bootout", "%s/%s" % (domain(), LABEL))
            os.remove(PLIST)
        if SYSTEM:
            subprocess.run(["open", "-g", APP], capture_output=True)
    return None


def tell_app(flag):
    if SYSTEM and is_running():
        subprocess.run([BINARY, flag], capture_output=True)


# ---- commands -------------------------------------------------------------

def cmd_check(args):
    cfg = load_config()
    print(json.dumps({
        "macos": platform.system() == "Darwin",
        "swiftc": have_swiftc(),
        "installed": installed(),
        "running": is_running(),
        "plugin_version": plugin_version(),
        "installed_version": installed_version(),
        "config": cfg if installed() else None,
        "defaults": DEFAULTS,
        "paths": {"writing": os.path.expanduser(cfg["save_dir"]), "app": HOME, "login": PLIST, "logs": LOGS},
    }, indent=2))


def summary(cfg):
    return "Writing goes to %s. Hotkey %s. Goal %s. Sounds %s. Starts at login: %s." % (
        cfg["save_dir"], show_hotkey(cfg["hotkey"]), show_goal(cfg["goal"]),
        "on" if cfg["sounds"] else "off", "yes" if cfg["login"] else "no")


def cmd_install(args):
    if platform.system() != "Darwin":
        sys.exit("Lowkeys is Mac-only.")
    try:
        cfg = merge_config(load_config(), args)
    except ValueError as e:
        sys.exit(str(e))
    version = plugin_version()
    need_build = args.rebuild or not os.path.exists(BINARY) or installed_version() != version

    if args.dry_run:
        print(summary(cfg))
        print("Would %s the app in %s%s." % (
            "build" if need_build else "keep", HOME,
            " (about 10 seconds, needs swiftc)" if need_build else ""))
        if cfg["login"]:
            print("Would write %s so it starts at login." % PLIST)
        else:
            print("Would not start it at login.")
        return

    if need_build and SYSTEM and not have_swiftc():
        sys.exit("Lowkeys is built on your Mac and needs the Xcode Command Line Tools. "
                 "Run: xcode-select --install   then set it up again.")

    os.makedirs(HOME, exist_ok=True)
    os.makedirs(os.path.expanduser(cfg["save_dir"]), exist_ok=True)
    was_login = load_config().get("login") if installed() else None
    if need_build:
        stop_app()
        copy_app()
        err = build(version)
        if err:
            sys.exit("The build failed:\n%s" % err)
        with open(VERSION, "w") as f:
            f.write(version + "\n")
    save_config(cfg)

    if need_build or was_login != cfg["login"] or not is_running():
        if not need_build:
            stop_app()
        err = start_app(cfg["login"])
        if err:
            sys.exit(err)
    else:
        tell_app("--reload")

    print("Lowkeys %s is %s." % (version, "installed" if need_build else "updated"))
    print(summary(cfg))
    print("Click the k in the menu bar%s to write." % (
        "" if cfg["hotkey"] == "off" else ", or press %s," % show_hotkey(cfg["hotkey"])))


def cmd_run(args):
    if platform.system() != "Darwin":
        sys.exit("Lowkeys is Mac-only.")
    if not installed():
        sys.exit("Lowkeys isn't set up on this Mac yet. Run /lowkeys:setup.")
    if SYSTEM:
        if is_running():
            subprocess.run([BINARY, "--open"], capture_output=True)
        else:
            subprocess.run(["open", APP, "--args", "--open"], capture_output=True)
    print("Opened the page. Esc closes it; everything is saved as you type.")


def sync(quiet=False):
    """Brings the installed app up to the plugin's version. Only ever moves
    forward, so an older copy of the plugin still in the cache can't undo a
    newer install. Waits for another time if the page is open."""
    if not installed():
        return None
    have, want = installed_version(), plugin_version()
    if not _newer(want, have):
        return None
    if SYSTEM and not have_swiftc():
        return None
    if writing():
        return None
    cfg = load_config()
    stop_app()
    copy_app()
    err = build(want)
    if err:
        return "Couldn't update Lowkeys to %s: %s" % (want, err.splitlines()[-1] if err else "")
    with open(VERSION, "w") as f:
        f.write(want + "\n")
    start_app(cfg.get("login", True))
    return "Updated Lowkeys from %s to %s." % (have or "an unknown version", want)


def cmd_sync(args):
    try:
        msg = sync()
    except Exception as e:      # a hook must never get in the way of a session
        msg = None if args.quiet else "sync failed: %s" % e
    if msg and not args.quiet:
        print(msg)
    elif msg:
        print(msg, file=sys.stderr)


def cmd_uninstall(args):
    stop_app()
    removed = []
    if os.path.exists(PLIST):
        os.remove(PLIST)
        removed.append("the login item")
    for path, what in ((APP, "the app"), (APP_DIR, None), (VERSION, None), (LOCK, None)):
        if os.path.isdir(path):
            shutil.rmtree(path)
        elif os.path.exists(path):
            os.remove(path)
        else:
            continue
        if what:
            removed.append(what)
    cfg = load_config()
    if args.all and os.path.isdir(HOME):
        shutil.rmtree(HOME)
        removed.append("its settings")
    if not removed:
        print("Lowkeys wasn't installed.")
    else:
        print("Removed %s." % ", ".join(removed))
    print("Your writing in %s is untouched." % cfg["save_dir"])


def main(argv=None):
    p = argparse.ArgumentParser(description="Set up, change or remove Lowkeys.")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("check").set_defaults(fn=cmd_check)

    i = sub.add_parser("install")
    i.add_argument("--save-dir")
    i.add_argument("--hotkey")
    i.add_argument("--goal-words", type=int)
    i.add_argument("--goal-minutes", type=int)
    i.add_argument("--goal", choices=["off"])
    i.add_argument("--sounds", choices=["on", "off"])
    i.add_argument("--volume", type=float)
    i.add_argument("--sounds-dir")
    i.add_argument("--font")
    i.add_argument("--margin", type=int)
    i.add_argument("--login", choices=["on", "off"])
    i.add_argument("--rebuild", action="store_true")
    i.add_argument("--dry-run", action="store_true")
    i.set_defaults(fn=cmd_install)

    sub.add_parser("run").set_defaults(fn=cmd_run)

    s = sub.add_parser("sync")
    s.add_argument("--quiet", action="store_true")
    s.set_defaults(fn=cmd_sync)

    u = sub.add_parser("uninstall")
    u.add_argument("--all", action="store_true")
    u.set_defaults(fn=cmd_uninstall)

    args = p.parse_args(argv)
    if args.cmd in ("check", "run"):
        # Keep the installed app in step with the plugin on the way past.
        try:
            msg = sync()
            if msg:
                print(msg, file=sys.stderr)
        except Exception:
            pass
    args.fn(args)


if __name__ == "__main__":
    main()
