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
import taglib, stream, private/internal, hints, parser, stream

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

  YamlPresenterJsonError* = object of Exception
    ## Exception that may be raised by the YAML presenter when it is
    ## instructed to output JSON, but is unable to do so. This may occur if:
    ##
    ## - The given `YamlStream <#YamlStream>`_ contains a map which has any
    ##   non-scalar type as key.
    ## - Any float scalar bears a ``NaN`` or positive/negative infinity value

  YamlPresenterOutputError* = object of Exception
    ## Exception that may be raised by the YAML presenter. This occurs if
    ## writing character data to the output stream raises any exception.
    ## The error that has occurred is available from ``parent``.

  DumperState = enum
    dBlockExplicitMapKey, dBlockImplicitMapKey, dBlockMapValue,
    dBlockInlineMap, dBlockSequenceItem, dFlowImplicitMapKey, dFlowMapValue,
    dFlowExplicitMapKey, dFlowSequenceItem, dFlowMapStart, dFlowSequenceStart

  ScalarStyle = enum
    sLiteral, sFolded, sPlain, sDoubleQuoted

  PresenterTarget = Stream | ptr[string]

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

proc writeDoubleQuoted(scalar: string, s: PresenterTarget, indentation: int,
                       newline: string)
            {.raises: [YamlPresenterOutputError].} =
  var curPos = indentation
  try:
    s.append('"')
    curPos.inc()
    for c in scalar:
      if curPos == 79:
        s.append('\\')
        s.append(newline)
        s.append(repeat(' ', indentation))
        curPos = indentation
        if c == ' ':
          s.append('\\')
          curPos.inc()
      case c
      of '"':
        s.append("\\\"")
        curPos.inc(2)
      of '\l':
        s.append("\\n")
        curPos.inc(2)
      of '\t':
        s.append("\\t")
        curPos.inc(2)
      of '\\':
        s.append("\\\\")
        curPos.inc(2)
      else:
        if ord(c) < 32:
          s.append("\\x" & toHex(ord(c), 2))
          curPos.inc(4)
        else:
          s.append(c)
          curPos.inc()
    s.append('"')
  except:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = getCurrentException()
    raise e

proc writeDoubleQuotedJson(scalar: string, s: PresenterTarget)
    {.raises: [YamlPresenterOutputError].} =
  try:
    s.append('"')
    for c in scalar:
      case c
      of '"': s.append("\\\"")
      of '\\': s.append("\\\\")
      of '\l': s.append("\\n")
      of '\t': s.append("\\t")
      of '\f': s.append("\\f")
      of '\b': s.append("\\b")
      else:
        if ord(c) < 32: s.append("\\u" & toHex(ord(c), 4)) else: s.append(c)
    s.append('"')
  except:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = getCurrentException()
    raise e

proc writeLiteral(scalar: string, indentation, indentStep: int,
                  s: PresenterTarget, lines: seq[tuple[start, finish: int]],
                  newline: string)
    {.raises: [YamlPresenterOutputError].} =
  try:
    s.append('|')
    if scalar[^1] != '\l': s.append('-')
    if scalar[0] in [' ', '\t']: s.append($indentStep)
    for line in lines:
      s.append(newline)
      s.append(repeat(' ', indentation + indentStep))
      if line.finish >= line.start:
        s.append(scalar[line.start .. line.finish])
  except:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = getCurrentException()
    raise e

