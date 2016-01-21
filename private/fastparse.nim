type
  FastParseState = enum
    fpInitial, fpBlockLineStart, fpBlockAfterScalar, fpBlockAfterPlainScalar,
    fpBlockObjectStart, fpBlockContinueScalar, fpExpectDocEnd, fpFlow,
    fpFlowAfterObject
  
  FastParseLevelKind = enum
    fplUnknown, fplSequence, fplMapKey, fplMapValue, fplScalar
  
  FastParseLevel = object
    kind: FastParseLevelKind
    indentation: int
  
  LexedDirective = enum
    ldYaml, ldTag, ldUnknown
  
  LexedPossibleDirectivesEnd = enum
    lpdeDirectivesEnd, lpdeSequenceItem, lpdeScalarContent
  
  YamlContext = enum
    cFlowIn, cFlowOut, cFlowKey, cBlockKey, cBlockIn, cBlockOut
  
  FastLexer = object of BaseLexer
    tokenstart: int

const
  space          = [' ', '\t']
  lineEnd        = ['\x0A', '\c', EndOfFile]
  spaceOrLineEnd = [' ', '\t', '\x0A', '\c', EndOfFile]
  digits         = '0'..'9'
  flowIndicators = ['[', ']', '{', '}', ',']

template debug(message: string) {.dirty.} =
  when defined(yamlDebug):
    try: styledWriteLine(stdout, fgBlue, message)
    except IOError: discard

template raiseError(message: string) {.dirty.} =
  var e = newException(YamlParserError, message)
  e.line = lexer.lineNumber
  e.column = lexer.tokenstart
  e.lineContent = lexer.getCurrentLine(false) &
      repeat(' ', lexer.getColNumber(lexer.bufpos)) & "^\n"
  raise e

template raiseError(message: string, col: int) {.dirty.} =
  var e = newException(YamlParserError, message)
  e.line = lexer.lineNumber
  e.column = col
  e.lineContent = lexer.getCurrentLine(false) &
      repeat(' ', lexer.getColNumber(lexer.bufpos)) & "^\n"
  raise e

template closeLevel() {.dirty.} =
  case level.kind
  of fplSequence:
    yield endSeqEvent()
  of fplMapKey:
    yield endMapEvent()
  of fplMapValue:
    yield scalarEvent("", tag, anchor)
    tag = yTagQuestionMark
    anchor = yAnchorNone
    yield endMapEvent()
  of fplScalar:
    applyObjectProperties()
    yield cachedScalar
  of fplUnknown:
    yield scalarEvent("")
  if ancestry.len > 0:
    level = ancestry.pop()

template handleLineEnd(insideDocument: bool) {.dirty.} =
  case lexer.buf[lexer.bufpos]
  of '\x0A':
    lexer.bufpos = lexer.handleLF(lexer.bufpos)
  of '\c':
    lexer.bufpos = lexer.handleCR(lexer.bufpos)
  of EndOfFile:
    when insideDocument:
      closeEverything()
    return
  else:
    discard

template handleObjectEnd() {.dirty.} =
  tag = yTagQuestionMark
  anchor = yAnchorNone
  case level.kind
  of fplMapKey:
    level.kind = fplMapValue
  of fplMapValue:
    level.kind = fplMapKey
  of fplSequence:
    discard
  of fplUnknown, fplScalar:
    raiseError("Internal error!")

template handleStartObject(k: YamlStreamEventKind) {.dirty.} =
  when k == yamlStartMap:
    yield startMapEvent(objectTag, objectAnchor)
    debug("started map at " & $lexer.tokenstart)
  else:
    yield startSeqEvent(objectTag, objectAnchor)
    debug("started sequence at " & $lexer.tokenstart)
  objectTag = yTagQuestionMark
  objectAnchor = yAnchorNone
  
template closeMoreIndentedLevels() {.dirty.} =
  while ancestry.len > 0:
    let parent = ancestry[ancestry.high]
    if parent.indentation >= indentation:
      debug("Closing because level.indentation =" & $level.indentation &
            ", but indentation = " & $indentation)
      closeLevel()
      handleObjectEnd()
    else:
      break

template closeEverything() {.dirty.} =
  indentation = 0
  closeMoreIndentedLevels()
  closeLevel()
  yield endDocEvent()

template handleStartBlockSequence() {.dirty.} =
  case level.kind
  of fplUnknown:
    level.kind = fplSequence
    handleStartObject(yamlStartSequence)
  of fplSequence:
    if level.indentation != indentation:
      raiseError("Invalid indentation of block sequence indicator",
                 lexer.bufpos)
  else:
      raiseError("Illegal sequence item in map")
  ancestry.add(level)
  lexer.skipWhitespace()
  indentation = lexer.getColNumber(lexer.bufpos)
  level = FastParseLevel(kind: fplUnknown, indentation: indentation)

template handleStartBlockScalar() {.dirty.} =
  case level.kind
  of fplUnknown, fplMapKey:
    discard
  of fplSequence:
    raiseError("Illegal token (expected '- ')")
  of fplMapValue, fplScalar:
    raiseError("Internal error!")

