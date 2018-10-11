#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import lexbase, streams, strutils, unicode
when defined(yamlDebug):
  import terminal
  export terminal

when defined(yamlScalarRepInd):
  type ScalarKind* = enum
    skSingleQuoted, skDoubleQuoted, skLiteral, skFolded

type
  StringSource* = object
    src: string
    pos: int
    line, lineStart: int

  SourceProvider* = concept c
    advance(c) is char
    lexCR(c)
    lexLF(c)

  YamlLexerObj* = object
    cur*: LexerToken
    curStartPos*: tuple[line, column: int]
    # ltScalarPart, ltQuotedScalar, ltYamlVersion, ltTagShorthand, ltTagUri,
    # ltLiteralTag, ltTagHandle, ltAnchor, ltAlias
    buf*: string
    # ltIndentation
    indentation*: int
    # ltTagHandle
    shorthandEnd*: int
    when defined(yamlScalarRepInd):
      # ltQuotedScalar, ltBlockScalarHeader
      scalarKind*: ScalarKind

    # may be modified from outside; will be consumed at plain scalar starts
    newlines*: int

    # internals
    when defined(JS): sSource: StringSource
    else: source: pointer
    inFlow: bool
    literalEndIndent: int
    nextState, lineStartState, inlineState, insideLineImpl, insideDocImpl,
        insideFlowImpl, outsideDocImpl: LexerState
    blockScalarIndent: int
    folded: bool
    chomp: ChompType
    c: char
    tokenLineGetter: proc(lex: YamlLexer, pos: tuple[line, column: int],
                          marker: bool): string {.raises: [].}
    searchColonImpl: proc(lex: YamlLexer): bool

  YamlLexer* = ref YamlLexerObj

  YamlLexerError* = object of Exception
    line*, column*: int
    lineContent*: string

  LexerState = proc(lex: YamlLexer): bool {.raises: YamlLexerError, locks: 0,
      gcSafe.}

  LexerToken* = enum
    ltYamlDirective, ltYamlVersion, ltTagDirective, ltTagShorthand,
    ltTagUri, ltUnknownDirective, ltUnknownDirectiveParams, ltEmptyLine,
    ltDirectivesEnd, ltDocumentEnd, ltStreamEnd, ltIndentation, ltQuotedScalar,
    ltScalarPart, ltBlockScalarHeader, ltBlockScalar, ltSeqItemInd, ltMapKeyInd,
    ltMapValInd, ltBraceOpen, ltBraceClose, ltBracketOpen, ltBracketClose,
    ltComma, ltLiteralTag, ltTagHandle, ltAnchor, ltAlias

  ChompType* = enum
    ctKeep, ctClip, ctStrip

# consts

const
  space          = {' ', '\t'}
  lineEnd        = {'\l', '\c', EndOfFile}
  spaceOrLineEnd = {' ', '\t', '\l', '\c', EndOfFile}
  digits         = {'0'..'9'}
  flowIndicators = {'[', ']', '{', '}', ','}
  uriChars       = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':',
      '@', '&', '-', '=', '+', '$', '_', '.', '~', '*', '\'', '(', ')'}

  UTF8NextLine           = toUTF8(0x85.Rune)
  UTF8NonBreakingSpace   = toUTF8(0xA0.Rune)
  UTF8LineSeparator      = toUTF8(0x2028.Rune)
  UTF8ParagraphSeparator = toUTF8(0x2029.Rune)

  UnknownIndentation* = int.low

# lexer backend implementations

template blSource(lex: YamlLexer): var BaseLexer =
  (cast[ptr BaseLexer](lex.source))[]
template sSource(lex: YamlLexer): var StringSource =
  (cast[ptr StringSource](lex.source))[]

proc advance(lex: YamlLexer, t: typedesc[BaseLexer], step: int = 1) {.inline.} =
  lex.blSource.bufpos.inc(step)
  lex.c = lex.blSource.buf[lex.blSource.bufpos]

proc advance(lex: YamlLexer, t: typedesc[StringSource], step: int = 1)
    {.inline.} =
  lex.sSource.pos.inc(step)
  if lex.sSource.pos >= lex.sSource.src.len: lex.c = EndOfFile
  else: lex.c = lex.sSource.src[lex.sSource.pos]

template lexCR(lex: YamlLexer, t: typedesc[BaseLexer]) =
  try: lex.blSource.bufpos = lex.blSource.handleCR(lex.blSource.bufpos)
  except:
    var e = generateError[T](lex, "Encountered stream error: " &
        getCurrentExceptionMsg())
    e.parent = getCurrentException()
    raise e
  lex.c = lex.blSource.buf[lex.blSource.bufpos]

template lexCR(lex: YamlLexer, t: typedesc[StringSource]) =
  lex.sSource.pos.inc()
  if lex.sSource.src[lex.sSource.pos] == '\l': lex.sSource.pos.inc()
  lex.sSource.lineStart = lex.sSource.pos
  lex.sSource.line.inc()
  lex.c = lex.sSource.src[lex.sSource.pos]

template lexLF(lex: YamlLexer, t: typedesc[BaseLexer]) =
  try: lex.blSource.bufpos = lex.blSource.handleLF(lex.blSource.bufpos)
  except:
    var e = generateError[T](lex, "Encountered stream error: " &
        getCurrentExceptionMsg())
    e.parent = getCurrentException()
    raise e
  lex.c = lex.blSource.buf[lex.blSource.bufpos]

