import streams, tables, strutils

import "private/lexer"

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
        ylInitial, ylSkipDirective, ylBlockLineStart, ylBlockAfterScalar,
        ylBlockAfterColon, ylBlockLineEnd, ylFlow
    
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

proc `==`*(left: YamlParserEvent, right: YamlParserEvent): bool =
    if left.kind != right.kind:
        return false
    case left.kind
    of yamlStartDocument, yamlEndDocument, yamlEndMap, yamlEndSequence:
        result = true
    of yamlStartMap, yamlStartSequence:
        result = left.objAnchor == right.objAnchor and
                 left.objTag == right.objTag
    of yamlScalar:
        result = left.scalarAnchor == right.scalarAnchor and
                 left.scalarTag == right.scalarTag and
                 left.scalarContent == right.scalarContent
    of yamlAlias:
        result = left.aliasName == right.aliasName
    of yamlError, yamlWarning:
        result = left.description == right.description and
                 left.line == right.line and left.column == right.column
    
template yieldWarning(d: string) {.dirty.} =
    yield YamlParserEvent(kind: yamlWarning, description: d,
                          line: lex.line, column: lex.column)

template yieldError(d: string) {.dirty.} =
    yield YamlParserEvent(kind: yamlError, description: d,
                          line: lex.line, column: lex.column)

template closeLevel() {.dirty.} =
    case level.kind
    of lUnknown:
        yield YamlParserEvent(kind: yamlScalar, scalarAnchor: level.anchor,
                              scalarTag: level.tag, scalarContent: "")
    of lSequence:
        yield YamlParserEvent(kind: yamlEndSequence)
    of lMap:
        yield YamlParserEvent(kind: yamlEndMap)

template closeLevelsByIndicator() {.dirty.} =
    while levels.len > 0:
        let level = levels[levels.high]
        if level.indicatorColumn > lex.column:
            closeLevel()
        elif level.indicatorColumn == -1:
            if levels[levels.high - 1].indicatorColumn >= lex.column:
                echo "seq ind col: ", levels[levels.high - 1].indicatorColumn, ", lex.column: ", lex.column
                closeLevel()
            else:
                break
        else:
            break
        discard levels.pop()

template closeAllLevels() {.dirty.} =
    while levels.len > 0:
        var level = levels.pop()
        closeLevel()

