#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import lexbase, streams, strutils, unicode
import ../data
when defined(yamlDebug):
  import terminal
  export terminal

type
  Lexer* = object
    cur*: Token
    curStartPos*, curEndPos*: Mark
    flowDepth*: int
    # recently read scalar or URI, if any
    evaluated*: string
    # internals
    indentation: int
    source: BaseLexer
    tokenStart: int
    state, lineStartState, jsonEnablingState: State
    c: char
    seenMultiline: bool
    # indentation of recently started set of node properties.
    # necessary for implicit keys with properties.
    propertyIndentation: int

  LexerError* = object of ValueError
    line*, column*: int
    lineContent*: string

  # temporarily missing .raises: [LexerError]
  # due to https://github.com/nim-lang/Nim/issues/13905
  State = proc(lex: var Lexer): bool {.locks: 0, gcSafe, nimcall.}

  Token* {.pure.} = enum
    YamlDirective,    # `%YAML`
    TagDirective,     # `%TAG`
    UnknownDirective, # any directive but `%YAML` and `%TAG`
    DirectiveParam,   # parameters of %YAML and unknown directives
    EmptyLine,        # for line folding in multiline plain scalars
    DirectivesEnd,    # explicit `---`
    DocumentEnd,      # explicit `...`
    StreamEnd,        # end of input
    Indentation,      # beginning of non-empty line
    Plain, SingleQuoted, DoubleQuoted, Literal, Folded,
    SeqItemInd,       # block sequence item indicator `- `
    MapKeyInd,        # block mapping key indicator `? `
    MapValueInd       # block mapping value indicator `: `
    MapStart, MapEnd, SeqStart, SeqEnd, SeqSep # {}[],
    TagHandle,        # a handle of a tag, e.g. `!!` of `!!str`
    Suffix,           # suffix of a tag shorthand, e.g. `str` of `!!str`.
                        # also used for the URI of the %TAG directive
    VerbatimTag,      # a verbatim tag, e.g. `!<tag:yaml.org,2002:str>`
    Anchor,           # anchor property of a node, e.g. `&anchor`
    Alias             # alias node, e.g. `*alias`

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
  flowIndicators = {'[', ']', '{', '}', ','}
  uriChars       = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':',
      '@', '&', '-', '=', '+', '$', '_', '.', '~', '*', '\'', '(', ')'}
  tagShorthandChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-'}
  nodePropertyKind* = {Token.TagHandle, Token.VerbatimTag, Token.Anchor}
  scalarTokenKind* = {Token.Plain, Token.SingleQuoted, Token.DoubleQuoted,
                     Token.Literal, Token.Folded}

  UTF8NextLine           = toUTF8(0x85.Rune)
  UTF8NonBreakingSpace   = toUTF8(0xA0.Rune)
  UTF8LineSeparator      = toUTF8(0x2028.Rune)
  UTF8ParagraphSeparator = toUTF8(0x2029.Rune)

  UnknownIndentation* = int.low

proc currentIndentation*(lex: Lexer): int {.locks: 0.} =
  return lex.source.getColNumber(lex.source.bufpos) - 1

proc recentIndentation*(lex: Lexer): int {.locks: 0.} =
  return lex.indentation

# lexer source handling

proc advance(lex: var Lexer, step: int = 1) {.inline.} =
  lex.c = lex.source.buf[lex.source.bufpos]
  lex.source.bufpos.inc(step)

template lexCR(lex: var Lexer) =
  try: lex.source.bufpos = lex.source.handleCR(lex.source.bufpos - 1)
  except:
    var e = lex.generateError("Encountered stream error: " &
        getCurrentExceptionMsg())
    e.parent = getCurrentException()
    raise e
  lex.advance()

template lexLF(lex: var Lexer) =
  try: lex.source.bufpos = lex.source.handleLF(lex.source.bufpos - 1)
  except:
    var e = generateError(lex, "Encountered stream error: " &
        getCurrentExceptionMsg())
    e.parent = getCurrentException()
    raise e
  lex.advance()

