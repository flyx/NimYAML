#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 - 2020 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## =========================
## Module yaml.serialization
## =========================
##
## This is the most high-level API of NimYAML. It enables you to parse YAML
## character streams directly into native YAML types and vice versa. It builds
## on top of the low-level parser and presenter APIs.
##
## It is possible to define custom construction and serialization procs for any
## type. Please consult the serialization guide on the NimYAML website for more
## information.

import tables, typetraits, strutils, macros, streams, times, parseutils, options
import parser, taglib, presenter, stream, private/internal, hints, annotations
export stream, macros, annotations, options
  # *something* in here needs externally visible `==`(x,y: AnchorId),
  # but I cannot figure out what. binding it would be the better option.

type
  SerializationContext* = ref object
    ## Context information for the process of serializing YAML from Nim values.
    when not defined(JS):
      refs*: Table[pointer, AnchorId] # `pointer` does not work with JS
    style: AnchorStyle
    nextAnchorId*: AnchorId
    put*: proc(e: YamlStreamEvent) {.raises: [], closure.}

  ConstructionContext* = ref object
    ## Context information for the process of constructing Nim values from YAML.
    when not defined(JS):
      refs*: Table[AnchorId, pointer]

  YamlConstructionError* = object of YamlLoadingError
    ## Exception that may be raised when constructing data objects from a
    ## `YamlStream <#YamlStream>`_. The fields ``line``, ``column`` and
    ## ``lineContent`` are only available if the costructing proc also does
    ## parsing, because otherwise this information is not available to the
    ## costruction proc.

# forward declares

proc constructChild*[T](s: var YamlStream, c: ConstructionContext,
                        result: var T)
    {.raises: [YamlConstructionError, YamlStreamError].}
  ## Constructs an arbitrary Nim value from a part of a YAML stream.
  ## The stream will advance until after the finishing token that was used
  ## for constructing the value. The ``ConstructionContext`` is needed for
  ## potential child objects which may be refs.

proc constructChild*(s: var YamlStream, c: ConstructionContext,
                     result: var string)
    {.raises: [YamlConstructionError, YamlStreamError].}
  ## Constructs a Nim value that is a string from a part of a YAML stream.
  ## This specialization takes care of possible nil strings.

proc constructChild*[T](s: var YamlStream, c: ConstructionContext,
                        result: var seq[T])
    {.raises: [YamlConstructionError, YamlStreamError].}
  ## Constructs a Nim value that is a string from a part of a YAML stream.
  ## This specialization takes care of possible nil seqs.

proc constructChild*[O](s: var YamlStream, c: ConstructionContext,
                        result: var ref O)
    {.raises: [YamlConstructionError, YamlStreamError].}
  ## Constructs an arbitrary Nim value from a part of a YAML stream.
  ## The stream will advance until after the finishing token that was used
  ## for constructing the value. The object may be constructed from an alias
  ## node which will be resolved using the ``ConstructionContext``.

proc representChild*[O](value: ref O, ts: TagStyle, c: SerializationContext)
    {.raises: [].}
  ## Represents an arbitrary Nim reference value as YAML object. The object
  ## may be represented as alias node if it is already present in the
  ## ``SerializationContext``.

proc representChild*(value: string, ts: TagStyle, c: SerializationContext)
    {.inline, raises: [].}
  ## Represents a Nim string. Supports nil strings.

proc representChild*[O](value: O, ts: TagStyle, c: SerializationContext)
  ## Represents an arbitrary Nim object as YAML object.

proc newConstructionContext*(): ConstructionContext =
  new(result)
  when defined(JS):
    {.emit: [result, """.refs = new Map();"""].}
  else:
    result.refs = initTable[AnchorId, pointer]()

proc newSerializationContext*(s: AnchorStyle,
    putImpl: proc(e: YamlStreamEvent) {.raises: [], closure.}):
    SerializationContext =
  result = SerializationContext(style: s, nextAnchorId: 0.AnchorId,
                                put: putImpl)
  when defined(JS):
    {.emit: [result, """.refs = new Map();"""].}
  else: result.refs = initTable[pointer, AnchorId]()

template presentTag*(t: typedesc, ts: TagStyle): TagId =
  ## Get the TagId that represents the given type in the given style
  if ts == tsNone: yTagQuestionMark else: yamlTag(t)

proc lazyLoadTag(uri: string): TagId {.inline, raises: [].} =
  try: result = serializationTagLibrary.tags[uri]
  except KeyError: result = serializationTagLibrary.registerUri(uri)

proc safeTagUri(id: TagId): string {.raises: [].} =
  try:
    var
      uri = serializationTagLibrary.uri(id)
      i = 0
    # '!' is not allowed inside a tag handle
    if uri.len > 0 and uri[0] == '!': uri = uri[1..^1]
    # ',' is not allowed after a tag handle in the suffix because it's a flow
    # indicator
    for c in uri.mitems():
      if c == ',': c = ';'
      inc(i)
    return uri
  except KeyError: internalError("Unexpected KeyError for TagId " & $id)

proc constructionError(s: YamlStream, msg: string): ref YamlConstructionError =
  result = newException(YamlConstructionError, msg)
  if not s.getLastTokenContext(result.line, result.column, result.lineContent):
    (result.line, result.column) = (-1, -1)
    result.lineContent = ""

template constructScalarItem*(s: var YamlStream, i: untyped,
                              t: typedesc, content: untyped) =
  ## Helper template for implementing ``constructObject`` for types that
  ## are constructed from a scalar. ``i`` is the identifier that holds
  ## the scalar as ``YamlStreamEvent`` in the content. Exceptions raised in
  ## the content will be automatically catched and wrapped in
  ## ``YamlConstructionError``, which will then be raised.
  bind constructionError
  let i = s.next()
  if i.kind != yamlScalar:
    raise constructionError(s, "Expected scalar")
  try: content
  except YamlConstructionError as e: raise e
  except Exception:
    var e = constructionError(s,
        "Cannot construct to " & name(t) & ": " & item.scalarContent &
        "; error: " & getCurrentExceptionMsg())
    e.parent = getCurrentException()
    raise e

proc yamlTag*(T: typedesc[string]): TagId {.inline, noSideEffect, raises: [].} =
  yTagString

proc constructObject*(s: var YamlStream, c: ConstructionContext,
                      result: var string)
    {.raises: [YamlConstructionError, YamlStreamError].} =
  ## costructs a string from a YAML scalar
  constructScalarItem(s, item, string):
    result = item.scalarContent

proc representObject*(value: string, ts: TagStyle,
        c: SerializationContext, tag: TagId) {.raises: [].} =
  ## represents a string as YAML scalar
  c.put(scalarEvent(value, tag, yAnchorNone))

proc parseHex[T: int8|int16|int32|int64|uint8|uint16|uint32|uint64](
      s: YamlStream, val: string): T =
  result = 0
  for i in 2..<val.len:
    case val[i]
    of '_': discard
    of '0'..'9': result = result shl 4 or T(ord(val[i]) - ord('0'))
    of 'a'..'f': result = result shl 4 or T(ord(val[i]) - ord('a') + 10)
    of 'A'..'F': result = result shl 4 or T(ord(val[i]) - ord('A') + 10)
    else:
      raise s.constructionError("Invalid character in hex: " &
          escape("" & val[i]))

proc parseOctal[T: int8|int16|int32|int64|uint8|uint16|uint32|uint64](
    s: YamlStream, val: string): T =
  for i in 2..<val.len:
    case val[i]
    of '_': discard
    of '0'..'7': result = result shl 3 + T((ord(val[i]) - ord('0')))
    else:
      raise s.constructionError("Invalid character in hex: " &
          escape("" & val[i]))

