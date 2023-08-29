#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## =====================
## Module yaml/presenter
## =====================
##
## This is the presenter API, used for generating YAML character streams.

import std / [streams, deques, strutils, options]
import data, taglib, stream, private/internal, hints, parser

type

  ContainerStyle* = enum
    ## How to serialize containers nodes.
    ##
    ## - ``cBlock`` writes all container nodes in block style,
    ##   i.e. indentation-based.
    ## - ``cFlow`` writes all container nodes in flow style,
    ##   i.e. JSON-like.
    ## - ``cMixed`` writes container nodes that only contain alias nodes
    ##   and short scalar nodes in flow style, all other container nodes
    ##   in block style.
    cBlock, cFlow, cMixed

  NewLineStyle* = enum
    ## What kind of newline sequence is used when presenting.
    ##
    ## - ``nlLF``: Use a single linefeed char as newline.
    ## - ``nlCRLF``: Use a sequence of carriage return and linefeed as
    ##   newline.
    ## - ``nlOSDefault``: Use the target operation system's default newline
    ##   sequence (CRLF on Windows, LF everywhere else).
    ## - ``nlNone``: Don't use newlines, write everything in one line.
    ##   forces ContainerStyle cFlow.
    nlLF, nlCRLF, nlOSDefault, nlNone

  OutputYamlVersion* = enum
    ## Specify which YAML version number the presenter shall emit. The
    ## presenter will always emit content that is valid YAML 1.1, but by
    ## default will write a directive ``%YAML 1.2``. For compatibility with
    ## other YAML implementations, it is possible to change this here.
    ##
    ## It is also possible to specify that the presenter shall not emit any
    ## YAML version. The generated content is then guaranteed to be valid
    ## YAML 1.1 and 1.2 (but not 1.0 or any newer YAML version).
    ov1_2, ov1_1, ovNone

  ScalarQuotingStyle* = enum
    ## Specifies whether scalars should forcibly be double-quoted.
    ## - ``sqUnset``: Quote where necessary
    ## - ``sqDouble``: Force double-quoted style for every scalar
    ## - ``sqJson``: Force JSON-compatible double-quoted style for every scalar
    ##   except for scalars of other JSON types (bool, int, double)
    sqUnset, sqDouble, sqJson
    
  DirectivesEndStyle* = enum
    ## Whether to write a directives end marker '---'
    ## - ``deAlways``: Always write it.
    ## - ``deIfNecessary``: Write it if any directive has been written,
    ##   or if the root node has an explicit tag
    ## - ``deNever``: Don't write it. Suppresses output of directives
    deAlways, deIfNecessary, deNever

  PresentationOptions* = object
    ## Options for generating a YAML character stream
    containers*     : ContainerStyle = cMixed ## how mappings and sequences are presented
    indentationStep*: int = 2 ## how many spaces a new level should be indented
    newlines*       : NewLineStyle = nlOSDefault ## kind of newline sequence to use
    outputVersion*  : OutputYamlVersion = ovNone ## whether to write the %YAML tag
    maxLineLength*  : Option[int] = some(80) ## max length of a line, including indentation
    directivesEnd*  : DirectivesEndStyle = deIfNecessary ## whether to write '---' after tags
    suppressAttrs*  : bool = false ## whether to suppress all attributes on nodes
    quoting*        : ScalarQuotingStyle = sqUnset ## how scalars are quoted
    condenseFlow*   : bool = true ## whether non-nested flow containers use a single line
    explicitKeys*   : bool = false ## whether mapping keys should always use '?'

  YamlPresenterJsonError* = object of ValueError
    ## Exception that may be raised by the YAML presenter when it is
    ## instructed to output JSON, but is unable to do so. This may occur if:
    ##
    ## - The given `YamlStream <#YamlStream>`_ contains a map which has any
    ##   non-scalar type as key.
    ## - Any float scalar bears a ``NaN`` or positive/negative infinity value

  YamlPresenterOutputError* = object of ValueError
    ## Exception that may be raised by the YAML presenter. This occurs if
    ## writing character data to the output stream raises any exception.
    ## The error that has occurred is available from ``parent``.

  DumperState = enum
    dBlockExplicitMapKey, dBlockImplicitMapKey, dBlockMapValue,
    dBlockInlineMap, dBlockSequenceItem, dFlowImplicitMapKey, dFlowMapValue,
    dFlowExplicitMapKey, dFlowSequenceItem, dFlowMapStart, dFlowSequenceStart
  
  DumperLevel = tuple
    state: DumperState
    indentation: int
    singleLine: bool
    wroteAnything: bool

  ScalarStyle = enum
    sLiteral, sFolded, sPlain, sDoubleQuoted

  Context = object
    target: Stream
    options: PresentationOptions
    handles: seq[tuple[handle, uriPrefix: string]]
    levels: seq[DumperLevel]
    needsWhitespace: int

