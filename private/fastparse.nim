type
  FastParseState = enum
    fpInitial, fpBlockLineStart, fpBlockAfterObject, fpBlockAfterPlainScalar,
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

template yieldLevelEnd() {.dirty.} =
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
    yield scalarEvent(content, tag, anchor)
    tag = yTagQuestionMark
    anchor = yAnchorNone
  of fplUnknown:
    yield scalarEvent("", tag, anchor)
    tag = yTagQuestionMark
    anchor = yAnchorNone

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

template handleObjectEnd(nextState: FastParseState) {.dirty.} =
  if ancestry.len == 0:
    state = fpExpectDocEnd
  else:
    level = ancestry.pop()
    state = nextState
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
      assert(false)

template handleObjectStart(k: YamlStreamEventKind) {.dirty.} =
  assert(level.kind == fplUnknown)
  when k == yamlStartMap:
    yield startMapEvent(tag, anchor)
    debug("started map at " & (if level.indentation == -1: $indentation else:
          $level.indentation))
    level.kind = fplMapKey
  else:
    yield startSeqEvent(tag, anchor)
    debug("started sequence at " & (if level.indentation == -1: $indentation else:
          $level.indentation))
    level.kind = fplSequence
  tag = yTagQuestionmark
  anchor = yAnchorNone
  if level.indentation == -1:
    level.indentation = indentation
  ancestry.add(level)
  level = FastParseLevel(kind: fplUnknown, indentation: -1)
  
template closeMoreIndentedLevels() {.dirty.} =
  while ancestry.len > 0:
    let parent = ancestry[ancestry.high]
    if parent.indentation >= indentation:
      debug("Closing because parent.indentation (" & $parent.indentation &
            ") >= indentation(" & $indentation & ")")
      yieldLevelEnd()
      handleObjectEnd(fpBlockAfterObject)
    else:
      break

template closeEverything() {.dirty.} =
  indentation = 0
  closeMoreIndentedLevels()
  yieldLevelEnd()
  yield endDocEvent()

template handleBlockSequenceIndicator() {.dirty.} =
  case level.kind
  of fplUnknown:
    handleObjectStart(yamlStartSequence)
  of fplSequence:
    if level.indentation != indentation:
      raiseError("Invalid indentation of block sequence indicator",
                 lexer.bufpos)
    ancestry.add(level)
    level = FastParseLevel(kind: fplUnknown, indentation: -1)
  else:
      raiseError("Illegal sequence item in map")
  lexer.skipWhitespace()
  indentation = lexer.getColNumber(lexer.bufpos)

template handleMapKeyIndicator() {.dirty.} =
  case level.kind
  of fplUnknown:
    handleObjectStart(yamlStartMap)
  of fplMapValue:
    if level.indentation != indentation:
      raiseError("Invalid indentation of map key indicator",
                 lexer.bufpos)
    yield scalarEvent("", yTagQuestionmark, yAnchorNone)
    level.kind = fplMapKey
    ancestry.add(level)
    level = FastParseLevel(kind: fplUnknown, indentation: -1)
  of fplMapKey:
    if level.indentation != indentation:
      raiseError("Invalid indentation of map key indicator",
                 lexer.bufpos)
    ancestry.add(level)
    level = FastParseLevel(kind: fplUnknown, indentation: -1)
  of fplSequence:
    raiseError("Unexpected map key indicator (expected '- ')")
  of fplScalar:
    raiseError("Unexpected map key indicator (expected multiline scalar end)")
  lexer.skipWhitespace()
  indentation = lexer.getColNumber(lexer.bufpos)