proc constructObject*[T: int8|int16|int32|int64](
    s: var YamlStream, c: ConstructionContext, result: var T)
    {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs an integer value from a YAML scalar
  constructScalarItem(s, item, T):
    if item.scalarContent[0] == '0' and item.scalarContent.len > 1 and item.scalarContent[1] in {'x', 'X' }:
      result = parseHex[T](s, item.scalarContent)
    elif item.scalarContent[0] == '0' and item.scalarContent.len > 1 and item.scalarContent[1] in {'o', 'O'}:
      result = parseOctal[T](s, item.scalarContent)
    else:
      let nInt = parseBiggestInt(item.scalarContent)
      if nInt <= T.high:
        # make sure we don't produce a range error
        result = T(nInt)
      else:
        raise s.constructionError("Cannot construct int; out of range: " &
          $nInt & " for type " & T.name & " with max of: " & $T.high)

proc constructObject*(s: var YamlStream, c: ConstructionContext,
                      result: var int)
    {.raises: [YamlConstructionError, YamlStreamError], inline.} =
  ## constructs an integer of architecture-defined length by loading it into
  ## int32 and then converting it.
  var i32Result: int32
  constructObject(s, c, i32Result)
  result = int(i32Result)

proc representObject*[T: int8|int16|int32|int64](value: T, ts: TagStyle,
    c: SerializationContext, tag: TagId) {.raises: [].} =
  ## represents an integer value as YAML scalar
  c.put(scalarEvent($value, tag, yAnchorNone))

proc representObject*(value: int, tagStyle: TagStyle,
                      c: SerializationContext, tag: TagId)
    {.raises: [YamlStreamError], inline.}=
  ## represent an integer of architecture-defined length by casting it to int32.
  ## on 64-bit systems, this may cause a RangeError.

  # currently, sizeof(int) is at least sizeof(int32).
  try: c.put(scalarEvent($int32(value), tag, yAnchorNone))
  except RangeError:
    var e = newException(YamlStreamError, getCurrentExceptionMsg())
    e.parent = getCurrentException()
    raise e

when defined(JS):
  type DefiniteUIntTypes = uint8 | uint16 | uint32
else:
  type DefiniteUIntTypes = uint8 | uint16 | uint32 | uint64

proc constructObject*[T: DefiniteUIntTypes](
    s: var YamlStream, c: ConstructionContext, result: var T)
    {.raises: [YamlConstructionError, YamlStreamError].} =
  ## construct an unsigned integer value from a YAML scalar
  constructScalarItem(s, item, T):
    if item.scalarContent[0] == '0' and item.scalarContent[1] in {'x', 'X'}:
      result = parseHex[T](s, item.scalarContent)
    elif item.scalarContent[0] == '0' and item.scalarContent[1] in {'o', 'O'}:
      result = parseOctal[T](s, item.scalarContent)
    else: result = T(parseBiggestUInt(item.scalarContent))

proc constructObject*(s: var YamlStream, c: ConstructionContext,
                      result: var uint)
    {.raises: [YamlConstructionError, YamlStreamError], inline.} =
  ## represent an unsigned integer of architecture-defined length by loading it
  ## into uint32 and then converting it.
  var u32Result: uint32
  constructObject(s, c, u32Result)
  result= uint(u32Result)

when defined(JS):
  # TODO: this is a dirty hack and may lead to overflows!
  proc `$`(x: uint8|uint16|uint32|uint64|uint): string =
    result = $BiggestInt(x)

proc representObject*[T: uint8|uint16|uint32|uint64](value: T, ts: TagStyle,
    c: SerializationContext, tag: TagId) {.raises: [].} =
  ## represents an unsigned integer value as YAML scalar
  c.put(scalarEvent($value, tag, yAnchorNone))

proc representObject*(value: uint, ts: TagStyle, c: SerializationContext,
    tag: TagId) {.raises: [YamlStreamError], inline.} =
  ## represent an unsigned integer of architecture-defined length by casting it
  ## to int32. on 64-bit systems, this may cause a RangeError.
  try: c.put(scalarEvent($uint32(value), tag, yAnchorNone))
  except RangeError:
    var e = newException(YamlStreamError, getCurrentExceptionMsg())
    e.parent = getCurrentException()
    raise e

proc constructObject*[T: float|float32|float64](
    s: var YamlStream, c: ConstructionContext, result: var T)
    {.raises: [YamlConstructionError, YamlStreamError].} =
  ## construct a float value from a YAML scalar
  constructScalarItem(s, item, T):
    let hint = guessType(item.scalarContent)
    case hint
    of yTypeFloat:
      discard parseBiggestFloat(item.scalarContent, result)
    of yTypeInteger:
      discard parseBiggestFloat(item.scalarContent, result)
    of yTypeFloatInf:
        if item.scalarContent[0] == '-': result = NegInf
        else: result = Inf
    of yTypeFloatNaN: result = NaN
    else:
      raise s.constructionError("Cannot construct to float: " &
          escape(item.scalarContent))

proc representObject*[T: float|float32|float64](value: T, ts: TagStyle,
    c: SerializationContext, tag: TagId) {.raises: [].} =
  ## represents a float value as YAML scalar
  case value
  of Inf: c.put(scalarEvent(".inf", tag))
  of NegInf: c.put(scalarEvent("-.inf", tag))
  of NaN: c.put(scalarEvent(".nan", tag))
  else: c.put(scalarEvent($value, tag))

proc yamlTag*(T: typedesc[bool]): TagId {.inline, raises: [].} = yTagBoolean

proc constructObject*(s: var YamlStream, c: ConstructionContext,
                      result: var bool)
    {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a bool value from a YAML scalar
  constructScalarItem(s, item, bool):
    case guessType(item.scalarContent)
    of yTypeBoolTrue: result = true
    of yTypeBoolFalse: result = false
    else:
      raise s.constructionError("Cannot construct to bool: " &
          escape(item.scalarContent))

proc representObject*(value: bool, ts: TagStyle, c: SerializationContext,
    tag: TagId)  {.raises: [].} =
  ## represents a bool value as a YAML scalar
  c.put(scalarEvent(if value: "y" else: "n", tag, yAnchorNone))

proc constructObject*(s: var YamlStream, c: ConstructionContext,
                      result: var char)
    {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a char value from a YAML scalar
  constructScalarItem(s, item, char):
    if item.scalarContent.len != 1:
      raise s.constructionError("Cannot construct to char (length != 1): " &
          escape(item.scalarContent))
    else: result = item.scalarContent[0]

proc representObject*(value: char, ts: TagStyle, c: SerializationContext,
    tag: TagId) {.raises: [].} =
  ## represents a char value as YAML scalar
  c.put(scalarEvent("" & value, tag, yAnchorNone))

proc yamlTag*(T: typedesc[Time]): TagId {.inline, raises: [].} = yTagTimestamp

proc constructObject*(s: var YamlStream, c: ConstructionContext,
                      result: var Time)
    {.raises: [YamlConstructionError, YamlStreamError].} =
  constructScalarItem(s, item, Time):
    if guessType(item.scalarContent) == yTypeTimestamp:
      var
        tmp = newStringOfCap(60)
        pos = 8
        c: char
      while pos < item.scalarContent.len():
        c = item.scalarContent[pos]
        if c in {' ', '\t', 'T', 't'}: break
        inc(pos)
      if pos == item.scalarContent.len():
        tmp.add(item.scalarContent)
        tmp.add("T00:00:00+00:00")
      else:
        tmp.add(item.scalarContent[0 .. pos - 1])
        if c in {' ', '\t'}:
          while true:
            inc(pos)
            c = item.scalarContent[pos]
            if c notin {' ', '\t'}: break
        else: inc(pos)
        tmp.add("T")
        let timeStart = pos
        inc(pos, 7)
        var fractionStart = -1
        while pos < item.scalarContent.len():
          c = item.scalarContent[pos]
          if c in {'+', '-', 'Z', ' ', '\t'}: break
          elif c == '.': fractionStart = pos
          inc(pos)
        if fractionStart == -1:
          tmp.add(item.scalarContent[timeStart .. pos - 1])
        else:
          tmp.add(item.scalarContent[timeStart .. fractionStart - 1])
        if c in {'Z', ' ', '\t'}: tmp.add("+00:00")
        else:
          tmp.add(c)
          inc(pos)
          let tzStart = pos
          inc(pos)
          if pos < item.scalarContent.len() and item.scalarContent[pos] != ':':
            inc(pos)
          if pos - tzStart == 1: tmp.add('0')
          tmp.add(item.scalarContent[tzStart .. pos - 1])
          if pos == item.scalarContent.len(): tmp.add(":00")
          elif pos + 2 == item.scalarContent.len():
            tmp.add(":0")
            tmp.add(item.scalarContent[pos + 1])
          else:
            tmp.add(item.scalarContent[pos .. pos + 2])
      let info = tmp.parse("yyyy-M-d'T'H:mm:sszzz")
      result = info.toTime()
    else:
      raise s.constructionError("Not a parsable timestamp: " &
          escape(item.scalarContent))

proc representObject*(value: Time, ts: TagStyle, c: SerializationContext,
                      tag: TagId) {.raises: [ValueError].} =
  let tmp = value.getGMTime()
  c.put(scalarEvent(tmp.format("yyyy-MM-dd'T'HH:mm:ss'Z'")))

proc yamlTag*[I](T: typedesc[seq[I]]): TagId {.inline, raises: [].} =
  let uri = nimTag("system:seq(" & safeTagUri(yamlTag(I)) & ')')
  result = lazyLoadTag(uri)

proc yamlTag*[I](T: typedesc[set[I]]): TagId {.inline, raises: [].} =
  let uri = nimTag("system:set(" & safeTagUri(yamlTag(I)) & ')')
  result = lazyLoadTag(uri)

proc constructObject*[T](s: var YamlStream, c: ConstructionContext,
                         result: var seq[T])
    {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a Nim seq from a YAML sequence
  let event = s.next()
  if event.kind != yamlStartSeq:
    raise s.constructionError("Expected sequence start")
  result = newSeq[T]()
  while s.peek().kind != yamlEndSeq:
    var item: T
    constructChild(s, c, item)
    result.add(item)
  discard s.next()

proc constructObject*[T](s: var YamlStream, c: ConstructionContext,
                         result: var set[T])
    {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a Nim seq from a YAML sequence
  let event = s.next()
  if event.kind != yamlStartSeq:
    raise s.constructionError("Expected sequence start")
  result = {}
  while s.peek().kind != yamlEndSeq:
    var item: T
    constructChild(s, c, item)
    result.incl(item)
  discard s.next()

proc representObject*[T](value: seq[T]|set[T], ts: TagStyle,
    c: SerializationContext, tag: TagId) =
  ## represents a Nim seq as YAML sequence
  let childTagStyle = if ts == tsRootOnly: tsNone else: ts
  c.put(startSeqEvent(tag))
  for item in value:
    representChild(item, childTagStyle, c)
  c.put(endSeqEvent())

proc yamlTag*[I, V](T: typedesc[array[I, V]]): TagId {.inline, raises: [].} =
  const rangeName = name(I)
  let uri = nimTag("system:array(" & rangeName[6..rangeName.high()] & ';' &
      safeTagUri(yamlTag(V)) & ')')
  result = lazyLoadTag(uri)

proc constructObject*[I, T](s: var YamlStream, c: ConstructionContext,
                         result: var array[I, T])
    {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a Nim array from a YAML sequence
  var event = s.next()
  if event.kind != yamlStartSeq:
    raise s.constructionError("Expected sequence start")
  for index in low(I)..high(I):
    event = s.peek()
    if event.kind == yamlEndSeq:
      raise s.constructionError("Too few array values")
    constructChild(s, c, result[index])
  event = s.next()
  if event.kind != yamlEndSeq:
    raise s.constructionError("Too many array values")

proc representObject*[I, T](value: array[I, T], ts: TagStyle,
    c: SerializationContext, tag: TagId) =
  ## represents a Nim array as YAML sequence
  let childTagStyle = if ts == tsRootOnly: tsNone else: ts
  c.put(startSeqEvent(tag))
  for item in value:
    representChild(item, childTagStyle, c)
  c.put(endSeqEvent())

proc yamlTag*[K, V](T: typedesc[Table[K, V]]): TagId {.inline, raises: [].} =
  try:
    let uri = nimTag("tables:Table(" & safeTagUri(yamlTag(K)) & ';' &
        safeTagUri(yamlTag(V)) & ")")
    result = lazyLoadTag(uri)
  except KeyError:
    # cannot happen (theoretically, you know)
    internalError("Unexpected KeyError")

proc constructObject*[K, V](s: var YamlStream, c: ConstructionContext,
                            result: var Table[K, V])
    {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a Nim Table from a YAML mapping
  let event = s.next()
  if event.kind != yamlStartMap:
    raise s.constructionError("Expected map start, got " & $event.kind)
  result = initTable[K, V]()
  while s.peek.kind != yamlEndMap:
    var
      key: K
      value: V
    constructChild(s, c, key)
    constructChild(s, c, value)
    if result.contains(key):
      raise s.constructionError("Duplicate table key!")
    result[key] = value
  discard s.next()

proc representObject*[K, V](value: Table[K, V], ts: TagStyle,
    c: SerializationContext, tag: TagId) =
  ## represents a Nim Table as YAML mapping
  let childTagStyle = if ts == tsRootOnly: tsNone else: ts
  c.put(startMapEvent(tag))
  for key, value in value.pairs:
    representChild(key, childTagStyle, c)
    representChild(value, childTagStyle, c)
  c.put(endMapEvent())

proc yamlTag*[K, V](T: typedesc[OrderedTable[K, V]]): TagId
    {.inline, raises: [].} =
  try:
    let uri = nimTag("tables:OrderedTable(" & safeTagUri(yamlTag(K)) & ';' &
        safeTagUri(yamlTag(V)) & ")")
    result = lazyLoadTag(uri)
  except KeyError:
    # cannot happen (theoretically, you know)
    internalError("Unexpected KeyError")

proc constructObject*[K, V](s: var YamlStream, c: ConstructionContext,
                            result: var OrderedTable[K, V])
    {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a Nim OrderedTable from a YAML mapping
  var event = s.next()
  if event.kind != yamlStartSeq:
    raise s.constructionError("Expected seq start, got " & $event.kind)
  result = initOrderedTable[K, V]()
  while s.peek.kind != yamlEndSeq:
    var
      key: K
      value: V
    event = s.next()
    if event.kind != yamlStartMap:
      raise s.constructionError("Expected map start, got " & $event.kind)
    constructChild(s, c, key)
    constructChild(s, c, value)
    event = s.next()
    if event.kind != yamlEndMap:
      raise s.constructionError("Expected map end, got " & $event.kind)
    if result.contains(key):
      raise s.constructionError("Duplicate table key!")
    result.add(key, value)
  discard s.next()

proc representObject*[K, V](value: OrderedTable[K, V], ts: TagStyle,
    c: SerializationContext, tag: TagId) =
  let childTagStyle = if ts == tsRootOnly: tsNone else: ts
  c.put(startSeqEvent(tag))
  for key, value in value.pairs:
    c.put(startMapEvent())
    representChild(key, childTagStyle, c)
    representChild(value, childTagStyle, c)
    c.put(endMapEvent())
  c.put(endSeqEvent())

proc yamlTag*(T: typedesc[object|enum]):
    TagId {.inline, raises: [].} =
  var uri = nimTag("custom:" & (typetraits.name(type(T))))
  try: serializationTagLibrary.tags[uri]
  except KeyError: serializationTagLibrary.registerUri(uri)

proc yamlTag*(T: typedesc[tuple]):
    TagId {.inline, raises: [].} =
  var
    i: T
    uri = nimTag("tuple(")
    first = true
  for name, value in fieldPairs(i):
    if first: first = false
    else: uri.add(",")
    uri.add(safeTagUri(yamlTag(type(value))))
  uri.add(")")
  try: serializationTagLibrary.tags[uri]
  except KeyError: serializationTagLibrary.registerUri(uri)

iterator recListItems(n: NimNode): NimNode =
  if n.kind == nnkRecList:
    for item in n.children: yield item
  else: yield n

proc recListLen(n: NimNode): int {.compileTime.} =
  if n.kind == nnkRecList: result = n.len
  else: result = 1

proc recListNode(n: NimNode): NimNode {.compileTime.} =
  if n.kind == nnkRecList: result = n[0]
  else: result = n

proc fieldCount(t: NimNode): int {.compiletime.} =
   result = 0
   let tDesc = getType(getType(t)[1])
   if tDesc.kind == nnkBracketExpr:
      # tuple
      result = tDesc.len - 1
   else:
      # object
      for child in tDesc[2].children:
         inc(result)
         if child.kind == nnkRecCase:
            for bIndex in 1..<len(child):
               var increment = 0
               case child[bIndex].kind
               of nnkOfBranch:
                  let content = child[bIndex][len(child[bIndex])-1]
                  # We cannot assume that child[bIndex][1] is a RecList due to
                  # a one-liner like 'of akDog: barkometer' not resulting in a
                  # RecList but in an Ident node.
                  case content.kind
                  of nnkRecList:
                     increment = len(content)
                  else:
                     increment = 1
               of nnkElse:
                  # Same goes for the else branch.
                  case child[bIndex][0].kind
                  of nnkRecList:
                     increment = len(child[bIndex][0])
                  else:
                     increment = 1
               else:
                  internalError("Unexpected child kind: " & $child[bIndex].kind)
               inc(result, increment)


macro matchMatrix(t: typedesc): untyped =
  result = newNimNode(nnkBracket)
  let numFields = fieldCount(t)
  for i in 0..<numFields:
    result.add(newLit(false))

proc checkDuplicate(s: NimNode, tName: string, name: string, i: int,
                    matched: NimNode): NimNode {.compileTime.} =
  result = newIfStmt((newNimNode(nnkBracketExpr).add(matched, newLit(i)),
      newNimNode(nnkRaiseStmt).add(newCall(bindSym("constructionError"), s,
      newLit("While constructing " & tName & ": Duplicate field: " &
      escape(name))))))

proc addDefaultOr(tName: string, i: int, o: NimNode,
    field, elseBranch: NimNode): NimNode {.compileTime.} =
  result = quote do:
    when `o`.`field`.hasCustomPragma(defaultVal):
      `o`.`field` = `o`.`field`.getCustomPragmaVal(defaultVal)
    else: `elseBranch`

proc hasSparse(t: typedesc): bool {.compileTime.} =
  when compiles(t.hasCustomPragma(sparse)):
    return t.hasCustomPragma(sparse)
  else:
    return false

proc getOptionInner(fType: NimNode): NimNode {.compileTime.} =
  if fType.kind == nnkBracketExpr and len(fType) == 2 and
      fType[1].kind == nnkSym:
    return newIdentNode($fType[1])
  else: return nil

proc checkMissing(s: NimNode, t: NimNode, tName: string, field: NimNode,
                  i: int, matched, o: NimNode):
    NimNode {.compileTime.} =
  let
    fType = getTypeInst(field)
    fName = escape($field)
    optionInner = getOptionInner(fType)
  result = quote do:
    when not `o`.`field`.hasCustomPragma(transient):
      if not `matched`[`i`]:
        when `o`.`field`.hasCustomPragma(defaultVal):
          `o`.`field` = `o`.`field`.getCustomPragmaVal(defaultVal)
        elif hasSparse(`t`) and `o`.`field` is Option:
          `o`.`field` = none(`optionInner`)
        else:
          raise constructionError(`s`, "While constructing " & `tName` &
              ": Missing field: " & `fName`)

proc markAsFound(i: int, matched: NimNode): NimNode {.compileTime.} =
  newAssignment(newNimNode(nnkBracketExpr).add(matched, newLit(i)),
      newLit(true))

proc ifNotTransient(o, field: NimNode,
    content: openarray[NimNode],
    elseError: bool, s: NimNode, tName, fName: string = ""):
    NimNode {.compileTime.} =
  var stmts = newStmtList(content)
  if elseError:
    result = quote do:
      when `o`.`field`.hasCustomPragma(transient):
        raise constructionError(`s`, "While constructing " & `tName` &
            ": Field \"" & `fName` & "\" is transient and may not occur in input")
      else:
        `stmts`
  else:
    result = quote do:
      when not `o`.`field`.hasCustomPragma(transient):
        `stmts`

macro ensureAllFieldsPresent(s: YamlStream, t: typedesc, o: typed,
                             matched: typed) =
  result = newStmtList()
  let
    tDecl = getType(t)
    tName = $tDecl[1]
    tDesc = getType(tDecl[1])
  var field = 0
  for child in tDesc[2].children:
    if child.kind == nnkRecCase:
      result.add(checkMissing(
          s, t, tName, child[0], field, matched, o))
      for bIndex in 1 .. len(child) - 1:
        let discChecks = newStmtList()
        var
          curValues = newNimNode(nnkCurly)
          recListIndex = 0
        case child[bIndex].kind
        of nnkOfBranch:
          while recListIndex < child[bIndex].len - 1:
            expectKind(child[bIndex][recListIndex], nnkIntLit)
            curValues.add(child[bIndex][recListIndex])
            inc(recListIndex)
        of nnkElse: discard
        else: internalError("Unexpected child kind: " & $child[bIndex].kind)
        for item in child[bIndex][recListIndex].recListItems:
          inc(field)
          discChecks.add(checkMissing(
              s, t, tName, item, field, matched, o))
        result.add(newIfStmt((infix(newDotExpr(o, newIdentNode($child[0])),
            "in", curValues), discChecks)))
    else:
      result.add(checkMissing(s, t, tName, child, field, matched, o))
    inc(field)

macro constructFieldValue(t: typedesc, stream: untyped,
                          context: untyped, name: untyped, o: untyped,
                          matched: untyped, failOnUnknown: bool) =
  let
    tDecl = getType(t)
    tName = $tDecl[1]
    tDesc = getType(tDecl[1])
  result = newStmtList()
  var caseStmt = newNimNode(nnkCaseStmt).add(name)
  var fieldIndex = 0
  for child in tDesc[2].children:
    if child.kind == nnkRecCase:
      let
        discriminant = newDotExpr(o, newIdentNode($child[0]))
        discType = newCall("type", discriminant)
      var disOb = newNimNode(nnkOfBranch).add(newStrLitNode($child[0]))
      var objConstr = newNimNode(nnkObjConstr).add(newCall("type", o))
      objConstr.add(newColonExpr(newIdentNode($child[0]), newIdentNode(
          "value")))
      for otherChild in tDesc[2].children:
        if otherChild == child:
          continue
        if otherChild.kind != nnkSym:
          error("Unexpected kind of field '" & $otherChild[0] &
              "': " & $otherChild.kind)
        objConstr.add(newColonExpr(newIdentNode($otherChild), newDotExpr(o,
            newIdentNode($otherChild))))
      disOb.add(newStmtList(
          checkDuplicate(stream, tName, $child[0], fieldIndex, matched),
          newNimNode(nnkVarSection).add(
              newNimNode(nnkIdentDefs).add(
                  newIdentNode("value"), discType, newEmptyNode())),
          newCall("constructChild", stream, context, newIdentNode("value")),
          newAssignment(o, objConstr),
          markAsFound(fieldIndex, matched)))
      caseStmt.add(disOb)
      var alreadyUsedSet = newNimNode(nnkCurly)
      for bIndex in 1 .. len(child) - 1:
        var recListIndex = 0
        var discTest: NimNode
        case child[bIndex].kind
        of nnkOfBranch:
          discTest = newNimNode(nnkCurly)
          while recListIndex < child[bIndex].len - 1:
            yAssert child[bIndex][recListIndex].kind == nnkIntLit
            discTest.add(child[bIndex][recListIndex])
            alreadyUsedSet.add(child[bIndex][recListIndex])
            inc(recListIndex)
          discTest = infix(discriminant, "in", discTest)
        of nnkElse:
          discTest = infix(discriminant, "notin", alreadyUsedSet)
        else:
          internalError("Unexpected child kind: " & $child[bIndex].kind)

        for item in child[bIndex][recListIndex].recListItems:
          inc(fieldIndex)
          yAssert item.kind == nnkSym
          var ob = newNimNode(nnkOfBranch).add(newStrLitNode($item))
          let field = newDotExpr(o, newIdentNode($item))
          var ifStmt = newIfStmt((cond: discTest, body: newStmtList(
              newCall("constructChild", stream, context, field))))
          ifStmt.add(newNimNode(nnkElse).add(newNimNode(nnkRaiseStmt).add(
              newCall(bindSym("constructionError"), stream,
              infix(newStrLitNode("Field " & $item & " not allowed for " &
              $child[0] & " == "), "&", prefix(discriminant, "$"))))))
          ob.add(ifNotTransient(o, item,
              [checkDuplicate(stream, tName, $item, fieldIndex, matched),
              ifStmt, markAsFound(fieldIndex, matched)], true, stream, tName,
              $item))
          caseStmt.add(ob)
    else:
      yAssert child.kind == nnkSym
      var ob = newNimNode(nnkOfBranch).add(newStrLitNode($child))
      let field = newDotExpr(o, newIdentNode($child))
      ob.add(ifNotTransient(o, child,
          [checkDuplicate(stream, tName, $child, fieldIndex, matched),
          newCall("constructChild", stream, context, field),
          markAsFound(fieldIndex, matched)], true, stream, tName, $child))
      caseStmt.add(ob)
    inc(fieldIndex)
  caseStmt.add(newNimNode(nnkElse).add(newNimNode(nnkWhenStmt).add(
    newNimNode(nnkElifBranch).add(failOnUnknown,
      newNimNode(nnkRaiseStmt).add(
        newCall(bindSym("constructionError"), stream,
        infix(newLit("While constructing " & tName & ": Unknown field: "), "&",
        newCall(bindSym("escape"), name))))))))
  result.add(caseStmt)

proc isVariantObject(t: NimNode): bool {.compileTime.} =
  var tDesc = getType(t)
  if tDesc.kind == nnkBracketExpr: tDesc = getType(tDesc[1])
  if tDesc.kind != nnkObjectTy:
    return false
  for child in tDesc[2].children:
    if child.kind == nnkRecCase: return true
  return false

proc hasIgnore(t: typedesc): bool {.compileTime.} =
  when compiles(t.hasCustomPragma(ignore)):
    return t.hasCustomPragma(ignore)
  else:
    return false

proc constructObjectDefault*[O: object|tuple](
    s: var YamlStream, c: ConstructionContext, result: var O)
    {.raises: [YamlConstructionError, YamlStreamError].} =
  ## Constructs a Nim object or tuple from a YAML mapping.
  ## This is the default implementation for custom objects and tuples and should
  ## not be redefined. If you are adding a custom constructObject()
  ## implementation, you can use this proc to call the default implementation
  ## within it.
  var matched = matchMatrix(O)
  var e = s.next()
  const
    startKind = when isVariantObject(getType(O)): yamlStartSeq else: yamlStartMap
    endKind = when isVariantObject(getType(O)): yamlEndSeq else: yamlEndMap
  if e.kind != startKind:
    raise s.constructionError("While constructing " &
        typetraits.name(O) & ": Expected " & $startKind & ", got " & $e.kind)
  when hasIgnore(O):
    const ignoredKeyList = O.getCustomPragmaVal(ignore)
    const failOnUnknown = len(ignoredKeyList) > 0
  else:
    const failOnUnknown = true
  while s.peek.kind != endKind:
    e = s.next()
    when isVariantObject(getType(O)):
      if e.kind != yamlStartMap:
        raise s.constructionError("Expected single-pair map, got " & $e.kind)
      e = s.next()
    if e.kind != yamlScalar:
      raise s.constructionError("Expected field name, got " & $e.kind)
    let name = e.scalarContent
    when result is tuple:
      var i = 0
      var found = false
      for fname, value in fieldPairs(result):
        if fname == name:
          if matched[i]:
            raise s.constructionError("While constructing " &
                typetraits.name(O) & ": Duplicate field: " & escape(name))
          constructChild(s, c, value)
          matched[i] = true
          found = true
          break
        inc(i)
      when failOnUnknown:
        if not found:
          raise s.constructionError("While constructing " &
              typetraits.name(O) & ": Unknown field: " & escape(name))
    else:
      when hasIgnore(O) and failOnUnknown:
        if name notin ignoredKeyList:
          constructFieldValue(O, s, c, name, result, matched, failOnUnknown)
        else:
          e = s.next()
          var depth = int(e.kind in {yamlStartMap, yamlStartSeq})
          while depth > 0:
            case s.next().kind
            of yamlStartMap, yamlStartSeq: inc(depth)
            of yamlEndMap, yamlEndSeq: dec(depth)
            of yamlScalar: discard
            else: internalError("Unexpected event kind.")
      else:
        constructFieldValue(O, s, c, name, result, matched, failOnUnknown)
    when isVariantObject(getType(O)):
      e = s.next()
      if e.kind != yamlEndMap:
        raise s.constructionError("Expected end of single-pair map, got " &
            $e.kind)
  discard s.next()
  when result is tuple:
    var i = 0
    for fname, value in fieldPairs(result):
      if not matched[i]:
        raise s.constructionError("While constructing " &
            typetraits.name(O) & ": Missing field: " & escape(fname))
      inc(i)
  else: ensureAllFieldsPresent(s, O, result, matched)

proc constructObject*[O: object|tuple](
    s: var YamlStream, c: ConstructionContext, result: var O)
    {.raises: [YamlConstructionError, YamlStreamError].} =
  ## Overridable default implementation for custom object and tuple types
  constructObjectDefault(s, c, result)

macro genRepresentObject(t: typedesc, value, childTagStyle: typed) =
  result = newStmtList()
  let
    tDecl = getType(t)
    tDesc = getType(tDecl[1])
    isVO  = isVariantObject(t)
  var fieldIndex = 0'i16
  for child in tDesc[2].children:
    if child.kind == nnkRecCase:
      let
        fieldName = $child[0]
        fieldAccessor = newDotExpr(value, newIdentNode(fieldName))
      result.add(quote do:
        c.put(startMapEvent(yTagQuestionMark, yAnchorNone))
        c.put(scalarEvent(`fieldName`, if `childTagStyle` == tsNone:
            yTagQuestionMark else: yTagNimField, yAnchorNone))
        representChild(`fieldAccessor`, `childTagStyle`, c)
        c.put(endMapEvent())
      )
      let enumName = $getTypeInst(child[0])
      var caseStmt = newNimNode(nnkCaseStmt).add(fieldAccessor)
      for bIndex in 1 .. len(child) - 1:
        var curBranch: NimNode
        var recListIndex = 0
        case child[bIndex].kind
        of nnkOfBranch:
          curBranch = newNimNode(nnkOfBranch)
          while recListIndex < child[bIndex].len - 1:
            expectKind(child[bIndex][recListIndex], nnkIntLit)
            curBranch.add(newCall(enumName, newLit(child[bIndex][recListIndex].intVal)))
            inc(recListIndex)
        of nnkElse:
          curBranch = newNimNode(nnkElse)
        else:
          internalError("Unexpected child kind: " & $child[bIndex].kind)
        var curStmtList = newStmtList()
        if child[bIndex][recListIndex].recListLen > 0:
          for item in child[bIndex][recListIndex].recListItems():
            inc(fieldIndex)
            let
              name = $item
              itemAccessor = newDotExpr(value, newIdentNode(name))
            curStmtList.add(quote do:
              when not `itemAccessor`.hasCustomPragma(transient):
                c.put(startMapEvent(yTagQuestionMark, yAnchorNone))
                c.put(scalarEvent(`name`, if `childTagStyle` == tsNone:
                    yTagQuestionMark else: yTagNimField, yAnchorNone))
                representChild(`itemAccessor`, `childTagStyle`, c)
                c.put(endMapEvent())
            )
        else:
          curStmtList.add(newNimNode(nnkDiscardStmt).add(newEmptyNode()))
        curBranch.add(curStmtList)
        caseStmt.add(curBranch)
      result.add(caseStmt)
    else:
      let
        name = $child
        childAccessor = newDotExpr(value, newIdentNode(name))
      result.add(quote do:
        when not `childAccessor`.hasCustomPragma(transient):
          when bool(`isVO`): c.put(startMapEvent(yTagQuestionMark, yAnchorNone))
          c.put(scalarEvent(`name`, if `childTagStyle` == tsNone:
              yTagQuestionMark else: yTagNimField, yAnchorNone))
          representChild(`childAccessor`, `childTagStyle`, c)
          when bool(`isVO`): c.put(endMapEvent())
      )
    inc(fieldIndex)

proc representObject*[O: object](value: O, ts: TagStyle,
    c: SerializationContext, tag: TagId) =
  ## represents a Nim object or tuple as YAML mapping
  let childTagStyle = if ts == tsRootOnly: tsNone else: ts
  when isVariantObject(getType(O)): c.put(startSeqEvent(tag, yAnchorNone))
  else: c.put(startMapEvent(tag, yAnchorNone))
  genRepresentObject(O, value, childTagStyle)
  when isVariantObject(getType(O)): c.put(endSeqEvent())
  else: c.put(endMapEvent())

proc representObject*[O: tuple](value: O, ts: TagStyle,
    c: SerializationContext, tag: TagId) =
  let childTagStyle = if ts == tsRootOnly: tsNone else: ts
  var fieldIndex = 0'i16
  c.put(startMapEvent(tag, yAnchorNone))
  for name, fvalue in fieldPairs(value):
    c.put(scalarEvent(name, if childTagStyle == tsNone:
          yTagQuestionMark else: yTagNimField, yAnchorNone))
    representChild(fvalue, childTagStyle, c)
    inc(fieldIndex)
  c.put(endMapEvent())

proc constructObject*[O: enum](s: var YamlStream, c: ConstructionContext,
                               result: var O)
    {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a Nim enum from a YAML scalar
  let e = s.next()
  if e.kind != yamlScalar:
    raise s.constructionError("Expected scalar, got " & $e.kind)
  try: result = parseEnum[O](e.scalarContent)
  except ValueError:
    var ex = s.constructionError("Cannot parse '" &
        escape(e.scalarContent) & "' as " & type(O).name)
    ex.parent = getCurrentException()
    raise ex

proc representObject*[O: enum](value: O, ts: TagStyle,
    c: SerializationContext, tag: TagId) {.raises: [].} =
  ## represents a Nim enum as YAML scalar
  c.put(scalarEvent($value, tag, yAnchorNone))

proc yamlTag*[O](T: typedesc[ref O]): TagId {.inline, raises: [].} = yamlTag(O)

macro constructImplicitVariantObject(s, c, r, possibleTagIds: untyped,
                                     t: typedesc) =
  let tDesc = getType(getType(t)[1])
  yAssert tDesc.kind == nnkObjectTy
  let recCase = tDesc[2][0]
  yAssert recCase.kind == nnkRecCase
  result = newNimNode(nnkIfStmt)
  for i in 1 .. recCase.len - 1:
    yAssert recCase[i].kind == nnkOfBranch
    var branch = newNimNode(nnkElifBranch)
    var branchContent = newStmtList(newAssignment(r,
        newNimNode(nnkObjConstr).add(
          newCall("type", r),
          newColonExpr(newIdentNode($recCase[0]), recCase[i][0])
    )))
    case recCase[i][1].recListLen
    of 0:
      branch.add(infix(newIdentNode("yTagNull"), "in", possibleTagIds))
      branchContent.add(newNimNode(nnkDiscardStmt).add(newCall("next", s)))
    of 1:
      let field = newDotExpr(r, newIdentNode($recCase[i][1].recListNode))
      branch.add(infix(
          newCall("yamlTag", newCall("type", field)), "in", possibleTagIds))
      branchContent.add(newCall("constructChild", s, c, field))
    else:
      block:
        internalError("Too many children: " & $recCase[i][1].recListlen)
    branch.add(branchContent)
    result.add(branch)
  let raiseStmt = newNimNode(nnkRaiseStmt).add(
      newCall(bindSym("constructionError"), s,
      infix(newStrLitNode("This value type does not map to any field in " &
                          getTypeImpl(t)[1].repr & ": "), "&",
            newCall("uri", newIdentNode("serializationTagLibrary"),
              newNimNode(nnkBracketExpr).add(possibleTagIds, newIntLitNode(0)))
      )
  ))
  result.add(newNimNode(nnkElse).add(newNimNode(nnkTryStmt).add(
      newStmtList(raiseStmt), newNimNode(nnkExceptBranch).add(
        newIdentNode("KeyError"),
        newNimNode(nnkDiscardStmt).add(newEmptyNode())
  ))))

proc isImplicitVariantObject(t: typedesc): bool {.compileTime.} =
  when compiles(t.hasCustomPragma(implicit)):
    return t.hasCustomPragma(implicit)
  else:
    return false

proc canBeImplicit(t: typedesc): bool {.compileTime.} =
  let tDesc = getType(t)
  if tDesc.kind != nnkObjectTy: return false
  if tDesc[2].len != 1: return false
  if tDesc[2][0].kind != nnkRecCase: return false
  var foundEmptyBranch = false
  for i in 1.. tDesc[2][0].len - 1:
    case tDesc[2][0][i][1].recListlen # branch contents
    of 0:
      if foundEmptyBranch: return false
      else: foundEmptyBranch = true
    of 1: discard
    else: return false
  return true

proc constructChild*[T](s: var YamlStream, c: ConstructionContext,
                        result: var T) =
  let item = s.peek()
  when isImplicitVariantObject(T):
    when not canBeImplicit(T):
      {. fatal: "This type cannot be marked as implicit" .}
    var possibleTagIds = newSeq[TagId]()
    case item.kind
    of yamlScalar:
      case item.scalarTag
      of yTagQuestionMark:
        case guessType(item.scalarContent)
        of yTypeInteger:
          possibleTagIds.add([yamlTag(int), yamlTag(int8), yamlTag(int16),
                              yamlTag(int32), yamlTag(int64)])
          if item.scalarContent[0] != '-':
            possibleTagIds.add([yamlTag(uint), yamlTag(uint8), yamlTag(uint16),
                                yamlTag(uint32), yamlTag(uint64)])
        of yTypeFloat, yTypeFloatInf, yTypeFloatNaN:
          possibleTagIds.add([yamlTag(float), yamlTag(float32),
                              yamlTag(float64)])
        of yTypeBoolTrue, yTypeBoolFalse:
          possibleTagIds.add(yamlTag(bool))
        of yTypeNull:
          raise s.constructionError("not implemented!")
        of yTypeUnknown:
          possibleTagIds.add(yamlTag(string))
        of yTypeTimestamp:
          possibleTagIds.add(yamlTag(Time))
      of yTagExclamationMark:
        possibleTagIds.add(yamlTag(string))
      else:
        possibleTagIds.add(item.scalarTag)
    of yamlStartMap:
      if item.mapTag in [yTagQuestionMark, yTagExclamationMark]:
        raise s.constructionError(
            "Complex value of implicit variant object type must have a tag.")
      possibleTagIds.add(item.mapTag)
    of yamlStartSeq:
      if item.seqTag in [yTagQuestionMark, yTagExclamationMark]:
        raise s.constructionError(
            "Complex value of implicit variant object type must have a tag.")
      possibleTagIds.add(item.seqTag)
    else: internalError("Unexpected item kind: " & $item.kind)
    constructImplicitVariantObject(s, c, result, possibleTagIds, T)
  else:
    case item.kind
    of yamlScalar:
      if item.scalarTag notin [yTagQuestionMark, yTagExclamationMark,
                               yamlTag(T)]:
        raise s.constructionError("Wrong tag for " & typetraits.name(T))
      elif item.scalarAnchor != yAnchorNone:
        raise s.constructionError("Anchor on non-ref type")
    of yamlStartMap:
      if item.mapTag notin [yTagQuestionMark, yamlTag(T)]:
        raise s.constructionError("Wrong tag for " & typetraits.name(T))
      elif item.mapAnchor != yAnchorNone:
        raise s.constructionError("Anchor on non-ref type")
    of yamlStartSeq:
      if item.seqTag notin [yTagQuestionMark, yamlTag(T)]:
        raise s.constructionError("Wrong tag for " & typetraits.name(T))
      elif item.seqAnchor != yAnchorNone:
        raise s.constructionError("Anchor on non-ref type")
    else: internalError("Unexpected item kind: " & $item.kind)
    constructObject(s, c, result)

proc constructChild*(s: var YamlStream, c: ConstructionContext,
                     result: var string) =
  let item = s.peek()
  if item.kind == yamlScalar:
    if item.scalarTag notin
        [yTagQuestionMark, yTagExclamationMark, yamlTag(string)]:
      raise s.constructionError("Wrong tag for string")
    elif item.scalarAnchor != yAnchorNone:
      raise s.constructionError("Anchor on non-ref type")
  constructObject(s, c, result)

proc constructChild*[T](s: var YamlStream, c: ConstructionContext,
                        result: var seq[T]) =
  let item = s.peek()
  if item.kind == yamlStartSeq:
    if item.seqTag notin [yTagQuestionMark, yamlTag(seq[T])]:
      raise s.constructionError("Wrong tag for " & typetraits.name(seq[T]))
    elif item.seqAnchor != yAnchorNone:
      raise s.constructionError("Anchor on non-ref type")
  constructObject(s, c, result)

proc constructChild*[T](s: var YamlStream, c: ConstructionContext,
    result: var Option[T]) =
  ## constructs an optional value. A value with a !!null tag will be loaded
  ## an empty value.
  let event = s.peek()
  if event.kind == yamlScalar and event.scalarTag == yTagNull:
    result = none(T)
    discard s.next()
  else:
    var inner: T
    constructChild(s, c, inner)
    result = some(inner)

when defined(JS):
  # in JS, Time is a ref type. Therefore, we need this specialization so that
  # it is not handled by the general ref-type handler.
  proc constructChild*(s: var YamlStream, c: ConstructionContext,
                       result: var Time) =
    let e = s.peek()
    if e.kind == yamlScalar:
      if e.scalarTag notin [yTagQuestionMark, yTagTimestamp]:
        raise s.constructionError("Wrong tag for Time")
      elif guessType(e.scalarContent) != yTypeTimestamp:
        raise s.constructionError("Invalid timestamp")
      elif e.scalarAnchor != yAnchorNone:
        raise s.constructionError("Anchor on non-ref type")
      constructObject(s, c, result)
    else:
      raise s.constructionError("Unexpected structure, expected timestamp")

proc constructChild*[O](s: var YamlStream, c: ConstructionContext,
                        result: var ref O) =
  var e = s.peek()
  if e.kind == yamlScalar:
    if e.scalarTag == yTagNull or (e.scalarTag == yTagQuestionMark and
        guessType(e.scalarContent) == yTypeNull):
      result = nil
      discard s.next()
      return
  elif e.kind == yamlAlias:
    when defined(JS):
      {.emit: [result, """ = """, c, """.refs.get(""", e.aliasTarget, """);"""].}
    else:
       result = cast[ref O](c.refs.getOrDefault(e.aliasTarget))
    discard s.next()
    return
  new(result)
  template removeAnchor(anchor: var AnchorId) {.dirty.} =
    if anchor != yAnchorNone:
      when defined(JS):
        {.emit: [c, """.refs.set(""", anchor, """, """, result, """);"""].}
      else:
        yAssert(not c.refs.hasKey(anchor))
        c.refs[anchor] = cast[pointer](result)
      anchor = yAnchorNone

  case e.kind
  of yamlScalar: removeAnchor(e.scalarAnchor)
  of yamlStartMap: removeAnchor(e.mapAnchor)
  of yamlStartSeq: removeAnchor(e.seqAnchor)
  else: internalError("Unexpected event kind: " & $e.kind)
  s.peek = e
  try: constructChild(s, c, result[])
  except YamlConstructionError as e:
    raise e
  except YamlStreamError as e:
    raise e
  except Exception:
    var e = newException(YamlStreamError, getCurrentExceptionMsg())
    e.parent = getCurrentException()
    raise e

proc representChild*(value: string, ts: TagStyle, c: SerializationContext) =
  let tag = presentTag(string, ts)
  representObject(value, ts, c,
                  if tag == yTagQuestionMark and guessType(value) != yTypeUnknown:
                    yTagExclamationMark
                  else:
                    tag)

proc representChild*[T](value: seq[T], ts: TagStyle, c: SerializationContext) =
  representObject(value, ts, c, presentTag(seq[T], ts))

proc representChild*[O](value: ref O, ts: TagStyle, c: SerializationContext) =
  if isNil(value): c.put(scalarEvent("~", yTagNull))
  elif c.style == asNone: representChild(value[], ts, c)
  else:
    var val: AnchorId
    when defined(JS):
      {.emit: ["""
      if (""", c, """.refs.has(""", value, """) {
        """, val, """ = """, c, """.refs.get(""", value, """);
        if (val == """, yAnchorNone, ") {"].}
      val = c.nextAnchorId
      {.emit: [c, """.refs.set(""", value, """, """, val, """);"""].}
      c.nextAnchorId = AnchorId(int(c.nextAnchorId) + 1)
      {.emit: "}".}
      c.put(aliasEvent(val))
      return
    else:
      let p = cast[pointer](value)
      if c.refs.hasKey(p):
        val = c.refs.getOrDefault(p)
        if val == yAnchorNone:
          val = c.nextAnchorId
          c.refs[p] = val
          c.nextAnchorId = AnchorId(int(c.nextAnchorId) + 1)
        c.put(aliasEvent(val))
        return
    if c.style == asAlways:
      val = c.nextAnchorId
      when defined(JS):
        {.emit: [c, ".refs.set(", p, ", ", val, ");"].}
      else: c.refs[p] = val
      c.nextAnchorId = AnchorId(int(val) + 1)
    else: c.refs[p] = yAnchorNone
    let
      a = if c.style == asAlways: val else: cast[AnchorId](p)
      childTagStyle = if ts == tsAll: tsAll else: tsRootOnly
      origPut = c.put
    c.put = proc(e: YamlStreamEvent) =
      var ex = e
      case ex.kind
      of yamlStartMap:
        ex.mapAnchor = a
        if ts == tsNone: ex.mapTag = yTagQuestionMark
      of yamlStartSeq:
        ex.seqAnchor = a
        if ts == tsNone: ex.seqTag = yTagQuestionMark
      of yamlScalar:
        ex.scalarAnchor = a
        if ts == tsNone and guessType(ex.scalarContent) != yTypeNull:
          ex.scalarTag = yTagQuestionMark
      else: discard
      c.put = origPut
      c.put(ex)
    representChild(value[], childTagStyle, c)

proc representChild*[T](value: Option[T], ts: TagStyle,
    c: SerializationContext) =
  ## represents an optional value. If the value is missing, a !!null scalar
  ## will be produced.
  if value.isSome:
    representChild(value.get(), ts, c)
  else:
    let childTagStyle = if ts == tsRootOnly: tsNone else: ts
    c.put(scalarEvent("~", yTagNull))

proc representChild*[O](value: O, ts: TagStyle,
                        c: SerializationContext) =
  when isImplicitVariantObject(O):
    # todo: this would probably be nicer if constructed with a macro
    var count = 0
    for name, field in fieldPairs(value):
      if count > 0:
        representChild(field, if ts == tsAll: tsAll else: tsRootOnly, c)
      inc(count)
    if count == 1: c.put(scalarEvent("~", yTagNull))
  else:
    representObject(value, ts, c,
        if ts == tsNone: yTagQuestionMark else: yamlTag(O))

proc construct*[T](s: var YamlStream, target: var T)
    {.raises: [YamlStreamError, YamlConstructionError].} =
  ## Constructs a Nim value from a YAML stream.
  var context = newConstructionContext()
  try:
    var e = s.next()
    yAssert(e.kind == yamlStartDoc)

    constructChild(s, context, target)
    e = s.next()
    yAssert(e.kind == yamlEndDoc)
  except YamlConstructionError:
    raise (ref YamlConstructionError)(getCurrentException())
  except YamlStreamError:
    let cur = getCurrentException()
    var e = newException(YamlStreamError, cur.msg)
    e.parent = cur.parent
    raise e
  except Exception:
    # may occur while calling s()
    var ex = newException(YamlStreamError, "")
    ex.parent = getCurrentException()
    raise ex

proc load*[K](input: Stream | string, target: var K)
    {.raises: [YamlConstructionError, IOError, YamlParserError].} =
  ## Loads a Nim value from a YAML character stream.
  var
    parser = newYamlParser(serializationTagLibrary)
    events = parser.parse(input)
  try: construct(events, target)
  except YamlStreamError:
    let e = (ref YamlStreamError)(getCurrentException())
    if e.parent of IOError: raise (ref IOError)(e.parent)
    elif e.parent of YamlParserError: raise (ref YamlParserError)(e.parent)
    else: internalError("Unexpected exception: " & $e.parent.name)

proc loadMultiDoc*[K](input: Stream | string, target: var seq[K]) =
  var
    parser = newYamlParser(serializationTagLibrary)
    events = parser.parse(input)
  try:
    while not events.finished():
      var item: K
      construct(events, item)
      target.add(item)
  except YamlConstructionError:
    var e = (ref YamlConstructionError)(getCurrentException())
    discard events.getLastTokenContext(e.line, e.column, e.lineContent)
    raise e
  except YamlStreamError:
    let e = (ref YamlStreamError)(getCurrentException())
    if e.parent of IOError: raise (ref IOError)(e.parent)
    elif e.parent of YamlParserError: raise (ref YamlParserError)(e.parent)
    else: internalError("Unexpected exception: " & $e.parent.name)

proc setAnchor(a: var AnchorId, c: var SerializationContext)
    {.inline.} =
  if a != yAnchorNone:
    when defined(JS):
      {.emit: [a, """ = """, c, """.refs.get(""", a, """);"""].}
    else:
      a = c.refs.getOrDefault(cast[pointer](a))

proc represent*[T](value: T, ts: TagStyle = tsRootOnly,
                   a: AnchorStyle = asTidy): YamlStream =
  ## Represents a Nim value as ``YamlStream``
  var bys = newBufferYamlStream()
  var context = newSerializationContext(a, proc(e: YamlStreamEvent) =
        bys.put(e)
      )
  bys.put(startDocEvent())
  representChild(value, ts, context)
  bys.put(endDocEvent())
  if a == asTidy:
    for item in bys.mitems():
      case item.kind
      of yamlStartMap: setAnchor(item.mapAnchor, context)
      of yamlStartSeq: setAnchor(item.seqAnchor, context)
      of yamlScalar: setAnchor(item.scalarAnchor, context)
      else: discard
  result = bys

proc dump*[K](value: K, target: Stream, tagStyle: TagStyle = tsRootOnly,
              anchorStyle: AnchorStyle = asTidy,
              options: PresentationOptions = defaultPresentationOptions)
    {.raises: [YamlPresenterJsonError, YamlPresenterOutputError,
               YamlStreamError].} =
  ## Dump a Nim value as YAML character stream.
  var events = represent(value,
      if options.style == psCanonical: tsAll else: tagStyle,
      if options.style == psJson: asNone else: anchorStyle)
  try: present(events, target, serializationTagLibrary, options)
  except YamlStreamError:
    internalError("Unexpected exception: " & $getCurrentException().name)

proc dump*[K](value: K, tagStyle: TagStyle = tsRootOnly,
              anchorStyle: AnchorStyle = asTidy,
              options: PresentationOptions = defaultPresentationOptions):
    string =
  ## Dump a Nim value as YAML into a string
  var events = represent(value,
      if options.style == psCanonical: tsAll else: tagStyle,
      if options.style == psJson: asNone else: anchorStyle)
  try: result = present(events, serializationTagLibrary, options)
  except YamlStreamError:
    internalError("Unexpected exception: " & $getCurrentException().name)
