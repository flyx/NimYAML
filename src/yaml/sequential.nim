import streams, tables, strutils

import private.lexer

type
    YamlParserEventKind* = enum
        yamlStartDocument, yamlEndDocument, yamlStartMap, yamlEndMap,
        yamlStartSequence, yamlEndSequence, yamlScalar, yamlAlias,
        yamlError, yamlWarning
    
    YamlParserEvent* = ref object
        case kind*: YamlParserEventKind
        of yamlStartMap, yamlStartSequence:
            objAnchor* : string # may be nil, may not be empty
            objTag*    : string # may not be nil or empty, is a complete URI.
        of yamlScalar:
            scalarAnchor* : string # may be nil
            scalarTag*    : string # may not be nil, is a complete URI.
            scalarContent*: string # may not be nil (but empty)
        of yamlEndMap, yamlEndSequence, yamlStartDocument, yamlEndDocument:
            discard
        of yamlAlias:
            aliasName*   : string # may not be nil nor empty
        of yamlError, yamlWarning:
            description* : string
            line*        : int
            column*      : int
    
    YamlParserState = enum
        ylInitial, ylSkipDirective, ylBlock, ylFlow
    
    OutcomeEnum = enum
        oOkay, oWarn, oContinue
    
    LevelKind = enum
        lUnknown, lSequence, lMap
    
    DocumentLevel = object
        kind: LevelKind
        indicatorColumn: int
        readKey: bool
        anchor: string
        tag: string
    
template yieldWarning(d: string) {.dirty.} =
    yield YamlParserEvent(kind: yamlWarning, description: d,
                          line: lex.line, column: lex.column)

template yieldError(d: string) {.dirty.} =
    yield YamlParserEvent(kind: yamlError, description: d,
                          line: lex.line, column: lex.column)

template tag(): string {.dirty.} =
    if isNil(level.tag):
        case level.kind
        of lUnknown:
            result = "!!str"
        of lSequence:
            result = "!!seq"
        of lMap:
            result = "!!map"
    else:
        return level.tag

template closeLevel() {.dirty.} =
    case level.kind
    of lUnknown:
        yield YamlParserEvent(kind: yamlScalar, scalarAnchor: level.anchor,
                              scalarTag: tag(), scalarContent: "")
    of lSequence:
        yield YamlParserEvent(kind: yamlEndSequence)
    of lMap:
        yield YamlParserEvent(kind: yamlEndMap)

template closeLevelsByIndicator() {.dirty.} =
    while levels.len > 0:
        let level = levels[levels.high]
        if level.indicatorColumn > lex.column:
            closeLevel()
        else:
            break
        levels.pop()

iterator events*(input: Stream): YamlParserEvent =
    var
        state = ylInitial
        lex   : YamlLexer
        foundYamlDirective = false
        tagShorthands = initTable[string, string]()
        levels = initSeq[DocumentLevel]()
        curIndentation: int
    lex.open(input)
    
    var nextToken = lexer.tokens
    var token = nextToken(lex)
    while not finished(nextToken):
        case state
        of ylInitial:
            case token.kind
            of yamlYamlDirective:
                if foundYamlDirective:
                    yield YamlParserEvent(kind: yamlError,
                            description: "Duplicate %YAML tag",
                            line:   lex.line,
                            column: lex.column)
                    state = ylSkipDirective
                else:
                    var
                        outcome = oOkay
                        actualVersion = ""
                    for version in [1, 2]:
                        token = nextToken(lex)
                        if finished(nextToken):
                            yieldError("Missing or badly formatted YAML version")
                            outcome = oContinue
                            break
                        if token.kind != yamlVersionPart:
                            yieldError("Missing or badly formatted YAML version")
                            outcome = oContinue
                            break
                        if parseInt(lex.content) != version:
                            outcome = oWarn
                        if actualVersion.len > 0: actualVersion &= "."
                        actualVersion &= $version
                    case outcome
                    of oContinue:
                        continue
                    of oWarn:
                        yieldWarning("Unsupported version: " & actualVersion &
                                     ", trying to parse anyway")
                    else:
                        discard
                    foundYamlDirective = true
            of yamlTagDirective:
                token = nextToken(lex)
                if finished(nextToken):
                    yieldError("Incomplete %TAG directive")
                    continue
                if token.kind != yamlTagHandle:
                    yieldError("Invalid token (expected tag handle)")
                    state = ylSkipDirective
                    continue
                let tagHandle = lex.content
                token = nextToken(lex)
                if finished(nextToken):
                    yieldError("Incomplete %TAG directive")
                    continue
                if token.kind != yamlTagURI:
                    yieldError("Invalid token (expected tag URI)")
                    state = ylSkipDirective
                    continue
                tagShorthands[tagHandle] = lex.content
            of yamlUnknownDirective:
                yieldWarning("Unknown directive: " & lex.content)
                state = ylSkipDirective
            of yamlComment:
                discard
            of yamlDirectivesEnd:
                yield YamlParserEvent(kind: yamlStartDocument)
                state = ylLineStart
            of yamlDocumentEnd:
                yield YamlParserEvent(kind: yamlStartDocument)
                yield YamlParserEvent(kind: yamlEndDocument)
            else:
                yield YamlParserEvent(kind: yamlStartDocument)
                state = ylLineStart
                continue
        of ylSkipDirective:
            if token.kind not in [yamlUnknownDirectiveParam, yamlTagHandle,
                                  yamlTagURI, yamlVersionPart, yamlComment]:
                state = ylInitial
                continue
        of ylBlock:
            case token.kind
            of yamlLineStart:
                discard
            of yamlDash:
                closeLevelsByIndicator()
                if levels.count > 0:
                    let level = levels[levels.high]
                    if level.kind == lUnknown:
                        level.kind = lSequence
                        level.indicatorColumn = lex.column
                        levels.add(DocumentLevel(kind: lUnknown,
                                                 indicatorColumn = -1,
                                                 readKey: false,
                                                 anchor: nil, tag: nil))
                    elif level.indicatorColumn < lex.column:
                        yieldError("Invalid indentation for '-'")
                    elif level.kind == lSequence:
                        levels.add(DocumentLevel(kind: lUnknown,
                                                 indicatorColumn: -1,
                                                 readKey: false,
                                                 anchor: nil, tag: nil))
                    else:
                        yieldError("Unexpected token: '-'")
                else:
                    levels.add(DocumentLevel(kind: lSequence,
                                             indicatorColumn: lex.column,
                                             readKey: false,
                                             anchor: nil, tag: nil))
                    levels.add(DocumentLevel(kind: lUnknown,
                                             indicatorColmun: -1,
                                             readKey: false,
                                             anchor: nil, tag: nil))
            of yamlQuestionmark:
            
            of yamlColon:
                    
                
        else:
            discard
            
        
        token = nextToken(lex)