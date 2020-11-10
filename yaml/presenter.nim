#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## =====================
## Module yaml.presenter
## =====================
##
## This is the presenter API, used for generating YAML character streams.

import streams, deques, strutils
import data, taglib, stream, private/internal, hints, parser, stream

type
  PresentationStyle* = enum
    ## Different styles for YAML character stream output.
    ##
    ## - ``ypsMinimal``: Single-line flow-only output which tries to
    ##   use as few characters as possible.
    ## - ``ypsCanonical``: Canonical YAML output. Writes all tags except
    ##   for the non-specific tags ``?`` and ``!``, uses flow style, quotes
    ##   all string scalars.
    ## - ``ypsDefault``: Tries to be as human-readable as possible. Uses
    ##   block style by default, but tries to condense mappings and
    ##   sequences which only contain scalar nodes into a single line using
    ##   flow style.
    ## - ``ypsJson``: Omits the ``%YAML`` directive and the ``---``
    ##   marker. Uses flow style. Flattens anchors and aliases, omits tags.
    ##   Output will be parseable as JSON. ``YamlStream`` to dump may only
    ##   contain one document.
    ## - ``ypsBlockOnly``: Formats all output in block style, does not use
    ##   flow style at all.
    psMinimal, psCanonical, psDefault, psJson, psBlockOnly

  TagStyle* = enum
    ## Whether object should be serialized with explicit tags.
    ##
    ## - ``tsNone``: No tags will be outputted unless necessary.
    ## - ``tsRootOnly``: A tag will only be outputted for the root tag and
    ##   where necessary.
    ## - ``tsAll``: Tags will be outputted for every object.
    tsNone, tsRootOnly, tsAll

  AnchorStyle* = enum
    ## How ref object should be serialized.
    ##
    ## - ``asNone``: No anchors will be outputted. Values present at
    ##   multiple places in the content that should be serialized will be
    ##   fully serialized at every occurence. If the content is cyclic, this
    ##   will lead to an endless loop!
    ## - ``asTidy``: Anchors will only be generated for objects that
    ##   actually occur more than once in the content to be serialized.
    ##   This is a bit slower and needs more memory than ``asAlways``.
    ## - ``asAlways``: Achors will be generated for every ref object in the
    ##   content to be serialized, regardless of whether the object is
    ##   referenced again afterwards
    asNone, asTidy, asAlways

  NewLineStyle* = enum
    ## What kind of newline sequence is used when presenting.
    ##
    ## - ``nlLF``: Use a single linefeed char as newline.
    ## - ``nlCRLF``: Use a sequence of carriage return and linefeed as
    ##   newline.
    ## - ``nlOSDefault``: Use the target operation system's default newline
    ##   sequence (CRLF on Windows, LF everywhere else).
    nlLF, nlCRLF, nlOSDefault

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

  PresentationOptions* = object
    ## Options for generating a YAML character stream
    style*: PresentationStyle
    indentationStep*: int
    newlines*: NewLineStyle
    outputVersion*: OutputYamlVersion

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

  ScalarStyle = enum
    sLiteral, sFolded, sPlain, sDoubleQuoted

  Context = object
    target: Stream
    tagLib: TagLibrary
    options: PresentationOptions
    handles: seq[tuple[handle, uriPrefix: string]]
    levels: seq[DumperState]

const
  defaultPresentationOptions* =
    PresentationOptions(style: psDefault, indentationStep: 2,
                            newlines: nlOSDefault)

proc defineOptions*(style: PresentationStyle = psDefault,
                    indentationStep: int = 2,
                    newlines: NewLineStyle = nlOSDefault,
                    outputVersion: OutputYamlVersion = ov1_2):
    PresentationOptions {.raises: [].} =
  ## Define a set of options for presentation. Convenience proc that requires
  ## you to only set those values that should not equal the default.
  PresentationOptions(style: style, indentationStep: indentationStep,
                      newlines: newlines, outputVersion: outputVersion)

proc state(c: Context): DumperState = c.levels[^1]

proc `state=`(c: var Context, v: DumperState) =
  c.levels[^1] = v

proc searchHandle(c: Context, tag: string):
    tuple[handle: string, len: int] {.raises: [].} =
  ## search in the registered tag handles for one whose prefix matches the start
  ## of the given tag. If multiple registered handles match, the one with the
  ## longest prefix is returned. If no registered handle matches, ("", 0) is
  ## returned.
  result.len = 0
  for item in c.handles:
    if item.uriPrefix.len > result.len:
      if tag.startsWith(item.uriPrefix):
        result.len = item.uriPrefix.len
        result.handle = item.handle