proc writeFolded(scalar: string, indentation, indentStep: int,
                 s: PresenterTarget, words: seq[tuple[start, finish: int]],
                 newline: string)
    {.raises: [YamlPresenterOutputError].} =
  try:
    s.append(">")
    if scalar[^1] != '\l': s.append('-')
    if scalar[0] in [' ', '\t']: s.append($indentStep)
    var curPos = 80
    for word in words:
      if word.start > 0 and scalar[word.start - 1] == '\l':
        s.append(newline & newline)
        s.append(repeat(' ', indentation + indentStep))
        curPos = indentation + indentStep
      elif curPos + (word.finish - word.start) > 80:
        s.append(newline)
        s.append(repeat(' ', indentation + indentStep))
        curPos = indentation + indentStep
      else:
        s.append(' ')
        curPos.inc()
      s.append(scalar[word.start .. word.finish])
      curPos += word.finish - word.start + 1
  except:
    var e = newException(YamlPresenterOutputError,
                         "Error while writing to output stream")
    e.parent = getCurrentException()
    raise e

template safeWrite(target: PresenterTarget, s: string or char) =
  try: target.append(s)
  except:
    var e = newException(YamlPresenterOutputError, "")
    e.parent = getCurrentException()
    raise e

proc startItem(target: PresenterTarget, style: PresentationStyle,
               indentation: int, state: var DumperState, isObject: bool,
               newline: string) {.raises: [YamlPresenterOutputError].} =
  try:
    case state
    of dBlockMapValue:
      target.append(newline)
      target.append(repeat(' ', indentation))
      if isObject or style == psCanonical:
        target.append("? ")
        state = dBlockExplicitMapKey
      else: state = dBlockImplicitMapKey
    of dBlockInlineMap: state = dBlockImplicitMapKey
    of dBlockExplicitMapKey:
      target.append(newline)
      target.append(repeat(' ', indentation))
      target.append(": ")
      state = dBlockMapValue
    of dBlockImplicitMapKey:
      target.append(": ")
      state = dBlockMapValue
    of dFlowExplicitMapKey:
      if style != psMinimal:
        target.append(newline)
        target.append(repeat(' ', indentation))
      target.append(": ")
      state = dFlowMapValue
    of dFlowMapValue:
      if (isObject and style != psMinimal) or style in [psJson, psCanonical]:
        target.append(',' & newline & repeat(' ', indentation))
        if style == psJson: state = dFlowImplicitMapKey
        else:
          target.append("? ")
          state = dFlowExplicitMapKey
      elif isObject and style == psMinimal:
        target.append(", ? ")
        state = dFlowExplicitMapKey
      else:
        target.append(", ")
        state = dFlowImplicitMapKey
    of dFlowMapStart:
      if (isObject and style != psMinimal) or style in [psJson, psCanonical]:
        target.append(newline & repeat(' ', indentation))
        if style == psJson: state = dFlowImplicitMapKey
        else:
          target.append("? ")
          state = dFlowExplicitMapKey
      else: state = dFlowImplicitMapKey
    of dFlowImplicitMapKey:
      target.append(": ")
      state = dFlowMapValue
    of dBlockSequenceItem:
      target.append(newline)
      target.append(repeat(' ', indentation))
      target.append("- ")
    of dFlowSequenceStart:
      case style
      of psMinimal, psDefault: discard
      of psCanonical, psJson:
        target.append(newline)
        target.append(repeat(' ', indentation))
      of psBlockOnly: discard # can never happen
      state = dFlowSequenceItem
    of dFlowSequenceItem:
      case style
      of psMinimal, psDefault: target.append(", ")
      of psCanonical, psJson:
        target.append(',' & newline)
        target.append(repeat(' ', indentation))
      of psBlockOnly: discard # can never happen
  except:
    var e = newException(YamlPresenterOutputError, "")
    e.parent = getCurrentException()
    raise e

proc anchorName(a: AnchorId): string {.raises: [].} =
  result = ""
  var i = int(a)
  while i >= 0:
    let j = i mod 36
    if j < 26: result.add(char(j + ord('a')))
    else: result.add(char(j + ord('0') - 26))
    i -= 36

