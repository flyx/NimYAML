#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

type
  FastParseState = enum
    fpInitial, fpBlockAfterObject, fpBlockAfterPlainScalar, fpBlockObjectStart,
    fpExpectDocEnd, fpFlow, fpFlowAfterObject, fpAfterDocument
  
  ScalarType = enum
    stFlow, stLiteral, stFolded
  
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
  result.content = ""
  result.after = ""
  result.tagUri = ""
  result.ancestry = newSeq[FastParseLevel]()

proc getLineNumber*(p: YamlParser): int = p.lexer.lineNumber
    
proc getColNumber*(p: YamlParser): int = p.tokenstart + 1 # column is 1-based

proc getLineContent*(p: YamlParser, marker: bool = true): string =
  result = p.lexer.getCurrentLine(false)
  if marker: result.add(repeat(' ', p.tokenstart) & "^\n")

template debug(message: string) {.dirty.} =
  when defined(yamlDebug):
    try: styledWriteLine(stdout, fgBlue, message)
    except IOError: discard

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

proc reset(buffer: var string) {.raises: [], inline.} = buffer.setLen(0)

proc initLevel(k: FastParseLevelKind): FastParseLevel {.raises: [], inline.} =
  FastParseLevel(kind: k, indentation: UnknownIndentation)

proc emptyScalar(p: YamlParser): YamlStreamEvent {.raises: [], inline.} =
  result = scalarEvent("", p.tag, p.anchor)
  p.tag = yTagQuestionMark
  p.anchor = yAnchorNone

proc currentScalar(p: YamlParser): YamlStreamEvent {.raises: [], inline.} =
  result = YamlStreamEvent(kind: yamlScalar, scalarTag: p.tag,
                           scalarAnchor: p.anchor, scalarContent: p.content)
  p.tag = yTagQuestionMark
  p.anchor = yAnchorNone

template yieldLevelEnd() {.dirty.} =
  case p.level.kind
  of fplSequence: yield endSeqEvent()
  of fplMapKey: yield endMapEvent()
  of fplMapValue, fplSinglePairValue:
    yield emptyScalar(p)
    yield endMapEvent()
  of fplScalar:
    if scalarType != stFlow:
      case chomp
      of ctKeep:
        if p.content.len == 0: p.newlines.inc(-1)
        p.content.addMultiple('\l', p.newlines)
      of ctClip:
        if p.content.len != 0: p.content.add('\l')
      of ctStrip: discard
    yield currentScalar(p)
    p.tag = yTagQuestionMark
    p.anchor = yAnchorNone
  of fplUnknown:
    if p.ancestry.len > 1:
      yield emptyScalar(p) # don't yield scalar for empty doc
  of fplSinglePairKey, fplDocument:
    internalError("Unexpected level kind: " & $p.level.kind)

template handleLineEnd(insideDocument: bool) {.dirty.} =
  case p.lexer.buf[p.lexer.bufpos]
  of '\l': p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
  of '\c': p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
  of EndOfFile:
    when insideDocument: closeEverything()
    return
  else: discard
  p.newlines.inc()

template handleObjectEnd(nextState: FastParseState) {.dirty.} =
  p.level = p.ancestry.pop()
  if p.level.kind == fplSinglePairValue:
    yield endMapEvent()
    p.level = p.ancestry.pop()
  state = if p.level.kind == fplDocument: fpExpectDocEnd else: nextState
  case p.level.kind
  of fplMapKey: p.level.kind = fplMapValue
  of fplSinglePairKey: p.level.kind = fplSinglePairValue
  of fplMapValue: p.level.kind = fplMapKey
  of fplSequence, fplDocument: discard
  of fplUnknown, fplScalar, fplSinglePairValue:
    internalError("Unexpected level kind: " & $p.level.kind)

proc objectStart(p: YamlParser, k: static[YamlStreamEventKind],
                 single: bool = false): YamlStreamEvent {.raises: [].} =
  yAssert(p.level.kind == fplUnknown)
  when k == yamlStartMap:
    result = startMapEvent(p.tag, p.anchor)
    if single:
      debug("started single-pair map at " &
          (if p.level.indentation == UnknownIndentation: $p.indentation else:
           $p.level.indentation))
      p.level.kind = fplSinglePairKey
    else:
      debug("started map at " &
          (if p.level.indentation == UnknownIndentation: $p.indentation else:
           $p.level.indentation))
      p.level.kind = fplMapKey
  else:
    result = startSeqEvent(p.tag, p.anchor)
    debug("started sequence at " &
        (if p.level.indentation == UnknownIndentation: $p.indentation else:
         $p.level.indentation))
    p.level.kind = fplSequence
  p.tag = yTagQuestionMark
  p.anchor = yAnchorNone
  if p.level.indentation == UnknownIndentation:
    p.level.indentation = p.indentation
  p.ancestry.add(p.level)
  p.level = initLevel(fplUnknown)
  
