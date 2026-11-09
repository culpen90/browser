#!/usr/bin/env python3
"""Stage a pinned, standalone SearXNG service for Browser.app."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path, PurePosixPath


SCRIPT_DIR = Path(__file__).resolve().parent
CACHE = SCRIPT_DIR.parent / ".build" / "local-search-artifacts"
LOCK = SCRIPT_DIR / "local-search-lock.json"


def sha256(path):
    with path.open("rb") as source:
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
        return digest.hexdigest()


def fetch(artifact):
    digest, url = artifact
    cached = CACHE / digest
    if cached.is_file() and sha256(cached) == digest:
        return cached
    with tempfile.TemporaryDirectory(dir=CACHE) as temporary:
        download = Path(temporary) / "download"
        subprocess.run(
            ["/usr/bin/curl", "--fail", "--silent", "--show-error", "--location",
             "--proto", "=https", "--proto-redir", "=https", "--retry", "2",
             "--connect-timeout", "15", "--max-time", "120", "--output", str(download), url],
            check=True,
        )
        if sha256(download) != digest:
            raise ValueError(f"SHA-256 mismatch for {url}")
        os.replace(download, cached)
    return cached


def artifact(record):
    return record["sha256"], record["url"]


def unpack_tar(archive, destination):
    subprocess.run(["/usr/bin/tar", "-xzf", str(archive), "-C", str(destination)], check=True)


def install_wheel(archive, packages):
    with zipfile.ZipFile(archive) as wheel:
        for member in wheel.infolist():
            if member.is_dir():
                continue
            path = PurePosixPath(member.filename)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError(f"Invalid wheel entry {member.filename}")
            if path.parts[0].endswith(".data"):
                scheme = path.parts[1]
                if scheme in ("scripts", "headers"):
                    continue
                if scheme not in ("purelib", "platlib"):
                    raise ValueError(f"Unsupported wheel entry {member.filename}")
                path = PurePosixPath(*path.parts[2:])
            destination = packages.joinpath(*path.parts)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with wheel.open(member) as source, destination.open("wb") as output:
                shutil.copyfileobj(source, output)


def sign_runtime(python, python_minor):
    libraries = python / "lib"
    binary = python / "bin" / f"python{python_minor}"
    mach_objects = [binary]
    for suffix in ("*.dylib", "*.so"):
        mach_objects.extend(path for path in sorted(libraries.rglob(suffix)) if not path.is_symlink())
    subprocess.run(
        ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", *map(str, mach_objects)],
        check=True,
    )
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary)], check=True)


def write_frozen_version(searx, version):
    (searx / "version_frozen.py").write_text(
        "# SPDX-License-Identifier: AGPL-3.0-or-later\n"
        "# Generated from the pinned SearXNG revision by Browser's packager.\n"
        f"VERSION_STRING = {version!r}\n"
        f"VERSION_TAG = {version!r}\n"
        f"DOCKER_TAG = {version.replace('+', '-')!r}\n"
        "GIT_URL = 'https://github.com/searxng/searxng'\n"
        "GIT_BRANCH = 'master'\n",
        encoding="utf-8",
    )


def write_notices(destination, source, archives, lock):
    searxng, python = lock["searxng"], lock["python"]
    licenses = destination / "licenses"
    licenses.mkdir()
    shutil.copyfile(source / "LICENSE", licenses / "SearXNG-AGPL-3.0.txt")
    sources = destination / "source"
    sources.mkdir()
    searx_archive = archives[searxng["sha256"]]
    shutil.copyfile(searx_archive, sources / f"searxng-{searxng['revision']}.tar.gz")
    python_archive = archives[python["source"]["sha256"]]
    shutil.copyfile(python_archive, sources / f"python-build-standalone-{python['release']}.tar.gz")
    with tarfile.open(python_archive, "r:gz") as standalone:
        for member in standalone:
            path = PurePosixPath(member.name)
            if member.isfile() and len(path.parts) == 2 and path.name.startswith("LICENSE"):
                license_name = path.name
                (licenses / f"Python-Build-Standalone-{license_name}").write_bytes(
                    standalone.extractfile(member).read()
                )
    shutil.copyfile(LOCK, destination / LOCK.name)
    (destination / "THIRD-PARTY.txt").write_text(
        f"""SearXNG {searxng['version']}
Copyright SearXNG contributors. Licensed under AGPL-3.0-or-later.
The complete upstream source is in source/searxng-{searxng['revision']}.tar.gz.
Browser generates version_frozen.py to identify this exact upstream revision.
https://github.com/searxng/searxng/tree/{searxng['revision']}

CPython {python['version']} from Python Build Standalone {python['release']}
CPython's license is included in the Python standard library and licenses/.
Python Build Standalone build sources and license notices are in source/ and licenses/.
CPython source: https://www.python.org/downloads/release/python-{python['version'].replace('.', '')}/
https://github.com/astral-sh/python-build-standalone/releases/tag/{python['release']}

The pinned Python wheels retain their notices and metadata under
python/lib/python*/site-packages in each architecture's folder.
See local-search-lock.json for the exact upstream artifacts.
""",
        encoding="utf-8",
    )


def bundle(destination, architectures, lock):
    searxng, python = lock["searxng"], lock["python"]
    python_minor = ".".join(python["version"].split(".")[:2])
    wanted = {artifact(searxng), artifact(python["source"])}
    wanted.update(tuple(item) for item in lock["wheels"]["all"].values())
    for arch in architectures:
        wanted.add(artifact(python["archives"][arch]))
        wanted.update(tuple(item) for item in lock["wheels"][arch].values())

    CACHE.mkdir(parents=True, exist_ok=True)
    artifacts = sorted(wanted)
    with ThreadPoolExecutor(max_workers=6) as pool:
        archives = {item[0]: path for item, path in zip(artifacts, pool.map(fetch, artifacts))}

    with tempfile.TemporaryDirectory(prefix="browser-searxng-source-") as temporary:
        unpack_tar(archives[searxng["sha256"]], temporary)
        source = Path(temporary) / f"searxng-{searxng['revision']}"
        for arch in architectures:
            print(f"Staging SearXNG {searxng['version']} for {arch}", flush=True)
            target = destination / arch
            target.mkdir()
            unpack_tar(archives[python["archives"][arch]["sha256"]], target)
            python_home = target / "python"
            subprocess.run(
                ["/usr/bin/lipo", "-verify_arch", arch, str(python_home / "bin" / "python3")],
                check=True,
            )
            packages = python_home / "lib" / f"python{python_minor}" / "site-packages"
            for digest, _ in (*lock["wheels"]["all"].values(), *lock["wheels"][arch].values()):
                install_wheel(archives[digest], packages)
            searx = packages / "searx"
            shutil.copytree(source / "searx", searx)
            write_frozen_version(searx, searxng["version"])
            sign_runtime(python_home, python_minor)
        write_notices(destination, source, archives, lock)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("architectures", nargs="+", choices=("arm64", "x86_64"))
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=True)
    if any(args.destination.iterdir()):
        parser.error("destination must be empty")
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    bundle(args.destination, tuple(dict.fromkeys(args.architectures)), lock)


if __name__ == "__main__":
    main()