proc level(ctx: var Context): var DumperLevel = ctx.levels[^1]
  
proc level(ctx: Context): DumperLevel = ctx.levels[^1]

proc state(ctx: Context): DumperState = ctx.level.state

proc `state=`(ctx: var Context, v: DumperState) =
  ctx.level.state = v

proc indentation(ctx: Context): int =
  result = if ctx.levels.len == 0: 0 else: ctx.level.indentation

proc searchHandle(ctx: Context, tag: string):
    tuple[handle: string, len: int] {.raises: [].} =
  ## search in the registered tag handles for one whose prefix matches the start
  ## of the given tag. If multiple registered handles match, the one with the
  ## longest prefix is returned. If no registered handle matches, ("", 0) is
  ## returned.
  result.len = 0
  for item in ctx.handles:
    if item.uriPrefix.len > result.len:
      if tag.startsWith(item.uriPrefix):
        result.len = item.uriPrefix.len
        result.handle = item.handle

proc inspect(scalar: string, indentation: int,
             words, lines: var seq[tuple[start, finish: int]],
             lineLength: Option[int]):
    ScalarStyle {.raises: [].} =
  var
    inLine = false
    inWord = false
    multipleSpaces = true
    curWord, curLine: tuple[start, finish: int]
    canUseFolded = true
    canUseLiteral = true
    canUsePlain = scalar.len > 0 and
        scalar[0] notin {'@', '`', '|', '>', '&', '*', '!', ' ', '\t'}
  for i, c in scalar:
    case c
    of ' ':
      if inWord:
        if not multipleSpaces:
          curWord.finish = i - 1
          inWord = false
      else:
        multipleSpaces = true
        inWord = true
        if not inLine:
          inLine = true
          curLine.start = i
          # space at beginning of line will preserve previous and next
          # line break. that is currently too complex to handle.
          canUseFolded = false
    of '\l':
      canUsePlain = false     # we don't use multiline plain scalars
      curWord.finish = i - 1
      if lineLength.isSome and
         curWord.finish - curWord.start + 1 > lineLength.get() - indentation:
        return if canUsePlain: sPlain else: sDoubleQuoted
      words.add(curWord)
      inWord = false
      curWord.start = i + 1
      multipleSpaces = true
      if not inLine: curLine.start = i
      inLine = false
      curLine.finish = i - 1
      if lineLength.isSome and
         curLine.finish - curLine.start + 1 > lineLength.get() - indentation:
        canUseLiteral = false
      lines.add(curLine)
    else:
      if c in {'{', '}', '[', ']', ',', '#', '-', ':', '?', '%', '"', '\''} or
          c.ord < 32: canUsePlain = false
      if not inLine:
        curLine.start = i
        inLine = true
      if not inWord:
        if not multipleSpaces:
          if lineLength.isSome and
             curWord.finish - curWord.start + 1 > lineLength.get() - indentation:
            return if canUsePlain: sPlain else: sDoubleQuoted
          words.add(curWord)
        curWord.start = i
        inWord = true
        multipleSpaces = false
  if inWord:
    curWord.finish = scalar.len - 1
    if lineLength.isSome and
       curWord.finish - curWord.start + 1 > lineLength.get() - indentation:
      return if canUsePlain: sPlain else: sDoubleQuoted
    words.add(curWord)
  if inLine:
    curLine.finish = scalar.len - 1
    if lineLength.isSome and
       curLine.finish - curLine.start + 1 > lineLength.get() - indentation:
      canUseLiteral = false
    lines.add(curLine)
  if lineLength.isNone or scalar.len <= lineLength.get() - indentation:
    result = if canUsePlain: sPlain else: sDoubleQuoted
  elif canUseLiteral: result = sLiteral
  elif canUseFolded: result = sFolded
  elif canUsePlain: result = sPlain
  else: result = sDoubleQuoted

