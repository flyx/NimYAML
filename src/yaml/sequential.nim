import streams, tables, strutils

import "private/lexer"

type
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
    
    YamlParserState = enum
        ylInitial, ylSkipDirective, ylBlockLineStart, ylBlockAfterTag,
        ylBlockAfterAnchor, ylBlockAfterAnchorAndTag, ylBlockAfterScalar,
        ylBlockAfterAlias, ylBlockAfterColon, ylBlockMultilineScalar,
        ylBlockLineEnd, ylBlockScalarHeader, ylBlockScalar, ylFlow,
        ylFlowAfterObject, ylFlowAfterTag, ylFlowAfterAnchor,
        ylFlowAfterAnchorAndTag, ylExpectingDocumentEnd, ylAfterDirectivesEnd
    
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
        anchors: OrderedTable[string, AnchorId]

const
    tagExclamationMark*: TagId = 0.TagId # "!" non-specific tag
    tagQuestionMark*   : TagId = 1.TagId # "?" non-specific tag
    anchorNone*: AnchorId = (-1).AnchorId   # no anchor defined

# interface

proc `==`*(left: YamlParserEvent, right: YamlParserEvent): bool

proc `==`*(left, right: TagId): bool {.borrow.}
proc `$`*(id: TagId): string {.borrow.}

proc `==`*(left, right: AnchorId): bool {.borrow.}
proc `$`*(id: AnchorId): string {.borrow.}

proc initParser*(): YamlSequentialParser

# iterators cannot be pre-declared.
#
# iterator events*(parser: YamlSequentialParser,
#                  input: Stream): YamlParserEvent

proc uri*(parser: YamlSequentialParser, id: TagId): string

proc registerUri*(parser: var YamlSequentialParser, uri: string): TagId 

proc anchor*(parser: YamlSequentialParser, id: AnchorId): string

# implementation

proc initParser*(): YamlSequentialParser =
    result.tags = initOrderedTable[string, TagId]()
    result.tags["!"] = tagExclamationMark
    result.tags["?"] = tagQuestionMark
    result.anchors = initOrderedTable[string, AnchorId]()

proc uri*(parser: YamlSequentialParser, id: TagId): string =
    for pair in parser.tags.pairs:
        if pair[1] == id:
            return pair[0]
    return nil

proc registerUri*(parser: var YamlSequentialParser, uri: string): TagId =
    result = cast[TagId](parser.tags.len)
    if parser.tags.hasKeyOrPut(uri, result):
        result = parser.tags[uri]

proc anchor*(parser: YamlSequentialParser, id: AnchorId): string =
    for pair in parser.anchors.pairs:
        if pair[1] == id:
            return pair[0]
    return nil

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
        result = left.aliasTarget == right.aliasTarget
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

template yieldUnexpectedToken(expected: string = "") {.dirty.} =
    var msg = "[" & $state & "] Unexpected token"
    if expected.len > 0:
        msg.add(" (expected " & expected & ")")
    msg.add(": " & $token)
    yieldError(msg)

proc resolveAnchor(parser: var YamlSequentialParser, anchor: var string):
        AnchorId {.inline.} =
    result = anchorNone
    if anchor.len > 0:
        result = cast[AnchorId](parser.anchors.len)
        if parser.anchors.hasKeyOrPut(anchor, result):
            result = parser.anchors[anchor]
    anchor = ""

proc resolveAlias(parser: var YamlSequentialParser, name: string): AnchorId =
    try:
        result = parser.anchors[name]
    except KeyError:
        result = anchorNone

proc resolveTag(parser: var YamlSequentialParser, tag: var string,
                quotedString: bool = false): TagId {.inline.} =
    if tag.len == 0:
        result = if quotedString: tagExclamationMark else: tagQuestionMark
    else:
        try:
            result = parser.tags[tag]
        except KeyError:
            result = cast[TagId](parser.tags.len)
            parser.tags[tag] = result
        tag = ""

template yieldScalar(content: string = "", quoted: bool = false) {.dirty.} =
    yield YamlParserEvent(kind: yamlScalar,
            scalarAnchor: resolveAnchor(parser, anchor),
            scalarTag: resolveTag(parser, tag, quoted),
            scalarContent: content)

template yieldStart(k: YamlParserEventKind) {.dirty.} =
    yield YamlParserEvent(kind: k, objAnchor: resolveAnchor(parser, anchor),
                          objTag: resolveTag(parser, tag))

