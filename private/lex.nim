#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import lexbase, streams, strutils, unicode

type
  StringSource* = object
    src: string
    pos: int
    line, lineStart: int

  SourceProvider* = concept c
    advance(c) is char
    lexCR(c)
    lexLF(c)

  # YamlLexer*[T: SourceProvider] = ref object # not possible -> compiler bug
  YamlLexer*[T] = ref object
    source: T
    inFlow: bool
    literalEndIndent: int
    nextImpl, stored: LexerState[T]
    buf*: string not nil
    indentation*: int
    c: char
  
  LexerState[T] = proc(lex: YamlLexer[T], t: var LexerToken): bool

  LexerToken* = enum
    ltYamlDirective, ltYamlVersion, ltTagDirective, ltTagShorthand,
    ltTagUrl, ltUnknownDirective, ltUnknownDirectiveParams,
    ltDirectivesEnd, ltDocumentEnd, ltStreamEnd, ltIndentation, ltQuotedScalar,
    ltScalarPart, ltEmptyLine, ltSeqItemInd, ltMapKeyInd, ltMapValInd,
    ltBraceOpen, ltBraceClose, ltBracketOpen, ltBracketClose, ltComma,
    ltLiteralTag, ltTagSuffix, ltAnchor, ltAlias

  YamlLexerError* = object of Exception
    line, column: int
    lineContent: string

# templates

proc advance(lex: YamlLexer[BaseLexer], step: int = 1) {.inline.} =
  lex.source.bufpos.inc(step)
  lex.c = lex.source.buf[lex.source.bufpos]

proc advance(lex: YamlLexer[StringSource], step: int = 1) {.inline.} =
  lex.source.pos.inc(step)
  if lex.source.pos >= lex.source.src.len: lex.c = EndOfFile
  else: lex.c = lex.source.src[lex.source.pos]

# lexer states

proc outsideDoc[T](lex: YamlLexer[T], t: var LexerToken): bool
proc yamlVersion[T](lex: YamlLexer[T], t: var LexerToken): bool
proc tagShorthand[T](lex: YamlLexer[T], t: var LexerToken): bool
proc tagUri[T](lex: YamlLexer[T], t: var LexerToken): bool
proc unknownDirParams[T](lex: YamlLexer[T], t: var LexerToken): bool
proc expectLineEnd[T](lex: YamlLexer[T], t: var LexerToken): bool
proc blockStyle[T](lex: YamlLexer[T], t: var LexerToken): bool {.locks:0.}
proc blockStyleInline[T](lex: YamlLexer[T], t: var LexerToken): bool
proc plainScalarPart[T](lex: YamlLexer[T], t: var LexerToken): bool
proc flowStyle[T](lex: YamlLexer[T], t: var LexerToken): bool
proc streamEnd[T](lex: YamlLexer[T], t: var LexerToken): bool

# interface

proc newYamlLexer*(source: Stream): YamlLexer[BaseLexer] = 
  result = YamlLexer[BaseLexer](source: BaseLexer(), inFlow: false, buf: "")
  result.source.open(source)
  result.c = result.source.buf[result.source.bufpos]

proc newYamlLexer*(source: string, startAt: int = 0):
    YamlLexer[StringSource] =
  result = YamlLexer[StringSource](buf: "", source:
      StringSource(src: source, pos: startAt, lineStart: startAt, line: 1),
      inFlow: false, c: source[startAt])

proc init*[T](lex: YamlLexer[T]) =
  lex.nextImpl = outsideDoc[T]

proc next*(lex: YamlLexer): LexerToken =
  while not lex.nextImpl(lex, result): discard

# implementation

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

template debug(message: string) {.dirty.} =
  when defined(yamlDebug):
    try: styledWriteLine(stdout, fgBlue, message)
    except IOError: discard

template lexCR(lex: YamlLexer[BaseLexer]) =
  lex.source.bufpos = lex.source.handleCR(lex.source.bufpos)
  lex.c = lex.source.buf[lex.source.bufpos]

