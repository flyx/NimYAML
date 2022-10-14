#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ===============
## Module yaml/dom
## ===============
##
## This is the DOM API, which enables you to load YAML into a tree-like
## structure. It can also dump the structure back to YAML. Formally, it
## represents the *Representation Graph* as defined in the YAML specification.
##
## The main interface of this API are ``loadDom`` and ``dumpDom``. The other
## exposed procs are low-level and useful if you want to load or generate parts
## of a ``YamlStream``.
##
## The ``YamlNode`` objects in the DOM can be used similarly to the ``JsonNode``
## objects of Nim's `json module <http://nim-lang.org/docs/json.html>`_.

import std / [tables, streams, hashes, sets, strutils]
import data, stream, taglib, serialization, private/internal, parser,
       presenter

when defined(gcArc) and not defined(gcOrc):
  {.error: "NimYAML's DOM API only supports ORC because ARC can't deal with cycles".}

const
  defaultMark: Mark = (1.Positive, 1.Positive) ## \
    ## used for events that are not generated from input.

when defined(nimNoNil):
    {.experimental: "notnil".}
type
  YamlNodeKind* = enum
    yScalar, yMapping, ySequence

  YamlNode* = ref YamlNodeObj
    ## Represents a node in a ``YamlDocument``.

  YamlNodeObj* = object
    tag*: Tag
    startPos*, endPos*: Mark
    case kind*: YamlNodeKind
    of yScalar:
      content*    : string
      scalarStyle*: ScalarStyle
    of ySequence:
      elems*   : seq[YamlNode]
      seqStyle*: CollectionStyle
    of yMapping:
      fields*  : TableRef[YamlNode, YamlNode]
      mapStyle*: CollectionStyle
      # compiler does not like Table[YamlNode, YamlNode]

  YamlDocument* {.deprecated: "use YamlNode with serialization API instead".} = object
    ## Represents a YAML document.
    root*: YamlNode

proc hash*(o: YamlNode): Hash =
  result = o.tag.hash
  case o.kind
  of yScalar: result = result !& o.content.hash
  of yMapping:
    for key, value in o.fields.pairs:
      result = result !& key.hash !& value.hash
  of ySequence:
    for item in o.elems:
      result = result !& item.hash
  result = !$result

proc eqImpl(x, y: YamlNode, alreadyVisited: var HashSet[pointer]): bool =
  template compare(a, b: YamlNode) {.dirty.} =
    if cast[pointer](a) != cast[pointer](b):
      if cast[pointer](a) in alreadyVisited and
          cast[pointer](b) in alreadyVisited:
        # prevent infinite loop!
        return false
      elif a != b: return false

  if x.kind != y.kind or x.tag != y.tag: return false
  alreadyVisited.incl(cast[pointer](x))
  alreadyVisited.incl(cast[pointer](y))
  case x.kind
  of yScalar: result = x.content == y.content
  of ySequence:
    if x.elems.len != y.elems.len: return false
    for i in 0..<x.elems.len:
      compare(x.elems[i], y.elems[i])
  of yMapping:
    if x.fields.len != y.fields.len: return false
    for xKey, xValue in x.fields.pairs:
      let xKeyVisited = cast[pointer](xKey) in alreadyVisited
      var matchingValue: ref YamlNodeObj = nil
      for yKey, yValue in y.fields.pairs:
        if cast[pointer](yKey) != cast[pointer](xKey):
          if cast[pointer](yKey) in alreadyVisited and xKeyVisited:
            # prevent infinite loop!
            continue
          if xKey == yKey:
            matchingValue = yValue
            break
        else:
          matchingValue = yValue
          break
      if isNil(matchingValue): return false
      compare(xValue, matchingValue)

proc `==`*(x, y: YamlNode): bool =
  var alreadyVisited = initHashSet[pointer]()
  result = eqImpl(x, y, alreadyVisited)

proc `$`*(n: YamlNode): string =
  result = "!<" & $n.tag & "> "
  case n.kind
  of yScalar: result.add(escape(n.content))
  of ySequence:
    result.add('[')
    for item in n.elems:
      result.add($item)
      result.add(", ")
    result.setLen(result.len - 1)
    result[^1] = ']'
  of yMapping:
    result.add('{')
    for key, value in n.fields.pairs:
      result.add($key)
      result.add(": ")
      result.add($value)
      result.add(", ")
    result.setLen(result.len - 1)
    result[^1] = '}'

proc newYamlNode*(content: string, tag: Tag = yTagQuestionMark,
    style: ScalarStyle = ssAny,
    startPos, endPos: Mark = defaultMark): YamlNode =
  YamlNode(kind: yScalar, content: content, tag: tag,
      startPos: startPos, endPos: endPos)

proc newYamlNode*(elems: openarray[YamlNode], tag: Tag = yTagQuestionMark,
    style: CollectionStyle = csAny,
    startPos, endPos: Mark = defaultMark): YamlNode =
  YamlNode(kind: ySequence, elems: @elems, tag: tag,
      startPos: startPos, endPos: endPos)

