#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

type
  FastParseState = enum
    fpInitial, fpBlockAfterObject, fpBlockAfterPlainScalar, fpBlockObjectStart,
    fpExpectDocEnd, fpFlow, fpFlowAfterObject, fpAfterDocument
  
  FastParseLevelKind = enum
    fplUnknown, fplSequence, fplMapKey, fplMapValue, fplSinglePairKey,
    fplSinglePairValue, fplScalar, fplDocument
  
  FastParseLevel = object
    kind: FastParseLevelKind
    indentation: int
  
  LexedDirective = enum
    ldYaml, ldTag, ldUnknown
  
  LexedPossibleDirectivesEnd = enum
    lpdeDirectivesEnd, lpdeSequenceItem, lpdeScalarContent
  
  YamlContext = enum
    cBlock, cFlow
  
const
  space          = {' ', '\t'}
  lineEnd        = {'\l', '\c', EndOfFile}
  spaceOrLineEnd = {' ', '\t', '\l', '\c', EndOfFile}
  digits         = {'0'..'9'}
  flowIndicators = {'[', ']', '{', '}', ','}
  
  UTF8NextLine           = toUTF8(0x85.Rune)
  UTF8NonBreakingSpace   = toUTF8(0xA0.Rune)
  UTF8LineSeparator      = toUTF8(0x2028.Rune)
  UTF8ParagraphSeparator = toUTF8(0x2029.Rune)
  UnknownIndentation = int.low
    
proc newYamlParser*(tagLib: TagLibrary = initExtendedTagLibrary(),
                    callback: WarningCallback = nil): YamlParser =
    new(result)
    result.tagLib = tagLib
    result.callback = callback

proc getLineNumber*(p: YamlParser): int = p.lexer.lineNumber
    
proc getColNumber*(p: YamlParser): int = p.tokenstart + 1 # column is 1-based

proc getLineContent*(p: YamlParser, marker: bool = true): string =
    result = p.lexer.getCurrentLine(false)
    if marker:
        result.add(repeat(' ', p.tokenstart) & "^\n")

template debug(message: string) {.dirty.} =
  when defined(yamlDebug):
    try: styledWriteLine(stdout, fgBlue, message)
    except IOError: discard

template debugFail() {.dirty.} =
  when not defined(release):
    echo "internal error at line: ", instantiationInfo().line
  assert(false)

template parserError(message: string) {.dirty.} =
  var e = newException(YamlParserError, message)
  e.line = p.lexer.lineNumber
  e.column = p.tokenstart + 1
  e.lineContent = p.getLineContent(true)
  raise e

template lexerError(lx: BaseLexer, message: string) {.dirty.} =
  var e = newException(YamlParserError, message)
  e.line = lx.lineNumber
  e.column = lx.bufpos + 1
  e.lineContent = lx.getCurrentLine(false) &
      repeat(' ', lx.getColNumber(lx.bufpos)) & "^\n"
  raise e

template initLevel(k: FastParseLevelKind): FastParseLevel =
  FastParseLevel(kind: k, indentation: UnknownIndentation)

template yieldEmptyScalar() {.dirty.} =
  yield scalarEvent("", tag, anchor)
  tag = yTagQuestionMark
  anchor = yAnchorNone

template yieldShallowScalar(content: string) {.dirty.} =
  var e = YamlStreamEvent(kind: yamlScalar, scalarTag: tag,
                          scalarAnchor: anchor)
  shallowCopy(e.scalarContent, content)
  yield e

template yieldLevelEnd() {.dirty.} =
  case level.kind
  of fplSequence: yield endSeqEvent()
  of fplMapKey: yield endMapEvent()
  of fplMapValue, fplSinglePairValue:
    yieldEmptyScalar()
    yield endMapEvent()
  of fplScalar:
    yieldShallowScalar(content)
    tag = yTagQuestionMark
    anchor = yAnchorNone
  of fplUnknown:
    if ancestry.len > 1: yieldEmptyScalar() # don't yield scalar for empty doc
  of fplSinglePairKey, fplDocument: debugFail()

template handleLineEnd(insideDocument: bool) {.dirty.} =
  case p.lexer.buf[p.lexer.bufpos]
  of '\l': p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
  of '\c': p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
  of EndOfFile:
    when insideDocument: closeEverything()
    return
  else: discard
  newlines.inc()

template handleObjectEnd(nextState: FastParseState) {.dirty.} =
  level = ancestry.pop()
  if level.kind == fplSinglePairValue:
    yield endMapEvent()
    level = ancestry.pop()
  state = if level.kind == fplDocument: fpExpectDocEnd else: nextState
  tag = yTagQuestionMark
  anchor = yAnchorNone
  case level.kind
  of fplMapKey: level.kind = fplMapValue
  of fplSinglePairKey: level.kind = fplSinglePairValue
  of fplMapValue: level.kind = fplMapKey
  of fplSequence, fplDocument: discard
  of fplUnknown, fplScalar, fplSinglePairValue: debugFail()

template handleObjectStart(k: YamlStreamEventKind, single: bool = false)
    {.dirty.} =
  assert(level.kind == fplUnknown)
  when k == yamlStartMap:
    yield startMapEvent(tag, anchor)
    if single:
      debug("started single-pair map at " &
          (if level.indentation == UnknownIndentation: $indentation else:
           $level.indentation))
      level.kind = fplSinglePairKey
    else:
      debug("started map at " &
          (if level.indentation == UnknownIndentation: $indentation else:
           $level.indentation))
      level.kind = fplMapKey
  else:
    yield startSeqEvent(tag, anchor)
    debug("started sequence at " &
        (if level.indentation == UnknownIndentation: $indentation else:
         $level.indentation))
    level.kind = fplSequence
  tag = yTagQuestionMark
  anchor = yAnchorNone
  if level.indentation == UnknownIndentation: level.indentation = indentation
  ancestry.add(level)
  level = initLevel(fplUnknown)
  
template closeMoreIndentedLevels(atSequenceItem: bool = false) {.dirty.} =
  while level.kind != fplDocument:
    let parent = ancestry[ancestry.high]
    if parent.indentation >= indentation:
      when atSequenceItem:
        if (indentation == level.indentation and level.kind == fplSequence) or
           (indentation == parent.indentation and level.kind == fplUnknown and
            parent.kind != fplSequence):
          break
      debug("Closing because parent.indentation (" & $parent.indentation &
            ") >= indentation(" & $indentation & ")")
      yieldLevelEnd()
      handleObjectEnd(state)
    else: break
  if level.kind == fplDocument: state = fpExpectDocEnd

template closeEverything() {.dirty.} =
  indentation = 0
  closeMoreIndentedLevels()
  case level.kind
  of fplUnknown: discard ancestry.pop()
  of fplDocument: discard
  else:
    yieldLevelEnd()
    discard ancestry.pop()
  yield endDocEvent()

