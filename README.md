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
I only maintain it and will not add any features due to lack of time and interest.
NimYAML passes all tests of the current YAML 1.2 test suite.
See [the official YAML test matrix][4] for details.

PRs for bugs are welcome. If you want to add a feature, you are free to; but be aware that I will not maintain it and am unlikely to review it in depth, so if I accept it, you will be co-maintainer.

## Features that have been planned, but will not be implemented by myself

 * Serialization:
   - Support for more standard library types
   - Support for polymorphism
   - Support for generic objects

## Developers

```bash
nim test # runs all tests
nim lexerTests # run lexer tests
nim parserTests # run parser tests (git-clones yaml-dev-kit)
nim nativeTests # runs native value tests
nim quickstartTests # run tests for quickstart snippets from documentation
nim bench # runs benchmarks, requires libyaml
nim clean # guess
nim build # build a library
```

NimYAML supports Nim 1.4.0 and later.
Previous versions are untested.

When debugging crashes in this library, use the `d:debug` compile flag to enable printing of the internal stack traces for calls to `internalError` and `yAssert`.

### Web Documentation

The online documentation on [nimyaml.org](https://nimyaml.org), including the
testing ground, is generated via [Nix Flake][3] and easily deployable on NixOS.
Just include the NixOS module in the flake and do

```nix
services.nimyaml-webdocs.enable = true;
```

This will run the documentation server locally at `127.0.0.1:5000`. You can
change the `address` setting to make it public, but I suggest proxying via nginx
to get HTTPS.

## License

[MIT][2]

## Support this Project

If you like this project and want to give something back, you can check out GitHub's Sponsor button to the right. This is just an option I provide, not something I request you to do, and I will never nag about it.

 [1]: http://flyx.github.io/NimYAML/
 [2]: copying.txt
 [3]: https://nixos.wiki/wiki/Flakes
 [4]: https://matrix.yaml.info/