template closeMoreIndentedLevels(atSequenceItem: bool = false) {.dirty.} =
  while p.level.kind != fplDocument:
    let parent = p.ancestry[p.ancestry.high]
    if parent.indentation >= p.indentation:
      when atSequenceItem:
        if (p.indentation == p.level.indentation and
            p.level.kind == fplSequence) or
           (p.indentation == parent.indentation and
            p.level.kind == fplUnknown and parent.kind != fplSequence):
          break
      debug("Closing because parent.indentation (" & $parent.indentation &
            ") >= indentation(" & $p.indentation & ")")
      yieldLevelEnd()
      handleObjectEnd(state)
    else: break
  if p.level.kind == fplDocument: state = fpExpectDocEnd

template closeEverything() {.dirty.} =
  p.indentation = 0
  closeMoreIndentedLevels()
  case p.level.kind
  of fplUnknown: discard p.ancestry.pop()
  of fplDocument: discard
  else:
    yieldLevelEnd()
    discard p.ancestry.pop()
  yield endDocEvent()

template handleBlockSequenceIndicator() {.dirty.} =
  p.startToken()
  case p.level.kind
  of fplUnknown: yield p.objectStart(yamlStartSeq)
  of fplSequence:
    if p.level.indentation != p.indentation:
      raise p.generateError("Invalid p.indentation of block sequence indicator")
    p.ancestry.add(p.level)
    p.level = initLevel(fplUnknown)
  else: raise p.generateError("Illegal sequence item in map")
  p.lexer.skipWhitespace()
  p.indentation = p.lexer.getColNumber(p.lexer.bufpos)

template handleMapKeyIndicator() {.dirty.} =
  p.startToken()
  case p.level.kind
  of fplUnknown: yield p.objectStart(yamlStartMap)
  of fplMapValue:
    if p.level.indentation != p.indentation:
      raise p.generateError("Invalid p.indentation of map key indicator")
    yield scalarEvent("", yTagQuestionMark, yAnchorNone)
    p.level.kind = fplMapKey
    p.ancestry.add(p.level)
    p.level = initLevel(fplUnknown)
  of fplMapKey:
    if p.level.indentation != p.indentation:
      raise p.generateError("Invalid p.indentation of map key indicator")
    p.ancestry.add(p.level)
    p.level = initLevel(fplUnknown)
  of fplSequence:
    raise p.generateError("Unexpected map key indicator (expected '- ')")
  of fplScalar:
    raise p.generateError(
        "Unexpected map key indicator (expected multiline scalar end)")
  of fplSinglePairKey, fplSinglePairValue, fplDocument:
    internalError("Unexpected level kind: " & $p.level.kind)
  p.lexer.skipWhitespace()
  p.indentation = p.lexer.getColNumber(p.lexer.bufpos)

template handleMapValueIndicator() {.dirty.} =
  p.startToken()
  case p.level.kind
  of fplUnknown:
    if p.level.indentation == UnknownIndentation:
      yield p.objectStart(yamlStartMap)
      yield scalarEvent("", yTagQuestionMark, yAnchorNone)
    else: yield emptyScalar(p)
    p.ancestry[p.ancestry.high].kind = fplMapValue
  of fplMapKey:
    if p.level.indentation != p.indentation:
      raise p.generateError("Invalid p.indentation of map key indicator")
    yield scalarEvent("", yTagQuestionMark, yAnchorNone)
    p.level.kind = fplMapValue
    p.ancestry.add(p.level)
    p.level = initLevel(fplUnknown)
  of fplMapValue:
    if p.level.indentation != p.indentation:
      raise p.generateError("Invalid p.indentation of map key indicator")
    p.ancestry.add(p.level)
    p.level = initLevel(fplUnknown)
  of fplSequence:
    raise p.generateError("Unexpected map value indicator (expected '- ')")
  of fplScalar:
    raise p.generateError(
        "Unexpected map value indicator (expected multiline scalar end)")
  of fplSinglePairKey, fplSinglePairValue, fplDocument:
    internalError("Unexpected level kind: " & $p.level.kind)
  p.lexer.skipWhitespace()
  p.indentation = p.lexer.getColNumber(p.lexer.bufpos)

proc initDocValues(p: YamlParser) {.raises: [].} =
  p.shorthands = initTable[string, string]()
  p.anchors = initTable[string, AnchorId]()
  p.shorthands["!"] = "!"
  p.shorthands["!!"] = "tag:yaml.org,2002:"
  p.nextAnchorId = 0.AnchorId
  p.level = initLevel(fplUnknown)
  p.tag = yTagQuestionMark
  p.anchor = yAnchorNone
  p.ancestry.add(FastParseLevel(kind: fplDocument, indentation: -1))

