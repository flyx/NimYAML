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
  YamlLexerObj* = object
    cur*: LexerToken
    curStartPos*, curEndPos*: tuple[line, column: int]
    # recently read scalar or URI, if any
    buf*: string
    # ltIndentation
    indentation*: int
    when defined(yamlScalarRepInd):
      # ltQuotedScalar, ltBlockScalarHeader
      scalarKind*: ScalarKind

    # internals
    source: BaseLexer
    tokenStart: int
    flowDepth: int
    state, lineStartState, jsonEnablingState: LexerState
    c: char
    seenMultiline: bool
    # indentation of recently started set of node properties.
    # necessary for implicit keys with properties.
    propertyIndentation: int

  YamlLexer* = ref YamlLexerObj

  YamlLexerError* = object of ValueError
    line*, column*: int
    lineContent*: string

  # temporarily missing .raises: [YamlLexerError]
  # due to https://github.com/nim-lang/Nim/issues/13905
  LexerState = proc(lex: YamlLexer): bool {.locks: 0, gcSafe.}

  LexerToken* = enum
    ltYamlDirective,    # `%YAML`
    ltTagDirective,     # `%TAG`
    ltUnknownDirective, # any directive but `%YAML` and `%TAG`
    ltDirectiveParam,   # parameters of %YAML and unknown directives
    ltEmptyLine,        # for line folding in multiline plain scalars
    ltDirectivesEnd,    # explicit `---`
    ltDocumentEnd,      # explicit `...`
    ltStreamEnd,        # end of input
    ltIndentation,      # beginning of non-empty line
    ltPlainScalar, ltSingleQuotedScalar, ltDoubleQuotedScalar,
    ltLiteralScalar, ltFoldedScalar,
    ltSeqItemInd,       # block sequence item indicator `- `
    ltMapKeyInd,        # block mapping key indicator `? `
    ltMapValueInd       # block mapping value indicator `: `
    ltMapStart, ltMapEnd, ltSeqStart, ltSeqEnd, ltSeqSep # {}[],
    ltTagHandle,        # a handle of a tag, e.g. `!!` of `!!str`
    ltSuffix,           # suffix of a tag shorthand, e.g. `str` of `!!str`.
                        # also used for the URI of the %TAG directive
    ltVerbatimTag,      # a verbatim tag, e.g. `!<tag:yaml.org,2002:str>`
    ltAnchor,           # anchor property of a node, e.g. `&anchor`
    ltAlias             # alias node, e.g. `*alias`

  ChompType* = enum
    ctKeep, ctClip, ctStrip

  LineStartType = enum
    lsDirectivesEndMarker, lsDocumentEndMarker, lsComment,
    lsNewline, lsStreamEnd, lsContent

# consts

const
  space          = {' ', '\t'}
  lineEnd        = {'\l', '\c', EndOfFile}
  spaceOrLineEnd = {' ', '\t', '\l', '\c', EndOfFile}
  commentOrLineEnd = {'\l', '\c', EndOfFile, '#'}
  digits         = {'0'..'9'}
  hexDigits      = {'0'..'9', 'a'..'f', 'A'..'F'}
  flowIndicators = {'[', ']', '{', '}', ','}
  uriChars       = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':',
      '@', '&', '-', '=', '+', '$', '_', '.', '~', '*', '\'', '(', ')'}
  tagShorthandChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-'}
  suffixChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', '@',
                 '&', '=', '+', '$', '_', '.', '!', '~', '*', '\'', '-'}
  nodePropertyKind = {ltTagHandle, ltVerbatimTag, ltAnchor}

  UTF8NextLine           = toUTF8(0x85.Rune)
  UTF8NonBreakingSpace   = toUTF8(0xA0.Rune)
  UTF8LineSeparator      = toUTF8(0x2028.Rune)
  UTF8ParagraphSeparator = toUTF8(0x2029.Rune)

  UnknownIndentation* = int.low

# lexer source handling

proc advance(lex: YamlLexer, step: int = 1) {.inline.} =
  lex.source.bufpos.inc(step)
  lex.c = lex.source.buf[lex.source.bufpos]

template lexCR(lex: YamlLexer) =
  try: lex.source.bufpos = lex.source.handleCR(lex.source.bufpos)
  except:
    var e = lex.generateError("Encountered stream error: " &
        getCurrentExceptionMsg())
    e.parent = getCurrentException()
    raise e
  lex.c = lex.source.buf[lex.source.bufpos]

template lexLF(lex: YamlLexer) =
  try: lex.source.bufpos = lex.source.handleLF(lex.source.bufpos)
  except:
    var e = generateError(lex, "Encountered stream error: " &
        getCurrentExceptionMsg())
    e.parent = getCurrentException()
    raise e
  lex.c = lex.source.buf[lex.source.bufpos]