proc inspect(scalar: string, indentation: int,
             words, lines: var seq[tuple[start, finish: int]]):
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
          # linebreak. that is currently too complex to handle.
          canUseFolded = false
    of '\l':
      canUsePlain = false     # we don't use multiline plain scalars
      curWord.finish = i - 1
      if curWord.finish - curWord.start + 1 > 80 - indentation:
        return if canUsePlain: sPlain else: sDoubleQuoted
      words.add(curWord)
      inWord = false
      curWord.start = i + 1
      multipleSpaces = true
      if not inLine: curLine.start = i
      inLine = false
      curLine.finish = i - 1
      if curLine.finish - curLine.start + 1 > 80 - indentation:
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
          if curWord.finish - curWord.start + 1 > 80 - indentation:
            return if canUsePlain: sPlain else: sDoubleQuoted
          words.add(curWord)
        curWord.start = i
        inWord = true
        multipleSpaces = false
  if inWord:
    curWord.finish = scalar.len - 1
    if curWord.finish - curWord.start + 1 > 80 - indentation:
      return if canUsePlain: sPlain else: sDoubleQuoted
    words.add(curWord)
  if inLine:
    curLine.finish = scalar.len - 1
    if curLine.finish - curLine.start + 1 > 80 - indentation:
      canUseLiteral = false
    lines.add(curLine)
  if scalar.len <= 80 - indentation:
    result = if canUsePlain: sPlain else: sDoubleQuoted
  elif canUseLiteral: result = sLiteral
  elif canUseFolded: result = sFolded
  elif canUsePlain: result = sPlain
  else: result = sDoubleQuoted

template append(target: Stream, val: string | char) =
  target.write(val)

template append(target: ptr[string], val: string | char) =
  target[].add(val)

proc writeDoubleQuoted(c: Context, scalar: string, indentation: int,
                       newline: string)
            {.raises: [YamlPresenterOutputError].} =
  var curPos = indentation
  let t = c.target
  try:
    t.append('"')
    curPos.inc()
    for c in scalar:
      if curPos == 79:
        t.append('\\')
        t.append(newline)
        t.append(repeat(' ', indentation))
        curPos = indentation
        if c == ' ':
          t.append('\\')
          curPos.inc()
      case c
      of '"':
        t.append("\\\"")
        curPos.inc(2)
      of '\l':
        t.append("\\n")
        curPos.inc(2)
      of '\t':
        t.append("\\t")
        curPos.inc(2)
      of '\\':
        t.append("\\\\")
        curPos.inc(2)
      else:
        if ord(c) < 32:
          t.append("\\x" & toHex(ord(c), 2))
          curPos.inc(4)
        else:
          t.append(c)
          curPos.inc()
    t.append('"')
  except:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = getCurrentException()
    raise e

proc writeDoubleQuotedJson(c: Context, scalar: string)
    {.raises: [YamlPresenterOutputError].} =
  let t = c.target
  try:
    t.append('"')
    for c in scalar:
      case c
      of '"': t.append("\\\"")
      of '\\': t.append("\\\\")
      of '\l': t.append("\\n")
      of '\t': t.append("\\t")
      of '\f': t.append("\\f")
      of '\b': t.append("\\b")
      else:
        if ord(c) < 32: t.append("\\u" & toHex(ord(c), 4)) else: t.append(c)
    t.append('"')
  except:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = getCurrentException()
    raise e

proc writeLiteral(c: Context, scalar: string, indentation, indentStep: int,
                  lines: seq[tuple[start, finish: int]], newline: string)
    {.raises: [YamlPresenterOutputError].} =
  let t = c.target
  try:
    t.append('|')
    if scalar[^1] != '\l': t.append('-')
    if scalar[0] in [' ', '\t']: t.append($indentStep)
    for line in lines:
      t.append(newline)
      t.append(repeat(' ', indentation + indentStep))
      if line.finish >= line.start:
        t.append(scalar[line.start .. line.finish])
  except:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = getCurrentException()
    raise e