template handleBlockSequenceIndicator() {.dirty.} =
  startToken()
  case level.kind
  of fplUnknown: handleObjectStart(yamlStartSeq)
  of fplSequence:
    if level.indentation != indentation:
      parserError("Invalid indentation of block sequence indicator")
    ancestry.add(level)
    level = initLevel(fplUnknown)
  else: parserError("Illegal sequence item in map")
  p.lexer.skipWhitespace()
  indentation = p.lexer.getColNumber(p.lexer.bufpos)

template handleMapKeyIndicator() {.dirty.} =
  startToken()
  case level.kind
  of fplUnknown: handleObjectStart(yamlStartMap)
  of fplMapValue:
    if level.indentation != indentation:
      parserError("Invalid indentation of map key indicator")
    yield scalarEvent("", yTagQuestionMark, yAnchorNone)
    level.kind = fplMapKey
    ancestry.add(level)
    level = initLevel(fplUnknown)
  of fplMapKey:
    if level.indentation != indentation:
      parserError("Invalid indentation of map key indicator")
    ancestry.add(level)
    level = initLevel(fplUnknown)
  of fplSequence:
    parserError("Unexpected map key indicator (expected '- ')")
  of fplScalar:
    parserError("Unexpected map key indicator (expected multiline scalar end)")
  of fplSinglePairKey, fplSinglePairValue, fplDocument: debugFail()
  p.lexer.skipWhitespace()
  indentation = p.lexer.getColNumber(p.lexer.bufpos)

template handleMapValueIndicator() {.dirty.} =
  startToken()
  case level.kind
  of fplUnknown:
    if level.indentation == UnknownIndentation:
      handleObjectStart(yamlStartMap)
      yield scalarEvent("", yTagQuestionMark, yAnchorNone)
    else: yieldEmptyScalar()
    ancestry[ancestry.high].kind = fplMapValue
  of fplMapKey:
    if level.indentation != indentation:
      parserError("Invalid indentation of map key indicator")
    yield scalarEvent("", yTagQuestionMark, yAnchorNone)
    level.kind = fplMapValue
    ancestry.add(level)
    level = initLevel(fplUnknown)
  of fplMapValue:
    if level.indentation != indentation:
      parserError("Invalid indentation of map key indicator")
    ancestry.add(level)
    level = initLevel(fplUnknown)
  of fplSequence:
    parserError("Unexpected map value indicator (expected '- ')")
  of fplScalar:
    parserError(
        "Unexpected map value indicator (expected multiline scalar end)")
  of fplSinglePairKey, fplSinglePairValue, fplDocument: debugFail()
  p.lexer.skipWhitespace()
  indentation = p.lexer.getColNumber(p.lexer.bufpos)

template initDocValues() {.dirty.} =
  shorthands = initTable[string, string]()
  anchors = initTable[string, AnchorId]()
  shorthands["!"] = "!"
  shorthands["!!"] = "tag:yaml.org,2002:"
  nextAnchorId = 0.AnchorId
  level = initLevel(fplUnknown)
  tag = yTagQuestionMark
  anchor = yAnchorNone
  ancestry.add(FastParseLevel(kind: fplDocument, indentation: -1))

template handleTagHandle() {.dirty.} =
  startToken()
  if level.kind != fplUnknown: parserError("Unexpected tag handle")
  if tag != yTagQuestionMark:
    parserError("Only one tag handle is allowed per node")
  content.setLen(0)
  var
    shorthandEnd: int
  p.lexer.tagHandle(content, shorthandEnd)
  if shorthandEnd != -1:
    try:
      tagUri.setLen(0)
      tagUri.add(shorthands[content[0..shorthandEnd]])
      tagUri.add(content[shorthandEnd + 1 .. ^1])
    except KeyError:
      parserError("Undefined tag shorthand: " & content[0..shorthandEnd])
    try: tag = p.tagLib.tags[tagUri]
    except KeyError: tag = p.tagLib.registerUri(tagUri)
  else:
    try: tag = p.tagLib.tags[content]
    except KeyError: tag = p.tagLib.registerUri(content)

template handleAnchor() {.dirty.} =
  startToken()
  if level.kind != fplUnknown: parserError("Unexpected token")
  if anchor != yAnchorNone:
    parserError("Only one anchor is allowed per node")
  content.setLen(0)
  p.lexer.anchorName(content)
  anchor = nextAnchorId
  anchors[content] = anchor
  nextAnchorId = cast[AnchorId](cast[int](nextAnchorId) + 1)

template handleAlias() {.dirty.} =
  startToken()
  if level.kind != fplUnknown: parserError("Unexpected token")
  if anchor != yAnchorNone or tag != yTagQuestionMark:
    parserError("Alias may not have anchor or tag")
  content.setLen(0)
  p.lexer.anchorName(content)
  var id: AnchorId
  try: id = anchors[content]
  except KeyError: parserError("Unknown anchor")
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
  
template handlePossibleMapStart(flow: bool = false,
                                single: bool = false) {.dirty.} =
  if level.indentation == UnknownIndentation:
    var flowDepth = 0
    var pos = p.lexer.bufpos
    var recentJsonStyle = false
    while pos < p.lexer.bufpos + 1024:
      case p.lexer.buf[pos]
      of ':':
        if flowDepth == 0 and (p.lexer.buf[pos + 1] in spaceOrLineEnd or
            recentJsonStyle):
          handleObjectStart(yamlStartMap, single)
          break
      of lineEnd: break
      of '[', '{': flowDepth.inc()
      of '}', ']':
        flowDepth.inc(-1)
        if flowDepth < 0: break
      of '?', ',':
        if flowDepth == 0: break
      of '#':
        if p.lexer.buf[pos - 1] in space: break
      of '"':
        pos.inc()
        while p.lexer.buf[pos] notin {'"', EndOfFile, '\l', '\c'}:
          if p.lexer.buf[pos] == '\\': pos.inc()
          pos.inc()
        if p.lexer.buf[pos] != '"': break
      of '\'':
        pos.inc()
        while p.lexer.buf[pos] notin {'\'', '\l', '\c', EndOfFile}:
          pos.inc()
      of '&', '*', '!':
        if pos == p.lexer.bufpos or p.lexer.buf[p.lexer.bufpos] in {'\t', ' '}:
          pos.inc()
          while p.lexer.buf[pos] notin {' ', '\t', '\l', '\c', EndOfFile}:
            pos.inc()
          continue
      else: discard
      if flow and p.lexer.buf[pos] notin {' ', '\t'}:
        recentJsonStyle = p.lexer.buf[pos] in {']', '}', '\'', '"'}
      pos.inc()
    if level.indentation == UnknownIndentation: level.indentation = indentation

template handleBlockItemStart() {.dirty.} =
  case level.kind
  of fplUnknown: handlePossibleMapStart()
  of fplSequence:
    parserError("Unexpected token (expected block sequence indicator)")
  of fplMapKey:
    ancestry.add(level)
    level = FastParseLevel(kind: fplUnknown, indentation: indentation)
  of fplMapValue:
    yieldEmptyScalar()
    level.kind = fplMapKey
    ancestry.add(level)
    level = FastParseLevel(kind: fplUnknown, indentation: indentation)
  of fplScalar, fplSinglePairKey, fplSinglePairValue, fplDocument: debugFail()

