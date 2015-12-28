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

proc needsEscaping(scalar: string): bool =
    scalar.find({'{', '}', '[', ']', ',', '#', '-', ':', '?', '%', '\x0A',
                 '\c'}) != -1

proc writeDoubleQuoted(scalar: string, s: Stream) =
    s.write('"')
    for c in scalar:
        if c == '"':
            s.write('\\')
        s.write(c)
    s.write('"')        

proc startItem(target: Stream, style: YamlDumpStyle, indentation: int,
               state: var DumperState) =
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
        if style == yDumpJson:
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
        if style == yDumpJson:
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
        of yDumpMinimal, yDumpDefault:
            discard
        of yDumpCanonical, yDumpJson:
            target.write('\x0A')
            target.write(repeat(' ', indentation))
        of yDumpBlockOnly:
            discard # can never happen
        state = dFlowSequenceItem
    of dFlowSequenceItem:
        case style
        of yDumpMinimal, yDumpDefault:
            target.write(", ")
        of yDumpCanonical, yDumpJson:
            target.write(",\x0A")
            target.write(repeat(' ', indentation))
        of yDumpBlockOnly:
            discard # can never happen
    
proc writeTagAndAnchor(target: Stream, tag: TagId, tagLib: YamlTagLibrary,
                       anchor: AnchorId) =
    if tag notin [yTagQuestionMark, yTagExclamationMark]:
        let tagUri = tagLib.uri(tag)
        if tagUri.startsWith("tag:yaml.org,2002:"):
            target.write("!!")
            target.write(tagUri[18..^1])
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

