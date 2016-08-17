#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

type  
  ScalarType = enum
    stFlow, stLiteral, stFolded
  
  LexedDirective = enum
    ldYaml, ldTag, ldUnknown
    
  YamlContext = enum
    cBlock, cFlow
  
  ChompType = enum
    ctKeep, ctClip, ctStrip
  
  ParserContext = ref object of YamlStream
    p: YamlParser
    storedState: proc(s: YamlStream, e: var YamlStreamEvent): bool
    scalarType: ScalarType
    chomp: ChompType
    atSequenceItem: bool
    recentWasMoreIndented: bool
    flowdepth: int
    explicitFlowKey: bool
    content, after: string
    ancestry: seq[FastParseLevel]
    level: FastParseLevel
    tagUri: string
    tag: TagId
    anchor: AnchorId
    shorthands: Table[string, string]
    nextAnchorId: AnchorId
    newlines: int
    indentation: int

  LevelEndResult = enum
    lerNothing, lerOne, lerAdditionalMapEnd

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
  if marker: result.add(repeat(' ', p.tokenstart) & "^\n")

proc lexer(c: ParserContext): var BaseLexer {.inline.} = c.p.lexer

template debug(message: string) {.dirty.} =
  when defined(yamlDebug):
    try: styledWriteLine(stdout, fgBlue, message)
    except IOError: discard

proc generateError(c: ParserContext, message: string):
    ref YamlParserError {.raises: [].} =
  result = newException(YamlParserError, message)
  result.line = c.lexer.lineNumber
  result.column = c.p.tokenstart + 1
  result.lineContent = c.p.getLineContent(true)

proc generateError(lx: BaseLexer, message: string):
    ref YamlParserError {.raises: [].} =
  result = newException(YamlParserError, message)
  result.line = lx.lineNumber
  result.column = lx.bufpos + 1
  result.lineContent = lx.getCurrentLine(false) &
      repeat(' ', lx.getColNumber(lx.bufpos)) & "^\n"

template lexCR(lexer: BaseLexer) {.dirty.} =
  try: lexer.bufpos = lexer.handleCR(lexer.bufpos)
  except:
    var e = generateError(lexer, "I/O Error: " & getCurrentExceptionMsg())
    e.parent = getCurrentException()
    raise e

template lexLF(lexer: BaseLexer) {.dirty.} =
  try: lexer.bufpos = lexer.handleLF(lexer.bufpos)
  except:
    var e = generateError(lexer, "I/O Error: " & getCurrentExceptionMsg())
    e.parent = getCurrentException()
    raise e

proc callCallback(c: ParserContext, msg: string) {.raises: [YamlParserError].} =
  try:
    if not isNil(c.p.callback):
      c.p.callback(c.lexer.lineNumber, c.p.getColNumber(), c.p.getLineContent(),
          msg)
  except:
    var e = newException(YamlParserError,
        "Warning callback raised exception: " & getCurrentExceptionMsg())
    e.parent = getCurrentException()
    raise e

proc addMultiple(s: var string, c: char, num: int) {.raises: [], inline.} =
  for i in 1..num:
    s.add(c)

proc reset(buffer: var string) {.raises: [], inline.} = buffer.setLen(0)

proc initLevel(k: FastParseLevelKind): FastParseLevel {.raises: [], inline.} =
  FastParseLevel(kind: k, indentation: UnknownIndentation)

proc emptyScalar(c: ParserContext): YamlStreamEvent {.raises: [], inline.} =
  result = scalarEvent("", c.tag, c.anchor)
  c.tag = yTagQuestionMark
  c.anchor = yAnchorNone

proc currentScalar(c: ParserContext): YamlStreamEvent {.raises: [], inline.} =
  result = YamlStreamEvent(kind: yamlScalar, scalarTag: c.tag,
                           scalarAnchor: c.anchor, scalarContent: c.content)
  c.tag = yTagQuestionMark
  c.anchor = yAnchorNone

proc handleLineEnd(c: ParserContext, incNewlines: static[bool]): bool =
  case c.lexer.buf[c.lexer.bufpos]
  of '\l': c.lexer.lexLF()
  of '\c': c.lexer.lexCR()
  of EndOfFile: return true
  else: discard
  when incNewlines: c.newlines.inc()

proc objectStart(c: ParserContext, k: static[YamlStreamEventKind],
                 single: bool = false): YamlStreamEvent {.raises: [].} =
  yAssert(c.level.kind == fplUnknown)
  when k == yamlStartMap:
    result = startMapEvent(c.tag, c.anchor)
    if single:
      debug("started single-pair map at " &
          (if c.level.indentation == UnknownIndentation: $c.indentation else:
           $c.level.indentation))
      c.level.kind = fplSinglePairKey
    else:
      debug("started map at " &
          (if c.level.indentation == UnknownIndentation: $c.indentation else:
           $c.level.indentation))
      c.level.kind = fplMapKey
  else:
    result = startSeqEvent(c.tag, c.anchor)
    debug("started sequence at " &
        (if c.level.indentation == UnknownIndentation: $c.indentation else:
         $c.level.indentation))
    c.level.kind = fplSequence
  c.tag = yTagQuestionMark
  c.anchor = yAnchorNone
  if c.level.indentation == UnknownIndentation:
    c.level.indentation = c.indentation
  c.ancestry.add(c.level)
  c.level = initLevel(fplUnknown)

proc initDocValues(c: ParserContext) {.raises: [].} =
  c.shorthands = initTable[string, string]()
  c.p.anchors = initTable[string, AnchorId]()
  c.shorthands["!"] = "!"
  c.shorthands["!!"] = "tag:yaml.org,2002:"
  c.nextAnchorId = 0.AnchorId
  c.level = initLevel(fplUnknown)
  c.tag = yTagQuestionMark
  c.anchor = yAnchorNone
  c.ancestry.add(FastParseLevel(kind: fplDocument, indentation: -1))

proc startToken(c: ParserContext) {.raises: [], inline.} =
  c.p.tokenstart = c.lexer.getColNumber(c.lexer.bufpos)

proc anchorName(c: ParserContext) {.raises: [].} =
  debug("lex: anchorName")
  while true:
    c.lexer.bufpos.inc()
    let ch = c.lexer.buf[c.lexer.bufpos]
    case ch
    of spaceOrLineEnd, '[', ']', '{', '}', ',': break
    else: c.content.add(ch)

proc handleAnchor(c: ParserContext) {.raises: [YamlParserError].} =
  c.startToken()
  if c.level.kind != fplUnknown: raise c.generateError("Unexpected token")
  if c.anchor != yAnchorNone:
    raise c.generateError("Only one anchor is allowed per node")
  c.content.reset()
  c.anchorName()
  c.anchor = c.nextAnchorId
  c.p.anchors[c.content] = c.anchor
  c.nextAnchorId = AnchorId(int(c.nextAnchorId) + 1)

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
      of '\l': lexer.lexLF()
      of '\c': lexer.lexCR()
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

proc lineEnding(c: ParserContext) {.raises: [YamlParserError], inline.} =
  debug("lex: lineEnding")
  if c.lexer.buf[c.lexer.bufpos] notin lineEnd:
    while c.lexer.buf[c.lexer.bufpos] in space: c.lexer.bufpos.inc()
    if c.lexer.buf[c.lexer.bufpos] in lineEnd: discard
    elif c.lexer.buf[c.lexer.bufpos] == '#':
      while c.lexer.buf[c.lexer.bufpos] notin lineEnd: c.lexer.bufpos.inc()
    else:
      c.startToken()
      raise c.generateError("Unexpected token (expected comment or line end)")