template lineNumber(lex: YamlLexer): int =
  lex.source.lineNumber

template columnNumber(lex: YamlLexer): int =
  lex.source.getColNumber(lex.source.bufpos) + 1

template currentLine(lex: YamlLexer): string =
  lex.source.getCurrentLine(true)

proc Safe(lex: YamlLexer): bool {.inline.} =
  case lex.source.buf[lex.source.bufpos + 1]
  of spaceOrLineEnd: result = false
  of flowIndicators: result = lex.flowDepth == 0
  else: result = true

proc lineWithMarker(lex: YamlLexer, pos: tuple[line, column: int],
                    marker: bool): string =
  if pos.line == lex.source.lineNumber:
    result = lex.source.getCurrentLine(false)
    if marker: result.add(spaces(pos.column - 1) & "^\n")
  else: result = ""

# lexer states

{.push gcSafe, locks: 0.}
# `raises` cannot be pushed.
proc outsideDoc(lex: YamlLexer): bool {.raises: [].}
proc yamlVersion(lex: YamlLexer): bool {.raises: YamlLexerError.}
proc tagShorthand(lex: YamlLexer): bool {.raises: YamlLexerError.}
proc tagUri(lex: YamlLexer): bool {.raises: YamlLexerError.}
proc unknownDirParams(lex: YamlLexer): bool {.raises: [].}
proc expectLineEnd(lex: YamlLexer): bool {.raises: YamlLexerError.}
proc lineStart(lex: YamlLexer): bool {.raises: YamlLexerError.}
proc flowLineStart(lex: YamlLexer): bool {.raises: YamlLexerError.}
proc flowLineIndentation(lex: YamlLexer): bool {.raises: YamlLexerError.}
proc insideLine(lex: YamlLexer): bool {.raises: YamlLexerError.}
proc indentationSettingToken(lex: YamlLexer): bool {.raises: YamlLexerError.}
proc afterToken(lex: YamlLexer): bool {.raises: YamlLexerError.}
proc beforeIndentationSettingToken(lex: YamlLexer): bool {.raises: YamlLexerError.}
proc afterJsonEnablingToken(lex: YamlLexer): bool {.raises: YamlLexerError.}
proc lineIndentation(lex: YamlLexer): bool {.raises: [].}
proc lineDirEnd(lex: YamlLexer): bool {.raises: [].}
proc lineDocEnd(lex: YamlLexer): bool {.raises: [].}
proc atSuffix(lex: YamlLexer): bool {.raises: [].}
proc streamEnd(lex: YamlLexer): bool {.raises: [].}
{.pop.}

# helpers

template debug(message: string) {.dirty.} =
  when defined(yamlDebug):
    try: styledWriteLine(stdout, fgBlue, message)
    except IOError: discard

proc generateError(lex: YamlLexer, message: string):
    ref YamlLexerError {.raises: [].} =
  result = newException(YamlLexerError, message)
  result.line = lex.lineNumber()
  result.column = lex.columnNumber()
  result.lineContent = lex.currentLine()

proc startToken(lex: YamlLexer) {.inline.} =
  lex.curStartPos = (lex.lineNumber(), lex.columnNumber())
  lex.tokenStart = lex.source.bufpos

proc endToken(lex: YamlLexer) {.inline.} =
  lex.curEndPos = (lex.lineNumber(), lex.columnNumber())

proc readNumericSubtoken(lex: YamlLexer) {.inline.} =
  if lex.c notin digits:
    raise lex.generateError("Illegal character in YAML version string: " & escape("" & lex.c))
  while true:
    lex.advance()
    if lex.c notin digits: break

proc isDirectivesEnd(lex: YamlLexer): bool =
  var peek = lex.source.bufpos
  if lex.source.buf[peek] == '-':
    peek += 1
    if lex.source.buf[peek] == '-':
      peek += 1
      if lex.source.buf[peek] in spaceOrLineEnd:
        lex.source.bufpos = peek
        lex.advance()
        return true
  return false

proc isDocumentEnd(lex: YamlLexer): bool =
  var peek = lex.source.bufpos
  if lex.source.buf[peek] == '.':
    peek += 1
    if lex.source.buf[peek] == '.':
      peek += 1
      if lex.source.buf[peek] in spaceOrLineEnd:
        lex.source.bufpos = peek
        lex.advance()
        return true
  return false