template handleFlowItemStart() {.dirty.} =
  if level.kind == fplUnknown and ancestry[ancestry.high].kind == fplSequence:
    handlePossibleMapStart(true, true)

template startToken() {.dirty.} =
  p.tokenstart = p.lexer.getColNumber(p.lexer.bufpos)

template finishLine(lexer: BaseLexer) =
  debug("lex: finishLine")
  while lexer.buf[lexer.bufpos] notin lineEnd:
    lexer.bufpos.inc()

template skipWhitespace(lexer: BaseLexer) =
  debug("lex: skipWhitespace")
  while lexer.buf[lexer.bufpos] in space: lexer.bufpos.inc()

template skipWhitespaceCommentsAndNewlines(lexer: BaseLexer) =
  debug("lex: skipWhitespaceCommentsAndNewlines")
  if lexer.buf[lexer.bufpos] != '#':
    while true:
      case lexer.buf[lexer.bufpos]
      of space: lexer.bufpos.inc()
      of '\l': lexer.bufpos = lexer.handleLF(lexer.bufpos)
      of '\c': lexer.bufpos = lexer.handleCR(lexer.bufpos)
      of '#': # also skip comments
        lexer.bufpos.inc()
        while lexer.buf[lexer.bufpos] notin {'\l', '\c', EndOfFile}:
          lexer.bufpos.inc()
      else: break

template skipIndentation(lexer: BaseLexer) =
  debug("lex: skipIndentation")
  while lexer.buf[lexer.bufpos] == ' ': lexer.bufpos.inc()

template directiveName(lexer: BaseLexer, directive: var LexedDirective) =
  debug("lex: directiveName")
  directive = ldUnknown
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
        if lexer.buf[lexer.bufpos] in {' ', '\t', '\l', '\c', EndOfFile}:
          directive = ldTag
  while lexer.buf[lexer.bufpos] notin spaceOrLineEnd:
    lexer.bufpos.inc()

template yamlVersion(lexer: BaseLexer, o: var string) =
  debug("lex: yamlVersion")
  while lexer.buf[lexer.bufpos] in space: lexer.bufpos.inc()
  var c = lexer.buf[lexer.bufpos]
  if c notin digits: lexerError(lexer, "Invalid YAML version number")
  o.add(c)
  lexer.bufpos.inc()
  c = lexer.buf[lexer.bufpos]
  while c in digits:
    lexer.bufpos.inc()
    o.add(c)
    c = lexer.buf[lexer.bufpos]
  if lexer.buf[lexer.bufpos] != '.':
    lexerError(lexer, "Invalid YAML version number")
  o.add('.')
  lexer.bufpos.inc()
  c = lexer.buf[lexer.bufpos]
  if c notin digits: lexerError(lexer, "Invalid YAML version number")
  o.add(c)
  lexer.bufpos.inc()
  c = lexer.buf[lexer.bufpos]
  while c in digits:
    o.add(c)
    lexer.bufpos.inc()
    c = lexer.buf[lexer.bufpos]
  if lexer.buf[lexer.bufpos] notin spaceOrLineEnd:
    lexerError(lexer, "Invalid YAML version number")

template lineEnding(lexer: BaseLexer) =
  debug("lex: lineEnding")
  if lexer.buf[lexer.bufpos] notin lineEnd:
    while lexer.buf[lexer.bufpos] in space: lexer.bufpos.inc()
    if lexer.buf[lexer.bufpos] in lineEnd: discard
    elif lexer.buf[lexer.bufpos] == '#':
      while lexer.buf[lexer.bufpos] notin lineEnd: lexer.bufpos.inc()
    else:
      startToken()
      parserError("Unexpected token (expected comment or line end)")

template tagShorthand(lexer: BaseLexer, shorthand: var string) =
  debug("lex: tagShorthand")
  while lexer.buf[lexer.bufpos] in space: lexer.bufpos.inc()
  assert lexer.buf[lexer.bufpos] == '!'
  shorthand.add('!')
  lexer.bufpos.inc()
  var c = lexer.buf[lexer.bufpos]
  if c in spaceOrLineEnd: discard
  else:
    while c != '!':
      case c
      of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-':
        shorthand.add(c)
        lexer.bufpos.inc()
        c = lexer.buf[lexer.bufpos]
      else: lexerError(lexer, "Illegal character in tag shorthand")
    shorthand.add(c)
    lexer.bufpos.inc()
  if lexer.buf[lexer.bufpos] notin spaceOrLineEnd:
    lexerError(lexer, "Missing space after tag shorthand")

template tagUriMapping(lexer: BaseLexer, uri: var string) =
  debug("lex: tagUriMapping")
  while lexer.buf[lexer.bufpos] in space:
    lexer.bufpos.inc()
  var c = lexer.buf[lexer.bufpos]
  if c == '!':
    uri.add(c)
    lexer.bufpos.inc()
    c = lexer.buf[lexer.bufpos]
  while c notin spaceOrLineEnd:
    case c
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@', '&',
       '-', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')':
      uri.add(c)
      lexer.bufpos.inc()
      c = lexer.buf[lexer.bufpos]
    else: lexerError(lexer, "Invalid tag uri")

template directivesEndMarker(lexer: var BaseLexer, success: var bool) =
  debug("lex: directivesEndMarker")
  success = true
  for i in 0..2:
    if lexer.buf[lexer.bufpos + i] != '-':
      success = false
      break
  if success: success = lexer.buf[lexer.bufpos + 3] in spaceOrLineEnd

template documentEndMarker(lexer: var BaseLexer, success: var bool) =
  debug("lex: documentEndMarker")
  success = true
  for i in 0..2:
    if lexer.buf[lexer.bufpos + i] != '.':
      success = false
      break
  if success: success = lexer.buf[lexer.bufpos + 3] in spaceOrLineEnd

proc unicodeSequence(lexer: var BaseLexer, length: int):
      string {.raises: [YamlParserError].} =
  debug("lex: unicodeSequence")
  var unicodeChar = 0.int
  for i in countup(0, length - 1):
    lexer.bufpos.inc()
    let
      digitPosition = length - i - 1
      c = lexer.buf[lexer.bufpos]
    case c
    of EndOFFile, '\l', '\c':
        lexerError(lexer, "Unfinished unicode escape sequence")
    of '0' .. '9':
        unicodeChar = unicodechar or
                (cast[int](c) - 0x30) shl (digitPosition * 4)
    of 'A' .. 'F':
        unicodeChar = unicodechar or
                (cast[int](c) - 0x37) shl (digitPosition * 4)
    of 'a' .. 'f':
        unicodeChar = unicodechar or
                (cast[int](c) - 0x57) shl (digitPosition * 4)
    else: lexerError(lexer, "Invalid character in unicode escape sequence")
  return toUTF8(cast[Rune](unicodeChar))