template lineNumber(lex: Lexer): Positive =
  lex.source.lineNumber

template columnNumber(lex: Lexer): Positive =
  lex.source.getColNumber(lex.source.bufpos)

template currentLine(lex: Lexer): string =
  lex.source.getCurrentLine(true)

proc isPlainSafe(lex: Lexer): bool {.inline.} =
  case lex.source.buf[lex.source.bufpos]
  of spaceOrLineEnd: result = false
  of flowIndicators: result = lex.flowDepth == 0
  else: result = true

# lexer states

{.push gcSafe, locks: 0.}
# `raises` cannot be pushed.
proc outsideDoc(lex: var Lexer): bool {.raises: [].}
proc yamlVersion(lex: var Lexer): bool {.raises: LexerError.}
proc tagShorthand(lex: var Lexer): bool {.raises: LexerError.}
proc tagUri(lex: var Lexer): bool {.raises: LexerError.}
proc unknownDirParams(lex: var Lexer): bool {.raises: [].}
proc expectLineEnd(lex: var Lexer): bool {.raises: LexerError.}
proc lineStart(lex: var Lexer): bool {.raises: LexerError.}
proc flowLineStart(lex: var Lexer): bool {.raises: LexerError.}
proc flowLineIndentation(lex: var Lexer): bool {.raises: LexerError.}
proc insideLine(lex: var Lexer): bool {.raises: LexerError.}
proc indentationSettingToken(lex: var Lexer): bool {.raises: LexerError.}
proc afterToken(lex: var Lexer): bool {.raises: LexerError.}
proc beforeIndentationSettingToken(lex: var Lexer): bool {.raises: LexerError.}
proc afterJsonEnablingToken(lex: var Lexer): bool {.raises: LexerError.}
proc lineIndentation(lex: var Lexer): bool {.raises: [].}
proc lineDirEnd(lex: var Lexer): bool {.raises: [].}
proc lineDocEnd(lex: var Lexer): bool {.raises: [].}
proc atSuffix(lex: var Lexer): bool {.raises: [LexerError].}
proc streamEnd(lex: var Lexer): bool {.raises: [].}
{.pop.}

# helpers

template debug*(message: string) =
  when defined(yamlDebug):
    when nimvm:
      echo "yamlDebug: ", message
    else:
      try: styledWriteLine(stdout, fgBlue, message)
      except ValueError, IOError: discard

proc generateError(lex: Lexer, message: string):
    ref LexerError {.raises: [].} =
  result = newException(LexerError, message)
  result.line = lex.lineNumber()
  result.column = lex.columnNumber()
  result.lineContent = lex.currentLine()

proc startToken(lex: var Lexer) {.inline.} =
  lex.curStartPos = (line: lex.lineNumber(), column: lex.columnNumber())
  lex.tokenStart = lex.source.bufpos

proc endToken(lex: var Lexer) {.inline.} =
  lex.curEndPos = (line: lex.lineNumber(), column: lex.columnNumber())

proc readNumericSubtoken(lex: var Lexer) {.inline.} =
  if lex.c notin digits:
    raise lex.generateError("Illegal character in YAML version string: " & escape("" & lex.c))
  while true:
    lex.advance()
    if lex.c notin digits: break

proc isDirectivesEnd(lex: var Lexer): bool =
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

proc isDocumentEnd(lex: var Lexer): bool =
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

proc readHexSequence(lex: var Lexer, len: int) =
  var charPos = 0
  for i in countup(0, len-1):
    lex.advance()
    let digitPosition = len - i - 1
    case lex.c
    of lineEnd:
      raise lex.generateError("Unfinished unicode escape sequence")
    of '0'..'9':
      charPos = charPos or (int(lex.c) - 0x30) shl (digitPosition * 4)
    of 'A' .. 'F':
      charPos = charPos or (int(lex.c) - 0x37) shl (digitPosition * 4)
    of 'a' .. 'f':
      charPos = charPos or (int(lex.c) - 0x57) shl (digitPosition * 4)
    else:
      raise lex.generateError("Invalid character in hex escape sequence: " &
          escape("" & lex.c))
  lex.evaluated.add(toUTF8(Rune(charPos)))

