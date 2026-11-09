# NimYAML - YAML implementation for Nim

![Test Status](https://github.com/flyx/NimYAML/actions/workflows/action.yml/badge.svg)

NimYAML is a pure Nim YAML implementation without any dependencies other than
Nim's standard library. It enables you to serialize Nim objects to a YAML stream
and back. It also provides a low-level event-based API.

Documentation, examples and an online demo are available [here][1]. Releases are
available as tags in this repository and can be fetched via nimble:

    nimble install yaml

## Status

This library is stable.
NimYAML passes all tests of the current [YAML 1.2 test suite][4].
This project follows [SemVer][5].

I am committed to maintaining the library, but will seldom introduce new features.
PRs are welcome.

## Dependencies

NimYAML requires Nim 2.0.0 or later.
The last version supporting Nim 1.6.x is `v1.1.0`.
Use this in your `.nimble` file if you haven't migrated to Nim 2.x yet:

```nim
requires "yaml ^= 1.1.0"
```

## Missing Features

Be aware that serialization currently doesn't support the following features in types that are used for loading and dumping:

 * Polymorphism: If a field has a type `ref Parent`, you cannot load a `ref Child` into it.
 * Generic objects: The code auto-generating loading and dumping functions currently cannot process instances of generic objects anywhere in the type you want to load/dump.
 * Default values: NimYAML uses its own `{.defaultVal: "foo".}` pragma.
   It currently cannot process default values introduced in Nim 2.0.

## Developers

Nix users can `nix develop` to get a devshell with the required Nim version. You'll need to have Flakes enabled.

```bash
nim test # runs all tests with the C backend
nim test tlex # runs a single test file (test/tlex.nim) with the C backend
nim testJS # runs all tests except tquickstart with the JS backend (requires Node.js)
nim testJS tparser # runs a single test file with the JS backend
nim clean # guess
nim build # build a library
```

Available test files are `tlex`, `tparser`, `tjson`, `tdom`, `tnative`, `thints`, `tpresenter`, `tannotations` and `tquickstart` (tests the quickstart snippets from the documentation; C backend only).

When debugging crashes in this library, use the `d:debug` compile flag to enable printing of the internal stack traces for calls to `internalError` and `yAssert`.

### Web Documentation

The online documentation on [nimyaml.org][1], including the
testing ground, is generated via [Nix Flake][3].

You can build & run the docs server at via

```bash
nix run .#webdocs
```

It can be deployed to NixOS by importing the Flake's NixOS module and then doing

```nix
services.nimyaml-webdocs.enable = true;
```

This will run the documentation server locally at `127.0.0.1:5000`.
Since there isn't much of a use-case for third parties to host this documentation, there is no support for running the server without Nix.

## License

[MIT][2]

## Support this Project

If you want to support this project financially, there's a GitHub Sponsor button to the right.

 [1]: https://nimyaml.org
 [2]: copying.txt
 [3]: https://nixos.wiki/wiki/Flakes
 [4]: https://github.com/yaml/yaml-test-suite
 [5]: https://semver.org
