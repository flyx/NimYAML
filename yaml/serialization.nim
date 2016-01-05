import "../yaml"
import macros, strutils, streams, tables, json, hashes, re
export yaml, streams, tables, json

type
    YamlTagStyle* = enum
        ytsNone,
        ytsRootOnly,
        ytsAll

proc initSerializationTagLibrary(): YamlTagLibrary =
    result = initTagLibrary()
    result.tags["!"] = yTagExclamationMark
    result.tags["?"] = yTagQuestionMark
    result.tags["tag:yaml.org,2002:str"]       = yTagString
    result.tags["tag:yaml.org,2002:null"]      = yTagNull
    result.tags["tag:yaml.org,2002:bool"]      = yTagBoolean
    result.tags["tag:yaml.org,2002:int"]       = yTagInteger
    result.tags["tag:yaml.org,2002:float"]     = yTagFloat
    result.tags["tag:yaml.org,2002:timestamp"] = yTagTimestamp
    result.tags["tag:yaml.org,2002:value"]     = yTagValue
    result.tags["tag:yaml.org,2002:binary"]    = yTagBinary

var
    serializationTagLibrary* = initSerializationTagLibrary() ## \
        ## contains all local tags that are used for type serialization. Does
        ## not contain any of the specific default tags for sequences or maps,
        ## as those are not suited for Nim's static type system.
        ##
        ## Should not be modified manually. Will be extended by
        ## `make_serializable <#make_serializable,stmt,stmt`_.


static:
    iterator objectFields(n: NimNode): tuple[name: NimNode, t: NimNode] =
        assert n.kind in [nnkRecList, nnkTupleTy]
        for identDefs in n.children:
            let numFields = identDefs.len - 2
            for i in 0..numFields - 1:
                yield (name: identDefs[i], t: identDefs[^2])
    
    var existingTuples = newSeq[NimNode]()

template presentTag(t: typedesc, tagStyle: YamlTagStyle): TagId =
     if tagStyle == ytsNone: yTagQuestionMark else: yamlTag(t)

proc lazyLoadTag*(uri: string): TagId {.inline.} =
    try:
        result = serializationTagLibrary.tags[uri]
    except KeyError:
        result = serializationTagLibrary.registerUri(uri)