proc startToken(p: YamlParser) {.raises: [], inline.} =
  p.tokenstart = p.lexer.getColNumber(p.lexer.bufpos)

proc anchorName(p: YamlParser) {.raises: [].} =
  debug("lex: anchorName")
  while true:
    p.lexer.bufpos.inc()
    let c = p.lexer.buf[p.lexer.bufpos]
    case c
    of spaceOrLineEnd, '[', ']', '{', '}', ',': break
    else: p.content.add(c)

proc handleAnchor(p: YamlParser) {.raises: [YamlParserError].} =
  p.startToken()
  if p.level.kind != fplUnknown: raise p.generateError("Unexpected token")
  if p.anchor != yAnchorNone:
    raise p.generateError("Only one anchor is allowed per node")
  p.content.reset()
  p.anchorName()
  p.anchor = p.nextAnchorId
  p.anchors[p.content] = p.anchor
  p.nextAnchorId = AnchorId(int(p.nextAnchorId) + 1)

template handleAlias() {.dirty.} =
  p.startToken()
  if p.level.kind != fplUnknown: raise p.generateError("Unexpected token")
  if p.anchor != yAnchorNone or p.tag != yTagQuestionMark:
    raise p.generateError("Alias may not have anchor or tag")
  p.content.reset()
  p.anchorName()
  var id: AnchorId
  try: id = p.anchors[p.content]
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
  if p.level.indentation == UnknownIndentation:
    var flowDepth = 0
    var pos = p.lexer.bufpos
    var recentJsonStyle = false
    while pos < p.lexer.bufpos + 1024:
      case p.lexer.buf[pos]
      of ':':
        if flowDepth == 0 and (p.lexer.buf[pos + 1] in spaceOrLineEnd or
            recentJsonStyle):
          yield p.objectStart(yamlStartMap, single)
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
    if p.level.indentation == UnknownIndentation:
      p.level.indentation = p.indentation

template handleBlockItemStart() {.dirty.} =
  case p.level.kind
  of fplUnknown: handlePossibleMapStart()
  of fplSequence:
    raise p.generateError(
        "Unexpected token (expected block sequence indicator)")
  of fplMapKey:
    p.ancestry.add(p.level)
    p.level = FastParseLevel(kind: fplUnknown, indentation: p.indentation)
  of fplMapValue:
    yield emptyScalar(p)
    p.level.kind = fplMapKey
    p.ancestry.add(p.level)
    p.level = FastParseLevel(kind: fplUnknown, indentation: p.indentation)
  of fplScalar, fplSinglePairKey, fplSinglePairValue, fplDocument:
    internalError("Unexpected level kind: " & $p.level.kind)

template handleFlowItemStart() {.dirty.} =
  if p.level.kind == fplUnknown and
      p.ancestry[p.ancestry.high].kind == fplSequence:
    handlePossibleMapStart(true, true)

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
  yAssert lexer.buf[lexer.bufpos] == '!'
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
proc processQuotedWhitespace(p: YamlParser, newlines: var int) =
  p.after.reset()
  block outer:
    while true:
      case p.lexer.buf[p.lexer.bufpos]
      of ' ', '\t': p.after.add(p.lexer.buf[p.lexer.bufpos])
      of '\l':
        p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
        break
      of '\c':
        p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
        break
      else:
        p.content.add(p.after)
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
        elif newlines == 1: p.content.add(' ')
        else: p.content.addMultiple('\l', newlines - 1)
        break
      p.lexer.bufpos.inc()

# TODO: {.raises: [YamlParserError].}
proc doubleQuotedScalar(p: YamlParser) =
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
      of '0':       p.content.add('\0')
      of 'a':       p.content.add('\x07')
      of 'b':       p.content.add('\x08')
      of '\t', 't': p.content.add('\t')
      of 'n':       p.content.add('\l')
      of 'v':       p.content.add('\v')
      of 'f':       p.content.add('\f')
      of 'r':       p.content.add('\c')
      of 'e':       p.content.add('\e')
      of ' ':       p.content.add(' ')
      of '"':       p.content.add('"')
      of '/':       p.content.add('/')
      of '\\':      p.content.add('\\')
      of 'N':       p.content.add(UTF8NextLine)
      of '_':       p.content.add(UTF8NonBreakingSpace)
      of 'L':       p.content.add(UTF8LineSeparator)
      of 'P':       p.content.add(UTF8ParagraphSeparator)
      of 'x':       p.content.add(p.lexer.unicodeSequence(2))
      of 'u':       p.content.add(p.lexer.unicodeSequence(4))
      of 'U':       p.content.add(p.lexer.unicodeSequence(8))
      of '\l', '\c':
        var newlines = 0
        p.processQuotedWhitespace(newlines)
        continue
      else: raise p.lexer.generateError("Illegal character in escape sequence")
    of '"':
      p.lexer.bufpos.inc()
      break
    of '\l', '\c', '\t', ' ':
      var newlines = 1
      p.processQuotedWhitespace(newlines)
      continue
    else: p.content.add(c)
    p.lexer.bufpos.inc()