template propsToObjectProps() {.dirty.} =
  if objectTag == yTagQuestionmark:
    objectTag = tag
    tag = yTagQuestionmark
  elif tag != yTagQuestionMark:
    raiseError("Only one tag is allowed per node")
  if objectAnchor == yAnchorNone:
    objectAnchor = anchor
    anchor = yAnchorNone
  elif anchor != yAnchorNone:
    raiseError("Only one anchor is allowed per node")

template initDocValues() {.dirty.} =
  shorthands = initTable[string, string]()
  anchors = initTable[string, AnchorId]()
  shorthands["!"] = "!"
  shorthands["!!"] = "tag:yaml.org,2002:"
  nextAnchorId = 0.AnchorId
  level = FastParseLevel(kind: fplUnknown, indentation: -1)
  tag = yTagQuestionmark
  objectTag = yTagQuestionmark
  anchor = yAnchorNone
  objectAnchor = yAnchorNone

template applyObjectProperties() {.dirty.} =
  if objectTag != yTagQuestionmark:
    if cachedScalar.scalarTag != yTagQuestionmark:
      debug("cached = " & $cachedScalar.scalarTag & ", object = " & $objectTag)
      raiseError("Only one tag is allowed per node")
    else:
      cachedScalar.scalarTag = objectTag
      objectTag = yTagQuestionmark
  if objectAnchor != yAnchorNone:
    if cachedScalar.scalarAnchor != yAnchorNone:
      raiseError("Only one anchor is allowed per node")
    else:
      cachedScalar.scalarAnchor = objectAnchor
      objectAnchor = yAnchorNone

template handleTagHandle() {.dirty.} =
  if tag != yTagQuestionmark:
    raiseError("Only one tag handle is allowed per node")
  content = ""
  var
    shorthandEnd: int
    tagUri: string
  lexer.tagHandle(content, shorthandEnd)
  if shorthandEnd != -1:
    try:
      let prefix = shorthands[content[0..shorthandEnd]]
      tagUri = prefix & content[shorthandEnd + 1 .. ^1]
    except KeyError:
      raiseError("Undefined tag shorthand: " & content[0..shorthandEnd])
  else:
    shallowCopy(tagUri, content)
  try:
    tag = tagLib.tags[tagUri]
  except KeyError:
    tag = tagLib.registerUri(tagUri)

template handleAnchor() {.dirty.} =
  if anchor != yAnchorNone:
    raiseError("Only one anchor is allowed per node", lexer.bufpos)
  content = ""
  lexer.anchorName(content)
  anchor = nextAnchorId
  anchors[content] = anchor
  nextAnchorId = cast[AnchorId](cast[int](nextAnchorId) + 1)

template handleAlias() {.dirty.} =
  if anchor != yAnchorNone or tag != yTagQuestionmark:
    raiseError("Alias may not have anchor or tag")
  content = ""
  lexer.anchorName(content)
  try:
    cachedScalar = aliasEvent(anchors[content])
  except KeyError:
    raiseError("Unknown anchor")
  state = fpBlockAfterScalar

template leaveFlowLevel() {.dirty.} =
  flowdepth.inc(-1)
  if ancestry.len == 0:
    state = fpExpectDocEnd
  else:
    level = ancestry.pop()
    if flowdepth == 0:
      lexer.lineEnding()
      handleLineEnd(true)
      state = fpBlockLineStart
    else:
      state = fpFlowAfterObject

template finishLine(lexer: FastLexer) =
  debug("lex: finishLine")
  while lexer.buf[lexer.bufpos] notin lineEnd:
    lexer.bufpos.inc()

template skipWhitespace(lexer: FastLexer) =
  debug("lex: skipWhitespace")
  while lexer.buf[lexer.bufpos] in space: lexer.bufpos.inc()

template skipWhitespaceAndNewlines(lexer: FastLexer) =
  debug("lex: skipWhitespaceAndNewLines")
  while true:
    case lexer.buf[lexer.bufpos]
    of space:
      lexer.bufpos.inc()
    of '\x0A':
      lexer.bufpos = lexer.handleLF(lexer.bufpos)
    of '\c':
      lexer.bufpos = lexer.handleCR(lexer.bufpos)
    else:
      break

template skipIndentation(lexer: FastLexer) =
  debug("lex: skipIndentation")
  while lexer.buf[lexer.bufpos] == ' ': lexer.bufpos.inc()