template lexLF(lex: YamlLexer, t: typedesc[StringSource]) =
  lex.sSource.pos.inc()
  lex.sSource.lineStart = lex.sSource.pos
  lex.sSource.line.inc()
  lex.c = lex.sSource.src[lex.sSource.pos]

template lineNumber(lex: YamlLexer, t: typedesc[BaseLexer]): int =
  lex.blSource.lineNumber

template lineNumber(lex: YamlLexer, t: typedesc[StringSource]): int =
  lex.sSource.line

template columnNumber(lex: YamlLexer, t: typedesc[BaseLexer]): int =
  lex.blSource.getColNumber(lex.blSource.bufpos) + 1

template columnNumber(lex: YamlLexer, t: typedesc[StringSource]): int =
  lex.sSource.pos - lex.sSource.lineStart + 1

template currentLine(lex: YamlLexer, t: typedesc[BaseLexer]): string =
  lex.blSource.getCurrentLine(true)

template currentLine(lex: YamlLexer, t: typedesc[StringSource]): string =
  var result = ""
  var i = lex.sSource.lineStart
  while lex.sSource.src[i] notin lineEnd:
    result.add(lex.sSource.src[i])
    inc(i)
  result.add("\n" & spaces(lex.columnNumber(t) - 1) & "^\n")
  result

proc nextIsPlainSafe(lex: YamlLexer, t: typedesc[BaseLexer], inFlow: bool):
    bool {.inline.} =
  case lex.blSource.buf[lex.blSource.bufpos + 1]
  of spaceOrLineEnd: result = false
  of flowIndicators: result = not inFlow
  else: result = true

proc nextIsPlainSafe(lex: YamlLexer, t: typedesc[StringSource],
    inFlow: bool): bool {.inline.} =
  case lex.sSource.src[lex.sSource.pos + 1]
  of spaceOrLineEnd: result = false
  of flowIndicators: result = not inFlow
  else: result = true

proc getPos(lex: YamlLexer, t: typedesc[BaseLexer]): int = lex.blSource.bufpos
proc getPos(lex: YamlLexer, t: typedesc[StringSource]): int = lex.sSource.pos

proc at(lex: YamlLexer, t: typedesc[BaseLexer], pos: int): char {.inline.} =
  lex.blSource.buf[pos]

proc at(lex: YamlLexer, t: typedesc[StringSource], pos: int): char {.inline.} =
  lex.sSource.src[pos]

proc mark(lex: YamlLexer, t: typedesc[BaseLexer]): int = lex.blSource.bufpos
proc mark(lex: YamlLexer, t: typedesc[StringSource]): int = lex.sSource.pos

proc afterMark(lex: YamlLexer, t: typedesc[BaseLexer], m: int): int {.inline.} =
  lex.blSource.bufpos - m

proc afterMark(lex: YamlLexer, t: typedesc[StringSource], m: int):
    int {.inline.} =
  lex.sSource.pos - m

proc lineWithMarker(lex: YamlLexer, pos: tuple[line, column: int],
    t: typedesc[BaseLexer], marker: bool): string =
  if pos.line == lex.blSource.lineNumber:
    result = lex.blSource.getCurrentLine(false)
    if marker: result.add(spaces(pos.column - 1) & "^\n")
  else: result = ""

proc lineWithMarker(lex: YamlLexer, pos: tuple[line, column: int],
    t: typedesc[StringSource], marker: bool): string =
  var
    lineStartIndex = lex.sSource.pos
    lineEndIndex: int
    curLine = lex.sSource.line
  if pos.line == curLine:
    lineEndIndex = lex.sSource.pos
    while lex.sSource.src[lineEndIndex] notin lineEnd: inc(lineEndIndex)
  while true:
    while lineStartIndex >= 0 and lex.sSource.src[lineStartIndex] notin lineEnd:
      dec(lineStartIndex)
    if curLine == pos.line:
      inc(lineStartIndex)
      break
    let wasLF = lex.sSource.src[lineStartIndex] == '\l'
    lineEndIndex = lineStartIndex
    dec(lineStartIndex)
    if lex.sSource.src[lineStartIndex] == '\c' and wasLF:
      dec(lineStartIndex)
      dec(lineEndIndex)
    dec(curLine)
  result = lex.sSource.src.substr(lineStartIndex, lineEndIndex - 1) & "\n"
  if marker: result.add(spaces(pos.column - 1) & "^\n")

# lexer states

