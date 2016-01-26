import "../yaml"
import macros, strutils, streams, tables, json, hashes, typetraits
export yaml, streams, tables, json

type
    TagStyle* = enum
        tsNone, tsRootOnly, tsAll

const
    yTagNimInt8*    = 100.TagId
    yTagNimInt16*   = 101.TagId
    yTagNimInt32*   = 102.TagId
    yTagNimInt64*   = 103.TagId
    yTagNimUInt8*   = 104.TagId
    yTagNimUInt16*  = 105.TagId
    yTagNimUInt32*  = 106.TagId
    yTagNimUInt64*  = 107.TagId
    yTagNimFloat32* = 108.TagId
    yTagNimFloat64* = 109.TagId
    yTagNimChar*    = 110.TagId

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
    result.tags["!nim:int8"]     = yTagNimInt8
    result.tags["!nim:int16"]    = yTagNimInt16
    result.tags["!nim:int32"]    = yTagNimInt32
    result.tags["!nim:int64"]    = yTagNimInt64
    result.tags["!nim:uint8"]    = yTagNimUInt8
    result.tags["!nim:uint16"]   = yTagNimUInt16
    result.tags["!nim:uint32"]   = yTagNimUInt32
    result.tags["!nim:uint64"]   = yTagNimUInt64
    result.tags["!nim:float32"]  = yTagNimFloat32
    result.tags["!nim:float64"]  = yTagNimFloat64
    result.tags["!nim:char"]     = yTagNimChar

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
        
        # constructObject()
        
        var constructProc = newProc(newIdentNode("constructObject"), [
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
                        newCall("constructObject", [newIdentNode("s"),
                        newDotExpr(newIdentNode("result"), field.name)])
                    ))
            )
            
        constructProc[6] = impl
        result.add(constructProc)
        
        # serializeObject()
        
        var serializeProc = newProc(newIdentNode("serializeObject"), [
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
                    newCall("serializeObject", newDotExpr(newIdentNode("value"),
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

proc constructObject*(s: YamlStream, result: var string)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(item, "string", yTagString):
        result = item.scalarContent

proc serializeObject*(value: string,
                      ts: TagStyle = tsNone): YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent(value, presentTag(string, ts), yAnchorNone)

proc yamlTag*(T: typedesc[int8]): TagId {.inline, raises: [].}  = yTagNimInt8
proc yamlTag*(T: typedesc[int16]): TagId {.inline, raises: [].} = yTagNimInt16
proc yamlTag*(T: typedesc[int32]): TagId {.inline, raises: [].} = yTagNimInt32
proc yamlTag*(T: typedesc[int64]): TagId {.inline, raises: [].} = yTagNimInt64

proc constructObject*[T: int8|int16|int32|int64](s: YamlStream, result: var T)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(item, name(T), yamlTag(T)):
        result = T(parseBiggestInt(item.scalarContent))

template constructObject*(s: YamlStream, result: var int) =
    {.fatal: "The length of `int` is platform dependent. Use int[8|16|32|64].".}
    discard

proc serializeObject*[T: int8|int16|int32|int64](value: T,
                                                 ts: TagStyle = tsNone):
            YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent($value, presentTag(T, ts), yAnchorNone)

template serialize*(value: int, tagStyle: TagStyle = tsNone) =
    {.fatal: "The length of `int` is platform dependent. Use int[8|16|32|64].".}
    discard

proc yamlTag*(T: typedesc[uint8]): TagId {.inline, raises: [].} = yTagNimUInt8
proc yamlTag*(T: typedesc[uint16]): TagId {.inline, raises: [].} = yTagNimUInt16
proc yamlTag*(T: typedesc[uint32]): TagId {.inline, raises: [].} = yTagNimUInt32
proc yamlTag*(T: typedesc[uint64]): TagId {.inline, raises: [].} = yTagNimUInt64

{.push overflowChecks: on.}
proc parseBiggestUInt(s: string): uint64 =
    result = 0
    for c in s:
        if c in {'0'..'9'}:
            result *= 10.uint64 + (uint64(c) - uint64('0'))
        elif c == '_':
            discard
        else:
            raise newException(ValueError, "Invalid char in uint: " & c)
{.pop.}

proc constructObject*[T: uint8|uint16|uint32|uint64](s: YamlStream,
                                                     result: var T)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(item, name[T], yamlTag(T)):
        result = T(parseBiggestUInt(item.scalarContent))

template constructObject*(s: YamlStream, result: var uint) =
    {.fatal:
        "The length of `uint` is platform dependent. Use uint[8|16|32|64].".}
    discard

proc serializeObject*[T: uint8|uint16|uint32|uint64](
        value: T, ts: TagStyle = tsNone): YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent($value, presentTag(T, ts), yAnchorNone)

template serializeObject*(value: uint, ts: TagStyle = tsNone) =
    {.fatal:
        "The length of `uint` is platform dependent. Use uint[8|16|32|64].".}
    discard

proc yamlTag*(T: typedesc[float32]): TagId {.inline, raises: [].} =
    yTagNimFloat32
proc yamlTag*(T: typedesc[float64]): TagId {.inline, raises: [].} =
    yTagNimFloat64

proc constructObject*[T: float32|float64](s: YamlStream, result: var T)
         {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(item, name(T), yamlTag(T)):
        let hint = guessType(item.scalarContent)
        case hint
        of yTypeFloat:
            result = T(parseBiggestFloat(item.scalarContent))
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

template constructObject*(s: YamlStream, result: var float) =
    {.fatal: "The length of `float` is platform dependent. Use float[32|64].".}

proc serializeObject*[T: float32|float64](value: T, ts: TagStyle = tsNone):
        YamlStream {.raises: [].} =
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
        yield scalarEvent(asString, presentTag(T, ts), yAnchorNone)

template serializeObject*(value: float, tagStyle: TagStyle = tsNone) =
    {.fatal: "The length of `float` is platform dependent. Use float[32|64].".}

proc yamlTag*(T: typedesc[bool]): TagId {.inline, raises: [].} = yTagBoolean

proc constructObject*(s: YamlStream, result: var bool)
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
        
proc serializeObject*(value: bool, ts: TagStyle = tsNone): YamlStream 
        {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent(if value: "y" else: "n", presentTag(bool, ts),
                          yAnchorNone)

proc yamlTag*(T: typedesc[char]): TagId {.inline, raises: [].} = yTagNimChar

proc constructObject*(s: YamlStream, result: var char)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(item, "char", yTagNimChar):
        if item.scalarContent.len != 1:
            raise newException(YamlConstructionError,
                    "Cannot construct to char (length != 1): " &
                    item.scalarContent)
        else:
            result = item.scalarContent[0]

proc serializeObject*(value: char, ts: TagStyle = tsNone): YamlStream
        {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent("" & value, presentTag(char, ts), yAnchorNone)

proc yamlTag*[I](T: typedesc[seq[I]]): TagId {.inline, raises: [].} =
    let uri = "!nim:seq(" & safeTagUri(yamlTag(I)) & ")"
    result = lazyLoadTag(uri)

proc constructObject*[T](s: YamlStream, result: var seq[T])
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
            constructObject(events, item)
        except AssertionError: raise
        except:
            # compiler bug: https://github.com/nim-lang/Nim/issues/3772
            assert(false)
        result.add(item)
        safeNextEvent(event, s)
        assert(not finished(s))

proc serializeObject*[T](value: seq[T], ts: TagStyle = tsNone): YamlStream
         {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        let childTagStyle = if ts == tsRootOnly: tsNone else: ts
        yield YamlStreamEvent(kind: yamlStartSequence,
                              seqTag: presentTag(seq[T], ts),
                              seqAnchor: yAnchorNone)
        for item in value:
            var events = serializeObject(item, childTagStyle)
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

proc constructObject*[K, V](s: YamlStream, result: var Table[K, V])
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
            constructObject(events, key)
            constructObject(s, value)
        except AssertionError: raise
        except Exception:
            # compiler bug: https://github.com/nim-lang/Nim/issues/3772
            assert(false)
        result[key] = value
        safeNextEvent(event, s)
        assert(not finished(s))

proc serializeObject*[K, V](value: Table[K, V],
                      ts: TagStyle = tsNone): YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        let childTagStyle = if ts == tsRootOnly: tsNone else: ts
        yield YamlStreamEvent(kind: yamlStartMap,
                              mapTag: presentTag(Table[K, V], ts),
                              mapAnchor: yAnchorNone)
        for key, value in value.pairs:
            var events = serializeObject(key, childTagStyle)
            for event in events():
                yield event
            events = serializeObject(value, childTagStyle)
            for event in events():
                yield event
        yield YamlStreamEvent(kind: yamlEndMap)

proc construct*[T](s: YamlStream, target: var T)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    try:
        var e = s()
        assert((not finished(s)) and e.kind == yamlStartDocument)
        constructObject(s, target)
        e = s()
        assert((not finished(s)) and e.kind == yamlEndDocument)
    except YamlConstructionError, YamlConstructionStreamError, AssertionError:
        raise
    except Exception:
        # may occur while calling s()
        var ex = newException(YamlConstructionStreamError, "")
        ex.parent = getCurrentException()
        raise ex

proc load*[K](input: Stream, target: var K)
        {.raises: [YamlConstructionError, IOError, YamlParserError].} =
    var
        parser = newYamlParser(serializationTagLibrary)
        events = parser.parse(input)
    try:
        construct(events, target)
    except YamlConstructionError, AssertionError:
        raise
    except YamlConstructionStreamError:
        let e = (ref YamlConstructionStreamError)(getCurrentException())
        if e.parent of IOError:
            raise (ref IOError)(e.parent)
        elif e.parent of YamlParserError:
            raise (ref YamlParserError)(e.parent)
        else:
            echo e.parent.repr
            assert(false)
    except Exception:
        # compiler bug: https://github.com/nim-lang/Nim/issues/3772
        assert(false)

proc serialize*[T](value: T, ts: TagStyle = tsRootOnly):
        YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        var serialized = serializeObject(value, ts)
        yield YamlStreamEvent(kind: yamlStartDocument)
        while true:
            var event: YamlStreamEvent
            try:
                event = serialized()
                if finished(serialized): break
            except AssertionError: raise
            except Exception:
                # serializing object does not raise any errors, so we can
                # ignore this
                assert(false)
            yield event
        yield YamlStreamEvent(kind: yamlEndDocument)

proc dump*[K](value: K, target: Stream, style: PresentationStyle = psDefault,
              tagStyle: TagStyle = tsRootOnly, indentationStep: int = 2)
            {.raises: [YamlPresenterJsonError, YamlPresenterOutputError].} =
    var events = serialize(value, if style == psCanonical: tsAll else: tagStyle)
    try:
        present(events, target, serializationTagLibrary, style, indentationStep)
    except YamlPresenterStreamError:
        # serializing object does not raise any errors, so we can ignore this
        assert(false)
    except YamlPresenterJsonError, YamlPresenterOutputError, AssertionError:
        raise
    except Exception:
        # cannot occur as serialize() doesn't raise any errors
        assert(false)