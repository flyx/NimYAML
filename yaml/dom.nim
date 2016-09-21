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
## The main interface of this API are ``loadDOM`` and ``dumpDOM``. The other
## exposed procs are low-level and useful if you want to load or generate parts
## of a ``YamlStream``.

import tables, streams
import common, stream, taglib, serialization, ../private/internal, parser,
       presenter

type
  YamlNodeKind* = enum
    yScalar, yMapping, ySequence

  YamlNode* = ref YamlNodeObj not nil
    ## Represents a node in a ``YamlDocument``.

  YamlNodeObj* = object
    tag*: string
    case kind*: YamlNodeKind
    of yScalar: content*: string
    of ySequence: children*: seq[YamlNode]
    of yMapping: pairs*: seq[tuple[key, value: YamlNode]]

  YamlDocument* = object
    ## Represents a YAML document.
    root*: YamlNode

proc newYamlNode*(content: string, tag: string = "?"): YamlNode =
  YamlNode(kind: yScalar, content: content, tag: tag)

proc newYamlNode*(children: openarray[YamlNode], tag: string = "?"):
    YamlNode =
  YamlNode(kind: ySequence, children: @children, tag: tag)

proc newYamlNode*(pairs: openarray[tuple[key, value: YamlNode]],
                  tag: string = "?"): YamlNode =
  YamlNode(kind: yMapping, pairs: @pairs, tag: tag)

proc initYamlDoc*(root: YamlNode): YamlDocument = result.root = root

proc composeNode(s: var YamlStream, tagLib: TagLibrary,
                 c: ConstructionContext):
    YamlNode {.raises: [YamlStreamError, YamlConstructionError].} =
  var start: YamlStreamEvent
  shallowCopy(start, s.next())
  new(result)
  try:
    case start.kind
    of yamlStartMap:
      result.tag = tagLib.uri(start.mapTag)
      result.kind = yMapping
      result.pairs = newSeq[tuple[key, value: YamlNode]]()
      while s.peek().kind != yamlEndMap:
        let
          key = composeNode(s, tagLib, c)
          value = composeNode(s, tagLib, c)
        result.pairs.add((key: key, value: value))
      discard s.next()
      if start.mapAnchor != yAnchorNone:
        yAssert(not c.refs.hasKey(start.mapAnchor))
        c.refs[start.mapAnchor] = cast[pointer](result)
    of yamlStartSeq:
      result.tag = tagLib.uri(start.seqTag)
      result.kind = ySequence
      result.children = newSeq[YamlNode]()
      while s.peek().kind != yamlEndSeq:
        result.children.add(composeNode(s, tagLib, c))
      if start.seqAnchor != yAnchorNone:
        yAssert(not c.refs.hasKey(start.seqAnchor))
        c.refs[start.seqAnchor] = cast[pointer](result)
      discard s.next()
    of yamlScalar:
      result.tag = tagLib.uri(start.scalarTag)
      result.kind = yScalar
      shallowCopy(result.content, start.scalarContent)
      if start.scalarAnchor != yAnchorNone:
        yAssert(not c.refs.hasKey(start.scalarAnchor))
        c.refs[start.scalarAnchor] = cast[pointer](result)
    of yamlAlias:
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

proc loadDOM*(s: Stream | string): YamlDocument
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
  let p = cast[pointer](n)
  if a != asNone and c.refs.hasKey(p):
    if c.refs.getOrDefault(p) == yAnchorNone:
      c.refs[p] = c.nextAnchorId
      c.nextAnchorId = AnchorId(int(c.nextAnchorId) + 1)
    c.put(aliasEvent(c.refs.getOrDefault(p)))
    return
  var
    tagId: TagId
    anchor: AnchorId
  if a == asAlways:
    c.refs[p] = c.nextAnchorId
    c.nextAnchorId = AnchorId(int(c.nextAnchorId) + 1)
  else: c.refs[p] = yAnchorNone
  tagId = if tagLib.tags.hasKey(n.tag): tagLib.tags.getOrDefault(n.tag) else:
          tagLib.registerUri(n.tag)
  case a
  of asNone: anchor = yAnchorNone
  of asTidy: anchor = cast[AnchorId](n)
  of asAlways: anchor = c.refs.getOrDefault(p)

  case n.kind
  of yScalar: c.put(scalarEvent(n.content, tagId, anchor))
  of ySequence:
    c.put(startSeqEvent(tagId, anchor))
    for item in n.children:
      serializeNode(item, c, a, tagLib)
    c.put(endSeqEvent())
  of yMapping:
    c.put(startMapEvent(tagId, anchor))
    for i in n.pairs:
      serializeNode(i.key, c, a, tagLib)
      serializeNode(i.value, c, a, tagLib)
    c.put(endMapEvent())

template processAnchoredEvent(target: untyped, c: SerializationContext): typed =
  let anchorId = c.refs.getOrDefault(cast[pointer](target))
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

proc dumpDOM*(doc: YamlDocument, target: Stream,
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