proc readHexSequence(lex: YamlLexer, len: int) =
  var charPos = 0
  let startPos = lex.source.bufpos
  for i in countup(0, len-1):
    if lex.source.buf[startPos + 1] notin hexDigits:
      raise lex.generateError("Invalid character in hex escape sequence: " &
          escape("" & lex.source.buf[startPos + i]))
  # no pow() for ints, do it manually
  var coeff = 1
  for exponent in countup(0, len-1): coeff *= 16
  for exponent in countdown(len-1, 0):
    lex.advance()
    case lex.c
    of digits:
      charPos += coeff * (int(lex.c) - int('0'))
    of 'a' .. 'f':
      charPos += coeff * (int(lex.c) - int('a') + 10)
    of 'A' .. 'F':
      charPos += coeff * (int(lex.c) - int('A') + 10)
    else: discard # cannot happen, we checked
    coeff = coeff div 16
  lex.buf.add($Rune(charPos))

proc readURI(lex: YamlLexer) =
  lex.buf.setLen(0)
  let endWithSpace = lex.c != '<'
  let restricted = lex.flowDepth > 0
  var literalStart: int
  if endWithSpace:
    if not restricted and lex.c in {'[', ']', ','}:
      raise lex.generateError("Flow indicator cannot start tag prefix")
    literalStart = lex.source.bufpos - 1
  else:
    literalStart = lex.source.bufpos
    lex.advance()
  while true:
    case lex.c
    of spaceOrLineEnd:
      if endWithSpace:
        lex.buf.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
        break
      raise lex.generateError("Unclosed verbatim tag")
    of '%':
      lex.buf.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.readHexSequence(2)
      literalStart = lex.source.bufpos
    of uriChars: discard
    of '[', ']', ',':
      if restricted:
        lex.buf.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
        break
    of '!':
      if restricted:
        raise lex.generateError("Illegal '!' in tag suffix")
    of '>':
      if endWithSpace:
        raise lex.generateError("Illegal character in URI: `>`")
      lex.buf.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.advance()
      break
    else:
      raise lex.generateError("Illegal character in URI: " & escape("" & lex.c))
    lex.advance()

proc endLine(lex: YamlLexer) =
  while true:
    case lex.c
    of '\l':
      lex.lexLF()
      lex.state = lex.lineStartState
      break
    of '\c':
      lex.lexCR()
      lex.state = lex.lineStartState
      break
    of EndOfFile:
      lex.state = streamEnd
      break
    of '#':
      while true:
        lex.advance()
        if lex.c in lineEnd: break
    else: discard

proc startLine(lex: YamlLexer): LineStartType =
  case lex.c
  of '-':
    return if lex.isDirectivesEnd(): lsDirectivesEndMarker
           else: lsContent
  of '.':
    return if lex.isDocumentEnd(): lsDocumentEndMarker
           else: lsContent
  else:
    while lex.c == ' ': lex.advance()
    return case lex.c
    of '#': lsComment
    of '\l', '\c': lsNewline
    of EndOfFile: lsStreamEnd
    else: lsContent

proc readPlainScalar(lex: YamlLexer) =
  lex.buf.setLen(0)
  let afterNewlineState = if lex.flowDepth == 0: lineIndentation
                          else: flowLineIndentation
  var lineStartPos: int
  lex.seenMultiline = false
  lex.startToken()
  if lex.propertyIndentation != -1:
    lex.indentation = lex.propertyIndentation
    lex.propertyIndentation = -1
  lex.cur = ltPlainScalar
  block multilineLoop:
    while true:
      lineStartPos = lex.source.bufpos - 1
      block inlineLoop:
        while true:
          lex.advance()
          case lex.c
          of ' ':
            lex.endToken()
            let contentEnd = lex.source.bufpos - 2
            block spaceLoop:
              lex.advance()
              case lex.c
              of '\l', '\c':
                lex.buf.add(lex.source.buf[lineStartPos..contentEnd])
                break inlineLoop
              of EndOfFile:
                lex.buf.add(lex.source.buf[lineStartPos..contentEnd])
                lex.state = streamEnd
                break multilineLoop
              of '#':
                lex.buf.add(lex.source.buf[lineStartPos..contentEnd])
                lex.state = expectLineEnd
                break multilineLoop
              of ':':
                if not lex.Safe():
                  lex.buf.add(lex.source.buf[lineStartPos..contentEnd])
                  lex.state = insideLine
                  break multilineLoop
                break spaceLoop
              of flowIndicators:
                if lex.flowDepth > 0:
                  lex.buf.add(lex.source.buf[lineStartPos..contentEnd])
                  lex.state = insideLine
                  break multilineLoop
                break spaceLoop
              of ' ': discard
              else: break spaceLoop
          of ':':
            if not lex.Safe():
              lex.buf.add(lex.source.buf[lineStartPos..lex.source.bufpos - 2])
              lex.endToken()
              lex.state = insideLine
              break multilineLoop
          of flowIndicators:
            if lex.flowDepth > 0:
              lex.buf.add(lex.source.buf[lineStartPos..lex.source.bufpos - 2])
              lex.endToken()
              lex.state = insideLine
              break multilineLoop
          of '\l', '\c':
            lex.buf.add(lex.source.buf[lineStartPos..lex.source.bufpos - 2])
            lex.endToken()
            break inlineLoop
          of EndOfFile:
            lex.buf.add(lex.source.buf[lineStartPos..lex.source.bufpos - 2])
            if lex.columnNumber() > 0:
              lex.endToken()
            lex.state = streamEnd
            break multilineLoop
          else: discard
      lex.endLine()
      var newlines = 1
      block newlineLoop:
        while true:
          case lex.startLine()
          of lsContent:
            if lex.columnNumber() <= lex.indentation:
              lex.state = afterNewlineState
              break multilineLoop
            break newlineLoop
          of lsDirectivesEndMarker:
            lex.state = lineDirEnd
            break multilineLoop
          of lsDocumentEndMarker:
            lex.state = lineDocEnd
            break multilineLoop
          of lsStreamEnd:
            break multilineLoop
          of lsComment:
            lex.endLine()
            lex.state = lineStart
            break multilineLoop
          of lsNewline: lex.endLine()
          newlines += 1
      if (lex.c == ':' and not lex.Safe()) or
         lex.c == '#' or (lex.c in flowIndicators and
         lex.flowDepth > 0):
        lex.state = afterNewlineState
        break multilineLoop
      lex.seenMultiline = true
      if newlines == 1: lex.buf.add(' ')
      else:
        for i in countup(2, newlines): lex.buf.add('\l')