template directiveName(lexer: FastLexer, directive: var LexedDirective) =
  debug("lex: directiveName")
  directive = ldUnknown
  lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
  lexer.bufpos.inc()
  if lexer.buf[lexer.bufpos] == 'Y':
    lexer.bufpos.inc()
    if lexer.buf[lexer.bufpos] == 'A':
      lexer.bufpos.inc()
      if lexer.buf[lexer.bufpos] == 'M':
        lexer.bufpos.inc()
        if lexer.buf[lexer.bufpos] == 'L':
          lexer.bufpos.inc()
          if lexer.buf[lexer.bufpos] in spaceOrLineEnd:
            directive = ldYaml
  elif lexer.buf[lexer.bufpos] == 'T':
    lexer.bufpos.inc()
    if lexer.buf[lexer.bufpos] == 'A':
      lexer.bufpos.inc()
      if lexer.buf[lexer.bufpos] == 'G':
        lexer.bufpos.inc()
        if lexer.buf[lexer.bufpos] in [' ', '\t', '\x0A', '\c', EndOfFile]:
          directive = ldTag
  while lexer.buf[lexer.bufpos] notin spaceOrLineEnd:
    lexer.bufpos.inc()

template yamlVersion(lexer: FastLexer, o: var string) =
  debug("lex: yamlVersion")
  while lexer.buf[lexer.bufpos] in space:
    lexer.bufpos.inc()
  var c = lexer.buf[lexer.bufpos]
  if c notin digits:
    raiseError("Invalid YAML version number")
  o.add(c)
  lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
  lexer.bufpos.inc()
  c = lexer.buf[lexer.bufpos]
  while c in digits:
    lexer.bufpos.inc()
    o.add(c)
    c = lexer.buf[lexer.bufpos]
  if lexer.buf[lexer.bufpos] != '.':
    raiseError("Invalid YAML version number")
  lexer.bufpos.inc()
  if lexer.buf[lexer.bufpos] notin digits:
    raiseError("Invalid YAML version number")
  lexer.bufpos.inc()
  while lexer.buf[lexer.bufpos] in digits:
    lexer.bufpos.inc()
  if lexer.buf[lexer.bufpos] notin spaceOrLineEnd:
    raiseError("Invalid YAML version number")

template lineEnding(lexer: FastLexer) =
  debug("lex: lineEnding")
  if lexer.buf[lexer.bufpos] notin lineEnd:
    while lexer.buf[lexer.bufpos] in space:
      lexer.bufpos.inc()
    if lexer.buf[lexer.bufpos] in lineEnd:
      discard
    elif lexer.buf[lexer.bufpos] == '#':
      while lexer.buf[lexer.bufpos] notin lineEnd:
        lexer.bufpos.inc()
    else:
      raiseError("Unexpected token (expected comment or line end)",
                 lexer.bufpos)

template tagShorthand(lexer: FastLexer, shorthand: var string) =
  debug("lex: tagShorthand")
  while lexer.buf[lexer.bufpos] in space:
    lexer.bufpos.inc()
  if lexer.buf[lexer.bufpos] != '!':
    raiseError("Invalid tag shorthand")
  shorthand.add('!')
  lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
  lexer.bufpos.inc()
  var c = lexer.buf[lexer.bufpos]
  if c in spaceOrLineEnd:
    discard
  else:
    while c != '!':
      case c
      of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-':
        shorthand.add(c)
        lexer.bufpos.inc()
        c = lexer.buf[lexer.bufpos]
      else:
        raiseError("Illegal character in tag shorthand", lexer.bufpos)
    shorthand.add(c)
  lexer.bufpos.inc()
  if lexer.buf[lexer.bufpos] notin spaceOrLineEnd:
    raiseError("Missing space after tag shorthand", lexer.bufpos)

template tagUri(lexer: FastLexer, uri: var string) =
  debug("lex: tagUri")
  while lexer.buf[lexer.bufpos] in space:
    lexer.bufpos.inc()
  lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
  var c = lexer.buf[lexer.bufpos]
  while c notin spaceOrLineEnd:
    case c
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@', '&',
       '-', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')':
      uri.add(c)
      lexer.bufpos.inc()
      c = lexer.buf[lexer.bufpos]
    else:
      raiseError("Invalid tag uri")

template directivesEnd(lexer: FastLexer, content: var string,
                       token: var LexedPossibleDirectivesEnd) =
  debug("lex: directivesEnd")
  content.add('-')
  lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
  lexer.bufpos.inc()
  case lexer.buf[lexer.bufpos]
  of '-':
    content.add('-')
    lexer.bufpos.inc()
    if lexer.buf[lexer.bufpos] == '-':
      content.add('-')
      lexer.bufpos.inc()
      if lexer.buf[lexer.bufpos] in spaceOrLineEnd:
        token = lpdeDirectivesEnd
      else:
        token = lpdeScalarContent
    else:
      token = lpdeScalarContent
  of spaceOrLineEnd:
    token = lpdeSequenceItem
  else:
    token = lpdeScalarContent

template documentEnd(lexer: var FastLexer, content: var string,
                     isDocumentEnd: var bool) =
  content.add('.')
  lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
  lexer.bufpos.inc()
  if lexer.buf[lexer.bufpos] == '.':
    content.add('.')
    lexer.bufpos.inc()
    if lexer.buf[lexer.bufpos] == '.':
      content.add('.')
      lexer.bufpos.inc()
      if lexer.buf[lexer.bufpos] in spaceOrLineEnd:
        isDocumentEnd = true
      else:
        isDocumentEnd = false
    else:
      isDocumentEnd = false
  else:
    isDocumentEnd = false

