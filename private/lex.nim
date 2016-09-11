#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import lexbase, streams, strutils, unicode
when defined(yamlDebug):
  import terminal
  export terminal

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
    # ltScalarPart, ltQuotedScalar, ltYamlVersion, ltTagShorthand, ltTagUri,
    # ltLiteralTag, ltTagHandle, ltAnchor, ltAlias
    buf*: string not nil
    # ltIndentation
    indentation*: int
    # ltBlockScalarHeader
    moreIndented*, folded*: bool
    chomp*: ChompType
    # ltTagHandle
    shorthandEnd*: int

    # internals
    source: pointer
    inFlow: bool
    literalEndIndent: int
    nextState, lineStartState, inlineState, insideLineImpl, insideDocImpl:
        LexerState
    blockScalarIndent: int
    c: char

  YamlLexer* = ref YamlLexerObj

  LexerState = proc(lex: YamlLexer): bool

  LexerToken* = enum
    ltYamlDirective, ltYamlVersion, ltTagDirective, ltTagShorthand,
    ltTagUri, ltUnknownDirective, ltUnknownDirectiveParams, ltEmptyLine,
    ltDirectivesEnd, ltDocumentEnd, ltStreamEnd, ltIndentation, ltQuotedScalar,
    ltScalarPart, ltBlockScalarHeader, ltSeqItemInd, ltMapKeyInd, ltMapValInd,
    ltBraceOpen, ltBraceClose, ltBracketOpen, ltBracketClose, ltComma,
    ltLiteralTag, ltTagHandle, ltAnchor, ltAlias

  YamlLexerError* = object of Exception
    line*, column*: int
    lineContent*: string

  ChompType* = enum
    ctKeep, ctClip, ctStrip

# consts

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
  lex.blSource.bufpos = lex.blSource.handleCR(lex.blSource.bufpos)
  lex.c = lex.blSource.buf[lex.blSource.bufpos]

template lexCR(lex: YamlLexer, t: typedesc[StringSource]) =
  lex.sSource.pos.inc()
  if lex.sSource.src[lex.sSource.pos] == '\l': lex.sSource.pos.inc()
  lex.sSource.lineStart = lex.sSource.pos
  lex.sSource.line.inc()
  lex.c = lex.sSource.src[lex.sSource.pos]

template lexLF(lex: YamlLexer, t: typedesc[BaseLexer]) =
  lex.blSource.bufpos = lex.blSource.handleLF(lex.blSource.bufpos)
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

# lexer states

proc outsideDoc[T](lex: YamlLexer): bool
proc yamlVersion[T](lex: YamlLexer): bool
proc tagShorthand[T](lex: YamlLexer): bool
proc tagUri[T](lex: YamlLexer): bool
proc unknownDirParams[T](lex: YamlLexer): bool
proc expectLineEnd[T](lex: YamlLexer): bool
proc possibleDirectivesEnd[T](lex: YamlLexer): bool
proc possibleDocumentEnd[T](lex: YamlLexer): bool
proc afterSeqInd[T](lex: YamlLexer): bool
proc insideDoc[T](lex: YamlLexer): bool {.locks:0.}
proc insideLine[T](lex: YamlLexer): bool
proc plainScalarPart[T](lex: YamlLexer): bool
proc blockScalarHeader[T](lex: YamlLexer): bool
proc blockScalar[T](lex: YamlLexer): bool
proc streamEnd(lex: YamlLexer): bool

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

proc directiveName(lex: YamlLexer, t: typedesc) =
  while lex.c notin spaceOrLineEnd:
    lex.buf.add(lex.c)
    lex.advance(t)

proc yamlVersion[T](lex: YamlLexer): bool =
  debug("lex: yamlVersion")
  while lex.c in space: lex.advance(T)
  if lex.c notin digits:
    raise generateError[T](lex, "Invalid YAML version number")
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
      lex.nextState = streamEnd
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
      raise generateError[T](lex, "Unexpected character (expected line end): " &
          escape("" & lex.c))

proc possibleDirectivesEnd[T](lex: YamlLexer): bool =
  debug("lex: possibleDirectivesEnd")
  lex.lineStartState = insideDoc[T]
  lex.advance(T)
  if lex.c == '-':
    lex.advance(T)
    if lex.c == '-':
      lex.advance(T)
      if lex.c in spaceOrLineEnd:
        lex.cur = ltDirectivesEnd
        lex.nextState = insideLine[T]
        return true
      lex.buf.add('-')
    lex.buf.add('-')
  elif lex.c in spaceOrLineEnd:
    lex.indentation = 0
    lex.cur = ltIndentation
    lex.nextState = afterSeqInd[T]
    return true
  lex.buf.add('-')
  lex.nextState = plainScalarPart[T]
  result = false

proc afterSeqInd[T](lex: YamlLexer): bool =
  result = true
  lex.cur = ltSeqItemInd
  if lex.c notin lineEnd: lex.advance(T)
  lex.nextState = insideLine[T]

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
        lex.lineStartState = outsideDoc[T]
        return true
      lex.buf.add('.')
    lex.buf.add('.')
  lex.buf.add('.')
  lex.nextState = plainScalarPart[T]
  result = false