template handleMapValueIndicator() {.dirty.} =
  case level.kind
  of fplUnknown:
    if level.indentation == -1:
      handleObjectStart(yamlStartMap)
      yield scalarEvent("", yTagQuestionmark, yAnchorNone)
    else:
      yield scalarEvent("", tag, anchor)
      tag = yTagQuestionmark
      anchor = yAnchorNone
    ancestry[ancestry.high].kind = fplMapValue
  of fplMapKey:
    if level.indentation != indentation:
      raiseError("Invalid indentation of map key indicator",
                 lexer.bufpos)
    yield scalarEvent("", yTagQuestionmark, yAnchorNone)
    level.kind = fplMapValue
    ancestry.add(level)
    level = FastParseLevel(kind: fplUnknown, indentation: -1)
  of fplMapValue:
    if level.indentation != indentation:
      raiseError("Invalid indentation of map key indicator",
                 lexer.bufpos)
    ancestry.add(level)
    level = FastParseLevel(kind: fplUnknown, indentation: -1)
  of fplSequence:
    raiseError("Unexpected map value indicator (expected '- ')")
  of fplScalar:
    raiseError("Unexpected map value indicator (expected multiline scalar end)")
  lexer.skipWhitespace()
  indentation = lexer.getColNumber(lexer.bufpos)

template initDocValues() {.dirty.} =
  shorthands = initTable[string, string]()
  anchors = initTable[string, AnchorId]()
  shorthands["!"] = "!"
  shorthands["!!"] = "tag:yaml.org,2002:"
  nextAnchorId = 0.AnchorId
  level = FastParseLevel(kind: fplUnknown, indentation: -1)
  tag = yTagQuestionmark
  anchor = yAnchorNone

template handleTagHandle() {.dirty.} =
  if level.kind != fplUnknown:
    raiseError("Unexpected token", lexer.bufpos)
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
  if level.kind != fplUnknown:
    raiseError("Unexpected token", lexer.bufpos)
  if anchor != yAnchorNone:
    raiseError("Only one anchor is allowed per node", lexer.bufpos)
  content = ""
  lexer.anchorName(content)
  anchor = nextAnchorId
  anchors[content] = anchor
  nextAnchorId = cast[AnchorId](cast[int](nextAnchorId) + 1)

template handleAlias() {.dirty.} =
  if level.kind != fplUnknown:
    raiseError("Unexpected token", lexer.bufpos)
  if anchor != yAnchorNone or tag != yTagQuestionmark:
    raiseError("Alias may not have anchor or tag")
  content = ""
  lexer.anchorName(content)
  var id: AnchorId
  try:
    id = anchors[content]
  except KeyError:
    raiseError("Unknown anchor")
  yield aliasEvent(id)
  handleObjectEnd(fpBlockAfterObject)

template leaveFlowLevel() {.dirty.} =
  flowdepth.inc(-1)
  if flowdepth == 0:
    yieldLevelEnd()
    handleObjectEnd(fpBlockAfterObject)
  else:
    yieldLevelEnd()
    handleObjectEnd(fpFlowAfterObject)
  
template handlePossibleMapStart() {.dirty.} =
  if level.indentation == -1:
    var flowDepth = 0
    for p in countup(lexer.bufpos, lexer.bufpos + 1024):
      case lexer.buf[p]
      of ':':
        if flowDepth == 0 and lexer.buf[p + 1] in spaceOrLineEnd:
          handleObjectStart(yamlStartMap)
          break
      of lineEnd:
        break
      of '[', '{':
        flowDepth.inc()
      of '}', ']':
        flowDepth.inc(-1)
      of '?':
        if flowDepth == 0: break
      of '#':
        if lexer.buf[p - 1] in space:
          break
      else:
        discard
    if level.indentation == -1:
      level.indentation = indentation

template handleBlockItemStart() {.dirty.} =
  case level.kind
  of fplUnknown:
    handlePossibleMapStart()
  of fplSequence:
    raiseError("Unexpected token (expected block sequence indicator)",
               lexer.bufpos)
  of fplMapKey:
    ancestry.add(level)
    level = FastParseLevel(kind: fplUnknown, indentation: indentation)
  of fplMapValue:
    yield scalarEvent("", tag, anchor)
    tag = yTagQuestionmark
    anchor = yAnchorNone
    level.kind = fplMapKey
    ancestry.add(level)
    level = FastParseLevel(kind: fplUnknown, indentation: indentation)
  of fplScalar:
    assert(false)

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

