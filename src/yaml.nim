## This module provides facilities to generate and interpret
## `YAML <http://yaml.org>`_ character streams. All primitive operations on
## data objects use a ``YamlStream`` either as source or as output. Because this
## stream is implemented as iterator, it is possible to process YAML input and
## output sequentially, i.e. without loading the processed data structure
## completely into RAM. This supports processing of large data structures.
##
## As YAML is a strict superset of `JSON <http://json.org>`_, JSON input is
## automatically supported. Additionally, there is functionality available to
## convert any YAML stream into JSON. While JSON is less readable than YAML,
## this enhances interoperability with other languages.

import streams, unicode, lexbase, tables, strutils, json, hashes, queues, macros

type
    YamlTypeHint* = enum
        ## A type hint is a friendly message from the YAML lexer, telling you
        ## it thinks a scalar string probably is of a certain type. You are not
        ## required to adhere to this information. The first matching RegEx will
        ## be the type hint of a scalar string.
        ##
        ## ================== =========================
        ## Name               RegEx
        ## ================== =========================
        ## ``yTypeInteger``   ``0 | -? [1-9] [0-9]*``
        ## ``yTypeFloat``     ``-? [1-9] ( \. [0-9]* [1-9] )? ( e [-+] [1-9] [0-9]* )?``
        ## ``yTypeFloatInf``  ``-? \. (inf | Inf | INF)``
        ## ``yTypeFloatNaN``  ``-? \. (nan | NaN | NAN)``
        ## ``yTypeBoolTrue``  ``y|Y|yes|Yes|YES|true|True|TRUE|on|On|ON``
        ## ``yTypeBoolFalse`` ``n|N|no|No|NO|false|False|FALSE|off|Off|OFF``
        ## ``yTypeNull``      ``~ | null | Null | NULL``
        ## ``yTypeString``    *none*
        ## ``yTypeUnknown``   ``*``
        ##
        ## The value `yTypeString` is not returned based on RegExes, but for
        ## scalars that are quoted within the YAML input character stream.
        yTypeInteger, yTypeFloat, yTypeFloatInf, yTypeFloatNaN, yTypeBoolTrue,
        yTypeBoolFalse, yTypeNull, yTypeString, yTypeUnknown
    
    YamlStreamEventKind* = enum
        yamlStartDocument, yamlEndDocument, yamlStartMap, yamlEndMap,
        yamlStartSequence, yamlEndSequence, yamlScalar, yamlAlias,
        yamlError, yamlWarning
    
    TagId* = distinct int
    AnchorId* = distinct int
    
    YamlStreamEvent* = object
        case kind*: YamlStreamEventKind
        of yamlStartMap:
            mapAnchor* : AnchorId
            mapTag*    : TagId
            mapMayHaveKeyObjects* : bool
        of yamlStartSequence:
            seqAnchor* : AnchorId
            seqTag*    : TagId
        of yamlScalar:
            scalarAnchor* : AnchorId
            scalarTag*    : TagId
            scalarContent*: string # may not be nil (but empty)
            scalarType*   : YamlTypeHint
        of yamlEndMap, yamlEndSequence, yamlStartDocument, yamlEndDocument:
            discard
        of yamlAlias:
            aliasTarget* : AnchorId
        of yamlError, yamlWarning:
            description* : string
            line*        : int
            column*      : int
    
    YamlStream* = iterator(): YamlStreamEvent
    
    YamlTagLibrary* = object
        tags: Table[string, TagId]
        nextCustomTagId*: TagId 
    
    YamlSequentialParser* = ref object
        tagLib: YamlTagLibrary
        anchors: OrderedTable[string, AnchorId]
    
    YamlDumpStyle* = enum
        yDumpMinimal, yDumpCanonical, yDumpDefault, yDumpJson, yDumpBlockOnly
