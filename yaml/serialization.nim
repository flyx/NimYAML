import "../yaml"
import macros, strutils, streams, tables, json, hashes
export yaml, streams, tables, json

type
    TagStyle* = enum
        tsNone, tsRootOnly, tsAll

const
    yTagNimInt*     = 100.TagId
    yTagNimInt64*   = 101.TagId
    yTagNimFloat*   = 102.TagId
    yTagNimFloat64* = 103.TagId

proc initSerializationTagLibrary(): TagLibrary {.raises: [].} =
    result = initTagLibrary()
    result.tags["!"] = yTagExclamationMark
    result.tags["?"] = yTagQuestionMark
    result.tags["tag:yaml.org,2002:str"]       = yTagString
    result.tags["tag:yaml.org,2002:null"]      = yTagNull
    result.tags["tag:yaml.org,2002:bool"]      = yTagBoolean
    result.tags["tag:yaml.org,2002:float"]     = yTagFloat
    result.tags["tag:yaml.org,2002:timestamp"] = yTagTimestamp
    result.tags["tag:yaml.org,2002:value"]     = yTagValue
    result.tags["tag:yaml.org,2002:binary"]    = yTagBinary
    result.tags["!nim:int"]      = yTagNimInt
    result.tags["!nim:int64"]    = yTagNimInt64
    result.tags["!nim:float"]    = yTagNimFloat
    result.tags["!nim:float64"]  = yTagNimFloat64

var
    serializationTagLibrary* = initSerializationTagLibrary() ## \
        ## contains all local tags that are used for type serialization. Does
        ## not contain any of the specific default tags for sequences or maps,
        ## as those are not suited for Nim's static type system.
        ##
        ## Should not be modified manually. Will be extended by
        ## `serializable <#serializable,stmt,stmt>`_.


static:
    iterator objectFields(n: NimNode): tuple[name: NimNode, t: NimNode]
            {.raises: [].} =
        assert n.kind in [nnkRecList, nnkTupleTy]
        for identDefs in n.children:
            let numFields = identDefs.len - 2
            for i in 0..numFields - 1:
                yield (name: identDefs[i], t: identDefs[^2])
    
    var existingTuples = newSeq[NimNode]()

template presentTag(t: typedesc, tagStyle: TagStyle): TagId =
     if tagStyle == tsNone: yTagQuestionMark else: yamlTag(t)

proc lazyLoadTag*(uri: string): TagId {.inline, raises: [].} =
    try:
        result = serializationTagLibrary.tags[uri]
    except KeyError:
        result = serializationTagLibrary.registerUri(uri)