macro make_serializable*(types: stmt): stmt =
    assert types.kind == nnkTypeSection
    result = newStmtList(types)
    for typedef in types.children:
        assert typedef.kind == nnkTypeDef
        let
            tName = $typedef[0].symbol
            tIdent = newIdentNode(tName)
        var
            tUri: NimNode
            recList: NimNode
        assert typedef[1].kind == nnkEmpty
        let objectTy = typedef[2]
        case objectTy.kind
        of nnkObjectTy:
            assert objectTy[0].kind == nnkEmpty
            assert objectTy[1].kind == nnkEmpty
            tUri = newStrLitNode("!nim:" & tName)
            recList = objectTy[2]
        of nnkTupleTy:
            if objectTy in existingTuples:
                continue
            existingTuples.add(objectTy)
            
            recList = objectTy
            tUri = newStmtList()
            var
                first = true
                curStrLit = "!nim:tuple("
                curInfix = tUri
            for field in objectFields(recList):
                if first:
                    first = false
                else:
                    curStrLit &= ","
                curStrLit &= $field.name & "="
                var tmp = newNimNode(nnkInfix).add(newIdentNode("&"),
                        newStrLitNode(curStrLit))
                curInfix.add(tmp)
                curInfix = tmp
                tmp = newNimNode(nnkInfix).add(newIdentNode("&"),
                        newCall("safeTagUri", newCall("yamlTag",
                            newCall("type", field.t))))
                curInfix.add(tmp)
                curInfix = tmp
                curStrLit = ""
            curInfix.add(newStrLitNode(curStrLit & ")"))
            tUri = tUri[0]
        else:
            assert false
                
        # yamlTag()
        
        var yamlTagProc = newProc(newIdentNode("yamlTag"), [
                newIdentNode("TagId"),
                newIdentDefs(newIdentNode("T"), newNimNode(nnkBracketExpr).add(
                             newIdentNode("typedesc"), tIdent))])
        var impl = newStmtList(newCall("lazyLoadTag", tUri))
        yamlTagProc[6] = impl
        result.add(yamlTagProc)
        
        # construct()
        
        var constructProc = newProc(newIdentNode("construct"), [
                newEmptyNode(),
                newIdentDefs(newIdentNode("s"), newIdentNode("YamlStream")),
                newIdentDefs(newIdentNode("result"),
                             newNimNode(nnkVarTy).add(tIdent))])
        impl = quote do:
            var event = s()
            if finished(s) or event.kind != yamlStartMap:
                raise newException(ValueError, "Construction error!")
            if event.mapTag != yTagQuestionMark and
                    event.mapTag != yamlTag(type(`tIdent`)):
                raise newException(ValueError, "Wrong tag for " & `tName`)
            event = s()
            if finished(s):
                raise newException(ValueError, "Construction error!")
            while event.kind != yamlEndMap:
                if event.kind == yamlError: echo event.description
                assert event.kind == yamlScalar
                assert event.scalarTag in [yTagQuestionMark, yTagString]
                case hash(event.scalarContent)
                else:
                    raise newException(ValueError, "Unknown key for " &
                                       `tName` & ": " & event.scalarContent)
                event = s()
                if finished(s):
                    raise newException(ValueError, "Construction error!")
        var keyCase = impl[5][1][3]
        assert keyCase.kind == nnkCaseStmt
        for field in objectFields(recList):
            let nameHash = hash($field.name.ident)
            keyCase.insert(1, newNimNode(nnkOfBranch).add(
                    newIntLitNode(nameHash)).add(newStmtList(
                        newCall("construct", [newIdentNode("s"), newDotExpr(
                        newIdentNode("result"), field.name)])
                    ))
            )
            
        constructProc[6] = impl
        result.add(constructProc)
        
        # serialize()
        
        var serializeProc = newProc(newIdentNode("serialize"), [
                newIdentNode("YamlStream"),
                newIdentDefs(newIdentNode("value"), tIdent),
                newIdentDefs(newIdentNode("tagStyle"),
                             newIdentNode("YamlTagStyle"),
                             newIdentNode("ytsNone"))])
        var iterBody = newStmtList(
            newLetStmt(newIdentNode("childTagStyle"), newNimNode(nnkIfExpr).add(
                newNimNode(nnkElifExpr).add(
                    newNimNode(nnkInfix).add(newIdentNode("=="),
                        newIdentNode("tagStyle"), newIdentNode("ytsRootOnly")),
                    newIdentNode("ytsNone")
                ), newNimNode(nnkElseExpr).add(newIdentNode("tagStyle")))),
            newNimNode(nnkYieldStmt).add(
                newNimNode(nnkObjConstr).add(newIdentNode("YamlStreamEvent"),
                    newNimNode(nnkExprColonExpr).add(newIdentNode("kind"),
                        newIdentNode("yamlStartMap")),
                    newNimNode(nnkExprColonExpr).add(newIdentNode("mapTag"),
                        newNimNode(nnkIfExpr).add(newNimNode(nnkElifExpr).add(
                            newNimNode(nnkInfix).add(newIdentNode("=="),
                                newIdentNode("tagStyle"),
                                newIdentNode("ytsNone")),
                            newIdentNode("yTagQuestionMark")
                        ), newNimNode(nnkElseExpr).add(
                            newCall("yamlTag", newCall("type", tIdent))
                        ))),
                    newNimNode(nnkExprColonExpr).add(newIdentNode("mapAnchor"),
                        newIdentNode("yAnchorNone"))    
                )
        ), newNimNode(nnkYieldStmt).add(newNimNode(nnkObjConstr).add(
            newIdentNode("YamlStreamEvent"), newNimNode(nnkExprColonExpr).add(
                newIdentNode("kind"), newIdentNode("yamlEndMap")
            )
        )))
        
        var i = 2
        for field in objectFields(recList):
            let
                fieldIterIdent = newIdentNode($field.name & "Events")
                fieldNameString = newStrLitNode($field.name)
            iterbody.insert(i, quote do:
                yield YamlStreamEvent(kind: yamlScalar,
                                      scalarTag: presentTag(string,
                                                            childTagStyle),
                                      scalarAnchor: yAnchorNone,
                                      scalarContent: `fieldNameString`)
            )
            iterbody.insert(i + 1, newVarStmt(fieldIterIdent,
                    newCall("serialize", newDotExpr(newIdentNode("value"),
                    field.name), newIdentNode("childTagStyle"))))
            iterbody.insert(i + 2, quote do:
                for event in `fieldIterIdent`():
                    yield event
            )
            i += 3
        impl = newStmtList(newAssignment(newIdentNode("result"), newProc(
                newEmptyNode(), [newIdentNode("YamlStreamEvent")], iterBody,
                nnkIteratorDef)))
        serializeProc[6] = impl
        result.add(serializeProc)
    echo result.repr

proc prepend*(event: YamlStreamEvent, s: YamlStream): YamlStream =
    result = iterator(): YamlStreamEvent =
        yield event
        for e in s():
            yield e

proc yamlTag*(T: typedesc[string]): TagId {.inline.} = yTagString

proc safeTagUri*(id: TagId): string =
    let uri = serializationTagLibrary.uri(id)
    if uri.len > 0 and uri[0] == '!':
        return uri[1..uri.len - 1]
    else:
        return uri