# TODO: {.raises: [].}
proc singleQuotedScalar(p: YamlParser) =
  debug("lex: singleQuotedScalar")
  p.lexer.bufpos.inc()
  while true:
    case p.lexer.buf[p.lexer.bufpos]
    of '\'':
      p.lexer.bufpos.inc()
      if p.lexer.buf[p.lexer.bufpos] == '\'': p.content.add('\'')
      else: break
    of EndOfFile: raise p.lexer.generateError("Unfinished single quoted string")
    of '\l', '\c', '\t', ' ':
      var newlines = 1
      p.processQuotedWhitespace(newlines)
      continue
    else: p.content.add(p.lexer.buf[p.lexer.bufpos])
    p.lexer.bufpos.inc()

proc isPlainSafe(lexer: BaseLexer, index: int, context: YamlContext): bool
    {.raises: [].} =
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

proc plainScalar(p: YamlParser, context: static[YamlContext]) {.raises: [].} =
  debug("lex: plainScalar")
  p.content.add(p.lexer.buf[p.lexer.bufpos])
  block outer:
    while true:
      p.lexer.bufpos.inc()
      let c = p.lexer.buf[p.lexer.bufpos]
      case c
      of ' ', '\t':
        p.after.setLen(1)
        p.after[0] = c
        while true:
          p.lexer.bufpos.inc()
          let c2 = p.lexer.buf[p.lexer.bufpos]
          case c2
          of ' ', '\t': p.after.add(c2)
          of lineEnd: break outer
          of ':':
            if p.lexer.isPlainSafe(p.lexer.bufpos + 1, context):
              p.content.add(p.after & ':')
              break
            else: break outer
          of '#': break outer
          of flowIndicators:
            if context == cBlock:
              p.content.add(p.after)
              p.content.add(c2)
              break
            else: break outer
          else:
            p.content.add(p.after)
            p.content.add(c2)
            break
      of flowIndicators:
        when context == cFlow: break
        else: p.content.add(c)
      of lineEnd: break
      of ':':
        if p.lexer.isPlainSafe(p.lexer.bufpos + 1, context): p.content.add(':')
        else: break outer
      else: p.content.add(c)
  debug("lex: \"" & p.content & '\"')

proc continueMultilineScalar(p: YamlParser) {.raises: [].} =
  p.content.add(if p.newlines == 1: " " else: repeat('\l', p.newlines - 1))
  p.startToken()
  p.plainScalar(cBlock)

template handleFlowPlainScalar() {.dirty.} =
  p.content.reset()
  p.startToken()
  p.plainScalar(cFlow)
  if p.lexer.buf[p.lexer.bufpos] in {'{', '}', '[', ']', ',', ':', '#'}:
    discard
  else:
    p.newlines = 0
    while true:
      case p.lexer.buf[p.lexer.bufpos]
      of ':':
        if p.lexer.isPlainSafe(p.lexer.bufpos + 1, cFlow):
          if p.newlines == 1:
            p.content.add(' ')
            p.newlines = 0
          elif p.newlines > 1:
            p.content.addMultiple(' ', p.newlines - 1)
            p.newlines = 0
          p.plainScalar(cFlow)
        break
      of '#', EndOfFile: break
      of '\l':
        p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
        p.newlines.inc()
      of '\c':
        p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
        p.newlines.inc()
      of flowIndicators: break
      of ' ', '\t': p.lexer.skipWhitespace()
      else:
        if p.newlines == 1:
          p.content.add(' ')
          p.newlines = 0
        elif p.newlines > 1:
          p.content.addMultiple(' ', p.newlines - 1)
          p.newlines = 0
        p.plainScalar(cFlow)
  yield currentScalar(p)
  handleObjectEnd(fpFlowAfterObject)

