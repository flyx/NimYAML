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