template singleQuotedScalar(lexer: FastLexer, content: var string) =
  debug("lex: singleQuotedScalar")
  lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
  lexer.bufpos.inc()
  while true:
    case lexer.buf[lexer.bufpos]
    of '\'':
      lexer.bufpos.inc()
      if lexer.buf[lexer.bufpos] == '\'':
        content.add('\'')
      else:
        break
    of EndOfFile:
      raiseError("Unfinished single quoted string")
    else:
      content.add(lexer.buf[lexer.bufpos])
    lexer.bufpos.inc()

proc unicodeSequence(lexer: var FastLexer, length: int):
      string {.raises: [YamlParserError].} =
  debug("lex: unicodeSequence")
  var unicodeChar = 0.Rune
  let start = lexer.bufpos - 1
  for i in countup(0, length - 1):
    lexer.bufpos.inc()
    let
      digitPosition = length - i - 1
      c = lexer.buf[lexer.bufpos]
    case c
    of EndOFFile:
        raiseError("Unfinished unicode escape sequence", start)
    of '0' .. '9':
        unicodeChar = unicodechar or
                (cast[int](c) - 0x30) shl (digitPosition * 4)
    of 'A' .. 'F':
        unicodeChar = unicodechar or
                (cast[int](c) - 0x37) shl (digitPosition * 4)
    of 'a' .. 'f':
        unicodeChar = unicodechar or
                (cast[int](c) - 0x57) shl (digitPosition * 4)
    else:
      raiseError("Invalid character in unicode escape sequence", lexer.bufpos)
  return toUTF8(unicodeChar)

template doublyQuotedScalar(lexer: FastLexer, content: var string) =
  debug("lex: doublyQuotedScalar")
  lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
  while true:
    lexer.bufpos.inc()
    let c = lexer.buf[lexer.bufpos]
    case c
    of EndOfFile:
      raiseError("Unfinished doubly quoted string")
    of '\\':
      lexer.bufpos.inc()
      case lexer.buf[lexer.bufpos]
      of EndOfFile:
        raiseError("Unfinished escape sequence")
      of '0':       content.add('\0')
      of 'a':       content.add('\x07')
      of 'b':       content.add('\x08')
      of '\t', 't': content.add('\t')
      of 'n':       content.add('\x0A')
      of 'v':       content.add('\v')
      of 'f':       content.add('\f')
      of 'r':       content.add('\r')
      of 'e':       content.add('\e')
      of ' ':       content.add(' ')
      of '"':       content.add('"')
      of '/':       content.add('/')
      of '\\':      content.add('\\')
      of 'N':       content.add(UTF8NextLine)
      of '_':       content.add(UTF8NonBreakingSpace)
      of 'L':       content.add(UTF8LineSeparator)
      of 'P':       content.add(UTF8ParagraphSeparator)
      of 'x':       content.add(lexer.unicodeSequence(2))
      of 'u':       content.add(lexer.unicodeSequence(4))
      of 'U':       content.add(lexer.unicodeSequence(8))
      else:
        raiseError("Illegal character in escape sequence")
    of '"':
      lexer.bufpos.inc()
      break
    else:
      content.add(c)

proc isPlainSafe(lexer: FastLexer, index: int, context: YamlContext): bool =
  case lexer.buf[lexer.bufpos + 1]
  of spaceOrLineEnd:
    result = false
  of flowIndicators:
    result = context in [cFlowOut, cBlockKey]
  else:
    result = true

template plainScalar(lexer: FastLexer, content: var string,
                     context: YamlContext) =
  debug("lex: plainScalar")
  lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
  content.add(lexer.buf[lexer.bufpos])
  block outer:
    while true:
      lexer.bufpos.inc()
      let c = lexer.buf[lexer.bufpos]
      case c
      of lineEnd:
        break
      of ' ', '\t':
        var after = "" & c
        while true:
          lexer.bufpos.inc()
          let c2 = lexer.buf[lexer.bufpos]
          case c2
          of ' ', '\t':
            after.add(c2)
          of lineEnd:
            break outer
          of ':':
            if lexer.isPlainSafe(lexer.bufpos + 1, context):
              content.add(after & ':')
            else:
              break outer
          of '#':
            break outer
          else:
            content.add(after)
            content.add(c2)
            break
      of flowIndicators:
        if context in [cBlockOut, cBlockIn, cBlockKey]:
          content.add(c)
        else:
          break
      of ':':
        if lexer.isPlainSafe(lexer.bufpos + 1, context):
          content.add(':')
        else:
          break outer
      of '#':
        break outer
      else:
        content.add(c)

template continueMultilineScalar() {.dirty.} =
  cachedScalar.scalarContent.add(if newlines == 1: " " else:
                                 repeat('\x0A', newlines - 1))
  lexer.plainScalar(cachedScalar.scalarContent, cBlockOut)
  state = fpBlockAfterPlainScalar