proc append(ctx: var Context, val: string | char) {.inline.} =
  if ctx.needsWhitespace > 0:
    ctx.target.write(repeat(' ', ctx.needsWhitespace))
    ctx.needsWhitespace = 0
  ctx.target.write(val)
  if ctx.levels.len > 0: ctx.level.wroteAnything = true

proc whitespace(ctx: var Context, single: bool = false) {.inline.} =
  if single or ctx.options.indentationStep == 1: ctx.needsWhitespace = 1
  else: ctx.needsWhitespace = ctx.options.indentationStep - 1

proc newline(ctx: var Context) {.inline.} =
  case ctx.options.newlines
  of nlCRLF: ctx.target.write("\c\l")
  of nlLF: ctx.target.write("\l")
  else: ctx.target.write("\n")
  ctx.needsWhitespace = 0
  if ctx.levels.len > 0: ctx.level.wroteAnything = true

proc writeDoubleQuoted(ctx: var Context, scalar: string)
    {.raises: [YamlPresenterOutputError].} =
  let indentation = ctx.indentation + ctx.options.indentationStep
  var curPos = indentation
  let t = ctx.target
  try:
    ctx.append('"')
    curPos.inc()
    for c in scalar:
      if ctx.options.maxLineLength.isSome and
         curPos == ctx.options.maxLineLength.get() - 1:
        t.write('\\')
        ctx.newline()
        t.write(repeat(' ', indentation))
        curPos = indentation
        if c == ' ':
          t.write('\\')
          curPos.inc()
      case c
      of '"':
        t.write("\\\"")
        curPos.inc(2)
      of '\l':
        t.write("\\n")
        curPos.inc(2)
      of '\t':
        t.write("\\t")
        curPos.inc(2)
      of '\\':
        t.write("\\\\")
        curPos.inc(2)
      else:
        if ord(c) < 32:
          t.write("\\x" & toHex(ord(c), 2))
          curPos.inc(4)
        else:
          t.write(c)
          curPos.inc()
    t.write('"')
  except CatchableError as ce:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = ce
    raise e

proc writeDoubleQuotedJson(ctx: var Context, scalar: string)
    {.raises: [YamlPresenterOutputError].} =
  let t = ctx.target
  try:
    ctx.append('"')
    for c in scalar:
      case c
      of '"': t.write("\\\"")
      of '\\': t.write("\\\\")
      of '\l': t.write("\\n")
      of '\t': t.write("\\t")
      of '\f': t.write("\\f")
      of '\b': t.write("\\b")
      else:
        if ord(c) < 32: t.write("\\u" & toHex(ord(c), 4)) else: t.write(c)
    t.write('"')
  except:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = getCurrentException()
    raise e

proc writeLiteral(
    ctx: var Context, scalar: string, lines: seq[tuple[start, finish: int]])
    {.raises: [YamlPresenterOutputError].} =
  let indentation = ctx.indentation + ctx.options.indentationStep
  let t = ctx.target
  try:
    ctx.append('|')
    if scalar[^1] != '\l': t.write('-')
    if scalar[0] in [' ', '\t']: t.write($ctx.options.indentationStep)
    for line in lines:
      ctx.newline()
      t.write(repeat(' ', indentation))
      if line.finish >= line.start:
        t.write(scalar[line.start .. line.finish])
  except CatchableError as ce:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = ce
    raise e

