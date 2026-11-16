import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "setup_deps.py"
SPEC = importlib.util.spec_from_file_location("setup_deps", SCRIPT)
setup_deps = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(setup_deps)


class DependencyArchiveTests(unittest.TestCase):
    def test_archive_url_is_pinned_to_revision(self):
        url = setup_deps.archive_url("https://github.com/libsdl-org/SDL.git", "abc123")
        self.assertEqual(url, "https://github.com/libsdl-org/SDL/archive/abc123.zip")

    def test_rejects_non_github_repository(self):
        with self.assertRaises(ValueError):
            setup_deps.archive_url("https://example.com/SDL.git", "abc123")

    def test_extracts_single_root_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "source.zip"
            destination = root / "out"
            destination.mkdir()
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("SDL-abc123/CMakeLists.txt", "project(SDL)\n")
                output.writestr("SDL-abc123/include/SDL.h", "/* header */\n")
            setup_deps.safe_extract(archive, destination)
            self.assertEqual((destination / "include" / "SDL.h").read_text(), "/* header */\n")
            self.assertTrue((destination / "CMakeLists.txt").is_file())

    def test_rejects_parent_traversal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "bad.zip"
            destination = root / "out"
            destination.mkdir()
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("source/../../outside.txt", "no")
            with self.assertRaises(RuntimeError):
                setup_deps.safe_extract(archive, destination)

    def test_rejects_windows_drive_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "bad.zip"
            destination = root / "out"
            destination.mkdir()
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("source/C:/outside.txt", "no")
            with self.assertRaises(RuntimeError):
                setup_deps.safe_extract(archive, destination)

    def test_rejects_multiple_archive_roots(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "bad.zip"
            destination = root / "out"
            destination.mkdir()
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("one/file.txt", "one")
                output.writestr("two/file.txt", "two")
            with self.assertRaises(RuntimeError):
                setup_deps.safe_extract(archive, destination)

    def test_rejects_symbolic_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "bad.zip"
            destination = root / "out"
            destination.mkdir()
            with zipfile.ZipFile(archive, "w") as output:
                info = zipfile.ZipInfo("source/link")
                info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                output.writestr(info, "../outside")
            with self.assertRaises(RuntimeError):
                setup_deps.safe_extract(archive, destination)


if __name__ == "__main__":
    unittest.main()
