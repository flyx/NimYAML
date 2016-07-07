### 0.6.2

Bugfixes:

 * Fixed problem when serializing a type that overloads the `==` operator (#19)
 * Fixed type hints for floats (`0` digit was not processed properly)

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