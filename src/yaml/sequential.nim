import streams, tables, strutils

import "private/lexer"

type
    YamlParserEventKind* = enum
        yamlStartDocument, yamlEndDocument, yamlStartMap, yamlEndMap,
        yamlStartSequence, yamlEndSequence, yamlScalar, yamlAlias,
        yamlError, yamlWarning
    
    TagId* = distinct int
    
    YamlParserEvent* = ref object
        case kind*: YamlParserEventKind
        of yamlStartMap, yamlStartSequence:
            objAnchor* : string # may be nil, may not be empty
            objTag*    : TagId
        of yamlScalar:
            scalarAnchor* : string # may be nil
            scalarTag*    : TagId
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
        ylBlockAfterAnchor, ylBlockAfterAnchorAndTag, ylBlockAfterScalar,
        ylBlockAfterColon, ylBlockMultilineScalar, ylBlockLineEnd,
        ylBlockScalarHeader, ylBlockScalar, ylFlow, ylFlowAfterObject,
        ylFlowAfterTag, ylFlowAfterAnchor, ylFlowAfterAnchorAndTag,
        ylExpectingDocumentEnd
    
    DocumentLevelMode = enum
        mBlockSequenceItem, mFlowSequenceItem, mExplicitBlockMapKey,
        mExplicitBlockMapValue, mImplicitBlockMapKey, mImplicitBlockMapValue,
        mFlowMapKey, mFlowMapValue, mScalar, mUnknown
    
    DocumentLevel = object
        mode: DocumentLevelMode
        indicatorColumn: int
        indentationColumn: int
    
    LineStrippingMode = enum
        lsStrip, lsClip, lsKeep
    
    BlockScalarStyle = enum
        bsLiteral, bsFolded
    
    YamlSequentialParser* = object
        tags: OrderedTable[string, TagId]

const
    tagNonSpecificEmark*: TagId = 0.TagId # "!" non-specific tag
    tagNonSpecificQmark*: TagId = 1.TagId # "?" non-specific tag

# interface

proc `==`*(left: YamlParserEvent, right: YamlParserEvent): bool

proc `==`*(left, right: TagId): bool {.borrow.}
proc `$`*(id: TagId): string {.borrow.}

proc initParser*(): YamlSequentialParser

# iterators cannot be pre-declared.
#
# iterator events*(parser: YamlSequentialParser,
#                  input: Stream): YamlParserEvent

proc uri*(parser: YamlSequentialParser, id: TagId): string

proc registerUri*(parser: var YamlSequentialParser, uri: string): TagId 

# implementation

proc initParser*(): YamlSequentialParser =
    result.tags = initOrderedTable[string, TagId]()
    result.tags["!"] = tagNonSpecificEmark
    result.tags["?"] = tagNonSpecificQmark

proc uri*(parser: YamlSequentialParser, id: TagId): string =
    for pair in parser.tags.pairs:
        if pair[1] == id:
            return pair[0]
    return nil

proc registerUri*(parser: var YamlSequentialParser, uri: string): TagId =
    result = cast[TagId](parser.tags.len)
    if parser.tags.hasKeyOrPut(uri, result):
        result = parser.tags[uri]

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

template yieldScalar(content: string = "", quoted: bool = false) {.dirty.} =
    var retTag: TagId
    if isNil(tag):
        retTag = if quoted: tagNonSpecificEmark else: tagNonSpecificQmark
    else:
        try:
            retTag = parser.tags[tag]
        except KeyError:
            retTag = cast[TagId](parser.tags.len)
            parser.tags[tag] = retTag
            
    yield YamlParserEvent(kind: yamlScalar,
            scalarAnchor: anchor, scalarTag: retTag,
            scalarContent: content)
    anchor = nil
    tag = nil

template yieldStart(k: YamlParserEventKind) {.dirty.} =
    var retTag: TagId
    if isNil(tag):
        retTag = tagNonSpecificQmark
    else:
        try:
            retTag = parser.tags[tag]
        except KeyError:
            retTag = cast[TagId](parser.tags.len)
            parser.tags[tag] = retTag
            
    yield YamlParserEvent(kind: k, objAnchor: anchor, objTag: retTag)
    anchor = nil
    tag = nil

template yieldDocumentEnd() {.dirty.} =
    yield YamlParserEvent(kind: yamlEndDocument)
    tagShorthands = initTable[string, string]()
    tagShorthands["!"] = "!"
    tagShorthands["!!"] = "tag:yaml.org,2002:"