template lexCR(lex: YamlLexer[StringSource]) =
  lex.source.pos.inc()
  if lex.source.src[lex.source.pos] == '\l': lex.source.pos.inc()
  lex.source.lineStart = lex.source.pos
  lex.source.line.inc()
  lex.c = lex.source.src[lex.source.pos]

template lexLF(lex: YamlLexer[BaseLexer]) =
  lex.source.bufpos = lex.source.handleLF(lex.source.bufpos)
  lex.c = lex.source.buf[lex.source.bufpos]

template lexLF(lex: YamlLexer[StringSource]) =
  lex.source.pos.inc()
  lex.source.lineStart = lex.source.pos
  lex.source.line.inc()
  lex.c = lex.source.src[lex.source.pos]

template lineNumber(lex: YamlLexer[BaseLexer]): int =
  lex.source.lineNumber

template lineNumber(lex: YamlLexer[StringSource]): int =
  lex.source.line

template columnNumber(lex: YamlLexer[BaseLexer]): int =
  lex.source.getColNumber() + 1

template columnNumber(lex: YamlLexer[StringSource]): int =
  lex.source.pos - lex.source.lineStart + 1

template currentLine(lex: YamlLexer[BaseLexer]): string =
  lex.source.getCurrentLine(true)

template currentLine(lex: YamlLexer[StringSource]): string =
  var result = ""
  var i = lex.source.lineStart
  while lex.source.src[i] notin lineEnd:
    result.add(lex.source.src[i])
    inc(i)
  result.add("\n" & spaces(lex.columnNumber) & "^\n")
  result

proc generateError(lex: YamlLexer, message: string):
    ref YamlLexerError {.raises: [].} =
  result = newException(YamlLexerError, message)
  result.line = lex.lineNumber
  result.column = lex.columnNumber
  result.lineContent = lex.currentLine

proc directiveName(lex: YamlLexer) =
  while lex.c notin spaceOrLineEnd:
    lex.buf.add(lex.c)
    lex.advance()

proc yamlVersion[T](lex: YamlLexer[T], t: var LexerToken): bool =
  debug("lex: yamlVersion")
  while lex.c in space: lex.advance()
  if lex.c notin digits: raise lex.generateError("Invalid YAML version number")
  lex.buf.add(lex.c)
  lex.advance()
  while lex.c in digits:
    lex.buf.add(lex.c)
    lex.advance()
  if lex.c != '.': raise lex.generateError("Invalid YAML version number")
  lex.buf.add('.')
  lex.advance()
  if lex.c notin digits: raise lex.generateError("Invalid YAML version number")
  lex.buf.add(lex.c)
  lex.advance()
  while lex.c in digits:
    lex.buf.add(lex.c)
    lex.advance()
  if lex.c notin spaceOrLineEnd:
    raise lex.generateError("Invalid YAML version number")
  t = ltYamlVersion
  result = true
  lex.stored = outsideDoc[T]
  lex.nextImpl = expectLineEnd[T]

template nextIsPlainSafe(lex: YamlLexer[BaseLexer], inFlow: bool): bool =
  case lex.source.buf[lex.source.bufpos + 1]
  of spaceOrLineEnd: result = false
  of flowIndicators: result = not inFlow
  else: result = true

template nextIsPlainSafe(lex: YamlLexer[StringSource], inFlow: bool): bool =
  var result: bool
  case lex.source.src[lex.source.pos + 1]
  of spaceOrLineEnd: result = false
  of flowIndicators: result = not inFlow
  else: result = true
  result

proc tagShorthand[T](lex: YamlLexer[T], t: var LexerToken): bool =
  debug("lex: tagShorthand")
  while lex.c in space: lex.advance()
  if lex.c != '!': raise lex.generateError("Tag shorthand must start with a '!'")
  lex.buf.add(lex.c)
  lex.advance()

  if lex.c in spaceOrLineEnd: discard
  else:
    while lex.c != '!':
      case lex.c
      of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-':
        lex.buf.add(lex.c)
        lex.advance()
      else: raise lex.generateError("Illegal character in tag shorthand")
    lex.buf.add(lex.c)
    lex.advance()
  if lex.c notin spaceOrLineEnd:
    raise lex.generateError("Missing space after tag shorthand")
  lex.nextImpl = tagUri[T]

