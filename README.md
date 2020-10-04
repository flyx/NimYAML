# NimYAML - YAML implementation for Nim

[![Build Status](https://travis-ci.org/flyx/NimYAML.svg?branch=devel)](https://travis-ci.org/flyx/NimYAML)

NimYAML is a pure Nim YAML implementation without any dependencies other than
Nim's standard library. It enables you to serialize Nim objects to a YAML stream
and back. It also provides a low-level event-based API, and a document object
model which you do not want to use because serializing to native types is much
more awesome.

Documentation, examples and an online demo are available [here][1]. Releases are
available as tags in this repository and can be fetched via nimble:

    nimble install yaml
    
## Status

The library is fairly stable, I only maintain it and will not add any features due to lack of time and interest. There are few issues with YAML corner cases in the lexer which you are unlikely to encounter unless you're going for them. Fixing them would mean a larger refactor of the lexer which I am not willing to do.

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

NimYAML needs at least Nim 0.17.0 in order to compile. Version 0.9.1
is the last release to support 0.15.x and 0.16.0.

When debugging crashes in this library, use the `d:debug` compile flag to enable printing of the internal stack traces for calls to `internalError` and `yAssert`.

## License

[MIT][2]

 [1]: http://flyx.github.io/NimYAML/
 [2]: copying.txt