proc writeFolded(c: Context, scalar: string, indentation, indentStep: int,
                 words: seq[tuple[start, finish: int]],
                 newline: string)
    {.raises: [YamlPresenterOutputError].} =
  let t = c.target
  try:
    t.append(">")
    if scalar[^1] != '\l': t.append('-')
    if scalar[0] in [' ', '\t']: t.append($indentStep)
    var curPos = 80
    for word in words:
      if word.start > 0 and scalar[word.start - 1] == '\l':
        t.append(newline & newline)
        t.append(repeat(' ', indentation + indentStep))
        curPos = indentation + indentStep
      elif curPos + (word.finish - word.start) > 80:
        t.append(newline)
        t.append(repeat(' ', indentation + indentStep))
        curPos = indentation + indentStep
      else:
        t.append(' ')
        curPos.inc()
      t.append(scalar[word.start .. word.finish])
      curPos += word.finish - word.start + 1
  except:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = getCurrentException()
    raise e

template safeWrite(c: Context, s: string or char) =
  try: c.target.append(s)
  except:
    var e = newException(YamlPresenterOutputError, "")
    e.parent = getCurrentException()
    raise e

proc startItem(c: var Context, indentation: int, isObject: bool,
               newline: string) {.raises: [YamlPresenterOutputError].} =
  let t = c.target
  try:
    case c.state
    of dBlockMapValue:
      t.append(newline)
      t.append(repeat(' ', indentation))
      if isObject or c.options.style == psCanonical:
        t.append("? ")
        c.state = dBlockExplicitMapKey
      else: c.state = dBlockImplicitMapKey
    of dBlockInlineMap: c.state = dBlockImplicitMapKey
    of dBlockExplicitMapKey:
      t.append(newline)
      t.append(repeat(' ', indentation))
      t.append(": ")
      c.state = dBlockMapValue
    of dBlockImplicitMapKey:
      t.append(": ")
      c.state = dBlockMapValue
    of dFlowExplicitMapKey:
      if c.options.style != psMinimal:
        t.append(newline)
        t.append(repeat(' ', indentation))
      t.append(": ")
      c.state = dFlowMapValue
    of dFlowMapValue:
      if (isObject and c.options.style != psMinimal) or c.options.style in [psJson, psCanonical]:
        t.append(',' & newline & repeat(' ', indentation))
        if c.options.style == psJson: c.state = dFlowImplicitMapKey
        else:
          t.append("? ")
          c.state = dFlowExplicitMapKey
      elif isObject and c.options.style == psMinimal:
        t.append(", ? ")
        c.state = dFlowExplicitMapKey
      else:
        t.append(", ")
        c.state = dFlowImplicitMapKey
    of dFlowMapStart:
      if (isObject and c.options.style != psMinimal) or c.options.style in [psJson, psCanonical]:
        t.append(newline & repeat(' ', indentation))
        if c.options.style == psJson: c.state = dFlowImplicitMapKey
        else:
          t.append("? ")
          c.state = dFlowExplicitMapKey
      else: c.state = dFlowImplicitMapKey
    of dFlowImplicitMapKey:
      t.append(": ")
      c.state = dFlowMapValue
    of dBlockSequenceItem:
      t.append(newline)
      t.append(repeat(' ', indentation))
      t.append("- ")
    of dFlowSequenceStart:
      case c.options.style
      of psMinimal, psDefault: discard
      of psCanonical, psJson:
        t.append(newline)
        t.append(repeat(' ', indentation))
      of psBlockOnly: discard # can never happen
      c.state = dFlowSequenceItem
    of dFlowSequenceItem:
      case c.options.style
      of psMinimal, psDefault: t.append(", ")
      of psCanonical, psJson:
        t.append(',' & newline)
        t.append(repeat(' ', indentation))
      of psBlockOnly: discard # can never happen
  except:
    var e = newException(YamlPresenterOutputError, "")
    e.parent = getCurrentException()
    raise e

proc writeTagAndAnchor(c: Context, props: Properties) {.raises: [YamlPresenterOutputError].} =
  let t = c.target
  try:
    if props.tag notin [yTagQuestionMark, yTagExclamationMark]:
      let tagUri = $props.tag
      let (handle, length) = c.searchHandle(tagUri)
      if length > 0:
        t.append(handle)
        t.append(tagUri[length..tagUri.high])
        t.append(' ')
      else:
        t.append("!<")
        t.append(tagUri)
        t.append("> ")
    if props.anchor != yAnchorNone:
      t.append("&")
      t.append($props.anchor)
      t.append(' ')
  except:
    var e = newException(YamlPresenterOutputError, "")
    e.parent = getCurrentException()
    raise e

proc nextItem(c: var Deque, s: var YamlStream):
    Event {.raises: [YamlStreamError].} =
  if c.len > 0:
    try: result = c.popFirst
    except IndexDefect: internalError("Unexpected IndexError")
  else:
    result = s.next()

