"""Tests for scripts/lowkeys.py.

    python3 -m unittest discover plugins/lowkeys/tests

Everything is written under a temp folder, and LOWKEYS_NO_SYSTEM=1 stops the
script compiling, calling launchctl or starting the app.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CLI = os.path.join(ROOT, "scripts", "lowkeys.py")

SANDBOX = tempfile.mkdtemp(prefix="lowkeys-test-")
os.environ["LOWKEYS_HOME"] = os.path.join(SANDBOX, "home")
os.environ["LOWKEYS_PLIST"] = os.path.join(SANDBOX, "agents", "com.stupendiff.lowkeys.plist")
os.environ["LOWKEYS_LOGS"] = os.path.join(SANDBOX, "logs")
os.environ["LOWKEYS_NO_SYSTEM"] = "1"

spec = importlib.util.spec_from_file_location("lowkeys", CLI)
lk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lk)

WRITING = os.path.join(SANDBOX, "writing")


def cli(*args):
    return subprocess.run([sys.executable, CLI] + list(args), capture_output=True, text=True)


def reset():
    for name in ("home", "agents", "logs", "writing"):
        shutil.rmtree(os.path.join(SANDBOX, name), ignore_errors=True)


def tearDownModule():
    shutil.rmtree(SANDBOX, ignore_errors=True)


class Hotkey(unittest.TestCase):
    def test_tidies_names_and_order(self):
        self.assertEqual(lk.parse_hotkey("Option+Control+L"), "ctrl+opt+l")
        self.assertEqual(lk.parse_hotkey("cmd + shift + space"), "shift+cmd+space")
        self.assertEqual(lk.parse_hotkey("alt+ctrl+7"), "ctrl+opt+7")

    def test_off(self):
        for word in ("off", "none", "OFF", ""):
            self.assertEqual(lk.parse_hotkey(word), "off")

    def test_needs_ctrl_or_cmd(self):
        with self.assertRaises(ValueError):
            lk.parse_hotkey("opt+l")
        with self.assertRaises(ValueError):
            lk.parse_hotkey("opt+shift+l")

    def test_needs_one_real_key(self):
        for bad in ("ctrl+opt", "ctrl+l+k", "ctrl+f13", "ctrl+é", "l"):
            with self.assertRaises(ValueError, msg=bad):
                lk.parse_hotkey(bad)

    def test_shown_the_mac_way(self):
        self.assertEqual(lk.show_hotkey("ctrl+opt+l"), "⌃⌥L")
        self.assertEqual(lk.show_hotkey("shift+cmd+space"), "⇧⌘Space")
        self.assertEqual(lk.show_hotkey("off"), "off")


class Versions(unittest.TestCase):
    def test_newer(self):
        self.assertTrue(lk._newer("0.2.0", "0.1.9"))
        self.assertTrue(lk._newer("0.10.0", "0.9.0"))
        self.assertTrue(lk._newer("1.0.0", None))
        self.assertFalse(lk._newer("0.1.0", "0.1.0"))
        self.assertFalse(lk._newer("0.1.0", "0.2.0"))

    def test_plugin_json_has_a_version(self):
        self.assertRegex(lk.plugin_version(), r"^\d+\.\d+\.\d+$")


class Plist(unittest.TestCase):
    def test_starts_at_login_and_is_not_kept_alive(self):
        xml = lk.plist_xml()
        self.assertIn("<string>com.stupendiff.lowkeys</string>", xml)
        self.assertIn("<key>RunAtLoad</key><true/>", xml)
        self.assertNotIn("KeepAlive", xml)
        self.assertIn(os.path.join(os.environ["LOWKEYS_HOME"], "Lowkeys.app", "Contents", "MacOS", "Lowkeys"), xml)
        self.assertIn(os.path.join(os.environ["LOWKEYS_LOGS"], "err.log"), xml)


class Install(unittest.TestCase):
    def setUp(self):
        reset()

    def config(self):
        with open(os.path.join(os.environ["LOWKEYS_HOME"], "config.json")) as f:
            return json.load(f)

    def test_check_before_install(self):
        out = json.loads(cli("check").stdout)
        self.assertFalse(out["installed"])
        self.assertIsNone(out["config"])
        self.assertEqual(out["defaults"]["hotkey"], "ctrl+opt+l")

    def test_dry_run_writes_nothing(self):
        r = cli("install", "--save-dir", WRITING, "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Would build", r.stdout)
        self.assertFalse(os.path.exists(os.environ["LOWKEYS_HOME"]))
        self.assertFalse(os.path.exists(WRITING))

    def test_install_lays_everything_out(self):
        r = cli("install", "--save-dir", WRITING, "--goal-words", "500")
        self.assertEqual(r.returncode, 0, r.stderr)
        home = os.environ["LOWKEYS_HOME"]
        self.assertTrue(os.path.isdir(WRITING))
        self.assertTrue(os.path.exists(os.path.join(home, "app", "Lowkeys.swift")))
        self.assertTrue(os.path.exists(os.path.join(home, "app", "web", "page.html")))
        self.assertTrue(os.path.exists(os.path.join(home, "app", "sounds", "bell.wav")))
        self.assertTrue(os.path.exists(os.path.join(home, "Lowkeys.app", "Contents", "MacOS", "Lowkeys")))
        with open(os.path.join(home, "VERSION")) as f:
            self.assertEqual(f.read().strip(), lk.plugin_version())
        self.assertTrue(os.path.exists(os.environ["LOWKEYS_PLIST"]))
        cfg = self.config()
        self.assertEqual(cfg["save_dir"], WRITING)
        self.assertEqual(cfg["goal"], {"words": 500})
        self.assertEqual(cfg["hotkey"], "ctrl+opt+l")
        self.assertIn("500 words", r.stdout)
        self.assertTrue(json.loads(cli("check").stdout)["installed"])

    def test_rerun_changes_only_what_it_is_told(self):
        cli("install", "--save-dir", WRITING, "--goal-minutes", "20", "--sounds", "off")
        r = cli("install", "--hotkey", "cmd+shift+k")
        self.assertEqual(r.returncode, 0, r.stderr)
        cfg = self.config()
        self.assertEqual(cfg["hotkey"], "shift+cmd+k")
        self.assertEqual(cfg["save_dir"], WRITING)
        self.assertEqual(cfg["goal"], {"minutes": 20})
        self.assertFalse(cfg["sounds"])
        self.assertIn("updated", r.stdout)

    def test_goal_off_and_none_values(self):
        cli("install", "--save-dir", WRITING, "--goal-words", "300", "--font", "Menlo")
        cli("install", "--goal", "off", "--font", "none")
        cfg = self.config()
        self.assertIsNone(cfg["goal"])
        self.assertIsNone(cfg["font"])

    def test_login_off_removes_the_login_item(self):
        cli("install", "--save-dir", WRITING)
        self.assertTrue(os.path.exists(os.environ["LOWKEYS_PLIST"]))
        cli("install", "--login", "off")
        self.assertFalse(os.path.exists(os.environ["LOWKEYS_PLIST"]))
        self.assertFalse(self.config()["login"])

    def test_bad_values_are_refused_and_nothing_is_written(self):
        for flags in (["--hotkey", "opt+l"], ["--goal-words", "0"], ["--volume", "3"], ["--margin", "5"]):
            r = cli("install", "--save-dir", WRITING, *flags)
            self.assertNotEqual(r.returncode, 0, flags)
            self.assertFalse(os.path.exists(os.environ["LOWKEYS_HOME"]), flags)

    def test_run_before_install_says_so(self):
        r = cli("run")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("/lowkeys:setup", r.stderr)


class Sync(unittest.TestCase):
    def setUp(self):
        reset()

    def version_file(self):
        return os.path.join(os.environ["LOWKEYS_HOME"], "VERSION")

    def test_nothing_installed_nothing_done(self):
        self.assertIsNone(lk.sync())
        self.assertFalse(os.path.exists(os.environ["LOWKEYS_HOME"]))

    def test_same_version_nothing_done(self):
        cli("install", "--save-dir", WRITING)
        self.assertIsNone(lk.sync())

    def test_older_install_is_brought_forward(self):
        cli("install", "--save-dir", WRITING)
        with open(self.version_file(), "w") as f:
            f.write("0.0.1\n")
        marker = os.path.join(os.environ["LOWKEYS_HOME"], "app", "stale.txt")
        with open(marker, "w") as f:
            f.write("old")
        msg = lk.sync()
        self.assertIn("0.0.1", msg)
        self.assertIn(lk.plugin_version(), msg)
        self.assertFalse(os.path.exists(marker))
        with open(self.version_file()) as f:
            self.assertEqual(f.read().strip(), lk.plugin_version())

    def test_never_goes_backwards(self):
        cli("install", "--save-dir", WRITING)
        with open(self.version_file(), "w") as f:
            f.write("99.0.0\n")
        self.assertIsNone(lk.sync())
        with open(self.version_file()) as f:
            self.assertEqual(f.read().strip(), "99.0.0")

    def test_quiet_sync_prints_nothing_to_stdout(self):
        cli("install", "--save-dir", WRITING)
        with open(self.version_file(), "w") as f:
            f.write("0.0.1\n")
        r = cli("sync", "--quiet")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")


class Uninstall(unittest.TestCase):
    def setUp(self):
        reset()

    def test_removes_the_app_and_keeps_settings_and_writing(self):
        cli("install", "--save-dir", WRITING)
        page = os.path.join(WRITING, "2026-01-01-0900.md")
        with open(page, "w") as f:
            f.write("words\n")
        r = cli("uninstall")
        self.assertEqual(r.returncode, 0, r.stderr)
        home = os.environ["LOWKEYS_HOME"]
        self.assertFalse(os.path.exists(os.path.join(home, "Lowkeys.app")))
        self.assertFalse(os.path.exists(os.path.join(home, "app")))
        self.assertFalse(os.path.exists(os.environ["LOWKEYS_PLIST"]))
        self.assertTrue(os.path.exists(os.path.join(home, "config.json")))
        self.assertTrue(os.path.exists(page))
        self.assertIn("untouched", r.stdout)

    def test_all_removes_settings_but_never_the_writing(self):
        cli("install", "--save-dir", WRITING)
        page = os.path.join(WRITING, "page.md")
        with open(page, "w") as f:
            f.write("words\n")
        cli("uninstall", "--all")
        self.assertFalse(os.path.exists(os.environ["LOWKEYS_HOME"]))
        self.assertTrue(os.path.exists(page))

    def test_uninstall_when_nothing_is_there(self):
        r = cli("uninstall")
        self.assertEqual(r.returncode, 0)
        self.assertIn("wasn't installed", r.stdout)


class Shipped(unittest.TestCase):
    """What the plugin carries has to be there for the build to work."""

    def test_app_files(self):
        for rel in ("Lowkeys.swift", "build.sh", "web/page.html", "web/page.css", "web/page.js",
                    "web/model.js", "fonts/CourierPrime-Regular.ttf", "fonts/OFL.txt"):
            self.assertTrue(os.path.exists(os.path.join(ROOT, "app", rel)), rel)

    def test_every_sound_the_app_asks_for(self):
        for name in ("key1", "key2", "key3", "key4", "space", "strike", "return", "bell", "goal"):
            self.assertTrue(os.path.exists(os.path.join(ROOT, "app", "sounds", name + ".wav")), name)

    def test_sounds_come_out_the_same_every_time(self):
        spec = importlib.util.spec_from_file_location("make_sounds", os.path.join(ROOT, "tools", "make_sounds.py"))
        ms = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ms)
        out = os.path.join(SANDBOX, "sounds")
        ms.main(out)
        for name in ("key1", "bell"):
            with open(os.path.join(out, name + ".wav"), "rb") as a, \
                 open(os.path.join(ROOT, "app", "sounds", name + ".wav"), "rb") as b:
                self.assertEqual(a.read(), b.read(), name)


if __name__ == "__main__":
    unittest.main()
