## 2.1.0 (upcoming)

Features:

 * New pragmas ``scalar`` and ``collection`` allow you to modify the
   presentation style used for certain types and object fields.
   Defined in new module ``yaml/style``.
 * The presenter now honors the node style set in the events it presents,
   if possible. So if a scalar is set to be a literal block scalar, it is
   presented as such unless impossible or presenter options specifically
   prevent this.
 * The presenter can now output single-quoted scalars. It only does so when
   this scalar style is explicitly set on an event.

Changes:

 * renamed ``canonicalDumper`` / ``setCanonicalStyle`` to
   ``explanatoryDumper`` / ``setExplanatoryStyle`` because it was
   a misnomer and there is nothing canonical about this output style.
   The terminology *canonical* was carried over from PyYAML, but the
   YAML specification uses that term for different things.
   The old names are kept with a ``deprecated`` pragma.
 * The ``explanatoryDumper`` now automatically enables the
   tag shorthand ``!n!``, because in this style you want that for readability.

Bugfixes:

 * Fixed a bug that prevented instances of generic types to be used in ``Option``
   fields (e.g. ``Option[seq[string]]``) (#101)
 * Fixed a bug that caused invalid indentation when dumping with certain
   settings (#140)
 * Fixed parsing errors for verbatim tags in flow style (#140)
 * Fixed a bug that caused presentation of block scalars in
   flow collections (#140)
 * Fixed a bug that sometimes caused the last word of a folded block scalar
   not to be presented.
 * Fixed maximum line length not properly implemented in presenter in a number
   of cases.
 * Fixed a bug that prevented the presenter from outputting compact
   flow mappings in cMixed mode.
 * Fixed block scalars as mapping keys not being presented properly.

## 2.0.0

Breaking Changes:

 * Requires Nim 2.x
 * ``yaml/serialization`` has been split into
   ``yaml/native`` (low-level API to load a ``YamlStream`` into Nim vars),
   ``yaml/loading`` (high-level loading API) and
   ``yaml/dumping`` (high-level dumping API).
 * Dumping API now has a ``Dumper`` object.
   All dumping procs require an instance of this object.
   Previous parameters ``tagStyle``, ``handles`` and ``options`` have been
   moved into this object.
 * Constants with default values have been removed in favor of default values
   for object fields.
 * Low-level native API for loading and dumping has undergone changes to
   parameter order. Serialization and deserialization context is now first
   parameter, to be able to use prefix notation.
 * Removed ``PresentationStyle``; instead ``Dumper`` can be initialized with
   presets mirroring the former values of ``PresentationStyle``.
 * Removed deprecated ``YamlDocument`` type from DOM API.
   Use ``YamlNode`` instead.

Features:

 * Can now load and dump fields of the parent type(s) of used types (#131)
 * Updated type guessing to use regexes from YAML 1.2 instead of old YAML 1.1.
   Type guessing is used primarily for heterogeneous items
   (implicit variant objects).
 * Presenter no longer outputs trailing spaces
 * More presentation options
 * Simplified default presentation style: Don't output ``%YAML 1.2``,
   ``%TAG !n! ...`` or ``---`` by default.
   Output compact notation for collections.
 * Loading now works at compile time (#70, #91).
   Dumping doesn't work at compile time currently.

Bugfixes:

 * Don't crash on invalid input, instead raise a catchable
   ``YamlParserError`` (#129)
 * Fixed some parser errors in exotic edge cases
 * Several fixes to make the library work with Nim 2.x

## 1.1.0

Features:

 * ``YamlNode`` now contains node styles and preserves them
   when serializing to YAML again
 * Added ``maxLineLength`` to ``PresentationOptions``. (#119)
 * Added ``loadFlattened`` to resolve aliases while loading,
   instead of deserializing them into pointers. (#117)

Bugfixes:

 * Fixed problems with ARC/ORC (#120)
 * Fixes some edge cases around whitespace while parsing
 * Fixed a problem that made ``{.ignore: [].}`` fail when trying
   to ignore collection values. (#127)
 * Always write a newline character at the end of output, as required
   by POSIX for text files.
 * Fixed an error with loading recursive nodes into YamlNodes.
 * Fixed an error where ``0`` could not be loaded into an unsigned
   integer lvalue. (#123)
 * Fixed an error where `float32` values could not properly
   be deserialized. (#124)
 * Fixed a compiler error concerning stricteffects. (#125)

## 1.0.0

Features:

 * ``YamlNode`` can now be used with the serialization API (``load`` / ``dump``)
   and can be used to hold substructures that should not be deserialized to
   native types (#48).

Bugfixes:

 * Raise a proper exception when a stream contains no documents but one is
   expected (#108)
 * Comments after a block scalar do not lead to a crash anymore (#106)
 * Fixed an error with parsing document end markers (#115)
 * Fixed an error when serializing block scalars (#105)

## 0.16.0

Features:

 * dumping ``sparse`` objects now omits empty ``Option`` fields (#100).

Bugfixes:

 * Fixed several parser errors that emerged from updates on the test suite.
 * Fixed ``raises`` annotations which could lead to compilation errors (#99).

## 0.15.0

Features:

 * Compiles with --gc:arc and --gc:orc

Bugfixes:

 * Parser rewrite: Fixes some test suite errors (including #83)
 * Fixed problems where a syntax error lead to an invalid state (#39, #90)
 * Serialize boolean values as ``true`` / ``false`` instead of ``y`` / ``y``
   to conform to YAML 1.2 spec.

## 0.14.0

Features:

 * **Breaking change**:
   transient, defaultVal, ignore and implicit are now annotations.
 * Added ``sparse`` annotation to treat all ``Option`` fields as optional.

Bugfixes:

 * can now use default values with ref objects (#66)

## 0.13.1

Bugfixes:

 * Changed `nim tests` to `nim test` to make nim ci happy.

## 0.13.0

Bugfixes:

 * Fixed submodule link to yaml-test-suite.

Features:

 * Added support for `Option` type.

## 0.12.0

Bugfixes:

 * Made it work with Nim 0.20.2

### 0.11.0

Bugfixes:

 * Made it work with Nim 0.19.0

NimYAML 0.11.0 is unlikely to work with older Nim versions.

## 0.10.4

Bugfixes:

 * Made it work with Nim 0.18.0

### 0.10.3

Bugfixes:

 * Fixed a nimble error when installing the package.

Features:

 * Added `ignoreUnknownKeys` macro to ignore all mapping keys that do not map
   to a field of an object / tuple (#43).

### 0.10.2

Bugfixes:

 * Fixed a nimble warning (#42)
 * Make sure special strings (e.g. "null") are properly quoted when dumping JSON
   (#44)

### 0.10.1

Bugfixes:

 * Made it *actually* work with Nim 0.17.0.

### 0.10.0

Features:

 * Compatibility with Nim 0.17.0 (#40).
   **Important:** This fix breaks compatibility with previous
   Nim versions!

### 0.9.1

Features:

 * Added `YamlParser.display()` which is mainly used by tests
 * NimYAML now builds for JS target (but does not work properly yet)

Bugfixes:

 * Correctly present empty collections in block-only style (#33)
 * Correctly handle `{1}` (#34)
 * Recognize empty plain scalar as possible `!!null` value
 * Require colons before subsequent keys in a flow mapping (#35)
 * Allow stream end after block scalar indicators
 * Fixed regression bugs introduced with timestamp parsing (#37)

### 0.9.0

Features:

 * Better DOM API:
   - yMapping is now a Table
   - field names have changed to imitate those of Nim's json API
   - Better getter and setter procs
 * Added ability to resolve non-specific tags in presenter.transform

Bugfixes:

 * Fixed parsing floating point literals (#30)
 * Fixed a bug with variant records (#31)
 * Empty documents now always contain an empty scalar
 * Block scalars with indentation indicator now have correct whitespace on first
   line.

### 0.8.0

Features:

 * NimYAML now has a global tag URI prefix for Nim types,
   `tag:nimyaml.org,2016:`. This prefix is denoted by the custom tag handle
   `!n!`.
 * Support arbitrary tag handles.
 * Added ability to mark object and tuple fields as transient.
 * Added ability to set a default value for object fields.
 * Added ability to ignore key-value pairs in the input when loading object
   values.
 * Support `!!timestamp` by parsing it to `Time` from module `times`.

Bugfixes:

 * Fixed a bug concerning duplicate TagIds for different tags in the
   `serializationTagLibrary`
 * Convert commas in tag URIs to semicolons when using a tag URI as generic
   parameter to another one, because commas after the tag handle are interpreted
   as flow separators.

### 0.7.0

Features:

 * Better handling of internal error messages
 * Refactoring of low-level API:
   * No more usage of first-class iterators (not supported for JS target)
   * Added ability to directly use strings as input without stdlib's streams
     (which are not available for JS)
 * Added ability to parse octal and hexadecimal numbers
 * Restructuring of API: now available as submodules of yaml. For backwards
   compatibility, it is still possible to `import yaml`, which will import all
   submodules
 * Check for missing, duplicate and unknown fields when deserializing tuples and
   objects

Bugfixes:

 * Fixed double quotes inside plain scalar (#25)
 * Return correct line content for errors if possible (#23)
 * Some smaller lexer/parser fixes

### 0.6.3

Bugfixes:

 * Can load floats from integer literals (without decimal point) (#22)

### 0.6.2

Bugfixes:

 * Fixed problem when serializing a type that overloads the `==` operator (#19)
 * Fixed type hints for floats (`0` digit was not processed properly) (#21)

### 0.6.1

Bugfixes:

 * Fixed deserialization of floats (#17)
 * Handle IndexError from queues properly

### 0.6.0

Features:

 * Properly support variant object types
 * First version that works with a released Nim version (0.14.0)

Bugfixes:

 * Fixed a crash in presenter when outputting JSON or canonical YAML
 * Raise an exception when trying to output multiple documents in JSON style

### 0.5.1

Bugfixes:

 * Fixed a problem that was introduced by a change in Nim devel

### 0.5.0

Features:

 * Support variant object types (experimental)
 * Added ability to use variant object types to process
   heterogeneous data
 * Support `set` type
 * Support `array` type
 * Support `int`, `uint` and `float` types
   (previously, the precision must be specified)
 * Check for duplicate tag URIs at compile time
 * Renamed `setTagUriForType` to `setTagUri`

Bugfixes:

 * None, but fastparse.nim has seen heavy refactoring

### 0.4.0

Features:

 * Added option to output YAML 1.1
 * Added benchmark for processing YAML input
 * Serialization for OrderedMap
 * Use !nim:field for object field names (#12)

Bugfixes:

 * Code refactoring (#9, #10, #11, #13)
 * Some small improvements parsing and presenting

### 0.3.0

Features:

 * Renamed some symbols to improve consistency (#6):
   - `yamlStartSequence` -> `yamlStartSeq`
   - `yamlEndSequence` -> `yamlEndSeq`
   - `yamlStartDocument` -> `yamlStartDoc`
   - `yamlEndDocument` -> `yamlEndDoc`
   - `yTagMap` -> `yTagMapping`
 * Introduced `PresentationOptions`:
   - Let user specify newline style
   - Merged old presentation options `indentationStep` and `presentationStyle`
     into it
 * Use YAML test suite from `yaml-dev-kit` to test parser.

Bugfixes:

 * Fixed various parser bugs discovered with YAML test suite:
   - Block scalar as root node no longer leads to a parser error
   - Fixed a bug that caused incorrect handling of comments after plain scalars
   - Fixed bugs with newline handling of block scalars
   - Fixed a bug related to block sequence indentation
   - Skip content in tag and anchor names and single-quoted scalars when
     scanning for possible implicit map key
   - Properly handle more indented lines in folded block scalars
   - Fixed a problem with handling ':' after whitespace
   - Fixed indentation handling after block scalar

### 0.2.0

Features:

 * Added DOM API
 * Output block scalars in presenter if scalar is long and block scalar output
   is feasible. Else, use multiple lines for long scalars in double quotes.

Bugfixes:

 * Improved parser (#1, #3, #5)
 * Made parser correctly handle block sequences that have the same indentation
   as their parent node (#2)
 * Fixed problems with outputting double quoted strings (#4)

### 0.1.0

 * Initial release