proc readURI(lex: var Lexer) =
  lex.evaluated.setLen(0)
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
        lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
        break
      raise lex.generateError("Unclosed verbatim tag")
    of '%':
      lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.readHexSequence(2)
      literalStart = lex.source.bufpos
    of uriChars: discard
    of '[', ']', ',':
      if restricted:
        lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
        break
    of '!':
      if restricted:
        raise lex.generateError("Illegal '!' in tag suffix")
    of '>':
      if endWithSpace:
        raise lex.generateError("Illegal character in URI: `>`")
      lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.advance()
      break
    else:
      raise lex.generateError("Illegal character in URI: " & escape("" & lex.c))
    lex.advance()

proc endLine(lex: var Lexer) =
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

proc startLine(lex: var Lexer): LineStartType =
  case lex.c
  of '-':
    return if lex.isDirectivesEnd(): lsDirectivesEndMarker
           else: lsContent
  of '.':
    return if lex.isDocumentEnd(): lsDocumentEndMarker
           else: lsContent
  else:
    while lex.c == ' ': lex.advance()
    if lex.c == '\t':
      var peek = lex.source.bufpos
      while lex.source.buf[peek] in space:
        peek += 1
      if lex.source.buf[peek] in commentOrLineEnd:
        lex.source.bufpos = peek + 1
        lex.c = lex.source.buf[peek]
      else:
        return lsContent
    return case lex.c
    of '#': lsComment
    of '\l', '\c': lsNewline
    of EndOfFile: lsStreamEnd
    else: lsContent

proc readPlainScalar(lex: var Lexer) =
  lex.evaluated.setLen(0)
  let afterNewlineState = if lex.flowDepth == 0: lineIndentation
                          else: flowLineIndentation
  var lineStartPos: int
  lex.seenMultiline = false
  lex.startToken()
  if lex.propertyIndentation != -1:
    lex.indentation = lex.propertyIndentation
    lex.propertyIndentation = -1
  lex.cur = Token.Plain
  block multilineLoop:
    while true:
      lineStartPos = lex.source.bufpos - 1
      block inlineLoop:
        while true:
          lex.advance()
          case lex.c
          of space:
            lex.endToken()
            let spaceStart = lex.source.bufpos - 2
            block spaceLoop:
              while true:
                lex.advance()
                case lex.c
                of '\l', '\c':
                  lex.evaluated.add(lex.source.buf[lineStartPos..spaceStart])
                  break inlineLoop
                of EndOfFile:
                  lex.evaluated.add(lex.source.buf[lineStartPos..spaceStart])
                  lex.state = streamEnd
                  break multilineLoop
                of '#':
                  lex.evaluated.add(lex.source.buf[lineStartPos..spaceStart])
                  lex.state = expectLineEnd
                  break multilineLoop
                of ':':
                  if not lex.isPlainSafe():
                    lex.evaluated.add(lex.source.buf[lineStartPos..spaceStart])
                    lex.state = insideLine
                    break multilineLoop
                  break spaceLoop
                of flowIndicators:
                  if lex.flowDepth > 0:
                    lex.evaluated.add(lex.source.buf[lineStartPos..spaceStart])
                    lex.state = insideLine
                    break multilineLoop
                  break spaceLoop
                of space: discard
                else: break spaceLoop
          of ':':
            if not lex.isPlainSafe():
              lex.evaluated.add(lex.source.buf[lineStartPos..lex.source.bufpos - 2])
              lex.endToken()
              lex.state = insideLine
              break multilineLoop
          of flowIndicators:
            if lex.flowDepth > 0:
              lex.evaluated.add(lex.source.buf[lineStartPos..lex.source.bufpos - 2])
              lex.endToken()
              lex.state = insideLine
              break multilineLoop
          of '\l', '\c':
            lex.evaluated.add(lex.source.buf[lineStartPos..lex.source.bufpos - 2])
            lex.endToken()
            break inlineLoop
          of EndOfFile:
            lex.evaluated.add(lex.source.buf[lineStartPos..lex.source.bufpos - 2])
            if lex.currentIndentation() > 0:
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
            if lex.currentIndentation() <= lex.indentation:
              lex.state = afterNewlineState
              break multilineLoop
            if lex.c == '\t':
              while lex.c in space: lex.advance()
              case lex.c:
              of '#':
                lex.endLine()
                lex.state = lineStart
                break multilineLoop
              of '\l', '\c':
                lex.endLine()
                newlines += 1
                continue
              else: discard
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
      while lex.c in space: lex.advance()
      if (lex.c == ':' and not lex.isPlainSafe()) or
         lex.c == '#' or (lex.c in flowIndicators and
         lex.flowDepth > 0):
        lex.state = afterNewlineState
        break multilineLoop
      lex.seenMultiline = true
      if newlines == 1: lex.evaluated.add(' ')
      else:
        for i in countup(2, newlines): lex.evaluated.add('\l')

