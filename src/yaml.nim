import streams, unicode, lexbase, tables, strutils, json, hashes

type
    YamlTypeHint* = enum
        yTypeInteger, yTypeFloat, yTypeBoolean, yTypeNull, yTypeString,
        yTypeUnknown
    
    YamlParserEventKind* = enum
        yamlStartDocument, yamlEndDocument, yamlStartMap, yamlEndMap,
        yamlStartSequence, yamlEndSequence, yamlScalar, yamlAlias,
        yamlError, yamlWarning
    
    TagId* = distinct int
    AnchorId* = distinct int
    
    YamlParserEvent* = ref object
        case kind*: YamlParserEventKind
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
    
    YamlSequentialParser* = ref object
        tags: OrderedTable[string, TagId]
        anchors: OrderedTable[string, AnchorId]

const
    tagExclamationMark*: TagId = 0.TagId # "!" non-specific tag
    tagQuestionMark*   : TagId = 1.TagId # "?" non-specific tag
    anchorNone*: AnchorId = (-1).AnchorId   # no anchor defined

# interface

proc `==`*(left: YamlParserEvent, right: YamlParserEvent): bool

proc `==`*(left, right: TagId): bool {.borrow.}
proc `$`*(id: TagId): string {.borrow.}
proc hash*(id: TagId): Hash {.borrow.}

proc `==`*(left, right: AnchorId): bool {.borrow.}
proc `$`*(id: AnchorId): string {.borrow.}
proc hash*(id: AnchorId): Hash {.borrow.}

proc newParser*(): YamlSequentialParser

proc uri*(parser: YamlSequentialParser, id: TagId): string

proc registerUri*(parser: var YamlSequentialParser, uri: string): TagId 

proc anchor*(parser: YamlSequentialParser, id: AnchorId): string

proc parse*(parser: YamlSequentialParser, s: Stream):
        iterator(): YamlParserEvent

proc parseToJson*(s: Stream): seq[JsonNode]
proc parseToJson*(s: string): seq[JsonNode]

# implementation

include private.lexer
include private.sequential
include private.json