proc tagShorthand(lexer: var BaseLexer, shorthand: var string) {.inline.} =
  debug("lex: tagShorthand")
  while lexer.buf[lexer.bufpos] in space: lexer.bufpos.inc()
  yAssert lexer.buf[lexer.bufpos] == '!'
  shorthand.add('!')
  lexer.bufpos.inc()
  var ch = lexer.buf[lexer.bufpos]
  if ch in spaceOrLineEnd: discard
  else:
    while ch != '!':
      case ch
      of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-':
        shorthand.add(ch)
        lexer.bufpos.inc()
        ch = lexer.buf[lexer.bufpos]
      else: raise lexer.generateError("Illegal character in tag shorthand")
    shorthand.add(ch)
    lexer.bufpos.inc()
  if lexer.buf[lexer.bufpos] notin spaceOrLineEnd:
    raise lexer.generateError("Missing space after tag shorthand")

proc tagUriMapping(lexer: var BaseLexer, uri: var string)
    {.raises: [YamlParserError].} =
  debug("lex: tagUriMapping")
  while lexer.buf[lexer.bufpos] in space:
    lexer.bufpos.inc()
  var ch = lexer.buf[lexer.bufpos]
  if ch == '!':
    uri.add(ch)
    lexer.bufpos.inc()
    ch = lexer.buf[lexer.bufpos]
  while ch notin spaceOrLineEnd:
    case ch
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@', '&',
       '-', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')':
      uri.add(ch)
      lexer.bufpos.inc()
      ch = lexer.buf[lexer.bufpos]
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
      ch = lexer.buf[lexer.bufpos]
    case ch
    of EndOFFile, '\l', '\c':
      raise lexer.generateError("Unfinished unicode escape sequence")
    of '0' .. '9':
      unicodeChar = unicodechar or (int(ch) - 0x30) shl (digitPosition * 4)
    of 'A' .. 'F':
      unicodeChar = unicodechar or (int(ch) - 0x37) shl (digitPosition * 4)
    of 'a' .. 'f':
      unicodeChar = unicodechar or (int(ch) - 0x57) shl (digitPosition * 4)
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
      ch = lexer.buf[lexer.bufpos]
    case ch
    of EndOfFile, '\l', 'r':
      raise lexer.generateError("Unfinished octet escape sequence")
    of '0' .. '9':
      charCode = charCode or (int8(ch) - 0x30.int8) shl (digitPosition * 4)
    of 'A' .. 'F':
      charCode = charCode or (int8(ch) - 0x37.int8) shl (digitPosition * 4)
    of 'a' .. 'f':
      charCode = charCode or (int8(ch) - 0x57.int8) shl (digitPosition * 4)
    else:
      raise lexer.generateError("Invalid character in octet escape sequence")
  return char(charCode)

# TODO: {.raises: [].}
proc processQuotedWhitespace(c: ParserContext, newlines: var int) =
  c.after.reset()
  block outer:
    while true:
      case c.lexer.buf[c.lexer.bufpos]
      of ' ', '\t': c.after.add(c.lexer.buf[c.lexer.bufpos])
      of '\l':
        c.lexer.bufpos = c.lexer.handleLF(c.lexer.bufpos)
        break
      of '\c':
        c.lexer.bufpos = c.lexer.handleLF(c.lexer.bufpos)
        break
      else:
        c.content.add(c.after)
        break outer
      c.lexer.bufpos.inc()
    while true:
      case c.lexer.buf[c.lexer.bufpos]
      of ' ', '\t': discard
      of '\l':
        c.lexer.lexLF()
        newlines.inc()
        continue
      of '\c':
        c.lexer.lexCR()
        newlines.inc()
        continue
      else:
        if newlines == 0: discard
        elif newlines == 1: c.content.add(' ')
        else: c.content.addMultiple('\l', newlines - 1)
        break
      c.lexer.bufpos.inc()

# TODO: {.raises: [YamlParserError].}
proc doubleQuotedScalar(c: ParserContext) =
  debug("lex: doubleQuotedScalar")
  c.lexer.bufpos.inc()
  while true:
    var ch = c.lexer.buf[c.lexer.bufpos]
    case ch
    of EndOfFile:
      raise c.lexer.generateError("Unfinished double quoted string")
    of '\\':
      c.lexer.bufpos.inc()
      case c.lexer.buf[c.lexer.bufpos]
      of EndOfFile:
        raise c.lexer.generateError("Unfinished escape sequence")
      of '0':       c.content.add('\0')
      of 'a':       c.content.add('\x07')
      of 'b':       c.content.add('\x08')
      of '\t', 't': c.content.add('\t')
      of 'n':       c.content.add('\l')
      of 'v':       c.content.add('\v')
      of 'f':       c.content.add('\f')
      of 'r':       c.content.add('\c')
      of 'e':       c.content.add('\e')
      of ' ':       c.content.add(' ')
      of '"':       c.content.add('"')
      of '/':       c.content.add('/')
      of '\\':      c.content.add('\\')
      of 'N':       c.content.add(UTF8NextLine)
      of '_':       c.content.add(UTF8NonBreakingSpace)
      of 'L':       c.content.add(UTF8LineSeparator)
      of 'P':       c.content.add(UTF8ParagraphSeparator)
      of 'x':       c.content.add(c.lexer.unicodeSequence(2))
      of 'u':       c.content.add(c.lexer.unicodeSequence(4))
      of 'U':       c.content.add(c.lexer.unicodeSequence(8))
      of '\l', '\c':
        var newlines = 0
        c.processQuotedWhitespace(newlines)
        continue
      else: raise c.lexer.generateError("Illegal character in escape sequence")
    of '"':
      c.lexer.bufpos.inc()
      break
    of '\l', '\c', '\t', ' ':
      var newlines = 1
      c.processQuotedWhitespace(newlines)
      continue
    else: c.content.add(ch)
    c.lexer.bufpos.inc()

# TODO: {.raises: [].}
proc singleQuotedScalar(c: ParserContext) =
  debug("lex: singleQuotedScalar")
  c.lexer.bufpos.inc()
  while true:
    case c.lexer.buf[c.lexer.bufpos]
    of '\'':
      c.lexer.bufpos.inc()
      if c.lexer.buf[c.lexer.bufpos] == '\'': c.content.add('\'')
      else: break
    of EndOfFile: raise c.lexer.generateError("Unfinished single quoted string")
    of '\l', '\c', '\t', ' ':
      var newlines = 1
      c.processQuotedWhitespace(newlines)
      continue
    else: c.content.add(c.lexer.buf[c.lexer.bufpos])
    c.lexer.bufpos.inc()

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