proc streamEndAfterBlock(lex: YamlLexer) =
  if lex.columnNumber() != 0:
    lex.endToken()
    lex.curEndPos.column -= 1


proc readBlockScalar(lex: YamlLexer) =
  var
    chomp = ctClip
    indent = 0
    separationLines = 0
    contentStart: int
  lex.startToken()
  lex.cur = if lex.c == '>': ltFoldedScalar else: ltLiteralScalar
  lex.buf.setLen(0)

  # header
  while true:
    lex.advance()
    case lex.c
    of '+':
      if chomp != ctClip:
        raise lex.generateError("Multiple chomping indicators")
      chomp = ctKeep
    of '-':
      if chomp != ctClip:
        raise lex.generateError("Multiple chomping indicators")
      chomp = ctStrip
    of '1' .. '9':
      if indent != 0:
        raise lex.generateError("Multiple indentation indicators")
      indent = max(0, lex.indentation) + int(lex.c) - int('0')
    of ' ':
      while true:
        lex.advance()
        if lex.c != ' ': break
      if lex.c notin commentOrLineEnd:
        raise lex.generateError("Illegal character after block scalar header: " &
            escape("" & lex.c))
      break
    of lineEnd: break
    else:
      raise lex.generateError("Illegal character in block scalar header: " &
          escape("" & lex.c))
  lex.endLine()

  block body:
    # determining indentation and leading empty lines
    var maxLeadingSpaces = 0
    while true:
      if indent == 0:
        while lex.c == ' ': lex.advance()
      else:
        maxLeadingSpaces = lex.columnNumber + indent
        while lex.c == ' ' and lex.columnNumber < maxLeadingSpaces:
          lex.advance()
      case lex.c
      of '\l', '\c':
        lex.endToken()
        maxLeadingSpaces = max(maxLeadingSpaces, lex.columnNumber())
        lex.endLine()
        separationLines += 1
      of EndOfFile:
        lex.state = streamEnd
        lex.streamEndAfterBlock()
        break body
      else:
        if indent == 0:
          indent = lex.columnNumber()
          if indent <= max(0, lex.indentation):
            lex.state = lineIndentation
            break body
          elif indent < maxLeadingSpaces:
            raise lex.generateError("Leading all-spaces line contains too many spaces")
        elif lex.columnNumber < indent: break body
        break
    for i in countup(0, separationLines - 1):
      lex.buf.add('\l')

    block content:
      contentStart = lex.source.bufpos - 1
      while lex.c notin lineEnd: lex.advance()
      lex.buf.add(lex.buf[contentStart .. lex.source.bufpos - 2])
      separationLines = 0
      if lex.c == EndOfFile:
        lex.state = streamEnd
        lex.streamEndAfterBlock()
        break body
      separationLines += 1
      lex.endToken()
      lex.endLine()

      # empty lines and indentation of next line
      while true:
        while lex.c == ' ' and lex.columnNumber() < indent:
          lex.advance()
        case lex.c
        of '\l', '\c':
          lex.endToken()
          separationLines += 1
          lex.endLine()
        of EndOfFile:
          lex.state = streamEnd
          lex.streamEndAfterBlock()
          break body
        else:
          if lex.columnNumber() < indent:
            break content
          else: break

      # line folding
      if lex.cur == ltLiteralScalar:
        for i in countup(0, separationLines - 1):
          lex.buf.add('\l')
      elif separationLines == 1:
        lex.buf.add(' ')
      else:
        for i in countup(0, separationLines - 2):
          lex.buf.add('\l')

    if lex.columnNumber() > max(0, lex.indentation):
      if lex.c == '#':
        lex.state = expectLineEnd
      else:
        raise lex.generateError("This line at " & escape("" & lex.c) & " is less indented than necessary")
    elif lex.columnNumber() == 1:
      lex.state = lineStart
    else:
      lex.state = lineIndentation

  lex.endToken()

  case chomp
  of ctStrip: discard
  of ctClip:
    if len(lex.buf) > 0:
      lex.buf.add('\l')
  of ctKeep:
    for i in countup(0, separationLines - 1):
      lex.buf.add('\l')