template closeLevel(lvl: DocumentLevel) {.dirty.} =
    case lvl.mode
    of mExplicitBlockMapKey, mFlowMapKey:
        yieldError("Missing Map value!")
    of mExplicitBlockMapValue, mImplicitBlockMapKey, mImplicitBlockMapValue,
       mFlowMapValue:
        yield YamlParserEvent(kind: yamlEndMap)
    of mBlockSequenceItem, mFlowSequenceItem:
        yield YamlParserEvent(kind: yamlEndSequence)
    of mScalar:
        var retTag: TagId
        if isNil(tag):
            retTag = tagNonSpecificQmark
        else:
            try:
                retTag = parser.tags[tag]
            except KeyError:
                retTag = cast[TagId](parser.tags.len)
                parser.tags[tag] = retTag
        
        yield YamlParserEvent(kind: yamlScalar, scalarAnchor: anchor,
                              scalarTag: retTag, scalarContent: scalarCache)
        anchor = nil
        tag = nil
    else:
        yieldScalar()      

template leaveMoreIndentedLevels() {.dirty.} =
    while ancestry.len > 0:
        let parent = ancestry[ancestry.high]
        if parent.indicatorColumn >= lex.column or
                 (parent.indicatorColumn == -1 and
                  parent.indentationColumn >= lex.column):
            closeLevel(level)
            level = ancestry.pop()
            if level.mode == mImplicitBlockMapValue:
                level.mode = mImplicitBlockMapKey
        else:
            break
           
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
        yieldStart(entering)
        ancestry.add(level)
        level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                              indentationColumn: -1)

template startPlainScalar() {.dirty.} =
    level.mode = mScalar
    scalarCache = lex.content
    state = ylBlockAfterScalar

template handleTagHandle() {.dirty.} =
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
    else:
        yieldError("Unknown tag shorthand: " & handle)

