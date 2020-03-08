#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ===============
## Module yaml.dom
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

import tables, streams, hashes, sets, strutils
import stream, taglib, serialization, private/internal, parser,
       presenter
       
when defined(nimNoNil):
    {.experimental: "notnil".}
type
  YamlNodeKind* = enum
    yScalar, yMapping, ySequence

  YamlNode* = ref YamlNodeObj not nil
    ## Represents a node in a ``YamlDocument``.

  YamlNodeObj* = object
    tag*: string
    case kind*: YamlNodeKind
    of yScalar: content*: string
    of ySequence: elems*: seq[YamlNode]
    of yMapping: fields*: TableRef[YamlNode, YamlNode]
      # compiler does not like Table[YamlNode, YamlNode]

  YamlDocument* = object
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
  result = "!<" & n.tag & "> "
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

proc newYamlNode*(content: string, tag: string = "?"): YamlNode =
  YamlNode(kind: yScalar, content: content, tag: tag)

proc newYamlNode*(elems: openarray[YamlNode], tag: string = "?"):
    YamlNode =
  YamlNode(kind: ySequence, elems: @elems, tag: tag)

proc newYamlNode*(fields: openarray[(YamlNode, YamlNode)],
                  tag: string = "?"): YamlNode =
  YamlNode(kind: yMapping, fields: newTable(fields), tag: tag)

proc initYamlDoc*(root: YamlNode): YamlDocument = result.root = root

proc composeNode(s: var YamlStream, tagLib: TagLibrary,
                 c: ConstructionContext):
    YamlNode {.raises: [YamlStreamError, YamlConstructionError].} =
  template addAnchor(c: ConstructionContext, target: AnchorId) =
    if target != yAnchorNone:
      when defined(JS):
        {.emit: [c, """.refs.set(""", target, ", ", result, ");"].}
      else:
        yAssert(not c.refs.hasKey(target))
        c.refs[target] = cast[pointer](result)

  var start: YamlStreamEvent
  shallowCopy(start, s.next())
  new(result)
  try:
    case start.kind
    of yamlStartMap:
      result = YamlNode(tag: tagLib.uri(start.mapTag),
                        kind: yMapping,
                        fields: newTable[YamlNode, YamlNode]())
      while s.peek().kind != yamlEndMap:
        let
          key = composeNode(s, tagLib, c)
          value = composeNode(s, tagLib, c)
        if result.fields.hasKeyOrPut(key, value):
          raise newException(YamlConstructionError,
              "Duplicate key: " & $key)
      discard s.next()
      addAnchor(c, start.mapAnchor)
    of yamlStartSeq:
      result = YamlNode(tag: tagLib.uri(start.seqTag),
                        kind: ySequence,
                        elems: newSeq[YamlNode]())
      while s.peek().kind != yamlEndSeq:
        result.elems.add(composeNode(s, tagLib, c))
      addAnchor(c, start.seqAnchor)
      discard s.next()
    of yamlScalar:
      result = YamlNode(tag: tagLib.uri(start.scalarTag),
                        kind: yScalar)
      shallowCopy(result.content, start.scalarContent)
      addAnchor(c, start.scalarAnchor)
    of yamlAlias:
      when defined(JS):
        {.emit: [result, " = ", c, ".refs.get(", start.aliasTarget, ");"].}
      else:
        result = cast[YamlNode](c.refs[start.aliasTarget])
    else: internalError("Malformed YamlStream")
  except KeyError:
    raise newException(YamlConstructionError,
                       "Wrong tag library: TagId missing")

proc compose*(s: var YamlStream, tagLib: TagLibrary): YamlDocument
    {.raises: [YamlStreamError, YamlConstructionError].} =
  var context = newConstructionContext()
  var n: YamlStreamEvent
  shallowCopy(n, s.next())
  yAssert n.kind == yamlStartDoc
  result.root = composeNode(s, tagLib, context)
  n = s.next()
  yAssert n.kind == yamlEndDoc

proc loadDom*(s: Stream | string): YamlDocument
    {.raises: [IOError, YamlParserError, YamlConstructionError].} =
  var
    tagLib = initExtendedTagLibrary()
    parser = newYamlParser(tagLib)
    events = parser.parse(s)
  try: result = compose(events, tagLib)
  except YamlStreamError:
    let e = getCurrentException()
    if e.parent of YamlParserError:
      raise (ref YamlParserError)(e.parent)
    elif e.parent of IOError:
      raise (ref IOError)(e.parent)
    else: internalError("Unexpected exception: " & e.parent.repr)

