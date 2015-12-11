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
        ylInitial, ylSkipDirective, ylBlockLineStart, ylBlockAfterTag,
        ylBlockAfterAnchor, ylBlockAfterScalar, ylBlockAfterColon,
        ylBlockLineEnd, ylFlow, ylFlowAfterObject, ylExpectingDocumentEnd
    
    DocumentLevelMode = enum
        mBlockSequenceItem, mFlowSequenceItem, mExplicitBlockMapKey,
        mExplicitBlockMapValue, mImplicitBlockMapKey, mImplicitBlockMapValue,
        mFlowMapKey, mFlowMapValue, mUnknown
    
    DocumentLevel = object
        mode: DocumentLevelMode
        indicatorColumn: int
        indentationColumn: int

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
    break parserLoop

template yieldScalar(content: string = "") {.dirty.} =
    yield YamlParserEvent(kind: yamlScalar,
            scalarAnchor: anchor, scalarTag: tag,
            scalarContent: content)
    anchor = nil
    tag = nil

template yieldStart(k: YamlParserEventKind) {.dirty.} =
    yield YamlParserEvent(kind: k, objAnchor: anchor, objTag: tag)
    anchor = nil
    tag = nil

template closeLevel(lvl: DocumentLevel) {.dirty.} =
    case lvl.mode
    of mExplicitBlockMapKey, mFlowMapKey:
        yieldError("Missing Map value!")
    of mExplicitBlockMapValue, mImplicitBlockMapKey, mImplicitBlockMapValue,
       mFlowMapValue:
        yield YamlParserEvent(kind: yamlEndMap)
    of mBlockSequenceItem, mFlowSequenceItem:
        yield YamlParserEvent(kind: yamlEndSequence)
    else:
        yieldScalar()      

template leaveMoreIndentedLevels() {.dirty.} =
    while level.indicatorColumn > lex.column or
          (level.indicatorColumn == -1 and
           level.indentationColumn > lex.column):
        closeLevel(level)
        level = ancestry.pop()
           
template closeAllLevels() {.dirty.} =
    while true:
        closeLevel(level)
        if ancestry.len == 0: break
        level = ancestry.pop()

template handleBlockIndicator(expected, next: DocumentLevelMode,
                              entering: YamlParserEventKind) {.dirty.} =
    leaveMoreIndentedLevels()
    if level.indicatorColumn == lex.column:
        if level.mode == expected:
            level.mode = next
            ancestry.add(level)
            level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                  indentationColumn: -1)
        else:
            yieldError("Invalid token after " & $level.mode)
    elif level.mode != mUnknown:
        yieldError("Invalid indentation")
    elif entering == yamlError:
        yieldError("Unexpected token: " & $token)
    else:
        level.mode = next
        level.indicatorColumn = lex.column
        yield YamlParserEvent(kind: entering)
        ancestry.add(level)
        level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                              indentationColumn: -1)

