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
from .configuration import Configuration
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


def _install_archive(wheel_path: Path, stage: Path, site_packages: str) -> None:
    scheme = {
        key: str(stage / (site_packages if key in ("purelib", "platlib") else key))
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
    def __init__(self, configuration: Configuration) -> None:
        self._configuration = configuration

    def download(self, wheel: Wheel) -> Path:
        destination = self._configuration.wheels / wheel.digest / wheel.filename
        destination.parent.mkdir(parents=True, exist_ok=True)

        if destination.is_file():
            with destination.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            if digest != wheel.digest:
                raise ValueError(f"Cached wheel checksum mismatch: {wheel.name}")
        else:
            self._publish_download(wheel, destination)

        return destination

    def _publish_download(self, wheel: Wheel, destination: Path) -> None:
        temporary = destination.with_name(uuid.uuid4().hex + self._configuration.download_suffix)
        try:
            _download(wheel, temporary)
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)

    def metadata(self, wheel: Wheel):
        with zipfile.ZipFile(self.download(wheel)) as archive:
            paths = list(
                distribution_metadata_paths(entry.filename for entry in archive.infolist())
            )
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
        target = self._configuration.installed / wheel.digest
        target.parent.mkdir(parents=True, exist_ok=True)

        if not target.is_dir():
            self._install(wheel, target)
        return target / self._configuration.site_packages

    def _install(self, wheel: Wheel, target: Path) -> None:
        configuration = self._configuration

        # Stage on the same filesystem so readers only see a complete installation.
        stage = Path(tempfile.mkdtemp(prefix=configuration.installation_prefix, dir=target.parent))
        try:
            wheel_path = self.download(wheel)
            _validate_archive(wheel_path, wheel)
            _install_archive(wheel_path, stage, configuration.site_packages)
            _publish_install(stage, target)
        finally:
            if stage.exists():
                shutil.rmtree(stage)


def archive(request: dict) -> None:
    source = absolute_path(request["directory"])
    destination = absolute_path(request["output"])

    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED) as output:
        for file in sorted(source.rglob("*")):
            if file.is_file():
                _write_archive_member(output, file, file.relative_to(source).as_posix())


def _write_archive_member(archive: zipfile.ZipFile, file: Path, name: str) -> None:
    entry = zipfile.ZipInfo(name)
    entry.compress_type = zipfile.ZIP_DEFLATED
    entry.external_attr = (file.stat().st_mode & 0o777) << 16

    with file.open("rb") as source, archive.open(entry, "w") as output:
        shutil.copyfileobj(source, output)
