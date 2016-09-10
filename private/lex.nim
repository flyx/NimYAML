#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import lexbase, streams, strutils

type
  StringSource* = object
    src: string
    pos: int
    line, lineStart: int

  SourceProvider* = concept c
    advance(c) is char
    lexCR(c)
    lexLF(c)

  YamlLexer*[T: SourceProvider] = ref object
    source: T
    inFlow: bool
    literalEndIndent: int
    nextImpl, stored: proc(lex: YamlLexer[T], t: var LexerToken): bool
    c: char
    buf*: string not nil
    indentation*: int

  LexerToken* = enum
    ltYamlDirective, ltYamlVersion, ltTagDirective, ltTagShorthand,
    ltTagUrl, ltUnknownDirective, ltUnknownDirectiveParams,
    ltDirectivesEnd, ltDocumentEnd, ltStreamEnd, ltIndentation, ltQuotedScalar,
    ltScalarPart, ltEmptyLine, ltSeqItemInd, ltMapKeyInd, ltMapValInd,
    ltBraceOpen, ltBraceClose, ltBracketOpen, ltBracketClose, ltComma,
    ltLiteralTag, ltTagSuffix, ltAnchor, ltAlias

  YamlLexerError* = object of Exception

# templates

template advance(lex: YamlLexer[BaseLexer], step: int = 1) =
  lex.source.bufpos.inc(step)
  lex.c = lex.source.buf[lex.source.bufpos]

template advance(lex: YamlLexer[StringSource], step: int = 1) =
  lex.source.pos.inc(step)
  lex.c = lex.source.src[lex.source.pos]

# lexer states

proc outsideDoc[T](lex: YamlLexer[T], t: var LexerToken): bool
proc yamlVersion[T](lex: YamlLexer[T], t: var LexerToken): bool
proc tagShorthand[T](lex: YamlLexer[T], t: var LexerToken): bool
proc tagUri[T](lex: YamlLexer[T], t: var LexerToken): bool
proc unknownDirParams[T](lex: YamlLexer[T], t: var LexerToken): bool
proc expectLineEnd[T](lex: YamlLexer[T], t: var LexerToken): bool
proc blockStyle[T](lex: YamlLexer[T], t: var LexerToken): bool
proc blockStyleInline[T](lex: YamlLexer[T], t: var LexerToken): bool
proc plainScalarPart[T](lex: YamlLexer[T], t: var LexerToken): bool
proc flowStyle[T](lex: YamlLexer[T], t: var LexerToken): bool
proc streamEnd[T](lex: YamlLexer[T], t: var LexerToken): bool

# interface

proc newYamlLexer*(source: Stream): YamlLexer[BaseLexer] = 
  result = YamlLexer[T](source: BaseLexer(), inFlow: false, buf: "",
      nextImpl: outsideDoc[T])
  result.source.open(source)
  result.c = result.source.buf[result.source.bufpos]

proc newYamlLexer*[T: StringSource](source: string, startAt: int = 0):
    YamlLexer[T] =
  result = YamlLexer[T](nextImpl: outsideDoc, buf: "", source:
      StringSource(src: source, pos: startAt, lineStart: startAt, line: 1),
      inFlow: false, c: source[startAt])

proc next*(lex: YamlLexer): LexerToken =
  while not lex.nextImpl(result): discard

# implementation

const
  space          = {' ', '\t'}
  lineEnd        = {'\l', '\c', EndOfFile}
  spaceOrLineEnd = {' ', '\t', '\l', '\c', EndOfFile}
  digits         = {'0'..'9'}
  flowIndicators = {'[', ']', '{', '}', ','}

template debug(message: string) {.dirty.} =
  when defined(yamlDebug):
    try: styledWriteLine(stdout, fgBlue, message)
    except IOError: discard

proc generateError(lex: YamlLexer, message: string):
    ref YamlLexerError {.raises: [].} =
  result = newException(YamlLexerError, message)
  result.line = lex.lineNumber
  result.column = lex.bufpos + 1
  result.lineContent = lex.getCurrentLine(false) &
      repeat(' ', lex.getColNumber(lex.bufpos)) & "^\n"

template handleCR(lex: YamlLexer[BaseLexer]) =
  lex.source.bufpos = lex.source.handleCR(lex.source.bufpos)

template handleCR(lex: YamlLexer[StringSource]) =
  lex.source.pos.inc()
  if lex.source.src[lex.source.pos] == '\l': lex.source.pos.inc()
  lex.source.lineStart = lex.source.pos
  lex.source.row.line.inc()

template handleLF(lex: YamlLexer[BaseLexer]) =
  lex.source.bufpos = lex.source.handleLF(lex.source.bufpos)

template handleLF(lex: YamlLexer[StringSource]) =
  lex.source.pos.inc()
  lex.source.lineStart = lex.source.pos
  lex.source.row.line.inc()

proc directiveName(lex: YamlLexer) =
  while lex.c notin spaceOrLineEnd:
    lex.buf.add(lex.c)
    lex.advance()

proc yamlVersion[T](lex: YamlLexer[T], t: var LexerToken): bool =
  debug("lex: yamlVersion")
  while lex.c in space: lex.anvance()
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
  case lex.source.src[lex.source.pos + 1]
  of spaceOrLineEnd: result = false
  of flowIndicators: result = not inFlow
  else: result = true

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
    lex.avance()
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
  var c = lex.curChar()
  while c notin lineEnd + {'#'}:
    lex.advance()
    c = lex.curChar()
  t = ltUnknownDirectiveParams
  result = true
  lex.stored = outsideDoc[T]
  lex.nextImpl = expectLineEnd[T]

proc expectLineEnd[T](lex: YamlLexer[T], t: var LexerToken): bool =
  debug("lex: expectLineEnd")
  result = false
  while lex.c in space: lex.anvance()
  while true:
    case lex.c
    of '#':
      lex.advance()
      while lex.c notin lineEnd: lex.advance()
    of EndOfFile:
      lex.nextImpl = streamEnd[T]
      break
    of '\l':
      lex.handleLF()
      lex.nextImpl = lex.stored
      break
    of '\c':
      lex.handleCR()
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
    of "YAML": lex.nextImpl = yamlVersion[T]
    of "TAG": lex.nextImpl = tagShorthand[T]
    else: lex.nextImpl = unknownDirParams[T]
    break
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
  of '{': result = lex.flowIndicator(ltBraceOpen, t)
  of '}': result = lex.flowIndicator(ltBraceClose, t)
  of '[': result = lex.flowIndicator(ltBracketOpen, t)
  of ']': result = lex.flowIndicator(ltBracketClose, t)
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
          case lex.ch
          of lineEnd + {'#'}:
            lex.buf.setLen(lenBeforeSpace)
            lex.nextImpl = expectLineEnd[T]
            lex.stored = if lex.inFlow: flowStyle[T] else: blockStyle[T]
            break outer
          of ':':
            if lex.nextIsPlainSafe(): break
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
      of flowIndicators:
        if lex.inFlow:
          lex.nextImpl = lex.stored
          break
      of ':':
        if not lex.nextIsPlainSafe(): break outer
      else: discard
  t = ltScalarPart
  result = true

proc flowStyle[T](lex: YamlLexer[T], t: var LexerToken): bool =
  result = false

proc streamEnd[T](lex: YamlLexer[T], t: var LexerToken): bool =
  t = ltStreamEnd
  result = true