proc processQuotedWhitespace(lex: YamlLexer, initial: int) =
  var newlines = initial
  let firstSpace = lex.source.bufpos - 1
  while true:
    case lex.c
    of ' ': discard
    of '\l':
      lex.lexLF()
      break
    of '\c':
      lex.lexCR()
      break
    else:
      lex.buf.add(lex.source.buf[firstSpace..lex.source.bufpos - 2])
      return
    lex.advance()
  lex.seenMultiline = true
  while true:
    case lex.startLine()
    of lsContent, lsComment: break
    of lsDirectivesEndMarker:
      raise lex.generateError("Illegal `---` within quoted scalar")
    of lsDocumentEndMarker:
      raise lex.generateError("Illegal `...` within quoted scalar")
    of lsNewline: lex.endLine()
    of lsStreamEnd:
      raise lex.generateError("Unclosed quoted string")
    newlines += 1
  if newlines == 0: discard
  elif newlines == 1: lex.buf.add(' ')
  else:
    for i in countup(2, newlines): lex.buf.add('\l')

proc readSingleQuotedScalar(lex: YamlLexer) =
  lex.seenMultiline = false
  lex.startToken()
  lex.buf.setLen(0)
  if lex.propertyIndentation != -1:
    lex.indentation = lex.propertyIndentation
    lex.propertyIndentation = -1
  var literalStart = lex.source.bufpos
  lex.advance()
  while true:
    case lex.c
    of EndOfFile:
      raise lex.generateError("Unclosed quoted string")
    of '\'':
      lex.buf.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.advance()
      if lex.c == '\'':
        lex.buf.add('\'')
        literalStart = lex.source.bufpos
        lex.advance()
      else: break
    of ' ', '\l', '\c':
      lex.buf.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.processQuotedWhitespace(1)
      literalStart = lex.source.bufpos - 1
    else:
      lex.advance()
  lex.endToken()
  lex.cur = ltSingleQuotedScalar

proc readDoubleQuotedScalar(lex: YamlLexer) =
  lex.seenMultiline = false
  lex.startToken()
  lex.buf.setLen(0)
  if lex.propertyIndentation != -1:
    lex.indentation = lex.propertyIndentation
    lex.propertyIndentation = -1
  var literalStart = lex.source.bufpos
  lex.advance()
  while true:
    case lex.c
    of EndOfFile:
      raise lex.generateError("Unclosed quoted string")
    of '\\':
      lex.buf.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.advance()
      literalStart = lex.source.bufpos
      case lex.c
      of '0': lex.buf.add('\0')
      of 'a': lex.buf.add('\a')
      of 'b': lex.buf.add('\b')
      of 't', '\t': lex.buf.add('\t')
      of 'n': lex.buf.add('\l')
      of 'v': lex.buf.add('\v')
      of 'f': lex.buf.add('\f')
      of 'r': lex.buf.add('\c')
      of 'e': lex.buf.add('\e')
      of ' ': lex.buf.add(' ')
      of '"': lex.buf.add('"')
      of '/': lex.buf.add('/')
      of '\\':lex.buf.add('\\')
      of 'N': lex.buf.add(UTF8NextLine)
      of '_': lex.buf.add(UTF8NonBreakingSpace)
      of 'L': lex.buf.add(UTF8LineSeparator)
      of 'P': lex.buf.add(UTF8ParagraphSeparator)
      of 'x':
        lex.readHexSequence(2)
        literalStart = lex.source.bufpos
      of 'u':
        lex.readHexSequence(4)
        literalStart = lex.source.bufpos
      of 'U':
        lex.readHexSequence(8)
        literalStart = lex.source.bufpos
      of '\l', '\c':
        lex.processQuotedWhitespace(0)
        literalStart = lex.source.bufpos - 1
        continue
      else:
        raise lex.generateError("Illegal character in escape sequence: " & escape("" & lex.c))
    of '"':
      lex.buf.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      break
    of ' ', '\l', '\c':
      lex.buf.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.processQuotedWhitespace(1)
      literalStart = lex.source.bufpos - 1
      continue
    else: discard
    lex.advance()
  lex.advance()
  lex.endToken()
  lex.cur = ltDoubleQuotedScalar

