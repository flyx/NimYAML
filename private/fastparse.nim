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
  
  ScalarType = enum
    stFlow, stLiteral, stFolded
  
  FastParseLevel = object
    kind: FastParseLevelKind
    indentation: int
  
  LexedDirective = enum
    ldYaml, ldTag, ldUnknown
    
  YamlContext = enum
    cBlock, cFlow
  
  ChompType = enum
    ctKeep, ctClip, ctStrip
  
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

proc generateError(p: YamlParser, message: string):
    ref YamlParserError {.raises: [].} =
  result = newException(YamlParserError, message)
  result.line = p.lexer.lineNumber
  result.column = p.tokenstart + 1
  result.lineContent = p.getLineContent(true)

proc generateError(lx: BaseLexer, message: string):
    ref YamlParserError {.raises: [].} =
  result = newException(YamlParserError, message)
  result.line = lx.lineNumber
  result.column = lx.bufpos + 1
  result.lineContent = lx.getCurrentLine(false) &
      repeat(' ', lx.getColNumber(lx.bufpos)) & "^\n"

proc addMultiple(s: var string, c: char, num: int) {.raises: [], inline.} =
  for i in 1..num:
    s.add(c)

proc reset(content: var string) {.raises: [], inline.} = content.setLen(0)

proc initLevel(k: FastParseLevelKind): FastParseLevel {.raises: [], inline.} =
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
    if scalarType != stFlow:
      case chomp
      of ctKeep:
        if content.len == 0: newlines.inc(-1)
        content.addMultiple('\l', newlines)
      of ctClip:
        if content.len != 0: content.add('\l')
      of ctStrip: discard
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
  p.startToken()
  case level.kind
  of fplUnknown: handleObjectStart(yamlStartSeq)
  of fplSequence:
    if level.indentation != indentation:
      raise p.generateError("Invalid indentation of block sequence indicator")
    ancestry.add(level)
    level = initLevel(fplUnknown)
  else: raise p.generateError("Illegal sequence item in map")
  p.lexer.skipWhitespace()
  indentation = p.lexer.getColNumber(p.lexer.bufpos)

template handleMapKeyIndicator() {.dirty.} =
  p.startToken()
  case level.kind
  of fplUnknown: handleObjectStart(yamlStartMap)
  of fplMapValue:
    if level.indentation != indentation:
      raise p.generateError("Invalid indentation of map key indicator")
    yield scalarEvent("", yTagQuestionMark, yAnchorNone)
    level.kind = fplMapKey
    ancestry.add(level)
    level = initLevel(fplUnknown)
  of fplMapKey:
    if level.indentation != indentation:
      raise p.generateError("Invalid indentation of map key indicator")
    ancestry.add(level)
    level = initLevel(fplUnknown)
  of fplSequence:
    raise p.generateError("Unexpected map key indicator (expected '- ')")
  of fplScalar:
    raise p.generateError(
        "Unexpected map key indicator (expected multiline scalar end)")
  of fplSinglePairKey, fplSinglePairValue, fplDocument: debugFail()
  p.lexer.skipWhitespace()
  indentation = p.lexer.getColNumber(p.lexer.bufpos)

