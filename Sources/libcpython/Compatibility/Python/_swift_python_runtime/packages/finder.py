"""Integrate archive modules, resources and distributions with importlib."""

import importlib.metadata
from _frozen_importlib_external import SourceLoader
from importlib.machinery import ModuleSpec
from importlib.util import spec_from_file_location

from .archive import Archive
from .resources import Resource, ResourceReader


class Loader(SourceLoader):
    def __init__(self, archive: "Archive", path: str) -> None:
        self.archive = archive
        self.path = path

    def get_filename(self, fullname: str) -> str:
        return self.archive.root + "/" + self.path

    def get_data(self, path: str) -> bytes:
        prefix = self.archive.root + "/"
        if not path.startswith(prefix):
            raise FileNotFoundError(path)

        return Resource(self.archive, path[len(prefix) :]).read_bytes()

    def is_package(self, fullname: str) -> bool:
        return self.path.endswith("/__init__.py")

    def get_resource_reader(self, fullname: str) -> ResourceReader:
        return ResourceReader(self.archive, self.path.rpartition("/")[0])


class PathFinder:
    def __init__(self, archive: Archive) -> None:
        self.archive = archive

    def find_spec(self, fullname: str, target=None) -> ModuleSpec | None:
        path = fullname.replace(".", "/")

        for candidate in (path + "/__init__.py", path + ".py"):
            if candidate in self.archive.names:
                loader = Loader(self.archive, candidate)
                return spec_from_file_location(fullname, loader=loader)

        if any(name.startswith(path + "/") for name in self.archive.names):
            spec = ModuleSpec(fullname, loader=None, is_package=True)
            spec.submodule_search_locations = [self.archive.root + "/" + path]
            return spec

        return None

    def iter_modules(self, prefix: str = ""):
        # The path hook constructs a finder at the requested package directory.
        path = getattr(self, "path", "")
        resource = Resource(self.archive, path)

        for entry in resource.iterdir():
            if entry.name == "__init__.py" or entry.name.endswith(".dist-info"):
                continue

            if entry.name.endswith(".py"):
                yield prefix + entry.name[:-3], False
            elif entry.is_dir():
                yield prefix + entry.name, True


class MetadataFinder:
    def __init__(self, archives: list[Archive]) -> None:
        self.archives = archives

    def find_spec(self, fullname: str, path=None, target=None) -> None:
        return None

    def find_distributions(
        self,
        context: importlib.metadata.DistributionFinder.Context = importlib.metadata.DistributionFinder.Context(),
    ):
        for archive in self.archives:
            if archive.root in context.path:
                yield from archive.distributions(context.name)