proc streamEndAfterBlock(lex: var Lexer) =
  if lex.currentIndentation() != 0:
    lex.endToken()
    lex.curEndPos.column -= 1

proc dirEndFollows(lex: Lexer): bool =
  return lex.c == '-' and lex.source.buf[lex.source.bufpos] == '-' and
      lex.source.buf[lex.source.bufpos+1] == '-'

proc docEndFollows(lex: Lexer): bool =
  return lex.c == '.' and lex.source.buf[lex.source.bufpos] == '.' and
      lex.source.buf[lex.source.bufpos+1] == '.'

proc readBlockScalar(lex: var Lexer) =
  var
    chomp = ctClip
    indent = 0
    separationLines = 0
    contentStart: int
    hasBody = true
  lex.startToken()
  lex.cur = if lex.c == '>': Token.Folded else: Token.Literal
  lex.evaluated.setLen(0)

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
    of EndOfFile:
      hasBody = false
      break
    of '\l', '\c': break
    else:
      raise lex.generateError("Illegal character in block scalar header: " &
          escape("" & lex.c))
  lex.endLine()

  block body:
    # determining indentation and leading empty lines
    var
      maxLeadingSpaces = 0
      moreIndented = false
    while true:
      if indent == 0:
        while lex.c == ' ': lex.advance()
      else:
        maxLeadingSpaces = lex.currentIndentation() + indent
        while lex.c == ' ' and lex.currentIndentation() < maxLeadingSpaces:
          lex.advance()
      case lex.c
      of '\l', '\c':
        lex.endToken()
        maxLeadingSpaces = max(maxLeadingSpaces, lex.currentIndentation())
        lex.endLine()
        separationLines += 1
      of EndOfFile:
        lex.state = streamEnd
        lex.streamEndAfterBlock()
        if lex.source.getColNumber(lex.source.bufpos) > 1 and hasBody: separationLines += 1
        break body
      else:
        if indent == 0:
          indent = lex.currentIndentation()
          if indent <= lex.indentation or
              (indent == 0 and (lex.dirEndFollows() or lex.docEndFollows())):
            lex.state = lineIndentation
            break body
          elif indent < maxLeadingSpaces:
            raise lex.generateError("Leading all-spaces line contains too many spaces")
        elif lex.currentIndentation() < indent: break body
        if lex.cur == Token.Folded and lex.c in space:
          moreIndented = true
        break
    for i in countup(0, separationLines - 1):
      lex.evaluated.add('\l')
    separationLines = if moreIndented: 1 else: 0

    block content:
      while true:
        contentStart = lex.source.bufpos - 1
        while lex.c notin lineEnd: lex.advance()
        lex.evaluated.add(lex.source.buf[contentStart .. lex.source.bufpos - 2])
        if lex.c == EndOfFile:
          lex.state = streamEnd
          lex.streamEndAfterBlock()
          break body
        separationLines += 1
        lex.endToken()
        lex.endLine()

        let oldMoreIndented = moreIndented
        # empty lines and indentation of next line
        moreIndented = false
        while true:
          while lex.c == ' ' and lex.currentIndentation() < indent:
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
            if lex.currentIndentation() < indent or
                (indent == 0 and (lex.dirEndFollows() or lex.docEndFollows())):
              break content
            if lex.cur == Token.Folded and lex.c in space:
              moreIndented = true
              if not oldMoreIndented:
                separationLines += 1
            break

        # line folding
        if lex.cur == Token.Literal:
          for i in countup(0, separationLines - 1):
            lex.evaluated.add('\l')
        elif separationLines == 1:
          lex.evaluated.add(' ')
        else:
          for i in countup(0, separationLines - 2):
            lex.evaluated.add('\l')
        separationLines = if moreIndented: 1 else: 0

    let markerFollows = lex.currentIndentation() == 0 and
        (lex.dirEndFollows() or lex.docEndFollows())
    if lex.c == '#':
      lex.state = expectLineEnd
    elif lex.currentIndentation() > lex.indentation and not markerFollows:
      raise lex.generateError("This line #" & $lex.curStartPos.line & " at " & escape("" & lex.c) & " is less indented than necessary")
    elif lex.currentIndentation() == 0:
      lex.state = lineStart
    else:
      lex.state = lineIndentation

  lex.endToken()

  case chomp
  of ctStrip: discard
  of ctClip:
    if len(lex.evaluated) > 0: lex.evaluated.add('\l')
  of ctKeep:
    for i in countup(0, separationLines - 1):
      lex.evaluated.add('\l')