proc writeFolded(ctx: var Context, scalar: string,
                 words: seq[tuple[start, finish: int]])
    {.raises: [YamlPresenterOutputError].} =
  let t = ctx.target
  let indentation = ctx.indentation + ctx.options.indentationStep
  let lineLength = (
    if ctx.options.maxLineLength.isSome:
      ctx.options.maxLineLength.get() else: 1024)
  try:
    ctx.append('>')
    if scalar[^1] != '\l': t.write('-')
    if scalar[0] in [' ', '\t']: t.write($ctx.options.indentationStep)
    var curPos = lineLength
    for word in words:
      if word.start > 0 and scalar[word.start - 1] == '\l':
        ctx.newline()
        ctx.newline()
        t.write(repeat(' ', indentation))
        curPos = indentation
      elif curPos + (word.finish - word.start + 1) > lineLength:
        ctx.newline()
        t.write(repeat(' ', indentation))
        curPos = indentation
      else:
        t.write(' ')
        curPos.inc()
      t.write(scalar[word.start .. word.finish])
      curPos += word.finish - word.start + 1
  except CatchableError as ce:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = ce
    raise e

template safeWrite(ctx: var Context, s: string or char) =
  try: ctx.append(s)
  except CatchableError as ce:
    var e = newException(YamlPresenterOutputError, "")
    e.parent = ce
    raise e

template safeNewline(c: var Context) =
  try: ctx.newline()
  except CatchableError as ce:
    var e = newException(YamlPresenterOutputError, "")
    e.parent = ce
    raise e

proc startItem(ctx: var Context, isObject: bool) {.raises: [YamlPresenterOutputError].} =
  let t = ctx.target
  try:
    case ctx.state
    of dBlockMapValue:
      if ctx.level.wroteAnything or ctx.options.indentationStep < 2:
        ctx.newline()
        t.write(repeat(' ', ctx.indentation))
      else:
        ctx.level.wroteAnything = true
      if isObject or ctx.options.explicitKeys:
        ctx.append('?')
        ctx.whitespace()
        ctx.state = dBlockExplicitMapKey
      else: ctx.state = dBlockImplicitMapKey
    of dBlockInlineMap: ctx.state = dBlockImplicitMapKey
    of dBlockExplicitMapKey:
      ctx.newline()
      t.write(repeat(' ', ctx.indentation))
      t.write(':')
      ctx.whitespace()
      ctx.state = dBlockMapValue
    of dBlockImplicitMapKey:
      ctx.append(':')
      ctx.whitespace(true)
      ctx.state = dBlockMapValue
    of dFlowExplicitMapKey:
      if ctx.options.newlines != nlNone:
        ctx.newline()
        t.write(repeat(' ', ctx.indentation))
      ctx.append(':')
      ctx.whitespace()
      ctx.state = dFlowMapValue
    of dFlowMapValue:
      ctx.append(',')
      ctx.whitespace(true)
      if not ctx.level.singleLine:
        ctx.newline()
        t.write(repeat(' ', ctx.indentation))
      if not isObject and not ctx.options.explicitKeys:
        ctx.state = dFlowImplicitMapKey
      else:
        t.write('?')
        ctx.whitespace()
        ctx.state = dFlowExplicitMapKey
    of dFlowMapStart:
      if not ctx.level.singleLine:
        ctx.newline()
        t.write(repeat(' ', ctx.indentation))
      if not isObject and not ctx.options.explicitKeys:
        ctx.state = dFlowImplicitMapKey
      else:
        ctx.append('?')
        ctx.whitespace()
        ctx.state = dFlowExplicitMapKey
    of dFlowImplicitMapKey:
      ctx.append(':')
      ctx.whitespace(true)
      ctx.state = dFlowMapValue
    of dBlockSequenceItem:
      if ctx.level.wroteAnything or ctx.options.indentationStep < 2:
        ctx.newline()
        t.write(repeat(' ', ctx.indentation))
      else:
        ctx.level.wroteAnything = true
      ctx.append('-')
      ctx.whitespace()
    of dFlowSequenceStart:
      if not ctx.level.singleLine:
        ctx.newline()
        t.write(repeat(' ', ctx.indentation))
      ctx.state = dFlowSequenceItem
    of dFlowSequenceItem:
      ctx.append(',')
      ctx.whitespace(true)
      if not ctx.options.condenseFlow:
        ctx.newline()
        t.write(repeat(' ', ctx.indentation))
  except CatchableError as ce:
    var e = newException(YamlPresenterOutputError, "")
    e.parent = ce
    raise e