proc plainScalar(c: ParserContext, context: static[YamlContext])
    {.raises: [].} =
  debug("lex: plainScalar")
  c.content.add(c.lexer.buf[c.lexer.bufpos])
  block outer:
    while true:
      c.lexer.bufpos.inc()
      let ch = c.lexer.buf[c.lexer.bufpos]
      case ch
      of ' ', '\t':
        c.after.setLen(1)
        c.after[0] = ch
        while true:
          c.lexer.bufpos.inc()
          let ch2 = c.lexer.buf[c.lexer.bufpos]
          case ch2
          of ' ', '\t': c.after.add(ch2)
          of lineEnd: break outer
          of ':':
            if c.lexer.isPlainSafe(c.lexer.bufpos + 1, context):
              c.content.add(c.after & ':')
              break
            else: break outer
          of '#': break outer
          of flowIndicators:
            if context == cBlock:
              c.content.add(c.after)
              c.content.add(ch2)
              break
            else: break outer
          else:
            c.content.add(c.after)
            c.content.add(ch2)
            break
      of flowIndicators:
        when context == cFlow: break
        else: c.content.add(ch)
      of lineEnd: break
      of ':':
        if c.lexer.isPlainSafe(c.lexer.bufpos + 1, context): c.content.add(':')
        else: break outer
      else: c.content.add(ch)
  debug("lex: \"" & c.content & '\"')

proc continueMultilineScalar(c: ParserContext) {.raises: [].} =
  c.content.add(if c.newlines == 1: " " else: repeat('\l', c.newlines - 1))
  c.startToken()
  c.plainScalar(cBlock)
  
template startScalar(t: ScalarType) {.dirty.} =
  c.newlines = 0
  c.level.kind = fplScalar
  c.scalarType = t
  
proc blockScalarHeader(c: ParserContext): bool =
  debug("lex: blockScalarHeader")
  c.chomp = ctClip
  c.level.indentation = UnknownIndentation
  if c.tag == yTagQuestionMark: c.tag = yTagExclamationMark
  let t = if c.lexer.buf[c.lexer.bufpos] == '|': stLiteral else: stFolded
  while true:
    c.lexer.bufpos.inc()
    case c.lexer.buf[c.lexer.bufpos]
    of '+':
      if c.chomp != ctClip:
        raise c.lexer.generateError("Only one chomping indicator is allowed")
      c.chomp = ctKeep
    of '-':
      if c.chomp != ctClip:
        raise c.lexer.generateError("Only one chomping indicator is allowed")
      c.chomp = ctStrip
    of '1'..'9':
      if c.level.indentation != UnknownIndentation:
        raise c.lexer.generateError("Only one p.indentation indicator is allowed")
      c.level.indentation = c.ancestry[c.ancestry.high].indentation +
          ord(c.lexer.buf[c.lexer.bufpos]) - ord('\x30')
    of spaceOrLineEnd: break
    else:
      raise c.lexer.generateError(
          "Illegal character in block scalar header: '" &
          c.lexer.buf[c.lexer.bufpos] & "'")
  c.recentWasMoreIndented = false
  c.lineEnding()
  result = c.handleLineEnd(true)
  if not result:
    startScalar(t)
    c.content.reset()

proc blockScalarLine(c: ParserContext):
    bool {.raises: [YamlParserError].} =
  debug("lex: blockScalarLine")
  result = false
  if c.level.indentation == UnknownIndentation:
    if c.lexer.buf[c.lexer.bufpos] in lineEnd:
      return c.handleLineEnd(true)
    else:
      c.level.indentation = c.indentation
      c.content.addMultiple('\l', c.newlines)
  elif c.indentation > c.level.indentation or
      c.lexer.buf[c.lexer.bufpos] == '\t':
    c.content.addMultiple('\l', c.newlines)
    c.recentWasMoreIndented = true
    c.content.addMultiple(' ', c.indentation - c.level.indentation)
  elif c.scalarType == stFolded:
    if c.recentWasMoreIndented:
      c.recentWasMoreIndented = false
      c.newlines.inc()
    if c.newlines == 0: discard
    elif c.newlines == 1: c.content.add(' ')
    else: c.content.addMultiple('\l', c.newlines - 1)    
  else: c.content.addMultiple('\l', c.newlines)
  c.newlines = 0
  while c.lexer.buf[c.lexer.bufpos] notin lineEnd:
    c.content.add(c.lexer.buf[c.lexer.bufpos])
    c.lexer.bufpos.inc()
  result = c.handleLineEnd(true)

proc tagHandle(c: ParserContext, shorthandEnd: var int)
    {.raises: [YamlParserError].} =
  debug("lex: tagHandle")
  shorthandEnd = 0
  c.content.add(c.lexer.buf[c.lexer.bufpos])
  var i = 0
  while true:
    c.lexer.bufpos.inc()
    i.inc()
    let ch = c.lexer.buf[c.lexer.bufpos]
    case ch
    of spaceOrLineEnd:
      if shorthandEnd == -1:
        raise c.lexer.generateError("Unclosed verbatim tag")
      break
    of '!':
      if shorthandEnd == -1 and i == 2:
        c.content.add(ch)
        continue
      elif shorthandEnd != 0:
        raise c.lexer.generateError("Illegal character in tag suffix")
      shorthandEnd = i
      c.content.add(ch)
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@', '&',
       '-', '=', '+', '$', '_', '.', '~', '*', '\'', '(', ')':
      c.content.add(ch)
    of ',':
      if shortHandEnd > 0: break # ',' after shorthand is flow indicator
      c.content.add(ch)
    of '<':
      if i == 1:
        shorthandEnd = -1
        c.content.reset()
      else: raise c.lexer.generateError("Illegal character in tag handle")
    of '>':
      if shorthandEnd == -1:
        c.lexer.bufpos.inc()
        if c.lexer.buf[c.lexer.bufpos] notin spaceOrLineEnd:
          raise c.lexer.generateError("Missing space after verbatim tag handle")
        break
      else: raise c.lexer.generateError("Illegal character in tag handle")
    of '%':
      if shorthandEnd != 0: c.content.add(c.lexer.byteSequence())
      else: raise c.lexer.generateError("Illegal character in tag handle")
    else: raise c.lexer.generateError("Illegal character in tag handle")

proc handleTagHandle(c: ParserContext) {.raises: [YamlParserError].} =
  c.startToken()
  if c.level.kind != fplUnknown: raise c.generateError("Unexpected tag handle")
  if c.tag != yTagQuestionMark:
    raise c.generateError("Only one tag handle is allowed per node")
  c.content.reset()
  var
    shorthandEnd: int
  c.tagHandle(shorthandEnd)
  if shorthandEnd != -1:
    try:
      c.tagUri.reset()
      c.tagUri.add(c.shorthands[c.content[0..shorthandEnd]])
      c.tagUri.add(c.content[shorthandEnd + 1 .. ^1])
    except KeyError:
      raise c.generateError(
          "Undefined tag shorthand: " & c.content[0..shorthandEnd])
    try: c.tag = c.p.tagLib.tags[c.tagUri]
    except KeyError: c.tag = c.p.tagLib.registerUri(c.tagUri)
  else:
    try: c.tag = c.p.tagLib.tags[c.content]
    except KeyError: c.tag = c.p.tagLib.registerUri(c.content)

proc consumeLineIfEmpty(c: ParserContext, newlines: var int): bool =
  result = true
  while true:
    c.lexer.bufpos.inc()
    case c.lexer.buf[c.lexer.bufpos]
    of ' ', '\t': discard
    of '\l':
      c.lexer.lexLF()
      break
    of '\c':
      c.lexer.lexCR()
      break
    of '#', EndOfFile:
      c.lineEnding()
      discard c.handleLineEnd(true)
      break
    else:
      result = false
      break