proc tagUri[T](lex: YamlLexer[T], t: var LexerToken): bool =
  debug("lex: tagUri")
  while lex.c in space: lex.advance()
  if lex.c == '!':
    lex.buf.add(lex.c)
    lex.advance()
  while true:
    case lex.c
    of  spaceOrLineEnd: break
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@', '&',
       '-', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')':
      lex.buf.add(lex.c)
      lex.advance()
    else: raise lex.generateError("Invalid character in tag uri: " &
        escape("" & lex.c))

proc unknownDirParams[T](lex: YamlLexer[T], t: var LexerToken): bool =
  while lex.c notin lineEnd + {'#'}: lex.advance()
  t = ltUnknownDirectiveParams
  result = true
  lex.stored = outsideDoc[T]
  lex.nextImpl = expectLineEnd[T]

proc expectLineEnd[T](lex: YamlLexer[T], t: var LexerToken): bool =
  debug("lex: expectLineEnd")
  result = false
  while lex.c in space: lex.advance()
  while true:
    case lex.c
    of '#':
      lex.advance()
      while lex.c notin lineEnd: lex.advance()
    of EndOfFile:
      lex.nextImpl = streamEnd[T]
      break
    of '\l':
      lex.lexLF()
      lex.nextImpl = lex.stored
      break
    of '\c':
      lex.lexCR()
      lex.nextImpl = lex.stored
      break
    else:
      raise lex.generateError("Unexpected character (expected line end): " &
          escape("" & lex.c))

proc possibleDirectivesEnd[T](lex: YamlLexer[T], t: var LexerToken) =
  lex.advance()
  if lex.c == '-':
    lex.advance()
    if lex.c == '-':
      lex.advance()
      if lex.c in spaceOrLineEnd:
        t = ltDirectivesEnd
        lex.nextImpl = blockStyleInline[T]
        return
      lex.buf.add('-')
    lex.buf.add('-')
  elif lex.c in spaceOrLineEnd:
    lex.advance()
    t = ltSeqItemInd
    lex.nextImpl = blockStyleInline[T]
    return
  lex.buf.add('-')
  lex.nextImpl = plainScalarPart[T]
  lex.indentation = 0
  t = ltIndentation

proc possibleDocumentEnd[T](lex: YamlLexer[T], t: var LexerToken) =
  lex.advance()
  if lex.c == '.':
    lex.advance()
    if lex.c == '.':
      lex.advance()
      if lex.c in spaceOrLineEnd:
        t = ltDocumentEnd
        lex.nextImpl = expectLineEnd[T]
        lex.stored = outsideDoc[T]
        return
      lex.buf.add('.')
    lex.buf.add('.')
  lex.buf.add('.')
  lex.nextImpl = plainScalarPart[T]
  lex.indentation = 0
  t = ltIndentation

proc outsideDoc[T](lex: YamlLexer[T], t: var LexerToken): bool =
  case lex.c
  of '%':
    lex.advance()
    lex.directiveName()
    case lex.buf
    of "YAML":
      t = ltYamlDirective
      lex.nextImpl = yamlVersion[T]
    of "TAG":
      t = ltTagDirective
      lex.nextImpl = tagShorthand[T]
    else:
      t = ltUnknownDirective
      lex.nextImpl = unknownDirParams[T]
    return true
  of '-':
    lex.possibleDirectivesEnd(t)
    return true
  of '.':
    lex.possibleDocumentEnd(t)
    return true
  of spaceOrLineEnd + {'#'}:
    lex.indentation = 0
    while lex.c == ' ':
      lex.indentation.inc()
      lex.advance()
    if lex.c in spaceOrLineEnd + {'#'}:
      lex.nextImpl = expectLineEnd[T]
      lex.stored = outsideDoc[T]
      return false
  else: lex.indentation = 0
  lex.nextImpl = blockStyleInline[T]
  t = ltIndentation
  result = true