const
    # failsafe schema

    tagExclamationMark*: TagId = 0.TagId ## ``!`` non-specific tag
    tagQuestionMark*   : TagId = 1.TagId ## ``?`` non-specific tag
    tagString*         : TagId = 2.TagId ## \
        ## `!!str <http://yaml.org/type/str.html >`_ tag
    tagSequence*       : TagId = 3.TagId ## \
        ## `!!seq <http://yaml.org/type/seq.html>`_ tag
    tagMap*            : TagId = 4.TagId ## \
        ## `!!map <http://yaml.org/type/map.html>`_ tag
    
    # json & core schema
    
    tagNull*    : TagId = 5.TagId ## \
        ## `!!null <http://yaml.org/type/null.html>`_ tag
    tagBoolean* : TagId = 6.TagId ## \
        ## `!!bool <http://yaml.org/type/bool.html>`_ tag
    tagInteger* : TagId = 7.TagId ## \
        ## `!!int <http://yaml.org/type/int.html>`_ tag
    tagFloat*   : TagId = 8.TagId ## \
        ## `!!float <http://yaml.org/type/float.html>`_ tag
    
    # other language-independent YAML types (from http://yaml.org/type/ )
    
    tagOrderedMap* : TagId = 9.TagId  ## \
        ## `!!omap <http://yaml.org/type/omap.html>`_ tag
    tagPairs*      : TagId = 10.TagId ## \
        ## `!!pairs <http://yaml.org/type/pairs.html>`_ tag
    tagSet*        : TagId = 11.TagId ## \
        ## `!!set <http://yaml.org/type/set.html>`_ tag
    tagBinary*     : TagId = 12.TagId ## \
        ## `!!binary <http://yaml.org/type/binary.html>`_ tag
    tagMerge*      : TagId = 13.TagId ## \
        ## `!!merge <http://yaml.org/type/merge.html>`_ tag
    tagTimestamp*  : TagId = 14.TagId ## \
        ## `!!timestamp <http://yaml.org/type/timestamp.html>`_ tag
    tagValue*      : TagId = 15.TagId ## \
        ## `!!value <http://yaml.org/type/value.html>`_ tag
    tagYaml*       : TagId = 16.TagId ## \
        ## `!!yaml <http://yaml.org/type/yaml.html>`_ tag
    
    anchorNone*: AnchorId = (-1).AnchorId # no anchor defined

# interface

proc `==`*(left: YamlStreamEvent, right: YamlStreamEvent): bool
proc `$`*(event: YamlStreamEvent): string

proc `==`*(left, right: TagId): bool {.borrow.}
proc `$`*(id: TagId): string {.borrow.}
proc hash*(id: TagId): Hash {.borrow.}

proc `==`*(left, right: AnchorId): bool {.borrow.}
proc `$`*(id: AnchorId): string {.borrow.}
proc hash*(id: AnchorId): Hash {.borrow.}

proc initTagLibrary*(): YamlTagLibrary
proc registerUri*(tagLib: var YamlTagLibrary, uri: string): TagId
proc uri*(tagLib: YamlTagLibrary, id: TagId): string

# these should be consts, but the Nim VM still has problems handling tables
# properly, so we use constructor procs instead.

proc failsafeTagLibrary*(): YamlTagLibrary
proc coreTagLibrary*(): YamlTagLibrary
proc extendedTagLibrary*(): YamlTagLibrary

proc newParser*(tagLib: YamlTagLibrary): YamlSequentialParser

proc anchor*(parser: YamlSequentialParser, id: AnchorId): string

proc parse*(parser: YamlSequentialParser, s: Stream): YamlStream

proc parseToJson*(s: Stream): seq[JsonNode]
proc parseToJson*(s: string): seq[JsonNode]

proc dump*(s: YamlStream, target: Stream, tagLib: YamlTagLibrary,
           style: YamlDumpStyle = yDumpDefault, indentationStep: int = 2)

proc transform*(input: Stream, output: Stream, style: YamlDumpStyle,
                indentationStep: int = 2)

# implementation

include private.lexer
include private.tagLibrary
include private.sequential
include private.json
include private.dumper