template handleFlowPlainScalar() {.dirty.} =
  content = ""
  lexer.plainScalar(content, cFlowOut)
  if lexer.buf[lexer.bufpos] in ['{', '}', '[', ']', ',', ':', '#']:
    discard
  else:
    var newlines = 0
    while true:
      case lexer.buf[lexer.bufpos]
      of ':':
        raiseError("Multiline scalar is not allowed as implicit key")
      of '#', EndOfFile:
        break
      of '\x0A':
        lexer.bufpos = lexer.handleLF(lexer.bufpos)
        newlines.inc()
      of '\c':
        lexer.bufpos = lexer.handleCR(lexer.bufpos)
        newlines.inc()
      of flowIndicators:
        break
      of ' ', '\t':
        lexer.skipWhitespace()
      else:
        if newlines == 1:
          content.add(' ')
          newlines = 0
        elif newlines > 1:
          content.add(repeat(' ', newlines - 1))
          newlines = 0
        lexer.plainScalar(content, cFlowOut)
  yield scalarEvent(content, tag, anchor)
  tag = yTagQuestionMark
  anchor = yAnchorNone
  level = ancestry.pop()
  state = fpFlowAfterObject

template tagHandle(lexer: var FastLexer, content: var string,
                   shorthandEnd: var int) =
  debug("lex: tagHandle")
  shorthandEnd = 0
  lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
  content.add(lexer.buf[lexer.bufpos])
  var i = 0
  while true:
    lexer.bufpos.inc()
    i.inc()
    let c = lexer.buf[lexer.bufpos]
    case c
    of spaceOrLineEnd:
      if shorthandEnd == -1:
        raiseError("Unclosed verbatim tag")
      break
    of '!':
      if shorthandEnd == -1 and i == 2:
        content.add(c)
      elif shorthandEnd != 0:
        raiseError("Illegal character in tag suffix", lexer.bufpos)
      shorthandEnd = i
      content.add(c)
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@', '&',
       '-', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')':
      content.add(c)
    of '<':
      if i == 1:
        shorthandEnd = -1
        content = ""
      else:
        raiseError("Illegal character in tag handle", lexer.bufpos)
    of '>':
      if shorthandEnd == -1:
        lexer.bufpos.inc()
        if lexer.buf[lexer.bufpos] notin spaceOrLineEnd:
          raiseError("Missing space after verbatim tag handle", lexer.bufpos)
        break
      else:
        raiseError("Illegal character in tag handle", lexer.bufpos)
    else:
      raiseError("Illegal character in tag handle", lexer.bufpos)

template anchorName(lexer: FastLexer, content: var string) =
  debug("lex: anchorName")
  lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
  while true:
    lexer.bufpos.inc()
    let c = lexer.buf[lexer.bufpos]
    case c
    of spaceOrLineEnd:
      break
    of '[', ']', '{', '}', ',':
      raiseError("Illegal character in anchor", lexer.bufpos)
    else:
      content.add(c)

