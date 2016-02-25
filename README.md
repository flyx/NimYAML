# NimYAML - YAML implementation for Nim

NimYAML is currently being developed. The current release 0.2.0 is not
considered stable. See [the documentation](http://flyx.github.io/NimYAML/) for
an overview of already available features.

## TODO list

 * Misc:
   - Add type hints for more scalar types
 * Serialization:
   - Support for more standard library types
   - Support polymorphism
   - Support variant objects
   - Support transient fields (i.e. fields that will not be (de-)serialized on
     objects and tuples)
   - Check for and avoid name clashes when generating local tags for custom
     object types.
   - Possibly use `genSym` for predefined and generated `yamlTag` procs because
     they are an implementation detail and should not be visible to the caller.
     same goes for `lazyLoadTag` and `safeLoadUri`.

## Developers

```bash
nim tests # runs all tests
nim parserTests # runs parser tests
nim serializationTests # runs serialization tests
nim documentation # builds documentation to folder docout
nim server # builds the REST server used for the testing ground
nim bench # runs benchmarks, requires libyaml
nim clean # guess
nim build # build a library
```

Project is tested against current develop branch of Nim. Older Nim versions
probably do not work.

## License

[MIT](copying.txt)