proc writeTagAndAnchor(ctx: var Context, props: Properties): bool
    {.raises: [YamlPresenterOutputError].} =
  if ctx.options.suppressAttrs: return false
  let t = ctx.target
  result = false
  try:
    if props.tag notin [yTagQuestionMark, yTagExclamationMark]:
      let tagUri = $props.tag
      let (handle, length) = ctx.searchHandle(tagUri)
      if length > 0:
        ctx.append(handle)
        t.write(tagUri[length..tagUri.high])
        ctx.whitespace(true)
      else:
        ctx.append("!<")
        t.write(tagUri)
        t.write('>')
        ctx.whitespace(true)
      result = true
    if props.anchor != yAnchorNone:
      ctx.append("&")
      t.write($props.anchor)
      ctx.whitespace(true)
      result = true
  except CatchableError as ce:
    var e = newException(YamlPresenterOutputError, "")
    e.parent = ce
    raise e

proc nextItem(c: var Deque, s: YamlStream):
    Event {.raises: [YamlStreamError].} =
  if c.len > 0:
    try: result = c.popFirst
    except IndexDefect: internalError("Unexpected IndexError")
  else:
    result = s.next()

proc doPresent(ctx: var Context, s: YamlStream)
    {.raises: [YamlPresenterJsonError, YamlPresenterOutputError,
     YamlStreamError].} =
  var
    cached = initDeQue[Event]()
    firstDoc = true
    wroteDirectivesEnd = false
  while true:
    let item = nextItem(cached, s)
    case item.kind
    of yamlStartStream: discard
    of yamlEndStream: break
    of yamlStartDoc:
      if not firstDoc:
        ctx.safeWrite("...")
        ctx.safeNewline()
      wroteDirectivesEnd =
        ctx.options.directivesEnd == deAlways or not s.peek().emptyProperties()
      
      if ctx.options.directivesEnd != deNever:
        resetHandles(ctx.handles)
        for v in item.handles:
          discard registerHandle(ctx.handles, v.handle, v.uriPrefix)
      
        try:
          case ctx.options.outputVersion
          of ov1_2:
              ctx.target.write("%YAML 1.2")
              ctx.newline()
              wroteDirectivesEnd = true
          of ov1_1:
              ctx.target.write("%YAML 1.1")
              ctx.newline()
              wroteDirectivesEnd = true
              echo "write --- because %YAML"
          of ovNone: discard
          for v in ctx.handles:
            if v.handle == "!":
              if v.uriPrefix != "!":
                ctx.target.write("%TAG ! " & v.uriPrefix)
                ctx.newline()
                wroteDirectivesEnd = true
            elif v.handle == "!!":
              if v.uriPrefix != yamlTagRepositoryPrefix:
                ctx.target.write("%TAG !! " & v.uriPrefix)
                ctx.newline()
                wroteDirectivesEnd = true
            else:
              ctx.target.write("%TAG " & v.handle & ' ' & v.uriPrefix)
              ctx.newline()
              wroteDirectivesEnd = true
        except CatchableError as ce:
          var e = newException(YamlPresenterOutputError, "")
          e.parent = ce
          raise e
      if wroteDirectivesEnd:
        ctx.safeWrite("---")
        ctx.whitespace(true)
    of yamlScalar:
      if ctx.levels.len > 0:
        ctx.startItem(false)
      discard ctx.writeTagAndAnchor(item.scalarProperties)
      if ctx.levels.len == 0:
        if wroteDirectivesEnd: ctx.safeNewline()
      case ctx.options.quoting
      of sqJson:
        var hint = yTypeUnknown
        if ctx.state == dFlowMapValue: hint = guessType(item.scalarContent)
        let tag = item.scalarProperties.tag
        if tag in [yTagQuestionMark, yTagBoolean] and
            hint in {yTypeBoolTrue, yTypeBoolFalse}:
          ctx.safeWrite(if hint == yTypeBoolTrue: "true" else: "false")
        elif tag in [yTagQuestionMark, yTagNull] and
            hint == yTypeNull:
          ctx.safeWrite("null")
        elif tag in [yTagQuestionMark, yTagInteger,
            yTagNimInt8, yTagNimInt16, yTagNimInt32, yTagNimInt64,
            yTagNimUInt8, yTagNimUInt16, yTagNimUInt32, yTagNimUInt64] and
            hint == yTypeInteger:
          ctx.safeWrite(item.scalarContent)
        elif tag in [yTagQuestionMark, yTagFloat, yTagNimFloat32,
            yTagNimFloat64] and hint in {yTypeFloatInf, yTypeFloatNaN}:
          raise newException(YamlPresenterJsonError,
              "Infinity and not-a-number values cannot be presented as JSON!")
        elif tag in [yTagQuestionMark, yTagFloat] and
            hint == yTypeFloat:
          ctx.safeWrite(item.scalarContent)
        else: ctx.writeDoubleQuotedJson(item.scalarContent)
      of sqDouble:
        ctx.writeDoubleQuoted(item.scalarContent)
      else:
        var words, lines = newSeq[tuple[start, finish: int]]()
        case item.scalarContent.inspect(
            ctx.indentation + ctx.options.indentationStep, words, lines,
            ctx.options.maxLineLength)
        of sLiteral: ctx.writeLiteral(item.scalarContent, lines)
        of sFolded: ctx.writeFolded(item.scalarContent, words)
        of sPlain: ctx.safeWrite(item.scalarContent)
        of sDoubleQuoted: ctx.writeDoubleQuoted(item.scalarContent)
    of yamlAlias:
      if ctx.options.quoting == sqJson:
        raise newException(YamlPresenterJsonError,
                           "Alias not allowed in JSON output")
      yAssert ctx.levels.len > 0
      ctx.startItem(false)
      try:
        ctx.append('*')
        ctx.target.write($item.aliasTarget)
      except CatchableError as ce:
        var e = newException(YamlPresenterOutputError, "")
        e.parent = ce
        raise e
    of yamlStartSeq:
      var nextState: DumperState
      case ctx.options.containers
      of cMixed:
        var length = 0
        while true:
          let next = s.next()
          cached.addLast(next)
          case next.kind
          of yamlScalar: length += 2 + next.scalarContent.len
          of yamlAlias: length += 6
          of yamlEndSeq: break
          else:
            length = high(int)
            break
        nextState = if length <= 60: dFlowSequenceStart else: dBlockSequenceItem
      of cFlow: nextState = dFlowSequenceStart
      of cBlock:
        let next = s.peek()
        if next.kind == yamlEndSeq: nextState = dFlowSequenceStart
        else: nextState = dBlockSequenceItem

      var indentation = 0
      var singleLine = ctx.options.condenseFlow or ctx.options.newlines == nlNone
      
      var wroteAnything = false
      if ctx.levels.len > 0: wroteAnything = ctx.state == dBlockImplicitMapKey
      
      if ctx.levels.len == 0:
        if nextState == dFlowSequenceStart:
          indentation = ctx.options.indentationStep
      else:
        ctx.startItem(true)
        indentation = ctx.indentation + ctx.options.indentationStep
      
      let wroteAttrs = ctx.writeTagAndAnchor(item.seqProperties)
      if wroteAttrs or (wroteDirectivesEnd and ctx.levels.len == 0):
        wroteAnything = true

      if nextState == dFlowSequenceStart:
        if ctx.levels.len == 0:
          if wroteAttrs or wroteDirectivesEnd: ctx.safeNewline()
        ctx.safeWrite('[')
      
      if ctx.levels.len > 0 and not ctx.options.condenseFlow and
          ctx.state in [dBlockExplicitMapKey, dBlockMapValue,
                        dBlockImplicitMapKey, dBlockSequenceItem]:
        indentation += ctx.options.indentationStep
        if ctx.options.newlines != nlNone: singleLine = false
      ctx.levels.add (nextState, indentation, singleLine, wroteAnything)
    of yamlStartMap:
      var nextState: DumperState
      case ctx.options.containers
      of cMixed:
        type MapParseState = enum
          mpInitial, mpKey, mpValue, mpNeedBlock
        var mps: MapParseState = mpInitial
        while mps != mpNeedBlock:
          case s.peek().kind
          of yamlScalar, yamlAlias:
            case mps
            of mpInitial: mps = mpKey
            of mpKey: mps = mpValue
            else: mps = mpNeedBlock
          of yamlEndMap: break
          else: mps = mpNeedBlock
        nextState = if mps == mpNeedBlock: dBlockMapValue else: dBlockInlineMap
      of cFlow: nextState = dFlowMapStart
      of cBlock:
        let next = s.peek()
        if next.kind == yamlEndMap: nextState = dFlowMapStart
        else: nextState = dBlockMapValue
      
      var indentation = 0
      var singleLine = ctx.options.condenseFlow or ctx.options.newlines == nlNone
      
      var wroteAnything = false
      if ctx.levels.len > 0: wroteAnything = ctx.state == dBlockImplicitMapKey
      
      if ctx.levels.len == 0:
        if nextState == dFlowMapStart:
          indentation = ctx.options.indentationStep
      else:
        ctx.startItem(true)
        indentation = ctx.indentation + ctx.options.indentationStep
      
      let wroteAttrs = ctx.writeTagAndAnchor(item.properties)
      if wroteAttrs or (wroteDirectivesEnd and ctx.levels.len == 0):
        wroteAnything = true

      if nextState == dFlowMapStart:
        if ctx.levels.len == 0:
          if wroteAttrs or wroteDirectivesEnd: ctx.safeNewline()
        ctx.safeWrite('{')

      if ctx.levels.len > 0 and not ctx.options.condenseFlow and
          ctx.state in [dBlockExplicitMapKey, dBlockMapValue,
                        dBlockImplicitMapKey, dBlockSequenceItem]:
        indentation += ctx.options.indentationStep
        if ctx.options.newlines != nlNone: singleLine = false
      ctx.levels.add (nextState, indentation, singleLine, wroteAnything)
    of yamlEndSeq:
      yAssert ctx.levels.len > 0
      let level = ctx.levels.pop()
      case level.state
      of dFlowSequenceItem:
        try:
          if not level.singleLine:
            ctx.newline()
            ctx.target.write(repeat(' ', ctx.indentation))
          ctx.target.write(']')
        except CatchableError as ce:
          var e = newException(YamlPresenterOutputError, "")
          e.parent = ce
          raise e
      of dFlowSequenceStart: ctx.safeWrite(']')
      of dBlockSequenceItem: discard
      else: internalError("Invalid popped level")
    of yamlEndMap:
      yAssert ctx.levels.len > 0
      let level = ctx.levels.pop()
      case level.state
      of dFlowMapValue:
        try:
          if not level.singleLine:
            ctx.safeNewline()
            ctx.target.write(repeat(' ', ctx.indentation))
          ctx.append('}')
        except CatchableError as ce:
          var e = newException(YamlPresenterOutputError, "")
          e.parent = ce
          raise e
      of dFlowMapStart: ctx.safeWrite('}')
      of dBlockMapValue, dBlockInlineMap: discard
      else: internalError("Invalid level: " & $level)
    of yamlEndDoc:
      firstDoc = false
      ctx.safeNewline()

