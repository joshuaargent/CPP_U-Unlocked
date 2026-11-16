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
    """Extract a GitHub source archive while rejecting traversal and link entries."""
    with zipfile.ZipFile(archive) as source:
        members = source.infolist()
        if not members:
            raise RuntimeError("The dependency archive is empty.")
        roots = set()
        for member in members:
            name = member.filename.replace("\\", "/")
            path = PurePosixPath(name)
            if path.is_absolute() or not path.parts or any(part in ("", ".", "..") for part in path.parts):
                raise RuntimeError(f"Unsafe dependency archive path: {member.filename}")
            mode = (member.external_attr >> 16) & 0xFFFF
            if stat.S_ISLNK(mode):
                raise RuntimeError(f"Dependency archive contains a symbolic link: {member.filename}")
            roots.add(path.parts[0])
        if len(roots) != 1:
            raise RuntimeError("The dependency archive does not contain exactly one source root.")

        root = next(iter(roots))
        for member in members:
            relative = PurePosixPath(member.filename.replace("\\", "/")).parts[1:]
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
    with tempfile.TemporaryDirectory(prefix=f"u-unlocked-{name}-") as temporary:
        temporary_path = Path(temporary)
        archive = temporary_path / "source.zip"
        extraction = temporary_path / "source"
        extraction.mkdir()
        request = urllib.request.Request(
            url,
            headers={"User-Agent": "U-Unlocked-Dependency-Bootstrap", "Accept": "application/zip"}
        )
        print(f"{name}: downloading pinned source {revision}")
        with urllib.request.urlopen(request, timeout=60) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output, length=1024 * 1024)
        safe_extract(archive, extraction)
        roots = list(extraction.iterdir())
        if len(roots) != 1 or not roots[0].is_dir():
            raise RuntimeError(f"{name}: source archive has an unexpected root layout.")
        shutil.move(str(roots[0]), str(destination))
        (destination / MARKER).write_text(revision + "\n", encoding="ascii")
    print(f"{name}: {revision} (downloaded and pinned)")


def main():
    dependencies = json.loads((ROOT / "dependencies.lock.json").read_text(encoding="utf-8"))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("names", nargs="*", help="Default: all dependencies in dependencies.lock.json")
    args = parser.parse_args()
    selected = args.names or list(dependencies)
    unknown = [name for name in selected if name not in dependencies]
    if unknown:
        parser.error("Unknown dependency: " + ", ".join(unknown))
    for name in selected:
        fetch_dependency(name, dependencies[name])


if __name__ == "__main__":
    main()