iterator events*(parser: var YamlSequentialParser,
                 input: Stream): YamlParserEvent {.closure.} =
    var
        # parsing state
        lex: YamlLexer
        state = ylInitial
        
        # document state
        foundYamlDirective = false
        tagShorthands = initTable[string, string]()
        
        # object tree state
        ancestry = newSeq[DocumentLevel]()
        level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                              indentationColumn: -1)
        
        # block scalar state
        lineStrip: LineStrippingMode
        blockScalar: BlockScalarStyle
        blockScalarIndentation: int
        blockScalarTrailing: string = nil
        
        # cached values
        tag: string = nil
        anchor: string = nil
        scalarCache: string = nil
        scalarIndentation: int
        scalarCacheIsQuoted: bool = false
        
    lex.open(input)
    tagShorthands["!"] = "!"
    tagShorthands["!!"] = "tag:yaml.org,2002:"
    
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
                yieldDocumentEnd()
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
            of yamlPipe, yamlGreater:
                blockScalar = if token == yamlPipe: bsLiteral else: bsFolded
                blockScalarIndentation = -1
                lineStrip = lsClip
                state = ylBlockScalarHeader
                scalarCache = ""
                level.mode = mScalar
            of yamlTagHandle:
                handleTagHandle()
                level.indentationColumn = lex.column
                state = ylBlockAfterTag
            of yamlVerbatimTag:
                tag = lex.content
                state = ylBlockAfterTag
                level.indentationColumn = lex.column
            of yamlAnchor:
                anchor = lex.content
                level.indentationColumn = lex.column
                state = ylBlockAfterAnchor
            of yamlScalarPart:
                leaveMoreIndentedLevels()
                case level.mode
                of mUnknown:
                    startPlainScalar()
                    level.indentationColumn = lex.column
                of mImplicitBlockMapKey:
                    scalarCache = lex.content
                    scalarCacheIsQuoted = false
                    scalarIndentation = lex.column
                of mImplicitBlockMapValue:
                    ancestry.add(level)
                    scalarCache = lex.content
                    scalarCacheIsQuoted = false
                    scalarIndentation = lex.column
                    level = DocumentLevel(mode: mScalar, indicatorColumn: -1,
                            indentationColumn:
                            ancestry[ancestry.high].indentationColumn + 1)
                else:
                    yieldError("Unexpected scalar")
                state = ylBlockAfterScalar
            of lexer.yamlScalar:
                leaveMoreIndentedLevels()
                case level.mode
                of mUnknown, mImplicitBlockMapKey:
                    scalarCache = lex.content
                    scalarCacheIsQuoted = true
                    scalarIndentation = lex.column
                    state = ylBlockAfterScalar
                else:
                    yieldError("Unexpected scalar")
            of yamlStreamEnd:
                closeAllLevels()
                yield YamlParserEvent(kind: yamlEndDocument)
                break
            of yamlDocumentEnd:
                closeAllLevels()
                yieldDocumentEnd()
                state = ylInitial
            of yamlOpeningBrace:
                state = ylFlow
                continue
            of yamlOpeningBracket:
                state = ylFlow
                continue
            else:
                yieldError("[block line start] Unexpected token: " & $token)
        of ylBlockMultilineScalar:            
            case token
            of yamlScalarPart:
                leaveMoreIndentedLevels()
                if level.mode != mScalar:
                    state = ylBlockLineStart
                    continue
                scalarCache &= " " & lex.content
                state = ylBlockLineEnd
            of yamlLineStart:
                discard
            of yamlColon, yamlDash, yamlQuestionMark:
                leaveMoreIndentedLevels()
                if level.mode != mScalar:
                    state = ylBlockLineStart
                    continue
                yieldError("[multiline scalar ?:-] Unexpected token: " & $token)
            of yamlDocumentEnd, yamlStreamEnd:
                closeAllLevels()
                scalarCache = nil
                state = ylExpectingDocumentEnd
                continue
            of yamlDirectivesEnd:
                closeAllLevels()
                state = ylInitial
                continue
            else:
                yieldError("[multiline scalar] Unexpected token: " & $token)
        of ylBlockAfterScalar:
            case token
            of yamlColon:
                assert level.mode in [mUnknown, mImplicitBlockMapKey, mScalar]
                if level.mode in [mUnknown, mScalar]:
                    level.indentationColumn = scalarIndentation
                    # tags and anchors are for key scalar, not for map.
                    yield YamlParserEvent(kind: yamlStartMap,
                                          objAnchor: nil,
                                          objTag: tagNonSpecificQmark)
                level.mode = mImplicitBlockMapValue
                ancestry.add(level)
                level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                      indentationColumn: -1)
                yieldScalar(scalarCache, scalarCacheIsQuoted)
                scalarCache = nil
                state = ylBlockAfterColon
            of yamlLineStart:
                if level.mode == mImplicitBlockMapKey:
                    yieldError("Missing colon after implicit map key")
                if level.mode != mScalar:
                    yieldScalar(scalarCache, scalarCacheIsQuoted)
                    scalarCache = nil
                    if ancestry.len > 0:
                        level = ancestry.pop()
                    else:
                        state = ylExpectingDocumentEnd
                else:
                    state = ylBlockMultilineScalar
            of yamlStreamEnd:
                yieldScalar(scalarCache, scalarCacheIsQuoted)
                scalarCache = nil
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
                state = ylBlockAfterAnchorAndTag
            of lexer.yamlScalar:
                state = ylBlockLineStart
                continue
            of yamlScalarPart:
                startPlainScalar()
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
                state = ylBlockLineStart
                continue
            of lexer.yamlScalarPart:
                startPlainScalar()
            of yamlLineStart:
                discard
            of yamlOpeningBracket, yamlOpeningBrace:
                state = ylFlow
                continue
            of yamlTagHandle:
                handleTagHandle()
                state = ylBlockAfterTag
            of yamlVerbatimTag:
                tag = lex.content
                state = ylBlockAfterTag
                level.indentationColumn = lex.column
            else:
                yieldError("Unexpected token: " & $token)
        of ylBlockAfterAnchorAndTag:
            case token
            of lexer.yamlScalar:
                state = ylBlockLineStart
                continue
            of yamlScalarPart:
                startPlainScalar()
            of yamlLineStart:
                discard
            of yamlOpeningBracket, yamlOpeningBrace:
                state = ylFlow
                continue
            else:
                yieldError("Unexpected token: " & $token)
        of ylBlockAfterColon:
            case token
            of lexer.yamlScalar:
                yieldScalar(lex.content, true)
                level = ancestry.pop()
                assert level.mode == mImplicitBlockMapValue
                level.mode = mImplicitBlockMapKey
                state = ylBlockLineEnd
            of yamlScalarPart:
                startPlainScalar()
            of yamlLineStart:
                state = ylBlockLineStart
            of yamlStreamEnd:
                closeAllLevels()
                yield YamlParserEvent(kind: yamlEndDocument)
                break
            of yamlOpeningBracket, yamlOpeningBrace:
                state = ylFlow
                continue
            of yamlPipe, yamlGreater:
                blockScalar = if token == yamlPipe: bsLiteral else: bsFolded
                blockScalarIndentation = -1
                lineStrip = lsClip
                state = ylBlockScalarHeader
                scalarCache = ""
                level.mode = mScalar
            of yamlTagHandle:
                handleTagHandle()
                state = ylBlockAfterTag
            of yamlAnchor:
                anchor = lex.content
                state = ylBlockAfterAnchor
            else:
                yieldError("Unexpected token (expected scalar or line end): " &
                           $token)
        of ylBlockLineEnd:
            case token
            of yamlLineStart:
                state = if level.mode == mScalar: ylBlockMultilineScalar else:
                        ylBlockLineStart
            of yamlStreamEnd:
                closeAllLevels()
                yield YamlParserEvent(kind: yamlEndDocument)
                break
            else:
                yieldError("Unexpected token (expected line end):" & $token)
        of ylBlockScalarHeader:
            case token
            of yamlPlus:
                if lineStrip != lsClip:
                    yieldError("Multiple chomping indicators!")
                else:
                    lineStrip = lsKeep
            of yamlDash:
                if lineStrip != lsClip:
                    yieldError("Multiple chomping indicators!")
                else:
                    lineStrip = lsStrip
            of yamlBlockIndentationIndicator:
                if blockScalarIndentation != -1:
                    yieldError("Multiple indentation indicators!")
                else:
                    blockScalarIndentation = parseInt(lex.content)
            of yamlLineStart:
                blockScalarTrailing = ""
                state = ylBlockScalar
            else:
                yieldError("Unexpected token: " & $token)
        of ylBlockScalar:
            case token
            of yamlLineStart:
                if level.indentationColumn == -1:
                    discard
                else:
                    case blockScalar
                    of bsLiteral:
                        blockScalarTrailing &= "\x0A"
                    of bsFolded:
                        case blockScalarTrailing.len
                        of 0:
                            blockScalarTrailing = " "
                        of 1:
                            blockScalarTrailing = "\x0A"
                        else:
                            discard
                    
                    if lex.content.len > level.indentationColumn:
                        if blockScalar == bsFolded:
                            if blockScalarTrailing == " ":
                                blockScalarTrailing = "\x0A"
                        scalarCache &= blockScalarTrailing &
                                lex.content[level.indentationColumn..^1]
                        blockScalarTrailing = ""
                            
            of yamlScalarPart:
                if ancestry.high > 0:
                    if ancestry[ancestry.high].indicatorColumn >= lex.column or
                       ancestry[ancestry.high].indicatorColumn == -1 and
                       ancestry[ancestry.high].indentationColumn >= lex.column:
                            # todo: trailing chomping?
                            closeLevel(level)
                            state = ylBlockLineStart
                            continue
                if level.indentationColumn == -1:
                    level.indentationColumn = lex.column
                else:
                    scalarCache &= blockScalarTrailing
                    blockScalarTrailing = ""
                scalarCache &= lex.content
            else:
                case lineStrip
                of lsStrip:
                    discard
                of lsClip:
                    scalarCache &= "\x0A"
                of lsKeep:
                    scalarCache &= blockScalarTrailing
                closeLevel(level)
                if ancestry.len == 0:
                    state = ylExpectingDocumentEnd
                else:
                    level = ancestry.pop()
                    state = ylBlockLineStart
                continue            
        of ylFlow:
            case token
            of yamlLineStart:
                discard
            of lexer.yamlScalar, yamlScalarPart:
                yieldScalar(lex.content, token == lexer.yamlScalar)
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
            of yamlTagHandle:
                handleTagHandle()
                state = ylFlowAfterTag
            of yamlAnchor:
                anchor = lex.content
                state = ylFlowAfterAnchor
            else:
                yieldError("Unexpected token: " & $token)
        of ylFlowAfterTag:
            case token
            of yamlTagHandle:
                yieldError("Multiple tags on same node!")
            of yamlAnchor:
                anchor = lex.content
                state = ylFlowAfterAnchorAndTag
            else:
                state = ylFlow
                continue
        of ylFlowAfterAnchor:
            case token
            of yamlAnchor:
                yieldError("Multiple anchors on same node!")
            of yamlTagHandle:
                handleTagHandle()
                state = ylFlowAfterAnchorAndTag
            else:
                state = ylFlow
                continue
        of ylFlowAfterAnchorAndTag:
            case token
            of yamlAnchor:
                yieldError("Multiple anchors on same node!")
            of yamlTagHandle:
                yieldError("Multiple tags on same node!")
            else:
                state = ylFlow
                continue
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
                yieldDocumentEnd()
                state = ylInitial
            of yamlDirectivesEnd:
                yieldDocumentEnd()
                state = ylInitial
                continue
            else:
                yieldError("Unexpected token (expected document end): " &
                           $token)
        token = nextToken(lex)