proc newYamlNode*(fields: openarray[(YamlNode, YamlNode)],
    tag: Tag = yTagQuestionMark, style: CollectionStyle = csAny,
    startPos, endPos: Mark = defaultMark): YamlNode =
  YamlNode(kind: yMapping, fields: newTable(fields), tag: tag,
      startPos: startPos, endPos: endPos)

proc initYamlDoc*(root: YamlNode): YamlDocument =
  result = YamlDocument(root: root)

proc constructChild*(s: var YamlStream, c: ConstructionContext,
                     result: var YamlNode)
    {.raises: [YamlStreamError, YamlConstructionError].} =
  template addAnchor(c: ConstructionContext, target: Anchor) =
    if target != yAnchorNone:
      yAssert(not c.refs.hasKey(target))
      c.refs[target] = (tag: yamlTag(YamlNode), p: cast[pointer](result))

  var start: Event
  when defined(gcArc) or defined(gcOrc):
    start = s.next()
  else:
    shallowCopy(start, s.next())

  case start.kind
  of yamlStartMap:
    result = YamlNode(tag: start.mapProperties.tag,
                      kind: yMapping,
                      fields: newTable[YamlNode, YamlNode](),
                      mapStyle: start.mapStyle,
                      startPos: start.startPos, endPos: start.endPos)
    addAnchor(c, start.mapProperties.anchor)
    while s.peek().kind != yamlEndMap:
      var
        key: YamlNode = nil
        value: YamlNode = nil
      constructChild(s, c, key)
      constructChild(s, c, value)
      if result.fields.hasKeyOrPut(key, value):
        raise newException(YamlConstructionError,
            "Duplicate key: " & $key)
    discard s.next()
  of yamlStartSeq:
    result = YamlNode(tag: start.seqProperties.tag,
                      kind: ySequence,
                      elems: newSeq[YamlNode](),
                      seqStyle: start.seqStyle,
                      startPos: start.startPos, endPos: start.endPos)
    addAnchor(c, start.seqProperties.anchor)
    while s.peek().kind != yamlEndSeq:
      var item: YamlNode = nil
      constructChild(s, c, item)
      result.elems.add(item)
    discard s.next()
  of yamlScalar:
    result = YamlNode(tag: start.scalarProperties.tag,
                      kind: yScalar, scalarStyle: start.scalarStyle,
                      startPos: start.startPos, endPos: start.endPos)
    addAnchor(c, start.scalarProperties.anchor)
    when defined(gcArc) or defined(gcOrc):
      result.content = move start.scalarContent
    else:
      shallowCopy(result.content, start.scalarContent)
  of yamlAlias:
    result = cast[YamlNode](c.refs.getOrDefault(start.aliasTarget).p)
  else: internalError("Malformed YamlStream")

proc compose*(s: var YamlStream): YamlDocument
    {.raises: [YamlStreamError, YamlConstructionError],
      deprecated: "use construct(s, root) instead".} =
  construct(s, result.root)

proc loadDom*(s: Stream | string): YamlDocument
    {.raises: [IOError, OSError, YamlParserError, YamlConstructionError]
      deprecated: "use loadAs[YamlNode](s) instead".} =
  load(s, result.root)

proc loadMultiDom*(s: Stream | string): seq[YamlDocument]
    {.raises: [IOError, OSError, YamlParserError, YamlConstructionError]
      deprecated: "use loadMultiDoc[YamlNode](s, target) instead".} =
  var
    parser = initYamlParser(tagLib)
    events = parser.parse(s)
    e: Event
  try:
    e = events.next()
    yAssert(e.kind == yamlStartStream)
    while events.peek().kind == yamlStartDoc:
      result.add(compose(events, tagLib))
    e = events.next()
    yAssert(e.kind != yamlEndStream)
  except YamlStreamError:
    let ex = getCurrentException()
    if ex.parent of YamlParserError:
      raise (ref YamlParserError)(ex.parent)
    elif ex.parent of IOError:
      raise (ref IOError)(ex.parent)
    elif ex.parent of OSError:
      raise (ref OSError)(ex.parent)
    else: internalError("Unexpected exception: " & ex.parent.repr)

proc representChild*(value: YamlNodeObj, ts: TagStyle,
                     c: SerializationContext) {.raises: [YamlSerializationError].} =
  let childTagStyle = if ts == tsRootOnly: tsNone else: ts
  case value.kind
  of yScalar:
    c.put(scalarEvent(value.content, value.tag, style = value.scalarStyle,
        startPos = value.startPos, endPos = value.endPos))
  of ySequence:
    c.put(startSeqEvent(tag = value.tag, style = value.seqStyle,
        startPos = value.startPos, endPos = value.endPos))
    for item in value.elems: representChild(item, childTagStyle, c)
    c.put(endSeqEvent())
  of yMapping:
    c.put(startMapEvent(tag = value.tag, style = value.mapStyle,
        startPos = value.startPos, endPos = value.endPos))
    for key, value in value.fields.pairs:
      representChild(key, childTagStyle, c)
      representChild(value, childTagStyle, c)
    c.put(endMapEvent())

