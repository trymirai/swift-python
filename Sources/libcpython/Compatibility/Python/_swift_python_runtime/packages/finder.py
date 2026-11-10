"""Integrate archive modules, resources and distributions with importlib."""

import importlib.metadata
import os
from _frozen_importlib_external import SourceLoader
from importlib.machinery import ModuleSpec
from importlib.machinery import PathFinder as ImportPathFinder
from importlib.util import spec_from_file_location

from .archive import Archive, normalize_name
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
    def __init__(self, archive: Archive, path: str = "") -> None:
        self.archive = archive
        self.path = path

    def find_spec(self, fullname: str, target=None) -> ModuleSpec | None:
        path = (self.path + "/" + fullname.rsplit(".", 1)[-1]).lstrip("/")

        for candidate in (path + "/__init__.py", path + ".py"):
            if candidate in self.archive.names:
                loader = Loader(self.archive, candidate)
                return spec_from_file_location(fullname, loader=loader)

        directory = path + "/"
        if self.archive.has_member_with_prefix(directory):
            spec = ModuleSpec(fullname, loader=None, is_package=True)
            spec.submodule_search_locations = [self.archive.root + "/" + path]
            return spec

        return None

    def iter_modules(self, prefix: str = ""):
        resource = Resource(self.archive, self.path)

        for entry in resource.iterdir():
            name = entry.name
            if name == "__init__.py" or name.endswith(".dist-info"):
                continue

            if name.endswith(".py"):
                yield prefix + name.removesuffix(".py"), False
            elif entry.is_dir():
                yield prefix + name, True


class FilteredFinder:
    """Hide modules owned by a distribution superseded in an earlier root."""

    def __init__(self, finder, hidden: set[str]) -> None:
        self.finder = finder
        self.hidden = hidden

    def find_spec(self, fullname: str, target=None) -> ModuleSpec | None:
        spec = self.finder.find_spec(fullname, target)
        if spec is not None and spec.origin is not None:
            if os.path.normpath(spec.origin) in self.hidden:
                return None
        return spec

    def __getattr__(self, name: str):
        return getattr(self.finder, name)

    def iter_modules(self, prefix: str = ""):
        from pkgutil import iter_importer_modules

        for name, is_package in iter_importer_modules(self.finder):
            if self.find_spec(name) is not None:
                yield prefix + name, is_package


class MetadataFinder(ImportPathFinder):
    def __init__(self, paths, selected) -> None:
        self.packages = {path: {} for path in paths}

        for name, (path, distribution) in selected.items():
            self.packages[path][name] = distribution

    def find_distributions(
        self,
        context: importlib.metadata.DistributionFinder.Context = importlib.metadata.DistributionFinder.Context(),
    ):
        name = normalize_name(context.name) if context.name is not None else None

        for path in dict.fromkeys(context.path):
            packages = self.packages.get(path)
            if packages is None:
                yield from directory_distributions(path, context.name)
            elif name is None:
                yield from packages.values()
            elif name in packages:
                yield packages[name]


def directory_distributions(path: str, name: str | None = None):
    context = importlib.metadata.DistributionFinder.Context(path=[path], name=name)
    return ImportPathFinder.find_distributions(context)