proc serializeNode(n: YamlNode, c: SerializationContext, a: AnchorStyle,
                   tagLib: TagLibrary) {.raises: [].}=
  var val = yAnchorNone
  when defined(JS):
    {.emit: ["""
      if (""", a, " != ", asNone, " && ", c, ".refs.has(", n, """) {
        """, val, " = ", c, ".refs.get(", n, """);
        if (""", c, ".refs.get(", n, ") == ", yAnchorNone, ") {"].}
    val = c.nextAnchorId
    {.emit: [c, """.refs.set(""", n, """, """, val, """);"""].}
    c.nextAnchorId = AnchorId(int(c.nextAnchorId) + 1)
    {.emit: "}".}
    c.put(aliasEvent(val))
    return
    {.emit: "}".}
  else:
    let p = cast[pointer](n)
    if a != asNone and c.refs.hasKey(p):
      val = c.refs.getOrDefault(p)
      if val == yAnchorNone:
        val = c.nextAnchorId
        c.refs[p] = val
        c.nextAnchorId = AnchorId(int(c.nextAnchorId) + 1)
      c.put(aliasEvent(val))
      return
  var
    tagId: TagId
    anchor: AnchorId
  if a == asAlways:
    val = c.nextAnchorId
    when defined(JS):
      {.emit: [c, ".refs.set(", n, ", ", val, ");"].}
    else:
      c.refs[p] = c.nextAnchorId
    c.nextAnchorId = AnchorId(int(val) + 1)
  else:
    when defined(JS):
      {.emit: [c, ".refs.set(", n, ", ", yAnchorNone, ");"].}
    else:
      c.refs[p] = yAnchorNone
  tagId = if tagLib.tags.hasKey(n.tag): tagLib.tags.getOrDefault(n.tag) else:
          tagLib.registerUri(n.tag)
  case a
  of asNone: anchor = yAnchorNone
  of asTidy: anchor = cast[AnchorId](n)
  of asAlways: anchor = val

  case n.kind
  of yScalar: c.put(scalarEvent(n.content, tagId, anchor))
  of ySequence:
    c.put(startSeqEvent(tagId, anchor))
    for item in n.elems:
      serializeNode(item, c, a, tagLib)
    c.put(endSeqEvent())
  of yMapping:
    c.put(startMapEvent(tagId, anchor))
    for key, value in n.fields.pairs:
      serializeNode(key, c, a, tagLib)
      serializeNode(value, c, a, tagLib)
    c.put(endMapEvent())

template processAnchoredEvent(target: untyped, c: SerializationContext) =
  var anchorId: AnchorId
  when defined(JS):
    {.emit: [anchorId, " = ", c, ".refs.get(", target, ");"].}
  else:
    anchorId = c.refs.getOrDefault(cast[pointer](target))
  if anchorId != yAnchorNone: target = anchorId
  else: target = yAnchorNone

proc serialize*(doc: YamlDocument, tagLib: TagLibrary, a: AnchorStyle = asTidy):
    YamlStream {.raises: [].} =
  var
    bys = newBufferYamlStream()
    c = newSerializationContext(a, proc(e: YamlStreamEvent) {.raises: [].} =
      bys.put(e)
    )
  c.put(startDocEvent())
  serializeNode(doc.root, c, a, tagLib)
  c.put(endDocEvent())
  if a == asTidy:
    for event in bys.mitems():
      case event.kind
      of yamlScalar: processAnchoredEvent(event.scalarAnchor, c)
      of yamlStartMap: processAnchoredEvent(event.mapAnchor, c)
      of yamlStartSeq: processAnchoredEvent(event.seqAnchor, c)
      else: discard
  result = bys

proc dumpDom*(doc: YamlDocument, target: Stream,
              anchorStyle: AnchorStyle = asTidy,
              options: PresentationOptions = defaultPresentationOptions)
    {.raises: [YamlPresenterJsonError, YamlPresenterOutputError,
               YamlStreamError].} =
  ## Dump a YamlDocument as YAML character stream.
  var
    tagLib = initExtendedTagLibrary()
    events = serialize(doc, tagLib,
                       if options.style == psJson: asNone else: anchorStyle)
  present(events, target, tagLib, options)

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
  var keyNode = YamlNode(kind: yScalar, tag: "!", content: key)
  result = node.fields.getOrDefault(keyNode)
  if isNil(result):
    keyNode.tag = "?"
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