proc writeTagAndAnchor(target: PresenterTarget, tag: TagId,
                       tagLib: TagLibrary,
                       anchor: AnchorId) {.raises: [YamlPresenterOutputError].} =
  try:
    if tag notin [yTagQuestionMark, yTagExclamationMark]:
      let tagUri = tagLib.uri(tag)
      let (handle, length) = tagLib.searchHandle(tagUri)
      if length > 0:
        target.append(handle)
        target.append(tagUri[length..tagUri.high])
        target.append(' ')
      else:
        target.append("!<")
        target.append(tagUri)
        target.append("> ")
    if anchor != yAnchorNone:
      target.append("&")
      target.append(anchorName(anchor))
      target.append(' ')
  except:
    var e = newException(YamlPresenterOutputError, "")
    e.parent = getCurrentException()
    raise e

proc nextItem(c: var Deque, s: var YamlStream):
    YamlStreamEvent {.raises: [YamlStreamError].} =
  if c.len > 0:
    try: result = c.popFirst
    except IndexError: internalError("Unexpected IndexError")
  else:
    result = s.next()

proc doPresent(s: var YamlStream, target: PresenterTarget,
              tagLib: TagLibrary,
              options: PresentationOptions = defaultPresentationOptions) =
  var
    indentation = 0
    levels = newSeq[DumperState]()
    cached = initDeQue[YamlStreamEvent]()
  let newline = if options.newlines == nlLF: "\l"
    elif options.newlines == nlCRLF: "\c\l" else: "\n"
  while cached.len > 0 or not s.finished():
    let item = nextItem(cached, s)
    case item.kind
    of yamlStartDoc:
      if options.style != psJson:
        try:
          case options.outputVersion
          of ov1_2: target.append("%YAML 1.2" & newline)
          of ov1_1: target.append("%YAML 1.1" & newLine)
          of ovNone: discard
          for prefix, handle in tagLib.handles():
            if handle == "!":
              if prefix != "!":
                target.append("%TAG ! " & prefix & newline)
            elif handle == "!!":
              if prefix != yamlTagRepositoryPrefix:
                target.append("%TAG !! " & prefix & newline)
            else:
              target.append("%TAG " & handle & ' ' & prefix & newline)
          target.append("--- ")
        except:
          var e = newException(YamlPresenterOutputError, "")
          e.parent = getCurrentException()
          raise e
    of yamlScalar:
      if levels.len == 0:
        if options.style != psJson: target.safeWrite(newline)
      else:
        startItem(target, options.style, indentation,
                  levels[levels.high], false, newline)
      if options.style != psJson:
        writeTagAndAnchor(target, item.scalarTag, tagLib, item.scalarAnchor)

      if options.style == psJson:
        let hint = guessType(item.scalarContent)
        if item.scalarTag in [yTagQuestionMark, yTagBoolean] and
              hint in {yTypeBoolTrue, yTypeBoolFalse}:
          target.safeWrite(if hint == yTypeBoolTrue: "true" else: "false")
        elif item.scalarTag in [yTagQuestionMark, yTagNull] and
            hint == yTypeNull:
          target.safeWrite("null")
        elif item.scalarTag in [yTagQuestionMark, yTagInteger,
            yTagNimInt8, yTagNimInt16, yTagNimInt32, yTagNimInt64,
            yTagNimUInt8, yTagNimUInt16, yTagNimUInt32, yTagNimUInt64] and
            hint == yTypeInteger:
          target.safeWrite(item.scalarContent)
        elif item.scalarTag in [yTagQuestionMark, yTagFloat, yTagNimFloat32,
            yTagNimFloat64] and hint in {yTypeFloatInf, yTypeFloatNaN}:
          raise newException(YamlPresenterJsonError,
              "Infinity and not-a-number values cannot be presented as JSON!")
        elif item.scalarTag in [yTagQuestionMark, yTagFloat] and
            hint == yTypeFloat:
          target.safeWrite(item.scalarContent)
        else: writeDoubleQuotedJson(item.scalarContent, target)
      elif options.style == psCanonical:
        writeDoubleQuoted(item.scalarContent, target,
                          indentation + options.indentationStep, newline)
      else:
        var words, lines = newSeq[tuple[start, finish: int]]()
        case item.scalarContent.inspect(
            indentation + options.indentationStep, words, lines)
        of sLiteral: writeLiteral(item.scalarContent, indentation,
                        options.indentationStep, target, lines, newline)
        of sFolded: writeFolded(item.scalarContent, indentation,
                        options.indentationStep, target, words, newline)
        of sPlain: target.safeWrite(item.scalarContent)
        of sDoubleQuoted: writeDoubleQuoted(item.scalarContent, target,
                        indentation + options.indentationStep, newline)
    of yamlAlias:
      if options.style == psJson:
        raise newException(YamlPresenterJsonError,
                           "Alias not allowed in JSON output")
      yAssert levels.len > 0
      startItem(target, options.style, indentation, levels[levels.high],
                false, newline)
      try:
        target.append('*')
        target.append(char(byte('a') + byte(item.aliasTarget)))
      except:
        var e = newException(YamlPresenterOutputError, "")
        e.parent = getCurrentException()
        raise e
    of yamlStartSeq:
      var nextState: DumperState
      case options.style
      of psDefault:
        var length = 0
        while true:
          yAssert(not s.finished())
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
        if levels.len > 0 and levels[levels.high] in
            [dFlowMapStart, dFlowMapValue]:
          raise newException(YamlPresenterJsonError, "Cannot have sequence as map key in JSON output!")
        nextState = dFlowSequenceStart
      of psMinimal, psCanonical: nextState = dFlowSequenceStart
      of psBlockOnly:
        yAssert(not s.finished())
        let next = s.peek()
        if next.kind == yamlEndSeq: nextState = dFlowSequenceStart
        else: nextState = dBlockSequenceItem

      if levels.len == 0:
        case nextState
        of dBlockSequenceItem:
          if options.style != psJson:
            writeTagAndAnchor(target, item.seqTag, tagLib, item.seqAnchor)
        of dFlowSequenceStart:
          target.safeWrite(newline)
          if options.style != psJson:
            writeTagAndAnchor(target, item.seqTag, tagLib, item.seqAnchor)
          indentation += options.indentationStep
        else: internalError("Invalid nextState: " & $nextState)
      else:
        startItem(target, options.style, indentation,
                  levels[levels.high], true, newline)
        if options.style != psJson:
          writeTagAndAnchor(target, item.seqTag, tagLib, item.seqAnchor)
        indentation += options.indentationStep

      if nextState == dFlowSequenceStart: target.safeWrite('[')
      if levels.len > 0 and options.style in [psJson, psCanonical] and
          levels[levels.high] in [dBlockExplicitMapKey, dBlockMapValue,
                                  dBlockImplicitMapKey, dBlockSequenceItem]:
        indentation += options.indentationStep
      levels.add(nextState)
    of yamlStartMap:
      var nextState: DumperState
      case options.style
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
        if levels.len > 0 and levels[levels.high] in
            [dFlowMapStart, dFlowMapValue]:
          raise newException(YamlPresenterJsonError,
                             "Cannot have map as map key in JSON output!")
        nextState = dFlowMapStart
      of psBlockOnly:
        yAssert(not s.finished())
        let next = s.peek()
        if next.kind == yamlEndMap: nextState = dFlowMapStart
        else: nextState = dBlockMapValue
      if levels.len == 0:
        case nextState
        of dBlockMapValue:
          if options.style != psJson:
            writeTagAndAnchor(target, item.mapTag, tagLib, item.mapAnchor)
          else:
            if options.style != psJson:
              target.safeWrite(newline)
              writeTagAndAnchor(target, item.mapTag, tagLib, item.mapAnchor)
            indentation += options.indentationStep
        of dFlowMapStart:
          target.safeWrite(newline)
          if options.style != psJson:
            writeTagAndAnchor(target, item.mapTag, tagLib, item.mapAnchor)
          indentation += options.indentationStep
        of dBlockInlineMap: discard
        else: internalError("Invalid nextState: " & $nextState)
      else:
        if nextState in [dBlockMapValue, dBlockImplicitMapKey]:
          startItem(target, options.style, indentation,
                    levels[levels.high], true, newline)
          if options.style != psJson:
            writeTagAndAnchor(target, item.mapTag, tagLib, item.mapAnchor)
        else:
          startItem(target, options.style, indentation,
                    levels[levels.high], true, newline)
          if options.style != psJson:
            writeTagAndAnchor(target, item.mapTag, tagLib, item.mapAnchor)
        indentation += options.indentationStep

      if nextState == dFlowMapStart: target.safeWrite('{')
      if levels.len > 0 and options.style in [psJson, psCanonical] and
          levels[levels.high] in
          [dBlockExplicitMapKey, dBlockMapValue,
           dBlockImplicitMapKey, dBlockSequenceItem]:
        indentation += options.indentationStep
      levels.add(nextState)

    of yamlEndSeq:
      yAssert levels.len > 0
      case levels.pop()
      of dFlowSequenceItem:
        case options.style
        of psDefault, psMinimal, psBlockOnly: target.safeWrite(']')
        of psJson, psCanonical:
          indentation -= options.indentationStep
          try:
            target.append(newline)
            target.append(repeat(' ', indentation))
            target.append(']')
          except:
            var e = newException(YamlPresenterOutputError, "")
            e.parent = getCurrentException()
            raise e
          if levels.len == 0 or levels[levels.high] notin
              [dBlockExplicitMapKey, dBlockMapValue,
               dBlockImplicitMapKey, dBlockSequenceItem]:
            continue
      of dFlowSequenceStart:
        if levels.len > 0 and options.style in [psJson, psCanonical] and
            levels[levels.high] in [dBlockExplicitMapKey, dBlockMapValue,
                                    dBlockImplicitMapKey, dBlockSequenceItem]:
          indentation -= options.indentationStep
        target.safeWrite(']')
      of dBlockSequenceItem: discard
      else: internalError("Invalid popped level")
      indentation -= options.indentationStep
    of yamlEndMap:
      yAssert levels.len > 0
      let level = levels.pop()
      case level
      of dFlowMapValue:
        case options.style
        of psDefault, psMinimal, psBlockOnly: target.safeWrite('}')
        of psJson, psCanonical:
          indentation -= options.indentationStep
          try:
            target.append(newline)
            target.append(repeat(' ', indentation))
            target.append('}')
          except:
            var e = newException(YamlPresenterOutputError, "")
            e.parent = getCurrentException()
            raise e
          if levels.len == 0 or levels[levels.high] notin
              [dBlockExplicitMapKey, dBlockMapValue,
               dBlockImplicitMapKey, dBlockSequenceItem]:
            continue
      of dFlowMapStart:
        if levels.len > 0 and options.style in [psJson, psCanonical] and
            levels[levels.high] in [dBlockExplicitMapKey, dBlockMapValue,
                                    dBlockImplicitMapKey, dBlockSequenceItem]:
          indentation -= options.indentationStep
        target.safeWrite('}')
      of dBlockMapValue, dBlockInlineMap: discard
      else: internalError("Invalid level: " & $level)
      indentation -= options.indentationStep
    of yamlEndDoc:
      if finished(s): break
      if options.style == psJson:
        raise newException(YamlPresenterJsonError,
            "Cannot output more than one document in JSON style")
      target.safeWrite("..." & newline)

