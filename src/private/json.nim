type
    Level = tuple[node: JsonNode, key: string]

proc initLevel(node: JsonNode): Level = (node: node, key: cast[string](nil))

proc jsonFromScalar(content: string, typeHint: YamlTypeHint): JsonNode =
    new(result)
    case typeHint
    of yTypeInteger:
        result.kind = JInt
        result.num = parseBiggestInt(content)
    of yTypeFloat:
        result.kind = JFloat
        result.fnum = parseFloat(content)
    of yTypeBoolean:
        result.kind = JBool
        result.bval = parseBool(content)
    of yTypeNull:
        result.kind = JNull
    else:
        result.kind = JString
        result.str = content

proc parseToJson*(s: string): seq[JsonNode] =
    result = parseToJson(newStringStream(s))

proc parseToJson*(s: Stream): seq[JsonNode] =
    newSeq(result, 0)
    
    var
        levels   = newSeq[Level]()
        parser   = newParser()
        tagStr   = parser.registerUri("tag:yaml.org,2002:str")
        tagBool  = parser.registerUri("tag:yaml.org,2002:bool")
        tagNull  = parser.registerUri("tag:yaml.org,2002:null")
        tagInt   = parser.registerUri("tag:yaml.org,2002:int")
        tagFloat = parser.registerUri("tag:yaml.org,2002:float")
        events   = parser.parse(s)
        anchors  = initTable[AnchorId, JsonNode]()
    
    for event in events():
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
            if event.objAnchor != anchorNone:
                anchors[event.objAnchor] = levels[levels.high].node
        of yamlStartMap:
            levels.add(initLevel(newJObject()))
            if event.objAnchor != anchorNone:
                anchors[event.objAnchor] = levels[levels.high].node
        of yamlScalar:
            case levels[levels.high].node.kind
            of JArray:
                let jsonScalar = jsonFromScalar(event.scalarContent,
                                                event.scalarType)
                levels[levels.high].node.elems.add(jsonScalar)
                if event.scalarAnchor != anchorNone:
                    anchors[event.scalarAnchor] = jsonScalar
            of JObject:
                if isNil(levels[levels.high].key):
                    # JSON only allows strings as keys
                    levels[levels.high].key = event.scalarContent
                    if event.scalarAnchor != anchorNone:
                        raise newException(ValueError,
                                "scalar keys may not have anchors in JSON")
                else:
                    let jsonScalar = jsonFromScalar(event.scalarContent,
                                                    event.scalarType)
                    levels[levels.high].node.fields.add(
                            (key: levels[levels.high].key, val: jsonScalar))
                    levels[levels.high].key = nil
                    if event.scalarAnchor != anchorNone:
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
        of yamlWarning:
            echo "YAML warning at line ", event.line, ", column ", event.column,
                 ": ", event.description
        of yamlError:
            echo "YAML error at line ", event.line, ", column ", event.column,
                 ": ", event.description
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