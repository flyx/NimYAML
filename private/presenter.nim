#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

type
    DumperState = enum
        dBlockExplicitMapKey, dBlockExplicitMapValue, dBlockImplicitMapKey,
        dBlockImplicitMapValue, dBlockSequenceItem, dFlowImplicitMapKey,
        dFlowImplicitMapValue, dFlowExplicitMapKey, dFlowExplicitMapValue,
        dFlowSequenceItem, dFlowImplicitMapStart, dFlowExplicitMapStart,
        dFlowSequenceStart

proc needsEscaping(scalar: string): bool {.raises: [].} =
    scalar.len == 0 or 
            scalar.find({'{', '}', '[', ']', ',', '#', '-', ':', '?', '%',
                         '\x0A', '\c'}) != -1

proc writeDoubleQuoted(scalar: string, s: Stream)
            {.raises: [YamlPresenterOutputError].} =
    try:
        s.write('"')
        for c in scalar:
            if c == '"':
                s.write('\\')
            s.write(c)
        s.write('"')  
    except:
        var e = newException(YamlPresenterOutputError, "")
        e.cause = getCurrentException()
        raise e

template safeWrite(s: string or char) {.dirty.} =
    try:
        target.write(s)
    except:
        var e = newException(YamlPresenterOutputError, "")
        e.cause = getCurrentException()
        raise e

proc startItem(target: Stream, style: YamlPresentationStyle, indentation: int,
               state: var DumperState) {.raises: [YamlPresenterOutputError].} =
    try:
        case state
        of dBlockExplicitMapValue:
            target.write('\x0A')
            target.write(repeat(' ', indentation))
            target.write("? ")
            state = dBlockExplicitMapKey
        of dBlockExplicitMapKey:
            target.write('\x0A')
            target.write(repeat(' ', indentation))
            target.write(": ")
            state = dBlockExplicitMapValue
        of dBlockImplicitMapValue:
            target.write('\x0A')
            target.write(repeat(' ', indentation))
            state = dBlockImplicitMapKey
        of dBlockImplicitMapKey:
            target.write(": ")
            state = dBlockImplicitMapValue
        of dFlowExplicitMapKey:
            target.write('\x0A')
            target.write(repeat(' ', indentation))
            target.write(": ")
            state = dFlowExplicitMapValue
        of dFlowExplicitMapValue:
            target.write(",\x0A")
            target.write(repeat(' ', indentation))
            target.write("? ")
            state = dFlowExplicitMapKey
        of dFlowImplicitMapStart:
            if style == ypsJson:
                target.write("\x0A")
                target.write(repeat(' ', indentation))
            state = dFlowImplicitMapKey
        of dFlowExplicitMapStart:
            target.write('\x0A')
            target.write(repeat(' ', indentation))
            target.write("? ")
            state = dFlowExplicitMapKey
        of dFlowImplicitMapKey:
            target.write(": ")
            state = dFlowImplicitMapValue
        of dFlowImplicitMapValue:
            if style == ypsJson:
                target.write(",\x0A")
                target.write(repeat(' ', indentation))
            else:
                target.write(", ")
            state = dFlowImplicitMapKey
        of dBlockSequenceItem:
            target.write('\x0A')
            target.write(repeat(' ', indentation))
            target.write("- ")
        of dFlowSequenceStart:
            case style
            of ypsMinimal, ypsDefault:
                discard
            of ypsCanonical, ypsJson:
                target.write('\x0A')
                target.write(repeat(' ', indentation))
            of ypsBlockOnly:
                discard # can never happen
            state = dFlowSequenceItem
        of dFlowSequenceItem:
            case style
            of ypsMinimal, ypsDefault:
                target.write(", ")
            of ypsCanonical, ypsJson:
                target.write(",\x0A")
                target.write(repeat(' ', indentation))
            of ypsBlockOnly:
                discard # can never happen
    except:
        var e = newException(YamlPresenterOutputError, "")
        e.cause = getCurrentException()
        raise e
    