proc dump*(s: YamlStream, target: Stream, tagLib: YamlTagLibrary,
           style: YamlDumpStyle = yDumpDefault, indentationStep: int = 2) =
    var
        cached = initQueue[YamlStreamEvent]()
        cacheIterator = iterator(): YamlStreamEvent =
            while true:
                while cached.len > 0:
                    yield cached.dequeue()
                let item = s()
                if finished(s):
                    break
                cached.enqueue(item)
        indentation = 0
        levels = newSeq[DumperState]()
    
    for item in cacheIterator():
        case item.kind
        of yamlStartDocument:
            if style != yDumpJson:
                # TODO: tag directives
                target.write("%YAML 1.2\x0A--- ")
        of yamlScalar:
            if levels.len == 0:
                if style != yDumpJson:
                    target.write('\x0A')
            else:
                startItem(target, style, indentation, levels[levels.high])
            if style != yDumpJson:
                writeTagAndAnchor(target,
                                  item.scalarTag, tagLib, item.scalarAnchor)
            
            if item.scalarContent.needsEscaping or
               style in [yDumpCanonical, yDumpJson]:
                writeDoubleQuoted(item.scalarContent, target)
            else:
                target.write(item.scalarContent)
        of yamlAlias:
            if levels.len == 0:
                raise newException(ValueError, "Malformed YamlStream")
            else:
                startItem(target, style, indentation, levels[levels.high])
            target.write('*')
            target.write(cast[byte]('a') + cast[byte](item.aliasTarget))
        of yamlStartSequence:
            var nextState: DumperState
            case style
            of yDumpDefault:
                var length = 0
                while true:
                    let next = s()
                    if finished(s):
                        raise newException(ValueError, "Malformed YamlStream")
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
                nextState = if length <= 60: dFlowSequenceStart else:
                            dBlockSequenceItem
            of yDumpMinimal, yDumpJson, yDumpCanonical:
                nextState = dFlowSequenceStart
            of yDumpBlockOnly:
                nextState = dBlockSequenceItem 
            
            if levels.len == 0:
                if nextState == dBlockSequenceItem:
                    if style != yDumpJson:
                        writeTagAndAnchor(target,
                                          item.seqTag, tagLib, item.seqAnchor)
                else:
                    if style != yDumpJson:
                        target.write('\x0A')
                        writeTagAndAnchor(target,
                                          item.seqTag, tagLib, item.seqAnchor)
                    indentation += indentationStep
            else:
                if nextState == dBlockSequenceItem:
                    if style != yDumpJson:
                        writeTagAndAnchor(target,
                                          item.seqTag, tagLib, item.seqAnchor)
                    startItem(target, style, indentation, levels[levels.high])
                else:
                    startItem(target, style, indentation, levels[levels.high])
                    if style != yDumpJson:
                        writeTagAndAnchor(target,
                                          item.seqTag, tagLib, item.seqAnchor)
                indentation += indentationStep
            
            if nextState == dFlowSequenceStart:
                target.write('[')
            if levels.len > 0 and style in [yDumpJson, yDumpCanonical] and
                    levels[levels.high] in
                    [dBlockExplicitMapKey, dBlockExplicitMapValue,
                     dBlockImplicitMapKey, dBlockImplicitMapValue,
                     dBlockSequenceItem]:
                indentation += indentationStep
            levels.add(nextState)
        of yamlStartMap:
            var nextState: DumperState
            case style
            of yDumpDefault:
                var length = 0
                while true:
                    let next = s()
                    if finished(s):
                        raise newException(ValueError, "Malformed YamlStream")
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
                nextState = if length <= 60: dFlowImplicitMapStart else:
                            if item.mapMayHaveKeyObjects:
                            dBlockExplicitMapValue else: dBlockImplicitMapValue
            of yDumpMinimal:
                nextState = if item.mapMayHaveKeyObjects:
                            dFlowExplicitMapStart else: dFlowImplicitMapStart
            of yDumpCanonical:
                nextState = dFlowExplicitMapStart
            of yDumpJson:
                nextState = dFlowImplicitMapStart
            of yDumpBlockOnly:
                nextState = if item.mapMayHaveKeyObjects:
                            dBlockExplicitMapValue else: dBlockImplicitMapValue
            
            if levels.len == 0:
                if nextState in
                        [dBlockExplicitMapValue, dBlockImplicitMapValue]:
                    if style != yDumpJson:
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                else:
                    if style != yDumpJson:
                        target.write('\x0A')
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                    indentation += indentationStep
            else:
                if nextState in
                        [dBlockExplicitMapValue, dBlockImplicitMapValue]:
                    if style != yDumpJson:
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                    startItem(target, style, indentation, levels[levels.high])
                else:
                    startItem(target, style, indentation, levels[levels.high])
                    if style != yDumpJson:
                        writeTagAndAnchor(target,
                                          item.mapTag, tagLib, item.mapAnchor)
                indentation += indentationStep
            
            if nextState in [dFlowImplicitMapStart, dFlowExplicitMapStart]:
                target.write('{')
            if levels.len > 0 and style in [yDumpJson, yDumpCanonical] and
                    levels[levels.high] in
                    [dBlockExplicitMapKey, dBlockExplicitMapValue,
                     dBlockImplicitMapKey, dBlockImplicitMapValue,
                     dBlockSequenceItem]:
                indentation += indentationStep
            levels.add(nextState)
            
        of yamlEndSequence:
            if levels.len == 0:
                raise newException(ValueError, "Malformed YamlStream")
            case levels.pop()
            of dFlowSequenceItem:
                case style
                of yDumpDefault, yDumpMinimal, yDumpBlockOnly:
                    target.write(']')
                of yDumpJson, yDumpCanonical:
                    indentation -= indentationStep
                    target.write('\x0A')
                    target.write(repeat(' ', indentation))
                    target.write(']')
                    if levels.len == 0 or levels[levels.high] notin
                            [dBlockExplicitMapKey, dBlockExplicitMapValue,
                             dBlockImplicitMapKey, dBlockImplicitMapValue,
                             dBlockSequenceItem]:
                        continue
            of dFlowSequenceStart:
                if levels.len > 0 and style in [yDumpJson, yDumpCanonical] and
                        levels[levels.high] in
                        [dBlockExplicitMapKey, dBlockExplicitMapValue,
                         dBlockImplicitMapKey, dBlockImplicitMapValue,
                         dBlockSequenceItem]:
                    indentation -= indentationStep
                target.write(']')
            of dBlockSequenceItem:
                discard
            else:
                raise newException(ValueError, "Malformed YamlStream")
            indentation -= indentationStep
        of yamlEndMap:
            if levels.len == 0:
                raise newException(ValueError, "Malformed YamlStream")
            case levels.pop()
            of dFlowImplicitMapValue, dFlowExplicitMapValue:
                case style
                of yDumpDefault, yDumpMinimal, yDumpBlockOnly:
                    target.write('}')
                of yDumpJson, yDumpCanonical:
                    indentation -= indentationStep
                    target.write('\x0A')
                    target.write(repeat(' ', indentation))
                    target.write('}')
                    if levels.len == 0 or levels[levels.high] notin
                            [dBlockExplicitMapKey, dBlockExplicitMapValue,
                             dBlockImplicitMapKey, dBlockImplicitMapValue,
                             dBlockSequenceItem]:
                        continue
            of dFlowImplicitMapStart, dFlowExplicitMapStart:
                if levels.len > 0 and style in [yDumpJson, yDumpCanonical] and
                        levels[levels.high] in
                        [dBlockExplicitMapKey, dBlockExplicitMapValue,
                         dBlockImplicitMapKey, dBlockImplicitMapValue,
                         dBlockSequenceItem]:
                    indentation -= indentationStep
                target.write('}')
            of dBlockImplicitMapValue, dBlockExplicitMapValue:
                discard
            else:
                raise newException(ValueError, "Malformed YamlStream")
            indentation -= indentationStep
        of yamlEndDocument:
            let next = s()
            if finished(s):
                break
            target.write("...\x0A")
            cached.enqueue(next)
        of yamlWarning:
            discard
        of yamlError:
            raise newException(ValueError, "(" & $item.line & ", " &
                               $item.column & "): " & item.description)

proc transform*(input: Stream, output: Stream, style: YamlDumpStyle,
                indentationStep: int = 2) =
    var
        tagLib = extendedTagLibrary()
        parser = newParser(tagLib)
    dump(parser.parse(input), output, tagLib, style,
         indentationStep)