proc handlePossibleMapStart(c: ParserContext, e: var YamlStreamEvent,
    flow: bool = false, single: bool = false): bool =
  result = false
  if c.level.indentation == UnknownIndentation:
    var flowDepth = 0
    var pos = c.lexer.bufpos
    var recentJsonStyle = false
    while pos < c.lexer.bufpos + 1024:
      case c.lexer.buf[pos]
      of ':':
        if flowDepth == 0 and (c.lexer.buf[pos + 1] in spaceOrLineEnd or
            recentJsonStyle):
          e = c.objectStart(yamlStartMap, single)
          result = true
          break
      of lineEnd: break
      of '[', '{': flowDepth.inc()
      of '}', ']':
        flowDepth.inc(-1)
        if flowDepth < 0: break
      of '?', ',':
        if flowDepth == 0: break
      of '#':
        if c.lexer.buf[pos - 1] in space: break
      of '"':
        pos.inc()
        while c.lexer.buf[pos] notin {'"', EndOfFile, '\l', '\c'}:
          if c.lexer.buf[pos] == '\\': pos.inc()
          pos.inc()
        if c.lexer.buf[pos] != '"': break
      of '\'':
        pos.inc()
        while c.lexer.buf[pos] notin {'\'', '\l', '\c', EndOfFile}:
          pos.inc()
      of '&', '*', '!':
        if pos == c.lexer.bufpos or c.lexer.buf[c.lexer.bufpos] in space:
          pos.inc()
          while c.lexer.buf[pos] notin spaceOrLineEnd:
            pos.inc()
          continue
      else: discard
      if flow and c.lexer.buf[pos] notin space:
        recentJsonStyle = c.lexer.buf[pos] in {']', '}', '\'', '"'}
      pos.inc()
    if c.level.indentation == UnknownIndentation:
      c.level.indentation = c.indentation

proc handleMapKeyIndicator(c: ParserContext, e: var YamlStreamEvent): bool =
  result = false
  c.startToken()
  case c.level.kind
  of fplUnknown:
    e = c.objectStart(yamlStartMap)
    result = true
  of fplMapValue:
    if c.level.indentation != c.indentation:
      raise c.generateError("Invalid p.indentation of map key indicator")
    e = scalarEvent("", yTagQuestionMark, yAnchorNone)
    result = true
    c.level.kind = fplMapKey
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
  of fplMapKey:
    if c.level.indentation != c.indentation:
      raise c.generateError("Invalid p.indentation of map key indicator")
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
  of fplSequence:
    raise c.generateError("Unexpected map key indicator (expected '- ')")
  of fplScalar:
    raise c.generateError(
        "Unexpected map key indicator (expected multiline scalar end)")
  of fplSinglePairKey, fplSinglePairValue, fplDocument:
    internalError("Unexpected level kind: " & $c.level.kind)
  c.lexer.skipWhitespace()
  c.indentation = c.lexer.getColNumber(c.lexer.bufpos)

proc handleBlockSequenceIndicator(c: ParserContext, e: var YamlStreamEvent):
    bool =
  result = false
  c.startToken()
  case c.level.kind
  of fplUnknown: 
    e = c.objectStart(yamlStartSeq)
    result = true
  of fplSequence:
    if c.level.indentation != c.indentation:
      raise c.generateError("Invalid p.indentation of block sequence indicator")
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
  else: raise c.generateError("Illegal sequence item in map")
  c.lexer.skipWhitespace()
  c.indentation = c.lexer.getColNumber(c.lexer.bufpos)

proc handleBlockItemStart(c: ParserContext, e: var YamlStreamEvent): bool =
  result = false
  case c.level.kind
  of fplUnknown:
    result = c.handlePossibleMapStart(e)
  of fplSequence:
    raise c.generateError(
        "Unexpected token (expected block sequence indicator)")
  of fplMapKey:
    c.ancestry.add(c.level)
    c.level = FastParseLevel(kind: fplUnknown, indentation: c.indentation)
  of fplMapValue:
    e = emptyScalar(c)
    result = true
    c.level.kind = fplMapKey
    c.ancestry.add(c.level)
    c.level = FastParseLevel(kind: fplUnknown, indentation: c.indentation)
  of fplScalar, fplSinglePairKey, fplSinglePairValue, fplDocument:
    internalError("Unexpected level kind: " & $c.level.kind)

proc handleFlowItemStart(c: ParserContext, e: var YamlStreamEvent): bool =
  if c.level.kind == fplUnknown and
      c.ancestry[c.ancestry.high].kind == fplSequence:
    result = c.handlePossibleMapStart(e, true, true)

proc handleFlowPlainScalar(c: ParserContext, e: var YamlStreamEvent) =
  c.content.reset()
  c.startToken()
  c.plainScalar(cFlow)
  if c.lexer.buf[c.lexer.bufpos] in {'{', '}', '[', ']', ',', ':', '#'}:
    discard
  else:
    c.newlines = 0
    while true:
      case c.lexer.buf[c.lexer.bufpos]
      of ':':
        if c.lexer.isPlainSafe(c.lexer.bufpos + 1, cFlow):
          if c.newlines == 1:
            c.content.add(' ')
            c.newlines = 0
          elif c.newlines > 1:
            c.content.addMultiple(' ', c.newlines - 1)
            c.newlines = 0
          c.plainScalar(cFlow)
        break
      of '#', EndOfFile: break
      of '\l':
        c.lexer.bufpos = c.lexer.handleLF(c.lexer.bufpos)
        c.newlines.inc()
      of '\c':
        c.lexer.bufpos = c.lexer.handleCR(c.lexer.bufpos)
        c.newlines.inc()
      of flowIndicators: break
      of ' ', '\t': c.lexer.skipWhitespace()
      else:
        if c.newlines == 1:
          c.content.add(' ')
          c.newlines = 0
        elif c.newlines > 1:
          c.content.addMultiple(' ', c.newlines - 1)
          c.newlines = 0
        c.plainScalar(cFlow)
  e = c.currentScalar()

# --- macros for defining parser states ---

macro parserStates(names: varargs[untyped]): stmt =
  ## generates proc declaration for each state in list like this:
  ## 
  ## proc name(s: YamlStream, e: var YamlStreamEvent):
  ##     bool {.raises: [YamlParserError].}
  result = newStmtList()
  for name in names:
    let nameId = newIdentNode("state" & strutils.capitalize($name.ident))
    result.add(newProc(nameId, [ident("bool"), newIdentDefs(ident("s"),
        ident("YamlStream")), newIdentDefs(ident("e"), newNimNode(nnkVarTy).add(
            ident("YamlStreamEvent")))], newEmptyNode()))
    result[0][4] = newNimNode(nnkPragma).add(newNimNode(nnkExprColonExpr).add(
        ident("raises"), newNimNode(nnkBracket).add(ident("YamlParserError"))))

proc processStateAsgns(source, target: NimNode) {.compileTime.} =
  ## copies children of source to target and replaces all assignments
  ## `state = [name]` with the appropriate code for changing states.
  for child in source.children:
    if child.kind == nnkAsgn and child[0].kind == nnkIdent:
      if $child[0].ident == "state":
        assert child[1].kind == nnkIdent
        var newNameId: NimNode
        if child[1].kind == nnkIdent and $child[1].ident == "stored":
          newNameId = newDotExpr(ident("c"), ident("storedState"))
        else:
          newNameId =
              newIdentNode("state" & strutils.capitalize($child[1].ident))
        target.add(newAssignment(newDotExpr(
            newIdentNode("s"), newIdentNode("nextImpl")), newNameId))
        continue
      elif $child[0].ident == "stored":
        assert child[1].kind == nnkIdent
        let newNameId =
            newIdentNode("state" & strutils.capitalize($child[1].ident))
        target.add(newAssignment(newDotExpr(newIdentNode("c"),
            newIdentNode("storedState")), newNameId))
        continue
    var processed = copyNimNode(child)
    processStateAsgns(child, processed)
    target.add(processed)