proc tagHandle(p: YamlParser, shorthandEnd: var int)
    {.raises: [YamlParserError].} =
  debug("lex: tagHandle")
  shorthandEnd = 0
  p.content.add(p.lexer.buf[p.lexer.bufpos])
  var i = 0
  while true:
    p.lexer.bufpos.inc()
    i.inc()
    let c = p.lexer.buf[p.lexer.bufpos]
    case c
    of spaceOrLineEnd:
      if shorthandEnd == -1:
        raise p.lexer.generateError("Unclosed verbatim tag")
      break
    of '!':
      if shorthandEnd == -1 and i == 2:
        p.content.add(c)
        continue
      elif shorthandEnd != 0:
        raise p.lexer.generateError("Illegal character in tag suffix")
      shorthandEnd = i
      p.content.add(c)
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@', '&',
       '-', '=', '+', '$', '_', '.', '~', '*', '\'', '(', ')':
      p.content.add(c)
    of ',':
      if shortHandEnd > 0: break # ',' after shorthand is flow indicator
      p.content.add(c)
    of '<':
      if i == 1:
        shorthandEnd = -1
        p.content.reset()
      else: raise p.lexer.generateError("Illegal character in tag handle")
    of '>':
      if shorthandEnd == -1:
        p.lexer.bufpos.inc()
        if p.lexer.buf[p.lexer.bufpos] notin spaceOrLineEnd:
          raise p.lexer.generateError("Missing space after verbatim tag handle")
        break
      else: raise p.lexer.generateError("Illegal character in tag handle")
    of '%':
      if shorthandEnd != 0: p.content.add(p.lexer.byteSequence())
      else: raise p.lexer.generateError("Illegal character in tag handle")
    else: raise p.lexer.generateError("Illegal character in tag handle")

proc handleTagHandle(p: YamlParser) {.raises: [YamlParserError].} =
  p.startToken()
  if p.level.kind != fplUnknown: raise p.generateError("Unexpected tag handle")
  if p.tag != yTagQuestionMark:
    raise p.generateError("Only one tag handle is allowed per node")
  p.content.reset()
  var
    shorthandEnd: int
  p.tagHandle(shorthandEnd)
  if shorthandEnd != -1:
    try:
      p.tagUri.reset()
      p.tagUri.add(p.shorthands[p.content[0..shorthandEnd]])
      p.tagUri.add(p.content[shorthandEnd + 1 .. ^1])
    except KeyError:
      raise p.generateError(
          "Undefined tag shorthand: " & p.content[0..shorthandEnd])
    try: p.tag = p.tagLib.tags[p.tagUri]
    except KeyError: p.tag = p.tagLib.registerUri(p.tagUri)
  else:
    try: p.tag = p.tagLib.tags[p.content]
    except KeyError: p.tag = p.tagLib.registerUri(p.content)

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
  p.newlines = 0
  p.level.kind = fplScalar
  scalarType = t

template blockScalarHeader() {.dirty.} =
  debug("lex: blockScalarHeader")
  chomp = ctClip
  p.level.indentation = UnknownIndentation
  if p.tag == yTagQuestionMark: p.tag = yTagExclamationMark
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
      if p.level.indentation != UnknownIndentation:
        raise p.lexer.generateError("Only one p.indentation indicator is allowed")
      p.level.indentation = p.ancestry[p.ancestry.high].indentation +
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
  p.content.reset()

template blockScalarLine() {.dirty.} =
  debug("lex: blockScalarLine")
  if p.indentation < p.level.indentation:
    if p.lexer.buf[p.lexer.bufpos] == '#':
      # skip all following comment lines
      while p.indentation > p.ancestry[p.ancestry.high].indentation:
        p.lineEnding()
        handleLineEnd(true)
        p.newlines.inc(-1)
        p.lexer.skipIndentation()
        p.indentation = p.lexer.getColNumber(p.lexer.bufpos)
      if p.indentation > p.ancestry[p.ancestry.high].indentation:
        raise p.lexer.generateError(
            "Invalid content in block scalar after comments")
      closeMoreIndentedLevels()
    else:
      raise p.lexer.generateError(
          "Invalid p.indentation (expected p.indentation of at least " &
          $p.level.indentation & " spaces)")    
  else:
    if p.level.indentation == UnknownIndentation:
      if p.lexer.buf[p.lexer.bufpos] in lineEnd:
        handleLineEnd(true)
        continue
      else:
        p.level.indentation = p.indentation
        p.content.addMultiple('\l', p.newlines)
    elif p.indentation > p.level.indentation or
        p.lexer.buf[p.lexer.bufpos] == '\t':
      p.content.addMultiple('\l', p.newlines)
      recentWasMoreIndented = true
      p.content.addMultiple(' ', p.indentation - p.level.indentation)
    elif scalarType == stFolded:
      if recentWasMoreIndented:
        recentWasMoreIndented = false
        p.newlines.inc()
      if p.newlines == 0: discard
      elif p.newlines == 1: p.content.add(' ')
      else: p.content.addMultiple('\l', p.newlines - 1)    
    else: p.content.addMultiple('\l', p.newlines)
    p.newlines = 0
    while p.lexer.buf[p.lexer.bufpos] notin lineEnd:
      p.content.add(p.lexer.buf[p.lexer.bufpos])
      p.lexer.bufpos.inc()
    handleLineEnd(true)