iterator events*(input: Stream): YamlParserEvent {.closure.} =
    var
        lex: YamlLexer
        foundYamlDirective = false
        tagShorthands = initTable[string, string]()
        ancestry = newSeq[DocumentLevel]()
        level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                              indentationColumn: -1)
        cachedScalar: YamlParserEvent
        cachedScalarIndentation: int
        tag: string = nil
        anchor: string = nil
        state = ylInitial
    lex.open(input)
    
    var nextToken = tokens
    var token = nextToken(lex)
    block parserLoop:
      while not finished(nextToken):
        case state
        of ylInitial:
            case token
            of yamlYamlDirective:
                if foundYamlDirective:
                    yieldError("Duplicate %YAML directive")
                var
                    warn = false
                    actualVersion = ""
                for version in [1, 2]:
                    token = nextToken(lex)
                    if finished(nextToken):
                        yieldError("Missing or badly formatted YAML version")
                    if token != yamlVersionPart:
                        yieldError("Missing or badly formatted YAML version")
                    if parseInt(lex.content) != version:
                        warn = true
                    if actualVersion.len > 0: actualVersion &= "."
                    actualVersion &= $version
                if warn:
                    yieldWarning("Unsupported version: " & actualVersion &
                                 ", trying to parse anyway")
                foundYamlDirective = true
            of yamlTagDirective:
                token = nextToken(lex)
                if finished(nextToken):
                    yieldError("Incomplete %TAG directive")
                if token != yamlTagHandle:
                    yieldError("Invalid token (expected tag handle)")
                let tagHandle = lex.content
                token = nextToken(lex)
                if finished(nextToken):
                    yieldError("Incomplete %TAG directive")
                if token != yamlTagURI:
                    yieldError("Invalid token (expected tag URI)")
                tagShorthands[tagHandle] = lex.content
            of yamlUnknownDirective:
                yieldWarning("Unknown directive: " & lex.content)
                state = ylSkipDirective
            of yamlComment:
                discard
            of yamlDirectivesEnd:
                yield YamlParserEvent(kind: yamlStartDocument)
                level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                      indentationColumn: -1)
                state = ylBlockLineStart
            of yamlDocumentEnd, yamlStreamEnd:
                yield YamlParserEvent(kind: yamlStartDocument)
                yield YamlParserEvent(kind: yamlEndDocument)
            else:
                yield YamlParserEvent(kind: yamlStartDocument)
                state = ylBlockLineStart
                continue
        of ylSkipDirective:
            if token notin [yamlUnknownDirectiveParam, yamlTagHandle,
                            yamlTagURI, yamlVersionPart, yamlComment]:
                state = ylInitial
                continue
        of ylBlockLineStart:
            case token
            of yamlLineStart:
                discard
            of yamlDash:
                handleBlockIndicator(mBlockSequenceItem, mBlockSequenceItem,
                                     yamlStartSequence)
            of yamlQuestionmark:
                handleBlockIndicator(mExplicitBlockMapValue,
                                     mExplicitBlockMapKey, yamlStartMap)
            of yamlColon:
                handleBlockIndicator(mExplicitBlockMapKey,
                                     mExplicitBlockMapValue, yamlError)
            of yamlTagHandle:
                let handle = lex.content
                if tagShorthands.hasKey(handle):
                    token = nextToken(lex)
                    if finished(nextToken):
                        yieldError("Missing tag suffix")
                        continue
                    if token != yamlTagSuffix:
                        yieldError("Missing tag suffix")
                        continue
                    tag = tagShorthands[handle] & lex.content
                    state = ylBlockAfterTag
                else:
                    yieldError("Unknown tag shorthand: " & handle)
            of yamlVerbatimTag:
                tag = lex.content
            of yamlAnchor:
                anchor = lex.content
                state = ylBlockAfterAnchor
            of lexer.yamlScalar:
                leaveMoreIndentedLevels()
                case level.mode
                of mUnknown, mImplicitBlockMapKey:
                    cachedScalar = YamlParserEvent(kind: yamlScalar,
                            scalarAnchor: anchor,
                            scalarTag: tag,
                            scalarContent: lex.content)
                    anchor = nil
                    tag = nil
                    cachedScalarIndentation = lex.column
                    state = ylBlockAfterScalar
                else:
                    yieldError("Unexpected scalar")
            of yamlStreamEnd:
                closeAllLevels()
                yield YamlParserEvent(kind: yamlEndDocument)
                break
            of yamlDocumentEnd:
                closeAllLevels()
                yield YamlParserEvent(kind: yamlEndDocument)
                state = ylInitial
            of yamlOpeningBrace:
                state = ylFlow
                continue
            of yamlOpeningBracket:
                state = ylFlow
                continue
            else:
                yieldError("Unexpected token: " & $token)
        of ylBlockAfterScalar:
            case token
            of yamlColon:
                assert level.mode == mUnknown or
                       level.mode == mImplicitBlockMapKey
                if level.mode == mUnknown:
                    level.indentationColumn = cachedScalarIndentation
                    yieldStart(yamlStartMap)
                level.mode = mImplicitBlockMapValue
                ancestry.add(level)
                level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                      indentationColumn: -1)
                yield cachedScalar
                cachedScalar = nil
                state = ylBlockAfterColon
            of yamlLineStart:
                if level.mode == mImplicitBlockMapKey:
                    yieldError("Missing colon after implicit map key")
                yield cachedScalar
                cachedScalar = nil
                if ancestry.len > 0:
                    level = ancestry.pop()
                    state = ylBlockLineStart
                else:
                    state = ylExpectingDocumentEnd
            of yamlStreamEnd:
                yield cachedScalar
                cachedScalar = nil
                if ancestry.len > 0:
                    level = ancestry.pop()
                    closeAllLevels()
                yield YamlParserEvent(kind: yamlEndDocument)
                break
            else:
                yieldError("Unexpected token: " & $token)
        of ylBlockAfterTag:
            case token
            of yamlAnchor:
                anchor = lex.content
                state = ylBlockAfterAnchor
            of lexer.yamlScalar:
                state = ylBlockLineStart
                continue
            of yamlLineStart:
                state = ylBlockLineStart
            of yamlOpeningBracket, yamlOpeningBrace:
                state = ylFlow
                continue
            else:
                yieldError("Unexpected token: " & $token)
        of ylBlockAfterAnchor:
            case token
            of lexer.yamlScalar:
                anchor = lex.content
                state = ylBlockLineStart
                continue
            of yamlLineStart:
                state = ylBlockLineStart
            of yamlOpeningBracket, yamlOpeningBrace:
                state = ylFlow
                continue
            else:
                yieldError("Unexpected token: " & $token)
        of ylBlockAfterColon:
            case token
            of lexer.yamlScalar:
                yieldScalar(lex.content)
                level = ancestry.pop()
                assert level.mode == mImplicitBlockMapValue
                level.mode = mImplicitBlockMapKey
                state = ylBlockLineEnd
            of yamlLineStart:
                state = ylBlockLineStart
            of yamlStreamEnd:
                closeAllLevels()
                yield YamlParserEvent(kind: yamlEndDocument)
                break
            of yamlOpeningBracket, yamlOpeningBrace:
                state = ylFlow
                continue
            else:
                yieldError("Unexpected token (expected scalar or line end): " &
                           $token)
        of ylBlockLineEnd:
            case token
            of yamlLineStart:
                state = ylBlockLineStart
            of yamlStreamEnd:
                closeAllLevels()
                yield YamlParserEvent(kind: yamlEndDocument)
                break
            else:
                yieldError("Unexpected token (expected line end):" & $token)
        of ylFlow:
            case token
            of yamlLineStart:
                discard
            of lexer.yamlScalar:
                yieldScalar(lex.content)
                level = ancestry.pop()
                state = ylFlowAfterObject
            of yamlColon:
                yieldScalar()
                level = ancestry.pop()
                if level.mode == mFlowMapKey:
                    level.mode = mFlowMapValue
                    ancestry.add(level)
                    level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                          indentationColumn: -1)
                else:
                    yieldError(
                        "Unexpected token (expected scalar, comma or " &
                        " map end): " & $token)
            of yamlComma:
                yieldScalar()
                level = ancestry.pop()
                case level.mode
                of mFlowMapValue:
                    level.mode = mFlowMapKey
                    ancestry.add(level)
                    level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                          indentationColumn: -1)
                of mFlowSequenceItem:
                    yieldScalar()
                else:
                    yieldError("Internal error! Please report this bug.")
            of yamlOpeningBrace:
                if level.mode != mUnknown:
                    yieldError("Unexpected token")
                level.mode = mFlowMapKey
                yieldStart(yamlStartMap)
                ancestry.add(level)
                level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                      indentationColumn: -1)
            of yamlOpeningBracket:
                if level.mode != mUnknown:
                    yieldError("Unexpected token")
                level.mode = mFlowSequenceItem
                yieldStart(yamlStartSequence)
                ancestry.add(level)
                level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                      indentationColumn: -1)
            of yamlClosingBrace:
                if level.mode == mUnknown:
                    yieldScalar()
                    level = ancestry.pop()
                if level.mode != mFlowMapValue:
                    yieldError("Unexpected token")
                yield YamlParserEvent(kind: yamlEndMap)
                if ancestry.len > 0:
                    level = ancestry.pop()
                    case level.mode
                    of mFlowMapKey, mFlowMapValue, mFlowSequenceItem:
                        state = ylFlowAfterObject
                    else:
                        state = ylBlockLineEnd
                else:
                    state = ylExpectingDocumentEnd
            of yamlClosingBracket:
                if level.mode == mUnknown:
                    yieldScalar()
                    level = ancestry.pop()
                if level.mode != mFlowSequenceItem:
                    yieldError("Unexpected token: " & $token)
                else:
                    yield YamlParserEvent(kind: yamlEndSequence)
                    if ancestry.len > 0:
                        level = ancestry.pop()
                        case level.mode
                        of mFlowMapKey, mFlowMapValue, mFlowSequenceItem:
                            state = ylFlowAfterObject
                        else:
                            state = ylBlockLineEnd
                    else:
                        state = ylExpectingDocumentEnd
            else:
                yieldError("Unexpected token: " & $token)
        of ylFlowAfterObject:
            case token
            of yamlLineStart:
                discard
            of yamlColon:
                if level.mode != mFlowMapKey:
                    yieldError("Unexpected token: " & $token)
                else:
                    level.mode = mFlowMapValue
                    ancestry.add(level)
                    level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                          indentationColumn: -1)
                    state = ylFlow
            of yamlComma:
                case level.mode
                of mFlowSequenceItem:
                    ancestry.add(level)
                    level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                          indentationColumn: -1)
                    state = ylFlow
                of mFlowMapValue:
                    level.mode = mFlowMapKey
                    ancestry.add(level)
                    level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                          indentationColumn: -1)
                    state = ylFlow
                else:
                    yieldError("Unexpected token: " & $token)
            of yamlClosingBrace:
                if level.mode != mFlowMapValue:
                    yieldError("Unexpected token: " & $token)
                else:
                    yield YamlParserEvent(kind: yamlEndMap)
                    if ancestry.len > 0:
                        level = ancestry.pop()
                        case level.mode
                        of mFlowMapKey, mFlowMapValue, mFlowSequenceItem:
                            state = ylFlow
                        else:
                            state = ylBlockLineEnd
                    else:
                        state = ylExpectingDocumentEnd
            of yamlClosingBracket:
                if level.mode != mFlowSequenceItem:
                    yieldError("Unexpected token: " & $token)
                else:
                    yield YamlParserEvent(kind: yamlEndSequence)
                    if ancestry.len > 0:
                        level = ancestry.pop()
                        case level.mode
                        of mFlowMapKey, mFlowMapValue, mFlowSequenceItem:
                            state = ylFlow
                        else:
                            state = ylBlockLineEnd
                    else:
                        state = ylExpectingDocumentEnd
            else:
                yieldError("Unexpected token: " & $token)
        of ylExpectingDocumentEnd:
            case token
            of yamlComment, yamlLineStart:
                discard
            of yamlStreamEnd, yamlDocumentEnd:
                yield YamlParserEvent(kind: yamlEndDocument)
                state = ylInitial
            of yamlDirectivesEnd:
                yield YamlParserEvent(kind: yamlEndDocument)
                state = ylInitial
                continue
            else:
                yieldError("Unexpected token (expected document end): " &
                           $token)
        token = nextToken(lex)