template directivesEnd(lexer: FastLexer,
                       token: var LexedPossibleDirectivesEnd) =
  debug("lex: directivesEnd")
  lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
  var p = lexer.bufpos + 1
  case lexer.buf[p]
  of '-':
    p.inc()
    if lexer.buf[p] == '-':
      p.inc()
      if lexer.buf[p] in spaceOrLineEnd:
        token = lpdeDirectivesEnd
      else:
        token = lpdeScalarContent
    else:
      token = lpdeScalarContent
  of spaceOrLineEnd:
    token = lpdeSequenceItem
  else:
    token = lpdeScalarContent

template documentEnd(lexer: var FastLexer, isDocumentEnd: var bool) =
  lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
  var p = lexer.bufpos + 1
  if lexer.buf[p] == '.':
    p.inc()
    if lexer.buf[p] == '.':
      p.inc()
      if lexer.buf[p] in spaceOrLineEnd:
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

template processDoubleQuotedWhitespace(newlines: var int) {.dirty.} =
  var
    after = ""
  block outer:
    while true:
      case lexer.buf[lexer.bufpos]
      of ' ', '\t':
        after.add(lexer.buf[lexer.bufpos])
      of '\x0A':
        lexer.bufpos = lexer.handleLF(lexer.bufpos)
        break
      of '\c':
        lexer.bufpos = lexer.handleLF(lexer.bufpos)
        break
      else:
        content.add(after)
        break outer
      lexer.bufpos.inc()
    while true:
      case lexer.buf[lexer.bufpos]
      of ' ', '\t':
        discard
      of '\x0A':
        lexer.bufpos = lexer.handleLF(lexer.bufpos)
        newlines.inc()
      of '\c':
        lexer.bufpos = lexer.handleCR(lexer.bufpos)
        newlines.inc()
      else:
        if newlines == 0:
          discard
        elif newlines == 1:
          content.add(' ')
        else:
          content.add(repeat('\x0A', newlines - 1))
        break
      lexer.bufpos.inc()

template doubleQuotedScalar(lexer: FastLexer, content: var string) =
  debug("lex: doubleQuotedScalar")
  lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
  lexer.bufpos.inc()
  while true:
    var c = lexer.buf[lexer.bufpos]
    case c
    of EndOfFile:
      raiseError("Unfinished double quoted string")
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
      of '\x0A', '\c':
        var newlines = 0
        processDoubleQuotedWhitespace(newlines)
        continue
      else:
        raiseError("Illegal character in escape sequence")
    of '"':
      lexer.bufpos.inc()
      break
    of '\x0A', '\c', '\t', ' ':
      var newlines = 1
      processdoubleQuotedWhitespace(newlines)
      continue
    else:
      content.add(c)
    lexer.bufpos.inc()

proc isPlainSafe(lexer: FastLexer, index: int, context: YamlContext): bool =
  case lexer.buf[lexer.bufpos + 1]
  of spaceOrLineEnd:
    result = false
  of flowIndicators:
    result = context in [cBlockIn, cBlockOut, cBlockKey]
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
  content.add(if newlines == 1: " " else: repeat('\x0A', newlines - 1))
  lexer.plainScalar(content, cBlockOut)
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
        if lexer.isPlainSafe(lexer.bufpos + 1, cFlowOut):
          if newlines == 1:
            content.add(' ')
            newlines = 0
          elif newlines > 1:
            content.add(repeat(' ', newlines - 1))
            newlines = 0
          lexer.plainScalar(content, cFlowOut)
        elif explicitFlowKey:
          break
        else:
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
  handleObjectEnd(fpFlowAfterObject)

template ensureCorrectIndentation() {.dirty.} =
  if level.indentation != indentation:
    raiseError("Invalid indentation (expected indentation for " & $level.kind &
               " :" & $level.indentation & ")", lexer.bufpos)

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
    of spaceOrLineEnd, '[', ']', '{', '}', ',':
      break
    else:
      content.add(c)