proc parse*(p: YamlParser, s: Stream): YamlStream =
  p.content.reset()
  p.after.reset()
  p.tagUri.reset()
  p.ancestry.setLen(0)
  var backend = iterator(): YamlStreamEvent =
    var
      state = fpInitial
      flowdepth: int = 0
      explicitFlowKey: bool
      scalarType: ScalarType
      recentWasMoreIndented: bool
      chomp: ChompType
    
    p.lexer.open(s)
    p.initDocValues()
    
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
            p.tagUri.reset()
            p.startToken()
            p.lexer.tagShorthand(shorthand)
            p.lexer.tagUriMapping(p.tagUri)
            p.shorthands[shorthand] = p.tagUri
            p.lineEnding()
            handleLineEnd(false)
          of ldUnknown:
            if p.callback != nil:
                p.callback(p.lexer.lineNumber, p.getColNumber(),
                           p.getLineContent(), "Unknown directive")
            p.lexer.finishLine()
            handleLineEnd(false)
        of ' ', '\t':
          if not p.consumeLineIfEmpty(p.newlines):
            p.indentation = p.lexer.getColNumber(p.lexer.bufpos)
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
          if p.level.kind notin {fplUnknown, fplScalar}:
            p.startToken()
            raise p.generateError("Unexpected scalar")
          startScalar(stFlow)
          p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
          p.newlines.inc()
          state = fpBlockObjectStart
        of '\c':
          if p.level.kind notin {fplUnknown, fplScalar}:
            p.startToken()
            raise p.generateError("Unexpected scalar")
          startScalar(stFlow)
          p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
          p.newlines.inc()
          state = fpBlockObjectStart
        else:
          yield currentScalar(p)
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
          case p.level.kind
          of fplUnknown: yield p.objectStart(yamlStartMap)
          of fplMapKey:
            yield scalarEvent("", yTagQuestionMark, yAnchorNone)
            p.level.kind = fplMapValue
            p.ancestry.add(p.level)
            p.level = initLevel(fplUnknown)
          of fplMapValue:
            p.level.kind = fplMapValue
            p.ancestry.add(p.level)
            p.level = initLevel(fplUnknown)
          of fplSequence:
            p.startToken()
            raise p.generateError("Illegal token (expected sequence item)")
          of fplScalar:
            p.startToken()
            raise p.generateError(
                "Multiline scalars may not be implicit map keys")
          of fplSinglePairKey, fplSinglePairValue, fplDocument:
            internalError("Unexpected level kind: " & $p.level.kind)
          p.lexer.bufpos.inc()
          p.lexer.skipWhitespace()
          p.indentation = p.lexer.getColNumber(p.lexer.bufpos)
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
        p.indentation = p.lexer.getColNumber(p.lexer.bufpos)
        if p.indentation == 0:
          var success: bool
          p.lexer.directivesEndMarker(success)
          if success:
            p.lexer.bufpos.inc(3)
            closeEverything()
            p.initDocValues()
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
        if p.indentation <= p.ancestry[p.ancestry.high].indentation:
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
        elif p.indentation <= p.level.indentation and
            p.lexer.buf[p.lexer.bufpos] in lineEnd:
          handleLineEnd(true)
          continue
        if p.level.kind == fplScalar and scalarType != stFlow:
          blockScalarLine()
          continue
        case p.lexer.buf[p.lexer.bufpos]
        of '\l':
          p.lexer.bufpos = p.lexer.handleLF(p.lexer.bufpos)
          p.newlines.inc()
          if p.level.kind == fplUnknown:
            p.level.indentation = UnknownIndentation
        of '\c':
          p.lexer.bufpos = p.lexer.handleCR(p.lexer.bufpos)
          p.newlines.inc()
          if p.level.kind == fplUnknown:
            p.level.indentation = UnknownIndentation
        of EndOfFile:
          closeEverything()
          return
        of '#':
          p.lineEnding()
          handleLineEnd(true)
          if p.level.kind == fplUnknown:
            p.level.indentation = UnknownIndentation
        of ':':
          if p.lexer.isPlainSafe(p.lexer.bufpos + 1, cBlock):
            if p.level.kind == fplScalar:
              p.continueMultilineScalar()
              state = fpBlockAfterPlainScalar
            else:
              handleBlockItemStart()
              p.content.reset()
              p.startToken()
              p.plainScalar(cBlock)
              state = fpBlockAfterPlainScalar
          else:
            p.lexer.bufpos.inc()
            handleMapValueIndicator()
        of '\t':
          if p.level.kind == fplScalar:
            p.lexer.skipWhitespace()
            p.continueMultilineScalar()
            state = fpBlockAfterPlainScalar
          else: raise p.lexer.generateError("\\t cannot start any token")
        else:
          if p.level.kind == fplScalar:
            p.continueMultilineScalar()
            state = fpBlockAfterPlainScalar
          else:
            case p.lexer.buf[p.lexer.bufpos]
            of '\'':
              handleBlockItemStart()
              p.content.reset()
              p.startToken()
              p.singleQuotedScalar()
              if p.tag == yTagQuestionMark: p.tag = yTagExclamationMark
              yield currentScalar(p)
              handleObjectEnd(fpBlockAfterObject)
            of '"':
              handleBlockItemStart()
              p.content.reset()
              p.startToken()
              p.doubleQuotedScalar()
              if p.tag == yTagQuestionMark: p.tag = yTagExclamationMark
              yield currentScalar(p)
              handleObjectEnd(fpBlockAfterObject)
            of '|', '>':
              blockScalarHeader()
              continue
            of '-':
              if p.lexer.isPlainSafe(p.lexer.bufpos + 1, cBlock):
                handleBlockItemStart()
                p.content.reset()
                p.startToken()
                p.plainScalar(cBlock)
                state = fpBlockAfterPlainScalar
              else:
                p.lexer.bufpos.inc()
                handleBlockSequenceIndicator()
            of '!':
              handleBlockItemStart()
              p.handleTagHandle()
            of '&':
              handleBlockItemStart()
              p.handleAnchor()
            of '*':
              handleBlockItemStart()
              handleAlias()
            of '[', '{':
              handleBlockItemStart()
              state = fpFlow
            of '?':
              if p.lexer.isPlainSafe(p.lexer.bufpos + 1, cBlock):
                handleBlockItemStart()
                p.content.reset()
                p.startToken()
                p.plainScalar(cBlock)
                state = fpBlockAfterPlainScalar
              else:
                p.lexer.bufpos.inc()
                handleMapKeyIndicator()
            of '@', '`':
              raise p.lexer.generateError(
                  "Reserved characters cannot start a plain scalar")
            else:
              handleBlockItemStart()
              p.content.reset()
              p.startToken()
              p.plainScalar(cBlock)
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
            discard p.ancestry.pop()
            p.initDocValues()
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
            p.initDocValues()
            yield startDocEvent()
            state = fpBlockObjectStart
        of '#':
          p.lineEnding()
          handleLineEnd(false)
        of '\t', ' ':
          if not p.consumeLineIfEmpty(p.newlines):
            p.indentation = p.lexer.getColNumber(p.lexer.bufpos)
            p.initDocValues()
            yield startDocEvent()
            state = fpBlockObjectStart
        of EndOfFile: break
        else:
          p.initDocValues()
          state = fpInitial
      of fpFlow:
        debug("state: flow")
        p.lexer.skipWhitespaceCommentsAndNewlines()
        case p.lexer.buf[p.lexer.bufpos]
        of '{':
          handleFlowItemStart()
          yield p.objectStart(yamlStartMap)
          flowdepth.inc()
          p.lexer.bufpos.inc()
          explicitFlowKey = false
        of '[':
          handleFlowItemStart()
          yield p.objectStart(yamlStartSeq)
          flowdepth.inc()
          p.lexer.bufpos.inc()
        of '}':
          yAssert(p.level.kind == fplUnknown)
          p.level = p.ancestry.pop()
          case p.level.kind
          of fplMapValue:
            yield emptyScalar(p)
            p.level.kind = fplMapKey
          of fplMapKey:
            if p.tag != yTagQuestionMark or p.anchor != yAnchorNone or
                explicitFlowKey:
              yield emptyScalar(p)
              yield scalarEvent("", yTagQuestionMark, yAnchorNone)
          of fplSequence:
            p.startToken()
            raise p.generateError("Unexpected token (expected ']')")
          of fplSinglePairValue:
            p.startToken()
            raise p.generateError("Unexpected token (expected ']')")
          of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
            internalError("Unexpected level kind: " & $p.level.kind)
          p.lexer.bufpos.inc()
          leaveFlowLevel()
        of ']':
          yAssert(p.level.kind == fplUnknown)
          p.level = p.ancestry.pop()
          case p.level.kind
          of fplSequence:
            if p.tag != yTagQuestionMark or p.anchor != yAnchorNone:
              yield emptyScalar(p)
          of fplSinglePairValue:
            yield emptyScalar(p)
            p.level = p.ancestry.pop()
            yield endMapEvent()
            yAssert(p.level.kind == fplSequence)
          of fplMapKey, fplMapValue:
            p.startToken()
            raise p.generateError("Unexpected token (expected '}')")
          of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
            internalError("Unexpected level kind: " & $p.level.kind)
          p.lexer.bufpos.inc()
          leaveFlowLevel()
        of ',':
          yAssert(p.level.kind == fplUnknown)
          p.level = p.ancestry.pop()
          case p.level.kind
          of fplSequence: yield emptyScalar(p)
          of fplMapValue:
            yield emptyScalar(p)
            p.level.kind = fplMapKey
            explicitFlowKey = false
          of fplMapKey:
            yield emptyScalar(p)
            yield scalarEvent("", yTagQuestionMark, yAnchorNone)
            explicitFlowKey = false
          of fplSinglePairValue:
            yield emptyScalar(p)
            p.level = p.ancestry.pop()
            yield endMapEvent()
            yAssert(p.level.kind == fplSequence)
          of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
            internalError("Unexpected level kind: " & $p.level.kind)
          p.ancestry.add(p.level)
          p.level = initLevel(fplUnknown)
          p.lexer.bufpos.inc()
        of ':':
          if p.lexer.isPlainSafe(p.lexer.bufpos + 1, cFlow):
            handleFlowItemStart()
            handleFlowPlainScalar()
          else:
            p.level = p.ancestry.pop()
            case p.level.kind
            of fplSequence:
              yield startMapEvent(p.tag, p.anchor)
              debug("started single-pair map at " &
                  (if p.level.indentation == UnknownIndentation:
                   $p.indentation else: $p.level.indentation))
              p.tag = yTagQuestionMark
              p.anchor = yAnchorNone
              if p.level.indentation == UnknownIndentation:
                p.level.indentation = p.indentation
              p.ancestry.add(p.level)
              p.level = initLevel(fplSinglePairValue)
              yield scalarEvent("")
            of fplMapValue, fplSinglePairValue:
              p.startToken()
              raise p.generateError("Unexpected token (expected ',')")
            of fplMapKey:
              yield emptyScalar(p)
              p.level.kind = fplMapValue
            of fplSinglePairKey:
              yield emptyScalar(p)
              p.level.kind = fplSinglePairValue
            of fplUnknown, fplScalar, fplDocument:
              internalError("Unexpected level kind: " & $p.level.kind)
            p.ancestry.add(p.level)
            p.level = initLevel(fplUnknown)
            p.lexer.bufpos.inc()
        of '\'':
          handleFlowItemStart()
          p.content.reset()
          p.startToken()
          p.singleQuotedScalar()
          if p.tag == yTagQuestionMark: p.tag = yTagExclamationMark
          yield currentScalar(p)
          handleObjectEnd(fpFlowAfterObject)
        of '"':
          handleFlowItemStart()
          p.content.reset()
          p.startToken()
          p.doubleQuotedScalar()
          if p.tag == yTagQuestionMark: p.tag = yTagExclamationMark
          yield currentScalar(p)
          handleObjectEnd(fpFlowAfterObject)
        of '!':
          handleFlowItemStart()
          p.handleTagHandle()
        of '&':
          handleFlowItemStart()
          p.handleAnchor()
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
          elif p.level.kind == fplUnknown:
            case p.ancestry[p.ancestry.high].kind
            of fplMapKey, fplMapValue, fplDocument: discard
            of fplSequence: yield p.objectStart(yamlStartMap, true)
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
          case p.level.kind
          of fplSequence: discard
          of fplMapKey, fplMapValue:
            p.startToken()
            raise p.generateError("Unexpected token (expected '}')")
          of fplSinglePairValue:
            p.level = p.ancestry.pop()
            yAssert(p.level.kind == fplSequence)
            yield endMapEvent()
          of fplScalar, fplUnknown, fplSinglePairKey, fplDocument:
            internalError("Unexpected level kind: " & $p.level.kind)
          p.lexer.bufpos.inc()
          leaveFlowLevel()
        of '}':
          case p.level.kind
          of fplMapKey, fplMapValue: discard
          of fplSequence, fplSinglePairValue:
            p.startToken()
            raise p.generateError("Unexpected token (expected ']')")
          of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
            internalError("Unexpected level kind: " & $p.level.kind)
          p.lexer.bufpos.inc()
          leaveFlowLevel()
        of ',':
          case p.level.kind
          of fplSequence: discard
          of fplMapValue:
            yield scalarEvent("", yTagQuestionMark, yAnchorNone)
            p.level.kind = fplMapKey
            explicitFlowKey = false
          of fplSinglePairValue:
            p.level = p.ancestry.pop()
            yAssert(p.level.kind == fplSequence)
            yield endMapEvent()
          of fplMapKey: explicitFlowKey = false
          of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
            internalError("Unexpected level kind: " & $p.level.kind)
          p.ancestry.add(p.level)
          p.level = initLevel(fplUnknown)
          state = fpFlow
          p.lexer.bufpos.inc()
        of ':':
          case p.level.kind
          of fplSequence, fplMapKey:
            p.startToken()
            raise p.generateError("Unexpected token (expected ',')")
          of fplMapValue, fplSinglePairValue: discard
          of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
            internalError("Unexpected level kind: " & $p.level.kind)
          p.ancestry.add(p.level)
          p.level = initLevel(fplUnknown)
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
  except Exception: # nimc enforces this handler although it isn't necessary
    internalError("Reached code that should be unreachable")