proc newYamlNode*(content: string, tag: string = "?"): YamlNode =
    new(result)
    result.kind = yScalar
    result.content = content
    result.tag = tag

proc newYamlNode*(children: openarray[YamlNode], tag: string = "?"):
        YamlNode =
    new(result)
    result.kind = ySequence
    result.children = @children
    result.tag = tag

proc newYamlNode*(pairs: openarray[tuple[key, value: YamlNode]],
                  tag: string = "?"): YamlNode =
    new(result)
    result.kind = yMapping
    result.pairs = @pairs
    result.tag = tag

proc initYamlDoc*(root: YamlNode): YamlDocument =
    result.root = root

proc composeNode(s: var YamlStream, tagLib: TagLibrary,
                 c: ConstructionContext):
        YamlNode {.raises: [YamlStreamError, YamlConstructionError].} =
    let start = s.next()
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
                assert(not c.refs.hasKey(start.mapAnchor))
                c.refs[start.mapAnchor] = cast[pointer](result)
        of yamlStartSequence:
            result.tag = tagLib.uri(start.seqTag)
            result.kind = ySequence
            result.children = newSeq[YamlNode]()
            while s.peek().kind != yamlEndSequence:
                result.children.add(composeNode(s, tagLib, c))
            if start.seqAnchor != yAnchorNone:
                assert(not c.refs.hasKey(start.seqAnchor))
                c.refs[start.seqAnchor] = cast[pointer](result)
            discard s.next()
        of yamlScalar:
            result.tag = tagLib.uri(start.scalarTag)
            result.kind = yScalar
            result.content = start.scalarContent
            if start.scalarAnchor != yAnchorNone:
                assert(not c.refs.hasKey(start.scalarAnchor))
                c.refs[start.scalarAnchor] = cast[pointer](result)
        of yamlAlias:
            result = cast[YamlNode](c.refs[start.aliasTarget])
        else: assert false, "Malformed YamlStream"
    except KeyError:
        raise newException(YamlConstructionError,
                           "Wrong tag library: TagId missing")

proc compose*(s: var YamlStream, tagLib: TagLibrary): YamlDocument
        {.raises: [YamlStreamError, YamlConstructionError].} =
    var context = newConstructionContext()
    assert s.next().kind == yamlStartDocument
    result.root = composeNode(s, tagLib, context)
    assert s.next().kind == yamlEndDocument

proc loadDOM*(s: Stream): YamlDocument
        {.raises: [IOError, YamlParserError, YamlConstructionError].} =
    var
        tagLib = initExtendedTagLibrary()
        parser = newYamlParser(tagLib)
        events = parser.parse(s)
    try:
        result = compose(events, tagLib)
    except YamlStreamError:
        let e = getCurrentException()
        if e.parent of YamlParserError:
            raise (ref YamlParserError)(e.parent)
        elif e.parent of IOError:
            raise (ref IOError)(e.parent)
        else: assert false, "Never happens: " & e.parent.repr

proc serializeNode(n: YamlNode, c: SerializationContext, a: AnchorStyle,
                   tagLib: TagLibrary): RawYamlStream {.raises: [].}=
    let p = cast[pointer](n)
    if a != asNone and c.refs.hasKey(p):
            try:
                if c.refs[p] == yAnchorNone:
                    c.refs[p] = c.nextAnchorId
                    c.nextAnchorId = AnchorId(int(c.nextAnchorId) + 1)
            except KeyError: assert false, "Can never happen"
            result = iterator(): YamlStreamEvent {.raises: [].} =
                var event: YamlStreamEvent
                try: event = aliasEvent(c.refs[p])
                except KeyError: assert false, "Can never happen"
                yield event
            return
    var
        tagId: TagId
        anchor: AnchorId
    try:
        if a == asAlways:
            c.refs[p] = c.nextAnchorId
            c.nextAnchorId = AnchorId(int(c.nextAnchorId) + 1)
        else: c.refs[p] = yAnchorNone
        tagId = if tagLib.tags.hasKey(n.tag): tagLib.tags[n.tag] else:
                tagLib.registerUri(n.tag)
        case a
        of asNone: anchor = yAnchorNone
        of asTidy: anchor = cast[AnchorId](n)
        of asAlways: anchor = c.refs[p]
    except KeyError: assert false, "Can never happen"
    result = iterator(): YamlStreamEvent =
        case n.kind
        of yScalar:
            yield scalarEvent(n.content, tagId, anchor)
        of ySequence:
            yield startSeqEvent(tagId, anchor)
            for item in n.children:
                var events = serializeNode(item, c, a, tagLib)
                while true:
                    let event = events()
                    if finished(events): break
                    yield event
            yield endSeqEvent()
        of yMapping:
            yield startMapEvent(tagId, anchor)
            for i in n.pairs:
                var events = serializeNode(i.key, c, a, tagLib)
                while true:
                    let event = events()
                    if finished(events): break
                    yield event
                events = serializeNode(i.value, c, a, tagLib)
                while true:
                    let event = events()
                    if finished(events): break
                    yield event
            yield endMapEvent()

template processAnchoredEvent(target: expr, c: SerializationContext): stmt =
    try:
        let anchorId = c.refs[cast[pointer](target)]
        if anchorId != yAnchorNone:
            target = anchorId
        else: target = yAnchorNone
    except KeyError: assert false, "Can never happen"
    yield event

proc serialize*(doc: YamlDocument, tagLib: TagLibrary, a: AnchorStyle = asTidy):
        YamlStream {.raises: [].} =
    var
        context = newSerializationContext(a)
        events = serializeNode(doc.root, context, a, tagLib)
    if a == asTidy:
        var backend = iterator(): YamlStreamEvent {.raises: [].} =
            var output = newSeq[YamlStreamEvent]()
            while true:
                let event = events()
                if finished(events): break
                output.add(event)
            yield startDocEvent()
            for event in output.mitems():
                case event.kind
                of yamlScalar:
                    processAnchoredEvent(event.scalarAnchor, context)
                of yamlStartMap: processAnchoredEvent(event.mapAnchor, context)
                of yamlStartSequence:
                    processAnchoredEvent(event.seqAnchor, context)
                else: yield event
            yield endDocEvent()
        result = initYamlStream(backend)
    else:
        var backend = iterator(): YamlStreamEvent {.raises: [].} =
            yield startDocEvent()
            while true:
                let event = events()
                if finished(events): break
                yield event
            yield endDocEvent()
        result = initYamlStream(backend)

proc dumpDOM*(doc: YamlDocument, target: Stream,
              anchorStyle: AnchorStyle = asTidy,
              options: PresentationOptions = defaultPresentationOptions)
            {.raises: [YamlPresenterJsonError, YamlPresenterOutputError].} =
    ## Dump a YamlDocument as YAML character stream.
    var
        tagLib = initExtendedTagLibrary()
        events = serialize(doc, tagLib,
                           if options.style == psJson: asNone else: anchorStyle)
    try:
        present(events, target, tagLib, options)
    except YamlStreamError:
        # serializing object does not raise any errors, so we can ignore this
        assert false, "Can never happen"