proc blockStyle[T](lex: YamlLexer[T], t: var LexerToken): bool =
  case lex.c
  of '-':
    lex.possibleDirectivesEnd(t)
    return true
  of '.':
    lex.possibleDocumentEnd(t)
    return true
  of spaceOrLineEnd + {'#'}:
    lex.indentation = 0
    while lex.c == ' ':
      lex.indentation.inc()
      lex.advance()
    if lex.c in spaceOrLineEnd + {'#'}:
      lex.nextImpl = expectLineEnd[T]
      lex.stored = blockStyle[T]
      t = ltEmptyLine
      return true
  else: lex.indentation = 0
  lex.nextImpl = blockStyleInline[T]
  t = ltIndentation
  result = true

proc possibleIndicatorChar[T](lex: YamlLexer[T], indicator: LexerToken,
    t: var LexerToken): bool =
  if lex.nextIsPlainSafe(false):
    lex.nextImpl = plainScalarPart[T]
    lex.stored = blockStyleInline[T]
    result = false
  else:
    t = indicator
    result = true
    lex.advance()
    while lex.c in space: lex.advance()
    if lex.c in lineEnd:
      lex.nextImpl = expectLineEnd[T]
      lex.stored = blockStyle[T]

proc flowIndicator[T](lex: YamlLexer[T], indicator: LexerToken,
    t: var LexerToken, inFlow: static[bool]): bool {.inline.} =
  t = indicator
  lex.advance()
  while lex.c in space: lex.advance()
  if lex.c in lineEnd:
    lex.nextImpl = expectLineEnd[T]
    when inFlow: lex.stored = flowStyle[T]
    else: lex.stored = blockStyle[T]

proc addMultiple(s: var string, c: char, num: int) {.raises: [], inline.} =
  for i in 1..num:
    s.add(c)

proc processQuotedWhitespace(lex: YamlLexer, newlines: var int) =
  block outer:
    let beforeSpace = lex.buf.len
    while true:
      case lex.c
      of ' ', '\t': lex.buf.add(lex.c)
      of '\l':
        lex.lexLF()
        break
      of '\c':
        lex.lexCR()
        break
      else: break outer
      lex.advance()
    lex.buf.setLen(beforeSpace)
    while true:
      case lex.c
      of ' ', '\t': discard
      of '\l':
        lex.lexLF()
        newlines.inc()
        continue
      of '\c':
        lex.lexCR()
        newlines.inc()
        continue
      else:
        if newlines == 0: discard
        elif newlines == 1: lex.buf.add(' ')
        else: lex.buf.addMultiple('\l', newlines - 1)
        break
      lex.advance()

proc singleQuotedScalar[T](lex: YamlLexer[T]) =
  debug("lex: singleQuotedScalar")
  lex.advance()
  while true:
    case lex.c
    of '\'':
      lex.advance()
      if lex.c == '\'': lex.buf.add('\'')
      else: break
    of EndOfFile: raise lex.generateError("Unfinished single quoted string")
    of '\l', '\c', '\t', ' ':
      var newlines = 1
      lex.processQuotedWhitespace(newlines)
      continue
    else: lex.buf.add(lex.c)
    lex.advance()

proc unicodeSequence(lex: YamlLexer, length: int) =
  debug("lex: unicodeSequence")
  var unicodeChar = 0.int
  for i in countup(0, length - 1):
    lex.advance()
    let digitPosition = length - i - 1
    case lex.c
    of EndOFFile, '\l', '\c':
      raise lex.generateError("Unfinished unicode escape sequence")
    of '0' .. '9':
      unicodeChar = unicodechar or (int(lex.c) - 0x30) shl (digitPosition * 4)
    of 'A' .. 'F':
      unicodeChar = unicodechar or (int(lex.c) - 0x37) shl (digitPosition * 4)
    of 'a' .. 'f':
      unicodeChar = unicodechar or (int(lex.c) - 0x57) shl (digitPosition * 4)
    else:
      raise lex.generateError(
          "Invalid character in unicode escape sequence: " &
          escape("" & lex.c))
  lex.buf.add(toUTF8(Rune(unicodeChar)))