proc doPresent(c: var Context, s: var YamlStream) =
  var
    indentation = 0
    cached = initDeQue[Event]()
  let newline = if c.options.newlines == nlLF: "\l"
    elif c.options.newlines == nlCRLF: "\c\l" else: "\n"
  var firstDoc = true
  while true:
    let item = nextItem(cached, s)
    case item.kind
    of yamlStartStream: discard
    of yamlEndStream: break
    of yamlStartDoc:
      resetHandles(c.handles)
      for v in item.handles:
        discard registerHandle(c.handles, v.handle, v.uriPrefix)
      if not firstDoc:
        if c.options.style == psJson:
          raise newException(YamlPresenterJsonError,
              "Cannot output more than one document in JSON style")
        c.safeWrite("..." & newline)

      if c.options.style != psJson:
        try:
          case c.options.outputVersion
          of ov1_2: c.target.append("%YAML 1.2" & newline)
          of ov1_1: c.target.append("%YAML 1.1" & newLine)
          of ovNone: discard
          for v in c.handles:
            if v.handle == "!":
              if v.uriPrefix != "!":
                c.target.append("%TAG ! " & v.uriPrefix & newline)
            elif v.handle == "!!":
              if v.uriPrefix != yamlTagRepositoryPrefix:
                c.target.append("%TAG !! " & v.uriPrefix & newline)
            else:
              c.target.append("%TAG " & v.handle & ' ' & v.uriPrefix & newline)
          c.target.append("--- ")
        except:
          var e = newException(YamlPresenterOutputError, "")
          e.parent = getCurrentException()
          raise e
    of yamlScalar:
      if c.levels.len == 0:
        if c.options.style != psJson: c.safeWrite(newline)
      else:
        c.startItem(indentation, false, newline)
      if c.options.style != psJson:
        c.writeTagAndAnchor(item.scalarProperties)

      if c.options.style == psJson:
        let hint = guessType(item.scalarContent)
        let tag = item.scalarProperties.tag
        if tag in [yTagQuestionMark, yTagBoolean] and
              hint in {yTypeBoolTrue, yTypeBoolFalse}:
          c.safeWrite(if hint == yTypeBoolTrue: "true" else: "false")
        elif tag in [yTagQuestionMark, yTagNull] and
            hint == yTypeNull:
          c.safeWrite("null")
        elif tag in [yTagQuestionMark, yTagInteger,
            yTagNimInt8, yTagNimInt16, yTagNimInt32, yTagNimInt64,
            yTagNimUInt8, yTagNimUInt16, yTagNimUInt32, yTagNimUInt64] and
            hint == yTypeInteger:
          c.safeWrite(item.scalarContent)
        elif tag in [yTagQuestionMark, yTagFloat, yTagNimFloat32,
            yTagNimFloat64] and hint in {yTypeFloatInf, yTypeFloatNaN}:
          raise newException(YamlPresenterJsonError,
              "Infinity and not-a-number values cannot be presented as JSON!")
        elif tag in [yTagQuestionMark, yTagFloat] and
            hint == yTypeFloat:
          c.safeWrite(item.scalarContent)
        else: c.writeDoubleQuotedJson(item.scalarContent)
      elif c.options.style == psCanonical:
        c.writeDoubleQuoted(item.scalarContent,
                          indentation + c.options.indentationStep, newline)
      else:
        var words, lines = newSeq[tuple[start, finish: int]]()
        case item.scalarContent.inspect(
            indentation + c.options.indentationStep, words, lines)
        of sLiteral: c.writeLiteral(item.scalarContent, indentation,
                        c.options.indentationStep, lines, newline)
        of sFolded: c.writeFolded(item.scalarContent, indentation,
                        c.options.indentationStep, words, newline)
        of sPlain: c.safeWrite(item.scalarContent)
        of sDoubleQuoted: c.writeDoubleQuoted(item.scalarContent,
                        indentation + c.options.indentationStep, newline)
    of yamlAlias:
      if c.options.style == psJson:
        raise newException(YamlPresenterJsonError,
                           "Alias not allowed in JSON output")
      yAssert c.levels.len > 0
      c.startItem(indentation, false, newline)
      try:
        c.target.append('*')
        c.target.append($item.aliasTarget)
      except:
        var e = newException(YamlPresenterOutputError, "")
        e.parent = getCurrentException()
        raise e
    of yamlStartSeq:
      var nextState: DumperState
      case c.options.style
      of psDefault:
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
      of psJson:
        if c.levels.len > 0 and c.state in [dFlowMapStart, dFlowMapValue]:
          raise newException(YamlPresenterJsonError, "Cannot have sequence as map key in JSON output!")
        nextState = dFlowSequenceStart
      of psMinimal, psCanonical: nextState = dFlowSequenceStart
      of psBlockOnly:
        let next = s.peek()
        if next.kind == yamlEndSeq: nextState = dFlowSequenceStart
        else: nextState = dBlockSequenceItem

      if c.levels.len == 0:
        case nextState
        of dBlockSequenceItem:
          if c.options.style != psJson:
            c.writeTagAndAnchor(item.seqProperties)
        of dFlowSequenceStart:
          c.safeWrite(newline)
          if c.options.style != psJson:
            c.writeTagAndAnchor(item.seqProperties)
          indentation += c.options.indentationStep
        else: internalError("Invalid nextState: " & $nextState)
      else:
        c.startItem(indentation, true, newline)
        if c.options.style != psJson:
          c.writeTagAndAnchor(item.seqProperties)
        indentation += c.options.indentationStep

      if nextState == dFlowSequenceStart: c.safeWrite('[')
      if c.levels.len > 0 and c.options.style in [psJson, psCanonical] and
          c.state in [dBlockExplicitMapKey, dBlockMapValue,
                      dBlockImplicitMapKey, dBlockSequenceItem]:
        indentation += c.options.indentationStep
      c.levels.add(nextState)
    of yamlStartMap:
      var nextState: DumperState
      case c.options.style
      of psDefault:
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
      of psMinimal: nextState = dFlowMapStart
      of psCanonical: nextState = dFlowMapStart
      of psJson:
        if c.levels.len > 0 and c.state in [dFlowMapStart, dFlowMapValue]:
          raise newException(YamlPresenterJsonError,
                             "Cannot have map as map key in JSON output!")
        nextState = dFlowMapStart
      of psBlockOnly:
        let next = s.peek()
        if next.kind == yamlEndMap: nextState = dFlowMapStart
        else: nextState = dBlockMapValue
      if c.levels.len == 0:
        case nextState
        of dBlockMapValue:
          if c.options.style != psJson:
            c.writeTagAndAnchor(item.mapProperties)
          else:
            if c.options.style != psJson:
              c.safeWrite(newline)
              c.writeTagAndAnchor(item.mapProperties)
            indentation += c.options.indentationStep
        of dFlowMapStart:
          c.safeWrite(newline)
          if c.options.style != psJson:
            c.writeTagAndAnchor(item.mapProperties)
          indentation += c.options.indentationStep
        of dBlockInlineMap: discard
        else: internalError("Invalid nextState: " & $nextState)
      else:
        if nextState in [dBlockMapValue, dBlockImplicitMapKey]:
          c.startItem(indentation, true, newline)
          if c.options.style != psJson:
            c.writeTagAndAnchor(item.mapProperties)
        else:
          c.startItem(indentation, true, newline)
          if c.options.style != psJson:
            c.writeTagAndAnchor(item.mapProperties)
        indentation += c.options.indentationStep

      if nextState == dFlowMapStart: c.safeWrite('{')
      if c.levels.len > 0 and c.options.style in [psJson, psCanonical] and
          c.state in [dBlockExplicitMapKey, dBlockMapValue,
                      dBlockImplicitMapKey, dBlockImplicitMapKey,
                      dBlockSequenceItem]:
        indentation += c.options.indentationStep
      c.levels.add(nextState)

    of yamlEndSeq:
      yAssert c.levels.len > 0
      case c.levels.pop()
      of dFlowSequenceItem:
        case c.options.style
        of psDefault, psMinimal, psBlockOnly: c.safeWrite(']')
        of psJson, psCanonical:
          indentation -= c.options.indentationStep
          try:
            c.target.append(newline)
            c.target.append(repeat(' ', indentation))
            c.target.append(']')
          except:
            var e = newException(YamlPresenterOutputError, "")
            e.parent = getCurrentException()
            raise e
          if c.levels.len == 0 or c.state notin
              [dBlockExplicitMapKey, dBlockMapValue,
               dBlockImplicitMapKey, dBlockSequenceItem]:
            continue
      of dFlowSequenceStart:
        if c.levels.len > 0 and c.options.style in [psJson, psCanonical] and
            c.state in [dBlockExplicitMapKey, dBlockMapValue,
                        dBlockImplicitMapKey, dBlockSequenceItem]:
          indentation -= c.options.indentationStep
        c.safeWrite(']')
      of dBlockSequenceItem: discard
      else: internalError("Invalid popped level")
      indentation -= c.options.indentationStep
    of yamlEndMap:
      yAssert c.levels.len > 0
      let level = c.levels.pop()
      case level
      of dFlowMapValue:
        case c.options.style
        of psDefault, psMinimal, psBlockOnly: c.safeWrite('}')
        of psJson, psCanonical:
          indentation -= c.options.indentationStep
          try:
            c.target.append(newline)
            c.target.append(repeat(' ', indentation))
            c.target.append('}')
          except:
            var e = newException(YamlPresenterOutputError, "")
            e.parent = getCurrentException()
            raise e
          if c.levels.len == 0 or c.state notin
              [dBlockExplicitMapKey, dBlockMapValue,
               dBlockImplicitMapKey, dBlockSequenceItem]:
            continue
      of dFlowMapStart:
        if c.levels.len > 0 and c.options.style in [psJson, psCanonical] and
            c.state in [dBlockExplicitMapKey, dBlockMapValue,
                        dBlockImplicitMapKey, dBlockSequenceItem]:
          indentation -= c.options.indentationStep
        c.safeWrite('}')
      of dBlockMapValue, dBlockInlineMap: discard
      else: internalError("Invalid level: " & $level)
      indentation -= c.options.indentationStep
    of yamlEndDoc:
      firstDoc = false