proc outsideDoc[T](lex: YamlLexer): bool =
  debug("lex: outsideDoc")
  case lex.c
  of '%':
    lex.advance(T)
    lex.directiveName(T)
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
    lex.nextState = possibleDocumentEnd[T]
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
    if lex.c in spaceOrLineEnd:
      lex.cur = ltEmptyLine
      lex.nextState = expectLineEnd[T]
      return true
    else:
      lex.nextState = lex.inlineState
  else: lex.nextState = lex.inlineState
  lex.cur = ltIndentation
  result = true

proc possibleIndicatorChar[T](lex: YamlLexer, indicator: LexerToken,
    jsonContext: bool = false): bool =
  if not(jsonContext) and lex.nextIsPlainSafe(T, false):
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
  lex.cur = indicator
  lex.advance(T)
  while lex.c in space: lex.advance(T)
  if lex.c in lineEnd:
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
    if lex.inFlow: lex.nextState = plainScalarPart[T]
    else: lex.nextState = blockScalarHeader[T]
    result = false
  of '{': result = flowIndicator[T](lex, ltBraceOpen)
  of '}': result = flowIndicator[T](lex, ltBraceClose)
  of '[': result = flowIndicator[T](lex, ltBracketOpen)
  of ']': result = flowIndicator[T](lex, ltBracketClose)
  of ',': result = flowIndicator[T](lex, ltComma)
  else:
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
              lex.nextState = insideLine[T]
              break outer
          of flowIndicators:
            if lex.inFlow:
              lex.buf.setLen(lenBeforeSpace)
              lex.nextState = insideLine[T]
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
          lex.nextState = insideLine[T]
          break
      of ':':
        if not lex.nextIsPlainSafe(T, lex.inFlow):
          lex.nextState = insideLine[T]
          break outer
      else: discard
  lex.cur = ltScalarPart
  result = true

proc blockScalarHeader[T](lex: YamlLexer): bool =
  debug("lex: blockScalarHeader")
  lex.chomp = ctClip
  lex.blockScalarIndent = UnknownIndentation
  lex.folded = lex.c == '>'
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
      lex.blockScalarIndent = lex.indentation + ord(lex.c) - ord('\x30')
    of spaceOrLineEnd: break
    else:
      raise generateError[T](lex,
          "Illegal character in block scalar header: '" & escape("" & lex.c) &
          '\'')
  lex.nextState = expectLineEnd[T]
  lex.inlineState = blockScalar[T]
  lex.cur = ltBlockScalarHeader
  result = true

proc blockScalar[T](lex: YamlLexer): bool =
  debug("lex: blockScalarLine")
  result = false
  if lex.blockScalarIndent == UnknownIndentation:
    lex.blockScalarIndent = lex.indentation
  elif lex.c == '#':
    lex.nextState = expectLineEnd[T]
    return false
  elif lex.indentation < lex.blockScalarIndent:
    raise generateError[T](lex, "Too little indentation in block scalar")
  elif lex.indentation > lex.blockScalarIndent or lex.c == '\t':
    lex.moreIndented = true
    lex.buf.addMultiple(' ', lex.indentation - lex.blockScalarIndent)
  else: lex.moreIndented = false
  while lex.c notin lineEnd:
    lex.buf.add(lex.c)
    lex.advance(T)
  lex.cur = ltScalarPart
  result = true
  lex.nextState = expectLineEnd[T]

proc streamEnd(lex: YamlLexer): bool =
  debug("lex: streamEnd")
  lex.cur = ltStreamEnd
  result = true

# interface

proc init*[T](lex: YamlLexer) =
  lex.nextState = outsideDoc[T]
  lex.lineStartState = outsideDoc[T]
  lex.inlineState = insideLine[T]
  lex.insideLineImpl = insideLine[T]
  lex.insideDocImpl = insideDoc[T]

proc newYamlLexer*(source: Stream): YamlLexer =
  let blSource = cast[ptr BaseLexer](alloc(sizeof(BaseLexer)))
  blSource[].open(source)
  new(result, proc(x: ref YamlLexerObj) {.nimcall.} =
      dealloc(x.source)
  )
  result[] = YamlLexerObj(source: blSource, inFlow: false, buf: "",
      c: blSource[].buf[blSource[].bufpos])
  init[BaseLexer](result)

proc newYamlLexer*(source: string, startAt: int = 0): YamlLexer =
  let sSource = cast[ptr StringSource](alloc(sizeof(StringSource)))
  sSource[] =
      StringSource(src: source, pos: startAt, lineStart: startAt, line: 1)
  new(result, proc(x: ref YamlLexerObj) {.nimcall.} =
      dealloc(x.source)
  )
  result[] = YamlLexerObj(buf: "", source: sSource, inFlow: false,
      c: sSource.src[startAt])
  init[StringSource](result)

proc next*(lex: YamlLexer) =
  while not lex.nextState(lex): discard

proc setFlow*(lex: YamlLexer, value: bool) =
  lex.inFlow = value
  if value: lex.lineStartState = lex.insideLineImpl
  else: lex.lineStartState = lex.insideDocImpl

proc endBlockScalar*(lex: YamlLexer) =
  lex.inlineState = lex.insideLineImpl
  lex.nextState = lex.insideLineImpl