template blockScalar(lexer: FastLexer, content: var string,
                     stateAfter: var FastParseState) =
  type ChompType = enum
    ctKeep, ctClip, ctStrip
  var
    literal: bool
    blockIndent = 0
    chomp: ChompType = ctClip
    detectedIndent = false
    
  case lexer.buf[lexer.bufpos]
  of '|':
    literal = true
  of '>':
    literal = false
  else:
    assert(false)
  
  while true:
    lexer.bufpos.inc()
    case lexer.buf[lexer.bufpos]
    of '+':
      if chomp != ctClip:
        raiseError("Only one chomping indicator is allowed", lexer.bufpos)
      chomp = ctKeep
    of '-':
      if chomp != ctClip:
        raiseError("Only one chomping indicator is allowed", lexer.bufpos)
      chomp = ctStrip
    of '1'..'9':
      if detectedIndent:
        raiseError("Only one indentation indicator is allowed", lexer.bufpos)
      blockIndent = int(lexer.buf[lexer.bufpos]) - int('\x30')
      detectedIndent = true
    of spaceOrLineEnd:
      break
    else:
      raiseError("Illegal character in block scalar header", lexer.bufpos)
  lexer.lineEnding()
  case lexer.buf[lexer.bufpos]
  of '\x0A':
    lexer.bufpos = lexer.handleLF(lexer.bufpos)
  of '\c':
    lexer.bufpos = lexer.handleCR(lexer.bufpos)
  of EndOfFile:
    raiseError("Missing content of block scalar") # TODO: is this correct?
  else:
    assert(false)
  var newlines = 0
  let parentIndent = ancestry[ancestry.high].indentation
  content = ""
  block outer:
    while true:
      block inner:
        for i in countup(1, parentIndent):
          case lexer.buf[lexer.bufpos]
          of ' ':
            discard
          of '\x0A':
            lexer.bufpos = lexer.handleLF(lexer.bufpos)
            newlines.inc()
            break inner
          of '\c':
            lexer.bufpos = lexer.handleCR(lexer.bufpos)
            newlines.inc()
            break inner
          else:
            stateAfter = if i == 1: fpBlockLineStart else: fpBlockObjectStart
            break outer
          lexer.bufpos.inc()
        if detectedIndent:
          for i in countup(1, blockIndent):
            case lexer.buf[lexer.bufpos]
            of ' ':
              discard
            of '\x0A':
              lexer.bufpos = lexer.handleLF(lexer.bufpos)
              newlines.inc()
              break inner
            of '\c':
              lexer.bufpos = lexer.handleCR(lexer.bufpos)
              newlines.inc()
              break inner
            of EndOfFile:
              stateAfter = fpBlockLineStart
              break outer
            of '#':
              lexer.lineEnding()
              case lexer.buf[lexer.bufpos]
              of '\x0A':
                lexer.bufpos = lexer.handleLF(lexer.bufpos)
              of '\c':
                lexer.bufpos = lexer.handleCR(lexer.bufpos)
              else: discard
              stateAfter = fpBlockLineStart
              break outer
            else:
              raiseError("The text is less indented than expected")
            lexer.bufpos.inc()
        else:
          while true:
            case lexer.buf[lexer.bufpos]
            of ' ':
              discard
            of '\x0A':
              lexer.bufpos = lexer.handleLF(lexer.bufpos)
              newlines.inc()
              break inner
            of '\c':
              lexer.bufpos = lexer.handleCR(lexer.bufpos)
              newlines.inc()
              break inner
            of EndOfFile:
              stateAfter = fpBlockLineStart
              break outer
            else:
              blockIndent = lexer.getColNumber(lexer.bufpos) - parentIndent
              detectedIndent = true
              break
            lexer.bufpos.inc()
        case lexer.buf[lexer.bufpos]
        of '\x0A':
          lexer.bufpos = lexer.handleLF(lexer.bufpos)
          newlines.inc()
          break inner
        of '\c':
          lexer.bufpos = lexer.handleCR(lexer.bufpos)
          newlines.inc()
          break inner
        of EndOfFile:
          stateAfter = fpBlockLineStart
          break outer
        else:
          discard
        if newlines > 0:
          if literal:
            content.add(repeat('\x0A', newlines))
          elif newlines == 1:
            content.add(' ')
          else:
            content.add(repeat('\x0A', newlines - 1))
          newlines = 0
        while true:
          let c = lexer.buf[lexer.bufpos]
          case c
          of '\x0A':
            lexer.bufpos = lexer.handleLF(lexer.bufpos)
            newlines.inc()
            break
          of '\c':
            lexer.bufpos = lexer.handleCR(lexer.bufpos)
            newlines.inc()
            break inner
          of EndOfFile:
            stateAfter = fpBlockLineStart
            break outer
          else:
            content.add(c)
          lexer.bufpos.inc()
  case chomp
  of ctClip:
    content.add('\x0A')
  of ctKeep:
    content.add(repeat('\x0A', newlines))
  of ctStrip:
    discard