macro parserState(name: untyped, impl: untyped): stmt =
  ## Creates a parser state. Every parser state is a proc with the signature
  ##
  ## proc(s: YamlStream, e: var YamlStreamEvent):
  ##     bool {.raises: [YamlParserError].}
  ##
  ## The proc name will be prefixed with "state" and the original name will be
  ## capitalized, so a state "foo" will yield a proc named "stateFoo".
  ##
  ## Inside the proc, you have access to the ParserContext with the let variable
  ## `c`. You can change the parser state by a assignment `state = [newState]`.
  ## The [newState] must have been declared with states(...) previously.
  let
    nameStr = $name.ident
    nameId = newIdentNode("state" & strutils.capitalize(nameStr))
  var procImpl = quote do:
    debug("state: " & `nameStr`)
  procImpl.add(newLetStmt(ident("c"), newCall("ParserContext", ident("s"))))
  procImpl.add(newAssignment(newIdentNode("result"), newLit(false)))
  assert impl.kind == nnkStmtList
  processStateAsgns(impl, procImpl)
  result = newProc(nameId, [ident("bool"),
      newIdentDefs(ident("s"), ident("YamlStream")), newIdentDefs(ident("e"),
      newNimNode(nnkVarTy).add(ident("YamlStreamEvent")))], procImpl)

# --- parser states ---

parserStates(initial, blockObjectStart, blockAfterPlainScalar, blockAfterObject,
             scalarEnd, objectEnd, expectDocEnd, startDoc, afterDocument,
             closeStream, closeMoreIndentedLevels, emitEmptyScalar, tagHandle,
             anchor, alias, flow, leaveFlowMap, leaveFlowSeq, flowAfterObject,
             leaveFlowSinglePairMap)

proc closeEverything(c: ParserContext) =
  c.indentation = -1
  c.nextImpl = stateCloseMoreIndentedLevels
  c.atSequenceItem = false

proc endLevel(c: ParserContext, e: var YamlStreamEvent):
    LevelEndResult =
  result = lerOne
  case c.level.kind
  of fplSequence:
    e = endSeqEvent()
  of fplMapKey:
    e = endMapEvent()
  of fplMapValue, fplSinglePairValue:
    e = emptyScalar(c)
    c.level.kind = fplMapKey
    result = lerAdditionalMapEnd
  of fplScalar:
    if c.scalarType != stFlow:
      case c.chomp
      of ctKeep:
        if c.content.len == 0: c.newlines.inc(-1)
        c.content.addMultiple('\l', c.newlines)
      of ctClip:
        if c.content.len != 0:
          debug("adding clipped newline")
          c.content.add('\l')
      of ctStrip: discard
    e = currentScalar(c)
    c.tag = yTagQuestionMark
    c.anchor = yAnchorNone
  of fplUnknown:
    if c.ancestry.len > 1:
      e = emptyScalar(c) # don't yield scalar for empty doc
    else:
      result = lerNothing
  of fplDocument:
    e = endDocEvent()
  of fplSinglePairKey:
    internalError("Unexpected level kind: " & $c.level.kind)

proc handleMapValueIndicator(c: ParserContext, e: var YamlStreamEvent): bool =
  c.startToken()
  case c.level.kind
  of fplUnknown:
    if c.level.indentation == UnknownIndentation:
      e = c.objectStart(yamlStartMap)
      result = true
      c.storedState = c.nextImpl
      c.nextImpl = stateEmitEmptyScalar
    else:
      e = emptyScalar(c)
      result = true
    c.ancestry[c.ancestry.high].kind = fplMapValue
  of fplMapKey:
    if c.level.indentation != c.indentation:
      raise c.generateError("Invalid p.indentation of map key indicator")
    e = scalarEvent("", yTagQuestionMark, yAnchorNone)
    result = true
    c.level.kind = fplMapValue
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
  of fplMapValue:
    if c.level.indentation != c.indentation:
      raise c.generateError("Invalid p.indentation of map key indicator")
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
  of fplSequence:
    raise c.generateError("Unexpected map value indicator (expected '- ')")
  of fplScalar:
    raise c.generateError(
        "Unexpected map value indicator (expected multiline scalar end)")
  of fplSinglePairKey, fplSinglePairValue, fplDocument:
    internalError("Unexpected level kind: " & $c.level.kind)
  c.lexer.skipWhitespace()
  c.indentation = c.lexer.getColNumber(c.lexer.bufpos)

template handleObjectEnd(c: ParserContext, mayHaveEmptyValue: bool = false):
    bool =
  var result = false
  c.level = c.ancestry.pop()
  when mayHaveEmptyValue:
    if c.level.kind == fplSinglePairValue:
      result = true
      c.level = c.ancestry.pop()
  case c.level.kind
  of fplMapKey: c.level.kind = fplMapValue
  of fplSinglePairKey: c.level.kind = fplSinglePairValue
  of fplMapValue: c.level.kind = fplMapKey
  of fplSequence, fplDocument: discard
  of fplUnknown, fplScalar, fplSinglePairValue:
    internalError("Unexpected level kind: " & $c.level.kind)
  result

proc leaveFlowLevel(c: ParserContext, e: var YamlStreamEvent): bool =
  c.flowdepth.dec()
  result = (c.endLevel(e) == lerOne) # lerAdditionalMapEnd cannot happen
  if c.flowdepth == 0:
    c.storedState = stateBlockAfterObject
  else:
    c.storedState = stateFlowAfterObject
  c.nextImpl = stateObjectEnd

parserState initial:
  case c.lexer.buf[c.lexer.bufpos]
  of '%':
    var ld: LexedDirective
    c.startToken()
    c.lexer.directiveName(ld)
    case ld
    of ldYaml:
      var version = ""
      c.startToken()
      c.lexer.yamlVersion(version)
      if version != "1.2":
        c.callCallback("Version is not 1.2, but " & version)
      c.lineEnding()
      discard c.handleLineEnd(true)
    of ldTag:
      var shorthand = ""
      c.tagUri.reset()
      c.startToken()
      c.lexer.tagShorthand(shorthand)
      c.lexer.tagUriMapping(c.tagUri)
      c.shorthands[shorthand] = c.tagUri
      c.lineEnding()
      discard c.handleLineEnd(true)
    of ldUnknown:
      c.callCallback("Unknown directive")
      c.lexer.finishLine()
      discard c.handleLineEnd(true)
  of ' ', '\t':
    if not c.consumeLineIfEmpty(c.newlines):
      c.indentation = c.lexer.getColNumber(c.lexer.bufpos)
      e = startDocEvent()
      result = true
      state = blockObjectStart
  of '\l': c.lexer.lexLF()
  of '\c': c.lexer.lexCR()
  of EndOfFile: c.isFinished = true
  of '#':
    c.lineEnding()
    discard c.handleLineEnd(true)
  of '-':
    var success: bool
    c.startToken()
    c.lexer.directivesEndMarker(success)
    if success: c.lexer.bufpos.inc(3)
    e = startDocEvent()
    result = true
    state = blockObjectStart
  else:
    e = startDocEvent()
    result = true
    state = blockObjectStart