proc basicInit(lex: YamlLexer) =
  lex.state = outsideDoc
  lex.flowDepth = 0
  lex.lineStartState = outsideDoc
  lex.jsonEnablingState = afterToken
  lex.propertyIndentation = -1
  lex.buf = ""
  lex.advance()

# interface

proc shortLexeme*(lex: YamlLexer): string =
  return lex.source.buf[lex.tokenStart..lex.source.bufpos-2]

proc fullLexeme*(lex: YamlLexer): string =
  return lex.source.buf[lex.tokenStart - 1..lex.source.bufpos-2]

proc next*(lex: YamlLexer) =
  while not lex.state(lex): discard
  debug("lexer -> " & $lex.cur)

proc newYamlLexer*(source: Stream): YamlLexer {.raises: [IOError, OSError].} =
  result = new(YamlLexerObj)
  result.source.open(source)
  result.basicInit()

proc newYamlLexer*(source: string): YamlLexer
    {.raises: [].} =
  result = new(YamlLexerObj)
  try:
    result.source.open(newStringStream(source))
  except:
    discard # can never happen with StringStream
  result.basicInit()

# states

proc outsideDoc(lex: YamlLexer): bool =
  case lex.c
  of '%':
    lex.startToken()
    while true:
      lex.advance()
      if lex.c in spaceOrLineEnd: break
    lex.endToken()
    let name = lex.shortLexeme()
    case name
    of "YAML":
      lex.state = yamlVersion
      lex.cur = ltYamlDirective
    of "TAG":
      lex.state = tagShorthand
      lex.cur = ltTagDirective
    else:
      lex.state = unknownDirParams
      lex.cur = ltUnknownDirective
      lex.buf.setLen(0)
      lex.buf.add(name)
  of '-':
    lex.startToken()
    if lex.isDirectivesEnd():
      lex.state = expectLineEnd
      lex.cur = ltDocumentEnd
    else:
      lex.state = indentationSettingToken
      lex.cur = ltIndentation
    lex.lineStartState = lineStart
    lex.indentation = -1
    lex.endToken()
  of '.':
    lex.startToken()
    if lex.isDocumentEnd():
      lex.state = expectLineEnd
      lex.cur = ltDocumentEnd
    else:
      lex.state = indentationSettingToken
      lex.lineStartState = lineStart
      lex.indentation = -1
      lex.cur = ltIndentation
    lex.endToken()
  else:
    lex.startToken()
    while lex.c == ' ': lex.advance()
    if lex.c in commentOrLineEnd:
      lex.state = expectLineEnd
      return false
    lex.endToken()
    lex.cur = ltIndentation
    lex.state = indentationSettingToken
    lex.lineStartState = lineStart
  return true

proc yamlVersion(lex: YamlLexer): bool =
  debug("lex: yamlVersion")
  while lex.c in space: lex.advance()
  lex.startToken()
  lex.readNumericSubtoken()
  if lex.c != '.':
    raise lex.generateError("Illegal character in YAML version string: " & escape("" & lex.c))
  lex.advance()
  lex.readNumericSubtoken()
  if lex.c notin spaceOrLineEnd:
    raise lex.generateError("Illegal character in YAML version string: " & escape("" & lex.c))
  lex.cur = ltDirectiveParam
  lex.endToken()
  lex.state = expectLineEnd

proc tagShorthand(lex: YamlLexer): bool =
  debug("lex: tagShorthand")
  while lex.c in space: lex.advance()
  if lex.c != '!':
    raise lex.generateError("Illegal character, tag shorthand must start with '!': " & escape("" & lex.c))
  lex.startToken()
  lex.advance()

  if lex.c in spaceOrLineEnd: discard
  else:
    while lex.c in tagShorthandChars: lex.advance()
    if lex.c != '!':
      if lex.c in spaceOrLineEnd:
        raise lex.generateError("Tag shorthand must end with '!'.")
      else:
        raise lex.generateError("Illegal character in tag shorthand: " & escape("" & lex.c))
    lex.advance()
    if lex.c notin spaceOrLineEnd:
      raise lex.generateError("Missing space after tag shorthand")
  lex.cur = ltTagHandle
  lex.endToken()
  lex.state = tagUri