proc byteSequence(lexer: var BaseLexer): char {.raises: [YamlParserError].} =
  debug("lex: byteSequence")
  var charCode = 0.int8
  for i in 0 .. 1:
    lexer.bufpos.inc()
    let
      digitPosition = int8(1 - i)
      c = lexer.buf[lexer.bufpos]
    case c
    of EndOfFile, '\l', 'r':
      lexerError(lexer, "Unfinished octet escape sequence")
    of '0' .. '9':
      charCode = charCode or (int8(c) - 0x30.int8) shl (digitPosition * 4)
    of 'A' .. 'F':
      charCode = charCode or (int8(c) - 0x37.int8) shl (digitPosition * 4)
    of 'a' .. 'f':
      charCode = charCode or (int8(c) - 0x57.int8) shl (digitPosition * 4)
    else: lexerError(lexer, "Invalid character in octet escape sequence")
  return char(charCode)

template processQuotedWhitespace(newlines: var int) {.dirty.} =
  after.setLen(0)
  block outer:
    while true:
      case p.lexer.buf[p.lexer.bufpos]
      of ' ', '\t': after.add(p.lexer.buf[p.lexer.bufpos])
      of '\l':
        p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
        break
      of '\c':
        p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
        break
      else:
        content.add(after)
        break outer
      p.lexer.bufpos.inc()
    while true:
      case p.lexer.buf[p.lexer.bufpos]
      of ' ', '\t': discard
      of '\l':
        p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
        newlines.inc()
        continue
      of '\c':
        p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
        newlines.inc()
        continue
      else:
        if newlines == 0: discard
        elif newlines == 1: content.add(' ')
        else: content.add(repeat('\l', newlines - 1))
        break
      p.lexer.bufpos.inc()

template doubleQuotedScalar(lexer: BaseLexer, content: var string) =
  debug("lex: doubleQuotedScalar")
  lexer.bufpos.inc()
  while true:
    var c = lexer.buf[lexer.bufpos]
    case c
    of EndOfFile:
      lexerError(lexer, "Unfinished double quoted string")
    of '\\':
      lexer.bufpos.inc()
      case lexer.buf[lexer.bufpos]
      of EndOfFile:
        lexerError(lexer, "Unfinished escape sequence")
      of '0':       content.add('\0')
      of 'a':       content.add('\x07')
      of 'b':       content.add('\x08')
      of '\t', 't': content.add('\t')
      of 'n':       content.add('\l')
      of 'v':       content.add('\v')
      of 'f':       content.add('\f')
      of 'r':       content.add('\c')
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
      of '\l', '\c':
        var newlines = 0
        processQuotedWhitespace(newlines)
        continue
      else: lexerError(lexer, "Illegal character in escape sequence")
    of '"':
      lexer.bufpos.inc()
      break
    of '\l', '\c', '\t', ' ':
      var newlines = 1
      processQuotedWhitespace(newlines)
      continue
    else:
      content.add(c)
    lexer.bufpos.inc()

template singleQuotedScalar(lexer: BaseLexer, content: var string) =
  debug("lex: singleQuotedScalar")
  lexer.bufpos.inc()
  while true:
    case lexer.buf[lexer.bufpos]
    of '\'':
      lexer.bufpos.inc()
      if lexer.buf[lexer.bufpos] == '\'': content.add('\'')
      else: break
    of EndOfFile: lexerError(lexer, "Unfinished single quoted string")
    of '\l', '\c', '\t', ' ':
      var newlines = 1
      processQuotedWhitespace(newlines)
      continue
    else: content.add(lexer.buf[lexer.bufpos])
    lexer.bufpos.inc()

proc isPlainSafe(lexer: BaseLexer, index: int, context: YamlContext): bool =
  case lexer.buf[lexer.bufpos + 1]
  of spaceOrLineEnd: result = false
  of flowIndicators: result = context == cBlock
  else: result = true


# tried this for performance optimization, but it didn't optimize any
# performance. keeping it around for future reference.
#const
#  plainCharOut   = {'!', '\"', '$'..'9',  ';'..'\xFF'}
#  plainCharIn    = {'!', '\"', '$'..'+', '-'..'9', ';'..'Z', '\\', '^'..'z',
#                    '|', '~'..'\xFF'}
#template isPlainChar(c: char, context: YamlContext): bool =
#  when context == cBlock: c in plainCharOut
#  else: c in plainCharIn

template plainScalar(lexer: BaseLexer, content: var string,
                     context: YamlContext) =
  debug("lex: plainScalar")
  content.add(lexer.buf[lexer.bufpos])
  block outer:
    while true:
      lexer.bufpos.inc()
      let c = lexer.buf[lexer.bufpos]
      case c
      of ' ', '\t':
        after.setLen(1)
        after[0] = c
        while true:
          lexer.bufpos.inc()
          let c2 = lexer.buf[lexer.bufpos]
          case c2
          of ' ', '\t': after.add(c2)
          of lineEnd: break outer
          of ':':
            if lexer.isPlainSafe(lexer.bufpos + 1, context):
              content.add(after & ':')
              break
            else: break outer
          of '#': break outer
          of flowIndicators:
            if context == cBlock:
              content.add(after)
              content.add(c2)
              break
            else: break outer
          else:
            content.add(after)
            content.add(c2)
            break
      of flowIndicators:
        when context == cFlow: break
        else: content.add(c)
      of lineEnd: break
      of ':':
        if lexer.isPlainSafe(lexer.bufpos + 1, context): content.add(':')
        else: break outer
      else: content.add(c)
  debug("lex: \"" & content & '\"')

template continueMultilineScalar() {.dirty.} =
  content.add(if newlines == 1: " " else: repeat('\l', newlines - 1))
  startToken()
  p.lexer.plainScalar(content, cBlock)
  state = fpBlockAfterPlainScalar

template handleFlowPlainScalar() {.dirty.} =
  content.setLen(0)
  startToken()
  p.lexer.plainScalar(content, cFlow)
  if p.lexer.buf[p.lexer.bufpos] in {'{', '}', '[', ']', ',', ':', '#'}:
    discard
  else:
    var newlines = 0
    while true:
      case p.lexer.buf[p.lexer.bufpos]
      of ':':
        if p.lexer.isPlainSafe(p.lexer.bufpos + 1, cFlow):
          if newlines == 1:
            content.add(' ')
            newlines = 0
          elif newlines > 1:
            content.add(repeat(' ', newlines - 1))
            newlines = 0
          p.lexer.plainScalar(content, cFlow)
        break
      of '#', EndOfFile: break
      of '\l':
        p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
        newlines.inc()
      of '\c':
        p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
        newlines.inc()
      of flowIndicators: break
      of ' ', '\t': p.lexer.skipWhitespace()
      else:
        if newlines == 1:
          content.add(' ')
          newlines = 0
        elif newlines > 1:
          content.add(repeat(' ', newlines - 1))
          newlines = 0
        p.lexer.plainScalar(content, cFlow)
  yieldShallowScalar(content)
  handleObjectEnd(fpFlowAfterObject)

