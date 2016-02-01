import "../yaml"
import macros, strutils, streams, tables, json, hashes, typetraits
export yaml, streams, tables, json

type
    TagStyle* = enum
        tsNone, tsRootOnly, tsAll
    
    AnchorStyle* = enum
        asNone, asTidy, asAlways
    
    RefNodeData* = object
        p: pointer
        count: int
        anchor: AnchorId
    
    ConstructionContext* = ref object
        refs: Table[AnchorId, pointer]
    
    SerializationContext* = ref object
        refsList: seq[RefNodeData]
        style: AnchorStyle
    
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

proc initRefNodeData(p: pointer): RefNodeData =
    result.p = p
    result.count = 1
    result.anchor = yAnchorNone

proc newConstructionContext(): ConstructionContext =
    new(result)
    result.refs = initTable[AnchorId, pointer]()

proc newSerializationContext(s: AnchorStyle): SerializationContext =
    new(result)
    result.refsList = newSeq[RefNodeData]()
    result.style = s

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
    result.tags["!nim:system:int8"]     = yTagNimInt8
    result.tags["!nim:system:int16"]    = yTagNimInt16
    result.tags["!nim:system:int32"]    = yTagNimInt32
    result.tags["!nim:system:int64"]    = yTagNimInt64
    result.tags["!nim:system:uint8"]    = yTagNimUInt8
    result.tags["!nim:system:uint16"]   = yTagNimUInt16
    result.tags["!nim:system:uint32"]   = yTagNimUInt32
    result.tags["!nim:system:uint64"]   = yTagNimUInt64
    result.tags["!nim:system:float32"]  = yTagNimFloat32
    result.tags["!nim:system:float64"]  = yTagNimFloat64
    result.tags["!nim:system:char"]     = yTagNimChar

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

