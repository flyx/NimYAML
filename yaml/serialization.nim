import "../yaml"
import macros, strutils, streams, tables, json, hashes
export yaml, streams, tables, json

static:
    iterator objectFields(n: NimNode): tuple[name: NimNode, t: NimNode] =
        assert n.kind == nnkRecList
        for identDefs in n.children:
            let numFields = identDefs.len - 2
            for i in 0..numFields - 1:
                yield (name: identDefs[i], t: identDefs[^2])

macro make_serializable*(types: stmt): stmt =
    assert types.kind == nnkTypeSection
    result = newStmtList(types)
    for typedef in types.children:
        assert typedef.kind == nnkTypeDef
        let
            tName = $typedef[0].symbol
            tIdent = newIdentNode(tName)
        assert typedef[1].kind == nnkEmpty
        let objectTy = typedef[2]
        assert objectTy.kind == nnkObjectTy
        assert objectTy[0].kind == nnkEmpty
        assert objectTy[1].kind == nnkEmpty
        let recList = objectTy[2]
        assert recList.kind == nnkRecList
        
        # construct()
        
        var constructProc = newProc(newIdentNode("construct"), [
                newEmptyNode(),
                newIdentDefs(newIdentNode("s"), newIdentNode("YamlStream")),
                newIdentDefs(newIdentNode("result"),
                             newNimNode(nnkVarTy).add(tIdent))])
        var impl = quote do:
            var event = s()
            if finished(s) or event.kind != yamlStartMap:
                raise newException(ValueError, "Construction error!" & $event.scalarContent)
            if event.mapTag != yTagQuestionMark:
                raise newException(ValueError, "Wrong tag for " & `tName`)
            event = s()
            if finished(s):
                raise newException(ValueError, "Construction error! b")
            while event.kind != yamlEndMap:
                assert event.kind == yamlScalar
                assert event.scalarTag == yTagQuestionMark
                case hash(event.scalarContent)
                else:
                    raise newException(ValueError, "Unknown key for " &
                                       `tName` & ": " & event.scalarContent)
                event = s()
                if finished(s):
                    raise newException(ValueError, "Construction error! c")
        var keyCase = impl[5][1][2]
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
                newIdentDefs(newIdentNode("verboseTags"), newIdentNode("bool"),
                             newIdentNode("false"))])
        var iterBody = quote do:
            yield YamlStreamEvent(kind: yamlStartMap,
                                  mapTag: yTagQuestionMark,
                                  mapAnchor: yAnchorNone)
            yield YamlStreamEvent(kind: yamlEndMap)
        
        var i = 1
        for field in objectFields(recList):
            let
                fieldIterIdent = newIdentNode($field.name & "Events")
                fieldNameString = newStrLitNode($field.name)
            iterbody.insert(i, quote do:
                yield YamlStreamEvent(kind: yamlScalar,
                                      scalarTag: yTagQuestionMark,
                                      scalarAnchor: yAnchorNone,
                                      scalarContent: `fieldNameString`)
            )
            iterbody.insert(i + 1, newVarStmt(fieldIterIdent,
                    newCall("serialize", newDotExpr(newIdentNode("value"),
                    field.name), newIdentNode("verboseTags"))))
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

proc prepend*(event: YamlStreamEvent, s: YamlStream): YamlStream =
    result = iterator(): YamlStreamEvent =
        yield event
        for e in s():
            yield e

proc wrapWithDocument*(s: YamlStream): YamlStream =
    result = iterator(): YamlStreamEvent =
        yield YamlStreamEvent(kind: yamlStartDocument)
        for event in s():
            yield event
        yield YamlStreamEvent(kind: yamlEndDocument)

proc construct*(s: YamlStream, result: var string) =
    let item = s()
    if finished(s) or item.kind != yamlScalar:
        raise newException(ValueError, "Construction error!")
    if item.scalarTag notin [yTagQuestionMark, yTagExclamationMark, yTagString]:
        raise newException(ValueError, "Wrong tag for string.")
    result = item.scalarContent

proc serialize*(value: string, verboseTags: bool = false): YamlStream =
    result = iterator(): YamlStreamEvent =
        yield YamlStreamEvent(kind: yamlScalar, scalarTag:
                if verboseTags: yTagString else: yTagQuestionMark,
                scalarAnchor: yAnchorNone, scalarContent: value)

proc construct*(s: YamlStream, result: var int) =
    let item = s()
    if finished(s) or item.kind != yamlScalar:
        raise newException(ValueError, "Construction error!")
    if item.scalarTag notin [yTagQuestionMark, yTagInteger] or
        item.scalarType != yTypeInteger:
        raise newException(ValueError, "Wrong scalar type for int.")
    result = parseInt(item.scalarContent)