proc processQuotedWhitespace(lex: var Lexer, initial: int) =
  var newlines = initial
  let firstSpace = lex.source.bufpos - 1
  while true:
    case lex.c
    of ' ', '\t': discard
    of '\l':
      lex.lexLF()
      break
    of '\c':
      lex.lexCR()
      break
    else:
      lex.evaluated.add(lex.source.buf[firstSpace..lex.source.bufpos - 2])
      return
    lex.advance()
  lex.seenMultiline = true
  while true:
    case lex.startLine()
    of lsContent, lsComment:
      while lex.c in space: lex.advance()
      if lex.c in {'\l', '\c'}:
        lex.endLine()
      else: break
    of lsDirectivesEndMarker:
      raise lex.generateError("Illegal `---` within quoted scalar")
    of lsDocumentEndMarker:
      raise lex.generateError("Illegal `...` within quoted scalar")
    of lsNewline: lex.endLine()
    of lsStreamEnd:
      raise lex.generateError("Unclosed quoted string")
    newlines += 1
  if newlines == 0: discard
  elif newlines == 1: lex.evaluated.add(' ')
  else:
    for i in countup(2, newlines): lex.evaluated.add('\l')

proc readSingleQuotedScalar(lex: var Lexer) =
  lex.seenMultiline = false
  lex.startToken()
  lex.evaluated.setLen(0)
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
      lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.advance()
      if lex.c == '\'':
        lex.evaluated.add('\'')
        literalStart = lex.source.bufpos
        lex.advance()
      else: break
    of ' ', '\t', '\l', '\c':
      lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.processQuotedWhitespace(1)
      literalStart = lex.source.bufpos - 1
    else:
      lex.advance()
  lex.endToken()
  lex.cur = Token.SingleQuoted

proc readDoubleQuotedScalar(lex: var Lexer) =
  lex.seenMultiline = false
  lex.startToken()
  lex.evaluated.setLen(0)
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
      lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.advance()
      literalStart = lex.source.bufpos
      case lex.c
      of '0': lex.evaluated.add('\0')
      of 'a': lex.evaluated.add('\a')
      of 'b': lex.evaluated.add('\b')
      of 't', '\t': lex.evaluated.add('\t')
      of 'n': lex.evaluated.add('\l')
      of 'v': lex.evaluated.add('\v')
      of 'f': lex.evaluated.add('\f')
      of 'r': lex.evaluated.add('\c')
      of 'e': lex.evaluated.add('\e')
      of ' ': lex.evaluated.add(' ')
      of '"': lex.evaluated.add('"')
      of '/': lex.evaluated.add('/')
      of '\\':lex.evaluated.add('\\')
      of 'N': lex.evaluated.add(UTF8NextLine)
      of '_': lex.evaluated.add(UTF8NonBreakingSpace)
      of 'L': lex.evaluated.add(UTF8LineSeparator)
      of 'P': lex.evaluated.add(UTF8ParagraphSeparator)
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
      lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      break
    of ' ', '\t', '\l', '\c':
      lex.evaluated.add(lex.source.buf[literalStart..lex.source.bufpos - 2])
      lex.processQuotedWhitespace(1)
      literalStart = lex.source.bufpos - 1
      continue
    else: discard
    lex.advance()
  lex.advance()
  lex.endToken()
  lex.cur = Token.DoubleQuoted

