#!/usr/bin/env python3
"""Fetch the exact dependency revisions in dependencies.lock.json without requiring Git."""

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
MARKER = ".u-unlocked-revision"


def archive_url(repository_url, revision):
    prefix = "https://github.com/"
    if not repository_url.startswith(prefix):
        raise ValueError(f"Only pinned GitHub repositories are supported: {repository_url}")
    repository = repository_url[len(prefix):].removesuffix(".git").strip("/")
    if not repository or repository.count("/") != 1:
        raise ValueError(f"Invalid GitHub repository URL: {repository_url}")
    return f"{prefix}{repository}/archive/{revision}.zip"


def safe_extract(archive, destination):
    """Extract a GitHub source archive without allowing traversal or external links."""
    with zipfile.ZipFile(archive) as source:
        members = source.infolist()
        if not members:
            raise RuntimeError("The dependency archive is empty.")
        if len(members) > 200000:
            raise RuntimeError("The dependency archive contains too many entries.")

        roots = set()
        seen = set()
        expanded_size = 0
        symlinks = []
        normalized_members = []
        for member in members:
            name = member.filename.replace("\\", "/")
            path = PurePosixPath(name)
            if path.is_absolute() or not path.parts or any(
                part in ("", ".", "..") or ":" in part for part in path.parts
            ):
                raise RuntimeError(f"Unsafe dependency archive path: {member.filename}")

            canonical = "/".join(path.parts).casefold()
            if canonical in seen:
                raise RuntimeError(f"Dependency archive contains a duplicate path: {member.filename}")
            seen.add(canonical)
            roots.add(path.parts[0])
            expanded_size += member.file_size
            if expanded_size > 2 * 1024 * 1024 * 1024:
                raise RuntimeError("The dependency archive exceeds the 2 GiB expanded-size limit.")

            mode = (member.external_attr >> 16) & 0xFFFF
            if stat.S_ISLNK(mode):
                symlinks.append((member, path.parts[1:]))
            else:
                normalized_members.append((member, path.parts[1:]))

        if len(roots) != 1:
            raise RuntimeError("The dependency archive does not contain exactly one source root.")

        root = next(iter(roots))
        for member, relative in normalized_members:
            if not relative:
                continue
            target = destination.joinpath(*relative)
            resolved_parent = target.parent.resolve()
            if destination.resolve() not in (resolved_parent, *resolved_parent.parents):
                raise RuntimeError(f"Dependency archive escaped its extraction directory: {member.filename}")
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open(member, "r") as incoming, target.open("wb") as outgoing:
                shutil.copyfileobj(incoming, outgoing, length=1024 * 1024)

        # GitHub source archives preserve Unix symlinks as ZIP entries. Windows
        # builds do not need filesystem symlinks, so materialize safe relative
        # links as ordinary copies after their targets have been extracted.
        pending = list(symlinks)
        while pending:
            remaining = []
            progressed = False
            for member, relative in pending:
                if not relative:
                    raise RuntimeError(f"Invalid root-level symlink in dependency archive: {member.filename}")
                raw_target = source.read(member).decode("utf-8", errors="strict").strip()
                link_target = PurePosixPath(raw_target.replace("\\", "/"))
                if not raw_target or link_target.is_absolute() or any(":" in part for part in link_target.parts):
                    raise RuntimeError(f"Unsafe symbolic link target in dependency archive: {member.filename}")
                stack = list(relative[:-1])
                for part in link_target.parts:
                    if part in ("", "."):
                        continue
                    if part == "..":
                        if not stack:
                            raise RuntimeError(f"Symbolic link escapes dependency source root: {member.filename}")
                        stack.pop()
                    else:
                        stack.append(part)
                if not stack:
                    raise RuntimeError(f"Symbolic link resolves to the source root: {member.filename}")

                link_path = destination.joinpath(*relative)
                resolved_target = destination.joinpath(*stack)
                if not resolved_target.exists():
                    remaining.append((member, relative))
                    continue
                if resolved_target.is_dir():
                    if link_path == resolved_target or resolved_target in link_path.parents:
                        raise RuntimeError(f"Recursive directory symlink in dependency archive: {member.filename}")
                    shutil.copytree(resolved_target, link_path)
                else:
                    link_path.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(resolved_target, link_path)
                progressed = True
            if not progressed and remaining:
                unresolved = ", ".join(member.filename for member, _ in remaining[:5])
                raise RuntimeError(f"Unresolved symbolic links in dependency archive: {unresolved}")
            pending = remaining