proc serialize*(doc: YamlDocument, a: AnchorStyle = asTidy): YamlStream
    {.deprecated: "use represent[YamlNode] instead".} =
  result = represent(doc.root, tsAll, a = a, handles = @[])

proc dumpDom*(doc: YamlDocument, target: Stream,
              anchorStyle: AnchorStyle = asTidy,
              options: PresentationOptions = defaultPresentationOptions)
    {.deprecated: "use dump[YamlNode] instead".} =
  ## Dump a YamlDocument as YAML character stream.
  dump(doc.root, target, tsAll, anchorStyle = anchorStyle, options = options,
       handles = @[])

proc `[]`*(node: YamlNode, i: int): YamlNode =
  ## Get the node at index *i* from a sequence. *node* must be a *ySequence*.
  assert node.kind == ySequence
  node.elems[i]

proc `[]=`*(node: var YamlNode, i: int, val: YamlNode) =
  ## Set the node at index *i* of a sequence. *node* must be a *ySequence*.
  assert node.kind == ySequence
  node.elems[i] = val

proc `[]`*(node: YamlNode, key: YamlNode): YamlNode =
  ## Get the value for a key in a mapping. *node* must be a *yMapping*.
  assert node.kind == yMapping
  node.fields[key]

proc `[]=`*(node: YamlNode, key: YamlNode, value: YamlNode) =
  ## Set the value for a key in a mapping. *node* must be a *yMapping*.
  node.fields[key] = value

proc `[]`*(node: YamlNode, key: string): YamlNode =
  ## Get the value for a string key in a mapping. *node* must be a *yMapping*.
  ## This searches for a scalar key with content *key* and either no explicit
  ## tag or the explicit tag ``!!str``.
  assert node.kind == yMapping
  var keyNode = YamlNode(kind: yScalar, tag: yTagExclamationMark, content: key)
  result = node.fields.getOrDefault(keyNode)
  if isNil(result):
    keyNode.tag = yTagQuestionMark
    result = node.fields.getOrDefault(keyNode)
    if isNil(result):
      keyNode.tag = nimTag(yamlTagRepositoryPrefix & "str")
      result = node.fields.getOrDefault(keyNode)
      if isNil(result):
        raise newException(KeyError, "No key " & escape(key) & " exists!")

proc len*(node: YamlNode): int =
  ## If *node* is a *yMapping*, return the number of key-value pairs. If *node*
  ## is a *ySequence*, return the number of elements. Else, return ``0``
  case node.kind
  of yMapping: result = node.fields.len
  of ySequence: result = node.elems.len
  of yScalar: result = 0

iterator items*(node: YamlNode): YamlNode =
  ## Iterates over all items of a sequence. *node* must be a *ySequence*.
  assert node.kind == ySequence
  for item in node.elems: yield item

iterator mitems*(node: var YamlNode): YamlNode =
  ## Iterates over all items of a sequence. *node* must be a *ySequence*.
  ## Values can be modified.
  assert node.kind == ySequence
  for item in node.elems.mitems: yield item

iterator pairs*(node: YamlNode): tuple[key, value: YamlNode] =
  ## Iterates over all key-value pairs of a mapping. *node* must be a
  ## *yMapping*.
  assert node.kind == yMapping
  for key, value in node.fields: yield (key, value)

iterator mpairs*(node: var YamlNode):
    tuple[key: YamlNode, value: var YamlNode] =
  ## Iterates over all key-value pairs of a mapping. *node* must be a
  ## *yMapping*. Values can be modified.
  doAssert node.kind == yMapping
  for key, value in node.fields.mpairs: yield (key, value)

proc loadFlattened*[K](input: Stream | string, target: var K)
    {.raises: [YamlConstructionError, YamlSerializationError, IOError, OSError,
               YamlParserError].} =
  ## Replaces all aliases with the referenced nodes in the input, then loads
  ## the resulting YAML into K. Can be used when anchors & aliases are used like
  ## variables in the input, to avoid having to define `ref` types for the
  ## anchored data.
  var node: YamlNode
  load(input, node)
  var stream = represent(node, tsNone, asNone)
  try:
    var e = stream.next()
    yAssert(e.kind == yamlStartStream)
    construct(stream, target)
    e = stream.next()
    yAssert(e.kind == yamlEndStream)
  except YamlStreamError:
    let e = (ref YamlStreamError)(getCurrentException())
    if e.parent of IOError: raise (ref IOError)(e.parent)
    if e.parent of OSError: raise (ref OSError)(e.parent)
    elif e.parent of YamlParserError: raise (ref YamlParserError)(e.parent)
    else: internalError("Unexpected exception: " & $e.parent.name)