proc present*(
  s      : YamlStream,
  target : Stream,
  options: PresentationOptions = PresentationOptions()
) {.raises: [
  YamlPresenterJsonError, YamlPresenterOutputError,
  YamlStreamError
].} =
  ## Convert ``s`` to a YAML character stream and write it to ``target``.
  var c = Context(target: target, options: options)
  doPresent(c, s)

proc present*(
  s      : YamlStream,
  options: PresentationOptions = PresentationOptions()
): string {.raises: [
  YamlPresenterJsonError, YamlPresenterOutputError,
  YamlStreamError
].} =
  ## Convert ``s`` to a YAML character stream and return it as string.

  var
    ss = newStringStream()
    c = Context(target: ss, options: options)
  doPresent(c, s)
  return ss.data

proc doTransform(
  ctx  : var Context,
  input: Stream,
  resolveToCoreYamlTags: bool
) =
  var parser: YamlParser
  parser.init()
  var events = parser.parse(input)
  try:
    if ctx.options.explicitKeys:
      var bys: YamlStream = newBufferYamlStream()
      for e in events:
        if resolveToCoreYamlTags:
          var event = e
          case event.kind
          of yamlStartStream, yamlEndStream, yamlStartDoc, yamlEndDoc, yamlEndMap, yamlAlias, yamlEndSeq:
            discard
          of yamlStartMap:
            if event.mapProperties.tag in [yTagQuestionMark, yTagExclamationMark]:
              event.mapProperties.tag = yTagMapping
          of yamlStartSeq:
            if event.seqProperties.tag in [yTagQuestionMark, yTagExclamationMark]:
              event.seqProperties.tag = yTagSequence
          of yamlScalar:
            if event.scalarProperties.tag == yTagQuestionMark:
              case guessType(event.scalarContent)
              of yTypeInteger: event.scalarProperties.tag = yTagInteger
              of yTypeFloat, yTypeFloatInf, yTypeFloatNaN:
                event.scalarProperties.tag = yTagFloat
              of yTypeBoolTrue, yTypeBoolFalse: event.scalarProperties.tag = yTagBoolean
              of yTypeNull: event.scalarProperties.tag = yTagNull
              of yTypeTimestamp: event.scalarProperties.tag = yTagTimestamp
              of yTypeUnknown: event.scalarProperties.tag = yTagString
            elif event.scalarProperties.tag == yTagExclamationMark:
              event.scalarProperties.tag = yTagString
          BufferYamlStream(bys).put(event)
        else: BufferYamlStream(bys).put(e)
      doPresent(ctx, bys)
    else:
      doPresent(ctx, events)
  except YamlStreamError as e:
    var curE: ref Exception = e
    while curE.parent of YamlStreamError: curE = curE.parent
    if curE.parent of IOError: raise (ref IOError)(curE.parent)
    elif curE.parent of OSError: raise (ref OSError)(curE.parent)
    elif curE.parent of YamlParserError: raise (ref YamlParserError)(curE.parent)
    else: internalError("Unexpected exception: " & curE.parent.repr)

