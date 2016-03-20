#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

type
    DumperState = enum
        dBlockExplicitMapKey, dBlockImplicitMapKey, dBlockMapValue,
        dBlockInlineMap, dBlockSequenceItem, dFlowImplicitMapKey, dFlowMapValue,
        dFlowExplicitMapKey, dFlowSequenceItem, dFlowMapStart,
        dFlowSequenceStart
    
    ScalarStyle = enum
        sLiteral, sFolded, sPlain, sDoubleQuoted

proc defineOptions*(style: PresentationStyle = psDefault,
                    indentationStep: int = 2,
                    newlines: NewLineStyle = nlOSDefault,
                    outputVersion: OutputYamlVersion = ov1_2):
        PresentationOptions =
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
            canUsePlain = false # we don't use multiline plain scalars
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
            if c in {'{', '}', '[', ']', ',', '#', '-', ':', '?', '%', '"',
                     '\''} or c.ord < 32: canUsePlain = false
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
    
proc writeDoubleQuoted(scalar: string, s: Stream, indentation: int,
                       newline: string)
            {.raises: [YamlPresenterOutputError].} =
    var curPos = indentation
    try:
        s.write('"')
        curPos.inc()
        for c in scalar:
            if curPos == 79:
                s.write('\\')
                s.write(newline)
                s.write(repeat(' ', indentation))
                curPos = indentation
                if c == ' ':
                    s.write('\\')
                    curPos.inc()
            case c
            of '"':
                s.write("\\\"")
                curPos.inc(2)
            of '\l':
                s.write("\\n")
                curPos.inc(2)
            of '\t':
                s.write("\\t")
                curPos.inc(2)
            of '\\':
                s.write("\\\\")
                curPos.inc(2)
            else:
                if ord(c) < 32:
                    s.write("\\x" & toHex(ord(c), 2))
                    curPos.inc(4)
                else:
                    s.write(c)
                    curPos.inc()
        s.write('"')
    except:
        var e = newException(YamlPresenterOutputError,
                             "Error while writing to output stream")
        e.parent = getCurrentException()
        raise e

proc writeDoubleQuotedJson(scalar: string, s: Stream)
        {.raises: [YamlPresenterOutputError].} =
    try:
        s.write('"')
        for c in scalar:
            case c
            of '"': s.write("\\\"")
            of '\\': s.write("\\\\")
            of '\l': s.write("\\n")
            of '\t': s.write("\\t")
            of '\f': s.write("\\f")
            of '\b': s.write("\\b")
            else:
                if ord(c) < 32: s.write("\\u" & toHex(ord(c), 4))
                else: s.write(c)
        s.write('"')
    except:
        var e = newException(YamlPresenterOutputError,
                             "Error while writing to output stream")
        e.parent = getCurrentException()
        raise e

proc writeLiteral(scalar: string, indentation, indentStep: int, s: Stream,
                  lines: seq[tuple[start, finish: int]], newline: string)
        {.raises: [YamlPresenterOutputError].} =
    try:
        s.write('|')
        if scalar[^1] != '\l': s.write('-')
        if scalar[0] in [' ', '\t']: s.write($indentStep)
        for line in lines:
            s.write(newline)
            s.write(repeat(' ', indentation + indentStep))
            if line.finish >= line.start:
                s.write(scalar[line.start .. line.finish])
    except:
        var e = newException(YamlPresenterOutputError,
                             "Error while writing to output stream")
        e.parent = getCurrentException()
        raise e

proc writeFolded(scalar: string, indentation, indentStep: int, s: Stream,
                 words: seq[tuple[start, finish: int]], newline: string)
        {.raises: [YamlPresenterOutputError].} =
    try:
        s.write(">")
        if scalar[^1] != '\l': s.write('-')
        if scalar[0] in [' ', '\t']: s.write($indentStep)
        var curPos = 80
        for word in words:
            if word.start > 0 and scalar[word.start - 1] == '\l':
                s.write(newline & newline)
                s.write(repeat(' ', indentation + indentStep))
                curPos = indentation + indentStep
            elif curPos + (word.finish - word.start) > 80:
                s.write(newline)
                s.write(repeat(' ', indentation + indentStep))
                curPos = indentation + indentStep
            else:
                s.write(' ')
                curPos.inc()
            s.write(scalar[word.start .. word.finish])
            curPos += word.finish - word.start + 1
    except:
        var e = newException(YamlPresenterOutputError,
                             "Error while writing to output stream")
        e.parent = getCurrentException()
        raise e

template safeWrite(s: string or char) {.dirty.} =
    try: target.write(s)
    except:
        var e = newException(YamlPresenterOutputError, "")
        e.parent = getCurrentException()
        raise e