parserState blockObjectStart:
  c.lexer.skipIndentation()
  c.indentation = c.lexer.getColNumber(c.lexer.bufpos)
  if c.indentation == 0:
    var success: bool
    c.lexer.directivesEndMarker(success)
    if success:
      c.lexer.bufpos.inc(3)
      c.closeEverything()
      stored = startDoc
      return false
    c.lexer.documentEndMarker(success)
    if success:
      c.closeEverything()
      c.lexer.bufpos.inc(3)
      c.lineEnding()
      discard c.handleLineEnd(false)
      stored = afterDocument
      return false
  if c.atSequenceItem: c.atSequenceItem = false
  elif c.indentation <= c.ancestry[c.ancestry.high].indentation:
    if c.lexer.buf[c.lexer.bufpos] in lineEnd:
      if c.handleLineEnd(true):
        c.closeEverything()
        stored = afterDocument
      return false
    elif c.lexer.buf[c.lexer.bufpos] == '#':
      c.lineEnding()
      if c.handleLineEnd(true):
        c.closeEverything()
        stored = afterDocument
      return false
    else:
      c.atSequenceItem = c.lexer.buf[c.lexer.bufpos] == '-' and
          not c.lexer.isPlainSafe(c.lexer.bufpos + 1, cBlock)
      state = closeMoreIndentedLevels
      stored = blockObjectStart
      return false
  elif c.indentation <= c.level.indentation and
      c.lexer.buf[c.lexer.bufpos] in lineEnd:
    if c.handleLineEnd(true):
      c.closeEverything()
      stored = afterDocument
    return false
  if c.level.kind == fplScalar and c.scalarType != stFlow:
    if c.indentation < c.level.indentation:
      if c.lexer.buf[c.lexer.bufpos] == '#':
        # skip all following comment lines
        while c.indentation > c.ancestry[c.ancestry.high].indentation:
          c.lineEnding()
          if c.handleLineEnd(false):
            c.closeEverything()
            stored = afterDocument
            return false
          c.lexer.skipIndentation()
          c.indentation = c.lexer.getColNumber(c.lexer.bufpos)
        if c.indentation > c.ancestry[c.ancestry.high].indentation:
          raise c.lexer.generateError(
              "Invalid content in block scalar after comments")
        state = closeMoreIndentedLevels
        stored = blockObjectStart
        return false
      else:
        raise c.lexer.generateError(
            "Invalid p.indentation (expected p.indentation of at least " &
            $c.level.indentation & " spaces)")
    if c.blockScalarLine():
      c.closeEverything()
      stored = afterDocument
    return false
  case c.lexer.buf[c.lexer.bufpos]
  of '\l':
    c.lexer.lexLF()
    c.newlines.inc()
    if c.level.kind == fplUnknown:
      c.level.indentation = UnknownIndentation
  of '\c':
    c.lexer.lexCR()
    c.newlines.inc()
    if c.level.kind == fplUnknown:
      c.level.indentation = UnknownIndentation
  of EndOfFile:
    c.closeEverything()
    stored = afterDocument
  of '#':
    c.lineEnding()
    if c.handleLineEnd(true):
      c.closeEverything()
      stored = afterDocument
    if c.level.kind == fplUnknown:
      c.level.indentation = UnknownIndentation
  of ':':
    if c.lexer.isPlainSafe(c.lexer.bufpos + 1, cBlock):
      if c.level.kind == fplScalar:
        c.continueMultilineScalar()
        state = blockAfterPlainScalar
      else:
        result = c.handleBlockItemStart(e)
        c.content.reset()
        c.startToken()
        c.plainScalar(cBlock)
        state = blockAfterPlainScalar
    else:
      c.lexer.bufpos.inc()
      result = c.handleMapValueIndicator(e)
  of '\t':
    if c.level.kind == fplScalar:
      c.lexer.skipWhitespace()
      c.continueMultilineScalar()
      state = blockAfterPlainScalar
    else: raise c.lexer.generateError("\\t cannot start any token")
  else:
    if c.level.kind == fplScalar:
      c.continueMultilineScalar()
      state = blockAfterPlainScalar
    else:
      case c.lexer.buf[c.lexer.bufpos]
      of '\'':
        result = c.handleBlockItemStart(e)
        c.content.reset()
        c.startToken()
        c.singleQuotedScalar()
        state = scalarEnd
      of '"':
        result = c.handleBlockItemStart(e)
        c.content.reset()
        c.startToken()
        c.doubleQuotedScalar()
        state = scalarEnd
      of '|', '>':
        if c.blockScalarHeader():
          c.closeEverything()
          stored = afterDocument
      of '-':
        if c.lexer.isPlainSafe(c.lexer.bufpos + 1, cBlock):
          result = c.handleBlockItemStart(e)
          c.content.reset()
          c.startToken()
          c.plainScalar(cBlock)
          state = blockAfterPlainScalar
        else:
          c.lexer.bufpos.inc()
          result = c.handleBlockSequenceIndicator(e)
      of '!':
        result = c.handleBlockItemStart(e)
        state = tagHandle
        stored = blockObjectStart
      of '&':
        result = c.handleBlockItemStart(e)
        state = anchor
        stored = blockObjectStart
      of '*':
        result = c.handleBlockItemStart(e)
        state = alias
        stored = blockAfterObject
      of '[', '{':
        result = c.handleBlockItemStart(e)
        state = flow
      of '?':
        if c.lexer.isPlainSafe(c.lexer.bufpos + 1, cBlock):
          result = c.handleBlockItemStart(e)
          c.content.reset()
          c.startToken()
          c.plainScalar(cBlock)
          state = blockAfterPlainScalar
        else:
          c.lexer.bufpos.inc()
          result = c.handleMapKeyIndicator(e)
      of '@', '`':
        raise c.lexer.generateError(
            "Reserved characters cannot start a plain scalar")
      else:
        result = c.handleBlockItemStart(e)
        c.content.reset()
        c.startToken()
        c.plainScalar(cBlock)
        state = blockAfterPlainScalar

parserState scalarEnd:
  if c.tag == yTagQuestionMark: c.tag = yTagExclamationMark
  e = c.currentScalar()
  result = true
  state = objectEnd
  stored = blockAfterObject

parserState blockAfterPlainScalar:
  c.lexer.skipWhitespace()
  case c.lexer.buf[c.lexer.bufpos]
  of '\l':
    if c.level.kind notin {fplUnknown, fplScalar}:
      c.startToken()
      raise c.generateError("Unexpected scalar")
    startScalar(stFlow)
    c.lexer.lexLF()
    c.newlines.inc()
    state = blockObjectStart
  of '\c':
    if c.level.kind notin {fplUnknown, fplScalar}:
      c.startToken()
      raise c.generateError("Unexpected scalar")
    startScalar(stFlow)
    c.lexer.lexCR()
    c.newlines.inc()
    state = blockObjectStart
  else:
    e = c.currentScalar()
    result = true
    state = objectEnd
    stored = blockAfterObject

