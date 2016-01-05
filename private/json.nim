#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

type
    Level = tuple[node: JsonNode, key: string]

proc initLevel(node: JsonNode): Level = (node: node, key: cast[string](nil))

proc jsonFromScalar(content: string, tag: TagId,
                    typeHint: YamlTypeHint): JsonNode =
    new(result)
    var mappedType: YamlTypeHint
    
    case tag
    of yTagQuestionMark:
        mappedType = typeHint
    of yTagExclamationMark, yTagString:
        mappedType = yTypeString
    of yTagBoolean:
        case typeHint
        of yTypeBoolTrue:
            mappedType = yTypeBoolTrue
        of yTypeBoolFalse:
            mappedType = yTypeBoolFalse
        else:
            raise newException(ValueError, "Invalid boolean value: " & content)
    of yTagInteger:
        mappedType = yTypeInteger
    of yTagNull:
        mappedType = yTypeNull
    of yTagFloat:
        mappedType = yTypeFloat
        ## TODO: NaN, inf
    else:
        mappedType = yTypeUnknown
    
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

proc constructJson*(s: YamlStream): seq[JsonNode] =
    newSeq(result, 0)
    
    var
        levels  = newSeq[Level]()
        anchors = initTable[AnchorId, JsonNode]()
    
    for event in s():
        case event.kind
        of yamlStartDocument:
            # we don't need to do anything here; root node will be created
            # by first scalar, sequence or map event
            discard
        of yamlEndDocument:
            # we can savely assume that levels has e length of exactly 1.
            result.add(levels.pop().node)
        of yamlStartSequence:
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
                                                 event.scalarTag,
                                                 event.scalarType), key: nil))
                continue
            
            case levels[levels.high].node.kind
            of JArray:
                let jsonScalar = jsonFromScalar(event.scalarContent,
                                                event.scalarTag,
                                                event.scalarType)
                levels[levels.high].node.elems.add(jsonScalar)
                if event.scalarAnchor != yAnchorNone:
                    anchors[event.scalarAnchor] = jsonScalar
            of JObject:
                if isNil(levels[levels.high].key):
                    # JSON only allows strings as keys
                    levels[levels.high].key = event.scalarContent
                    if event.scalarAnchor != yAnchorNone:
                        raise newException(ValueError,
                                "scalar keys may not have anchors in JSON")
                else:
                    let jsonScalar = jsonFromScalar(event.scalarContent,
                                                    event.scalarTag,
                                                    event.scalarType)
                    levels[levels.high].node.fields.add(
                            (key: levels[levels.high].key, val: jsonScalar))
                    levels[levels.high].key = nil
                    if event.scalarAnchor != yAnchorNone:
                        anchors[event.scalarAnchor] = jsonScalar
            else:
                discard # will never happen
        of yamlEndSequence, yamlEndMap:
            if levels.len > 1:
                let level = levels.pop()
                case levels[levels.high].node.kind
                of JArray:
                    levels[levels.high].node.elems.add(level.node)
                of JObject:
                    if isNil(levels[levels.high].key):
                        raise newException(ValueError,
                                "non-scalar as key not allowed in JSON")
                    else:
                        levels[levels.high].node.fields.add(
                            (key: levels[levels.high].key, val: level.node))
                        levels[levels.high].key = nil
                else:
                    discard # will never happen
            else:
                discard # wait for yamlEndDocument
        of yamlAlias:
            # we can savely assume that the alias exists in anchors
            # (else the parser would have already thrown an exception)
            case levels[levels.high].node.kind
            of JArray:
                levels[levels.high].node.elems.add(anchors[event.aliasTarget])
            of JObject:
                if isNil(levels[levels.high].key):
                    raise newException(ValueError,
                            "cannot use alias node as key in JSON")
                else:
                    levels[levels.high].node.fields.add(
                            (key: levels[levels.high].key,
                             val: anchors[event.aliasTarget]))
                    levels[levels.high].key = nil
            else:
                discard # will never happen

proc loadToJson*(s: Stream): seq[JsonNode] =
    var
        parser = newParser(coreTagLibrary())
        events = parser.parse(s)
    return constructJson(events)