proc construct*(s: YamlStream, result: var string) =
    let item = s()
    if finished(s) or item.kind != yamlScalar:
        raise newException(ValueError, "Construction error!" & $item.description)
    if item.scalarTag notin [yTagQuestionMark, yTagExclamationMark, yTagString]:
        raise newException(ValueError, "Wrong tag for string.")
    result = item.scalarContent

proc serialize*(value: string,
                tagStyle: YamlTagStyle = ytsNone): YamlStream =
    result = iterator(): YamlStreamEvent =
        yield YamlStreamEvent(kind: yamlScalar,
                              scalarTag: presentTag(string, tagStyle),
                              scalarAnchor: yAnchorNone, scalarContent: value)

proc yamlTag*(T: typedesc[int]): TagId {.inline.} = yTagInteger

proc construct*(s: YamlStream, result: var int) =
    let item = s()
    if finished(s) or item.kind != yamlScalar:
        raise newException(ValueError, "Construction error!")
    if item.scalarTag != yTagInteger and not (
       item.scalarTag == yTagQuestionMark and item.scalarType == yTypeInteger):
        raise newException(ValueError, "Wrong scalar type for int.")
    result = parseInt(item.scalarContent)

proc serialize*(value: int,
                tagStyle: YamlTagStyle = ytsNone): YamlStream =
    result = iterator(): YamlStreamEvent =
        yield YamlStreamEvent(kind: yamlScalar,
                              scalarTag: presentTag(int, tagStyle),
                              scalarAnchor: yAnchorNone, scalarContent: $value)

proc yamlTag*(T: typedesc[int64]): TagId {.inline.} = yTagInteger

proc contruct*(s: YamlStream, result: var int64) =
    let item = s()
    if finished(s) or item.kind != yamlScalar:
        raise newException(ValueError, "Construction error!")
    if item.scalarTag != yTagInteger and not (
       item.scalarTag == yTagQuestionMark and item.scalarType == yTypeInteger):
        raise newException(ValueError, "Wrong scalar type for int64.")
    result = parseBiggestInt(item.scalarContent)

proc serialize*(value: int64,
                tagStyle: YamlTagStyle = ytsNone): YamlStream =
    result = iterator(): YamlStreamEvent =
        yield YamlStreamEvent(kind: yamlScalar,
                              scalarTag: presentTag(int64, tagStyle),
                              scalarAnchor: yAnchorNone, scalarContent: $value)

proc yamlTag*(T: typedesc[float]): TagId {.inline.} = yTagFloat

proc construct*(s: YamlStream, result: var float) =
    let item = s()
    if finished(s) or item.kind != yamlScalar:
        raise newException(ValueError, "Construction error!")
    if item.scalarTag != yTagFloat and not (
       item.scalarTag == yTagQuestionMark and item.scalarType == yTypeFloat):
        raise newException(ValueError, "Wrong scalar type for float.")
    case item.scalarType
    of yTypeFloat:
        result = parseFloat(item.scalarContent)
    of yTypeFloatInf:
        if item.scalarContent[0] == '-':
            result = NegInf
        else:
            result = Inf
    of yTypeFloatNaN:
        result = NaN
    else:
        raise newException(ValueError, "Wrong scalar type for float.")

proc serialize*(value: float,
                tagStyle: YamlTagStyle = ytsNone): YamlStream =
    result = iterator(): YamlStreamEvent =
        var asString = case value
            of Inf: ".inf"
            of NegInf: "-.inf"
            of NaN: ".nan"
            else: $value
    
        yield YamlStreamEvent(kind: yamlScalar,
                scalarTag: presentTag(float, tagStyle),
                scalarAnchor: yAnchorNone, scalarContent: asString)

proc yamlTag*(T: typedesc[bool]): TagId {.inline.} = yTagBoolean

proc construct*(s: YamlStream, result: var bool) =
    let item = s()
    if finished(s) or item.kind != yamlScalar:
        raise newException(ValueError, "Construction error!")
    case item.scalarTag
    of yTagQuestionMark:
        case item.scalarType
        of yTypeBoolTrue:
            result = true
        of yTypeBoolFalse:
            result = false
        else:
            raise newException(ValueError, "Wrong scalar type for bool.")
    of yTagBoolean:
        if item.scalarContent.match(
                re"y|Y|yes|Yes|YES|true|True|TRUE|on|On|ON"):
            result = true
        elif item.scalarContent.match(
                re"n|N|no|No|NO|false|False|FALSE|off|Off|OFF"):
            result = false
        else:
            raise newException(ValueError, "Wrong content for bool.")
    else:
        raise newException(ValueError, "Wrong scalar type for bool")
        