macro serializable*(types: stmt): stmt =
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
        constructProc[4] = newNimNode(nnkPragma).add(
                newNimNode(nnkExprColonExpr).add(newIdentNode("raises"),
                newNimNode(nnkBracket).add(
                newIdentNode("YamlConstructionError"),
                newIdentNode("YamlConstructionStreamError"))))
        impl = quote do:
            var event = s()
            if finished(s) or event.kind != yamlStartMap:
                raise newException(YamlConstructionError, "Expected map start")
            if event.mapTag != yTagQuestionMark and
                    event.mapTag != yamlTag(type(`tIdent`)):
                raise newException(YamlConstructionError,
                                   "Wrong tag for " & `tName`)
            event = s()
            assert(not finished(s))
            while event.kind != yamlEndMap:
                assert event.kind == yamlScalar
                assert event.scalarTag in [yTagQuestionMark, yTagString]
                case event.scalarContent
                else:
                    raise newException(YamlConstructionError,
                            "Unknown key for " & `tName` & ": " &
                            event.scalarContent)
                event = s()
                assert(not finished(s))
        var keyCase = impl[5][1][2]
        assert keyCase.kind == nnkCaseStmt
        for field in objectFields(recList):
            keyCase.insert(1, newNimNode(nnkOfBranch).add(
                    newStrLitNode($field.name.ident)).add(newStmtList(
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
                             newIdentNode("TagStyle"),
                             newIdentNode("tsNone"))])
        serializeProc[4] = newNimNode(nnkPragma).add(
                newNimNode(nnkExprColonExpr).add(newIdentNode("raises"),
                newNimNode(nnkBracket)))
        var iterBody = newStmtList(
            newLetStmt(newIdentNode("childTagStyle"), newNimNode(nnkIfExpr).add(
                newNimNode(nnkElifExpr).add(
                    newNimNode(nnkInfix).add(newIdentNode("=="),
                        newIdentNode("tagStyle"), newIdentNode("tsRootOnly")),
                    newIdentNode("tsNone")
                ), newNimNode(nnkElseExpr).add(newIdentNode("tagStyle")))),
            newNimNode(nnkYieldStmt).add(
                newNimNode(nnkObjConstr).add(newIdentNode("YamlStreamEvent"),
                    newNimNode(nnkExprColonExpr).add(newIdentNode("kind"),
                        newIdentNode("yamlStartMap")),
                    newNimNode(nnkExprColonExpr).add(newIdentNode("mapTag"),
                        newNimNode(nnkIfExpr).add(newNimNode(nnkElifExpr).add(
                            newNimNode(nnkInfix).add(newIdentNode("=="),
                                newIdentNode("tagStyle"),
                                newIdentNode("tsNone")),
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

proc prepend(event: YamlStreamEvent, s: YamlStream): YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield event
        for e in s():
            yield e

proc safeTagUri*(id: TagId): string {.raises: [].} =
    try:
        let uri = serializationTagLibrary.uri(id)
        if uri.len > 0 and uri[0] == '!':
            return uri[1..uri.len - 1]
        else:
            return uri
    except KeyError:
        # cannot happen (theoretically, you known)
        assert(false)

template constructScalarItem(item: YamlStreamEvent, name: string, t: TagId,
                             content: stmt) =
    try:
        item = s()
    except Exception:
        var e = newException(YamlConstructionStreamError, "")
        e.parent = getCurrentException()
        raise e
    if finished(s) or item.kind != yamlScalar:
        raise newException(YamlConstructionError, "Expected scalar")
    if item.scalarTag notin [yTagQuestionMark, yTagExclamationMark, t]:
        raise newException(YamlConstructionError, "Wrong tag for " & name)
    try:
        content
    except YamlConstructionError:
        raise
    except Exception:
        var e = newException(YamlConstructionError,
                "Cannot construct to " & name & ": " & item.scalarContent)
        e.parent = getCurrentException()
        raise e

template safeNextEvent(e: YamlStreamEvent, s: YamlStream) =
    try:
        e = s()
    except Exception:
        var ex = newException(YamlConstructionStreamError, "")
        ex.parent = getCurrentException()
        raise ex

proc yamlTag*(T: typedesc[string]): TagId {.inline, raises: [].} = yTagString

proc construct*(s: YamlStream, result: var string)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(item, "string", yTagString):
        result = item.scalarContent

proc serialize*(value: string,
                tagStyle: TagStyle = tsNone): YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent(value, presentTag(string, tagStyle), yAnchorNone)

proc yamlTag*(T: typedesc[int]): TagId {.inline.} = yTagNimInt

proc construct*(s: YamlStream, result: var int)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(item, "int", yTagNimInt):
        result = parseInt(item.scalarContent)

proc serialize*(value: int, tagStyle: TagStyle = tsNone): YamlStream =
    result = iterator(): YamlStreamEvent {.raises: [].} =
        yield scalarEvent($value, presentTag(int, tagStyle), yAnchorNone)

proc yamlTag*(T: typedesc[int64]): TagId {.inline, raises: [].} = yTagNimInt64

proc contruct*(s: YamlStream, result: var int64)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(item, "int64", yTagNimInt64):
        result = parseBiggestInt(item.scalarContent)

proc serialize*(value: int64, tagStyle: TagStyle = tsNone): YamlStream
        {.raises: [].}=
    result = iterator(): YamlStreamEvent =
        yield scalarEvent($value, presentTag(int64, tagStyle), yAnchorNone)

proc yamlTag*(T: typedesc[float]): TagId {.inline, raises: [].} = yTagNimFloat

proc construct*(s: YamlStream, result: var float)
         {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(item, "float", yTagNimFloat):
        let hint = guessType(item.scalarContent)
        case hint
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
            raise newException(YamlConstructionError,
                    "Cannot construct to float: " & item.scalarContent)

proc serialize*(value: float, tagStyle: TagStyle = tsNone): YamlStream
         {.raises: [].}=
    result = iterator(): YamlStreamEvent =
        var
            asString: string
        case value
        of Inf:
            asString = ".inf"
        of NegInf:
            asString = "-.inf"
        of NaN:
            asString = ".nan"
        else:
            asString = $value
        yield scalarEvent(asString, presentTag(float, tagStyle), yAnchorNone)

proc yamlTag*(T: typedesc[bool]): TagId {.inline, raises: [].} = yTagBoolean

proc construct*(s: YamlStream, result: var bool)
         {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(item, "bool", yTagBoolean):
        case guessType(item.scalarContent)
        of yTypeBoolTrue:
            result = true
        of yTypeBoolFalse:
            result = false
        else:
            raise newException(YamlConstructionError,
                    "Cannot construct to bool: " & item.scalarContent)
        
proc serialize*(value: bool, tagStyle: TagStyle = tsNone): YamlStream 
        {.raises: [].}=
    result = iterator(): YamlStreamEvent =
        yield scalarEvent(if value: "y" else: "n", presentTag(bool, tagStyle),
                          yAnchorNone)

proc yamlTag*[I](T: typedesc[seq[I]]): TagId {.inline, raises: [].} =
    let uri = "!nim:seq(" & safeTagUri(yamlTag(I)) & ")"
    result = lazyLoadTag(uri)

proc construct*[T](s: YamlStream, result: var seq[T])
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var event: YamlStreamEvent
    safeNextEvent(event, s)
    if finished(s) or event.kind != yamlStartSequence:
        raise newException(YamlConstructionError, "Expected sequence start")
    if event.seqTag notin [yTagQuestionMark, yamlTag(seq[T])]:
        raise newException(YamlConstructionError, "Wrong tag for seq[T]")
    result = newSeq[T]()
    safeNextEvent(event, s)
    assert(not finished(s))
    while event.kind != yamlEndSequence:
        var
            item: T
            events = prepend(event, s)
        try:
            construct(events, item)
        except:
            # compiler bug: https://github.com/nim-lang/Nim/issues/3772
            assert(false)
        result.add(item)
        safeNextEvent(event, s)
        assert(not finished(s))

proc serialize*[T](value: seq[T], tagStyle: TagStyle = tsNone): YamlStream
         {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        let childTagStyle = if tagStyle == tsRootOnly: tsNone else: tagStyle
        yield YamlStreamEvent(kind: yamlStartSequence,
                              seqTag: presentTag(seq[T], tagStyle),
                              seqAnchor: yAnchorNone)
        for item in value:
            var events = serialize(item, childTagStyle)
            for event in events():
                yield event
        yield YamlStreamEvent(kind: yamlEndSequence)

proc yamlTag*[K, V](T: typedesc[Table[K, V]]): TagId {.inline, raises: [].} =
    try:
        let
            keyUri     = serializationTagLibrary.uri(yamlTag(K))
            valueUri   = serializationTagLibrary.uri(yamlTag(V))
            keyIdent   = if keyUri[0] == '!': keyUri[1..keyUri.len - 1] else:
                         keyUri
            valueIdent = if valueUri[0] == '!':
                    valueUri[1..valueUri.len - 1] else: valueUri
            uri = "!nim:Table(" & keyUri & "," & valueUri & ")"
        result = lazyLoadTag(uri)
    except KeyError:
        # cannot happen (theoretically, you known)
        assert(false)

proc construct*[K, V](s: YamlStream, result: var Table[K, V])
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var event: YamlStreamEvent
    safeNextEvent(event, s)
    if finished(s) or event.kind != yamlStartMap:
        raise newException(YamlConstructionError, "Expected map start")
    if event.mapTag notin [yTagQuestionMark, yamlTag(Table[K, V])]:
        raise newException(YamlConstructionError, "Wrong tag for Table[K, V]")
    result = initTable[K, V]()
    safeNextEvent(event, s)
    assert(not finished(s))
    while event.kind != yamlEndMap:
        var
            key: K
            value: V
            events = prepend(event, s)
        try:
            construct(events, key)
            construct(s, value)
        except Exception:
            # compiler bug: https://github.com/nim-lang/Nim/issues/3772
            assert(false)
        result[key] = value
        safeNextEvent(event, s)
        assert(not finished(s))

proc serialize*[K, V](value: Table[K, V],
                      tagStyle: TagStyle = tsNone): YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        let childTagStyle = if tagStyle == tsRootOnly: tsNone else: tagStyle
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

proc load*[K](input: Stream, target: var K)
        {.raises: [YamlConstructionError, IOError, YamlParserError].} =
    try:
        var
            parser = newYamlParser(serializationTagLibrary)
            events = parser.parse(input)
        assert events().kind == yamlStartDocument
        construct(events, target)
        assert events().kind == yamlEndDocument
    except YamlConstructionError, IOError, YamlParserError:
        raise
    except YamlConstructionStreamError:
        let e = cast[ref YamlConstructionError](getCurrentException())
        if e.parent of IOError:
            raise cast[ref IOError](e.parent)
        elif e.parent of YamlParserError:
            raise cast[ref YamlParserError](e.parent)
        else:
            assert(false)
    except Exception:
        # compiler bug: https://github.com/nim-lang/Nim/issues/3772
        assert(false)

proc dump*[K](value: K, target: Stream, style: PresentationStyle = psDefault,
              tagStyle: TagStyle = tsRootOnly, indentationStep: int = 2)
            {.raises: [YamlConstructionError, YamlConstructionStreamError,
                       YamlPresenterJsonError, YamlPresenterOutputError].} =
    var serialized = serialize(value,
            if style == psCanonical: tsAll else: tagStyle)
    var events = iterator(): YamlStreamEvent =
        yield YamlStreamEvent(kind: yamlStartDocument)
        while true:
            var event: YamlStreamEvent
            try:
                event = serialized()
                if finished(serialized): break
            except Exception:
                # serializing object does not raise any errors, so we can
                # ignore this
                assert(false)
            yield event
        yield YamlStreamEvent(kind: yamlEndDocument)
    try:
        present(events, target, serializationTagLibrary, style, indentationStep)
    except YamlPresenterStreamError:
        # serializing object does not raise any errors, so we can ignore this
        assert(false)