proc fastparse*(tagLib: TagLibrary, s: Stream): YamlStream =
  result = iterator(): YamlStreamEvent =
    var
      lexer: FastLexer
      state = fpInitial
      shorthands: Table[string, string]
      anchors: Table[string, AnchorId]
      nextAnchorId: AnchorId
      content: string
      tag, objectTag: TagId
      anchor, objectAnchor: AnchorId
      ancestry = newSeq[FastParseLevel]()
      level: FastParseLevel
      cachedScalar: YamlStreamEvent
      indentation: int
      newlines: int
      flowdepth: int = 0
    
    lexer.open(s)
    initDocValues()
    
    while true:
      case state
      of fpInitial:
        debug("state: initial")
        case lexer.buf[lexer.bufpos]
        of '%':
          var ld: LexedDirective
          lexer.directiveName(ld)
          case ld
          of ldYaml:
            var version = ""
            lexer.yamlVersion(version)
            if version != "1.2":
              echo "version is not 1.2!"
              # TODO: warning (unknown version)
              discard
            lexer.lineEnding()
            handleLineEnd(false)
          of ldTag:
            var shorthand, uri = ""
            lexer.tagShorthand(shorthand)
            lexer.tagUri(uri)
            shorthands.add(shorthand, uri)
            lexer.lineEnding()
            handleLineEnd(false)
          of ldUnknown:
            # TODO: warning (unknown directive)
            lexer.finishLine()
            handleLineEnd(false)
        of ' ', '\t':
          lexer.bufpos.inc()
        of '\x0A':
          lexer.bufpos = lexer.handleLF(lexer.bufpos)
        of '\c':
          lexer.bufpos = lexer.handleCR(lexer.bufpos)
          lexer.bufpos.inc()
        of EndOfFile:
          return
        of '#':
          lexer.lineEnding()
          handleLineEnd(false)
        of '-':
          var token: LexedPossibleDirectivesEnd
          content = ""
          lexer.directivesEnd(content, token)
          yield startDocEvent()
          case token
          of lpdeDirectivesEnd:
            state = fpBlockObjectStart
          of lpdeSequenceItem:
            indentation = 0
            handleStartBlockSequence()
            state = fpBlockObjectStart
          of lpdeScalarContent:
            lexer.plainScalar(content, cBlockOut)
            cachedScalar = scalarEvent(content, tag, anchor)
            state = fpBlockAfterPlainScalar
        else:
          yield startDocEvent()
          state = fpBlockLineStart
      of fpBlockLineStart:
        debug("state: blockLineStart")
        case lexer.buf[lexer.bufpos]
        of '-':
          var token: LexedPossibleDirectivesEnd
          content = ""
          lexer.directivesEnd(content, token)
          case token
          of lpdeDirectivesEnd:
            closeEverything()
            initDocValues()
            yield startDocEvent()
            state = fpBlockObjectStart
          of lpdeSequenceItem:
            indentation = 0
            closeMoreIndentedLevels()
            handleStartBlockSequence()
            state = fpBlockObjectStart
          of lpdeScalarContent:
            if level.kind == fplScalar:
              continueMultilineScalar()
            else:
              lexer.plainScalar(content, cBlockOut)
              cachedScalar = scalarEvent(content, tag, anchor)
              state = fpBlockAfterPlainScalar
        of '.':
          var isDocumentEnd: bool
          content = ""
          lexer.documentEnd(content, isDocumentEnd)
          if isDocumentEnd:
            lexer.lineEnding()
            closeEverything()
            initDocValues()
            state = fpInitial
          elif level.kind == fplScalar:
            continueMultilineScalar()
          else:
            lexer.plainScalar(content, cBlockOut)
            cachedScalar = scalarEvent(content, tag, anchor)
            state = fpBlockAfterPlainScalar
        of ' ':
          lexer.skipIndentation()
          indentation = lexer.getColNumber(lexer.bufpos)
          closeMoreIndentedLevels()
          case level.kind
          of fplScalar:
            state = fpBlockContinueScalar
          of fplUnknown:
            state = fpBlockObjectStart
            level.indentation = indentation
          else:
            state = fpBlockObjectStart
        else:
          indentation = 0
          closeMoreIndentedLevels()
          case level.kind
          of fplScalar:
            state = fpBlockContinueScalar
          of fplUnknown:
            state = fpBlockObjectStart
            level.indentation = indentation
          else:
            state = fpBlockObjectStart
      of fpBlockContinueScalar:
        debug("state: blockAfterPlainScalar")
        lexer.skipWhitespace()
        case lexer.buf[lexer.bufpos]
        of '\x0A':
          newlines.inc()
          lexer.bufpos = lexer.handleLF(lexer.bufpos)
          state = fpBlockLineStart
        of '\c':
          newlines.inc()
          lexer.bufpos = lexer.handleCR(lexer.bufpos)
        of ':':
          if lexer.isPlainSafe(lexer.bufpos + 1, cBlockOut):
            continueMultilineScalar()
          else:
            raiseError("Unexpected token", lexer.bufpos)
        of '#':
          yield cachedScalar
          lexer.lineEnding()
          handleLineEnd(true)
          if ancestry.len == 0:
            state = fpExpectDocEnd
          else:
            level = ancestry.pop()
            handleObjectEnd()
            state = fpBlockLineStart
        else:
          continueMultilineScalar()
        
      of fpBlockAfterPlainScalar:
        debug("state: blockAfterPlainScalar")
        lexer.skipWhitespace()
        case lexer.buf[lexer.bufpos]
        of '\x0A':
          if level.kind notin [fplUnknown, fplScalar]:
            raiseError("Unexpected scalar")
          newlines = 1
          level.kind = fplScalar
          lexer.bufpos = lexer.handleLF(lexer.bufpos)
          state = fpBlockLineStart
        of '\c':
          if level.kind notin [fplUnknown, fplScalar]:
            raiseError("Unexpected scalar")
          newlines = 1
          level.kind = fplScalar
          lexer.bufpos = lexer.handleCR(lexer.bufpos)
          state = fpBlockLineStart
        else:
          state = fpBlockAfterScalar
      of fpBlockAfterScalar:
        debug("state: blockAfterScalar")
        lexer.skipWhitespace()
        case lexer.buf[lexer.bufpos]
        of EndOfFile:
          level.kind = fplScalar
          closeEverything()
          break
        of '\x0A':
          if level.kind != fplUnknown:
            raiseError("Unexpected scalar")
          applyObjectProperties()
          yield cachedScalar
          if ancestry.len == 0:
            state = fpExpectDocEnd
          else:
            level = ancestry.pop()
            handleObjectEnd()
            state = fpBlockLineStart
          lexer.bufpos = lexer.handleLF(lexer.bufpos)
        of '\c':
          if level.kind != fplUnknown:
            raiseError("Unexpected scalar")
          applyObjectProperties()
          yield cachedScalar
          if ancestry.len == 0:
            state = fpExpectDocEnd
          else:
            level = ancestry.pop()
            handleObjectEnd()
            state = fpBlockLineStart
          lexer.bufpos = lexer.handleCR(lexer.bufpos)
        of ':':
          case level.kind
          of fplUnknown:
            level.kind = fplMapKey
            handleStartObject(yamlStartMap)
          of fplMapValue:
            yield scalarEvent("", yTagQuestionMark, yAnchorNone)
            level.kind = fplMapKey
          of fplMapKey:
            if level.indentation != indentation:
              raiseError("Invalid indentation for map key")
          of fplSequence:
            raiseError("Illegal token (expected sequence item)")
          of fplScalar:
            raiseError("Multiline scalars may not be implicit map keys")
          handleObjectEnd()
          yield cachedScalar
          ancestry.add(level)
          lexer.bufpos.inc()
          lexer.skipWhitespace()
          indentation = lexer.getColNumber(lexer.bufpos)
          level = FastParseLevel(kind: fplUnknown, indentation: indentation)
          state = fpBlockObjectStart
        of '#':
          applyObjectProperties()
          yield cachedScalar
          lexer.lineEnding()
          handleLineEnd(true)
          state = fpBlockLineStart
        else:
          raiseError("Illegal token (expected ':', comment or line end)",
                     lexer.bufpos)
      of fpBlockObjectStart:
        debug("state: blockObjectStart")
        lexer.skipWhitespace()
        let objectStart = lexer.getColNumber(lexer.bufpos)
        case lexer.buf[lexer.bufpos]
        of '\x0A':
          propsToObjectProps()
          lexer.bufpos = lexer.handleLF(lexer.bufpos)
          state = fpBlockLineStart
        of '\c':
          propsToObjectProps()
          lexer.bufpos = lexer.handleCR(lexer.bufpos)
          state = fpBlockLineStart
        of EndOfFile:
          closeEverything()
          return
        of '#':
          lexer.lineEnding()
          handleLineEnd(true)
        of '\'':
          handleStartBlockScalar()
          content = ""
          lexer.singleQuotedScalar(content)
          if tag == yTagQuestionMark:
            tag = yTagExclamationMark
          cachedScalar = scalarEvent(content, tag, anchor)
          state = fpBlockAfterScalar
        of '"':
          handleStartBlockScalar()
          content = ""
          lexer.doublyQuotedScalar(content)
          if tag == yTagQuestionMark:
            tag = yTagExclamationMark
          cachedScalar = scalarEvent(content, tag, anchor)
          state = fpBlockAfterScalar
        of '-':
          if lexer.isPlainSafe(lexer.bufpos + 1, cBlockOut):
            handleStartBlockScalar()
            lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
            lexer.plainScalar(content, cBlockOut)
            cachedScalar = scalarEvent(content, tag, anchor)
            state = fpBlockAfterPlainScalar
          else:
            lexer.bufpos.inc()
            handleStartBlockSequence()
        of '!':
          handleTagHandle()
        of '&':
          handleAnchor()
        of '*':
          handleAlias()
        of '[', '{':
          applyObjectProperties()
          state = fpFlow
        else:
          handleStartBlockScalar()
          content = ""
          lexer.plainScalar(content, cBlockOut)
          cachedScalar = scalarEvent(content, tag, anchor)
          state = fpBlockAfterPlainScalar
      of fpExpectDocEnd:
        case lexer.buf[lexer.bufpos]
        of '-':
          var token: LexedPossibleDirectivesEnd
          content = ""
          lexer.directivesEnd(content, token)
          case token
          of lpdeDirectivesEnd:
            yield endDocEvent()
            initDocValues()
            yield startDocEvent()
            state = fpBlockObjectStart
          else:
            raiseError("Unexpected content (expected document end)")
        of '.':
          var isDocumentEnd: bool
          content = ""
          lexer.documentEnd(content, isDocumentEnd)
          if isDocumentEnd:
            yield endDocEvent()
            initDocValues()
            state = fpInitial
          else:
            raiseError("Unexpected content (expected document end)")
        of ' ', '\t', '#':
          lexer.lineEnding()
          handleLineEnd(true)
        of '\x0A':
          lexer.bufpos = lexer.handleLF(lexer.bufpos)
        of '\c':
          lexer.bufpos = lexer.handleCR(lexer.bufpos)
        of EndOfFile:
          yield endDocEvent()
          break
        else:
          raiseError("Unexpected content (expected document end)")
      of fpFlow:
        lexer.skipWhitespaceAndNewlines()
        case lexer.buf[lexer.bufpos]
        of '{':
          assert(level.kind == fplUnknown)
          yield startMapEvent(tag, anchor)
          tag = yTagQuestionmark
          anchor = yAnchorNone
          flowdepth.inc()
          level.kind = fplMapKey
          ancestry.add(level)
          level = FastParseLevel(kind: fplUnknown)
          lexer.bufpos.inc()
        of '[':
          assert(level.kind == fplUnknown)
          yield startSeqEvent(tag, anchor)
          tag = yTagQuestionmark
          anchor = yAnchorNone
          flowdepth.inc()
          level.kind = fplSequence
          ancestry.add(level)
          level = FastParseLevel(kind: fplUnknown)
          lexer.bufpos.inc()
        of '}':
          assert(level.kind == fplUnknown)
          level = ancestry.pop()
          case level.kind
          of fplMapValue:
            yield scalarEvent("", tag, anchor)
            tag = yTagQuestionmark
            anchor = yAnchorNone
          of fplMapKey:
            discard
          of fplSequence:
            raiseError("Unexpected token (expected ']')", lexer.bufpos)
          of fplUnknown, fplScalar:
            assert(false)
          yield endMapEvent()
          leaveFlowLevel()
          lexer.bufpos.inc()
        of ']':
          assert(level.kind == fplUnknown)
          level = ancestry.pop()
          case level.kind
          of fplSequence:
            yield endSeqEvent()
          of fplMapKey, fplMapValue:
            raiseError("Unexpected token (expected '}')", lexer.bufpos)
          of fplUnknown, fplScalar:
            assert(false)
          leaveFlowLevel()
          lexer.bufpos.inc()
        of ',':
          assert(level.kind == fplUnknown)
          level = ancestry.pop()
          case level.kind
          of fplSequence:
            yield scalarEvent("", tag, anchor)
            tag = yTagQuestionmark
            anchor = yAnchorNone
          of fplMapValue:
            yield scalarEvent("", tag, anchor)
            tag = yTagQuestionmark
            anchor = yAnchorNone
            level.kind = fplMapKey
          of fplMapKey:
            yield scalarEvent("", tag, anchor)
            tag = yTagQuestionmark
            anchor = yAnchorNone
            yield scalarEvent("", tag, anchor)
          of fplUnknown, fplScalar:
            assert(false)
          ancestry.add(level)
          level = FastParseLevel(kind: fplUnknown)
          lexer.bufpos.inc()
        of ':':
          assert(level.kind == fplUnknown)
          if lexer.isPlainSafe(lexer.bufpos + 1, cFlowIn):
            level = ancestry.pop()
            case level.kind
            of fplSequence, fplMapValue:
              raiseError("Unexpected token (expected ',')", lexer.bufpos)
            of fplMapKey:
              yield scalarEvent("", tag, anchor)
              tag = yTagQuestionmark
              anchor = yAnchorNone
              level.kind = fplMapValue
            of fplUnknown, fplScalar:
              assert(false)
            ancestry.add(level)
            level = FastParseLevel(kind: fplUnknown)
            lexer.bufpos.inc()
          else:
            handleFlowPlainScalar()
        of '\'':
          content = ""
          lexer.singleQuotedScalar(content)
          if tag == yTagQuestionMark:
            tag = yTagExclamationMark
          yield scalarEvent(content, tag, anchor)
          tag = yTagQuestionmark
          anchor = yAnchorNone
          level = ancestry.pop()
          state = fpFlowAfterObject
        of '"':
          content = ""
          lexer.doublyQuotedScalar(content)
          if tag == yTagQuestionmark:
            tag = yTagExclamationmark
          yield scalarEvent(content, tag, anchor)
          tag = yTagQuestionmark
          anchor = yAnchorNone
          level = ancestry.pop()
          state = fpFlowAfterObject
        of '!':
          handleTagHandle()
        of '&':
          handleAnchor()
        of '*':
          handleAlias()
          level = ancestry.pop()
          yield cachedScalar
          state = fpFlowAfterObject
        else:
          handleFlowPlainScalar()
      of fpFlowAfterObject:
        lexer.skipWhitespaceAndNewlines()
        case lexer.buf[lexer.bufpos]
        of ']':
          case level.kind
          of fplSequence:
            yield endSeqEvent()
          of fplMapKey, fplMapValue:
            raiseError("Unexpected token (expected '}')", lexer.bufpos)
          of fplScalar, fplUnknown:
            assert(false)
          leaveFlowLevel()
        of '}':
          case level.kind
          of fplSequence:
            raiseError("Unexpected token (expected ']')", lexer.bufpos)
          of fplMapKey:
            yield scalarEvent("", yTagQuestionmark, yAnchorNone)
          of fplMapValue:
            discard
          of fplUnknown, fplScalar:
            assert(false)
          yield endMapEvent()
          leaveFlowLevel()
        of ',':
          case level.kind
          of fplSequence:
            discard
          of fplMapKey:
            yield scalarEvent("", yTagQuestionmark, yAnchorNone)
          of fplMapValue:
            level.kind = fplMapKey
          of fplUnknown, fplScalar:
            assert(false)
          ancestry.add(level)
          level = FastParseLevel(kind: fplUnknown)
          state = fpFlow
        of ':':
          case level.kind
          of fplSequence, fplMapValue:
            raiseError("Unexpected token (expected ',')", lexer.bufpos)
          of fplMapKey:
            level.kind = fplMapValue
          of fplUnknown, fplScalar:
            assert(false)
          ancestry.add(level)
          level = FastParseLevel(kind: fplUnknown)
          state = fpFlow
        of '#':
          lexer.lineEnding()
        of EndOfFile:
          raiseError("Unclosed flow content", lexer.bufpos)
        else:
          raiseError("Unexpected content (expected flow indicator)",
                     lexer.bufpos)
        lexer.bufpos.inc()