template ensureCorrectIndentation() {.dirty.} =
  if level.indentation != indentation:
    startToken()
    parserError("Invalid indentation: " & $indentation &
                " (expected indentation of " & $level.indentation & ")")

template tagHandle(lexer: var BaseLexer, content: var string,
                   shorthandEnd: var int) =
  debug("lex: tagHandle")
  shorthandEnd = 0
  content.add(lexer.buf[lexer.bufpos])
  var i = 0
  while true:
    lexer.bufpos.inc()
    i.inc()
    let c = lexer.buf[lexer.bufpos]
    case c
    of spaceOrLineEnd:
      if shorthandEnd == -1: lexerError(lexer, "Unclosed verbatim tag")
      break
    of '!':
      if shorthandEnd == -1 and i == 2:
        content.add(c)
        continue
      elif shorthandEnd != 0:
        lexerError(lexer, "Illegal character in tag suffix")
      shorthandEnd = i
      content.add(c)
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@', '&',
       '-', '=', '+', '$', '_', '.', '~', '*', '\'', '(', ')':
      content.add(c)
    of ',':
      if shortHandEnd > 0: break # ',' after shorthand is flow indicator
      content.add(c)
    of '<':
      if i == 1:
        shorthandEnd = -1
        content.setLen(0)
      else: lexerError(lexer, "Illegal character in tag handle")
    of '>':
      if shorthandEnd == -1:
        lexer.bufpos.inc()
        if lexer.buf[lexer.bufpos] notin spaceOrLineEnd:
          lexerError(lexer, "Missing space after verbatim tag handle")
        break
      else: lexerError(lexer, "Illegal character in tag handle")
    of '%':
      if shorthandEnd != 0: content.add(lexer.byteSequence())
      else: lexerError(lexer, "Illegal character in tag handle")
    else: lexerError(lexer, "Illegal character in tag handle")

template anchorName(lexer: BaseLexer, content: var string) =
  debug("lex: anchorName")
  while true:
    lexer.bufpos.inc()
    let c = lexer.buf[lexer.bufpos]
    case c
    of spaceOrLineEnd, '[', ']', '{', '}', ',': break
    else: content.add(c)

template blockScalar(lexer: BaseLexer, content: var string,
                     stateAfter: var FastParseState) =
  debug("lex: blockScalar")
  type ChompType = enum
    ctKeep, ctClip, ctStrip
  var
    literal: bool
    blockIndent = 0
    chomp: ChompType = ctClip
    detectedIndent = false
    recentLineMoreIndented = false
  let parentIndent = ancestry[ancestry.high].indentation
  assert(parentIndent != Unknownindentation,
         "parent " & $ancestry[ancestry.high].kind & " has unknown indentation")
  
  case lexer.buf[lexer.bufpos]
  of '|': literal = true
  of '>': literal = false
  else: debugFail()
  
  while true:
    lexer.bufpos.inc()
    case lexer.buf[lexer.bufpos]
    of '+':
      if chomp != ctClip:
        lexerError(lexer, "Only one chomping indicator is allowed")
      chomp = ctKeep
    of '-':
      if chomp != ctClip:
        lexerError(lexer, "Only one chomping indicator is allowed")
      chomp = ctStrip
    of '1'..'9':
      if detectedIndent:
        lexerError(lexer, "Only one indentation indicator is allowed")
      blockIndent = int(lexer.buf[lexer.bufpos]) - int('\x30')
      detectedIndent = true
    of spaceOrLineEnd: break
    else: lexerError(lexer, "Illegal character in block scalar header: '" &
                     lexer.buf[lexer.bufpos] & "'")
  lexer.lineEnding()
  case lexer.buf[lexer.bufpos]
  of '\l': lexer.bufpos = lexer.handleLF(lexer.bufpos)
  of '\c': lexer.bufpos = lexer.handleCR(lexer.bufpos)
  of EndOfFile:
    lexerError(lexer, "Missing content of block scalar")
        # TODO: is this correct?
  else: debugFail()
  var newlines = 0
  content.setLen(0)
  block outer:
    while true:
      block inner:
        for i in countup(1, parentIndent + 1):
          case lexer.buf[lexer.bufpos]
          of ' ': discard
          of '\l':
            lexer.bufpos = lexer.handleLF(lexer.bufpos)
            newlines.inc()
            break inner
          of '\c':
            lexer.bufpos = lexer.handleCR(lexer.bufpos)
            newlines.inc()
            break inner
          else:
            stateAfter = fpBlockObjectStart
            break outer
          lexer.bufpos.inc()
        if parentIndent == -1 and lexer.buf[lexer.bufpos] == '.':
          var isDocumentEnd: bool
          startToken()
          lexer.documentEndMarker(isDocumentEnd)
          if isDocumentEnd:
            stateAfter = fpExpectDocEnd
            break outer
        if detectedIndent:
          for i in countup(1, blockIndent - 1 + max(0, -parentIndent)):
            case lexer.buf[lexer.bufpos]
            of ' ': discard
            of '\l':
              lexer.bufpos = lexer.handleLF(lexer.bufpos)
              newlines.inc()
              break inner
            of '\c':
              lexer.bufpos = lexer.handleCR(lexer.bufpos)
              newlines.inc()
              break inner
            of EndOfFile:
              stateAfter = fpBlockObjectStart
              break outer
            of '#':
              lexer.lineEnding()
              case lexer.buf[lexer.bufpos]
              of '\l': lexer.bufpos = lexer.handleLF(lexer.bufpos)
              of '\c': lexer.bufpos = lexer.handleCR(lexer.bufpos)
              else: discard
              stateAfter = fpBlockObjectStart
              break outer
            else:
              startToken()
              parserError("The text is less indented than expected ")
            lexer.bufpos.inc()
        else:
          while true:
            case lexer.buf[lexer.bufpos]
            of ' ': discard
            of '\l':
              lexer.bufpos = lexer.handleLF(lexer.bufpos)
              newlines.inc()
              break inner
            of '\c':
              lexer.bufpos = lexer.handleCR(lexer.bufpos)
              newlines.inc()
              break inner
            of EndOfFile:
              stateAfter = fpBlockObjectStart
              break outer
            else:
              blockIndent =
                  lexer.getColNumber(lexer.bufpos) - max(0, parentIndent)
              if blockIndent == 0 and parentIndent >= 0:
                stateAfter = fpBlockObjectStart
                break outer
              detectedIndent = true
              break
            lexer.bufpos.inc()
        case lexer.buf[lexer.bufpos]
        of '\l':
          lexer.bufpos = lexer.handleLF(lexer.bufpos)
          newlines.inc()
          break inner
        of '\c':
          lexer.bufpos = lexer.handleCR(lexer.bufpos)
          newlines.inc()
          break inner
        of EndOfFile:
          stateAfter = fpBlockObjectStart
          break outer
        of ' ', '\t':
          if not literal:
            if content.len > 0:
              recentLineMoreIndented = true
              newlines.inc()
        else:
          if not literal:
            if recentLineMoreIndented:
              recentLineMoreIndented = false
              newlines.inc()
        if newlines > 0:
          if literal: content.add(repeat('\l', newlines))
          elif newlines == 1:
            if content.len == 0: content.add('\l')
            else: content.add(' ')
          else:
            if content.len == 0: content.add(repeat('\l', newlines))
            else: content.add(repeat('\l', newlines - 1))
          newlines = 0
        while true:
          let c = lexer.buf[lexer.bufpos]
          case c
          of '\l':
            lexer.bufpos = lexer.handleLF(lexer.bufpos)
            newlines.inc()
            break
          of '\c':
            lexer.bufpos = lexer.handleCR(lexer.bufpos)
            newlines.inc()
            break inner
          of EndOfFile:
            stateAfter = fpBlockObjectStart
            break outer
          else: content.add(c)
          lexer.bufpos.inc()
  case chomp
  of ctClip:
    if content.len > 0: content.add('\l')
  of ctKeep: 
    if content.len > 0: content.add(repeat('\l', newlines))
    else: content.add(repeat('\l', newlines - 1))
  of ctStrip: discard
  debug("lex: \"" & content & '\"')