template yieldDocumentEnd() {.dirty.} =
    yield YamlParserEvent(kind: yamlEndDocument)
    tagShorthands = initTable[string, string]()
    tagShorthands["!"] = "!"
    tagShorthands["!!"] = "tag:yaml.org,2002:"
    parser.anchors = initOrderedTable[string, AnchorId]()

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
        yield YamlParserEvent(kind: yamlScalar,
                              scalarAnchor: resolveAnchor(parser, anchor),
                              scalarTag: resolveTag(parser, tag),
                              scalarContent: scalarCache)
        
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
        yieldUnexpectedToken()
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
        tag: string = ""
        anchor: string = ""
        scalarCache: string = nil
        scalarIndentation: int
        scalarCacheIsQuoted: bool = false
        aliasCache = anchorNone
        
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
                state = ylAfterDirectivesEnd
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
        of ylAfterDirectivesEnd:
            case token
            of yamlTagHandle:
                handleTagHandle()
                state = ylBlockLineEnd
            of yamlComment:
                state = ylBlockLineEnd
            of yamlLineStart:
                state = ylBlockLineStart
            else:
                yieldUnexpectedToken()
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
            of lexer.yamlAlias:
                aliasCache = resolveAlias(parser, lex.content)
                if aliasCache == anchorNone:
                    yieldError("[alias] Unknown anchor: " & lex.content)
                if ancestry.len > 0:
                    if level.mode == mUnknown:
                        level = ancestry.pop()
                else:
                    assert level.mode == mImplicitBlockMapKey
                leaveMoreIndentedLevels()
                case level.mode
                of mUnknown, mImplicitBlockMapKey, mBlockSequenceItem:
                    state = ylBlockAfterAlias
                else:
                    yieldError("Unexpected alias")
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
                yieldUnexpectedToken()
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
                yieldUnexpectedToken()
            of yamlDocumentEnd, yamlStreamEnd:
                closeAllLevels()
                scalarCache = nil
                state = ylInitial
                continue
            of yamlDirectivesEnd:
                closeAllLevels()
                state = ylAfterDirectivesEnd
                continue
            of lexer.yamlAlias:
                leaveMoreIndentedLevels()
                state = ylBlockLineStart
                continue
            else:
                yieldUnexpectedToken()
        of ylBlockAfterScalar:
            case token
            of yamlColon:
                assert level.mode in [mUnknown, mImplicitBlockMapKey, mScalar]
                if level.mode in [mUnknown, mScalar]:
                    level.indentationColumn = scalarIndentation
                    # tags and anchors are for key scalar, not for map.
                    yield YamlParserEvent(kind: yamlStartMap,
                                          objAnchor: anchorNone,
                                          objTag: tagQuestionMark)
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
                yieldUnexpectedToken()
        of ylBlockAfterAlias:
            case token
            of yamlColon:
                assert level.mode in [mUnknown, mImplicitBlockMapKey]
                if level.mode == mUnknown:
                    yield YamlParserEvent(kind: yamlStartMap,
                                          objAnchor: anchorNone,
                                          objTag: tagQuestionMark)
                level.mode = mImplicitBlockMapValue
                ancestry.add(level)
                level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                      indentationColumn: -1)
                yield YamlParserEvent(kind: yamlAlias, aliasTarget: aliasCache)
                state = ylBlockAfterColon
            of yamlLineStart:
                if level.mode == mImplicitBlockMapKey:
                    yieldError("Missing colon after implicit map key")
                if level.mode == mUnknown:
                    assert ancestry.len > 0
                    level = ancestry.pop()
                yield YamlParserEvent(kind: yamlAlias, aliasTarget: aliasCache)
                state = ylBlockLineStart
            of yamlStreamEnd:
                yield YamlParserEvent(kind: yamlAlias, aliasTarget: aliasCache)
                if level.mode == mUnknown:
                    assert ancestry.len > 0
                    level = ancestry.pop()
                state = ylBlockLineEnd
                continue
            else:
                yieldUnexpectedToken()
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
                yieldUnexpectedToken()
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
                state = ylBlockAfterAnchorAndTag
            of yamlVerbatimTag:
                tag = lex.content
                state = ylBlockAfterAnchorAndTag
                level.indentationColumn = lex.column
            else:
                yieldUnexpectedToken()
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
                yieldUnexpectedToken()
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
            of lexer.yamlAlias:
                var noAnchor = false
                try:
                    aliasCache = parser.anchors[lex.content]
                except KeyError:
                    noAnchor = true
                if noAnchor:
                    # cannot use yield within try/except, so do it here
                    yieldError("[alias] Unknown anchor: " & lex.content)
                yield YamlParserEvent(kind: yamlAlias, aliasTarget: aliasCache)
                level = ancestry.pop()
                state = ylBlockLineEnd
            else:
                yieldUnexpectedToken("scalar or line end")
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
                yieldUnexpectedToken("line end")
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
                yieldUnexpectedToken()
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
                    yieldUnexpectedToken("scalar, comma or map end")
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
                    yieldUnexpectedToken()
                level.mode = mFlowMapKey
                yieldStart(yamlStartMap)
                ancestry.add(level)
                level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                      indentationColumn: -1)
            of yamlOpeningBracket:
                if level.mode != mUnknown:
                    yieldUnexpectedToken()
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
                    yieldUnexpectedToken()
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
                    yieldUnexpectedToken()
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
            of lexer.yamlAlias:
                yield YamlParserEvent(kind: yamlAlias,
                        aliasTarget: resolveAlias(parser, lex.content))
                state = ylFlowAfterObject
                level = ancestry.pop()
            else:
                yieldUnexpectedToken()
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
                    yieldUnexpectedToken()
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
                    echo "level.mode = ", level.mode
                    yieldUnexpectedToken()
            of yamlClosingBrace:
                if level.mode != mFlowMapValue:
                    yieldUnexpectedToken()
                else:
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
                if level.mode != mFlowSequenceItem:
                    yieldUnexpectedToken()
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
                yieldUnexpectedToken()
        of ylExpectingDocumentEnd:
            case token
            of yamlComment, yamlLineStart:
                discard
            of yamlStreamEnd, yamlDocumentEnd:
                yieldDocumentEnd()
                state = ylInitial
            of yamlDirectivesEnd:
                yieldDocumentEnd()
                state = ylAfterDirectivesEnd
                continue
            else:
                yieldUnexpectedToken("document end")
        token = nextToken(lex)