proc writeTagAndAnchor(target: Stream, tag: TagId, tagLib: YamlTagLibrary,
                       anchor: AnchorId) {.raises:[YamlPresenterOutputError].} =
    try:
        if tag notin [yTagQuestionMark, yTagExclamationMark]:
            let tagUri = tagLib.uri(tag)
            if tagUri.startsWith(tagLib.secondaryPrefix):
                target.write("!!")
                target.write(tagUri[18..^1])
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
            # TODO: properly select an anchor
            target.write(cast[byte]('a') + cast[byte](anchor))
            target.write(' ')
    except:
        var e = newException(YamlPresenterOutputError, "")
        e.cause = getCurrentException()
        raise e

proc present*(s: YamlStream, target: Stream, tagLib: YamlTagLibrary,
              style: YamlPresentationStyle = ypsDefault,
              indentationStep: int = 2) =
    var
        cached = initQueue[YamlStreamEvent]()
        cacheIterator = iterator(): YamlStreamEvent =
            while true:
                while cached.len > 0:
                    yield cached.dequeue()
                try:
                    let item = s()
                    if finished(s):
                        break
                    cached.enqueue(item)
                except:
                    var e = newException(YamlPresenterStreamError, "")
                    e.cause = getCurrentException()
                    raise e
        indentation = 0
        levels = newSeq[DumperState]()
    
    for item in cacheIterator():
        case item.kind
        of yamlStartDocument:
            if style != ypsJson:
                # TODO: tag directives
                try:
                    target.write("%YAML 1.2\x0A")
                    if tagLib.secondaryPrefix != yamlTagRepositoryPrefix:
                        target.write("%TAG !! " &
                                tagLib.secondaryPrefix & '\x0A')
                    target.write("--- ")
                except:
                    var e = newException(YamlPresenterOutputError, "")
                    e.cause = getCurrentException()
                    raise e
        of yamlScalar:
            if levels.len == 0:
                if style != ypsJson:
                    safeWrite('\x0A')
            else:
                startItem(target, style, indentation, levels[levels.high])
            if style != ypsJson:
                writeTagAndAnchor(target,
                                  item.scalarTag, tagLib, item.scalarAnchor)
            
            if style == ypsJson:
                if item.scalarTag in [yTagQuestionMark, yTagBoolean] and
                        item.scalarType in [yTypeBoolTrue, yTypeBoolFalse]:
                    if item.scalarType == yTypeBoolTrue:
                        safeWrite("true")
                    else:
                        safeWrite("false")
                elif item.scalarTag in [yTagQuestionMark, yTagNull] and
                        item.scalarType == yTypeNull:
                    safeWrite("null")
                elif item.scalarTag in [yTagQuestionMark, yTagFloat] and
                        item.scalarType in [yTypeFloatInf, yTypeFloatNaN]:
                    raise newException(YamlPresenterJsonError,
                            "Infinity and not-a-number values cannot be presented as JSON!")
                else:
                    safeWrite(item.scalarContent)
            elif style == ypsCanonical or item.scalarContent.needsEscaping or
               (style == ypsJson and
                (item.scalarTag notin [yTagQuestionMark, yTagInteger, yTagFloat,
                                       yTagBoolean, yTagNull] or
                 (item.scalarTag == yTagQuestionMark and item.scalarType notin
                  [yTypeBoolFalse, yTypeBoolTrue, yTypeInteger, yTypeFloat,
                   yTypeNull]))):
                writeDoubleQuoted(item.scalarContent, target)
            else:
                safeWrite(item.scalarContent)
        of yamlAlias:
            assert levels.len > 0
            startItem(target, style, indentation, levels[levels.high])
            try:
                target.write('*')
                target.write(cast[byte]('a') + cast[byte](item.aliasTarget))
            except:
                var e = newException(YamlPresenterOutputError, "")
                e.cause = getCurrentException()
                raise e
        of yamlStartSequence:
            var nextState: DumperState
            case style
            of ypsDefault:
                var length = 0
                while true:
                    try:
                        let next = s()
                        assert (not finished(s))
                        cached.enqueue(next)
                        case next.kind
                        of yamlScalar:
                            length += 2 + next.scalarContent.len
                        of yamlAlias:
                            length += 6
                        of yamlEndSequence:
                            break
                        else:
                            length = int.high
                            break
                    except:
                        var e = newException(YamlPresenterStreamError, "")
                        e.cause = getCurrentException()
                        raise e
                nextState = if length <= 60: dFlowSequenceStart else:
                            dBlockSequenceItem
            of ypsJson:
                if levels[levels.high] in
                        [dFlowImplicitMapStart, dFlowImplicitMapValue]:
                    raise newException(YamlPresenterJsonError,
                            "Cannot have sequence as map key in JSON output!")
                nextState = dFlowSequenceStart
            of ypsMinimal, ypsCanonical:
                nextState = dFlowSequenceStart
            of ypsBlockOnly:
                nextState = dBlockSequenceItem 
            
            if levels.len == 0:
                if nextState == dBlockSequenceItem:
                    if style != ypsJson:
                        writeTagAndAnchor(target,
                                          item.seqTag, tagLib, item.seqAnchor)
                else:
                    if style != ypsJson:
                        writeTagAndAnchor(target,
                                          item.seqTag, tagLib, item.seqAnchor)
                    safeWrite('\x0A')
                    indentation += indentationStep
            else:
                startItem(target, style, indentation, levels[levels.high])
                if style != ypsJson:
                    writeTagAndAnchor(target,
                                      item.seqTag, tagLib, item.seqAnchor)
                indentation += indentationStep
            
            if nextState == dFlowSequenceStart:
                safeWrite('[')
            if levels.len > 0 and style in [ypsJson, ypsCanonical] and
                    levels[levels.high] in
                    [dBlockExplicitMapKey, dBlockExplicitMapValue,
                     dBlockImplicitMapKey, dBlockImplicitMapValue,
                     dBlockSequenceItem]:
                indentation += indentationStep
            levels.add(nextState)
        of yamlStartMap:
            var nextState: DumperState
            case style
            of ypsDefault:
                var length = 0
                while true:
                    try:
                        let next = s()
                        assert (not finished(s))
                        cached.enqueue(next)
                        case next.kind
                        of yamlScalar:
                            length += 2 + next.scalarContent.len
                        of yamlAlias:
                            length += 6
                        of yamlEndMap:
                            break
                        else:
                            length = int.high
                            break
                    except:
                        var e = newException(YamlPresenterStreamError, "")
                        e.cause = getCurrentException()
                        raise e
                nextState = if length <= 60: dFlowImplicitMapStart else:
                            if item.mapMayHaveKeyObjects:
                            dBlockExplicitMapValue else: dBlockImplicitMapValue
            of ypsMinimal:
                nextState = if item.mapMayHaveKeyObjects:
                            dFlowExplicitMapStart else: dFlowImplicitMapStart
            of ypsCanonical:
                nextState = dFlowExplicitMapStart
            of ypsJson:
                if levels[levels.high] in
                        [dFlowImplicitMapStart, dFlowImplicitMapValue]:
                    raise newException(YamlPresenterJsonError,
                            "Cannot have map as map key in JSON output!")
                nextState = dFlowImplicitMapStart
            of ypsBlockOnly:
                nextState = if item.mapMayHaveKeyObjects:
                            dBlockExplicitMapValue else: dBlockImplicitMapValue
            
            if levels.len == 0:
                if nextState in
                        [dBlockExplicitMapValue, dBlockImplicitMapValue]:
                    if style != ypsJson:
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                else:
                    if style != ypsJson:
                        safeWrite('\x0A')
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                    indentation += indentationStep
            else:
                if nextState in
                        [dBlockExplicitMapValue, dBlockImplicitMapValue,
                         dBlockImplicitMapKey]:
                    if style != ypsJson:
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                    startItem(target, style, indentation, levels[levels.high])
                else:
                    startItem(target, style, indentation, levels[levels.high])
                    if style != ypsJson:
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                indentation += indentationStep
            
            if nextState in [dFlowImplicitMapStart, dFlowExplicitMapStart]:
                safeWrite('{')
            if levels.len > 0 and style in [ypsJson, ypsCanonical] and
                    levels[levels.high] in
                    [dBlockExplicitMapKey, dBlockExplicitMapValue,
                     dBlockImplicitMapKey, dBlockImplicitMapValue,
                     dBlockSequenceItem]:
                indentation += indentationStep
            levels.add(nextState)
            
        of yamlEndSequence:
            assert levels.len > 0
            case levels.pop()
            of dFlowSequenceItem:
                case style
                of ypsDefault, ypsMinimal, ypsBlockOnly:
                    safeWrite(']')
                of ypsJson, ypsCanonical:
                    indentation -= indentationStep
                    try:
                        target.write('\x0A')
                        target.write(repeat(' ', indentation))
                        target.write(']')
                    except:
                        var e = newException(YamlPresenterOutputError, "")
                        e.cause = getCurrentException()
                        raise e
                    if levels.len == 0 or levels[levels.high] notin
                            [dBlockExplicitMapKey, dBlockExplicitMapValue,
                             dBlockImplicitMapKey, dBlockImplicitMapValue,
                             dBlockSequenceItem]:
                        continue
            of dFlowSequenceStart:
                if levels.len > 0 and style in [ypsJson, ypsCanonical] and
                        levels[levels.high] in
                        [dBlockExplicitMapKey, dBlockExplicitMapValue,
                         dBlockImplicitMapKey, dBlockImplicitMapValue,
                         dBlockSequenceItem]:
                    indentation -= indentationStep
                safeWrite(']')
            of dBlockSequenceItem:
                discard
            else:
                assert false
            indentation -= indentationStep
        of yamlEndMap:
            assert levels.len > 0
            case levels.pop()
            of dFlowImplicitMapValue, dFlowExplicitMapValue:
                case style
                of ypsDefault, ypsMinimal, ypsBlockOnly:
                    safeWrite('}')
                of ypsJson, ypsCanonical:
                    indentation -= indentationStep
                    try:
                        target.write('\x0A')
                        target.write(repeat(' ', indentation))
                        target.write('}')
                    except:
                        var e = newException(YamlPresenterOutputError, "")
                        e.cause = getCurrentException()
                        raise e
                    if levels.len == 0 or levels[levels.high] notin
                            [dBlockExplicitMapKey, dBlockExplicitMapValue,
                             dBlockImplicitMapKey, dBlockImplicitMapValue,
                             dBlockSequenceItem]:
                        continue
            of dFlowImplicitMapStart, dFlowExplicitMapStart:
                if levels.len > 0 and style in [ypsJson, ypsCanonical] and
                        levels[levels.high] in
                        [dBlockExplicitMapKey, dBlockExplicitMapValue,
                         dBlockImplicitMapKey, dBlockImplicitMapValue,
                         dBlockSequenceItem]:
                    indentation -= indentationStep
                safeWrite('}')
            of dBlockImplicitMapValue, dBlockExplicitMapValue:
                discard
            else:
                assert false
            indentation -= indentationStep
        of yamlEndDocument:
            try:
                let next = s()
                if finished(s):
                    break
                cached.enqueue(next)
            except:
                var e = newException(YamlPresenterStreamError, "")
                e.cause = getCurrentException()
                raise e
            safeWrite("...\x0A")

proc transform*(input: Stream, output: Stream, style: YamlPresentationStyle,
                indentationStep: int = 2) =
    var
        tagLib = extendedTagLibrary()
        parser = newParser(tagLib)
    present(parser.parse(input), output, tagLib, style,
            indentationStep)