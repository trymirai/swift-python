"""Download, verify, unpack and archive immutable wheel artifacts."""

import email.parser
import errno
import hashlib
import os
import shutil
import sys
import tempfile
import urllib.request
import uuid
import zipfile
from pathlib import Path

from installer import install as install_wheel
from installer.destinations import SchemeDictionaryDestination
from installer.sources import WheelFile
from packaging.utils import canonicalize_name
from packaging.version import Version

from ..packages.archive import distribution_metadata_paths
from .candidate import Wheel
from .paths import absolute_path, walk_files


def _download(wheel: Wheel, temporary: Path) -> None:
    digest = hashlib.sha256()
    with (
        urllib.request.urlopen(wheel.url, timeout=30) as response,
        temporary.open("xb") as output,
    ):
        size = 0

        while chunk := response.read(128 * 1024):
            size += len(chunk)
            if size > 256 * 1024 * 1024:
                raise ValueError(f"Wheel exceeds the download limit: {wheel.name}")

            digest.update(chunk)
            output.write(chunk)

        output.flush()
        os.fsync(output.fileno())

    if digest.hexdigest() != wheel.digest:
        raise ValueError(f"Wheel checksum mismatch: {wheel.name}")


def _validate_archive(wheel_path: Path, wheel: Wheel) -> None:
    with zipfile.ZipFile(wheel_path) as archive:
        entries = archive.infolist()
        if sum(info.file_size for info in entries) > 1024 * 1024 * 1024:
            raise ValueError(f"Unpacked wheel exceeds the installation limit: {wheel.name}")

        for info in entries:
            path = Path(info.filename)
            if path.is_absolute() or ".." in path.parts or "\0" in info.filename:
                raise ValueError(f"Invalid wheel member: {info.filename!r}")


def _install_archive(wheel_path: Path, stage: Path) -> None:
    scheme = {
        key: str(stage / ("site-packages" if key in ("purelib", "platlib") else key))
        for key in ("purelib", "platlib", "scripts", "headers", "data")
    }
    destination = SchemeDictionaryDestination(
        scheme,
        interpreter=sys.executable or "python",
        script_kind="posix",
        bytecode_optimization_levels=(),
    )
    with WheelFile.open(wheel_path) as source:
        source.validate_record(validate_contents=True)
        install_wheel(source, destination, {"INSTALLER": b"swift-python\n"})

    for path in walk_files(stage):
        path.chmod(path.stat().st_mode & ~0o222)


def _publish_install(stage: Path, target: Path) -> None:
    try:
        os.rename(stage, target)
    except OSError as error:
        # Another installer may have published this same digest first.
        if error.errno not in (errno.EEXIST, errno.ENOTEMPTY) or not target.is_dir():
            raise


class WheelCache:
    def __init__(self, directory: Path) -> None:
        self.directory = directory

    def download(self, wheel: Wheel) -> Path:
        cache = self.directory / "wheels" / wheel.digest
        cache.mkdir(parents=True, exist_ok=True)

        destination = cache / wheel.filename
        if destination.is_file():
            with destination.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()

            if digest != wheel.digest:
                raise ValueError(f"Cached wheel checksum mismatch: {wheel.name}")

            return destination

        temporary = cache / (uuid.uuid4().hex + ".download")

        try:
            _download(wheel, temporary)
            os.replace(temporary, destination)
            return destination
        finally:
            temporary.unlink(missing_ok=True)

    def metadata(self, wheel: Wheel):
        with zipfile.ZipFile(self.download(wheel)) as archive:
            paths = list(distribution_metadata_paths(archive.namelist()))
            if len(paths) != 1:
                raise ValueError(
                    f"Wheel must have one distribution metadata directory: {wheel.name}"
                )

            metadata = email.parser.BytesParser().parsebytes(archive.read(paths[0]))
            if (
                canonicalize_name(metadata["Name"]) != wheel.name
                or Version(metadata["Version"]) != wheel.version
            ):
                raise ValueError(f"Wheel metadata does not match its filename: {wheel.filename}")

            return metadata

    def unpack(self, wheel: Wheel) -> Path:
        parent = self.directory / "installed"
        parent.mkdir(parents=True, exist_ok=True)
        target = parent / wheel.digest
        if target.is_dir():
            return target

        # Stage beside the digest directory so publication is a single rename.
        stage = Path(tempfile.mkdtemp(prefix=".install-", dir=parent))

        try:
            wheel_path = self.download(wheel)
            _validate_archive(wheel_path, wheel)
            _install_archive(wheel_path, stage)

            _publish_install(stage, target)
            return target
        finally:
            if stage.exists():
                shutil.rmtree(stage)


def archive(request: dict) -> None:
    source = absolute_path(request["directory"])
    destination = absolute_path(request["output"])

    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(source.rglob("*")):
            if not file.is_file():
                continue

            entry = zipfile.ZipInfo(file.relative_to(source).as_posix())
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = (file.stat().st_mode & 0o777) << 16

            with file.open("rb") as source_file, archive.open(entry, "w") as entry_stream:
                shutil.copyfileobj(source_file, entry_stream)