proc startItem(target: Stream, style: PresentationStyle, indentation: int,
               state: var DumperState, isObject: bool, newline: string)
              {.raises: [YamlPresenterOutputError].} =
    try:
        case state
        of dBlockMapValue:
            target.write(newline)
            target.write(repeat(' ', indentation))
            if isObject or style == psCanonical:
                target.write("? ")
                state = dBlockExplicitMapKey
            else: state = dBlockImplicitMapKey
        of dBlockInlineMap: state = dBlockImplicitMapKey
        of dBlockExplicitMapKey:
            target.write(newline)
            target.write(repeat(' ', indentation))
            target.write(": ")
            state = dBlockMapValue
        of dBlockImplicitMapKey:
            target.write(": ")
            state = dBlockMapValue
        of dFlowExplicitMapKey:
            if style != psMinimal:
                target.write(newline)
                target.write(repeat(' ', indentation))
            target.write(": ")
            state = dFlowMapValue
        of dFlowMapValue:
            if (isObject and style != psMinimal) or
                    style in [psJson, psCanonical]:
                target.write(',' & newline & repeat(' ', indentation))
                if style == psJson: state = dFlowImplicitMapKey
                else:
                    target.write("? ")
                    state = dFlowExplicitMapKey
            elif isObject and style == psMinimal:
                target.write(", ? ")
                state = dFlowExplicitMapKey
            else:
                target.write(", ")
                state = dFlowImplicitMapKey
        of dFlowMapStart:
            if (isObject and style != psMinimal) or
                    style in [psJson, psCanonical]:
                target.write(newline & repeat(' ', indentation))
                if style == psJson: state = dFlowImplicitMapKey
                else:
                    target.write("? ")
                    state = dFlowExplicitMapKey
            else:
                state = dFlowImplicitMapKey
        of dFlowImplicitMapKey:
            target.write(": ")
            state = dFlowMapValue
        of dBlockSequenceItem:
            target.write(newline)
            target.write(repeat(' ', indentation))
            target.write("- ")
        of dFlowSequenceStart:
            case style
            of psMinimal, psDefault: discard
            of psCanonical, psJson:
                target.write(newline)
                target.write(repeat(' ', indentation))
            of psBlockOnly: discard # can never happen
            state = dFlowSequenceItem
        of dFlowSequenceItem:
            case style
            of psMinimal, psDefault: target.write(", ")
            of psCanonical, psJson:
                target.write(',' & newline)
                target.write(repeat(' ', indentation))
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

proc writeTagAndAnchor(target: Stream, tag: TagId, tagLib: TagLibrary,
                       anchor: AnchorId) {.raises:[YamlPresenterOutputError].} =
    try:
        if tag notin [yTagQuestionMark, yTagExclamationMark]:
            let tagUri = tagLib.uri(tag)
            if tagUri.startsWith(tagLib.secondaryPrefix):
                target.write("!!")
                target.write(tagUri[18..tagUri.high])
                target.write(' ')
            elif tagUri.startsWith("!"):
                target.write(tagUri)
                target.write(' ')
            else:
                target.write("!<")
                target.write(tagUri)
                target.write("> ")
        if anchor != yAnchorNone:
            target.write("&")
            target.write(anchorName(anchor))
            target.write(' ')
    except:
        var e = newException(YamlPresenterOutputError, "")
        e.parent = getCurrentException()
        raise e

