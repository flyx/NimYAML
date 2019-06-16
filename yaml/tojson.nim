#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ==================
## Module yaml.tojson
## ==================
##
## The tojson API enables you to parser a YAML character stream into the JSON
## structures provided by Nim's stdlib.

import json, streams, strutils, tables
import taglib, hints, serialization, stream, private/internal, parser

# represents a single YAML level. The `node` with name `key`.
# `expKey` is used to indicate that an empty node shall be filled
type Level = tuple[node: JsonNode, key: string, expKey: bool]

proc initLevel(node: JsonNode): Level {.raises: [].} =
  (node: node, key: "", expKey: true)

proc jsonFromScalar(content: string, tag: TagId): JsonNode
   {.raises: [YamlConstructionError].}=
  new(result)
  var mappedType: TypeHint

  case tag
  of yTagQuestionMark: mappedType = guessType(content)
  of yTagExclamationMark, yTagString: mappedType = yTypeUnknown
  of yTagBoolean:
    case guessType(content)
    of yTypeBoolTrue: mappedType = yTypeBoolTrue
    of yTypeBoolFalse: mappedType = yTypeBoolFalse
    else:
      raise newException(YamlConstructionError,
                         "Invalid boolean value: " & content)
  of yTagInteger: mappedType = yTypeInteger
  of yTagNull: mappedType = yTypeNull
  of yTagFloat:
    case guessType(content)
    of yTypeFloat: mappedType = yTypeFloat
    of yTypeFloatInf: mappedType = yTypeFloatInf
    of yTypeFloatNaN: mappedType = yTypeFloatNaN
    else:
      raise newException(YamlConstructionError,
                         "Invalid float value: " & content)
  else: mappedType = yTypeUnknown

  try:
    case mappedType
    of yTypeInteger:
      result = JsonNode(kind: JInt, num: parseBiggestInt(content))
    of yTypeFloat:
      result = JsonNode(kind: JFloat, fnum: parseFloat(content))
    of yTypeFloatInf:
      result = JsonNode(kind: JFloat, fnum: if content[0] == '-': NegInf else: Inf)
    of yTypeFloatNaN:
      result = JsonNode(kind: JFloat, fnum: NaN)
    of yTypeBoolTrue:
      result = JsonNode(kind: JBool, bval: true)
    of yTypeBoolFalse:
      result = JsonNode(kind: JBool, bval: false)
    of yTypeNull:
      result = JsonNode(kind: JNull)
    else:
      result = JsonNode(kind: JString)
      shallowCopy(result.str, content)
  except ValueError:
    var e = newException(YamlConstructionError, "Cannot parse numeric value")
    e.parent = getCurrentException()
    raise e

proc constructJson*(s: var YamlStream): seq[JsonNode]
    {.raises: [YamlConstructionError, YamlStreamError].} =
  ## Construct an in-memory JSON tree from a YAML event stream. The stream may
  ## not contain any tags apart from those in ``coreTagLibrary``. Anchors and
  ## aliases will be resolved. Maps in the input must not contain
  ## non-scalars as keys. Each element of the result represents one document
  ## in the YAML stream.
  ##
  ## **Warning:** The special float values ``[+-]Inf`` and ``NaN`` will be
  ## parsed into Nim's JSON structure without error. However, they cannot be
  ## rendered to a JSON character stream, because these values are not part
  ## of the JSON specification. Nim's JSON implementation currently does not
  ## check for these values and will output invalid JSON when rendering one
  ## of these values into a JSON character stream.
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
                                         event.scalarTag),
                    key: "",
                    expKey: true))
        continue

      case levels[levels.high].node.kind
      of JArray:
        let jsonScalar = jsonFromScalar(event.scalarContent,
                                        event.scalarTag)
        levels[levels.high].node.elems.add(jsonScalar)
        if event.scalarAnchor != yAnchorNone:
          anchors[event.scalarAnchor] = jsonScalar
      of JObject:
        if levels[levels.high].expKey:
          levels[levels.high].expKey = false
          # JSON only allows strings as keys
          levels[levels.high].key = event.scalarContent
          if event.scalarAnchor != yAnchorNone:
            raise newException(YamlConstructionError,
                "scalar keys may not have anchors in JSON")
        else:
          let jsonScalar = jsonFromScalar(event.scalarContent,
                                          event.scalarTag)
          levels[levels.high].node[levels[levels.high].key] = jsonScalar
          levels[levels.high].expKey = true
          if event.scalarAnchor != yAnchorNone:
            anchors[event.scalarAnchor] = jsonScalar
      else:
        internalError("Unexpected node kind: " & $levels[levels.high].node.kind)
    of yamlEndSeq, yamlEndMap:
      if levels.len > 1:
        let level = levels.pop()
        case levels[levels.high].node.kind
        of JArray: levels[levels.high].node.elems.add(level.node)
        of JObject:
          if levels[levels.high].expKey:
            raise newException(YamlConstructionError,
                "non-scalar as key not allowed in JSON")
          else:
            levels[levels.high].node[levels[levels.high].key] = level.node
            levels[levels.high].expKey = true
        else:
          internalError("Unexpected node kind: " &
                        $levels[levels.high].node.kind)
      else: discard # wait for yamlEndDocument
    of yamlAlias:
      # we can savely assume that the alias exists in anchors
      # (else the parser would have already thrown an exception)
      case levels[levels.high].node.kind
      of JArray:
        levels[levels.high].node.elems.add(
            anchors.getOrDefault(event.aliasTarget))
      of JObject:
        if levels[levels.high].expKey:
          raise newException(YamlConstructionError,
              "cannot use alias node as key in JSON")
        else:
          levels[levels.high].node.fields.add(
              levels[levels.high].key, anchors.getOrDefault(event.aliasTarget))
          levels[levels.high].expKey = true
      else:
        internalError("Unexpected node kind: " & $levels[levels.high].node.kind)

when not defined(JS):
  proc loadToJson*(s: Stream): seq[JsonNode]
      {.raises: [YamlParserError, YamlConstructionError, IOError].} =
    ## Uses `YamlParser <#YamlParser>`_ and
    ## `constructJson <#constructJson>`_ to construct an in-memory JSON tree
    ## from a YAML character stream.
    var
      parser = newYamlParser(initCoreTagLibrary())
      events = parser.parse(s)
    try:
      return constructJson(events)
    except YamlStreamError:
      let e = getCurrentException()
      if e.parent of IOError:
        raise (ref IOError)(e.parent)
      elif e.parent of YamlParserError:
        raise (ref YamlParserError)(e.parent)
      else: internalError("Unexpected exception: " & e.parent.repr)

proc loadToJson*(str: string): seq[JsonNode]
    {.raises: [YamlParserError, YamlConstructionError].} =
  ## Uses `YamlParser <#YamlParser>`_ and
  ## `constructJson <#constructJson>`_ to construct an in-memory JSON tree
  ## from a YAML character stream.
  var
    parser = newYamlParser(initCoreTagLibrary())
    events = parser.parse(str)
  try: return constructJson(events)
  except YamlStreamError:
    let e = getCurrentException()
    if e.parent of YamlParserError:
      raise (ref YamlParserError)(e.parent)
    else: internalError("Unexpected exception: " & e.parent.repr)