proc doubleQuotedScalar[T](lex: YamlLexer[T]) =
  debug("lex: doubleQuotedScalar")
  lex.advance()
  while true:
    case lex.c
    of EndOfFile:
      raise lex.generateError("Unfinished double quoted string")
    of '\\':
      lex.advance()
      case lex.c
      of EndOfFile:
        raise lex.generateError("Unfinished escape sequence")
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
      of 'x':       lex.unicodeSequence(2)
      of 'u':       lex.unicodeSequence(4)
      of 'U':       lex.unicodeSequence(8)
      of '\l', '\c':
        var newlines = 0
        lex.processQuotedWhitespace(newlines)
        continue
      else: raise lex.generateError("Illegal character in escape sequence")
    of '"':
      lex.advance()
      break
    of '\l', '\c', '\t', ' ':
      var newlines = 1
      lex.processQuotedWhitespace(newlines)
      continue
    else: lex.buf.add(lex.c)
    lex.advance()

proc blockStyleInline[T](lex: YamlLexer[T], t: var LexerToken): bool =
  case lex.c
  of ':': result = lex.possibleIndicatorChar(ltMapValInd, t)
  of '?': result = lex.possibleIndicatorChar(ltMapKeyInd, t)
  of '-': result = lex.possibleIndicatorChar(ltSeqItemInd, t)
  of lineEnd + {'#'}:
    result = false
    lex.nextImpl = expectLineEnd[T]
    lex.stored = blockStyle[T]
  of '\"':
    lex.doubleQuotedScalar()
    t = ltQuotedScalar
    result = true
  of '\'':
    lex.singleQuotedScalar()
    t = ltQuotedScalar
    result = true
  of '>', '|':
    # TODO
    result = true
  of '{': result = lex.flowIndicator(ltBraceOpen, t, false)
  of '}': result = lex.flowIndicator(ltBraceClose, t, false)
  of '[': result = lex.flowIndicator(ltBracketOpen, t, false)
  of ']': result = lex.flowIndicator(ltBracketClose, t, false)
  else:
    lex.nextImpl = plainScalarPart[T]
    lex.stored = blockStyleInline[T]
    result = false

proc plainScalarPart[T](lex: YamlLexer[T], t: var LexerToken): bool =
  debug("lex: plainScalar")
  block outer:
    while true:
      lex.buf.add(lex.c)
      lex.advance()
      case lex.c
      of space:
        let lenBeforeSpace = lex.buf.len()
        while true:
          lex.buf.add(lex.c)
          lex.advance()
          case lex.c
          of lineEnd + {'#'}:
            lex.buf.setLen(lenBeforeSpace)
            lex.nextImpl = expectLineEnd[T]
            lex.stored = if lex.inFlow: flowStyle[T] else: blockStyle[T]
            break outer
          of ':':
            if lex.nextIsPlainSafe(lex.inFlow): break
            else:
              lex.buf.setLen(lenBeforeSpace)
              lex.nextImpl = lex.stored
              break outer
          of flowIndicators:
            if lex.inFlow:
              lex.buf.setLen(lenBeforeSpace)
              lex.nextImpl = lex.stored
              break outer
            else:
              lex.buf.add(lex.c)
              lex.advance()
              break
          of space: discard
          else: break
      of lineEnd:
        lex.nextImpl = expectLineEnd[T]
        lex.stored = if lex.inFlow: flowStyle[T] else: blockStyle[T]
        break
      of flowIndicators:
        if lex.inFlow:
          lex.nextImpl = lex.stored
          break
      of ':':
        if not lex.nextIsPlainSafe(lex.inFlow):
          lex.nextImpl = blockStyleInline[T]
          break outer
      else: discard
  t = ltScalarPart
  result = true

proc flowStyle[T](lex: YamlLexer[T], t: var LexerToken): bool =
  result = false

proc streamEnd[T](lex: YamlLexer[T], t: var LexerToken): bool =
  t = ltStreamEnd
  result = true