parserState blockAfterObject:
  c.lexer.skipWhitespace()
  case c.lexer.buf[c.lexer.bufpos]
  of EndOfFile:
    c.closeEverything()
    stored = afterDocument
  of '\l':
    state = blockObjectStart
    c.lexer.lexLF()
  of '\c':
    state = blockObjectStart
    c.lexer.lexCR()
  of ':':
    case c.level.kind
    of fplUnknown:
      e = c.objectStart(yamlStartMap)
      result = true
    of fplMapKey:
      e = scalarEvent("", yTagQuestionMark, yAnchorNone)
      result = true
      c.level.kind = fplMapValue
      c.ancestry.add(c.level)
      c.level = initLevel(fplUnknown)
    of fplMapValue:
      c.level.kind = fplMapValue
      c.ancestry.add(c.level)
      c.level = initLevel(fplUnknown)
    of fplSequence:
      c.startToken()
      raise c.generateError("Illegal token (expected sequence item)")
    of fplScalar:
      c.startToken()
      raise c.generateError(
          "Multiline scalars may not be implicit map keys")
    of fplSinglePairKey, fplSinglePairValue, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.lexer.bufpos.inc()
    c.lexer.skipWhitespace()
    c.indentation = c.lexer.getColNumber(c.lexer.bufpos)
    state = blockObjectStart
  of '#':
    c.lineEnding()
    if c.handleLineEnd(true):
      c.closeEverything()
      stored = afterDocument
    else: state = blockObjectStart
  else:
    c.startToken()
    raise c.generateError(
        "Illegal token (expected ':', comment or line end)")

parserState objectEnd:
  if c.handleObjectEnd(true):
    e = endMapEvent()
    result = true
  if c.level.kind == fplDocument: state = expectDocEnd
  else: state = stored

parserState expectDocEnd:
  case c.lexer.buf[c.lexer.bufpos]
  of '-':
    var success: bool
    c.lexer.directivesEndMarker(success)
    if success:
      c.lexer.bufpos.inc(3)
      e = endDocEvent()
      result = true
      state = startDoc
      c.ancestry.setLen(0)
    else:
      raise c.generateError("Unexpected content (expected document end)")
  of '.':
    var isDocumentEnd: bool
    c.startToken()
    c.lexer.documentEndMarker(isDocumentEnd)
    if isDocumentEnd:
      c.lexer.bufpos.inc(3)
      c.lineEnding()
      discard c.handleLineEnd(true)
      e = endDocEvent()
      result = true
      state = afterDocument
    else:
      raise c.generateError("Unexpected content (expected document end)")
  of ' ', '\t', '#':
    c.lineEnding()
    if c.handleLineEnd(true):
      c.closeEverything()
      stored = afterDocument
  of '\l': c.lexer.lexLF()
  of '\c': c.lexer.lexCR()
  of EndOfFile:
    e = endDocEvent()
    result = true
    c.isFinished = true
  else:
    c.startToken()
    raise c.generateError("Unexpected content (expected document end)")

parserState startDoc:
  c.initDocValues()
  e = startDocEvent()
  result = true
  state = blockObjectStart

parserState afterDocument:
  case c.lexer.buf[c.lexer.bufpos]
  of '.':
    var isDocumentEnd: bool
    c.startToken()
    c.lexer.documentEndMarker(isDocumentEnd)
    if isDocumentEnd:
      c.lexer.bufpos.inc(3)
      c.lineEnding()
      discard c.handleLineEnd(true)
    else:
      c.initDocValues()
      e = startDocEvent()
      result = true
      state = blockObjectStart
  of '#':
    c.lineEnding()
    discard c.handleLineEnd(true)
  of '\t', ' ':
    if not c.consumeLineIfEmpty(c.newlines):
      c.indentation = c.lexer.getColNumber(c.lexer.bufpos)
      c.initDocValues()
      e = startDocEvent()
      result = true
      state = blockObjectStart
  of EndOfFile: c.isFinished = true
  else:
    c.initDocValues()
    state = initial

parserState closeStream:
  case c.level.kind
  of fplUnknown: discard c.ancestry.pop()
  of fplDocument: discard
  else:
    case c.endLevel(e)
    of lerNothing: discard
    of lerOne: result = true
    of lerAdditionalMapEnd: return true
    c.level = c.ancestry.pop()
    if result: return
  e = endDocEvent()
  result = true
  c.isFinished = true

parserState closeMoreIndentedLevels:
  if c.ancestry.len > 0:
    let parent = c.ancestry[c.ancestry.high]
    if parent.indentation >= c.indentation:
      if c.atSequenceItem:
        if (c.indentation == c.level.indentation and
            c.level.kind == fplSequence) or
           (c.indentation == parent.indentation and
            c.level.kind == fplUnknown and parent.kind != fplSequence):
          state = stored
          return false
      debug("Closing because parent.indentation (" & $parent.indentation &
            ") >= indentation(" & $c.indentation & ")")
      case c.endLevel(e)
      of lerNothing: discard
      of lerOne: result = true
      of lerAdditionalMapEnd: return true
      discard c.handleObjectEnd(false)
      return result
    if c.level.kind == fplDocument: state = expectDocEnd
    else: state = stored
  elif c.indentation == c.level.indentation:
    let res = c.endLevel(e)
    yAssert(res == lerOne)
    result = true
    state = stored
  else:
    state = stored

parserState emitEmptyScalar:
  e = scalarEvent("", yTagQuestionMark, yAnchorNone)
  result = true
  state = stored

parserState tagHandle:
  c.handleTagHandle()
  state = stored

parserState anchor:
  c.handleAnchor()
  state = stored

parserState alias:
  c.startToken()
  if c.level.kind != fplUnknown: raise c.generateError("Unexpected token")
  if c.anchor != yAnchorNone or c.tag != yTagQuestionMark:
    raise c.generateError("Alias may not have anchor or tag")
  c.content.reset()
  c.anchorName()
  var id: AnchorId
  try: id = c.p.anchors[c.content]
  except KeyError: raise c.generateError("Unknown anchor")
  e = aliasEvent(id)
  result = true
  state = objectEnd