template presentTag(t: typedesc, ts: TagStyle): TagId =
     if ts == tsNone: yTagQuestionMark else: yamlTag(t)

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
            tUri = newStrLitNode("!nim:custom:" & tName)
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
                newIdentDefs(newIdentNode("c"),
                newIdentNode("ConstructionContext")),
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
                        newIdentNode("c"),
                        newDotExpr(newIdentNode("result"), field.name)])
                    ))
            )
            
        constructProc[6] = impl
        result.add(constructProc)
        
        # serializeObject()
        
        var serializeProc = newProc(newIdentNode("serializeObject"), [
                newIdentNode("YamlStream"),
                newIdentDefs(newIdentNode("value"), tIdent),
                newIdentDefs(newIdentNode("ts"),
                             newIdentNode("TagStyle")),
                newIdentDefs(newIdentNode("c"),
                             newIdentNode("SerializationContext"))])
        serializeProc[4] = newNimNode(nnkPragma).add(
                newNimNode(nnkExprColonExpr).add(newIdentNode("raises"),
                newNimNode(nnkBracket)))
        var iterBody = newStmtList(
            newLetStmt(newIdentNode("childTagStyle"), newNimNode(nnkIfExpr).add(
                newNimNode(nnkElifExpr).add(
                    newNimNode(nnkInfix).add(newIdentNode("=="),
                        newIdentNode("ts"), newIdentNode("tsRootOnly")),
                    newIdentNode("tsNone")
                ), newNimNode(nnkElseExpr).add(newIdentNode("ts")))),
            newNimNode(nnkYieldStmt).add(
                newNimNode(nnkObjConstr).add(newIdentNode("YamlStreamEvent"),
                    newNimNode(nnkExprColonExpr).add(newIdentNode("kind"),
                        newIdentNode("yamlStartMap")),
                    newNimNode(nnkExprColonExpr).add(newIdentNode("mapTag"),
                        newNimNode(nnkIfExpr).add(newNimNode(nnkElifExpr).add(
                            newNimNode(nnkInfix).add(newIdentNode("=="),
                                newIdentNode("ts"),
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
                    field.name), newIdentNode("childTagStyle"),
                    newIdentNode("c"))))
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
    except YamlConstructionStreamError, AssertionError:
        raise
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
    except YamlConstructionStreamError, AssertionError:
        raise
    except Exception:
        var ex = newException(YamlConstructionStreamError, "")
        ex.parent = getCurrentException()
        raise ex

proc yamlTag*(T: typedesc[string]): TagId {.inline, raises: [].} = yTagString

proc constructObject*(s: YamlStream, c: ConstructionContext, result: var string)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(item, "string", yTagString):
        result = item.scalarContent

proc serializeObject*(value: string, ts: TagStyle = tsNone,
                      c: SerializationContext): YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent(value, presentTag(string, ts), yAnchorNone)

proc yamlTag*(T: typedesc[int8]): TagId {.inline, raises: [].}  = yTagNimInt8
proc yamlTag*(T: typedesc[int16]): TagId {.inline, raises: [].} = yTagNimInt16
proc yamlTag*(T: typedesc[int32]): TagId {.inline, raises: [].} = yTagNimInt32
proc yamlTag*(T: typedesc[int64]): TagId {.inline, raises: [].} = yTagNimInt64

proc constructObject*[T: int8|int16|int32|int64](
        s: YamlStream, c: ConstructionContext, result: var T)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(item, name(T), yamlTag(T)):
        result = T(parseBiggestInt(item.scalarContent))

template constructObject*(s: YamlStream, c: ConstructionContext,
                          result: var int) =
    {.fatal: "The length of `int` is platform dependent. Use int[8|16|32|64].".}
    discard

proc serializeObject*[T: int8|int16|int32|int64](
        value: T, ts: TagStyle = tsNone, c: SerializationContext):
        YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent($value, presentTag(T, ts), yAnchorNone)

template serializeObject*(value: int, tagStyle: TagStyle,
                          c: SerializationContext) =
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

proc constructObject*[T: uint8|uint16|uint32|uint64](
        s: YamlStream, c: ConstructionContext, result: var T)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(item, name[T], yamlTag(T)):
        result = T(parseBiggestUInt(item.scalarContent))

template constructObject*(s: YamlStream, c: ConstructionContext,
                          result: var uint) =
    {.fatal:
        "The length of `uint` is platform dependent. Use uint[8|16|32|64].".}
    discard

proc serializeObject*[T: uint8|uint16|uint32|uint64](
        value: T, ts: TagStyle, c: SerializationContext):
        YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent($value, presentTag(T, ts), yAnchorNone)

template serializeObject*(value: uint, ts: TagStyle, c: SerializationContext) =
    {.fatal:
        "The length of `uint` is platform dependent. Use uint[8|16|32|64].".}
    discard

proc yamlTag*(T: typedesc[float32]): TagId {.inline, raises: [].} =
    yTagNimFloat32
proc yamlTag*(T: typedesc[float64]): TagId {.inline, raises: [].} =
    yTagNimFloat64

proc constructObject*[T: float32|float64](
        s: YamlStream, c: ConstructionContext, result: var T)
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

template constructObject*(s: YamlStream, c: ConstructionContext,
                          result: var float) =
    {.fatal: "The length of `float` is platform dependent. Use float[32|64].".}

proc serializeObject*[T: float32|float64](value: T, ts: TagStyle,
                                          c: SerializationContext):
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

template serializeObject*(value: float, tagStyle: TagStyle,
                          c: SerializationContext) =
    {.fatal: "The length of `float` is platform dependent. Use float[32|64].".}

proc yamlTag*(T: typedesc[bool]): TagId {.inline, raises: [].} = yTagBoolean

proc constructObject*(s: YamlStream, c: ConstructionContext, result: var bool)
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
        
proc serializeObject*(value: bool, ts: TagStyle,
                      c: SerializationContext): YamlStream  {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent(if value: "y" else: "n", presentTag(bool, ts),
                          yAnchorNone)

proc yamlTag*(T: typedesc[char]): TagId {.inline, raises: [].} = yTagNimChar

proc constructObject*(s: YamlStream, c: ConstructionContext, result: var char)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(item, "char", yTagNimChar):
        if item.scalarContent.len != 1:
            raise newException(YamlConstructionError,
                    "Cannot construct to char (length != 1): " &
                    item.scalarContent)
        else:
            result = item.scalarContent[0]

proc serializeObject*(value: char, ts: TagStyle,
                      c: SerializationContext): YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent("" & value, presentTag(char, ts), yAnchorNone)

proc yamlTag*[I](T: typedesc[seq[I]]): TagId {.inline, raises: [].} =
    let uri = "!nim:system:seq(" & safeTagUri(yamlTag(I)) & ")"
    result = lazyLoadTag(uri)

proc constructObject*[T](s: YamlStream, c: ConstructionContext,
                         result: var seq[T])
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
            constructObject(events, c, item)
        except AssertionError, YamlConstructionError,
               YamlConstructionStreamError: raise
        except:
            # compiler bug: https://github.com/nim-lang/Nim/issues/3772
            assert(false)
        result.add(item)
        safeNextEvent(event, s)
        assert(not finished(s))

proc serializeObject*[T](value: seq[T], ts: TagStyle,
                         c: SerializationContext): YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        let childTagStyle = if ts == tsRootOnly: tsNone else: ts
        yield YamlStreamEvent(kind: yamlStartSequence,
                              seqTag: presentTag(seq[T], ts),
                              seqAnchor: yAnchorNone)
        for item in value:
            var events = serializeObject(item, childTagStyle, c)
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
            uri = "!nim:tables:Table(" & keyUri & "," & valueUri & ")"
        result = lazyLoadTag(uri)
    except KeyError:
        # cannot happen (theoretically, you known)
        assert(false)

proc constructObject*[K, V](s: YamlStream, c: ConstructionContext,
                            result: var Table[K, V])
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var event: YamlStreamEvent
    safeNextEvent(event, s)
    assert(not finished(s))
    if event.kind != yamlStartMap:
        raise newException(YamlConstructionError, "Expected map start, got " &
                           $event.kind)
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
            constructObject(events, c, key)
            constructObject(s, c, value)
        except AssertionError: raise
        except Exception:
            # compiler bug: https://github.com/nim-lang/Nim/issues/3772
            assert(false)
        result[key] = value
        safeNextEvent(event, s)
        assert(not finished(s))

proc serializeObject*[K, V](value: Table[K, V], ts: TagStyle,
                            c: SerializationContext): YamlStream {.raises:[].} =
    result = iterator(): YamlStreamEvent =
        let childTagStyle = if ts == tsRootOnly: tsNone else: ts
        yield YamlStreamEvent(kind: yamlStartMap,
                              mapTag: presentTag(Table[K, V], ts),
                              mapAnchor: yAnchorNone)
        for key, value in value.pairs:
            var events = serializeObject(key, childTagStyle, c)
            for event in events():
                yield event
            events = serializeObject(value, childTagStyle, c)
            for event in events():
                yield event
        yield YamlStreamEvent(kind: yamlEndMap)

template yamlTag*(T: typedesc[object|enum]): expr =
    var uri = when compiles(yamlTagId(T)): yamlTagId(T) else:
            "!nim:custom:" & T.name
    try:
        serializationTagLibrary.tags[uri]
    except KeyError:
        serializationTagLibrary.registerUri(uri)

template yamlTag*(T: typedesc[tuple]): expr =
    var
        i: T
        uri = "!nim:tuple("
        first = true
    for name, value in fieldPairs(i):
        if first: first = false
        else: uri.add(",")
        uri.add(safeTagUri(yamlTag(type(value))))
    uri.add(")")
    try: serializationTagLibrary.tags[uri]
    except KeyError: serializationTagLibrary.registerUri(uri)

proc constructObject*[O: object|tuple](s: YamlStream, c: ConstructionContext,
                                 result: var O)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var e = s()
    assert(not finished(s))
    if e.kind != yamlStartMap:
        raise newException(YamlConstructionError, "Expected map start, got " &
                           $e.kind)
    if e.mapAnchor != yAnchorNone:
        raise newException(YamlConstructionError, "Anchor on a non-ref type")
    e = s()
    assert(not finished(s))
    while e.kind != yamlEndMap:
        if e.kind != yamlScalar:
            raise newException(YamlConstructionError, "Expected field name")
        let name = e.scalarContent
        for fname, value in fieldPairs(result):
            if fname == name:
                constructObject(s, c, value)
                break
        e = s()
        assert(not finished(s))

proc serializeObject*[O: object|tuple](value: O, ts: TagStyle,
                                 c: SerializationContext):
        YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        let childTagStyle = if ts == tsRootOnly: tsNone else: ts
        yield startMapEvent(presentTag(O, ts), yAnchorNone)
        for name, value in fieldPairs(value):
            yield scalarEvent(name, presentTag(string, childTagStyle),
                              yAnchorNone)
            var events = serializeObject(value, childTagStyle, c)
            for event in events():
                yield event
        yield endMapEvent()

proc constructObject*[O: enum](s: YamlStream, c: ConstructionContext,
                               result: var O)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    let e = s()
    assert(not finished(s))
    if e.kind != yamlScalar:
        raise newException(YamlConstructionError, "Expected scalar, got " &
                           $e.kind)
    try: result = parseEnum[O](e.scalarContent)
    except ValueError:
        var ex = newException(YamlConstructionError, "Cannot parse '" &
                e.scalarContent & "' as " & type(O).name)
        ex.parent = getCurrentException()
        raise ex

proc serializeObject*[O: enum](value: O, ts: TagStyle,
                               c: SerializationContext):
        YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent($value, presentTag(O, ts), yAnchorNone)

proc yamlTag*[O](T: typedesc[ref O]): TagId {.inline, raises: [].} = yamlTag(O)

proc constructObject*[O](s: YamlStream, c: ConstructionContext,
                         result: var ref O)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var e = s()
    assert(not finished(s))
    if e.kind == yamlScalar:
        if e.scalarTag == yTagNull or (
                e.scalarTag in [yTagQuestionMark, yTagExclamationMark] and
                guessType(e.scalarContent) == yTypeNull):
            result = nil
            return
    elif e.kind == yamlAlias:
        try:
            result = cast[ref O](c.refs[e.aliasTarget])
            return
        except KeyError:
            assert(false)
    new(result)
    var a: ptr AnchorId
    case e.kind
    of yamlScalar: a = addr(e.scalarAnchor)
    of yamlStartMap: a = addr(e.mapAnchor)
    of yamlStartSequence: a = addr(e.seqAnchor)
    else: assert(false)
    if a[] != yAnchorNone:
        assert(not c.refs.hasKey(a[]))
        c.refs[a[]] = cast[pointer](result)
        a[] = yAnchorNone
    try:
        constructObject(prepend(e, s), c, result[])
    except YamlConstructionError, YamlConstructionStreamError, AssertionError:
        raise
    except Exception:
        var e = newException(YamlConstructionStreamError,
                             getCurrentExceptionMsg())
        e.parent = getCurrentException()
        raise e

proc serializeObject*[O](value: ref O, ts: TagStyle, c: SerializationContext):
        YamlStream {.raises: [].} =
    if value == nil:
        result = iterator(): YamlStreamEvent = yield scalarEvent("~", yTagNull)
    elif c.style == asNone:
        result = serializeObject(value[], ts, c)
    else:
        let
            p = cast[pointer](value)
        for i in countup(0, c.refsList.high):
            if p == c.refsList[i].p:
                c.refsList[i].count.inc()
                result = iterator(): YamlStreamEvent =
                    yield aliasEvent(if c.style == asAlways: AnchorId(i) else:
                                     cast[AnchorId](p))
                return
        c.refsList.add(initRefNodeData(p))
        let a = if c.style == asAlways: AnchorId(c.refsList.high) else:
                cast[AnchorId](p)
        try:
            var
                objStream = serializeObject(value[], ts, c)
                first = objStream()
            assert(not finished(objStream))
            case first.kind
            of yamlStartMap:
                first.mapAnchor = a
            of yamlStartSequence:
                first.seqAnchor = a
            of yamlScalar:
                first.scalarAnchor = a
            else:
                assert(false)
            result = prepend(first, objStream)
        except Exception:
            assert(false)

proc construct*[T](s: YamlStream, target: var T)
        {.raises: [YamlConstructionError, YamlConstructionStreamError].} =
    var context = newConstructionContext()
    try:
        var e = s()
        assert((not finished(s)) and e.kind == yamlStartDocument)
        
        constructObject(s, context, target)
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

proc setAnchor(a: var AnchorId, q: var seq[RefNodeData], n: var AnchorId)
        {.inline.} =
    if a != yAnchorNone:
        let p = cast[pointer](a)
        for i in countup(0, q.len - 1):
            if p == q[i].p:
                if q[i].count > 1:
                    assert(q[i].anchor == yAnchorNone)
                    q[i].anchor = n
                    a = n
                    n = AnchorId(int(n) + 1)
                else:
                    a = yAnchorNone
                break

proc setAliasAnchor(a: var AnchorId, q: var seq[RefNodeData]) {.inline.} =
    let p = cast[pointer](a)
    for i in countup(0, q.len - 1):
        if p == q[i].p:
            assert q[i].count > 1
            assert q[i].anchor != yAnchorNone
            a = q[i].anchor
            return
    assert(false)
            
proc insideDoc(s: YamlStream): YamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield YamlStreamEvent(kind: yamlStartDocument)
        while true:
            var event: YamlStreamEvent
            try:
                event = s()
                if finished(s): break
            except AssertionError: raise
            except Exception:
                # serializing object does not raise any errors, so we can
                # ignore this
                assert(false)
            yield event
        yield YamlStreamEvent(kind: yamlEndDocument)

proc serialize*[T](value: T, ts: TagStyle = tsRootOnly,
                   a: AnchorStyle = asTidy): YamlStream {.raises: [].} =
    var
        context = newSerializationContext(a)
        objStream: YamlStream
    try:
        objStream = insideDoc(serializeObject(value, ts, context))
    except Exception:
        assert(false)
    if a == asTidy:
        var objQueue = newSeq[YamlStreamEvent]()
        try:
            for event in objStream():
                objQueue.add(event)
        except Exception:
            assert(false)
        var next = 0.AnchorId
        result = iterator(): YamlStreamEvent =
            for i in countup(0, objQueue.len - 1):
                var event = objQueue[i]
                case event.kind
                of yamlStartMap:
                    event.mapAnchor.setAnchor(context.refsList, next)
                of yamlStartSequence:
                    event.seqAnchor.setAnchor(context.refsList, next)
                of yamlScalar:
                    event.scalarAnchor.setAnchor(context.refsList, next)
                of yamlAlias:
                    event.aliasTarget.setAliasAnchor(context.refsList)
                else:
                    discard
                yield event
    else:
        result = objStream

proc dump*[K](value: K, target: Stream, style: PresentationStyle = psDefault,
              tagStyle: TagStyle = tsRootOnly,
              anchorStyle: AnchorStyle = asTidy, indentationStep: int = 2)
            {.raises: [YamlPresenterJsonError, YamlPresenterOutputError].} =
    var events = serialize(value, if style == psCanonical: tsAll else: tagStyle,
                           if style == psJson: asNone else: anchorStyle)
    try:
        present(events, target, serializationTagLibrary, style, indentationStep)
    except YamlPresenterStreamError:
        # serializing object does not raise any errors, so we can ignore this
        var e = getCurrentException()
        echo e.msg
        echo e.parent.repr
        assert(false)
    except YamlPresenterJsonError, YamlPresenterOutputError, AssertionError:
        raise
    except Exception:
        # cannot occur as serialize() doesn't raise any errors
        assert(false)