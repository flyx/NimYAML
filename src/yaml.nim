import streams, unicode, lexbase, tables, strutils

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

# interface

proc parse*(parser: YamlSequentialParser, s: Stream): iterator(): YamlParserEvent

# implementation

include private.lexer
include private.sequential