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
