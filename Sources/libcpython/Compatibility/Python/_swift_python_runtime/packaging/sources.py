"""Publish supplied site-packages ZIPs as shared, content-addressed directories."""

import hashlib
import shutil
import tempfile
import zipfile
from pathlib import Path

from ..packages.archive import Reader
from .paths import absolute_path, archive_entries, archive_member_path, publish_directory


def source_directories(cache: Path, sources, read) -> list[str]:
    paths = []
    for index, source in enumerate(sources):
        path = _source_directory(cache, source, index, read)
        paths.append(str(path))

    return list(dict.fromkeys(paths))


def _source_directory(cache: Path, source: dict, index: int, read) -> Path:
    if "directory" in source:
        path = absolute_path(source["directory"])
        if not path.is_dir():
            raise FileNotFoundError(path)
        return path

    if "archive" in source:
        stream = absolute_path(source["archive"]).open("rb")
    else:
        stream = Reader(source["size"], lambda offset, size: read(index, offset, size))

    with stream:
        return _materialize(cache / "bundles", stream)


def _archive_digest(stream, copy_to=None) -> str:
    digest = hashlib.sha256()
    while chunk := stream.read(256 * 1024):
        digest.update(chunk)
        if copy_to is not None:
            copy_to.write(chunk)
    return digest.hexdigest()


def _materialize(cache: Path, stream) -> Path:
    digest = _archive_digest(stream)
    target = cache / digest
    if target.is_dir():
        return target

    cache.mkdir(parents=True, exist_ok=True)
    stream.seek(0)
    with tempfile.TemporaryDirectory(dir=cache) as temporary:
        stage = Path(temporary)
        snapshot = stage / "archive.zip"
        _snapshot_archive(stream, snapshot, digest)

        contents = stage / "site-packages"
        contents.mkdir()
        _extract(snapshot, contents)
        publish_directory(contents, target)

    return target


def _snapshot_archive(stream, snapshot: Path, digest: str) -> None:
    with snapshot.open("wb") as output:
        # The source may change after we derive the cache key from it.
        if _archive_digest(stream, copy_to=output) != digest:
            raise ValueError("Package archive changed during preparation")


def _extract(snapshot: Path, destination: Path) -> None:
    with zipfile.ZipFile(snapshot) as archive:
        entries = archive_entries(archive, "Unpacked package bundle exceeds the installation limit")
        for info in entries:
            _extract_member(archive, info, destination)


def _extract_member(archive: zipfile.ZipFile, info: zipfile.ZipInfo, destination: Path) -> None:
    path = archive_member_path(info.filename)
    if path is None or not path.parts:
        raise ValueError(f"Invalid package archive path: {info.filename!r}")
    if path.suffix.lower() in (".so", ".dylib", ".pyd", ".dll"):
        raise ImportError("Embedded archives support Python code and resources only")

    target = destination / path
    if info.is_dir():
        target.mkdir(parents=True, exist_ok=True)
        return

    target.parent.mkdir(parents=True, exist_ok=True)
    with archive.open(info) as source, target.open("xb") as output:
        shutil.copyfileobj(source, output)
    target.chmod(0o444)
