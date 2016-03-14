#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

type
    Level = tuple[node: JsonNode, key: string]

proc initLevel(node: JsonNode): Level {.raises: [].} =
    (node: node, key: cast[string](nil))

proc jsonFromScalar(content: string, tag: TagId): JsonNode
       {.raises: [YamlConstructionError].}=
    new(result)
    var mappedType: TypeHint
    
    case tag
    of yTagQuestionMark:
        mappedType = guessType(content)
    of yTagExclamationMark, yTagString:
        mappedType = yTypeUnknown
    of yTagBoolean:
        case guessType(content)
        of yTypeBoolTrue:
            mappedType = yTypeBoolTrue
        of yTypeBoolFalse:
            mappedType = yTypeBoolFalse
        else:
            raise newException(YamlConstructionError,
                               "Invalid boolean value: " & content)
    of yTagInteger:
        mappedType = yTypeInteger
    of yTagNull:
        mappedType = yTypeNull
    of yTagFloat:
        case guessType(content)
        of yTypeFloat:
            mappedType = yTypeFloat
        of yTypeFloatInf:
            mappedType = yTypeFloatInf
        of yTypeFloatNaN:
            mappedType = yTypeFloatNaN
        else:
            raise newException(YamlConstructionError,
                               "Invalid float value: " & content)
    else:
        mappedType = yTypeUnknown
    
    try:
        case mappedType
        of yTypeInteger:
            result.kind = JInt
            result.num = parseBiggestInt(content)
        of yTypeFloat:
            result.kind = JFloat
            result.fnum = parseFloat(content)
        of yTypeFloatInf:
            result.kind = JFloat
            result.fnum = if content[0] == '-': NegInf else: Inf
        of yTypeFloatNaN:
            result.kind = JFloat
            result.fnum = NaN
        of yTypeBoolTrue:
            result.kind = JBool
            result.bval = true
        of yTypeBoolFalse:
            result.kind = JBool
            result.bval = false
        of yTypeNull:
            result.kind = JNull
        else:
            result.kind = JString
            result.str = content
    except ValueError:
        var e = newException(YamlConstructionError,
                             "Cannot parse numeric value")
        e.parent = getCurrentException()
        raise e

proc constructJson*(s: var YamlStream): seq[JsonNode] =
    newSeq(result, 0)
    
    var
        levels  = newSeq[Level]()
        anchors = initTable[AnchorId, JsonNode]()
    for event in s:
        case event.kind
        of yamlStartDoc:
            # we don't need to do anything here; root node will be created
            # by first scalar, sequence or map event
            discard
        of yamlEndDoc:
            # we can savely assume that levels has e length of exactly 1.
            result.add(levels.pop().node)
        of yamlStartSeq:
            levels.add(initLevel(newJArray()))
            if event.seqAnchor != yAnchorNone:
                anchors[event.seqAnchor] = levels[levels.high].node
        of yamlStartMap:
            levels.add(initLevel(newJObject()))
            if event.mapAnchor != yAnchorNone:
                anchors[event.mapAnchor] = levels[levels.high].node
        of yamlScalar:
            if levels.len == 0:
                # parser ensures that next event will be yamlEndDocument
                levels.add((node: jsonFromScalar(event.scalarContent,
                                                 event.scalarTag), key: nil))
                continue
            
            case levels[levels.high].node.kind
            of JArray:
                let jsonScalar = jsonFromScalar(event.scalarContent,
                                                event.scalarTag)
                levels[levels.high].node.elems.add(jsonScalar)
                if event.scalarAnchor != yAnchorNone:
                    anchors[event.scalarAnchor] = jsonScalar
            of JObject:
                if isNil(levels[levels.high].key):
                    # JSON only allows strings as keys
                    levels[levels.high].key = event.scalarContent
                    if event.scalarAnchor != yAnchorNone:
                        raise newException(YamlConstructionError,
                                "scalar keys may not have anchors in JSON")
                else:
                    let jsonScalar = jsonFromScalar(event.scalarContent,
                                                    event.scalarTag)
                    levels[levels.high].node[levels[levels.high].key] =
                            jsonScalar
                    levels[levels.high].key = nil
                    if event.scalarAnchor != yAnchorNone:
                        anchors[event.scalarAnchor] = jsonScalar
            else: discard # will never happen
        of yamlEndSeq, yamlEndMap:
            if levels.len > 1:
                let level = levels.pop()
                case levels[levels.high].node.kind
                of JArray:
                    levels[levels.high].node.elems.add(level.node)
                of JObject:
                    if isNil(levels[levels.high].key):
                        raise newException(YamlConstructionError,
                                "non-scalar as key not allowed in JSON")
                    else:
                        levels[levels.high].node[
                            levels[levels.high].key] = level.node
                        levels[levels.high].key = nil
                else: discard # will never happen
            else: discard # wait for yamlEndDocument
        of yamlAlias:
            # we can savely assume that the alias exists in anchors
            # (else the parser would have already thrown an exception)
            case levels[levels.high].node.kind
            of JArray:
                try:
                    levels[levels.high].node.elems.add(
                            anchors[event.aliasTarget])
                except KeyError:
                    # we can safely assume that this doesn't happen. It would
                    # have resulted in a parser error earlier.
                    assert(false)
            of JObject:
                if isNil(levels[levels.high].key):
                    raise newException(YamlConstructionError,
                            "cannot use alias node as key in JSON")
                else:
                    try:
                        levels[levels.high].node.fields.add(
                                levels[levels.high].key,
                                anchors[event.aliasTarget])
                    except KeyError:
                        # we can safely assume that this doesn't happen. It would
                        # have resulted in a parser error earlier.
                        assert(false)
                    levels[levels.high].key = nil
            else: discard # will never happen

proc loadToJson*(s: Stream): seq[JsonNode] =
    var
        parser = newYamlParser(initCoreTagLibrary())
        events = parser.parse(s)
    try:
        return constructJson(events)
    except YamlConstructionError:
        var e = cast[ref YamlConstructionError](getCurrentException())
        e.line = parser.getLineNumber()
        e.column = parser.getColNumber()
        e.lineContent = parser.getLineContent()
        raise e
    except YamlStreamError:
        let e = getCurrentException()
        if e.parent of IOError:
            raise cast[ref IOError](e.parent)
        elif e.parent of YamlParserError:
            raise cast[ref YamlParserError](e.parent)
        else:
            # can never happen
            assert(false)
    except AssertionError: raise
    except Exception:
        # compiler bug: https://github.com/nim-lang/Nim/issues/3772
        assert(false)