proc present*(s: var YamlStream, target: Stream,
              tagLib: TagLibrary,
              options: PresentationOptions = defaultPresentationOptions)
    {.raises: [YamlPresenterJsonError, YamlPresenterOutputError,
               YamlStreamError].} =
  ## Convert ``s`` to a YAML character stream and write it to ``target``.
  var c = Context(target: target, tagLib: tagLib, options: options)
  doPresent(c, s)

proc present*(s: var YamlStream, tagLib: TagLibrary,
              options: PresentationOptions = defaultPresentationOptions):
    string {.raises: [YamlPresenterJsonError, YamlPresenterOutputError,
                      YamlStreamError].} =
  ## Convert ``s`` to a YAML character stream and return it as string.

  var
    ss = newStringStream()
    c = Context(target: ss, tagLib: tagLib, options: options)
  doPresent(c, s)
  return ss.data

proc doTransform(c: var Context, input: Stream,
                 resolveToCoreYamlTags: bool) =
  var
    taglib = initExtendedTagLibrary()
    parser: YamlParser
  parser.init(tagLib)
  var events = parser.parse(input)
  try:
    if c.options.style == psCanonical:
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
      doPresent(c, bys)
    else:
      doPresent(c, events)
  except YamlStreamError:
    var e = getCurrentException()
    while e.parent of YamlStreamError: e = e.parent
    if e.parent of IOError: raise (ref IOError)(e.parent)
    elif e.parent of OSError: raise (ref OSError)(e.parent)
    elif e.parent of YamlParserError: raise (ref YamlParserError)(e.parent)
    else: internalError("Unexpected exception: " & e.parent.repr)