{.push gcSafe, locks: 0.}
# `raises` cannot be pushed.
proc outsideDoc[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc yamlVersion[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc tagShorthand[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc tagUri[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc unknownDirParams[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc expectLineEnd[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc possibleDirectivesEnd[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc possibleDocumentEnd[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc afterSeqInd[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc insideDoc[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc insideFlow[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc insideLine[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc plainScalarPart[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc blockScalarHeader[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc blockScalar[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc indentationAfterBlockScalar[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc dirEndAfterBlockScalar[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc docEndAfterBlockScalar[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc tagHandle[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc anchor[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc alias[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
proc streamEnd[T](lex: YamlLexer): bool {.raises: YamlLexerError.}
{.pop.}

# implementation

template debug(message: string) {.dirty.} =
  when defined(yamlDebug):
    try: styledWriteLine(stdout, fgBlue, message)
    except IOError: discard

proc generateError[T](lex: YamlLexer, message: string):
    ref YamlLexerError {.raises: [].} =
  result = newException(YamlLexerError, message)
  result.line = lex.lineNumber(T)
  result.column = lex.columnNumber(T)
  result.lineContent = lex.currentLine(T)

proc startToken[T](lex: YamlLexer) {.inline.} =
  lex.curStartPos = (lex.lineNumber(T), lex.columnNumber(T))

proc directiveName[T](lex: YamlLexer) =
  while lex.c notin spaceOrLineEnd:
    lex.buf.add(lex.c)
    lex.advance(T)

proc consumeNewlines(lex: YamlLexer) {.inline, raises: [].} =
  case lex.newlines
  of 0: return
  of 1: lex.buf.add(' ')
  else: lex.buf.add(repeat('\l', lex.newlines - 1))
  lex.newlines = 0

proc yamlVersion[T](lex: YamlLexer): bool =
  debug("lex: yamlVersion")
  while lex.c in space: lex.advance(T)
  if lex.c notin digits:
    raise generateError[T](lex, "Invalid YAML version number")
  startToken[T](lex)
  lex.buf.add(lex.c)
  lex.advance(T)
  while lex.c in digits:
    lex.buf.add(lex.c)
    lex.advance(T)
  if lex.c != '.': raise generateError[T](lex, "Invalid YAML version number")
  lex.buf.add('.')
  lex.advance(T)
  if lex.c notin digits:
    raise generateError[T](lex, "Invalid YAML version number")
  lex.buf.add(lex.c)
  lex.advance(T)
  while lex.c in digits:
    lex.buf.add(lex.c)
    lex.advance(T)
  if lex.c notin spaceOrLineEnd:
    raise generateError[T](lex, "Invalid YAML version number")
  lex.cur = ltYamlVersion
  result = true
  lex.nextState = expectLineEnd[T]

proc tagShorthand[T](lex: YamlLexer): bool =
  debug("lex: tagShorthand")
  while lex.c in space: lex.advance(T)
  if lex.c != '!':
    raise generateError[T](lex, "Tag shorthand must start with a '!'")
  startToken[T](lex)
  lex.buf.add(lex.c)
  lex.advance(T)

  if lex.c in spaceOrLineEnd: discard
  else:
    while lex.c != '!':
      case lex.c
      of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-':
        lex.buf.add(lex.c)
        lex.advance(T)
      else: raise generateError[T](lex, "Illegal character in tag shorthand")
    lex.buf.add(lex.c)
    lex.advance(T)
  if lex.c notin spaceOrLineEnd:
    raise generateError[T](lex, "Missing space after tag shorthand")
  lex.cur = ltTagShorthand
  result = true
  lex.nextState = tagUri[T]

proc tagUri[T](lex: YamlLexer): bool =
  debug("lex: tagUri")
  while lex.c in space: lex.advance(T)
  startToken[T](lex)
  if lex.c == '!':
    lex.buf.add(lex.c)
    lex.advance(T)
  while true:
    case lex.c
    of  spaceOrLineEnd: break
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@', '&',
       '-', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')':
      lex.buf.add(lex.c)
      lex.advance(T)
    else: raise generateError[T](lex, "Invalid character in tag uri: " &
        escape("" & lex.c))
  lex.cur = ltTagUri
  result = true
  lex.nextState = expectLineEnd[T]

proc unknownDirParams[T](lex: YamlLexer): bool =
  debug("lex: unknownDirParams")
  while lex.c in space: lex.advance(T)
  startToken[T](lex)
  while lex.c notin lineEnd + {'#'}:
    lex.buf.add(lex.c)
    lex.advance(T)
  lex.cur = ltUnknownDirectiveParams
  result = true
  lex.nextState = expectLineEnd[T]

proc expectLineEnd[T](lex: YamlLexer): bool =
  debug("lex: expectLineEnd")
  result = false
  while lex.c in space: lex.advance(T)
  while true:
    case lex.c
    of '#':
      lex.advance(T)
      while lex.c notin lineEnd: lex.advance(T)
    of EndOfFile:
      lex.nextState = streamEnd[T]
      break
    of '\l':
      lex.lexLF(T)
      lex.nextState = lex.lineStartState
      break
    of '\c':
      lex.lexCR(T)
      lex.nextState = lex.lineStartState
      break
    else:
      raise generateError[T](lex,
          "Unexpected character (expected line end): " & escape("" & lex.c))

proc possibleDirectivesEnd[T](lex: YamlLexer): bool =
  debug("lex: possibleDirectivesEnd")
  lex.indentation = 0
  lex.lineStartState = lex.insideDocImpl  # could be insideDoc[T]
  lex.advance(T)
  if lex.c == '-':
    lex.advance(T)
    if lex.c == '-':
      lex.advance(T)
      if lex.c in spaceOrLineEnd:
        lex.cur = ltDirectivesEnd
        while lex.c in space: lex.advance(T)
        lex.nextState = lex.insideLineImpl
        return true
      lex.consumeNewlines()
      lex.buf.add('-')
    else: lex.consumeNewlines()
    lex.buf.add('-')
  elif lex.c in spaceOrLineEnd:
    lex.cur = ltIndentation
    lex.nextState = afterSeqInd[T]
    return true
  else: lex.consumeNewlines()
  lex.buf.add('-')
  lex.cur = ltIndentation
  lex.nextState = plainScalarPart[T]
  result = true

proc afterSeqInd[T](lex: YamlLexer): bool =
  result = true
  lex.cur = ltSeqItemInd
  if lex.c notin lineEnd:
    lex.advance(T)
    while lex.c in space: lex.advance(T)
  lex.nextState = lex.insideLineImpl

proc possibleDocumentEnd[T](lex: YamlLexer): bool =
  debug("lex: possibleDocumentEnd")
  lex.advance(T)
  if lex.c == '.':
    lex.advance(T)
    if lex.c == '.':
      lex.advance(T)
      if lex.c in spaceOrLineEnd:
        lex.cur = ltDocumentEnd
        lex.nextState = expectLineEnd[T]
        lex.lineStartState = lex.outsideDocImpl
        return true
      lex.consumeNewlines()
      lex.buf.add('.')
    else: lex.consumeNewlines()
    lex.buf.add('.')
  else: lex.consumeNewlines()
  lex.buf.add('.')
  lex.nextState = plainScalarPart[T]
  result = false

proc outsideDoc[T](lex: YamlLexer): bool =
  debug("lex: outsideDoc")
  startToken[T](lex)
  case lex.c
  of '%':
    lex.advance(T)
    directiveName[T](lex)
    case lex.buf
    of "YAML":
      lex.cur = ltYamlDirective
      lex.buf.setLen(0)
      lex.nextState = yamlVersion[T]
    of "TAG":
      lex.buf.setLen(0)
      lex.cur = ltTagDirective
      lex.nextState = tagShorthand[T]
    else:
      lex.cur = ltUnknownDirective
      lex.nextState = unknownDirParams[T]
    return true
  of '-':
    lex.nextState = possibleDirectivesEnd[T]
    return false
  of '.':
    lex.indentation = 0
    if possibleDocumentEnd[T](lex): return true
  of spaceOrLineEnd + {'#'}:
    lex.indentation = 0
    while lex.c == ' ':
      lex.indentation.inc()
      lex.advance(T)
    if lex.c in spaceOrLineEnd + {'#'}:
      lex.nextState = expectLineEnd[T]
      return false
    lex.nextState = insideLine[T]
  else:
    lex.indentation = 0
    lex.nextState = insideLine[T]
  lex.lineStartState = insideDoc[T]
  lex.cur = ltIndentation
  result = true

proc insideDoc[T](lex: YamlLexer): bool =
  debug("lex: insideDoc")
  startToken[T](lex)
  lex.indentation = 0
  case lex.c
  of '-':
    lex.nextState = possibleDirectivesEnd[T]
    return false
  of '.': lex.nextState = possibleDocumentEnd[T]
  of spaceOrLineEnd:
    while lex.c == ' ':
      lex.indentation.inc()
      lex.advance(T)
    while lex.c in space: lex.advance(T)
    case lex.c
    of lineEnd:
      lex.cur = ltEmptyLine
      lex.nextState = expectLineEnd[T]
      return true
    else:
      lex.nextState = lex.inlineState
  else: lex.nextState = lex.inlineState
  lex.cur = ltIndentation
  result = true

proc insideFlow[T](lex: YamlLexer): bool =
  debug("lex: insideFlow")
  startToken[T](lex)
  while lex.c in space: lex.advance(T)
  if lex.c in lineEnd + {'#'}:
    lex.cur = ltEmptyLine
    lex.nextState = expectLineEnd[T]
    return true
  lex.nextState = insideLine[T]
  result = false

proc possibleIndicatorChar[T](lex: YamlLexer, indicator: LexerToken,
    jsonContext: bool = false): bool =
  startToken[T](lex)
  if not(jsonContext) and lex.nextIsPlainSafe(T, lex.inFlow):
    lex.consumeNewlines()
    lex.nextState = plainScalarPart[T]
    result = false
  else:
    lex.cur = indicator
    result = true
    lex.advance(T)
    while lex.c in space: lex.advance(T)
    if lex.c in lineEnd:
      lex.nextState = expectLineEnd[T]

proc flowIndicator[T](lex: YamlLexer, indicator: LexerToken): bool {.inline.} =
  startToken[T](lex)
  lex.cur = indicator
  lex.advance(T)
  while lex.c in space: lex.advance(T)
  if lex.c in lineEnd + {'#'}:
    lex.nextState = expectLineEnd[T]
  result = true

proc addMultiple(s: var string, c: char, num: int) {.raises: [], inline.} =
  for i in 1..num: s.add(c)

proc processQuotedWhitespace[T](lex: YamlLexer, newlines: var int) =
  block outer:
    let beforeSpace = lex.buf.len
    while true:
      case lex.c
      of ' ', '\t': lex.buf.add(lex.c)
      of '\l':
        lex.lexLF(T)
        break
      of '\c':
        lex.lexCR(T)
        break
      else: break outer
      lex.advance(T)
    lex.buf.setLen(beforeSpace)
    while true:
      case lex.c
      of ' ', '\t': discard
      of '\l':
        lex.lexLF(T)
        newlines.inc()
        continue
      of '\c':
        lex.lexCR(T)
        newlines.inc()
        continue
      else:
        if newlines == 0: discard
        elif newlines == 1: lex.buf.add(' ')
        else: lex.buf.addMultiple('\l', newlines - 1)
        break
      lex.advance(T)

proc singleQuotedScalar[T](lex: YamlLexer) =
  debug("lex: singleQuotedScalar")
  startToken[T](lex)
  when defined(yamlScalarRepInd): lex.scalarKind = skSingleQuoted
  lex.advance(T)
  while true:
    case lex.c
    of '\'':
      lex.advance(T)
      if lex.c == '\'': lex.buf.add('\'')
      else: break
    of EndOfFile: raise generateError[T](lex, "Unfinished single quoted string")
    of '\l', '\c', '\t', ' ':
      var newlines = 1
      processQuotedWhitespace[T](lex, newlines)
      continue
    else: lex.buf.add(lex.c)
    lex.advance(T)
  while lex.c in space: lex.advance(T)
  if lex.c in lineEnd + {'#'}:
    lex.nextState = expectLineEnd[T]

proc unicodeSequence[T](lex: YamlLexer, length: int) =
  debug("lex: unicodeSequence")
  var unicodeChar = 0.int
  for i in countup(0, length - 1):
    lex.advance(T)
    let digitPosition = length - i - 1
    case lex.c
    of EndOFFile, '\l', '\c':
      raise generateError[T](lex, "Unfinished unicode escape sequence")
    of '0' .. '9':
      unicodeChar = unicodechar or (int(lex.c) - 0x30) shl (digitPosition * 4)
    of 'A' .. 'F':
      unicodeChar = unicodechar or (int(lex.c) - 0x37) shl (digitPosition * 4)
    of 'a' .. 'f':
      unicodeChar = unicodechar or (int(lex.c) - 0x57) shl (digitPosition * 4)
    else:
      raise generateError[T](lex,
          "Invalid character in unicode escape sequence: " &
          escape("" & lex.c))
  lex.buf.add(toUTF8(Rune(unicodeChar)))

proc doubleQuotedScalar[T](lex: YamlLexer) =
  debug("lex: doubleQuotedScalar")
  startToken[T](lex)
  when defined(yamlScalarRepInd): lex.scalarKind = skDoubleQuoted
  lex.advance(T)
  while true:
    case lex.c
    of EndOfFile:
      raise generateError[T](lex, "Unfinished double quoted string")
    of '\\':
      lex.advance(T)
      case lex.c
      of EndOfFile:
        raise generateError[T](lex, "Unfinished escape sequence")
      of '0':       lex.buf.add('\0')
      of 'a':       lex.buf.add('\x07')
      of 'b':       lex.buf.add('\x08')
      of '\t', 't': lex.buf.add('\t')
      of 'n':       lex.buf.add('\l')
      of 'v':       lex.buf.add('\v')
      of 'f':       lex.buf.add('\f')
      of 'r':       lex.buf.add('\c')
      of 'e':       lex.buf.add('\e')
      of ' ':       lex.buf.add(' ')
      of '"':       lex.buf.add('"')
      of '/':       lex.buf.add('/')
      of '\\':      lex.buf.add('\\')
      of 'N':       lex.buf.add(UTF8NextLine)
      of '_':       lex.buf.add(UTF8NonBreakingSpace)
      of 'L':       lex.buf.add(UTF8LineSeparator)
      of 'P':       lex.buf.add(UTF8ParagraphSeparator)
      of 'x':       unicodeSequence[T](lex, 2)
      of 'u':       unicodeSequence[T](lex, 4)
      of 'U':       unicodeSequence[T](lex, 8)
      of '\l', '\c':
        var newlines = 0
        processQuotedWhitespace[T](lex, newlines)
        continue
      else: raise generateError[T](lex, "Illegal character in escape sequence")
    of '"':
      lex.advance(T)
      break
    of '\l', '\c', '\t', ' ':
      var newlines = 1
      processQuotedWhitespace[T](lex, newlines)
      continue
    else: lex.buf.add(lex.c)
    lex.advance(T)
  while lex.c in space: lex.advance(T)
  if lex.c in lineEnd + {'#'}:
    lex.nextState = expectLineEnd[T]

proc insideLine[T](lex: YamlLexer): bool =
  debug("lex: insideLine")
  case lex.c
  of ':':
    result = possibleIndicatorChar[T](lex, ltMapValInd,
        lex.inFlow and
        lex.cur in [ltBraceClose, ltBracketClose, ltQuotedScalar])
  of '?': result = possibleIndicatorChar[T](lex, ltMapKeyInd)
  of '-': result = possibleIndicatorChar[T](lex, ltSeqItemInd)
  of lineEnd + {'#'}:
    result = false
    lex.nextState = expectLineEnd[T]
  of '\"':
    doubleQuotedScalar[T](lex)
    lex.cur = ltQuotedScalar
    result = true
  of '\'':
    singleQuotedScalar[T](lex)
    lex.cur = ltQuotedScalar
    result = true
  of '>', '|':
    startToken[T](lex)
    lex.consumeNewlines()
    if lex.inFlow: lex.nextState = plainScalarPart[T]
    else: lex.nextState = blockScalarHeader[T]
    result = false
  of '{': result = flowIndicator[T](lex, ltBraceOpen)
  of '}': result = flowIndicator[T](lex, ltBraceClose)
  of '[': result = flowIndicator[T](lex, ltBracketOpen)
  of ']': result = flowIndicator[T](lex, ltBracketClose)
  of ',': result = flowIndicator[T](lex, ltComma)
  of '!':
    lex.nextState = tagHandle[T]
    result = false
  of '&':
    lex.nextState = anchor[T]
    result = false
  of '*':
    lex.nextState = alias[T]
    result = false
  of '@', '`':
    raise generateError[T](lex,
        "Reserved characters cannot start a plain scalar")
  else:
    startToken[T](lex)
    lex.consumeNewlines()
    lex.nextState = plainScalarPart[T]
    result = false

proc plainScalarPart[T](lex: YamlLexer): bool =
  debug("lex: plainScalarPart")
  block outer:
    while true:
      lex.buf.add(lex.c)
      lex.advance(T)
      case lex.c
      of space:
        let lenBeforeSpace = lex.buf.len()
        while true:
          lex.buf.add(lex.c)
          lex.advance(T)
          case lex.c
          of lineEnd + {'#'}:
            lex.buf.setLen(lenBeforeSpace)
            lex.nextState = expectLineEnd[T]
            break outer
          of ':':
            if lex.nextIsPlainSafe(T, lex.inFlow): break
            else:
              lex.buf.setLen(lenBeforeSpace)
              lex.nextState = lex.insideLineImpl # could be insideLine[T]
              break outer
          of flowIndicators:
            if lex.inFlow:
              lex.buf.setLen(lenBeforeSpace)
              lex.nextState = lex.insideLineImpl # could be insideLine[T]
              break outer
            else:
              lex.buf.add(lex.c)
              lex.advance(T)
              break
          of space: discard
          else: break
      of lineEnd:
        lex.nextState = expectLineEnd[T]
        break
      of flowIndicators:
        if lex.inFlow:
          lex.nextState = lex.insideLineImpl # could be insideLine[T]
          break
      of ':':
        if not lex.nextIsPlainSafe(T, lex.inFlow):
          lex.nextState = lex.insideLineImpl # could be insideLine[T]
          break outer
      else: discard
  lex.cur = ltScalarPart
  result = true

proc blockScalarHeader[T](lex: YamlLexer): bool =
  debug("lex: blockScalarHeader")
  lex.chomp = ctClip
  lex.blockScalarIndent = UnknownIndentation
  lex.folded = lex.c == '>'
  when defined(yamlScalarRepInd):
    lex.scalarKind = if lex.folded: skFolded else: skLiteral
  startToken[T](lex)
  while true:
    lex.advance(T)
    case lex.c
    of '+':
      if lex.chomp != ctClip:
        raise generateError[T](lex, "Only one chomping indicator is allowed")
      lex.chomp = ctKeep
    of '-':
      if lex.chomp != ctClip:
        raise generateError[T](lex, "Only one chomping indicator is allowed")
      lex.chomp = ctStrip
    of '1'..'9':
      if lex.blockScalarIndent != UnknownIndentation:
        raise generateError[T](lex, "Only one indentation indicator is allowed")
      lex.blockScalarIndent = ord(lex.c) - ord('\x30')
    of spaceOrLineEnd: break
    else:
      raise generateError[T](lex,
          "Illegal character in block scalar header: '" & escape("" & lex.c) &
          '\'')
  lex.nextState = expectLineEnd[T]
  lex.lineStartState = blockScalar[T]
  lex.cur = ltBlockScalarHeader
  result = true

proc blockScalarAfterLineStart[T](lex: YamlLexer,
    recentWasMoreIndented: var bool): bool =
  if lex.indentation < lex.blockScalarIndent:
    lex.nextState = indentationAfterBlockScalar[T]
    return false

  if lex.folded and not recentWasMoreIndented: lex.consumeNewlines()
  else:
    recentWasMoreIndented = false
    lex.buf.add(repeat('\l', lex.newlines))
    lex.newlines = 0
  result = true

proc blockScalarLineStart[T](lex: YamlLexer, recentWasMoreIndented: var bool):
    bool =
  while true:
    case lex.c
    of '-':
      if lex.indentation < lex.blockScalarIndent:
        lex.nextState = indentationAfterBlockScalar[T]
        return false
      discard possibleDirectivesEnd[T](lex)
      case lex.cur
      of ltDirectivesEnd:
        lex.nextState = dirEndAfterBlockScalar[T]
        return false
      of ltIndentation:
        if lex.nextState == afterSeqInd[T]:
          lex.consumeNewlines()
          lex.buf.add("- ")
      else: discard
      break
    of '.':
      if lex.indentation < lex.blockScalarIndent:
        lex.nextState = indentationAfterBlockScalar[T]
        return false
      if possibleDocumentEnd[T](lex):
        lex.nextState = docEndAfterBlockScalar[T]
        return false
      break
    of spaceOrLineEnd:
      while lex.c == ' ' and lex.indentation < lex.blockScalarIndent:
        lex.indentation.inc()
        lex.advance(T)
      case lex.c
      of '\l':
        lex.newlines.inc()
        lex.lexLF(T)
        lex.indentation = 0
      of '\c':
        lex.newlines.inc()
        lex.lexCR(T)
        lex.indentation = 0
      of EndOfFile:
        lex.nextState = streamEnd[T]
        return false
      of ' ', '\t':
        recentWasMoreIndented = true
        lex.buf.add(repeat('\l', lex.newlines))
        lex.newlines = 0
        return true
      else: break
    else: break
  result = blockScalarAfterLineStart[T](lex, recentWasMoreIndented)

proc blockScalar[T](lex: YamlLexer): bool =
  debug("lex: blockScalar")
  block outer:
    var recentWasMoreIndented = true
    if lex.blockScalarIndent == UnknownIndentation:
      while true:
        lex.blockScalarIndent = 0
        while lex.c == ' ':
          lex.blockScalarIndent.inc()
          lex.advance(T)
        case lex.c
        of '\l':
          lex.lexLF(T)
          lex.newlines.inc()
        of '\c':
          lex.lexCR(T)
          lex.newlines.inc()
        of EndOfFile:
          lex.nextState = streamEnd[T]
          break outer
        else:
          if lex.blockScalarIndent <= lex.indentation:
            lex.indentation = lex.blockScalarIndent
            lex.nextState = indentationAfterBlockScalar[T]
            break outer
          lex.indentation = lex.blockScalarIndent
          break
    else:
      lex.blockScalarIndent += lex.indentation
      lex.indentation = 0
    if lex.c notin {'.', '-'} or lex.indentation == 0:
      if not blockScalarLineStart[T](lex, recentWasMoreIndented): break outer
    else:
      if not blockScalarAfterLineStart[T](lex, recentWasMoreIndented):
        break outer
    while true:
      while lex.c notin lineEnd:
        lex.buf.add(lex.c)
        lex.advance(T)
      if not blockScalarLineStart[T](lex, recentWasMoreIndented): break outer

  debug("lex: leaving block scalar at indentation " & $lex.indentation)
  case lex.chomp
  of ctStrip: discard
  of ctClip:
    if lex.buf.len > 0: lex.buf.add('\l')
  of ctKeep: lex.buf.add(repeat('\l', lex.newlines))
  lex.newlines = 0
  lex.lineStartState = insideDoc[T]
  lex.cur = ltBlockScalar
  result = true

proc indentationAfterBlockScalar[T](lex: YamlLexer): bool =
  if lex.indentation == 0:
    lex.nextState = lex.insideDocImpl
  elif lex.c == '#':
    lex.nextState = expectLineEnd[T]
    result = false
  else:
    lex.cur = ltIndentation
    result = true
    lex.nextState = lex.insideLineImpl

proc dirEndAfterBlockScalar[T](lex: YamlLexer): bool =
  lex.cur = ltDirectivesEnd
  while lex.c in space: lex.advance(T)
  lex.nextState = lex.insideLineImpl
  result = true

proc docEndAfterBlockScalar[T](lex: YamlLexer): bool =
  lex.cur = ltDocumentEnd
  lex.nextState = expectLineEnd[T]
  lex.lineStartState = lex.outsideDocImpl
  result = true

proc byteSequence[T](lex: YamlLexer) =
  debug("lex: byteSequence")
  var charCode = 0.int8
  for i in 0 .. 1:
    lex.advance(T)
    let digitPosition = int8(1 - i)
    case lex.c
    of EndOfFile, '\l', 'r':
      raise generateError[T](lex, "Unfinished octet escape sequence")
    of '0' .. '9':
      charCode = charCode or (int8(lex.c) - 0x30.int8) shl (digitPosition * 4)
    of 'A' .. 'F':
      charCode = charCode or (int8(lex.c) - 0x37.int8) shl (digitPosition * 4)
    of 'a' .. 'f':
      charCode = charCode or (int8(lex.c) - 0x57.int8) shl (digitPosition * 4)
    else:
      raise generateError[T](lex, "Invalid character in octet escape sequence")
  lex.buf.add(char(charCode))

proc tagHandle[T](lex: YamlLexer): bool =
  debug("lex: tagHandle")
  startToken[T](lex)
  lex.advance(T)
  if lex.c == '<':
    lex.advance(T)
    if lex.c == '!':
      lex.buf.add('!')
      lex.advance(T)
    while true:
      case lex.c
      of spaceOrLineEnd: raise generateError[T](lex, "Unclosed verbatim tag")
      of '%': byteSequence[T](lex)
      of uriChars + {','}: lex.buf.add(lex.c)
      of '>': break
      else: raise generateError[T](lex, "Illegal character in verbatim tag")
      lex.advance(T)
    lex.advance(T)
    lex.cur = ltLiteralTag
  else:
    lex.shorthandEnd = 0
    let m = lex.mark(T)
    lex.buf.add('!')
    while true:
      case lex.c
      of spaceOrLineEnd: break
      of '!':
        if lex.shorthandEnd != 0:
          raise generateError[T](lex, "Illegal character in tag suffix")
        lex.shorthandEnd = lex.afterMark(T, m) + 1
        lex.buf.add('!')
      of ',':
        if lex.shorthandEnd > 0: break # ',' after shorthand is flow indicator
        lex.buf.add(',')
      of '%':
        if lex.shorthandEnd == 0:
          raise generateError[T](lex, "Illegal character in tag handle")
        byteSequence[T](lex)
      of uriChars: lex.buf.add(lex.c)
      else: raise generateError[T](lex, "Illegal character in tag handle")
      lex.advance(T)
    lex.cur = ltTagHandle
  while lex.c in space: lex.advance(T)
  if lex.c in lineEnd: lex.nextState = expectLineEnd[T]
  else: lex.nextState = lex.insideLineImpl # could be insideLine[T]
  result = true

proc anchorName[T](lex: YamlLexer) =
  debug("lex: anchorName")
  startToken[T](lex)
  while true:
    lex.advance(T)
    case lex.c
    of spaceOrLineEnd, '[', ']', '{', '}', ',': break
    else: lex.buf.add(lex.c)
  while lex.c in space: lex.advance(T)
  if lex.c in lineEnd: lex.nextState = expectLineEnd[T]
  else: lex.nextState = lex.insideLineImpl # could be insideLine[T]

proc anchor[T](lex: YamlLexer): bool =
  debug("lex: anchor")
  anchorName[T](lex)
  lex.cur = ltAnchor
  result = true

proc alias[T](lex: YamlLexer): bool =
  debug("lex: alias")
  anchorName[T](lex)
  lex.cur = ltAlias
  result = true

proc streamEnd[T](lex: YamlLexer): bool =
  debug("lex: streamEnd")
  startToken[T](lex)
  lex.cur = ltStreamEnd
  result = true

proc tokenLine[T](lex: YamlLexer, pos: tuple[line, column: int], marker: bool):
    string =
  result = lex.lineWithMarker(pos, T, marker)

proc searchColon[T](lex: YamlLexer): bool =
  var flowDepth = if lex.cur in [ltBraceOpen, ltBracketOpen]: 1 else: 0
  let start = lex.getPos(T)
  var
    peek = start
    recentAllowsAdjacent = lex.cur == ltQuotedScalar
  result = false

  proc skipPlainScalarContent(lex: YamlLexer) {.closure.} =
    while true:
      inc(peek)
      case lex.at(T, peek)
      of ']', '}', ',':
        if flowDepth > 0 or lex.inFlow: break
      of '#':
        if lex.at(T, peek - 1) in space: break
      of ':':
        if lex.at(T, peek + 1) in spaceOrLineEnd: break
      of lineEnd: break
      else: discard

  while peek < start + 1024:
    case lex.at(T, peek)
    of ':':
      if flowDepth == 0:
        if recentAllowsAdjacent or lex.at(T, peek + 1) in spaceOrLineEnd:
          result = true
          break
        lex.skipPlainScalarContent()
        continue
    of '{', '[': inc(flowDepth)
    of '}', ']':
      dec(flowDepth)
      if flowDepth < 0:
        if lex.inFlow: break
        else:
          flowDepth = 0
          lex.skipPlainScalarContent()
          continue
      recentAllowsAdjacent = true
    of lineEnd: break
    of '"':
      while true:
        inc(peek)
        case lex.at(T, peek)
        of lineEnd, '"': break
        of '\\': inc(peek)
        else: discard
      if lex.at(T, peek) != '"': break
      recentAllowsAdjacent = true
    of '\'':
      inc(peek)
      while lex.at(T, peek) notin {'\''} + lineEnd: inc(peek)
      if lex.at(T, peek) != '\'': break
      recentAllowsAdjacent = true
    of '?', ',':
      if flowDepth == 0: break
    of '#':
      if lex.at(T, peek - 1) in space: break
      lex.skipPlainScalarContent()
      continue
    of '&', '*', '!':
      inc(peek)
      while lex.at(T, peek) notin spaceOrLineEnd: inc(peek)
      recentAllowsAdjacent = false
      continue
    of space: discard
    else:
      lex.skipPlainScalarContent()
      continue
    inc(peek)

# interface

proc init*[T](lex: YamlLexer) =
  lex.nextState = outsideDoc[T]
  lex.lineStartState = outsideDoc[T]
  lex.inlineState = insideLine[T]
  lex.insideLineImpl = insideLine[T]
  lex.insideDocImpl = insideDoc[T]
  lex.insideFlowImpl = insideFlow[T]
  lex.outsideDocImpl = outsideDoc[T] # only needed because of compiler checks
  lex.tokenLineGetter = tokenLine[T]
  lex.searchColonImpl = searchColon[T]

when not defined(JS):
  proc newYamlLexer*(source: Stream): YamlLexer {.raises: [YamlLexerError].} =
    let blSource = new(BaseLexer)
    try: blSource[].open(source)
    except:
      var e = newException(YamlLexerError,
          "Could not open stream for reading:\n" & getCurrentExceptionMsg())
      e.parent = getCurrentException()
      raise e
    GC_ref(blSource)
    new(result, proc(x: ref YamlLexerObj) {.nimcall.} =
        GC_unref(cast[ref BaseLexer](x.source))
    )
    result[] = YamlLexerObj(source: cast[pointer](blSource), inFlow: false,
        buf: "", c: blSource[].buf[blSource[].bufpos], newlines: 0,
        folded: true)
    init[BaseLexer](result)

proc newYamlLexer*(source: string, startAt: int = 0): YamlLexer
    {.raises: [].} =
  # append a `\0` at the very end to work around null terminator being
  # inaccessible
  let sourceNull = source & '\0'
  when defined(JS):
    let sSource = StringSource(pos: startAt, lineStart: startAt, line: 1,
                               src: sourceNull)
    result = YamlLexer(buf: "", sSource: sSource,
        inFlow: false, c: sSource.src[startAt], newlines: 0, folded: true)
  else:
    let sSource = new(StringSource)
    sSource[] = StringSource(pos: startAt, lineStart: startAt, line: 1,
                             src: sourceNull)
    GC_ref(sSource)
    new(result, proc(x: ref YamlLexerObj) {.nimcall.} =
        GC_unref(cast[ref StringSource](x.source))
    )
    result[] = YamlLexerObj(buf: "", source: cast[pointer](sSource),
        inFlow: false, c: sSource.src[startAt], newlines: 0, folded: true)
  init[StringSource](result)

proc next*(lex: YamlLexer) =
  while not lex.nextState(lex): discard
  debug("lexer -> " & $lex.cur)

proc setFlow*(lex: YamlLexer, value: bool) =
  lex.inFlow = value
  # in flow mode, no indentation tokens are generated because they are not
  # necessary. actually, the lexer will behave wrongly if we do that, because
  # adjacent values need to check if the preceding token was a JSON value, and
  # if indentation tokens are generated, that information is not available.
  # therefore, we use insideFlow instead of insideDoc in flow mode. another
  # reason is that this would erratically check for document markers (---, ...)
  # which are simply scalars in flow mode.
  if value: lex.lineStartState = lex.insideFlowImpl
  else: lex.lineStartState = lex.insideDocImpl

proc endBlockScalar*(lex: YamlLexer) =
  lex.inlineState = lex.insideLineImpl
  lex.nextState = lex.insideLineImpl
  lex.folded = true

proc getTokenLine*(lex: YamlLexer, marker: bool = true): string =
  result = lex.tokenLineGetter(lex, lex.curStartPos, marker)

proc getTokenLine*(lex: YamlLexer, pos: tuple[line, column: int],
    marker: bool = true): string =
  result = lex.tokenLineGetter(lex, pos, marker)

proc isImplicitKeyStart*(lex: YamlLexer): bool =
  result = lex.searchColonImpl(lex)