template handleMapValueIndicator() {.dirty.} =
  p.startToken()
  case level.kind
  of fplUnknown:
    if level.indentation == UnknownIndentation:
      handleObjectStart(yamlStartMap)
      yield scalarEvent("", yTagQuestionMark, yAnchorNone)
    else: yieldEmptyScalar()
    ancestry[ancestry.high].kind = fplMapValue
  of fplMapKey:
    if level.indentation != indentation:
      raise p.generateError("Invalid indentation of map key indicator")
    yield scalarEvent("", yTagQuestionMark, yAnchorNone)
    level.kind = fplMapValue
    ancestry.add(level)
    level = initLevel(fplUnknown)
  of fplMapValue:
    if level.indentation != indentation:
      raise p.generateError("Invalid indentation of map key indicator")
    ancestry.add(level)
    level = initLevel(fplUnknown)
  of fplSequence:
    raise p.generateError("Unexpected map value indicator (expected '- ')")
  of fplScalar:
    raise p.generateError(
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
  p.startToken()
  if level.kind != fplUnknown: raise p.generateError("Unexpected tag handle")
  if tag != yTagQuestionMark:
    raise p.generateError("Only one tag handle is allowed per node")
  content.reset()
  var
    shorthandEnd: int
  p.lexer.tagHandle(content, shorthandEnd)
  if shorthandEnd != -1:
    try:
      tagUri.setLen(0)
      tagUri.add(shorthands[content[0..shorthandEnd]])
      tagUri.add(content[shorthandEnd + 1 .. ^1])
    except KeyError:
      raise p.generateError(
          "Undefined tag shorthand: " & content[0..shorthandEnd])
    try: tag = p.tagLib.tags[tagUri]
    except KeyError: tag = p.tagLib.registerUri(tagUri)
  else:
    try: tag = p.tagLib.tags[content]
    except KeyError: tag = p.tagLib.registerUri(content)

template handleAnchor() {.dirty.} =
  p.startToken()
  if level.kind != fplUnknown: raise p.generateError("Unexpected token")
  if anchor != yAnchorNone:
    raise p.generateError("Only one anchor is allowed per node")
  content.reset()
  p.lexer.anchorName(content)
  anchor = nextAnchorId
  anchors[content] = anchor
  nextAnchorId = AnchorId(int(nextAnchorId) + 1)

template handleAlias() {.dirty.} =
  p.startToken()
  if level.kind != fplUnknown: raise p.generateError("Unexpected token")
  if anchor != yAnchorNone or tag != yTagQuestionMark:
    raise p.generateError("Alias may not have anchor or tag")
  content.reset()
  p.lexer.anchorName(content)
  var id: AnchorId
  try: id = anchors[content]
  except KeyError: raise p.generateError("Unknown anchor")
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
        if pos == p.lexer.bufpos or p.lexer.buf[p.lexer.bufpos] in space:
          pos.inc()
          while p.lexer.buf[pos] notin spaceOrLineEnd:
            pos.inc()
          continue
      else: discard
      if flow and p.lexer.buf[pos] notin space:
        recentJsonStyle = p.lexer.buf[pos] in {']', '}', '\'', '"'}
      pos.inc()
    if level.indentation == UnknownIndentation: level.indentation = indentation

template handleBlockItemStart() {.dirty.} =
  case level.kind
  of fplUnknown: handlePossibleMapStart()
  of fplSequence:
    raise p.generateError(
        "Unexpected token (expected block sequence indicator)")
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

proc startToken(p: YamlParser) {.raises: [], inline.} =
  p.tokenstart = p.lexer.getColNumber(p.lexer.bufpos)

proc finishLine(lexer: var BaseLexer) {.raises: [], inline.} =
  debug("lex: finishLine")
  while lexer.buf[lexer.bufpos] notin lineEnd:
    lexer.bufpos.inc()

proc skipWhitespace(lexer: var BaseLexer) {.raises: [], inline.} =
  debug("lex: skipWhitespace")
  while lexer.buf[lexer.bufpos] in space: lexer.bufpos.inc()

# TODO: {.raises: [].}
proc skipWhitespaceCommentsAndNewlines(lexer: var BaseLexer) {.inline.} =
  debug("lex: skipWhitespaceCommentsAndNewlines")
  if lexer.buf[lexer.bufpos] != '#':
    while true:
      case lexer.buf[lexer.bufpos]
      of space: lexer.bufpos.inc()
      of '\l': lexer.bufpos = lexer.handleLF(lexer.bufpos)
      of '\c': lexer.bufpos = lexer.handleCR(lexer.bufpos)
      of '#': # also skip comments
        lexer.bufpos.inc()
        while lexer.buf[lexer.bufpos] notin lineEnd:
          lexer.bufpos.inc()
      else: break

proc skipIndentation(lexer: var BaseLexer) {.raises: [], inline.} =
  debug("lex: skipIndentation")
  while lexer.buf[lexer.bufpos] == ' ': lexer.bufpos.inc()

proc directiveName(lexer: var BaseLexer, directive: var LexedDirective)
    {.raises: [].} =
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
        if lexer.buf[lexer.bufpos] in spaceOrLineEnd:
          directive = ldTag
  while lexer.buf[lexer.bufpos] notin spaceOrLineEnd:
    lexer.bufpos.inc()

proc yamlVersion(lexer: var BaseLexer, o: var string)
    {.raises: [YamlParserError], inline.} =
  debug("lex: yamlVersion")
  while lexer.buf[lexer.bufpos] in space: lexer.bufpos.inc()
  var c = lexer.buf[lexer.bufpos]
  if c notin digits: raise lexer.generateError("Invalid YAML version number")
  o.add(c)
  lexer.bufpos.inc()
  c = lexer.buf[lexer.bufpos]
  while c in digits:
    lexer.bufpos.inc()
    o.add(c)
    c = lexer.buf[lexer.bufpos]
  if lexer.buf[lexer.bufpos] != '.':
    raise lexer.generateError("Invalid YAML version number")
  o.add('.')
  lexer.bufpos.inc()
  c = lexer.buf[lexer.bufpos]
  if c notin digits: raise lexer.generateError("Invalid YAML version number")
  o.add(c)
  lexer.bufpos.inc()
  c = lexer.buf[lexer.bufpos]
  while c in digits:
    o.add(c)
    lexer.bufpos.inc()
    c = lexer.buf[lexer.bufpos]
  if lexer.buf[lexer.bufpos] notin spaceOrLineEnd:
    raise lexer.generateError("Invalid YAML version number")

proc lineEnding(p: YamlParser) {.raises: [YamlParserError], inline.} =
  debug("lex: lineEnding")
  if p.lexer.buf[p.lexer.bufpos] notin lineEnd:
    while p.lexer.buf[p.lexer.bufpos] in space: p.lexer.bufpos.inc()
    if p.lexer.buf[p.lexer.bufpos] in lineEnd: discard
    elif p.lexer.buf[p.lexer.bufpos] == '#':
      while p.lexer.buf[p.lexer.bufpos] notin lineEnd: p.lexer.bufpos.inc()
    else:
      p.startToken()
      raise p.generateError("Unexpected token (expected comment or line end)")

proc tagShorthand(lexer: var BaseLexer, shorthand: var string) {.inline.} =
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
      else: raise lexer.generateError("Illegal character in tag shorthand")
    shorthand.add(c)
    lexer.bufpos.inc()
  if lexer.buf[lexer.bufpos] notin spaceOrLineEnd:
    raise lexer.generateError("Missing space after tag shorthand")

proc tagUriMapping(lexer: var BaseLexer, uri: var string)
    {.raises: [YamlParserError].} =
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
    else: raise lexer.generateError("Invalid tag uri")

proc directivesEndMarker(lexer: var BaseLexer, success: var bool)
    {.raises: [].} =
  debug("lex: directivesEndMarker")
  success = true
  for i in 0..2:
    if lexer.buf[lexer.bufpos + i] != '-':
      success = false
      break
  if success: success = lexer.buf[lexer.bufpos + 3] in spaceOrLineEnd

proc documentEndMarker(lexer: var BaseLexer, success: var bool) {.raises: [].} =
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
      raise lexer.generateError("Unfinished unicode escape sequence")
    of '0' .. '9':
      unicodeChar = unicodechar or (int(c) - 0x30) shl (digitPosition * 4)
    of 'A' .. 'F':
      unicodeChar = unicodechar or (int(c) - 0x37) shl (digitPosition * 4)
    of 'a' .. 'f':
      unicodeChar = unicodechar or (int(c) - 0x57) shl (digitPosition * 4)
    else:
      raise lexer.generateError(
          "Invalid character in unicode escape sequence")
  return toUTF8(Rune(unicodeChar))

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
      raise lexer.generateError("Unfinished octet escape sequence")
    of '0' .. '9':
      charCode = charCode or (int8(c) - 0x30.int8) shl (digitPosition * 4)
    of 'A' .. 'F':
      charCode = charCode or (int8(c) - 0x37.int8) shl (digitPosition * 4)
    of 'a' .. 'f':
      charCode = charCode or (int8(c) - 0x57.int8) shl (digitPosition * 4)
    else:
      raise lexer.generateError("Invalid character in octet escape sequence")
  return char(charCode)

# TODO: {.raises: [].}
proc processQuotedWhitespace(p: YamlParser, content, after: var string,
                             newlines: var int) =
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
        else: content.addMultiple('\l', newlines - 1)
        break
      p.lexer.bufpos.inc()

# TODO: {.raises: [YamlParserError].}
proc doubleQuotedScalar(p: YamlParser, content, after: var string) =
  debug("lex: doubleQuotedScalar")
  p.lexer.bufpos.inc()
  while true:
    var c = p.lexer.buf[p.lexer.bufpos]
    case c
    of EndOfFile:
      raise p.lexer.generateError("Unfinished double quoted string")
    of '\\':
      p.lexer.bufpos.inc()
      case p.lexer.buf[p.lexer.bufpos]
      of EndOfFile:
        raise p.lexer.generateError("Unfinished escape sequence")
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
      of 'x':       content.add(p.lexer.unicodeSequence(2))
      of 'u':       content.add(p.lexer.unicodeSequence(4))
      of 'U':       content.add(p.lexer.unicodeSequence(8))
      of '\l', '\c':
        var newlines = 0
        p.processQuotedWhitespace(content, after, newlines)
        continue
      else: raise p.lexer.generateError("Illegal character in escape sequence")
    of '"':
      p.lexer.bufpos.inc()
      break
    of '\l', '\c', '\t', ' ':
      var newlines = 1
      p.processQuotedWhitespace(content, after, newlines)
      continue
    else:
      content.add(c)
    p.lexer.bufpos.inc()

# TODO: {.raises: [].}
proc singleQuotedScalar(p: YamlParser, content, after: var string) =
  debug("lex: singleQuotedScalar")
  p.lexer.bufpos.inc()
  while true:
    case p.lexer.buf[p.lexer.bufpos]
    of '\'':
      p.lexer.bufpos.inc()
      if p.lexer.buf[p.lexer.bufpos] == '\'': content.add('\'')
      else: break
    of EndOfFile: raise p.lexer.generateError("Unfinished single quoted string")
    of '\l', '\c', '\t', ' ':
      var newlines = 1
      p.processQuotedWhitespace(content, after, newlines)
      continue
    else: content.add(p.lexer.buf[p.lexer.bufpos])
    p.lexer.bufpos.inc()

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

proc plainScalar(lexer: var BaseLexer, content, after: var string,
                 context: static[YamlContext]) {.raises: [].} =
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
  p.startToken()
  p.lexer.plainScalar(content, after, cBlock)
  state = fpBlockAfterPlainScalar

template handleFlowPlainScalar() {.dirty.} =
  content.reset()
  p.startToken()
  p.lexer.plainScalar(content, after, cFlow)
  if p.lexer.buf[p.lexer.bufpos] in {'{', '}', '[', ']', ',', ':', '#'}:
    discard
  else:
    newlines = 0
    while true:
      case p.lexer.buf[p.lexer.bufpos]
      of ':':
        if p.lexer.isPlainSafe(p.lexer.bufpos + 1, cFlow):
          if newlines == 1:
            content.add(' ')
            newlines = 0
          elif newlines > 1:
            content.addMultiple(' ', newlines - 1)
            newlines = 0
          p.lexer.plainScalar(content, after, cFlow)
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
          content.addMultiple(' ', newlines - 1)
          newlines = 0
        p.lexer.plainScalar(content, after, cFlow)
  yieldShallowScalar(content)
  handleObjectEnd(fpFlowAfterObject)

proc tagHandle(lexer: var BaseLexer, content: var string,
                shorthandEnd: var int) {.raises: [YamlParserError].} =
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
      if shorthandEnd == -1: raise lexer.generateError("Unclosed verbatim tag")
      break
    of '!':
      if shorthandEnd == -1 and i == 2:
        content.add(c)
        continue
      elif shorthandEnd != 0:
        raise lexer.generateError("Illegal character in tag suffix")
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
        content.reset()
      else: raise lexer.generateError("Illegal character in tag handle")
    of '>':
      if shorthandEnd == -1:
        lexer.bufpos.inc()
        if lexer.buf[lexer.bufpos] notin spaceOrLineEnd:
          raise lexer.generateError("Missing space after verbatim tag handle")
        break
      else: raise lexer.generateError("Illegal character in tag handle")
    of '%':
      if shorthandEnd != 0: content.add(lexer.byteSequence())
      else: raise lexer.generateError("Illegal character in tag handle")
    else: raise lexer.generateError("Illegal character in tag handle")

proc anchorName(lexer: var BaseLexer, content: var string) {.raises: [].} =
  debug("lex: anchorName")
  while true:
    lexer.bufpos.inc()
    let c = lexer.buf[lexer.bufpos]
    case c
    of spaceOrLineEnd, '[', ']', '{', '}', ',': break
    else: content.add(c)

proc consumeLineIfEmpty(p: YamlParser, newlines: var int): bool =
  result = true
  while true:
    p.lexer.bufpos.inc()
    case p.lexer.buf[p.lexer.bufpos]
    of ' ', '\t': discard
    of '\l':
      p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
      break
    of '\c':
      p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
      break
    of '#', EndOfFile:
      p.lineEnding()
      handleLineEnd(false)
      break
    else:
      result = false
      break

template startScalar(t: ScalarType) {.dirty.} =
  newlines = 0
  level.kind = fplScalar
  scalarType = t

template blockScalarHeader() {.dirty.} =
  debug("lex: blockScalarHeader")
  chomp = ctClip
  level.indentation = UnknownIndentation
  if tag == yTagQuestionMark: tag = yTagExclamationMark
  let t = if p.lexer.buf[p.lexer.bufpos] == '|': stLiteral else: stFolded
  while true:
    p.lexer.bufpos.inc()
    case p.lexer.buf[p.lexer.bufpos]
    of '+':
      if chomp != ctClip:
        raise p.lexer.generateError("Only one chomping indicator is allowed")
      chomp = ctKeep
    of '-':
      if chomp != ctClip:
        raise p.lexer.generateError("Only one chomping indicator is allowed")
      chomp = ctStrip
    of '1'..'9':
      if level.indentation != UnknownIndentation:
        raise p.lexer.generateError("Only one indentation indicator is allowed")
      level.indentation = ancestry[ancestry.high].indentation +
          ord(p.lexer.buf[p.lexer.bufpos]) - ord('\x30')
    of spaceOrLineEnd: break
    else:
      raise p.lexer.generateError(
          "Illegal character in block scalar header: '" &
          p.lexer.buf[p.lexer.bufpos] & "'")
  recentWasMoreIndented = false
  p.lineEnding()
  handleLineEnd(true)
  startScalar(t)
  content.reset()

template blockScalarLine() {.dirty.} =
  debug("lex: blockScalarLine")
  if indentation < level.indentation:
    if p.lexer.buf[p.lexer.bufpos] == '#':
      # skip all following comment lines
      while indentation > ancestry[ancestry.high].indentation:
        p.lineEnding()
        handleLineEnd(true)
        newlines.inc(-1)
        p.lexer.skipIndentation()
        indentation = p.lexer.getColNumber(p.lexer.bufpos)
      if indentation > ancestry[ancestry.high].indentation:
        raise p.lexer.generateError(
            "Invalid content in block scalar after comments")
      closeMoreIndentedLevels()
    else:
      raise p.lexer.generateError(
          "Invalid indentation (expected indentation of at least " &
          $level.indentation & " spaces)")    
  else:
    if level.indentation == UnknownIndentation:
      if p.lexer.buf[p.lexer.bufpos] in lineEnd:
        handleLineEnd(true)
        continue
      else:
        level.indentation = indentation
        content.addMultiple('\l', newlines)
    elif indentation > level.indentation or p.lexer.buf[p.lexer.bufpos] == '\t':
      content.addMultiple('\l', newlines)
      recentWasMoreIndented = true
      content.addMultiple(' ', indentation - level.indentation)
    elif scalarType == stFolded:
      if recentWasMoreIndented:
        recentWasMoreIndented = false
        newlines.inc()
      if newlines == 0: discard
      elif newlines == 1: content.add(' ')
      else: content.addMultiple('\l', newlines - 1)    
    else: content.addMultiple('\l', newlines)
    newlines = 0
    while p.lexer.buf[p.lexer.bufpos] notin lineEnd:
      content.add(p.lexer.buf[p.lexer.bufpos])
      p.lexer.bufpos.inc()
    handleLineEnd(true)

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
      scalarType: ScalarType
      recentWasMoreIndented: bool
      chomp: ChompType
    
    p.lexer.open(s)
    initDocValues()
    
    while true:
      case state
      of fpInitial:
        debug("state: initial")
        case p.lexer.buf[p.lexer.bufpos]
        of '%':
          var ld: LexedDirective
          p.startToken()
          p.lexer.directiveName(ld)
          case ld
          of ldYaml:
            var version = ""
            p.startToken()
            p.lexer.yamlVersion(version)
            if version != "1.2":
              if p.callback != nil:
                  p.callback(p.lexer.lineNumber, p.getColNumber(),
                             p.getLineContent(),
                             "Version is not 1.2, but " & version)
              discard
            p.lineEnding()
            handleLineEnd(false)
          of ldTag:
            var shorthand = ""
            tagUri.setLen(0)
            p.startToken()
            p.lexer.tagShorthand(shorthand)
            p.lexer.tagUriMapping(tagUri)
            shorthands[shorthand] = tagUri
            p.lineEnding()
            handleLineEnd(false)
          of ldUnknown:
            if p.callback != nil:
                p.callback(p.lexer.lineNumber, p.getColNumber(),
                           p.getLineContent(), "Unknown directive")
            p.lexer.finishLine()
            handleLineEnd(false)
        of ' ', '\t':
          if not p.consumeLineIfEmpty(newlines):
            indentation = p.lexer.getColNumber(p.lexer.bufpos)
            yield startDocEvent()
            state = fpBlockObjectStart
        of '\l': p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
        of '\c': p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
        of EndOfFile: return
        of '#':
          p.lineEnding()
          handleLineEnd(false)
        of '-':
          var success: bool
          p.startToken()
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
            p.startToken()
            raise p.generateError("Unexpected scalar")
          startScalar(stFlow)
          p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
          newlines.inc()
          state = fpBlockObjectStart
        of '\c':
          if level.kind notin {fplUnknown, fplScalar}:
            p.startToken()
            raise p.generateError("Unexpected scalar")
          startScalar(stFlow)
          p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
          newlines.inc()
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
            p.startToken()
            raise p.generateError("Illegal token (expected sequence item)")
          of fplScalar:
            p.startToken()
            raise p.generateError(
                "Multiline scalars may not be implicit map keys")
          of fplSinglePairKey, fplSinglePairValue, fplDocument: debugFail()
          p.lexer.bufpos.inc()
          p.lexer.skipWhitespace()
          indentation = p.lexer.getColNumber(p.lexer.bufpos)
          state = fpBlockObjectStart
        of '#':
          p.lineEnding()
          handleLineEnd(true)
          state = fpBlockObjectStart
        else:
          p.startToken()
          raise p.generateError(
              "Illegal token (expected ':', comment or line end)")
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
            p.lineEnding()
            handleLineEnd(false)
            state = fpAfterDocument
            continue
        if indentation <= ancestry[ancestry.high].indentation:
          if p.lexer.buf[p.lexer.bufpos] in lineEnd:
            handleLineEnd(true)
            continue
          elif p.lexer.buf[p.lexer.bufpos] == '#':
            p.lineEnding()
            handleLineEnd(true)
            continue
          elif p.lexer.buf[p.lexer.bufpos] == '-' and not
              p.lexer.isPlainSafe(p.lexer.bufpos + 1, cBlock):
            closeMoreIndentedLevels(true)
          else: closeMoreIndentedLevels()
        elif indentation <= level.indentation and
            p.lexer.buf[p.lexer.bufpos] in lineEnd:
          handleLineEnd(true)
          continue
        if level.kind == fplScalar and scalarType != stFlow:
          blockScalarLine()
          continue
        case p.lexer.buf[p.lexer.bufpos]
        of '\l':
          p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
          newlines.inc()
          if level.kind == fplUnknown: level.indentation = UnknownIndentation
        of '\c':
          p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
          newlines.inc()
          if level.kind == fplUnknown: level.indentation = UnknownIndentation
        of EndOfFile:
          closeEverything()
          return
        of '#':
          p.lineEnding()
          handleLineEnd(true)
          if level.kind == fplUnknown: level.indentation = UnknownIndentation
        of '\'':
          handleBlockItemStart()
          content.reset()
          p.startToken()
          p.singleQuotedScalar(content, after)
          if tag == yTagQuestionMark: tag = yTagExclamationMark
          yieldShallowScalar(content)
          handleObjectEnd(fpBlockAfterObject)
        of '"':
          handleBlockItemStart()
          content.reset()
          p.startToken()
          p.doubleQuotedScalar(content, after)
          if tag == yTagQuestionMark: tag = yTagExclamationMark
          yieldShallowScalar(content)
          handleObjectEnd(fpBlockAfterObject)
        of '|', '>':
          blockScalarHeader()
          continue
        of '-':
          if p.lexer.isPlainSafe(p.lexer.bufpos + 1, cBlock):
            if level.kind == fplScalar: continueMultilineScalar()
            else:
              handleBlockItemStart()
              content.reset()
              p.startToken()
              p.lexer.plainScalar(content, after, cBlock)
              state = fpBlockAfterPlainScalar
          else:
            p.lexer.bufpos.inc()
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
          if p.lexer.isPlainSafe(p.lexer.bufpos + 1, cBlock):
            if level.kind == fplScalar: continueMultilineScalar()
            else:
              handleBlockItemStart()
              content.reset()
              p.startToken()
              p.lexer.plainScalar(content, after, cBlock)
              state = fpBlockAfterPlainScalar
          else:
            p.lexer.bufpos.inc()
            handleMapKeyIndicator()
        of ':':
          if p.lexer.isPlainSafe(p.lexer.bufpos + 1, cBlock):
            if level.kind == fplScalar: continueMultilineScalar()
            else:
              handleBlockItemStart()
              content.reset()
              p.startToken()
              p.lexer.plainScalar(content, after, cBlock)
              state = fpBlockAfterPlainScalar
          else:
            p.lexer.bufpos.inc()
            handleMapValueIndicator()
        of '@', '`':
          raise p.lexer.generateError(
              "Reserved characters cannot start a plain scalar")
        of '\t':
          if level.kind == fplScalar:
            p.lexer.skipWhitespace()
            continueMultilineScalar()
          else: raise p.lexer.generateError("\\t cannot start any token")
        else:
          if level.kind == fplScalar: continueMultilineScalar()
          else:
            handleBlockItemStart()
            content.reset()
            p.startToken()
            p.lexer.plainScalar(content, after, cBlock)
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
          else:
            raise p.generateError("Unexpected content (expected document end)")
        of '.':
          var isDocumentEnd: bool
          p.startToken()
          p.lexer.documentEndMarker(isDocumentEnd)
          if isDocumentEnd:
            closeEverything()
            p.lexer.bufpos.inc(3)
            p.lineEnding()
            handleLineEnd(false)
            state = fpAfterDocument
          else:
            raise p.generateError("Unexpected content (expected document end)")
        of ' ', '\t', '#':
          p.lineEnding()
          handleLineEnd(true)
        of '\l': p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
        of '\c': p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
        of EndOfFile:
          yield endDocEvent()
          break
        else:
          p.startToken()
          raise p.generateError("Unexpected content (expected document end)")
      of fpAfterDocument:
        debug("state: afterDocument")
        case p.lexer.buf[p.lexer.bufpos]
        of '.':
          var isDocumentEnd: bool
          p.startToken()
          p.lexer.documentEndMarker(isDocumentEnd)
          if isDocumentEnd:
            p.lexer.bufpos.inc(3)
            p.lineEnding()
            handleLineEnd(false)
          else:
            initDocValues()
            yield startDocEvent()
            state = fpBlockObjectStart
        of '#':
          p.lineEnding()
          handleLineEnd(false)
        of '\t', ' ':
          if not p.consumeLineIfEmpty(newlines):
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
            p.startToken()
            raise p.generateError("Unexpected token (expected ']')")
          of fplSinglePairValue:
            p.startToken()
            raise p.generateError("Unexpected token (expected ']')")
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
            p.startToken()
            raise p.generateError("Unexpected token (expected '}')")
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
              p.startToken()
              raise p.generateError("Unexpected token (expected ',')")
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
          content.reset()
          p.startToken()
          p.singleQuotedScalar(content, after)
          if tag == yTagQuestionMark: tag = yTagExclamationMark
          yieldShallowScalar(content)
          handleObjectEnd(fpFlowAfterObject)
        of '"':
          handleFlowItemStart()
          content.reset()
          p.startToken()
          p.doubleQuotedScalar(content, after)
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
            p.startToken()
            raise p.generateError("Duplicate '?' in flow mapping")
          elif level.kind == fplUnknown:
            case ancestry[ancestry.high].kind
            of fplMapKey, fplMapValue, fplDocument: discard
            of fplSequence: handleObjectStart(yamlStartMap, true)
            else:
              p.startToken()
              raise p.generateError("Unexpected token")
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
            p.startToken()
            raise p.generateError("Unexpected token (expected '}')")
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
            p.startToken()
            raise p.generateError("Unexpected token (expected ']')")
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
            p.startToken()
            raise p.generateError("Unexpected token (expected ',')")
          of fplMapValue, fplSinglePairValue: discard
          of fplUnknown, fplScalar, fplSinglePairKey, fplDocument: debugFail()
          ancestry.add(level)
          level = initLevel(fplUnknown)
          state = fpFlow
          p.lexer.bufpos.inc()
        of '#':
          p.lineEnding()
          handleLineEnd(true)
        of EndOfFile:
          p.startToken()
          raise p.generateError("Unclosed flow content")
        else:
          p.startToken()
          raise p.generateError("Unexpected content (expected flow indicator)")
  try: result = initYamlStream(backend)
  except Exception: debugFail() # compiler error