proc tagUri(lex: YamlLexer): bool =
  debug("lex: tagUri")
  while lex.c in space: lex.advance()
  lex.startToken()
  if lex.c == '<':
    raise lex.generateError("Illegal character in tag URI: " & escape("" & lex.c))
  lex.readUri()
  lex.cur = ltSuffix
  lex.endToken()
  lex.state = expectLineEnd
  return true

proc unknownDirParams(lex: YamlLexer): bool =
  debug("lex: unknownDirParams")
  while lex.c in space: lex.advance()
  if lex.c in lineEnd + {'#'}:
    lex.state = expectLineEnd
    return false
  lex.startToken()
  while true:
    lex.advance()
    if lex.c in lineEnd + {'#'}: break
  lex.cur = ltDirectiveParam
  return true

proc expectLineEnd(lex: YamlLexer): bool =
  debug("lex: expectLineEnd")
  while lex.c in space: lex.advance()
  if lex.c notin commentOrLineEnd:
    raise lex.generateError("Unexpected character (expected line end): " & escape("" & lex.c))
  lex.endLine()
  return false

proc lineStart(lex: YamlLexer): bool =
  debug("lex: lineStart")
  return case lex.startLine()
  of lsDirectivesEndMarker: lex.lineDirEnd()
  of lsDocumentEndMarker: lex.lineDocEnd()
  of lsComment, lsNewline: lex.endLine(); false
  of lsStreamEnd: lex.state = streamEnd; false
  of lsContent: lex.lineIndentation()

proc flowLineStart(lex: YamlLexer): bool =
  var indent: int
  case lex.c
  of '-':
    if lex.isDirectivesEnd():
      raise lex.generateError("Directives end marker before end of flow content")
    indent = 0
  of '.':
    if lex.isDocumentEnd():
      raise lex.generateError("Document end marker before end of flow content")
    indent = 0
  else:
    let lineStart = lex.source.bufpos
    while lex.c == ' ': lex.advance()
    indent = lex.source.bufpos - lineStart
  if indent <= lex.indentation:
    raise lex.generateError("Too few indentation spaces (must surpass surrounding block level)")
  lex.state = insideLine
  return false

proc flowLineIndentation(lex: YamlLexer): bool =
  if lex.columnNumber() < lex.indentation:
    raise lex.generateError("Too few indentation spaces (must surpass surrounding block level)")
  lex.state = insideLine
  return false

proc checkIndicatorChar(lex: YamlLexer, kind: LexerToken) =
  if lex.Safe():
    lex.readPlainScalar()
  else:
    lex.startToken()
    lex.advance()
    lex.endToken()
    lex.cur = kind
    lex.state = beforeIndentationSettingToken

proc enterFlowCollection(lex: YamlLexer, kind: LexerToken) =
  lex.startToken()
  if lex.flowDepth == 0:
    lex.jsonEnablingState = afterJsonEnablingToken
    lex.lineStartState = flowLineStart
    lex.propertyIndentation = -1
  lex.flowDepth += 1
  lex.state = afterToken
  lex.advance()
  lex.endToken()
  lex.cur = kind

proc leaveFlowCollection(lex: YamlLexer, kind: LexerToken) =
  lex.startToken()
  if lex.flowDepth == 0:
    raise lex.generateError("No flow collection to leave!")
  lex.flowDepth -= 1
  if lex.flowDepth == 0:
    lex.jsonEnablingState = afterToken
    lex.lineStartState = lineStart
  lex.state = lex.jsonEnablingState
  lex.advance()
  lex.endToken()
  lex.cur = kind

proc readNamespace(lex: YamlLexer) =
  lex.startToken()
  lex.advance()
  if lex.c == '<':
    lex.readURI()
    lex.endToken()
    lex.cur = ltVerbatimTag
  else:
    var handleEnd = lex.tokenStart
    while true:
      case lex.source.buf[handleEnd]
      of spaceOrLineEnd + flowIndicators:
        handleEnd = lex.tokenStart
        lex.source.bufpos -= 1
        break
      of '!':
        handleEnd += 1
        break
      else:
        handleEnd += 1
    while lex.source.bufpos < handleEnd:
      lex.advance()
      if lex.c notin tagShorthandChars + {'!'}:
        raise lex.generateError("Illegal character in tag handle: " & escape("" & lex.c))
    lex.advance()
    lex.endToken()
    lex.cur = ltTagHandle
    lex.state = atSuffix

