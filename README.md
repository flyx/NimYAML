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

## Features that may come in the future

 * Serialization:
   - Support for more standard library types
   - Support for polymorphism
   - Support for generic objects
   - Support for transient fields (i.e. object fields that will not be
     (de-)serialized

## Developers

```bash
nim tests # runs all tests
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

NimYAML needs at least Nim 0.15.0 in order to compile.

## License

[MIT][2]

 [1]: http://flyx.github.io/NimYAML/
 [2]: copying.txt