proc basicInit(lex: var Lexer) =
  lex.state = outsideDoc
  lex.flowDepth = 0
  lex.lineStartState = outsideDoc
  lex.jsonEnablingState = afterToken
  lex.propertyIndentation = -1
  lex.evaluated = ""
  lex.advance()

# interface

proc lastScalarWasMultiline*(lex: Lexer): bool {.locks: 0.} =
  result = lex.seenMultiline

proc shortLexeme*(lex: Lexer): string {.locks: 0.} =
  return lex.source.buf[lex.tokenStart..lex.source.bufpos-2]

proc fullLexeme*(lex: Lexer): string {.locks: 0.} =
  return lex.source.buf[lex.tokenStart - 1..lex.source.bufpos-2]

proc currentLine*(lex: Lexer): string {.locks: 0.} =
  return lex.source.getCurrentLine(false)

proc next*(lex: var Lexer) =
  while not lex.state(lex): discard
  debug("lexer -> [" & $lex.curStartPos.line & "," & $lex.curStartPos.column &
      "-" & $lex.curEndPos.line & "," & $lex.curEndPos.column & "] " & $lex.cur)

proc init*(lex: var Lexer, source: Stream) {.raises: [IOError, OSError].} =
  lex.source.open(source)
  lex.basicInit()

proc init*(lex: var Lexer, source: string) {.raises: [].} =
  try:
    lex.source.open(newStringStream(source))
  except:
    discard # can never happen with StringStream
  lex.basicInit()

# states

proc outsideDoc(lex: var Lexer): bool =
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
      lex.cur = Token.YamlDirective
    of "TAG":
      lex.state = tagShorthand
      lex.cur = Token.TagDirective
    else:
      lex.state = unknownDirParams
      lex.cur = Token.UnknownDirective
      lex.evaluated.setLen(0)
      lex.evaluated.add(name)
  of '-':
    lex.startToken()
    if lex.isDirectivesEnd():
      lex.state = afterToken
      lex.cur = Token.DirectivesEnd
    else:
      lex.state = indentationSettingToken
      lex.cur = Token.Indentation
    lex.lineStartState = lineStart
    lex.indentation = -1
    lex.endToken()
  of '.':
    lex.startToken()
    if lex.isDocumentEnd():
      lex.state = expectLineEnd
      lex.cur = Token.DocumentEnd
    else:
      lex.state = indentationSettingToken
      lex.lineStartState = lineStart
      lex.indentation = -1
      lex.cur = Token.Indentation
    lex.endToken()
  else:
    lex.startToken()
    while lex.c == ' ': lex.advance()
    if lex.c in commentOrLineEnd:
      lex.state = expectLineEnd
      return false
    if lex.c == '\t':
      var peek = lex.source.bufpos
      while lex.source.buf[peek] in space:
        peek += 1
      if lex.source.buf[peek] in commentOrLineEnd:
        lex.state = expectLineEnd
        lex.source.bufpos = peek
        return false
    lex.endToken()
    lex.cur = Token.Indentation
    lex.indentation = -1
    lex.state = indentationSettingToken
    lex.lineStartState = lineStart
  return true