proc serialize*(value: bool,
                tagStyle: YamlTagStyle = ytsNone): YamlStream =
    result = iterator(): YamlStreamEvent =
        yield YamlStreamEvent(kind: yamlScalar,
                              scalarTag: presentTag(bool, tagStyle),
                              scalarAnchor: yAnchorNone, scalarContent:
                              if value: "y" else: "n")

proc yamlTag*[I](T: typedesc[seq[I]]): TagId {.inline.} =
    let uri = "!nim:seq(" & safeTagUri(yamlTag(I)) & ")"
    result = lazyLoadTag(uri)

proc construct*[T](s: YamlStream, result: var seq[T]) =
    var event = s()
    if finished(s) or event.kind != yamlStartSequence:
        raise newException(ValueError, "Construction error!1")
    if event.seqTag != yTagQuestionMark and
            event.seqTag != yamlTag(seq[T]):
        raise newException(ValueError, "Wrong sequence type for seq[T]")
    result = newSeq[T]()
    event = s()
    if finished(s):
        raise newException(ValueError, "Construction error!2")
    while event.kind != yamlEndSequence:
        var
            item: T
            events = prepend(event, s)
        construct(events, item)
        result.add(item)
        event = s()
        if finished(s):
            raise newException(ValueError, "Construction error!3")

proc serialize*[T](value: seq[T],
                   tagStyle: YamlTagStyle = ytsNone): YamlStream =
    result = iterator(): YamlStreamEvent =
        let childTagStyle = if tagStyle == ytsRootOnly: ytsNone else: tagStyle
        yield YamlStreamEvent(kind: yamlStartSequence,
                              seqTag: presentTag(seq[T], tagStyle),
                              seqAnchor: yAnchorNone)
        for item in value:
            var events = serialize(item, childTagStyle)
            for event in events():
                yield event
        yield YamlStreamEvent(kind: yamlEndSequence)

proc yamlTag*[K, V](T: typedesc[Table[K, V]]): TagId {.inline.} =
    let
        keyUri     = serializationTagLibrary.uri(yamlTag(K))
        valueUri   = serializationTagLibrary.uri(yamlTag(V))
        keyIdent   = if keyUri[0] == '!': keyUri[1..keyUri.len - 1] else: keyUri
        valueIdent = if valueUri[0] == '!':
                valueUri[1..valueUri.len - 1] else: valueUri
        uri = "!nim:Table(" & keyUri & "," & valueUri & ")"
    result = lazyLoadTag(uri)

proc construct*[K, V](s: YamlStream, result: var Table[K, V]) =
    var event = s()
    if finished(s) or event.kind != yamlStartMap:
        raise newException(ValueError, "Construction error!")
    if event.mapTag != yTagQuestionMark and
            event.mapTag != yamlTag(Table[K, V]):
        raise newException(ValueError, "Wrong map type for Table[K, V]")
    result = initTable[K, V]()
    event = s()
    if finished(s):
        raise newException(ValueError, "Construction error!")
    while event.kind != yamlEndMap:
        var
            key: K
            value: V
            events = prepend(event, s)
        construct(events, key)
        construct(s, value)
        result[key] = value
        event = s()
        if finished(s):
            raise newException(ValueError, "Construction error!")

proc serialize*[K, V](value: Table[K, V],
                      tagStyle: YamlTagStyle = ytsNone): YamlStream =
    result = iterator(): YamlStreamEvent =
        let childTagStyle = if tagStyle == ytsRootOnly: ytsNone else: tagStyle
        yield YamlStreamEvent(kind: yamlStartMap,
                              mapTag: presentTag(Table[K, V], tagStyle),
                              mapAnchor: yAnchorNone)
        for key, value in value.pairs:
            var events = serialize(key, childTagStyle)
            for event in events():
                yield event
            events = serialize(value, childTagStyle)
            for event in events():
                yield event
        yield YamlStreamEvent(kind: yamlEndMap)

proc load*[K](input: Stream, target: var K) =
    var
        parser = newParser(serializationTagLibrary)
        events = parser.parse(input)
    assert events().kind == yamlStartDocument
    construct(events, target)
    assert events().kind == yamlEndDocument

proc dump*[K](value: K, target: Stream,
              style: YamlPresentationStyle = ypsDefault,
              tagStyle: YamlTagStyle = ytsRootOnly, indentationStep: int = 2) =
    var serialized = serialize(value,
            if style == ypsCanonical: ytsAll else: tagStyle)
    var events = iterator(): YamlStreamEvent =
        yield YamlStreamEvent(kind: yamlStartDocument)
        for event in serialized():
            yield event
        yield YamlStreamEvent(kind: yamlEndDocument)
    present(events, target, serializationTagLibrary, style, indentationStep)