proc readAnchorName(lex: YamlLexer) =
  lex.startToken()
  while true:
    lex.advance()
    if lex.c notin tagShorthandChars + {'_'}: break
  if lex.c notin spaceOrLineEnd + flowIndicators:
    raise lex.generateError("Illegal character in anchor: " & escape("" & lex.c))
  elif lex.source.bufpos == lex.tokenStart + 1:
    raise lex.generateError("Anchor name must not be empty")
  lex.state = afterToken

proc insideLine(lex: YamlLexer): bool =
  case lex.c
  of ':':
    lex.checkIndicatorChar(ltMapValueInd)
    if lex.cur == ltMapValueInd and lex.propertyIndentation != -1:
      lex.indentation = lex.propertyIndentation
      lex.propertyIndentation = -1
  of '?':
    lex.checkIndicatorChar(ltMapKeyInd)
  of '-':
    lex.checkIndicatorChar(ltSeqItemInd)
  of commentOrLineEnd:
    lex.endLine()
    return false
  of '"':
    lex.readDoubleQuotedScalar()
    lex.state = lex.jsonEnablingState
  of '\'':
    lex.readSingleQuotedScalar()
    lex.state = lex.jsonEnablingState
  of '>', '|':
    if lex.flowDepth > 0:
      lex.readPlainScalar()
    else:
      lex.readBlockScalar()
  of '{':
    lex.enterFlowCollection(ltMapStart)
  of '}':
    lex.leaveFlowCollection(ltMapEnd)
  of '[':
    lex.enterFlowCollection(ltSeqStart)
  of ']':
    lex.leaveFlowCollection(ltSeqEnd)
  of ',':
    lex.startToken()
    lex.advance()
    lex.endToken()
    lex.cur = ltSeqSep
    lex.state = afterToken
  of '!':
    lex.readNamespace()
  of '&':
    lex.readAnchorName()
    lex.endToken()
    lex.cur = ltAnchor
  of '*':
    lex.readAnchorName()
    lex.endToken()
    lex.cur = ltAlias
  of '@', '`':
    raise lex.generateError("Reserved character may not start any token")
  else:
    lex.readPlainScalar()
  return true

proc indentationSettingToken(lex: YamlLexer): bool =
  let cachedIntentation = lex.columnNumber()
  result = lex.insideLine()
  if result and lex.flowDepth > 0:
    if lex.cur in nodePropertyKind:
      lex.propertyIndentation = cachedIntentation
    else:
      lex.indentation = cachedIntentation

proc afterToken(lex: YamlLexer): bool =
  while lex.c == ' ': lex.advance()
  if lex.c in commentOrLineEnd:
    lex.endLine()
  else:
    lex.state = insideLine
  return false

proc beforeIndentationSettingToken(lex: YamlLexer): bool =
  discard lex.afterToken()
  if lex.state == insideLine:
    lex.state = indentationSettingToken
  return false

proc afterJsonEnablingToken(lex: YamlLexer): bool =
  while lex.c == ' ': lex.advance()
  while true:
    case lex.c
    of ':':
      lex.startToken()
      lex.advance()
      lex.endToken()
      lex.cur = ltMapValueInd
      lex.state = afterToken
    of '#', '\l', '\c':
      lex.endLine()
      discard lex.flowLineStart()
    of EndOfFile:
      lex.state = streamEnd
      return false
    else:
      lex.state = insideLine
      return false

proc lineIndentation(lex: YamlLexer): bool =
  lex.curStartPos.line = lex.source.lineNumber
  lex.curStartPos.column = 1
  lex.endToken()
  lex.cur = ltIndentation
  lex.state = indentationSettingToken
  return true

proc lineDirEnd(lex: YamlLexer): bool =
  lex.curStartPos.line = lex.source.lineNumber
  lex.curStartPos.column = 1
  lex.endToken()
  lex.cur = ltDirectivesEnd
  lex.indentation = -1
  lex.propertyIndentation = -1
  return true

proc lineDocEnd(lex: YamlLexer): bool =
  lex.curStartPos.line = lex.source.lineNumber
  lex.curStartPos.column = 1
  lex.endToken()
  lex.cur = ltDocumentEnd
  lex.state = expectLineEnd
  lex.lineStartState = outsideDoc
  return true

proc atSuffix(lex: YamlLexer): bool =
  lex.startToken()
  while lex.c in suffixChars: lex.advance()
  lex.buf = lex.fullLexeme()
  lex.endToken()
  lex.cur = ltSuffix
  lex.state = afterToken
  return true

proc streamEnd(lex: YamlLexer): bool =
  lex.startToken()
  lex.endToken()
  lex.cur = ltStreamEnd
  return true