parserState flow:
  c.lexer.skipWhitespaceCommentsAndNewlines()
  case c.lexer.buf[c.lexer.bufpos]
  of '{':
    if c.handleFlowItemStart(e): return true
    e = c.objectStart(yamlStartMap)
    result = true
    c.flowdepth.inc()
    c.lexer.bufpos.inc()
    c.explicitFlowKey = false
  of '[':
    if c.handleFlowItemStart(e): return true
    e = c.objectStart(yamlStartSeq)
    result = true
    c.flowdepth.inc()
    c.lexer.bufpos.inc()
  of '}':
    yAssert(c.level.kind == fplUnknown)
    c.level = c.ancestry.pop()
    c.lexer.bufpos.inc()
    state = leaveFlowMap
  of ']':
    yAssert(c.level.kind == fplUnknown)
    c.level = c.ancestry.pop()
    c.lexer.bufpos.inc()
    state = leaveFlowSeq
  of ',':
    yAssert(c.level.kind == fplUnknown)
    c.level = c.ancestry.pop()
    case c.level.kind
    of fplSequence:
      e = c.emptyScalar()
      result = true
    of fplMapValue:
      e = c.emptyScalar()
      result = true
      c.level.kind = fplMapKey
      c.explicitFlowKey = false
    of fplMapKey:
      e = c.emptyScalar()
      c.level.kind = fplMapValue
      return true
    of fplSinglePairValue:
      e = c.emptyScalar()
      result = true
      c.level = c.ancestry.pop()
      state = leaveFlowSinglePairMap
      stored = flow
    of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
    c.lexer.bufpos.inc()
  of ':':
    if c.lexer.isPlainSafe(c.lexer.bufpos + 1, cFlow):
      if c.handleFlowItemStart(e): return true
      c.handleFlowPlainScalar(e)
      result = true
      state = objectEnd
      stored = flowAfterObject
    else:
      c.level = c.ancestry.pop()
      case c.level.kind
      of fplSequence:
        e = startMapEvent(c.tag, c.anchor)
        result = true
        debug("started single-pair map at " &
            (if c.level.indentation == UnknownIndentation:
             $c.indentation else: $c.level.indentation))
        c.tag = yTagQuestionMark
        c.anchor = yAnchorNone
        if c.level.indentation == UnknownIndentation:
          c.level.indentation = c.indentation
        c.ancestry.add(c.level)
        c.level = initLevel(fplSinglePairKey)
      of fplMapValue, fplSinglePairValue:
        c.startToken()
        raise c.generateError("Unexpected token (expected ',')")
      of fplMapKey:
        e = c.emptyScalar()
        result = true
        c.level.kind = fplMapValue
      of fplSinglePairKey:
        e = c.emptyScalar()
        result = true
        c.level.kind = fplSinglePairValue
      of fplUnknown, fplScalar, fplDocument:
        internalError("Unexpected level kind: " & $c.level.kind)
      if c.level.kind != fplSinglePairKey: c.lexer.bufpos.inc()
      c.ancestry.add(c.level)
      c.level = initLevel(fplUnknown)
  of '\'':
    if c.handleFlowItemStart(e): return true
    c.content.reset()
    c.startToken()
    c.singleQuotedScalar()
    if c.tag == yTagQuestionMark: c.tag = yTagExclamationMark
    e = c.currentScalar()
    result = true
    state = objectEnd
    stored = flowAfterObject
  of '"':
    if c.handleFlowItemStart(e): return true
    c.content.reset()
    c.startToken()
    c.doubleQuotedScalar()
    if c.tag == yTagQuestionMark: c.tag = yTagExclamationMark
    e = c.currentScalar()
    result = true
    state = objectEnd
    stored = flowAfterObject
  of '!':
    if c.handleFlowItemStart(e): return true
    c.handleTagHandle()
  of '&':
    if c.handleFlowItemStart(e): return true
    c.handleAnchor()
  of '*':
    state = alias
    stored = flowAfterObject
  of '?':
    if c.lexer.isPlainSafe(c.lexer.bufpos + 1, cFlow):
      if c.handleFlowItemStart(e): return true
      c.handleFlowPlainScalar(e)
      result = true
      state = objectEnd
      stored = flowAfterObject
    elif c.explicitFlowKey:
      c.startToken()
      raise c.generateError("Duplicate '?' in flow mapping")
    elif c.level.kind == fplUnknown:
      case c.ancestry[c.ancestry.high].kind
      of fplMapKey, fplMapValue, fplDocument: discard
      of fplSequence:
        e = c.objectStart(yamlStartMap, true)
        result = true
      else:
        c.startToken()
        raise c.generateError("Unexpected token")
      c.explicitFlowKey = true
      c.lexer.bufpos.inc()
    else:
      c.explicitFlowKey = true
      c.lexer.bufpos.inc()
  else:
    if c.handleFlowItemStart(e): return true
    c.handleFlowPlainScalar(e)
    result = true
    state = objectEnd
    stored = flowAfterObject

parserState leaveFlowMap:
  case c.level.kind
  of fplMapValue:
    e = c.emptyScalar()
    c.level.kind = fplMapKey
    return true
  of fplMapKey:
    if c.tag != yTagQuestionMark or c.anchor != yAnchorNone or
        c.explicitFlowKey:
      e = c.emptyScalar()
      c.level.kind = fplMapValue
      c.explicitFlowKey = false
      return true
  of fplSequence:
    c.startToken()
    raise c.generateError("Unexpected token (expected ']')")
  of fplSinglePairValue:
    c.startToken()
    raise c.generateError("Unexpected token (expected ']')")
  of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
    internalError("Unexpected level kind: " & $c.level.kind)
  result = c.leaveFlowLevel(e)
  
parserState leaveFlowSeq:
  case c.level.kind
  of fplSequence:
    if c.tag != yTagQuestionMark or c.anchor != yAnchorNone:
      e = c.emptyScalar()
      return true
  of fplSinglePairValue:
    e = c.emptyScalar()
    c.level = c.ancestry.pop()
    state = leaveFlowSinglePairMap
    stored = leaveFlowSeq
    return true
  of fplMapKey, fplMapValue:
    c.startToken()
    raise c.generateError("Unexpected token (expected '}')")
  of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
    internalError("Unexpected level kind: " & $c.level.kind)
  result = c.leaveFlowLevel(e)

parserState leaveFlowSinglePairMap:
  e = endMapEvent()
  result = true
  state = stored

parserState flowAfterObject:
  c.lexer.skipWhitespaceCommentsAndNewlines()
  case c.lexer.buf[c.lexer.bufpos]
  of ']':
    case c.level.kind
    of fplSequence: discard
    of fplMapKey, fplMapValue:
      c.startToken()
      raise c.generateError("Unexpected token (expected '}')")
    of fplSinglePairValue:
      c.level = c.ancestry.pop()
      yAssert(c.level.kind == fplSequence)
      e = endMapEvent()
      return true
    of fplScalar, fplUnknown, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.lexer.bufpos.inc()
    result = c.leaveFlowLevel(e)
  of '}':
    case c.level.kind
    of fplMapKey, fplMapValue: discard
    of fplSequence, fplSinglePairValue:
      c.startToken()
      raise c.generateError("Unexpected token (expected ']')")
    of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.lexer.bufpos.inc()
    result = c.leaveFlowLevel(e)
  of ',':
    case c.level.kind
    of fplSequence: discard
    of fplMapValue:
      e = scalarEvent("", yTagQuestionMark, yAnchorNone)
      result = true
      c.level.kind = fplMapKey
      c.explicitFlowKey = false
    of fplSinglePairValue:
      c.level = c.ancestry.pop()
      yAssert(c.level.kind == fplSequence)
      e = endMapEvent()
      result = true
    of fplMapKey: c.explicitFlowKey = false
    of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
    state = flow
    c.lexer.bufpos.inc()
  of ':':
    case c.level.kind
    of fplSequence, fplMapKey:
      c.startToken()
      raise c.generateError("Unexpected token (expected ',')")
    of fplMapValue, fplSinglePairValue: discard
    of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
    state = flow
    c.lexer.bufpos.inc()
  of '#':
    c.lineEnding()
    if c.handleLineEnd(true):
      c.startToken()
      raise c.generateError("Unclosed flow content")
  of EndOfFile:
    c.startToken()
    raise c.generateError("Unclosed flow content")
  else:
    c.startToken()
    raise c.generateError("Unexpected content (expected flow indicator)")

# --- parser initialization ---

proc parse*(p: YamlParser, s: Stream): YamlStream =
  result = new(ParserContext)
  let c = ParserContext(result)
  c.content = ""
  c.after = ""
  c.tagUri = ""
  c.ancestry = newSeq[FastParseLevel]()
  c.p = p
  try: p.lexer.open(s)
  except:
    let e = newException(YamlParserError,
        "Error while opening stream: " & getCurrentExceptionMsg())
    e.parent = getCurrentException()
    e.line = 1
    e.column = 1
    e.lineContent = ""
    raise e
  c.initDocValues()
  c.atSequenceItem = false
  c.flowdepth = 0
  result.isFinished = false
  result.peeked = false
  result.nextImpl = stateInitial