proc yamlVersion(lex: var Lexer): bool =
  while lex.c in space: lex.advance()
  lex.startToken()
  lex.readNumericSubtoken()
  if lex.c != '.':
    raise lex.generateError("Illegal character in YAML version string: " & escape("" & lex.c))
  lex.advance()
  lex.readNumericSubtoken()
  if lex.c notin spaceOrLineEnd:
    raise lex.generateError("Illegal character in YAML version string: " & escape("" & lex.c))
  lex.cur = Token.DirectiveParam
  lex.endToken()
  lex.state = expectLineEnd
  return true

proc tagShorthand(lex: var Lexer): bool =
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
  lex.cur = Token.TagHandle
  lex.endToken()
  lex.state = tagUri
  return true

proc tagUri(lex: var Lexer): bool =
  while lex.c in space: lex.advance()
  lex.startToken()
  if lex.c == '<':
    raise lex.generateError("Illegal character in tag URI: " & escape("" & lex.c))
  lex.readUri()
  lex.cur = Token.Suffix
  lex.endToken()
  lex.state = expectLineEnd
  return true

proc unknownDirParams(lex: var Lexer): bool =
  while lex.c in space: lex.advance()
  if lex.c in lineEnd + {'#'}:
    lex.state = expectLineEnd
    return false
  lex.startToken()
  while true:
    lex.advance()
    if lex.c in lineEnd + {'#'}: break
  lex.cur = Token.DirectiveParam
  return true

proc expectLineEnd(lex: var Lexer): bool =
  while lex.c in space: lex.advance()
  if lex.c notin commentOrLineEnd:
    raise lex.generateError("Unexpected character (expected line end): " & escape("" & lex.c))
  lex.endLine()
  return false

proc lineStart(lex: var Lexer): bool =
  return case lex.startLine()
  of lsDirectivesEndMarker: lex.lineDirEnd()
  of lsDocumentEndMarker: lex.lineDocEnd()
  of lsComment, lsNewline: lex.endLine(); false
  of lsStreamEnd: lex.state = streamEnd; false
  of lsContent:
    if lex.flowDepth == 0: lex.lineIndentation()
    else: lex.flowLineIndentation()

proc flowLineStart(lex: var Lexer): bool =
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
    while lex.c in space: lex.advance()
  if lex.c in commentOrLineEnd:
    lex.state = expectLineEnd
    return false
  if indent <= lex.indentation:
    raise lex.generateError("Too few indentation spaces (must surpass surrounding block level)")
  lex.state = insideLine
  return false

proc flowLineIndentation(lex: var Lexer): bool =
  if lex.currentIndentation() < lex.indentation:
    raise lex.generateError("Too few indentation spaces (must surpass surrounding block level)")
  lex.state = insideLine
  return false

proc checkIndicatorChar(lex: var Lexer, kind: Token) =
  if lex.isPlainSafe():
    lex.readPlainScalar()
  else:
    lex.startToken()
    lex.advance()
    lex.endToken()
    lex.cur = kind
    lex.state = beforeIndentationSettingToken

proc enterFlowCollection(lex: var Lexer, kind: Token) =
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

proc leaveFlowCollection(lex: var Lexer, kind: Token) =
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

proc readNamespace(lex: var Lexer) =
  lex.startToken()
  lex.advance()
  if lex.c == '<':
    lex.readURI()
    lex.endToken()
    lex.cur = Token.VerbatimTag
    lex.state = afterToken
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
    lex.cur = Token.TagHandle
    lex.state = atSuffix

proc readAnchorName(lex: var Lexer) =
  lex.startToken()
  while true:
    lex.advance()
    if lex.c in spaceOrLineEnd + flowIndicators: break
  if lex.source.bufpos == lex.tokenStart + 1:
    raise lex.generateError("Anchor name must not be empty")
  lex.state = afterToken