proc serialize*(value: int, verboseTags: bool = false): YamlStream =
    result = iterator(): YamlStreamEvent =
        yield YamlStreamEvent(kind: yamlScalar, scalarTag:
                if verboseTags: yTagInteger else: yTagQuestionMark,
                scalarAnchor: yAnchorNone, scalarContent: $value)

proc contruct*(s: YamlStream, result: var int64) =
    let item = s()
    if finished(s) or item.kind != yamlScalar:
        raise newException(ValueError, "Construction error!")
    if item.scalarTag notin [yTagQuestionMark, yTagInteger] or
        item.scalarType != yTypeInteger:
        raise newException(ValueError, "Wrong scalar type for int64.")
    result = parseBiggestInt(item.scalarContent)

proc serialize*(value: int64, verboseTags: bool = false): YamlStream =
    result = iterator(): YamlStreamEvent =
        yield YamlStreamEvent(kind: yamlScalar, scalarTag:
                if verboseTags: yTagInteger else: yTagQuestionMark,
                scalarAnchor: yAnchorNone, scalarContent: $value)

proc construct*(s: YamlStream, result: var float) =
    let item = s()
    if finished(s) or item.kind != yamlScalar:
        raise newException(ValueError, "Construction error!")
    if item.scalarTag notin [yTagQuestionMark, yTagFloat]:
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

proc serialize*(value: float, verboseTags: bool = false): YamlStream =
    result = iterator(): YamlStreamEvent =
        var asString = case value
            of Inf: ".inf"
            of NegInf: "-.inf"
            of NaN: ".nan"
            else: $value
    
        yield YamlStreamEvent(kind: yamlScalar, scalarTag:
                if verboseTags: yTagFloat else: yTagQuestionMark,
                scalarAnchor: yAnchorNone, scalarContent: asString)

proc construct*(s: YamlStream, result: var bool) =
    let item = s()
    if finished(s) or item.kind != yamlScalar:
        raise newException(ValueError, "Construction error!")
    if item.scalarTag notin [yTagQuestionMark, yTagBoolean]:
        raise newException(ValueError, "Wrong scalar type for bool.")
    case item.scalarType
    of yTypeBoolTrue:
        result = true
    of yTypeBoolFalse:
        result = false
    else:
        raise newException(ValueError, "Wrong scalar type for bool.")

proc serialize*(value: bool, verboseTags: bool = false): YamlStream =
    result = iterator(): YamlStreamEvent =
        yield YamlStreamEvent(kind: yamlScalar, scalarTag:
                if verboseTags: yTagBoolean else: yTagQuestionMark,
                scalarAnchor: yAnchorNone, scalarContent:
                if value: "y" else: "n")

proc construct*[T](s: YamlStream, result: var seq[T]) =
    var event = s()
    if finished(s) or event.kind != yamlStartSequence:
        raise newException(ValueError, "Construction error!")
    if event.seqTag != yTagQuestionMark:
        raise newException(ValueError, "Wrong sequence type for seq[T]")
    result = newSeq[T]()
    event = s()
    if finished(s):
        raise newException(ValueError, "Construction error!")
    while event.kind != yamlEndSequence:
        var
            item: T
            events = prepend(event, s)
        construct(events, item)
        result.add(item)
        event = s()
        if finished(s):
            raise newException(ValueError, "Construction error!")

proc serialize*[T](value: seq[T], verboseTags: bool = false): YamlStream =
    result = iterator(): YamlStreamEvent =
        yield YamlStreamEvent(kind: yamlStartSequence, seqTag: yTagQuestionMark,
                              seqAnchor: yAnchorNone)
        for item in value:
            var events = serialize(item, verboseTags)
            for event in events():
                yield event
        yield YamlStreamEvent(kind: yamlEndSequence)

proc construct*[K, V](s: YamlStream, result: var Table[K, V]) =
    var event = s()
    if finished(s) or event.kind != yamlStartMap:
        raise newException(ValueError, "Construction error!")
    if event.mapTag != yTagQuestionMark:
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
                      verboseTags: bool = false): YamlStream =
    result = iterator(): YamlStreamEvent =
        yield YamlStreamEvent(kind: yamlStartMap, mapTag: yTagQuestionMark,
                              mapAnchor: yAnchorNone)
        for key, value in value.pairs:
            var events = serialize(key, verboseTags)
            for event in events():
                yield event
            events = serialize(value, verboseTags)
            for event in events():
                yield event
        yield YamlStreamEvent(kind: yamlEndMap)