proc genInput(input: Stream): Stream = input
proc genInput(input: string): Stream = newStringStream(input)

proc transform*(
  input  : Stream | string,
  output : Stream,
  options: PresentationOptions = PresentationOptions(),
  resolveToCoreYamlTags: bool = false
) {.raises: [
  IOError, OSError, YamlParserError, YamlPresenterJsonError,
  YamlPresenterOutputError
].} =
  ## Parser ``input`` as YAML character stream and then dump it to ``output``
  ## while resolving non-specific tags to the ones in the YAML core tag
  ## library. If ``resolveToCoreYamlTags`` is ``true``, non-specific tags will
  ## be replaced by specific tags according to the YAML core schema.
  var c = Context(target: output, options: options)
  doTransform(c, genInput(input), resolveToCoreYamlTags)

proc transform*(
  input  : Stream | string,
  options: PresentationOptions = PresentationOptions(),
  resolveToCoreYamlTags: bool = false
): string {.raises: [
  IOError, OSError, YamlParserError, YamlPresenterJsonError,
  YamlPresenterOutputError
].} =
  ## Parser ``input`` as YAML character stream, resolves non-specific tags to
  ## the ones in the YAML core tag library, and then returns a serialized
  ## YAML string that represents the stream. If ``resolveToCoreYamlTags`` is
  ## ``true``, non-specific tags will be replaced by specific tags according to
  ## the YAML core schema.
  var
    ss = newStringStream()
    c = Context(target: ss, options: options)
  doTransform(c, genInput(input), resolveToCoreYamlTags)
  return ss.data