iterator events*(input: Stream): YamlParserEvent {.closure.} =
    var
        state = ylInitial
        lex   : YamlLexer
        foundYamlDirective = false
        tagShorthands = initTable[string, string]()
        levels = newSeq[DocumentLevel]()
        curIndentation: int
        cachedScalar: YamlParserEvent
        cachedScalarIndentation: int
    lex.open(input)
    
    var nextToken = tokens
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
                state = ylBlockLinestart
            of yamlDocumentEnd, yamlStreamEnd:
                yield YamlParserEvent(kind: yamlStartDocument)
                yield YamlParserEvent(kind: yamlEndDocument)
            else:
                yield YamlParserEvent(kind: yamlStartDocument)
                state = ylBlockLineStart
                continue
        of ylSkipDirective:
            if token.kind notin [yamlUnknownDirectiveParam, yamlTagHandle,
                                 yamlTagURI, yamlVersionPart, yamlComment]:
                state = ylInitial
                continue
        of ylBlockLineStart:
            case token.kind
            of yamlLineStart:
                discard
            of yamlDash:
                closeLevelsByIndicator()
                if levels.len > 0:
                    var level = addr(levels[levels.high])
                    if level.kind == lUnknown:
                        level.kind = lSequence
                        level.indicatorColumn = lex.column
                        levels.add(DocumentLevel(kind: lUnknown,
                                                 indicatorColumn: -1,
                                                 readKey: false,
                                                 anchor: nil, tag: nil))
                        yield YamlParserEvent(kind: yamlStartSequence,
                                              objAnchor: level.anchor,
                                              objTag: level.tag)
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
                                             indicatorColumn: -1,
                                             readKey: false,
                                             anchor: nil, tag: nil))
                    yield YamlParserEvent(kind: yamlStartSequence,
                                          objAnchor: nil, objTag: nil)
            of yamlQuestionmark, yamlColon:
                closeLevelsByIndicator()
                if levels.len > 0:
                    var level = addr(levels[levels.high])
                    if level.kind == lUnknown:
                        level.kind = lMap
                        level.indicatorColumn = lex.column
                        levels.add(DocumentLevel(kind: lUnknown,
                                                 indicatorColumn: -1,
                                                 readKey: true,
                                                 anchor: nil, tag: nil))
                        yield YamlParserEvent(kind: yamlStartMap,
                                              objAnchor: level.anchor,
                                              objTag: level.tag)
                        if token.kind == yamlColon:
                            yield YamlParserEvent(kind: yamlScalar,
                                                  scalarAnchor: level.anchor,
                                                  scalarTag: level.tag,
                                                  scalarContent: "")
                            level.readKey = false
                    elif level.indicatorColumn < lex.column:
                        yieldError("Invalid indentation for '?'")
                    elif level.kind == lMap and level.readKey ==
                            (token.kind == yamlColon):
                        level.readKey = true
                        levels.add(DocumentLevel(kind: lUnknown,
                                                 indicatorColumn: -1,
                                                 readKey: (token.kind == yamlQuestionmark),
                                                 anchor: nil, tag: nil))
                    else:
                        yieldError("Unexpected token: '?'")
                else:
                    levels.add(DocumentLevel(kind: lMap,
                                             indicatorColumn: lex.column,
                                             readKey: true,
                                             anchor: nil, tag: nil))
                    var level = addr(levels[levels.high])
                    levels.add(DocumentLevel(kind: lUnknown,
                                             indicatorColumn: -1,
                                             readKey: false,
                                             anchor: nil, tag: nil))
                    yield YamlParserEvent(kind: yamlStartMap,
                                          objAnchor: nil,
                                          objTag: nil)
                    if token.kind == yamlColon:
                        yield YamlParserEvent(kind: yamlScalar,
                                              scalarAnchor: nil,
                                              scalarTag: nil,
                                              scalarContent: "")
                        level.readKey = false
            of yamlTagHandle:
                var level = addr(levels[levels.high])
                let handle = lex.content
                if tagShorthands.hasKey(handle):
                    token = nextToken(lex)
                    if finished(nextToken):
                        yieldError("Missing tag suffix")
                        continue
                    if token.kind != yamlTagSuffix:
                        yieldError("Missing tag suffix")
                        continue
                    level.tag = tagShorthands[handle] & lex.content
                else:
                    yieldError("Unknown tag shorthand: " & handle)
            of yamlVerbatimTag:
                levels[levels.high].tag = lex.content
            of lexer.yamlScalar:
                closeLevelsByIndicator()
                if levels.len > 0:
                    let level = levels.pop()
                    if level.kind != lUnknown:
                        yieldError("Unexpected scalar in " & $level.kind)
                    else:
                        cachedScalar = YamlParserEvent(kind: yamlScalar,
                                scalarAnchor: level.anchor,
                                scalarTag: level.tag,
                                scalarContent: lex.content)
                        cachedScalarIndentation = lex.column
                else:
                    cachedScalar = YamlParserEvent(kind: yamlScalar,
                            scalarAnchor: nil, scalarTag: nil,
                            scalarContent: lex.content)
                    cachedScalarIndentation = lex.column
                state = ylBlockAfterScalar
            of yamlStreamEnd:
                closeAllLevels()
                yield YamlParserEvent(kind: yamlEndDocument)
                break
            of yamlDocumentEnd:
                closeAllLevels()
                yield YamlParserEvent(kind: yamlEndDocument)
                state = ylInitial
            else:
                yieldError("Unexpected token: " & $token.kind)
        of ylBlockAfterScalar:
            case token.kind
            of yamlColon:
                var level: ptr DocumentLevel = nil
                if levels.len > 0:
                    level = addr(levels[levels.high])
                if level == nil or level.kind != lUnknown:
                    levels.add(DocumentLevel(kind: lUnknown))
                    level = addr(levels[levels.high])
                level.kind = lMap
                level.indicatorColumn = cachedScalarIndentation
                level.readKey = true
                yield YamlParserEvent(kind: yamlStartMap)
                yield cachedScalar
                levels.add(DocumentLevel(kind: lUnknown,
                                         indicatorColumn: -1))
                cachedScalar = nil
                state = ylBlockAfterColon
            of yamlLineStart:
                yield cachedScalar
                state = ylBlockLineStart
            of yamlStreamEnd:
                yield cachedScalar
                closeAllLevels()
                yield YamlParserEvent(kind: yamlEndDocument)
                break
            else:
                yieldError("Unexpected token: " & $token.kind)
        of ylBlockAfterColon:
            case token.kind
            of lexer.yamlScalar:
                var level = levels.pop()
                yield YamlParserEvent(kind: yamlScalar,
                        scalarAnchor: level.anchor, scalarTag: level.tag,
                        scalarContent: lex.content)
                state = ylBlockLineEnd
            of yamlLineStart:
                state = ylBlockLineStart
            of yamlStreamEnd:
                closeAllLevels()
                yield YamlParserEvent(kind: yamlEndDocument)
                break
            else:
                yieldError("Unexpected token (expected scalar or line end): " &
                           $token.kind)
        of ylBlockLineEnd:
            case token.kind
            of yamlLineStart:
                state = ylBlockLineStart
            of yamlStreamEnd:
                closeAllLevels()
                yield YamlParserEvent(kind: yamlEndDocument)
                break
            else:
                yieldError("Unexpected token (expected line end):" &
                           $token.kind)
        else:
            discard
        token = nextToken(lex)