proc insideLine(lex: var Lexer): bool =
  case lex.c
  of ':':
    lex.checkIndicatorChar(Token.MapValueInd)
    if lex.cur == Token.MapValueInd and lex.propertyIndentation != -1:
      lex.indentation = lex.propertyIndentation
      lex.propertyIndentation = -1
  of '?':
    lex.checkIndicatorChar(Token.MapKeyInd)
  of '-':
    lex.checkIndicatorChar(Token.SeqItemInd)
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
    lex.enterFlowCollection(Token.MapStart)
  of '}':
    lex.leaveFlowCollection(Token.MapEnd)
  of '[':
    lex.enterFlowCollection(Token.SeqStart)
  of ']':
    lex.leaveFlowCollection(Token.SeqEnd)
  of ',':
    lex.startToken()
    lex.advance()
    lex.endToken()
    lex.cur = Token.SeqSep
    lex.state = afterToken
  of '!':
    lex.readNamespace()
  of '&':
    lex.readAnchorName()
    lex.endToken()
    lex.cur = Token.Anchor
  of '*':
    lex.readAnchorName()
    lex.endToken()
    lex.cur = Token.Alias
  of ' ', '\t':
    while true:
      lex.advance()
      if lex.c notin space: break
    return false
  of '@', '`':
    raise lex.generateError("Reserved character may not start any token")
  else:
    lex.readPlainScalar()
  return true

proc indentationSettingToken(lex: var Lexer): bool =
  let cachedIntentation = lex.currentIndentation()
  result = lex.insideLine()
  if result and lex.flowDepth == 0:
    if lex.cur in nodePropertyKind:
      lex.propertyIndentation = cachedIntentation
    else:
      lex.indentation = cachedIntentation

proc afterToken(lex: var Lexer): bool =
  while lex.c in space: lex.advance()
  if lex.c in commentOrLineEnd:
    lex.endLine()
  else:
    lex.state = insideLine
  return false

proc beforeIndentationSettingToken(lex: var Lexer): bool =
  discard lex.afterToken()
  if lex.state == insideLine:
    lex.state = indentationSettingToken
  return false

proc afterJsonEnablingToken(lex: var Lexer): bool =
  while lex.c == ' ': lex.advance()
  while true:
    case lex.c
    of ':':
      lex.startToken()
      lex.advance()
      lex.endToken()
      lex.cur = Token.MapValueInd
      lex.state = afterToken
      return true
    of '#', '\l', '\c':
      lex.endLine()
      discard lex.flowLineStart()
    of EndOfFile:
      lex.state = streamEnd
      return false
    else:
      lex.state = insideLine
      return false

proc lineIndentation(lex: var Lexer): bool =
  lex.curStartPos.line = lex.source.lineNumber
  lex.curStartPos.column = 1
  lex.endToken()
  lex.cur = Token.Indentation
  lex.state = indentationSettingToken
  return true

proc lineDirEnd(lex: var Lexer): bool =
  lex.curStartPos.line = lex.source.lineNumber
  lex.curStartPos.column = 1
  lex.endToken()
  lex.cur = Token.DirectivesEnd
  lex.state = afterToken
  lex.indentation = -1
  lex.propertyIndentation = -1
  return true

proc lineDocEnd(lex: var Lexer): bool =
  lex.curStartPos.line = lex.source.lineNumber
  lex.curStartPos.column = 1
  lex.endToken()
  lex.cur = Token.DocumentEnd
  lex.state = expectLineEnd
  lex.lineStartState = outsideDoc
  return true

proc atSuffix(lex: var Lexer): bool =
  lex.startToken()
  lex.evaluated.setLen(0)
  var curStart = lex.tokenStart - 1
  while true:
    case lex.c
    of uriChars: lex.advance()
    of '%':
      if curStart <= lex.source.bufpos - 2:
        lex.evaluated.add(lex.source.buf[curStart..lex.source.bufpos - 2])
      lex.readHexSequence(2)
      curStart = lex.source.bufpos
      lex.advance()
    else: break
  if curStart <= lex.source.bufpos - 2:
    lex.evaluated.add(lex.source.buf[curStart..lex.source.bufpos - 2])
  lex.endToken()
  lex.cur = Token.Suffix
  lex.state = afterToken
  return true

proc streamEnd(lex: var Lexer): bool =
  lex.startToken()
  lex.endToken()
  lex.cur = Token.StreamEnd
  return true