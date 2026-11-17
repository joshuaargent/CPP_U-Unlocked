import http.client
import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "setup_deps.py"
SPEC = importlib.util.spec_from_file_location("setup_deps", SCRIPT)
setup_deps = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(setup_deps)


class FakeResponse:
    def __init__(self, content_length, reads):
        self.headers = {"Content-Length": str(content_length)}
        self.reads = iter(reads)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def read(self, _size):
        value = next(self.reads)
        if isinstance(value, BaseException):
            raise value
        return value

    def close(self):
        pass


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

    def test_materializes_safe_relative_symbolic_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "source.zip"
            destination = root / "out"
            destination.mkdir()
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("source/bin/zstd", "binary placeholder")
                info = zipfile.ZipInfo("source/bin/unzstd")
                info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                output.writestr(info, "zstd")
            setup_deps.safe_extract(archive, destination)
            self.assertEqual((destination / "bin" / "unzstd").read_text(), "binary placeholder")

    def test_rejects_symbolic_link_escape(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "bad.zip"
            destination = root / "out"
            destination.mkdir()
            with zipfile.ZipFile(archive, "w") as output:
                info = zipfile.ZipInfo("source/link")
                info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                output.writestr(info, "../../outside")
            with self.assertRaises(RuntimeError):
                setup_deps.safe_extract(archive, destination)

    def test_retries_interrupted_download_and_replaces_partial_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "source.zip"
            interrupted = FakeResponse(
                6,
                [b"abc", http.client.IncompleteRead(b"def", 3)],
            )
            completed = FakeResponse(6, [b"abcdef", b""])
            with mock.patch.object(
                setup_deps.urllib.request,
                "urlopen",
                side_effect=[interrupted, completed],
            ) as urlopen, mock.patch("time.sleep"):
                setup_deps.download_archive("SDL", "https://example.invalid/source.zip", archive)

            self.assertEqual(urlopen.call_count, 2)
            self.assertEqual(archive.read_bytes(), b"abcdef")

    def test_removes_partial_archive_after_all_download_attempts_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "source.zip"
            failures = [
                FakeResponse(6, [b"abc", b""]),
                FakeResponse(6, [b"abc", b""]),
                FakeResponse(6, [b"abc", b""]),
                FakeResponse(6, [b"abc", b""]),
                FakeResponse(6, [b"abc", b""]),
            ]
            with mock.patch.object(
                setup_deps.urllib.request,
                "urlopen",
                side_effect=failures,
            ) as urlopen, mock.patch("time.sleep"):
                with self.assertRaisesRegex(RuntimeError, "after 5 attempts"):
                    setup_deps.download_archive(
                        "SDL", "https://example.invalid/source.zip", archive
                    )

            self.assertEqual(urlopen.call_count, 5)
            self.assertFalse(archive.exists())

    def test_does_not_retry_permanent_http_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "source.zip"
            missing = setup_deps.urllib.error.HTTPError(
                "https://example.invalid/source.zip", 404, "Not Found", {}, None
            )
            with mock.patch.object(
                setup_deps.urllib.request, "urlopen", side_effect=missing
            ) as urlopen, mock.patch("time.sleep"):
                with self.assertRaisesRegex(RuntimeError, "HTTP 404"):
                    setup_deps.download_archive(
                        "SDL", "https://example.invalid/source.zip", archive
                    )
            self.assertEqual(urlopen.call_count, 1)
            self.assertFalse(archive.exists())

    def test_retries_transient_http_503(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "source.zip"
            unavailable = setup_deps.urllib.error.HTTPError(
                "https://example.invalid/source.zip", 503, "Unavailable", {}, None
            )
            completed = FakeResponse(6, [b"abcdef", b""])
            with mock.patch.object(
                setup_deps.urllib.request,
                "urlopen",
                side_effect=[unavailable, completed],
            ) as urlopen, mock.patch("time.sleep"):
                setup_deps.download_archive(
                    "SDL", "https://example.invalid/source.zip", archive
                )
            self.assertEqual(urlopen.call_count, 2)
            self.assertEqual(archive.read_bytes(), b"abcdef")

    def test_does_not_retry_local_archive_write_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "source.zip"
            response = FakeResponse(6, [b"abcdef", b""])
            original_open = Path.open

            def failing_open(path, *args, **kwargs):
                if path == archive:
                    raise PermissionError("simulated disk permission failure")
                return original_open(path, *args, **kwargs)

            with mock.patch.object(
                setup_deps.urllib.request, "urlopen", return_value=response
            ) as urlopen, mock.patch.object(Path, "open", failing_open):
                with self.assertRaises(PermissionError):
                    setup_deps.download_archive(
                        "SDL", "https://example.invalid/source.zip", archive
                    )
            self.assertEqual(urlopen.call_count, 1)

    def test_rejects_invalid_content_length_without_retry(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "source.zip"
            response = FakeResponse("not-a-number", [b"abcdef"])
            with mock.patch.object(
                setup_deps.urllib.request, "urlopen", return_value=response
            ) as urlopen:
                with self.assertRaisesRegex(RuntimeError, "invalid Content-Length"):
                    setup_deps.download_archive(
                        "SDL", "https://example.invalid/source.zip", archive
                    )
            self.assertEqual(urlopen.call_count, 1)
            self.assertFalse(archive.exists())


if __name__ == "__main__":
    unittest.main()