proc present*(s: var YamlStream, target: Stream,
              tagLib: TagLibrary,
              options: PresentationOptions = defaultPresentationOptions)
    {.raises: [YamlPresenterJsonError, YamlPresenterOutputError,
               YamlStreamError].} =
  ## Convert ``s`` to a YAML character stream and write it to ``target``.
  doPresent(s, target, tagLib, options)

proc present*(s: var YamlStream, tagLib: TagLibrary,
              options: PresentationOptions = defaultPresentationOptions):
    string {.raises: [YamlPresenterJsonError, YamlPresenterOutputError,
                      YamlStreamError].} =
  ## Convert ``s`` to a YAML character stream and return it as string.
  result = ""
  doPresent(s, addr result, tagLib, options)

proc doTransform(input: Stream | string, output: PresenterTarget,
                 options: PresentationOptions, resolveToCoreYamlTags: bool) =
  var
    taglib = initExtendedTagLibrary()
    parser = newYamlParser(tagLib)
    events = parser.parse(input)
  try:
    if options.style == psCanonical:
      var bys: YamlStream = newBufferYamlStream()
      for e in events:
        if resolveToCoreYamlTags:
          var event = e
          case event.kind
          of yamlStartDoc, yamlEndDoc, yamlEndMap, yamlAlias, yamlEndSeq:
            discard
          of yamlStartMap:
            if event.mapTag in [yTagQuestionMark, yTagExclamationMark]:
              event.mapTag = yTagMapping
          of yamlStartSeq:
            if event.seqTag in [yTagQuestionMark, yTagExclamationMark]:
              event.seqTag = yTagSequence
          of yamlScalar:
            if event.scalarTag == yTagQuestionMark:
              case guessType(event.scalarContent)
              of yTypeInteger: event.scalarTag = yTagInteger
              of yTypeFloat, yTypeFloatInf, yTypeFloatNaN:
                event.scalarTag = yTagFloat
              of yTypeBoolTrue, yTypeBoolFalse: event.scalarTag = yTagBoolean
              of yTypeNull: event.scalarTag = yTagNull
              of yTypeTimestamp: event.scalarTag = yTagTimestamp
              of yTypeUnknown: event.scalarTag = yTagString
            elif event.scalarTag == yTagExclamationMark:
              event.scalarTag = yTagString
          BufferYamlStream(bys).put(event)
        else: BufferYamlStream(bys).put(e)
      when output is ptr[string]: output[] = present(bys, tagLib, options)
      else: present(bys, output, tagLib, options)
    else:
      when output is ptr[string]: output[] = present(events, tagLib, options)
      else: present(events, output, tagLib, options)
  except YamlStreamError:
    var e = getCurrentException()
    while e.parent of YamlStreamError: e = e.parent
    if e.parent of IOError: raise (ref IOError)(e.parent)
    elif e.parent of YamlParserError: raise (ref YamlParserError)(e.parent)
    else: internalError("Unexpected exception: " & e.parent.repr)

