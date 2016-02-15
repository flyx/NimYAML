# NimYAML - YAML implementation for Nim

NimYAML is currently being developed. There is no release yet. See
[the documentation](http://flyx.github.io/NimYAML/) for an overview of already
available features.

## TODO list

 * Misc:
   - Add type hints for more scalar types
 * Serialization:
   - Support for more standard library types
   - Support polymorphism
   - Support variant objects
   - Support transient fields (i.e. fields that will not be (de-)serialized on
     objects and tuples)
   - Use `concept` type class `Serializable` or something
   - Check for and avoid name clashes when generating local tags for custom
     object types.
   - Possibly use `genSym` for predefined and generated `yamlTag` procs because
     they are an implementation detail and should not be visible to the caller.
     same goes for `lazyLoadTag` and `safeLoadUri`.

## License

[MIT](copying.txt)