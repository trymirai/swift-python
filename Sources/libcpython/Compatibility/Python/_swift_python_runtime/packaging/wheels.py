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

from .candidate import Candidate
from .paths import absolute_path


def _metadata(data: bytes):
    return email.parser.BytesParser().parsebytes(data)


class WheelCache:
    def __init__(self, directory: Path) -> None:
        self.directory = directory

    def download(self, candidate: Candidate) -> Path:
        cache = self.directory / "wheels"
        cache.mkdir(exist_ok=True)
        cache = cache / candidate.digest
        cache.mkdir(exist_ok=True)
        destination = cache / candidate.filename
        if destination.is_file():
            with destination.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            if digest == candidate.digest:
                return destination

            raise ValueError(f"Cached wheel checksum mismatch: {candidate.name}")

        temporary = cache / (uuid.uuid4().hex + ".download")

        try:
            digest = hashlib.sha256()
            with (
                urllib.request.urlopen(candidate.url, timeout=30) as response,
                temporary.open("xb") as output,
            ):
                size = 0

                while chunk := response.read(128 * 1024):
                    size += len(chunk)
                    if size > 256 * 1024 * 1024:
                        raise ValueError(f"Wheel exceeds the download limit: {candidate.name}")

                    digest.update(chunk)
                    output.write(chunk)

                output.flush()
                os.fsync(output.fileno())

            if digest.hexdigest() != candidate.digest:
                raise ValueError(f"Wheel checksum mismatch: {candidate.name}")

            os.replace(temporary, destination)
            return destination
        finally:
            temporary.unlink(missing_ok=True)

    def metadata(self, candidate: Candidate):
        with zipfile.ZipFile(self.download(candidate)) as archive:
            paths = [
                name
                for name in archive.namelist()
                if name.endswith(".dist-info/METADATA") and name.count("/") == 1
            ]
            if len(paths) != 1:
                raise ValueError(
                    f"Wheel must have one distribution metadata directory: {candidate.name}"
                )

            metadata = _metadata(archive.read(paths[0]))
            if (
                canonicalize_name(metadata["Name"]) != candidate.name
                or Version(metadata["Version"]) != candidate.version
            ):
                raise ValueError(
                    f"Wheel metadata does not match its filename: {candidate.filename}"
                )

            return metadata

    def unpack(self, candidate: Candidate) -> Path:
        parent = self.directory / "installed"
        parent.mkdir(exist_ok=True)
        target = parent / candidate.digest
        if target.is_dir():
            return target

        stage = Path(tempfile.mkdtemp(prefix=".install-", dir=parent))

        try:
            with zipfile.ZipFile(self.download(candidate)) as archive:
                if sum(info.file_size for info in archive.infolist()) > 1024 * 1024 * 1024:
                    raise ValueError(
                        f"Unpacked wheel exceeds the installation limit: {candidate.name}"
                    )

                for info in archive.infolist():
                    path = Path(info.filename)
                    if path.is_absolute() or ".." in path.parts or "\0" in info.filename:
                        raise ValueError(f"Invalid wheel member: {info.filename!r}")

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
            # WheelFile validates RECORD hashes while the public installer writes the
            # wheel's declared installation scheme and distribution metadata.
            with WheelFile.open(self.download(candidate)) as wheel:
                wheel.validate_record(validate_contents=True)
                install_wheel(wheel, destination, {"INSTALLER": b"swift-python\n"})

            for directory, _, files in os.walk(stage):
                for file in files:
                    path = Path(directory) / file
                    path.chmod(path.stat().st_mode & ~0o222)

            try:
                os.rename(stage, target)
            except OSError as error:
                if error.errno not in (errno.EEXIST, errno.ENOTEMPTY) or not target.is_dir():
                    raise

            return target
        finally:
            if stage.exists():
                shutil.rmtree(stage)


def archive(request: dict, unused, control) -> None:
    source = absolute_path(request["directory"])
    destination = absolute_path(request["output"])
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(source.rglob("*")):
            if file.is_file():
                entry = zipfile.ZipInfo(file.relative_to(source).as_posix())
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = (file.stat().st_mode & 0o777) << 16
                with file.open("rb") as input, archive.open(entry, "w") as output:
                    shutil.copyfileobj(input, output)