proc present*(s: var YamlStream, target: Stream, tagLib: TagLibrary,
              options: PresentationOptions = defaultPresentationOptions) =
    var
        indentation = 0
        levels = newSeq[DumperState]()
        cached = initQueue[YamlStreamEvent]()
    let newline = if options.newlines == nlLF: "\l"
            elif options.newlines == nlCRLF: "\c\l" else: "\n"
    while cached.len > 0 or not s.finished():
        let item = if cached.len > 0: cached.dequeue else: s.next()
        case item.kind
        of yamlStartDoc:
            if options.style != psJson:
                # TODO: tag directives
                try:
                    case options.outputVersion
                    of ov1_2: target.write("%YAML 1.2" & newline)
                    of ov1_1: target.write("%YAML 1.1" & newLine)
                    of ovNone: discard
                    if tagLib.secondaryPrefix != yamlTagRepositoryPrefix:
                        target.write("%TAG !! " &
                                tagLib.secondaryPrefix & newline)
                    target.write("--- ")
                except:
                    var e = newException(YamlPresenterOutputError, "")
                    e.parent = getCurrentException()
                    raise e
        of yamlScalar:
            if levels.len == 0:
                if options.style != psJson: safeWrite(newline)
            else:
                startItem(target, options.style, indentation,
                          levels[levels.high], false, newline)
            if options.style != psJson:
                writeTagAndAnchor(target,
                                  item.scalarTag, tagLib, item.scalarAnchor)
            
            if options.style == psJson:
                let hint = guessType(item.scalarContent)
                if item.scalarTag in [yTagQuestionMark, yTagBoolean] and
                        hint in {yTypeBoolTrue, yTypeBoolFalse}:
                    if hint == yTypeBoolTrue:
                        safeWrite("true")
                    else:
                        safeWrite("false")
                elif item.scalarTag in [yTagQuestionMark, yTagNull] and
                        hint == yTypeNull:
                    safeWrite("null")
                elif item.scalarTag in [yTagQuestionMark, yTagInteger,
                        yTagNimInt8, yTagNimInt16, yTagNimInt32, yTagNimInt64,
                        yTagNimUInt8, yTagNimUInt16, yTagNimUInt32,
                        yTagNimUInt64] and
                        hint == yTypeInteger:
                    safeWrite(item.scalarContent)
                elif item.scalarTag in [yTagQuestionMark, yTagFloat,
                        yTagNimFloat32, yTagNimFloat64] and
                        hint in {yTypeFloatInf, yTypeFloatNaN}:
                    raise newException(YamlPresenterJsonError,
                            "Infinity and not-a-number values cannot be presented as JSON!")
                elif item.scalarTag in [yTagQuestionMark, yTagFloat] and
                        hint == yTypeFloat:
                    safeWrite(item.scalarContent)
                else: writeDoubleQuotedJson(item.scalarContent, target)
            elif options.style == psCanonical:
                writeDoubleQuoted(item.scalarContent, target,
                                  indentation + options.indentationStep,
                                  newline)
            else:
                var words, lines = newSeq[tuple[start, finish: int]]()
                case item.scalarContent.inspect(
                        indentation + options.indentationStep, words, lines)
                of sLiteral: writeLiteral(item.scalarContent, indentation,
                        options.indentationStep, target, lines, newline)
                of sFolded: writeFolded(item.scalarContent, indentation,
                        options.indentationStep, target, words, newline)
                of sPlain: safeWrite(item.scalarContent)
                of sDoubleQuoted: writeDoubleQuoted(item.scalarContent, target,
                        indentation + options.indentationStep, newline)
        of yamlAlias:
            if options.style == psJson:
                raise newException(YamlPresenterJsonError,
                                   "Alias not allowed in JSON output")
            assert levels.len > 0
            startItem(target, options.style, indentation, levels[levels.high],
                      false, newline)
            try:
                target.write('*')
                target.write(cast[byte]('a') + cast[byte](item.aliasTarget))
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
                    assert(not(s.finished()))
                    let next = s.next()
                    cached.enqueue(next)
                    case next.kind
                    of yamlScalar: length += 2 + next.scalarContent.len
                    of yamlAlias: length += 6
                    of yamlEndSeq: break
                    else:
                        length = high(int)
                        break
                nextState = if length <= 60: dFlowSequenceStart else:
                            dBlockSequenceItem
            of psJson:
                if levels.len > 0 and levels[levels.high] in
                        [dFlowMapStart, dFlowMapValue]:
                    raise newException(YamlPresenterJsonError,
                            "Cannot have sequence as map key in JSON output!")
                nextState = dFlowSequenceStart
            of psMinimal, psCanonical: nextState = dFlowSequenceStart
            of psBlockOnly: nextState = dBlockSequenceItem 
            
            if levels.len == 0:
                if nextState == dBlockSequenceItem:
                    if options.style != psJson:
                        writeTagAndAnchor(target,
                                          item.seqTag, tagLib, item.seqAnchor)
                else:
                    if options.style != psJson:
                        writeTagAndAnchor(target,
                                          item.seqTag, tagLib, item.seqAnchor)
                    safeWrite(newline)
                    indentation += options.indentationStep
            else:
                startItem(target, options.style, indentation,
                          levels[levels.high], true, newline)
                if options.style != psJson:
                    writeTagAndAnchor(target,
                                      item.seqTag, tagLib, item.seqAnchor)
                indentation += options.indentationStep
            
            if nextState == dFlowSequenceStart: safeWrite('[')
            if levels.len > 0 and options.style in [psJson, psCanonical] and
                    levels[levels.high] in
                    [dBlockExplicitMapKey, dBlockMapValue,
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
                nextState = if mps == mpNeedBlock: dBlockMapValue else:
                        dBlockInlineMap
            of psMinimal: nextState = dFlowMapStart
            of psCanonical: nextState = dFlowMapStart
            of psJson:
                if levels.len > 0 and levels[levels.high] in
                        [dFlowMapStart, dFlowMapValue]:
                    raise newException(YamlPresenterJsonError,
                            "Cannot have map as map key in JSON output!")
                nextState = dFlowMapStart
            of psBlockOnly: nextState = dBlockMapValue
            if levels.len == 0:
                if nextState == dBlockMapValue:
                    if options.style != psJson:
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                else:
                    if options.style != psJson:
                        safeWrite(newline)
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                    indentation += options.indentationStep
            else:
                if nextState in [dBlockMapValue, dBlockImplicitMapKey]:
                    startItem(target, options.style, indentation,
                              levels[levels.high], true, newline)
                    if options.style != psJson:
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                else:
                    startItem(target, options.style, indentation,
                              levels[levels.high], true, newline)
                    if options.style != psJson:
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                indentation += options.indentationStep
            
            if nextState == dFlowMapStart: safeWrite('{')
            if levels.len > 0 and options.style in [psJson, psCanonical] and
                    levels[levels.high] in
                    [dBlockExplicitMapKey, dBlockMapValue,
                     dBlockImplicitMapKey, dBlockSequenceItem]:
                indentation += options.indentationStep
            levels.add(nextState)
            
        of yamlEndSeq:
            assert levels.len > 0
            case levels.pop()
            of dFlowSequenceItem:
                case options.style
                of psDefault, psMinimal, psBlockOnly: safeWrite(']')
                of psJson, psCanonical:
                    indentation -= options.indentationStep
                    try:
                        target.write(newline)
                        target.write(repeat(' ', indentation))
                        target.write(']')
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
                        levels[levels.high] in
                        [dBlockExplicitMapKey, dBlockMapValue,
                         dBlockImplicitMapKey, dBlockSequenceItem]:
                    indentation -= options.indentationStep
                safeWrite(']')
            of dBlockSequenceItem: discard
            else: assert false
            indentation -= options.indentationStep
        of yamlEndMap:
            assert levels.len > 0
            let level = levels.pop()
            case level
            of dFlowMapValue:
                case options.style
                of psDefault, psMinimal, psBlockOnly: safeWrite('}')
                of psJson, psCanonical:
                    indentation -= options.indentationStep
                    try:
                        target.write(newline)
                        target.write(repeat(' ', indentation))
                        target.write('}')
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
                        levels[levels.high] in
                        [dBlockExplicitMapKey, dBlockMapValue,
                         dBlockImplicitMapKey, dBlockSequenceItem]:
                    indentation -= options.indentationStep
                safeWrite('}')
            of dBlockMapValue, dBlockInlineMap: discard
            else: assert(false)
            indentation -= options.indentationStep
        of yamlEndDoc:
            if finished(s): break
            safeWrite("..." & newline)

proc transform*(input: Stream, output: Stream,
                options: PresentationOptions = defaultPresentationOptions) =
    var
        taglib = initExtendedTagLibrary()
        parser = newYamlParser(tagLib)
        events = parser.parse(input)
    try:
        if options.style == psCanonical:
            var specificTagEvents = iterator(): YamlStreamEvent =
                for e in events:
                    var event = e
                    case event.kind
                    of yamlStartDoc, yamlEndDoc, yamlEndMap, yamlAlias,
                            yamlEndSeq:
                        discard
                    of yamlStartMap:
                        if event.mapTag in [yTagQuestionMark,
                                            yTagExclamationMark]:
                            event.mapTag = yTagMapping
                    of yamlStartSeq:
                        if event.seqTag in [yTagQuestionMark,
                                            yTagExclamationMark]:
                            event.seqTag = yTagSequence
                    of yamlScalar:
                        if event.scalarTag == yTagQuestionMark:
                            case guessType(event.scalarContent)
                            of yTypeInteger:
                                event.scalarTag = yTagInteger
                            of yTypeFloat, yTypeFloatInf, yTypeFloatNaN:
                                event.scalarTag = yTagFloat
                            of yTypeBoolTrue, yTypeBoolFalse:
                                event.scalarTag = yTagBoolean
                            of yTypeNull:
                                event.scalarTag = yTagNull
                            of yTypeUnknown:
                                event.scalarTag = yTagString
                        elif event.scalarTag == yTagExclamationMark:
                            event.scalarTag = yTagString
                    yield event
            var s = initYamlStream(specificTagEvents)
            present(s, output, tagLib, options)
        else:
            present(events, output, tagLib, options)
    except YamlStreamError:
        var e = getCurrentException()
        while e.parent of YamlStreamError: e = e.parent
        if e.parent of IOError:
            raise (ref IOError)(e.parent)
        elif e.parent of YamlParserError:
            raise (ref YamlParserError)(e.parent)
        else:
            # never happens
            assert(false)
    except YamlPresenterJsonError:
        raise (ref YamlPresenterJsonError)(getCurrentException())
    except YamlPresenterOutputError:
        raise (ref YamlPresenterOutputError)(getCurrentException())