def download_archive(name, url, archive):
    """Download a pinned archive with bounded retries for transient network failures."""
    import http.client
    import time
    import urllib.error

    class TransientReadError(Exception):
        pass

    attempts = 5
    last_error = None
    for attempt in range(1, attempts + 1):
        request = urllib.request.Request(
            url,
            headers={"User-Agent": "U-Unlocked-Dependency-Bootstrap", "Accept": "application/zip"}
        )
        try:
            response = urllib.request.urlopen(request, timeout=90)
        except urllib.error.HTTPError as error:
            if error.code not in (408, 425, 429) and not 500 <= error.code <= 599:
                error.close()
                archive.unlink(missing_ok=True)
                raise RuntimeError(
                    f"{name}: GitHub rejected the pinned dependency download (HTTP {error.code})."
                ) from error
            last_error = error
            error.close()
        except (urllib.error.URLError, http.client.RemoteDisconnected,
                TimeoutError, ConnectionError) as error:
            last_error = error
        else:
            try:
                with response:
                    content_length = response.headers.get("Content-Length")
                    try:
                        expected = int(content_length) if content_length else None
                    except ValueError as error:
                        raise RuntimeError(
                            f"{name}: server returned an invalid Content-Length header."
                        ) from error
                    if expected is not None and (expected < 0 or expected > 512 * 1024 * 1024):
                        raise RuntimeError(
                            f"{name}: compressed dependency archive exceeds the 512 MiB download limit."
                        )

                    total = 0
                    with archive.open("wb") as output:
                        while True:
                            try:
                                block = response.read(1024 * 1024)
                            except (http.client.IncompleteRead, http.client.RemoteDisconnected,
                                    TimeoutError, ConnectionError, OSError) as error:
                                raise TransientReadError from error
                            if not block:
                                break
                            total += len(block)
                            if total > 512 * 1024 * 1024:
                                raise RuntimeError(
                                    f"{name}: compressed dependency archive exceeds the 512 MiB download limit."
                                )
                            output.write(block)
                    if expected is not None and total != expected:
                        raise http.client.IncompleteRead(b"", expected - total)
                    if total == 0:
                        raise RuntimeError(f"{name}: downloaded dependency archive is empty.")
                return
            except TransientReadError as error:
                last_error = error.__cause__
            except (http.client.IncompleteRead, http.client.RemoteDisconnected,
                    TimeoutError, ConnectionError, urllib.error.URLError) as error:
                last_error = error

        try:
            archive.unlink(missing_ok=True)
        except OSError as error:
            raise RuntimeError(
                f"{name}: cannot remove an incomplete dependency archive: {error}"
            ) from error

        if attempt == attempts:
            break
        delay = min(2 ** (attempt - 1), 16)
        print(
            f"{name}: transient download failure on attempt {attempt}/{attempts} "
            f"({last_error}); retrying in {delay}s",
            flush=True
        )
        time.sleep(delay)

    raise RuntimeError(
        f"{name}: unable to download pinned source after {attempts} attempts: {last_error}"
    ) from last_error


def fetch_dependency(name, dependency):
    destination = ROOT / "third_party" / name
    revision = dependency["revision"]
    if destination.exists():
        marker = destination / MARKER
        if marker.is_file() and marker.read_text(encoding="ascii").strip() == revision:
            print(f"{name}: {revision} (verified archive marker)")
            return
        git_dir = destination / ".git"
        if git_dir.exists():
            import subprocess
            actual = subprocess.run(
                ["git", "-C", str(destination), "rev-parse", "HEAD"],
                check=True, capture_output=True, text=True
            ).stdout.strip()
            if actual == revision:
                print(f"{name}: {actual} (verified Git checkout)")
                return
        raise RuntimeError(
            f"Refusing to replace existing dependency directory {destination}: "
            f"it is not marked as the pinned revision {revision}. Remove it manually after checking local changes."
        )

    destination.parent.mkdir(parents=True, exist_ok=True)
    url = archive_url(dependency["url"], revision)
    with tempfile.TemporaryDirectory(prefix=f".u-unlocked-{name}-", dir=destination.parent) as temporary:
        temporary_path = Path(temporary)
        archive = temporary_path / "source.zip"
        extraction = temporary_path / "source"
        extraction.mkdir()
        print(f"{name}: downloading pinned source {revision}", flush=True)
        download_archive(name, url, archive)
        safe_extract(archive, extraction)
        if not any(extraction.iterdir()):
            raise RuntimeError(f"{name}: source archive extracted no files.")
        (extraction / MARKER).write_text(revision + "\n", encoding="ascii")
        os.replace(extraction, destination)
    print(f"{name}: {revision} (downloaded and pinned)")