template consumeLineIfEmpty(lex: BaseLexer): bool =
  var result = true
  while true:
    lex.bufpos.inc()
    case lex.buf[lex.bufpos]
    of ' ', '\t': discard
    of '\l':
      lex.bufpos = lex.handleLF(lex.bufpos)
      break
    of '\c':
      lex.bufpos = lex.handleCR(lex.bufpos)
      break
    of '#', EndOfFile:
      lex.lineEnding()
      handleLineEnd(false)
      break
    else:
      result = false
      break
  result

proc parse*(p: YamlParser, s: Stream): YamlStream =
  var backend = iterator(): YamlStreamEvent =
    var
      state = fpInitial
      shorthands: Table[string, string]
      anchors: Table[string, AnchorId]
      nextAnchorId: AnchorId
      content: string = ""
      after: string = ""
      tagUri: string = ""
      tag: TagId
      anchor: AnchorId
      ancestry = newSeq[FastParseLevel]()
      level: FastParseLevel
      indentation: int
      newlines: int
      flowdepth: int = 0
      explicitFlowKey: bool
    
    p.lexer.open(s)
    initDocValues()
    
    while true:
      case state
      of fpInitial:
        debug("state: initial")
        case p.lexer.buf[p.lexer.bufpos]
        of '%':
          var ld: LexedDirective
          startToken()
          p.lexer.directiveName(ld)
          case ld
          of ldYaml:
            var version = ""
            startToken()
            p.lexer.yamlVersion(version)
            if version != "1.2":
              if p.callback != nil:
                  p.callback(p.lexer.lineNumber, p.getColNumber(),
                             p.getLineContent(),
                             "Version is not 1.2, but " & version)
              discard
            p.lexer.lineEnding()
            handleLineEnd(false)
          of ldTag:
            var shorthand = ""
            tagUri.setLen(0)
            startToken()
            p.lexer.tagShorthand(shorthand)
            p.lexer.tagUriMapping(tagUri)
            shorthands[shorthand] = tagUri
            p.lexer.lineEnding()
            handleLineEnd(false)
          of ldUnknown:
            if p.callback != nil:
                p.callback(p.lexer.lineNumber, p.getColNumber(),
                           p.getLineContent(), "Unknown directive")
            p.lexer.finishLine()
            handleLineEnd(false)
        of ' ', '\t':
          if not p.lexer.consumeLineIfEmpty():
            indentation = p.lexer.getColNumber(p.lexer.bufpos)
            yield startDocEvent()
            state = fpBlockObjectStart
        of '\l': p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
        of '\c': p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
        of EndOfFile: return
        of '#':
          p.lexer.lineEnding()
          handleLineEnd(false)
        of '-':
          var success: bool
          startToken()
          p.lexer.directivesEndMarker(success)
          yield startDocEvent()
          if success:
            p.lexer.bufpos.inc(3)
          state = fpBlockObjectStart
        else:
          yield startDocEvent()
          state = fpBlockObjectStart
      of fpBlockAfterPlainScalar:
        debug("state: blockAfterPlainScalar")
        p.lexer.skipWhitespace()
        case p.lexer.buf[p.lexer.bufpos]
        of '\l':
          if level.kind notin {fplUnknown, fplScalar}:
            startToken()
            parserError("Unexpected scalar")
          newlines = 1
          level.kind = fplScalar
          p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
          state = fpBlockObjectStart
        of '\c':
          if level.kind notin {fplUnknown, fplScalar}:
            startToken()
            parserError("Unexpected scalar")
          newlines = 1
          level.kind = fplScalar
          p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
          state = fpBlockObjectStart
        else:
          yieldShallowScalar(content)
          handleObjectEnd(fpBlockAfterObject)
      of fpBlockAfterObject:
        debug("state: blockAfterObject")
        p.lexer.skipWhitespace()
        case p.lexer.buf[p.lexer.bufpos]
        of EndOfFile:
          closeEverything()
          break
        of '\l':
          state = fpBlockObjectStart
          p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
        of '\c':
          state = fpBlockObjectStart
          p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
        of ':':
          case level.kind
          of fplUnknown:
            handleObjectStart(yamlStartMap)
          of fplMapKey:
            yield scalarEvent("", yTagQuestionMark, yAnchorNone)
            level.kind = fplMapValue
            ancestry.add(level)
            level = initLevel(fplUnknown)
          of fplMapValue:
            level.kind = fplMapValue
            ancestry.add(level)
            level = initLevel(fplUnknown)
          of fplSequence:
            startToken()
            parserError("Illegal token (expected sequence item)")
          of fplScalar:
            startToken()
            parserError("Multiline scalars may not be implicit map keys")
          of fplSinglePairKey, fplSinglePairValue, fplDocument: debugFail()
          p.lexer.bufpos.inc()
          p.lexer.skipWhitespace()
          indentation = p.lexer.getColNumber(p.lexer.bufpos)
          state = fpBlockObjectStart
        of '#':
          p.lexer.lineEnding()
          handleLineEnd(true)
          state = fpBlockObjectStart
        else:
          startToken()
          parserError("Illegal token (expected ':', comment or line end)")
      of fpBlockObjectStart:
        debug("state: blockObjectStart")
        p.lexer.skipIndentation()
        indentation = p.lexer.getColNumber(p.lexer.bufpos)
        if indentation == 0:
          var success: bool
          p.lexer.directivesEndMarker(success)
          if success:
            p.lexer.bufpos.inc(3)
            closeEverything()
            initDocValues()
            yield startDocEvent()
            continue
          p.lexer.documentEndMarker(success)
          if success:
            closeEverything()
            p.lexer.bufpos.inc(3)
            p.lexer.lineEnding()
            handleLineEnd(false)
            state = fpAfterDocument
            continue
        case p.lexer.buf[p.lexer.bufpos]
        of '\l':
          p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
          if level.kind == fplUnknown: level.indentation = UnknownIndentation
          newlines.inc()
        of '\c':
          p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
          if level.kind == fplUnknown: level.indentation = UnknownIndentation
          newlines.inc()
        of EndOfFile:
          closeEverything()
          return
        of '#':
          p.lexer.lineEnding()
          handleLineEnd(true)
          if level.kind == fplUnknown: level.indentation = UnknownIndentation
        of '\'':
          closeMoreIndentedLevels()
          handleBlockItemStart()
          content.setLen(0)
          startToken()
          p.lexer.singleQuotedScalar(content)
          if tag == yTagQuestionMark: tag = yTagExclamationMark
          yieldShallowScalar(content)
          handleObjectEnd(fpBlockAfterObject)
        of '"':
          closeMoreIndentedLevels()
          handleBlockItemStart()
          content.setLen(0)
          startToken()
          p.lexer.doubleQuotedScalar(content)
          if tag == yTagQuestionMark: tag = yTagExclamationMark
          yieldShallowScalar(content)
          handleObjectEnd(fpBlockAfterObject)
        of '|', '>':
          closeMoreIndentedLevels()
          # TODO: this will scan for possible map start, which is not
          # neccessary in this case
          handleBlockItemStart()
          var stateAfter: FastParseState
          content.setLen(0)
          p.lexer.blockScalar(content, stateAfter)
          if tag == yTagQuestionMark: tag = yTagExclamationMark
          yieldShallowScalar(content)
          handleObjectEnd(stateAfter)
          if stateAfter == fpBlockObjectStart and
              p.lexer.buf[p.lexer.bufpos] != '#':
            indentation = p.lexer.getColNumber(p.lexer.bufpos)
            closeMoreIndentedLevels()
        of '-':
          if p.lexer.isPlainSafe(p.lexer.bufpos + 1, cBlock):
            closeMoreIndentedLevels()
            if level.kind == fplScalar: continueMultilineScalar()
            else:
              handleBlockItemStart()
              content.setLen(0)
              startToken()
              p.lexer.plainScalar(content, cBlock)
              state = fpBlockAfterPlainScalar
          else:
            closeMoreIndentedLevels(true)
            p.lexer.bufpos.inc()
            handleBlockSequenceIndicator()
        of '!':
          closeMoreIndentedLevels()
          handleBlockItemStart()
          handleTagHandle()
        of '&':
          closeMoreIndentedLevels()
          handleBlockItemStart()
          handleAnchor()
        of '*':
          closeMoreIndentedLevels()
          handleBlockItemStart()
          handleAlias()
        of '[', '{':
          closeMoreIndentedLevels()
          handleBlockItemStart()
          state = fpFlow
        of '?':
          closeMoreIndentedLevels()
          if p.lexer.isPlainSafe(p.lexer.bufpos + 1, cBlock):
            if level.kind == fplScalar: continueMultilineScalar()
            else:
              handleBlockItemStart()
              content.setLen(0)
              startToken()
              p.lexer.plainScalar(content, cBlock)
              state = fpBlockAfterPlainScalar
          else:
            p.lexer.bufpos.inc()
            handleMapKeyIndicator()
        of ':':
          closeMoreIndentedLevels()
          if p.lexer.isPlainSafe(p.lexer.bufpos + 1, cBlock):
            if level.kind == fplScalar: continueMultilineScalar()
            else:
              handleBlockItemStart()
              content.setLen(0)
              startToken()
              p.lexer.plainScalar(content, cBlock)
              state = fpBlockAfterPlainScalar
          else:
            p.lexer.bufpos.inc()
            handleMapValueIndicator()
        of '@', '`':
          lexerError(p.lexer, "Reserved characters cannot start a plain scalar")
        of '\t':
          closeMoreIndentedLevels()
          if level.kind == fplScalar:
            p.lexer.skipWhitespace()
            continueMultilineScalar()
          else: lexerError(p.lexer, "\\t cannot start any token")
        else:
          closeMoreIndentedLevels()
          if level.kind == fplScalar: continueMultilineScalar()
          else:
            handleBlockItemStart()
            content.setLen(0)
            startToken()
            p.lexer.plainScalar(content, cBlock)
            state = fpBlockAfterPlainScalar
      of fpExpectDocEnd:
        debug("state: expectDocEnd")
        case p.lexer.buf[p.lexer.bufpos]
        of '-':
          var success: bool
          p.lexer.directivesEndMarker(success)
          if success:
            p.lexer.bufpos.inc(3)
            yield endDocEvent()
            discard ancestry.pop()
            initDocValues()
            yield startDocEvent()
            state = fpBlockObjectStart
          else: parserError("Unexpected content (expected document end)")
        of '.':
          var isDocumentEnd: bool
          startToken()
          p.lexer.documentEndMarker(isDocumentEnd)
          if isDocumentEnd:
            closeEverything()
            p.lexer.bufpos.inc(3)
            p.lexer.lineEnding()
            handleLineEnd(false)
            state = fpAfterDocument
          else: parserError("Unexpected content (expected document end)")
        of ' ', '\t', '#':
          p.lexer.lineEnding()
          handleLineEnd(true)
        of '\l': p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
        of '\c': p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
        of EndOfFile:
          yield endDocEvent()
          break
        else:
          startToken()
          parserError("Unexpected content (expected document end)")
      of fpAfterDocument:
        debug("state: afterDocument")
        case p.lexer.buf[p.lexer.bufpos]
        of '.':
          var isDocumentEnd: bool
          startToken()
          p.lexer.documentEndMarker(isDocumentEnd)
          if isDocumentEnd:
            p.lexer.bufpos.inc(3)
            p.lexer.lineEnding()
            handleLineEnd(false)
          else:
            initDocValues()
            yield startDocEvent()
            state = fpBlockObjectStart
        of '#':
          p.lexer.lineEnding()
          handleLineEnd(false)
        of '\t', ' ':
          if not p.lexer.consumeLineIfEmpty():
            indentation = p.lexer.getColNumber(p.lexer.bufpos)
            initDocValues()
            yield startDocEvent()
            state = fpBlockObjectStart
        of EndOfFile: break
        else:
          initDocValues()
          state = fpInitial
      of fpFlow:
        debug("state: flow")
        p.lexer.skipWhitespaceCommentsAndNewlines()
        case p.lexer.buf[p.lexer.bufpos]
        of '{':
          handleFlowItemStart()
          handleObjectStart(yamlStartMap)
          flowdepth.inc()
          p.lexer.bufpos.inc()
          explicitFlowKey = false
        of '[':
          handleFlowItemStart()
          handleObjectStart(yamlStartSeq)
          flowdepth.inc()
          p.lexer.bufpos.inc()
        of '}':
          assert(level.kind == fplUnknown)
          level = ancestry.pop()
          case level.kind
          of fplMapValue:
            yieldEmptyScalar()
            level.kind = fplMapKey
          of fplMapKey:
            if tag != yTagQuestionMark or anchor != yAnchorNone or
                explicitFlowKey:
              yieldEmptyScalar()
              yield scalarEvent("", yTagQuestionMark, yAnchorNone)
          of fplSequence:
            startToken()
            parserError("Unexpected token (expected ']')")
          of fplSinglePairValue:
            startToken()
            parserError("Unexpected token (expected ']')")
          of fplUnknown, fplScalar, fplSinglePairKey, fplDocument: debugFail()
          p.lexer.bufpos.inc()
          leaveFlowLevel()
        of ']':
          assert(level.kind == fplUnknown)
          level = ancestry.pop()
          case level.kind
          of fplSequence:
            if tag != yTagQuestionMark or anchor != yAnchorNone:
              yieldEmptyScalar()
          of fplSinglePairValue:
            yieldEmptyScalar()
            level = ancestry.pop()
            yield endMapEvent()
            assert(level.kind == fplSequence)
          of fplMapKey, fplMapValue:
            startToken()
            parserError("Unexpected token (expected '}')")
          of fplUnknown, fplScalar, fplSinglePairKey, fplDocument: debugFail()
          p.lexer.bufpos.inc()
          leaveFlowLevel()
        of ',':
          assert(level.kind == fplUnknown)
          level = ancestry.pop()
          case level.kind
          of fplSequence: yieldEmptyScalar()
          of fplMapValue:
            yieldEmptyScalar()
            level.kind = fplMapKey
            explicitFlowKey = false
          of fplMapKey:
            yieldEmptyScalar
            yield scalarEvent("", yTagQuestionMark, yAnchorNone)
            explicitFlowKey = false
          of fplSinglePairValue:
            yieldEmptyScalar()
            level = ancestry.pop()
            yield endMapEvent()
            assert(level.kind == fplSequence)
          of fplUnknown, fplScalar, fplSinglePairKey, fplDocument: debugFail()
          ancestry.add(level)
          level = initLevel(fplUnknown)
          p.lexer.bufpos.inc()
        of ':':
          if p.lexer.isPlainSafe(p.lexer.bufpos + 1, cFlow):
            handleFlowItemStart()
            handleFlowPlainScalar()
          else:
            level = ancestry.pop()
            case level.kind
            of fplSequence:
              yield startMapEvent(tag, anchor)
              debug("started single-pair map at " &
                  (if level.indentation == UnknownIndentation:
                   $indentation else: $level.indentation))
              tag = yTagQuestionMark
              anchor = yAnchorNone
              if level.indentation == UnknownIndentation:
                level.indentation = indentation
              ancestry.add(level)
              level = initLevel(fplSinglePairValue)
              yield scalarEvent("")
            of fplMapValue, fplSinglePairValue:
              startToken()
              parserError("Unexpected token (expected ',')")
            of fplMapKey:
              yieldEmptyScalar()
              level.kind = fplMapValue
            of fplSinglePairKey:
              yieldEmptyScalar()
              level.kind = fplSinglePairValue
            of fplUnknown, fplScalar, fplDocument: debugFail()
            ancestry.add(level)
            level = initLevel(fplUnknown)
            p.lexer.bufpos.inc()
        of '\'':
          handleFlowItemStart()
          content.setLen(0)
          startToken()
          p.lexer.singleQuotedScalar(content)
          if tag == yTagQuestionMark: tag = yTagExclamationMark
          yieldShallowScalar(content)
          handleObjectEnd(fpFlowAfterObject)
        of '"':
          handleFlowItemStart()
          content.setLen(0)
          startToken()
          p.lexer.doubleQuotedScalar(content)
          if tag == yTagQuestionMark: tag = yTagExclamationMark
          yieldShallowScalar(content)
          handleObjectEnd(fpFlowAfterObject)
        of '!':
          handleFlowItemStart()
          handleTagHandle()
        of '&':
          handleFlowItemStart()
          handleAnchor()
        of '*':
          handleAlias()
          state = fpFlowAfterObject
        of '?':
          if p.lexer.isPlainSafe(p.lexer.bufpos + 1, cFlow):
            handleFlowItemStart()
            handleFlowPlainScalar()
          elif explicitFlowKey:
            startToken()
            parserError("Duplicate '?' in flow mapping")
          elif level.kind == fplUnknown:
            case ancestry[ancestry.high].kind
            of fplMapKey, fplMapValue, fplDocument: discard
            of fplSequence: handleObjectStart(yamlStartMap, true)
            else:
              startToken()
              parserError("Unexpected token")
            explicitFlowKey = true
            p.lexer.bufpos.inc()
          else:
            explicitFlowKey = true
            p.lexer.bufpos.inc()
        else:
          handleFlowItemStart()
          handleFlowPlainScalar()
      of fpFlowAfterObject:
        debug("state: flowAfterObject")
        p.lexer.skipWhitespaceCommentsAndNewlines()
        case p.lexer.buf[p.lexer.bufpos]
        of ']':
          case level.kind
          of fplSequence: discard
          of fplMapKey, fplMapValue:
            startToken()
            parserError("Unexpected token (expected '}')")
          of fplSinglePairValue:
            level = ancestry.pop()
            assert(level.kind == fplSequence)
            yield endMapEvent()
          of fplScalar, fplUnknown, fplSinglePairKey, fplDocument: debugFail()
          p.lexer.bufpos.inc()
          leaveFlowLevel()
        of '}':
          case level.kind
          of fplMapKey, fplMapValue: discard
          of fplSequence, fplSinglePairValue:
            startToken()
            parserError("Unexpected token (expected ']')")
          of fplUnknown, fplScalar, fplSinglePairKey, fplDocument: debugFail()
          p.lexer.bufpos.inc()
          leaveFlowLevel()
        of ',':
          case level.kind
          of fplSequence: discard
          of fplMapValue:
            yield scalarEvent("", yTagQuestionMark, yAnchorNone)
            level.kind = fplMapKey
            explicitFlowKey = false
          of fplSinglePairValue:
            level = ancestry.pop()
            assert(level.kind == fplSequence)
            yield endMapEvent()
          of fplMapKey: explicitFlowKey = false
          of fplUnknown, fplScalar, fplSinglePairKey, fplDocument: debugFail()
          ancestry.add(level)
          level = initLevel(fplUnknown)
          state = fpFlow
          p.lexer.bufpos.inc()
        of ':':
          case level.kind
          of fplSequence, fplMapKey:
            startToken()
            parserError("Unexpected token (expected ',')")
          of fplMapValue, fplSinglePairValue: discard
          of fplUnknown, fplScalar, fplSinglePairKey, fplDocument: debugFail()
          ancestry.add(level)
          level = initLevel(fplUnknown)
          state = fpFlow
          p.lexer.bufpos.inc()
        of '#':
          p.lexer.lineEnding()
          handleLineEnd(true)
        of EndOfFile:
          startToken()
          parserError("Unclosed flow content")
        else:
          startToken()
          parserError("Unexpected content (expected flow indicator)")
  try: result = initYamlStream(backend)
  except Exception: debugFail() # compiler error