proc transform*(input: Stream | string, output: Stream,
                options: PresentationOptions = defaultPresentationOptions,
                resolveToCoreYamlTags: bool = false)
    {.raises: [IOError, YamlParserError, YamlPresenterJsonError,
               YamlPresenterOutputError].} =
  ## Parser ``input`` as YAML character stream and then dump it to ``output``
  ## while resolving non-specific tags to the ones in the YAML core tag
  ## library. If ``resolveToCoreYamlTags`` is ``true``, non-specific tags will
  ## be replaced by specific tags according to the YAML core schema.
  doTransform(input, output, options, resolveToCoreYamlTags)

proc transform*(input: Stream | string,
                options: PresentationOptions = defaultPresentationOptions,
                resolveToCoreYamlTags: bool = false):
    string {.raises: [IOError, YamlParserError, YamlPresenterJsonError,
                      YamlPresenterOutputError].} =
  ## Parser ``input`` as YAML character stream, resolves non-specific tags to
  ## the ones in the YAML core tag library, and then returns a serialized
  ## YAML string that represents the stream. If ``resolveToCoreYamlTags`` is
  ## ``true``, non-specific tags will be replaced by specific tags according to
  ## the YAML core schema.
  result = ""
  doTransform(input, addr result, options, resolveToCoreYamlTags)
