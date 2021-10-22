# NimYAML - YAML implementation for Nim

![Test Status](https://github.com/flyx/NimYAML/actions/workflows/action.yml/badge.svg)

NimYAML is a pure Nim YAML implementation without any dependencies other than
Nim's standard library. It enables you to serialize Nim objects to a YAML stream
and back. It also provides a low-level event-based API, and a document object
model which you do not want to use because serializing to native types is much
more awesome.

Documentation, examples and an online demo are available [here][1]. Releases are
available as tags in this repository and can be fetched via nimble:

    nimble install yaml

## Status

The library is fairly stable, I only maintain it and will not add any features due to lack of time and interest. NimYAML passes all tests of the current YAML
test suite which makes it 100% conformant with YAML 1.2.

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
nim serializationTests # runs serialization tests
nim quickstartTests # run tests for quickstart snippets from documentation
nim documentation # builds documentation to folder docout
nim server # builds the REST server used for the testing ground
nim bench # runs benchmarks, requires libyaml
nim clean # guess
nim build # build a library
```

NimYAML supports Nim 1.4.0 and later.
Previous versions are untested.
NimYAML v0.9.1 is the last release to support Nim 0.15.x and 0.16.0.

When debugging crashes in this library, use the `d:debug` compile flag to enable printing of the internal stack traces for calls to `internalError` and `yAssert`.

## License

[MIT][2]

## Support this Project

If you like this project and want to give something back, you can check out GitHub's Sponsor button to the right. This is just an option I provide, not something I request you to do, and I will never nag about it.

 [1]: http://flyx.github.io/NimYAML/
 [2]: copying.txt