proc genInput(input: Stream): Stream = input
proc genInput(input: string): Stream = newStringStream(input)

proc transform*(input: Stream | string, output: Stream,
                options: PresentationOptions = defaultPresentationOptions,
                resolveToCoreYamlTags: bool = false)
    {.raises: [IOError, OSError, YamlParserError, YamlPresenterJsonError,
               YamlPresenterOutputError].} =
  ## Parser ``input`` as YAML character stream and then dump it to ``output``
  ## while resolving non-specific tags to the ones in the YAML core tag
  ## library. If ``resolveToCoreYamlTags`` is ``true``, non-specific tags will
  ## be replaced by specific tags according to the YAML core schema.
  doTransform(genInput(input), output, options, resolveToCoreYamlTags)

proc transform*(input: Stream | string,
                options: PresentationOptions = defaultPresentationOptions,
                resolveToCoreYamlTags: bool = false):
    string {.raises: [IOError, OSError, YamlParserError, YamlPresenterJsonError,
                      YamlPresenterOutputError].} =
  ## Parser ``input`` as YAML character stream, resolves non-specific tags to
  ## the ones in the YAML core tag library, and then returns a serialized
  ## YAML string that represents the stream. If ``resolveToCoreYamlTags`` is
  ## ``true``, non-specific tags will be replaced by specific tags according to
  ## the YAML core schema.
  result = ""
  doTransform(genInput(input), addr result, options, resolveToCoreYamlTags)
