# NimYAML - YAML implementation for Nim

NimYAML is currently being developed. The current release 0.4.0 is not
considered stable. See [the documentation](http://flyx.github.io/NimYAML/) for
an overview of already available features.

## TODO list

 * Misc:
   - Add type hints for more scalar types
 * Serialization:
   - Support for more standard library types
   - Support polymorphism
   - Support variant objects
   - Support generic objects
   - Support transient fields (i.e. fields that will not be (de-)serialized on
     objects and tuples)

## Developers

```bash
nim tests # runs unit tests (serialization, dom, json)
          # for parser tests, see yamlTestSuite
nim serializationTests # runs serialization tests
nim documentation # builds documentation to folder docout
nim server # builds the REST server used for the testing ground
nim bench # runs benchmarks, requires libyaml
nim clean # guess
nim build # build a library
nim yamlTestSuite # execute YAML test suite (git-clones yaml-dev-kit)
```

Project is tested against current develop branch of Nim. Older Nim versions
probably do not work.

## License

[MIT](copying.txt)