proc fastparse*(tagLib: TagLibrary, s: Stream): YamlStream =
  result = iterator(): YamlStreamEvent =
    var
      lexer: FastLexer
      state = fpInitial
      shorthands: Table[string, string]
      anchors: Table[string, AnchorId]
      nextAnchorId: AnchorId
      content: string
      tag: TagId
      anchor: AnchorId
      ancestry = newSeq[FastParseLevel]()
      level: FastParseLevel
      indentation: int
      newlines: int
      flowdepth: int = 0
      explicitFlowKey: bool
    
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
          while true:
            lexer.bufpos.inc()
            case lexer.buf[lexer.bufpos]
            of ' ', '\t':
              discard
            of '\x0A':
              lexer.bufpos = lexer.handleLF(lexer.bufpos)
              break
            of '\c':
              lexer.bufpos = lexer.handleCR(lexer.bufpos)
              break
            of '#', EndOfFile:
              lexer.lineEnding()
              handleLineEnd(false)
              break
            else:
              indentation = lexer.getColNumber(lexer.bufpos)
              yield startDocEvent()
              state = fpBlockObjectStart
              break
        of '\x0A':
          lexer.bufpos = lexer.handleLF(lexer.bufpos)
        of '\c':
          lexer.bufpos = lexer.handleCR(lexer.bufpos)
        of EndOfFile:
          return
        of '#':
          lexer.lineEnding()
          handleLineEnd(false)
        of '-':
          var token: LexedPossibleDirectivesEnd
          lexer.directivesEnd(token)
          yield startDocEvent()
          case token
          of lpdeDirectivesEnd:
            lexer.bufpos.inc(3)
            state = fpBlockObjectStart
          of lpdeSequenceItem:
            indentation = 0
            lexer.bufpos.inc()
            handleBlockSequenceIndicator()
            state = fpBlockObjectStart
          of lpdeScalarContent:
            content = ""
            lexer.plainScalar(content, cBlockOut)
            state = fpBlockAfterPlainScalar
        else:
          yield startDocEvent()
          state = fpBlockLineStart
      of fpBlockLineStart:
        debug("state: blockLineStart")
        case lexer.buf[lexer.bufpos]
        of '-':
          var token: LexedPossibleDirectivesEnd
          lexer.directivesEnd(token)
          case token
          of lpdeDirectivesEnd:
            lexer.bufpos.inc(3)
            closeEverything()
            initDocValues()
            yield startDocEvent()
            state = fpBlockObjectStart
          of lpdeSequenceItem:
            indentation = 0
            closeMoreIndentedLevels()
            lexer.bufpos.inc()
            handleBlockSequenceIndicator()
            state = fpBlockObjectStart
          of lpdeScalarContent:
            case level.kind
            of fplScalar:
              continueMultilineScalar()
            of fplUnknown:
              handlePossibleMapStart()
            else:
              ensureCorrectIndentation()
              ancestry.add(level)
              level = FastParseLevel(kind: fplUnknown, indentation: -1)
              content = ""
              lexer.plainScalar(content, cBlockOut)
              state = fpBlockAfterPlainScalar
        of '.':
          var isDocumentEnd: bool
          lexer.documentEnd(isDocumentEnd)
          if isDocumentEnd:
            lexer.bufpos.inc(3)
            lexer.lineEnding()
            handleLineEnd(true)
            closeEverything()
            initDocValues()
            state = fpInitial
          else:
            indentation = 0
            closeMoreIndentedLevels()
            case level.kind
            of fplUnknown:
              handlePossibleMapStart()
            of fplScalar:
              continueMultilineScalar()
            else:
              ensureCorrectIndentation()
              ancestry.add(level)
              level = FastParseLevel(kind: fplUnknown, indentation: -1)
              content = ""
              lexer.plainScalar(content, cBlockOut)
              state = fpBlockAfterPlainScalar
        of ' ':
          lexer.skipIndentation()
          if lexer.buf[lexer.bufpos] in ['\t', '\x0A', '\c', '#']:
            lexer.lineEnding()
            handleLineEnd(true)
          else:
            indentation = lexer.getColNumber(lexer.bufpos)
            closeMoreIndentedLevels()
            case level.kind
            of fplScalar:
              state = fpBlockContinueScalar
            of fplUnknown:
              state = fpBlockObjectStart
            else:
              ensureCorrectIndentation()
              state = fpBlockObjectStart
        else:
          indentation = 0
          closeMoreIndentedLevels()
          case level.kind
          of fplScalar:
            state = fpBlockContinueScalar
          of fplUnknown:
            state = fpBlockObjectStart
          else:
            ensureCorrectIndentation()
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
          yield scalarEvent(content, tag, anchor)
          lexer.lineEnding()
          handleLineEnd(true)
          handleObjectEnd(fpBlockLineStart)
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
          yield scalarEvent(content, tag, anchor)
          handleObjectEnd(fpBlockAfterObject)
      of fpBlockAfterObject:
        debug("state: blockAfterObject")
        lexer.skipWhitespace()
        case lexer.buf[lexer.bufpos]
        of EndOfFile:
          closeEverything()
          break
        of '\x0A':
          state = fpBlockLineStart
          lexer.bufpos = lexer.handleLF(lexer.bufpos)
        of '\c':
          state = fpBlockLineStart
          lexer.bufpos = lexer.handleCR(lexer.bufpos)
        of ':':
          case level.kind
          of fplUnknown:
            handleObjectStart(yamlStartMap)
          of fplMapKey:
            yield scalarEvent("", yTagQuestionMark, yAnchorNone)
            level.kind = fplMapValue
            ancestry.add(level)
            level = FastParseLevel(kind: fplUnknown, indentation: -1)
          of fplMapValue:
            level.kind = fplMapValue
            ancestry.add(level)
            level = FastParseLevel(kind: fplUnknown, indentation: -1)
          of fplSequence:
            raiseError("Illegal token (expected sequence item)")
          of fplScalar:
            raiseError("Multiline scalars may not be implicit map keys")
          lexer.bufpos.inc()
          lexer.skipWhitespace()
          indentation = lexer.getColNumber(lexer.bufpos)
          state = fpBlockObjectStart
        of '#':
          lexer.lineEnding()
          handleLineEnd(true)
          handleObjectEnd(fpBlockLineStart)
        else:
          raiseError("Illegal token (expected ':', comment or line end)",
                     lexer.bufpos)
      of fpBlockObjectStart:
        debug("state: blockObjectStart")
        lexer.skipWhitespace()
        indentation = lexer.getColNumber(lexer.bufpos)
        let objectStart = lexer.getColNumber(lexer.bufpos)
        case lexer.buf[lexer.bufpos]
        of '\x0A':
          lexer.bufpos = lexer.handleLF(lexer.bufpos)
          state = fpBlockLineStart
          level.indentation = -1
        of '\c':
          lexer.bufpos = lexer.handleCR(lexer.bufpos)
          state = fpBlockLineStart
          level.indentation = -1
        of EndOfFile:
          closeEverything()
          return
        of '#':
          lexer.lineEnding()
          handleLineEnd(true)
        of '\'':
          handleBlockItemStart()
          content = ""
          lexer.singleQuotedScalar(content)
          if tag == yTagQuestionMark:
            tag = yTagExclamationMark
          yield scalarEvent(content, tag, anchor)
          handleObjectEnd(fpBlockAfterObject)
        of '"':
          handleBlockItemStart()
          content = ""
          lexer.doubleQuotedScalar(content)
          if tag == yTagQuestionMark:
            tag = yTagExclamationMark
          yield scalarEvent(content, tag, anchor)
          handleObjectEnd(fpBlockAfterObject)
        of '|', '>':
          # TODO: this will scan for possible map start, which is not
          # neccessary in this case
          handleBlockItemStart()
          var stateAfter: FastParseState
          content = ""
          lexer.blockScalar(content, stateAfter)
          if tag == yTagQuestionmark:
            tag = yTagExclamationmark
          yield scalarEvent(content, tag, anchor)
          handleObjectEnd(stateAfter)
        of '-':
          if lexer.isPlainSafe(lexer.bufpos + 1, cBlockOut):
            handleBlockItemStart()
            content = ""
            lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
            lexer.plainScalar(content, cBlockOut)
            state = fpBlockAfterPlainScalar
          else:
            lexer.bufpos.inc()
            handleBlockSequenceIndicator()
        of '!':
          handleBlockItemStart()
          handleTagHandle()
        of '&':
          handleBlockItemStart()
          handleAnchor()
        of '*':
          handleBlockItemStart()
          handleAlias()
        of '[', '{':
          handleBlockItemStart()
          state = fpFlow
        of '?':
          if lexer.isPlainSafe(lexer.bufpos + 1, cBlockOut):
            handleBlockItemStart()
            content = ""
            lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
            lexer.plainScalar(content, cBlockOut)
            state = fpBlockAfterPlainScalar
          else:
            lexer.bufpos.inc()
            handleMapKeyIndicator()
        of ':':
          if lexer.isPlainSafe(lexer.bufpos + 1, cBlockOut):
            handleBlockItemStart()
            content = ""
            lexer.tokenstart = lexer.getColNumber(lexer.bufpos)
            lexer.plainScalar(content, cBlockOut)
            state = fpBlockAfterPlainScalar
          else:
            lexer.bufpos.inc()
            handleMapValueIndicator()
        of '@', '`':
          raiseError("Reserved characters cannot start a plain scalar",
                     lexer.bufpos)
        else:
          handleBlockItemStart()
          content = ""
          lexer.plainScalar(content, cBlockOut)
          state = fpBlockAfterPlainScalar
      of fpExpectDocEnd:
        case lexer.buf[lexer.bufpos]
        of '-':
          var token: LexedPossibleDirectivesEnd
          lexer.directivesEnd(token)
          case token
          of lpdeDirectivesEnd:
            lexer.bufpos.inc(3)
            yield endDocEvent()
            initDocValues()
            yield startDocEvent()
            state = fpBlockObjectStart
          else:
            raiseError("Unexpected content (expected document end)")
        of '.':
          var isDocumentEnd: bool
          lexer.documentEnd(isDocumentEnd)
          if isDocumentEnd:
            lexer.bufpos.inc(3)
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
        debug("state: flow")
        lexer.skipWhitespaceAndNewlines()
        case lexer.buf[lexer.bufpos]
        of '{':
          handleObjectStart(yamlStartMap)
          flowdepth.inc()
          lexer.bufpos.inc()
          explicitFlowKey = false
        of '[':
          handleObjectStart(yamlStartSequence)
          flowdepth.inc()
          lexer.bufpos.inc()
        of '}':
          assert(level.kind == fplUnknown)
          level = ancestry.pop()
          case level.kind
          of fplMapValue:
            yield scalarEvent("", tag, anchor)
            tag = yTagQuestionmark
            anchor = yAnchorNone
            level.kind = fplMapKey
          of fplMapKey:
            if tag != yTagQuestionmark or anchor != yAnchorNone or
                explicitFlowKey:
              yield scalarEvent("", tag, anchor)
              tag = yTagQuestionmark
              anchor = yAnchorNone
              yield scalarEvent("", tag, anchor)
          of fplSequence:
            raiseError("Unexpected token (expected ']')", lexer.bufpos)
          of fplUnknown, fplScalar:
            assert(false)
          lexer.bufpos.inc()
          leaveFlowLevel()
        of ']':
          assert(level.kind == fplUnknown)
          level = ancestry.pop()
          case level.kind
          of fplSequence:
            if tag != yTagQuestionmark or anchor != yAnchorNone:
              yield scalarEvent("", tag, anchor)
              tag = yTagQuestionmark
              anchor = yAnchorNone
          of fplMapKey, fplMapValue:
            raiseError("Unexpected token (expected '}')", lexer.bufpos)
          of fplUnknown, fplScalar:
            assert(false)
          lexer.bufpos.inc()
          leaveFlowLevel()
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
            explicitFlowKey = false
          of fplMapKey:
            yield scalarEvent("", tag, anchor)
            tag = yTagQuestionmark
            anchor = yAnchorNone
            yield scalarEvent("", tag, anchor)
            explicitFlowKey = false
          of fplUnknown, fplScalar:
            assert(false)
          ancestry.add(level)
          level = FastParseLevel(kind: fplUnknown, indentation: -1)
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
            level = FastParseLevel(kind: fplUnknown, indentation: -1)
            lexer.bufpos.inc()
          else:
            handleFlowPlainScalar()
        of '\'':
          content = ""
          lexer.singleQuotedScalar(content)
          if tag == yTagQuestionMark:
            tag = yTagExclamationMark
          yield scalarEvent(content, tag, anchor)
          handleObjectEnd(fpFlowAfterObject)
        of '"':
          content = ""
          lexer.doubleQuotedScalar(content)
          if tag == yTagQuestionmark:
            tag = yTagExclamationmark
          yield scalarEvent(content, tag, anchor)
          handleObjectEnd(fpFlowAfterObject)
        of '!':
          handleTagHandle()
        of '&':
          handleAnchor()
        of '*':
          handleAlias()
          state = fpFlowAfterObject
        of '?':
          if lexer.isPlainSafe(lexer.bufpos + 1, cFlowOut):
            handleFlowPlainScalar()
          elif explicitFlowKey:
            raiseError("Duplicate '?' in flow mapping", lexer.bufpos)
          else:
            explicitFlowKey = true
            lexer.bufpos.inc()
        else:
          handleFlowPlainScalar()
      of fpFlowAfterObject:
        debug("state: flowAfterObject")
        lexer.skipWhitespaceAndNewlines()
        case lexer.buf[lexer.bufpos]
        of ']':
          case level.kind
          of fplSequence:
            discard
          of fplMapKey, fplMapValue:
            raiseError("Unexpected token (expected '}')", lexer.bufpos)
          of fplScalar, fplUnknown:
            assert(false)
          lexer.bufpos.inc()
          leaveFlowLevel()
        of '}':
          case level.kind
          of [fplMapKey, fplMapValue]:
            discard
          of fplSequence:
            raiseError("Unexpected token (expected ']')", lexer.bufpos)
          of fplUnknown, fplScalar:
            assert(false)
          lexer.bufpos.inc()
          leaveFlowLevel()
        of ',':
          case level.kind
          of fplSequence:
            discard
          of fplMapValue:
            yield scalarEvent("", yTagQuestionmark, yAnchorNone)
            level.kind = fplMapKey
            explicitFlowKey = false
          of fplMapKey:
            explicitFlowKey = false
          of fplUnknown, fplScalar:
            assert(false)
          ancestry.add(level)
          level = FastParseLevel(kind: fplUnknown, indentation: -1)
          state = fpFlow
          lexer.bufpos.inc()
        of ':':
          case level.kind
          of fplSequence, fplMapKey:
            raiseError("Unexpected token (expected ',')", lexer.bufpos)
          of fplMapValue:
            level.kind = fplMapValue
          of fplUnknown, fplScalar:
            assert(false)
          ancestry.add(level)
          level = FastParseLevel(kind: fplUnknown, indentation: -1)
          state = fpFlow
          lexer.bufpos.inc()
        of '#':
          lexer.lineEnding()
          handleLineEnd(true)
        of EndOfFile:
          raiseError("Unclosed flow content", lexer.bufpos)
        else:
          raiseError("Unexpected content (expected flow indicator)",
                     lexer.bufpos)
