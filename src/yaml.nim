import streams, unicode, lexbase, tables, strutils, json, hashes

type
    YamlTypeHint* = enum
        yTypeInteger, yTypeFloat, yTypeBoolean, yTypeNull, yTypeString,
        yTypeUnknown
    
    YamlStreamEventKind* = enum
        yamlStartDocument, yamlEndDocument, yamlStartMap, yamlEndMap,
        yamlStartSequence, yamlEndSequence, yamlScalar, yamlAlias,
        yamlError, yamlWarning
    
    TagId* = distinct int
    AnchorId* = distinct int
    
    YamlStreamEvent* = object
        case kind*: YamlStreamEventKind
        of yamlStartMap, yamlStartSequence:
            objAnchor* : AnchorId
            objTag*    : TagId
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

const
    # failsafe schema

    tagExclamationMark*: TagId = 0.TagId # "!" non-specific tag
    tagQuestionMark*   : TagId = 1.TagId # "?" non-specific tag
    tagString*         : TagId = 2.TagId # !!str tag
    tagSequence*       : TagId = 3.TagId # !!seq tag
    tagMap*            : TagId = 4.TagId # !!map tag
    
    # json & core schema
    
    tagNull*    : TagId = 5.TagId # !!null tag
    tagBoolean* : TagId = 6.TagId # !!bool tag
    tagInteger* : TagId = 7.TagId # !!int tag
    tagFloat*   : TagId = 8.TagId # !!float tag
    
    # other language-independent YAML types (from http://yaml.org/type/ )
    
    tagOrderedMap* : TagId = 9.TagId  # !!omap tag
    tagPairs*      : TagId = 10.TagId # !!pairs tag
    tagSet*        : TagId = 11.TagId # !!set tag
    tagBinary*     : TagId = 12.TagId # !!binary tag
    tagMerge*      : TagId = 13.TagId # !!merge tag
    tagTimestamp*  : TagId = 14.TagId # !!timestamp tag
    tagValue*      : TagId = 15.TagId # !!value tag
    tagYaml*       : TagId = 16.TagId # !!yaml tag
    
    anchorNone*: AnchorId = (-1).AnchorId # no anchor defined

# interface

proc `==`*(left: YamlStreamEvent, right: YamlStreamEvent): bool

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

# implementation

include private.lexer
include private.tagLibrary
include private.sequential
include private.json
