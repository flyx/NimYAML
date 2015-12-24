type
    Level = tuple[node: JsonNode, key: string]

proc initLevel(node: JsonNode): Level = (node: node, key: nil)

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
        events = parser.parse(s)
    
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
            levels.add((node: newJArray(), key: cast[string](nil)))
        of yamlStartMap:
            levels.add((node: newJObject(), key: cast[string](nil)))
        of yamlScalar:
            case levels[levels.high].node.kind
            of JArray:
                levels[levels.high].node.elems.add(
                        jsonFromScalar(event.scalarContent, event.scalarType))
            of JObject:
                if isNil(levels[levels.high].key):
                    # JSON only allows strings as keys
                    levels[levels.high].key = event.scalarContent
                else:
                    levels[levels.high].node.fields.add(
                            (key: levels[levels.high].key, val: jsonFromScalar(
                                   event.scalarContent, event.scalarType)))
                    levels[levels.high].key = nil
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
            discard # todo