def create_dependency_bundle(output, dependencies):
    """Package already-verified pinned sources into a release bundle."""
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as bundle:
        for name, dependency in sorted(dependencies.items()):
            source = ROOT / "third_party" / name
            marker = source / MARKER
            if not marker.is_file() or marker.read_text(encoding="ascii").strip() != dependency["revision"]:
                raise RuntimeError(f"{name}: cannot bundle a missing or unverified dependency; expected {dependency['revision']}.")
            for path in sorted(source.rglob("*")):
                if path.is_symlink():
                    raise RuntimeError(f"{name}: refusing to bundle a symbolic link: {path}")
                if not path.is_file():
                    continue
                relative = path.relative_to(source).as_posix()
                if any(part in ("", ".", "..") or ":" in part for part in PurePosixPath(relative).parts):
                    raise RuntimeError(f"{name}: unsafe dependency path: {relative}")
                bundle.write(path, f"bundle/third_party/{name}/{relative}")
    if not output.is_file() or output.stat().st_size == 0:
        raise RuntimeError("The dependency bundle was not created.")
    print(f"Created verified dependency bundle: {output} ({output.stat().st_size} bytes)")


def install_dependency_bundle(bundle_path, dependencies):
    """Install only locked, marker-verified dependency trees from a release bundle."""
    bundle_path = Path(bundle_path)
    if not bundle_path.is_file():
        raise RuntimeError(f"Dependency bundle does not exist: {bundle_path}")
    with tempfile.TemporaryDirectory(prefix="u-unlocked-dependency-bundle-") as temporary:
        extracted = Path(temporary)
        safe_extract(bundle_path, extracted)
        source_root = extracted / "third_party"
        if not source_root.is_dir():
            raise RuntimeError("Dependency bundle is missing its third_party directory.")
        sources = {}
        for name, dependency in dependencies.items():
            source = source_root / name
            marker = source / MARKER
            if not source.is_dir() or not marker.is_file():
                raise RuntimeError(f"Dependency bundle is missing pinned dependency {name}.")
            actual = marker.read_text(encoding="ascii").strip()
            if actual != dependency["revision"]:
                raise RuntimeError(f"{name}: dependency bundle revision mismatch; expected {dependency['revision']}, found {actual}.")
            destination = ROOT / "third_party" / name
            if destination.exists():
                existing_marker = destination / MARKER
                if not existing_marker.is_file() or existing_marker.read_text(encoding="ascii").strip() != dependency["revision"]:
                    raise RuntimeError(f"Refusing to replace existing dependency directory {destination}; it does not match the locked revision.")
            sources[name] = (source, destination)
        for name, (source, destination) in sources.items():
            if destination.exists():
                print(f"{name}: {dependencies[name]['revision']} (already installed)")
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(source, destination)
            print(f"{name}: {dependencies[name]['revision']} (installed from release bundle)")

def main():
    dependencies = json.loads((ROOT / "dependencies.lock.json").read_text(encoding="utf-8"))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("names", nargs="*", help="Default: all dependencies in dependencies.lock.json")
    parser.add_argument("--bundle-output", type=Path, help="Create a release bundle from already verified local dependencies.")
    parser.add_argument("--bundle-archive", type=Path, default=Path(os.environ["U_UNLOCKED_DEPENDENCY_BUNDLE"]) if os.environ.get("U_UNLOCKED_DEPENDENCY_BUNDLE") else None, help="Install pinned dependencies from a release bundle before checking online sources.")
    args = parser.parse_args()
    if args.bundle_output and args.bundle_archive:
        parser.error("--bundle-output and --bundle-archive cannot be used together")
    if args.bundle_output:
        if args.names:
            parser.error("dependency names cannot be combined with --bundle-output")
        create_dependency_bundle(args.bundle_output, dependencies)
        return
    if args.bundle_archive:
        install_dependency_bundle(args.bundle_archive, dependencies)
    selected = args.names or list(dependencies)
    unknown = [name for name in selected if name not in dependencies]
    if unknown:
        parser.error("Unknown dependency: " + ", ".join(unknown))
    for name in selected:
        fetch_dependency(name, dependencies[name])


if __name__ == "__main__":
    main()
