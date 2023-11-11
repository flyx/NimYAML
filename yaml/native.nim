#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 - 2020 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ==================
## Module yaml/native
## ==================
##
## This module transforms native Nim values into a stream of YAML events,
## and vice versa. The procs of this module must be available for name binding
## when using the loading and dumping APIs. A NimYAML consumer would rarely
## call this module's procs directly. The main entry points to this API are
## ``construct`` and ``represent``; all other procs are usually called via
## instantiations of those two procs.
##
## You can extend the procs defined here with own procs to define custom
## handling for native types. See the documentation on the NimYAML
## website for more information.

import std / [tables, typetraits, strutils, macros, streams, times, parseutils, options]
import data, taglib, stream, private/internal, hints, annotations
export data, stream, macros, annotations, options
  # *something* in here needs externally visible `==`(x,y: AnchorId),
  # but I cannot figure out what. binding it would be the better option.

type
  TagStyle* = enum
    ## Whether object should be serialized with explicit tags.
    ##
    ## - ``tsNone``: No tags will be outputted unless necessary.
    ## - ``tsRootOnly``: A tag will only be outputted for the root tag and
    ##   where necessary.
    ## - ``tsAll``: Tags will be outputted for every object.
    tsNone, tsRootOnly, tsAll
  
  AnchorStyle* = enum
    ## How ref object should be serialized.
    ##
    ## - ``asNone``: No anchors will be written. Values present at
    ##   multiple places in the content that is serialized will be
    ##   duplicated at every occurrence. If the content is cyclic, this
    ##   will raise a YamlSerializationError.
    ## - ``asTidy``: Anchors will only be generated for objects that
    ##   actually occur more than once in the content to be serialized.
    ##   This is a bit slower and needs more memory than ``asAlways``.
    ## - ``asAlways``: Achors will be generated for every ref object in the
    ##   content that is serialized, regardless of whether the object is
    ##   referenced again afterwards.
    asNone, asTidy, asAlways

  SerializationOptions* = object
    tagStyle*   : TagStyle    = tsNone
    anchorStyle*: AnchorStyle = asTidy
    handles*    : seq[tuple[handle, uriPrefix: string]]

  SerializationContext* = object
    ## Context information for the process of serializing YAML from Nim values.
    refs: Table[pointer, tuple[a: Anchor, referenced: bool]]
    emitTag: bool
    nextAnchorId: string
    options*: SerializationOptions
    putImpl*: proc(ctx: var SerializationContext, e: Event) {.raises: [], closure.}
    overridingScalarStyle*: ScalarStyle = ssAny
    overridingCollectionStyle*: CollectionStyle = csAny

  ConstructionContext* = object
    ## Context information for the process of constructing Nim values from YAML.
    input*: YamlStream
    refs* : Table[Anchor, tuple[tag: Tag, p: pointer]]

  YamlConstructionError* = object of YamlLoadingError
    ## Exception that may be raised when constructing data objects from a
    ## `YamlStream <#YamlStream>`_. The fields ``line``, ``column`` and
    ## ``lineContent`` are only available if the costructing proc also does
    ## parsing, because otherwise this information is not available to the
    ## costruction proc.

  YamlSerializationError* = object of ValueError
    ## Exception that may be raised when serializing Nim values into YAML
    ## stream events.

proc put*(ctx: var SerializationContext, e: Event) {.raises: [].} =
  ctx.putImpl(ctx, e)

proc scalarStyleFor(ctx: var SerializationContext, t: typedesc): ScalarStyle =
  if ctx.overridingScalarStyle != ssAny:
    result = ctx.overridingScalarStyle
    ctx.overridingScalarStyle = ssAny
  else:
    when compiles(t.hasCustomPragma(scalar)):
      when t.hasCustomPragma(scalar):
        result = t.getCustomPragmaVal(scalar)
      else: result = ssAny
    else: result = ssAny
  ctx.overridingCollectionStyle = csAny

proc collectionStyleFor(ctx: var SerializationContext, t: typedesc): CollectionStyle =
  if ctx.overridingCollectionStyle != csAny:
    result = ctx.overridingCollectionStyle
    ctx.overridingCollectionStyle = csAny
  else:
    when compiles(t.hasCustomPragma(collection)):
      when t.hasCustomPragma(collection):
        result = t.getCustomPragmaVal(collection)
      else: result = csAny
    else: result = csAny
  ctx.overridingScalarStyle = ssAny

# forward declares

proc constructChild*[T](
  ctx   : var ConstructionContext,
  result: var T,
) {.raises: [YamlConstructionError, YamlStreamError].}
  ## Constructs an arbitrary Nim value from a part of a YAML stream.
  ## The stream will advance until after the finishing token that was used
  ## for constructing the value. The ``ConstructionContext`` is needed for
  ## potential child objects which may be refs.

proc constructChild*(
  ctx   : var ConstructionContext,
  result: var string,
) {.raises: [YamlConstructionError, YamlStreamError].}
  ## Constructs a Nim value that is a string from a part of a YAML stream.
  ## This specialization takes care of possible nil strings.

proc constructChild*[T](
  ctx   : var ConstructionContext,
  result: var seq[T],
) {.raises: [YamlConstructionError, YamlStreamError].}
  ## Constructs a Nim value that is a string from a part of a YAML stream.
  ## This specialization takes care of possible nil seqs.

proc constructChild*[O](
  ctx   : var ConstructionContext,
  result: var ref O,
) {.raises: [YamlConstructionError, YamlStreamError].}
  ## Constructs an arbitrary Nim value from a part of a YAML stream.
  ## The stream will advance until after the finishing token that was used
  ## for constructing the value. The object may be constructed from an alias
  ## node which will be resolved using the ``ConstructionContext``.

proc representChild*[O](
  ctx  : var SerializationContext,
  value: ref O,
) {.raises: [YamlSerializationError].}
  ## Represents an arbitrary Nim reference value as YAML object. The object
  ## may be represented as alias node if it is already present in the
  ## ``SerializationContext``.

proc representChild*(
  ctx  : var SerializationContext,
  value: string,
) {.inline, raises: [].}
  ## Represents a Nim string. Supports nil strings.

proc representChild*[O](
  ctx: var SerializationContext,
  value: O,
) {.raises: [YamlSerializationError].}
  ## Represents an arbitrary Nim object as YAML object.

proc initConstructionContext*(input: YamlStream): ConstructionContext =
  result = ConstructionContext(
    input: input,
    refs : initTable[Anchor, tuple[tag: Tag, p: pointer]](),
  )

proc initSerializationContext*(
  options: SerializationOptions,
  putImpl: proc(ctx: var SerializationContext, e: Event) {.raises: [], closure.}
): SerializationContext =
  result = SerializationContext(
    refs: initTable[pointer, tuple[a: Anchor, referenced: bool]](),
    emitTag: options.tagStyle != tsNone,
    nextAnchorId: "a",
    options: options,
    putImpl: putImpl
  )

proc presentTag*(ctx: var SerializationContext, t: typedesc): Tag {.inline.} =
  ## Get the Tag that represents the given type in the given style
  if ctx.emitTag:
    result = yamlTag(t)
    if ctx.options.tagStyle == tsRootOnly: ctx.emitTag = false
  else:
    result = yTagQuestionMark

proc safeTagUri(tag: Tag): string {.raises: [].} =
  try:
    var uri = $tag
    # '!' is not allowed inside a tag handle
    if uri.len > 0 and uri[0] == '!': uri = uri[1..^1]
    # ',' is not allowed after a tag handle in the suffix because it's a flow
    # indicator
    for i in countup(0, uri.len - 1):
      if uri[i] == ',': uri[i] = ';'
    return uri
  except KeyError:
    internalError("Unexpected KeyError for Tag " & $tag)

proc newYamlConstructionError*(
  s: YamlStream,
  mark: Mark,
  msg: string,
): ref YamlConstructionError =
  result = newException(YamlConstructionError, msg)
  result.mark = mark
  if not s.getLastTokenContext(result.lineContent):
    result.lineContent = ""

proc constructionError*(s: YamlStream, mark: Mark, msg: string):
    ref YamlConstructionError =
  return newYamlConstructionError(s, mark, msg)

template constructScalarItem*(
  s: var YamlStream,
  i: untyped,
  t: typedesc,
  content: untyped,
) =
  ## Helper template for implementing ``constructObject`` for types that
  ## are constructed from a scalar. ``i`` is the identifier that holds
  ## the scalar as ``Event`` in the content. Exceptions raised in
  ## the content will be automatically caught and wrapped in
  ## ``YamlConstructionError``, which will then be raised.
  bind constructionError
  let i = s.next()
  if i.kind != yamlScalar:
    raise constructionError(s, i.startPos, "Expected scalar")
  try: content
  except YamlConstructionError as e: raise e
  except CatchableError as e:
    var ce = constructionError(s, i.startPos,
        "Cannot construct to " & name(t) & ": " & item.scalarContent &
        "; error: " & e.msg)
    ce.parent = e
    raise ce

proc yamlTag*(T: typedesc[string]): Tag {.inline, noSideEffect, raises: [].} =
  yTagString

proc constructObject*(
  ctx   : var ConstructionContext,
  result: var string,
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a string from a YAML scalar
  ctx.input.constructScalarItem(item, string):
    result = item.scalarContent

proc representObject*(
  ctx  : var SerializationContext,
  value: string,
  tag  : Tag,
) {.raises: [].} =
  ## represents a string as YAML scalar
  ctx.put(scalarEvent(value, tag, yAnchorNone, ctx.scalarStyleFor(string)))

proc parseHex[T: int8|int16|int32|int64|uint8|uint16|uint32|uint64](
  s: YamlStream, mark: Mark, val: string
): T =
  result = 0
  for i in 2..<val.len:
    case val[i]
    of '_': discard
    of '0'..'9': result = result shl 4 or T(ord(val[i]) - ord('0'))
    of 'a'..'f': result = result shl 4 or T(ord(val[i]) - ord('a') + 10)
    of 'A'..'F': result = result shl 4 or T(ord(val[i]) - ord('A') + 10)
    else:
      raise s.constructionError(mark, "Invalid character in hex: " &
          escape("" & val[i]))

proc parseOctal[T: int8|int16|int32|int64|uint8|uint16|uint32|uint64](
  s: YamlStream, mark: Mark, val: string
): T =
  for i in 2..<val.len:
    case val[i]
    of '_': discard
    of '0'..'7': result = result shl 3 + T((ord(val[i]) - ord('0')))
    else:
      raise s.constructionError(mark, "Invalid character in hex: " &
          escape("" & val[i]))

type NumberStyle = enum
  nsHex
  nsOctal
  nsDecimal

proc numberStyle(item: Event): NumberStyle =
  if item.scalarContent[0] == '0' and item.scalarContent.len > 1:
    if item.scalarContent[1] in {'x', 'X' }: return nsHex
    if item.scalarContent[1] in {'o', 'O'}: return nsOctal
  return nsDecimal

proc constructObject*[T: int8|int16|int32|int64](
  ctx   : var ConstructionContext,
  result: var T,
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs an integer value from a YAML scalar
  ctx.input.constructScalarItem(item, T):
    case item.numberStyle
    of nsHex:
      result = parseHex[T](ctx.input, item.startPos, item.scalarContent)
    of nsOctal:
      result = parseOctal[T](ctx.input, item.startPos, item.scalarContent)
    of nsDecimal:
      let nInt = parseBiggestInt(item.scalarContent)
      if nInt <= T.high:
        # make sure we don't produce a range error
        result = T(nInt)
      else:
        raise ctx.input.constructionError(
          item.startPos,
          "Cannot construct int; out of range: " &
          $nInt & " for type " & T.name & " with max of: " & $T.high
        )

proc constructObject*(
  ctx   : var ConstructionContext,
  result: var int,
) {.raises: [YamlConstructionError, YamlStreamError], inline.} =
  ## constructs an integer of architecture-defined length by loading it into
  ## int32 and then converting it.
  var i32Result: int32
  ctx.constructObject(i32Result)
  result = int(i32Result)

proc representObject*[T: int8|int16|int32|int64](
  ctx  : var SerializationContext,
  value: T,
  tag  : Tag,
) {.raises: [].} =
  ## represents an integer value as YAML scalar
  ctx.put(scalarEvent($value, tag, yAnchorNone, ctx.scalarStyleFor(T)))

proc representObject*(
  ctx  : var SerializationContext,
  value: int,
  tag  : Tag,
) {.raises: [YamlSerializationError], inline.}=
  ## represent an integer of architecture-defined length by casting it to int32.
  ## on 64-bit systems, this may cause a RangeDefect.

  # currently, sizeof(int) is at least sizeof(int32).
  try:
    ctx.put(scalarEvent(
      $int32(value), tag, yAnchorNone, ctx.scalarStyleFor(int)))
  except RangeDefect as rd:
    var e = newException(YamlSerializationError, rd.msg)
    e.parent = rd
    raise e

when defined(JS):
  type DefiniteUIntTypes = uint8 | uint16 | uint32
else:
  type DefiniteUIntTypes = uint8 | uint16 | uint32 | uint64

proc constructObject*[T: DefiniteUIntTypes](
  ctx   : var ConstructionContext,
  result: var T,
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ## construct an unsigned integer value from a YAML scalar
  ctx.input.constructScalarItem(item, T):
    case item.numberStyle
    of nsHex:
      result = parseHex[T](ctx.input, item.startPos, item.scalarContent)
    of nsOctal:
      result = parseOctal[T](ctx.input, item.startPos, item.scalarContent)
    else:
      let nUInt = parseBiggestUInt(item.scalarContent)
      if nUInt <= T.high:
        # make sure we don't produce a range error
        result = T(nUInt)
      else:
        raise ctx.input.constructionError(
          item.startPos,
          "Cannot construct uint; out of range: " &
          $nUInt & " for type " & T.name & " with max of: " & $T.high
        )

proc constructObject*(
  ctx   : var ConstructionContext,
  result: var uint,
) {.raises: [YamlConstructionError, YamlStreamError], inline.} =
  ## represent an unsigned integer of architecture-defined length by loading it
  ## into uint32 and then converting it.
  var u32Result: uint32
  ctx.constructObject(u32Result)
  result = uint(u32Result)

when defined(JS):
  # TODO: this is a dirty hack and may lead to overflows!
  proc `$`(x: uint8|uint16|uint32|uint64|uint): string =
    result = $BiggestInt(x)

proc representObject*[T: uint8|uint16|uint32|uint64](
  ctx  : var SerializationContext,
  value: T,
  tag  : Tag,
) {.raises: [].} =
  ## represents an unsigned integer value as YAML scalar
  ctx.put(scalarEvent($value, tag, yAnchorNone, ctx.scalarStyleFor(T)))

proc representObject*(
  ctx  : var SerializationContext,
  value: uint,
  tag  : Tag,
) {.raises: [YamlSerializationError], inline.} =
  ## represent an unsigned integer of architecture-defined length by casting it
  ## to int32. on 64-bit systems, this may cause a RangeDefect.
  try:
    ctx.put(scalarEvent(
      $uint32(value), tag, yAnchorNone, ctx.scalarStyleFor(uint)))
  except RangeDefect as rd:
    var e = newException(YamlSerializationError, rd.msg)
    e.parent = rd
    raise e

proc constructObject*[T: float|float32|float64](
  ctx   : var ConstructionContext,
  result: var T,
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ## construct a float value from a YAML scalar
  ctx.input.constructScalarItem(item, T):
    let hint = guessType(item.scalarContent)
    case hint
    of yTypeFloat:
      var res: BiggestFloat
      discard parseBiggestFloat(item.scalarContent, res)
      result = res
    of yTypeInteger:
      var res: BiggestFloat
      discard parseBiggestFloat(item.scalarContent, res)
      result = res
    of yTypeFloatInf:
        if item.scalarContent[0] == '-': result = NegInf
        else: result = Inf
    of yTypeFloatNaN: result = NaN
    else:
      raise ctx.input.constructionError(
        item.startPos,
        "Cannot construct to float: " & escape(item.scalarContent)
      )

proc representObject*[T: float|float32|float64](
  ctx  : var SerializationContext,
  value: T,
  tag  : Tag,
) {.raises: [].} =
  ## represents a float value as YAML scalar
  case value
  of Inf: ctx.put(scalarEvent(".inf", tag, ctx.scalarStyleFor(T)))
  of NegInf: ctx.put(scalarEvent("-.inf", tag, ctx.scalarStyleFor(T)))
  of NaN: ctx.put(scalarEvent(".nan", tag, ctx.scalarStyleFor(T)))
  else: ctx.put(scalarEvent($value, tag, ctx.scalarStyleFor(T)))

proc yamlTag*(T: typedesc[bool]): Tag {.inline, raises: [].} = yTagBoolean

proc constructObject*(
  ctx   : var ConstructionContext,
  result: var bool,
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a bool value from a YAML scalar
  ctx.input.constructScalarItem(item, bool):
    case guessType(item.scalarContent)
    of yTypeBoolTrue: result = true
    of yTypeBoolFalse: result = false
    else:
      raise ctx.input.constructionError(
        item.startPos,
        "Cannot construct to bool: " & escape(item.scalarContent)
      )

proc representObject*(
  ctx  : var SerializationContext,
  value: bool,
  tag  : Tag,
)  {.raises: [].} =
  ## represents a bool value as a YAML scalar
  ctx.put(scalarEvent(if value: "true" else: "false",
    tag, yAnchorNone, ctx.scalarStyleFor(bool)))

proc constructObject*(
  ctx   : var ConstructionContext,
  result: var char,
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a char value from a YAML scalar
  ctx.input.constructScalarItem(item, char):
    if item.scalarContent.len != 1:
      raise ctx.input.constructionError(
        item.startPos,
        "Cannot construct to char (length != 1): " & escape(item.scalarContent)
      )
    else: result = item.scalarContent[0]

proc representObject*(
  ctx  : var SerializationContext,
  value: char,
  tag  : Tag
) {.raises: [].} =
  ## represents a char value as YAML scalar
  ctx.put(scalarEvent("" & value, tag, yAnchorNone, ctx.scalarStyleFor(char)))

proc yamlTag*(T: typedesc[Time]): Tag {.inline, raises: [].} = yTagTimestamp

proc constructObject*(
  ctx   : var ConstructionContext,
  result: var Time,
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ctx.input.constructScalarItem(item, Time):
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
      raise ctx.input.constructionError(
        item.startPos,
        "Not a parsable timestamp: " & escape(item.scalarContent)
      )

proc representObject*(
  ctx  : var SerializationContext,
  value: Time,
  tag  : Tag,
) {.raises: [].} =
  let tmp = value.utc()
  ctx.put(scalarEvent(tmp.format(
    "yyyy-MM-dd'T'HH:mm:ss'Z'"), tag, yAnchorNone, ctx.scalarStyleFor(Time)))

proc yamlTag*[I](T: typedesc[seq[I]]): Tag {.inline, raises: [].} =
  return nimTag("system:seq(" & safeTagUri(yamlTag(I)) & ')')

proc yamlTag*[I](T: typedesc[set[I]]): Tag {.inline, raises: [].} =
  return nimTag("system:set(" & safeTagUri(yamlTag(I)) & ')')

proc constructObject*[T](
  ctx   : var ConstructionContext,
  result: var seq[T],
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a Nim seq from a YAML sequence
  let event = ctx.input.next()
  if event.kind != yamlStartSeq:
    raise ctx.input.constructionError(event.startPos, "Expected sequence start")
  result = newSeq[T]()
  while ctx.input.peek().kind != yamlEndSeq:
    var item: T
    ctx.constructChild(item)
    result.add(move(item))
  discard ctx.input.next()

proc constructObject*[T](
  ctx   : var ConstructionContext,
  result: var set[T],
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a Nim seq from a YAML sequence
  let event = ctx.input.next()
  if event.kind != yamlStartSeq:
    raise ctx.input.constructionError(event.startPos, "Expected sequence start")
  result = {}
  while ctx.input.peek().kind != yamlEndSeq:
    var item: T
    ctx.constructChild(item)
    result.incl(item)
  discard ctx.input.next()

proc representObject*[T](
  ctx  : var SerializationContext,
  value: seq[T]|set[T],
  tag  : Tag,
) {.raises: [YamlSerializationError].} =
  ## represents a Nim seq as YAML sequence
  ctx.put(
    startSeqEvent(tag = tag, style = ctx.collectionStyleFor(type(value))))
  for item in value: ctx.representChild(item)
  ctx.put(endSeqEvent())

proc yamlTag*[I, V](T: typedesc[array[I, V]]): Tag {.inline, raises: [].} =
  const rangeName = name(I)
  return nimTag("system:array(" & rangeName[6..rangeName.high()] & ';' &
      safeTagUri(yamlTag(V)) & ')')

proc constructObject*[I, T](
  ctx   : var ConstructionContext,
  result: var array[I, T],
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a Nim array from a YAML sequence
  var event = ctx.input.next()
  if event.kind != yamlStartSeq:
    raise ctx.input.constructionError(event.startPos, "Expected sequence start")
  for index in low(I)..high(I):
    event = ctx.input.peek()
    if event.kind == yamlEndSeq:
      raise ctx.input.constructionError(event.startPos, "Too few array values")
    ctx.constructChild(result[index])
  event = ctx.input.next()
  if event.kind != yamlEndSeq:
    raise ctx.input.constructionError(event.startPos, "Too many array values")

proc representObject*[I, T](
  ctx  : var SerializationContext,
  value: array[I, T],
  tag  : Tag,
) {.raises: [YamlSerializationError].} =
  ## represents a Nim array as YAML sequence
  ctx.put(startSeqEvent(tag = tag, style = ctx.collectionStyleFor(array[I, T])))
  for item in value: ctx.representChild(item)
  ctx.put(endSeqEvent())

proc yamlTag*[K, V](T: typedesc[Table[K, V]]): Tag {.inline, raises: [].} =
  return nimTag("tables:Table(" & safeTagUri(yamlTag(K)) & ';' &
      safeTagUri(yamlTag(V)) & ")")

proc constructObject*[K, V](
  ctx   : var ConstructionContext,
  result: var Table[K, V],
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a Nim Table from a YAML mapping
  let event = ctx.input.next()
  if event.kind != yamlStartMap:
    raise ctx.input.constructionError(
      event.startPos, "Expected map start, got " & $event.kind
    )
  result = initTable[K, V]()
  while ctx.input.peek.kind != yamlEndMap:
    var
      key: K
      value: V
    ctx.constructChild(key)
    ctx.constructChild(value)
    if result.contains(key):
      raise ctx.input.constructionError(event.startPos, "Duplicate table key!")
    result[key] = value
  discard ctx.input.next()

proc representObject*[K, V](
  ctx  : var SerializationContext,
  value: Table[K, V],
  tag  : Tag,
) {.raises: [YamlSerializationError].} =
  ## represents a Nim Table as YAML mapping
  ctx.put(
    startMapEvent(tag = tag, style = ctx.collectionStyleFor(Table[K, V])))
  for key, value in value.pairs:
    ctx.representChild(key)
    ctx.representChild(value)
  ctx.put(endMapEvent())

proc yamlTag*[K, V](T: typedesc[OrderedTable[K, V]]): Tag
    {.inline, raises: [].} =
  return nimTag("tables:OrderedTable(" & safeTagUri(yamlTag(K)) & ';' &
      safeTagUri(yamlTag(V)) & ")")

proc constructObject*[K, V](
  ctx   : var ConstructionContext,
  result: var OrderedTable[K, V],
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a Nim OrderedTable from a YAML mapping
  var event = ctx.input.next()
  if event.kind != yamlStartSeq:
    raise ctx.input.constructionError(
      event.startPos, "Expected seq start, got " & $event.kind
    )
  result = initOrderedTable[K, V]()
  while ctx.input.peek.kind != yamlEndSeq:
    var
      key: K
      value: V
    event = ctx.input.next()
    if event.kind != yamlStartMap:
      raise ctx.input.constructionError(
        event.startPos, "Expected map start, got " & $event.kind
      )
    ctx.constructChild(key)
    ctx.constructChild(value)
    event = ctx.input.next()
    if event.kind != yamlEndMap:
      raise ctx.input.constructionError(
        event.startPos, "Expected map end, got " & $event.kind
      )
    if result.contains(key):
      raise ctx.input.constructionError(event.startPos, "Duplicate table key!")
    result[move(key)] = move(value)
  discard ctx.input.next()

proc representObject*[K, V](
  ctx  : var SerializationContext,
  value: OrderedTable[K, V],
  tag  : Tag,
) {.raises: [YamlSerializationError].} =
  ctx.put(startSeqEvent(
    tag = tag, style = ctx.collectionStyleFor(OrderedTable[K, V])))
  for key, value in value.pairs:
    ctx.put(startMapEvent())
    ctx.representChild(key)
    ctx.representChild(value)
    ctx.put(endMapEvent())
  ctx.put(endSeqEvent())

proc yamlTag*(T: typedesc[object|enum]):
    Tag {.inline, raises: [].} =
  return nimTag("custom:" & (typetraits.name(type(T))))

proc yamlTag*(T: typedesc[tuple]):
    Tag {.inline, raises: [].} =
  var
    i: T
    uri = nimyamlTagRepositoryPrefix & "tuple("
    first = true
  for name, value in fieldPairs(i):
    if first: first = false
    else: uri.add(",")
    uri.add(safeTagUri(yamlTag(type(value))))
  uri.add(")")
  return Tag(uri)

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

proc parentType(tDesc: NimNode): NimNode {.compileTime.} =
  var name: NimNode
  case tDesc[1].kind
  of nnkEmpty: return nil
  of nnkBracketExpr:
    # happens when parent type is `ref X`
    name = tDesc[1][1]
  of nnkObjectTy, nnkSym:
    name = tDesc[1]
  else:
    return nil
  result = newNimNode(nnkBracketExpr)
  result.add(bindSym("typeDesc"))
  result.add(name)

proc fieldCount(t: NimNode): int {.compiletime.} =
  result = 0
  var tTypedesc: NimNode
  if t.kind == nnkSym:
    tTypedesc = getType(t)
  else:
    tTypedesc = t

  let tDesc = getType(tTypedesc[1])
  if tDesc.kind == nnkBracketExpr:
    # tuple
    result = tDesc.len - 1
  else:
    # object
    let tParent = parentType(tDesc)
    if tParent != nil:
      # inherited fields
      result += fieldCount(tParent)
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
  let numFields = fieldCount(t)
  if numFields == 0:
    result = quote do:
      (seq[bool])(@[])
    return
  
  result = newNimNode(nnkBracket)
  for i in 0..<numFields:
    result.add(newLit(false))

proc checkDuplicate(
  s      : NimNode,
  tName  : string,
  name   : string,
  i      : int,
  matched: NimNode,
  m      : NimNode,
): NimNode {.compileTime.} =
  result = newIfStmt((newNimNode(nnkBracketExpr).add(matched, newLit(i)),
      newNimNode(nnkRaiseStmt).add(newCall(bindSym("constructionError"), s, m,
      newLit("While constructing " & tName & ": Duplicate field: " &
      escape(name))))))

proc input(ctx: NimNode): NimNode {.compileTime.} =
  return newDotExpr(ctx, ident("input"))

proc hasSparse(t: typedesc): bool {.compileTime.} =
  when compiles(t.hasCustomPragma(sparse)):
    return t.hasCustomPragma(sparse)
  else:
    return false

proc getOptionInner(fType: NimNode): NimNode {.compileTime.} =
  if fType.kind == nnkBracketExpr and len(fType) == 2 and
      fType[0].kind == nnkSym:
    return fType[1]
  else: return nil

proc checkMissing(
  s, t   : NimNode,
  tName  : string,
  field  : NimNode,
  i      : int,
  matched: NimNode,
  o, m   : NimNode,
):
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
          `o`.`field` = none[`optionInner`]()
        else:
          raise constructionError(`s`, `m`, "While constructing " & `tName` &
              ": Missing field: " & `fName`)

proc markAsFound(i: int, matched: NimNode): NimNode {.compileTime.} =
  newAssignment(newNimNode(nnkBracketExpr).add(matched, newLit(i)),
      newLit(true))

proc ifNotTransient(
  o, field : NimNode,
  content  : openarray[NimNode],
  elseError: bool,
  s, m : NimNode, 
  tName: string = "",
  fName: string = "",
):
    NimNode {.compileTime.} =
  var stmts = newStmtList(content)
  if elseError:
    result = quote do:
      when `o`.`field`.hasCustomPragma(transient):
        raise constructionError(`s`, `m`, "While constructing " & `tName` &
            ": Field \"" & `fName` & "\" is transient and may not occur in input")
      else:
        `stmts`
  else:
    result = quote do:
      when not `o`.`field`.hasCustomPragma(transient):
        `stmts`

proc recEnsureAllFieldsPresent(
  s, tDecl, o: NimNode,
  matched, m : NimNode,
  tName: string,
  field: var int,
  stmt : NimNode,
) {.compileTime.} =
  var
    tDesc = getType(tDecl[1])
    tParent = parentType(tDesc)
  if tParent != nil:
    recEnsureAllFieldsPresent(s, tParent, o, matched, m, tName, field, stmt)
  for child in tDesc[2].children:
    if child.kind == nnkRecCase:
      stmt.add(checkMissing(
          s, tDecl, tName, child[0], field, matched, o, m))
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
              s, tDecl, tName, item, field, matched, o, m))
        stmt.add(newIfStmt((infix(newDotExpr(o, newIdentNode($child[0])),
            "in", curValues), discChecks)))
    else:
      stmt.add(checkMissing(s, tDecl, tName, child, field, matched, o, m))
    inc(field)

macro ensureAllFieldsPresent(
  s      : YamlStream,
  t      : typedesc,
  o      : typed,
  matched: typed,
  m      : Mark,
) =
  result = newStmtList()
  let
    tDecl = getType(t)
    tName = $tDecl[1]
  var field = 0
  recEnsureAllFieldsPresent(s, tDecl, o, matched, m, tName, field, result)

proc skipOverValue(s: var YamlStream) =
    var e = s.next()
    var depth = int(e.kind in {yamlStartMap, yamlStartSeq})
    while depth > 0:
      case s.next().kind
      of yamlStartMap, yamlStartSeq: inc(depth)
      of yamlEndMap, yamlEndSeq: dec(depth)
      of yamlScalar, yamlAlias: discard
      else: internalError("Unexpected event kind.")

proc addFieldCases(
  tDecl, context  : NimNode,
  name, o, matched: NimNode,
  failOnUnknown, m: NimNode,
  tName     : string,
  caseStmt  : NimNode,
  fieldIndex: var int,
) {.compileTime.} =
  var
    tDesc = getType(tDecl[1])
    tParent = parentType(tDesc)
  if tParent != nil:
    addFieldCases(tParent, context, name, o, matched, failOnUnknown, m, tName, caseStmt, fieldIndex)
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
          checkDuplicate(input(context), tName, $child[0], fieldIndex, matched, m),
          newNimNode(nnkVarSection).add(
              newNimNode(nnkIdentDefs).add(
                  newIdentNode("value"), discType, newEmptyNode())),
          newCall("constructChild", context, newIdentNode("value")),
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
              newCall("constructChild", context, field))))
          ifStmt.add(newNimNode(nnkElse).add(newNimNode(nnkRaiseStmt).add(
              newCall(bindSym("constructionError"), input(context), m,
              infix(newStrLitNode("Field " & $item & " not allowed for " &
              $child[0] & " == "), "&", prefix(discriminant, "$"))))))
          ob.add(ifNotTransient(o, item,
              [checkDuplicate(input(context), tName, $item, fieldIndex, matched, m),
              ifStmt, markAsFound(fieldIndex, matched)], true,
              input(context), m, tName, $item))
          caseStmt.add(ob)
    else:
      yAssert child.kind == nnkSym
      var ob = newNimNode(nnkOfBranch).add(newStrLitNode($child))
      let field = newDotExpr(o, newIdentNode($child))
      ob.add(ifNotTransient(o, child,
          [checkDuplicate(input(context), tName, $child, fieldIndex, matched, m),
          newCall("constructChild", context, field),
          markAsFound(fieldIndex, matched)], true, input(context), m, tName, $child))
      caseStmt.add(ob)
    inc(fieldIndex)

macro constructFieldValue(
  t: typedesc, 
  context, name, o, matched: untyped,
  failOnUnknown: bool,
  m: untyped,
) =
  let
    tDecl = getType(t)
    tName = $tDecl[1]
  result = newStmtList()
  var caseStmt = newNimNode(nnkCaseStmt).add(name)
  var fieldIndex = 0
  addFieldCases(tDecl, context, name, o, matched, failOnUnknown, m, tName, caseStmt, fieldIndex)
  caseStmt.add(newNimNode(nnkElse).add(newNimNode(nnkWhenStmt).add(
    newNimNode(nnkElifBranch).add(failOnUnknown,
      newNimNode(nnkRaiseStmt).add(
        newCall(bindSym("constructionError"), input(context), m,
        infix(newLit("While constructing " & tName & ": Unknown field: "), "&",
        newCall(bindSym("escape"), name)))))
  ).add(newNimNode(nnkElse).add(
    newCall(bindSym("skipOverValue"), input(context))
  ))))
  result.add(caseStmt)

proc isVariantObject(t: NimNode): bool {.compileTime.} =
  var
    tResolved: NimNode
    tDesc: NimNode
  if t.kind == nnkSym:
    tResolved = getType(t)
  else:
    tResolved = t
  if tResolved.kind == nnkBracketExpr and tResolved[0].strVal == "typeDesc":
    tDesc = getType(tResolved[1])
  else:
    tDesc = tResolved
  if tDesc.kind != nnkObjectTy: return false
  let tParent = parentType(tDesc)
  if tParent != nil:
    if isVariantObject(tParent): return true
  for child in tDesc[2].children:
    if child.kind == nnkRecCase: return true
  return false

proc hasIgnore(t: typedesc): bool {.compileTime.} =
  when compiles(t.hasCustomPragma(ignore)):
    return t.hasCustomPragma(ignore)
  else:
    return false

proc constructObjectDefault*(
  ctx   : var ConstructionContext,
  result: var RootObj,
) =
  # specialization of generic proc for RootObj, doesn't do anything
  return

proc constructObjectDefault*[O: object|tuple](
  ctx   : var ConstructionContext,
  result: var O,
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ## Constructs a Nim object or tuple from a YAML mapping.
  ## This is the default implementation for custom objects and tuples and should
  ## not be redefined. If you are adding a custom constructObject()
  ## implementation, you can use this proc to call the default implementation
  ## within it.
  var matched = matchMatrix(O)
  var e = ctx.input.next()
  const
    startKind = when isVariantObject(getType(O)): yamlStartSeq else: yamlStartMap
    endKind = when isVariantObject(getType(O)): yamlEndSeq else: yamlEndMap
  if e.kind != startKind:
    raise ctx.input.constructionError(
      e.startPos,
      "While constructing " & typetraits.name(O) &
      ": Expected " & $startKind & ", got " & $e.kind
    )
  let startPos = e.startPos
  when hasIgnore(O):
    const ignoredKeyList = O.getCustomPragmaVal(ignore)
    const failOnUnknown = len(ignoredKeyList) > 0
  else:
    const failOnUnknown = true
  while ctx.input.peek.kind != endKind:
    e = ctx.input.next()
    when isVariantObject(getType(O)):
      if e.kind != yamlStartMap:
        raise ctx.input.constructionError(
          e.startPos, "Expected single-pair map, got " & $e.kind
        )
      e = ctx.input.next()
    if e.kind != yamlScalar:
      raise ctx.input.constructionError(
        e.startPos, "Expected field name, got " & $e.kind
      )
    let name = e.scalarContent
    when result is tuple:
      var i = 0
      var found = false
      for fname, value in fieldPairs(result):
        if fname == name:
          if matched[i]:
            raise ctx.input.constructionError(
              e.startPos, "While constructing " &
              typetraits.name(O) & ": Duplicate field: " & escape(name)
            )
          ctx.constructChild(value)
          matched[i] = true
          found = true
          break
        inc(i)
      when failOnUnknown:
        if not found:
          raise ctx.input.constructionError(
            e.startPos, "While constructing " &
            typetraits.name(O) & ": Unknown field: " & escape(name)
          )
    else:
      when hasIgnore(O) and failOnUnknown:
        if name notin ignoredKeyList:
          constructFieldValue(O, ctx, name, result, matched, failOnUnknown, e.startPos)
        else:
          skipOverValue(ctx.input)
      else:
        constructFieldValue(O, ctx, name, result, matched, failOnUnknown, e.startPos)
    when isVariantObject(getType(O)):
      e = ctx.input.next()
      if e.kind != yamlEndMap:
        raise ctx.input.constructionError(
          e.startPos, "Expected end of single-pair map, got " & $e.kind
        )
  discard ctx.input.next()
  when result is tuple:
    var i = 0
    for fname, value in fieldPairs(result):
      if not matched[i]:
        raise ctx.input.constructionError(startPos, "While constructing " &
            typetraits.name(O) & ": Missing field: " & escape(fname))
      inc(i)
  else: ensureAllFieldsPresent(ctx.input, O, result, matched, startPos)

proc constructObject*[O: object|tuple](
  ctx   : var ConstructionContext,
  result: var O,
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ## Overridable default implementation for custom object and tuple types
  ctx.constructObjectDefault(result)

proc recGenFieldRepresenters(
  tDecl, value: NimNode,
  isVO        : bool,
  fieldIndex  : var int16,
  result      : NimNode,
) {.compileTime.} =
  let
    tDesc = getType(tDecl[1])
    tParent = parentType(tDesc)
  if tParent != nil:
    recGenFieldRepresenters(tParent, value, isVO, fieldIndex, result)
  for child in tDesc[2].children:
    if child.kind == nnkRecCase:
      let
        fieldName = $child[0]
        fieldAccessor = newDotExpr(value, newIdentNode(fieldName))
      result.add(quote do:
        ctx.put(startMapEvent())
        ctx.put(scalarEvent(
          `fieldName`,
          tag = if ctx.emitTag: yTagNimField else: yTagQuestionMark
        ))
        when `fieldAccessor`.hasCustomPragma(scalar):
          ctx.overridingScalarStyle = `fieldAccessor`.getCustomPragmaVal(scalar)
          echo "set scalar style to ", $ctx.overridingScalarStyle
        when `fieldAccessor`.hasCustomPragma(collection):
          ctx.overridingCollectionStyle = `fieldAccessor`.getCustomPragmaVal(collection)
        ctx.representChild(`fieldAccessor`)
        ctx.put(endMapEvent())
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
                ctx.put(startMapEvent())
                ctx.put(scalarEvent(
                  `name`,
                  tag = if ctx.emitTag: yTagNimField else: yTagQuestionMark 
                ))
                when `itemAccessor`.hasCustomPragma(scalar):
                  ctx.overridingScalarStyle = `itemAccessor`.getCustomPragmaVal(scalar)
                  echo "set scalar style to ", $ctx.overridingScalarStyle
                when `itemAccessor`.hasCustomPragma(collection):
                  ctx.overridingCollectionStyle = `itemAccessor`.getCustomPragmaVal(collection)
                ctx.representChild(`itemAccessor`)
                ctx.put(endMapEvent())
            )
        else:
          curStmtList.add(newNimNode(nnkDiscardStmt).add(newEmptyNode()))
        curBranch.add(curStmtList)
        caseStmt.add(curBranch)
      result.add(caseStmt)
    else:
      let
        name = $child
        templName = genSym(nskTemplate)
        childAccessor = newDotExpr(value, newIdentNode(name))
      result.add(quote do:
        template `templName` {.used.} =
          when bool(`isVO`): ctx.put(startMapEvent())
          ctx.put(scalarEvent(
            `name`,
            if ctx.emitTag: yTagNimField else: yTagQuestionMark,
            yAnchorNone
          ))
          when `childAccessor`.hasCustomPragma(scalar):
            ctx.overridingScalarStyle = `childAccessor`.getCustomPragmaVal(scalar)
            echo "set scalar style to ", $ctx.overridingScalarStyle
          when `childAccessor`.hasCustomPragma(collection):
            ctx.overridingCollectionStyle = `childAccessor`.getCustomPragmaVal(collection)
          ctx.representChild(`childAccessor`)
          when bool(`isVO`): ctx.put(endMapEvent())
        when not `childAccessor`.hasCustomPragma(transient):
          when hasSparse(`tDecl`) and `child` is Option:
            if `childAccessor`.isSome: `templName`()
          else:
            `templName`()
      )
    inc(fieldIndex)

macro genRepresentObject(t: typedesc, value) =
  result = newStmtList()
  let
    tDecl = getType(t)
    isVO  = isVariantObject(t)
  var fieldIndex = 0'i16
  recGenFieldRepresenters(tDecl, value, isVO, fieldIndex, result)

proc representObject*[O: object](
  ctx  : var SerializationContext,
  value: O,
  tag  : Tag,
) {.raises: [YamlSerializationError].} =
  ## represents a Nim object or tuple as YAML mapping
  when isVariantObject(getType(O)):
    ctx.put(startSeqEvent(tag = tag, style = ctx.collectionStyleFor(O)))
  else:
    ctx.put(startMapEvent(tag = tag, style = ctx.collectionStyleFor(O)))
  genRepresentObject(O, value)
  when isVariantObject(getType(O)): ctx.put(endSeqEvent())
  else: ctx.put(endMapEvent())

proc representObject*[O: tuple](
  ctx  : var SerializationContext,
  value: O,
  tag  : Tag,
) {.raises: [YamlSerializationError].} =
  var fieldIndex = 0'i16
  ctx.put(startMapEvent(tag = tag, style = ctx.collectionStyleFor(O)))
  for name, fvalue in fieldPairs(value):
    ctx.put(scalarEvent(
      name,
      tag = if ctx.emitTag: yTagNimField else: yTagQuestionMark
    ))
    ctx.representChild(fvalue)
    inc(fieldIndex)
  ctx.put(endMapEvent())

proc constructObject*[O: enum](
  ctx   : var ConstructionContext,
  result: var O,
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ## constructs a Nim enum from a YAML scalar
  let e = ctx.input.next()
  if e.kind != yamlScalar:
    raise ctx.input.constructionError(
      e.startPos, "Expected scalar, got " & $e.kind
    )
  try: result = parseEnum[O](e.scalarContent)
  except ValueError as ve:
    var ex = ctx.input.constructionError(e.startPos, "Cannot parse '" &
      escape(e.scalarContent) & "' as " & type(O).name
    )
    ex.parent = ve
    raise ex

proc representObject*[O: enum](
  ctx  : var SerializationContext,
  value: O,
  tag  : Tag,
) {.raises: [].} =
  ## represents a Nim enum as YAML scalar
  ctx.put(scalarEvent($value, tag, yAnchorNone, ctx.scalarStyleFor(O)))

proc yamlTag*[O](T: typedesc[ref O]): Tag {.inline, raises: [].} = yamlTag(O)

macro constructImplicitVariantObject(
  m, c, r, possibleTags: untyped,
  t: typedesc,
) =
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
      branch.add(infix(newIdentNode("yTagNull"), "in", possibleTags))
      branchContent.add(
        newNimNode(nnkDiscardStmt).add(newCall("next", input(c))))
    of 1:
      let field = newDotExpr(r, newIdentNode($recCase[i][1].recListNode))
      branch.add(infix(
          newCall("yamlTag", newCall("type", field)), "in", possibleTags))
      branchContent.add(newCall("constructChild", c, field))
    else:
      block:
        internalError("Too many children: " & $recCase[i][1].recListlen)
    branch.add(branchContent)
    result.add(branch)
  let raiseStmt = newNimNode(nnkRaiseStmt).add(
      newCall(bindSym("constructionError"), input(c), m,
      infix(newStrLitNode("This value type does not map to any field in " &
                          getTypeImpl(t)[1].repr & ": "), "&",
            newCall("$", newNimNode(nnkBracketExpr).add(possibleTags, newIntLitNode(0)))
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

proc constructChild*[T](
  ctx   : var ConstructionContext,
  result: var T,
) =
  let item = ctx.input.peek()
  when isImplicitVariantObject(T):
    when not canBeImplicit(T):
      {. fatal: "This type cannot be marked as implicit" .}
    var possibleTags = newSeq[Tag]()
    case item.kind
    of yamlScalar:
      case item.scalarProperties.tag
      of yTagQuestionMark:
        case guessType(item.scalarContent)
        of yTypeInteger:
          possibleTags.add([yamlTag(int), yamlTag(int8), yamlTag(int16),
                              yamlTag(int32), yamlTag(int64)])
          if item.scalarContent[0] != '-':
            possibleTags.add([yamlTag(uint), yamlTag(uint8), yamlTag(uint16),
                                yamlTag(uint32), yamlTag(uint64)])
        of yTypeFloat, yTypeFloatInf, yTypeFloatNaN:
          possibleTags.add([yamlTag(float), yamlTag(float32),
                              yamlTag(float64)])
        of yTypeBoolTrue, yTypeBoolFalse:
          possibleTags.add(yamlTag(bool))
        of yTypeNull:
          raise ctx.input.constructionError(item.startPos, "not implemented!")
        of yTypeUnknown:
          possibleTags.add(yamlTag(string))
        of yTypeTimestamp:
          possibleTags.add(yamlTag(Time))
      of yTagExclamationMark:
        possibleTags.add(yamlTag(string))
      else:
        possibleTags.add(item.scalarProperties.tag)
    of yamlStartMap:
      if item.mapProperties.tag in [yTagQuestionMark, yTagExclamationMark]:
        raise ctx.input.constructionError(item.startPos,
            "Complex value of implicit variant object type must have a tag.")
      possibleTags.add(item.mapProperties.tag)
    of yamlStartSeq:
      if item.seqProperties.tag in [yTagQuestionMark, yTagExclamationMark]:
        raise ctx.input.constructionError(item.startPos,
            "Complex value of implicit variant object type must have a tag.")
      possibleTags.add(item.seqProperties.tag)
    of yamlAlias:
      raise ctx.input.constructionError(item.startPos,
          "cannot load non-ref value from alias node")
    else: internalError("Unexpected item kind: " & $item.kind)
    constructImplicitVariantObject(item.startPos, ctx, result, possibleTags, T)
  else:
    case item.kind
    of yamlScalar:
      if item.scalarProperties.tag notin [yTagQuestionMark, yTagExclamationMark,
                               yamlTag(T)]:
        raise ctx.input.constructionError(
          item.startPos, "Wrong tag for " & typetraits.name(T) & ": " & $item.scalarProperties.tag)
      elif item.scalarProperties.anchor != yAnchorNone:
        raise ctx.input.constructionError(item.startPos, "Anchor on non-ref type")
    of yamlStartMap:
      if item.mapProperties.tag notin [yTagQuestionMark, yamlTag(T)]:
        raise ctx.input.constructionError(
          item.startPos, "Wrong tag for " & typetraits.name(T) & ": " & $item.mapProperties.tag)
      elif item.mapProperties.anchor != yAnchorNone:
        raise ctx.input.constructionError(item.startPos, "Anchor on non-ref type")
    of yamlStartSeq:
      if item.seqProperties.tag notin [yTagQuestionMark, yamlTag(T)]:
        raise ctx.input.constructionError(
          item.startPos, "Wrong tag for " & typetraits.name(T) & ": " & $item.seqProperties.tag)
      elif item.seqProperties.anchor != yAnchorNone:
        raise ctx.input.constructionError(item.startPos, "Anchor on non-ref type")
    of yamlAlias:
      raise ctx.input.constructionError(item.startPos,
          "cannot load non-ref value from alias node")
    else: internalError("Unexpected item kind: " & $item.kind)
    ctx.constructObject(result)

proc constructChild*(
  ctx   : var ConstructionContext,
  result: var string,
) =
  let item = ctx.input.peek()
  if item.kind == yamlScalar:
    if item.scalarProperties.tag notin
        [yTagQuestionMark, yTagExclamationMark, yamlTag(string)]:
      raise ctx.input.constructionError(
        item.startPos, "Wrong tag for string: " & $item.scalarProperties.tag)
    elif item.scalarProperties.anchor != yAnchorNone:
      raise ctx.input.constructionError(item.startPos, "Anchor on non-ref type")
  ctx.constructObject(result)

proc constructChild*[T](
  ctx   : var ConstructionContext,
  result: var seq[T],
) =
  let item = ctx.input.peek()
  if item.kind == yamlStartSeq:
    if item.seqProperties.tag notin [yTagQuestionMark, yamlTag(seq[T])]:
      raise ctx.input.constructionError(
        item.startPos, "Wrong tag for " & typetraits.name(seq[T]) & ": " & $item.seqProperties.tag)
    elif item.seqProperties.anchor != yAnchorNone:
      raise ctx.input.constructionError(item.startPos, "Anchor on non-ref type")
  ctx.constructObject(result)

proc constructChild*[I, T](
  ctx   : var ConstructionContext,
  result: var array[I, T],
) =
  let item = ctx.input.peek()
  if item.kind == yamlStartSeq:
    if item.seqProperties.tag notin [yTagQuestionMark, yamlTag(array[I, T])]:
      raise ctx.input.constructionError(
        item.startPos, "Wrong tag for " & typetraits.name(array[I, T]) & ": " & $item.seqProperties.tag)
    elif item.seqProperties.anchor != yAnchorNone:
      raise ctx.input.constructionError(item.startPos, "Anchor on non-ref type")
  ctx.constructObject(result)

proc constructChild*[T](
  ctx   : var ConstructionContext,
  result: var Option[T],
) =
  ## constructs an optional value. A value with a !!null tag will be loaded
  ## an empty value.
  let event = ctx.input.peek()
  if event.kind == yamlScalar and event.scalarProperties.tag == yTagNull:
    result = none(T)
    discard ctx.input.next()
  else:
    var inner: T
    ctx.constructChild(inner)
    result = some(inner)

when defined(JS):
  # in JS, Time is a ref type. Therefore, we need this specialization so that
  # it is not handled by the general ref-type handler.
  proc constructChild*(
    ctx   : var ConstructionContext,
    result: var Time,
  ) =
    let e = ctx.input.peek()
    if e.kind == yamlScalar:
      if e.scalarProperties.tag notin [yTagQuestionMark, yTagTimestamp]:
        raise ctx.input.constructionError(e.startPos, "Wrong tag for Time: " & $e.scalarProperties.tag)
      elif guessType(e.scalarContent) != yTypeTimestamp:
        raise ctx.input.constructionError(e.startPos, "Invalid timestamp")
      elif e.scalarProperties.anchor != yAnchorNone:
        raise ctx.input.constructionError(e.startPos, "Anchor on non-ref type")
      ctx.constructObject(result)
    else:
      raise ctx.input.constructionError(e.startPos, "Unexpected structure, expected timestamp")

proc constructChild*[O](
  ctx   : var ConstructionContext,
  result: var ref O,
) =
  var e = ctx.input.peek()
  if e.kind == yamlScalar:
    let props = e.scalarProperties
    if props.tag == yTagNull or (props.tag == yTagQuestionMark and
        guessType(e.scalarContent) == yTypeNull):
      result = nil
      discard ctx.input.next()
      return
  elif e.kind == yamlAlias:
    when nimvm:
      raise ctx.input.constructionError(e.startPos,
        "aliases are not supported at compile time")
    else:
      let val = ctx.refs.getOrDefault(e.aliasTarget, (yTagNull, pointer(nil)))
      if val.p == nil:
        raise ctx.input.constructionError(e.startPos,
          "alias node refers to anchor in ignored scope")
      if val.tag != yamlTag(O):
        raise ctx.input.constructionError(e.startPos,
          "alias node refers to object of incompatible type")
      result = cast[ref O](val.p)
      discard ctx.input.next()
      return
  new(result)
  template removeAnchor(anchor: var Anchor) {.dirty.} =
    if anchor != yAnchorNone:
      yAssert(not ctx.refs.hasKey(anchor))
      when nimvm: discard # no aliases supported at compile time
      else: ctx.refs[anchor] = (yamlTag(O), cast[pointer](result))
      anchor = yAnchorNone

  case e.kind
  of yamlScalar: removeAnchor(e.scalarProperties.anchor)
  of yamlStartMap: removeAnchor(e.mapProperties.anchor)
  of yamlStartSeq: removeAnchor(e.seqProperties.anchor)
  else: internalError("Unexpected event kind: " & $e.kind)
  ctx.input.peek = e
  try: ctx.constructChild(result[])
  except YamlConstructionError as e: raise e
  except YamlStreamError as e: raise e
  except CatchableError as ce:
    var e = newException(YamlStreamError, ce.msg)
    e.parent = ce
    raise e

proc representChild*(
  ctx  : var SerializationContext,
  value: string,
) =
  let tag = ctx.presentTag(string)
  ctx.representObject(
    value,
    if tag == yTagQuestionMark and guessType(value) != yTypeUnknown:
      yTagExclamationMark
    else:
      tag
  )

proc representChild*[T](
  ctx  : var SerializationContext,
  value: seq[T],
) {.raises: [YamlSerializationError].} =
  ctx.representObject(value, ctx.presentTag(seq[T]))

proc representChild*[I, T](
  ctx  : var SerializationContext,
  value: array[I, T],
) {.raises: [YamlSerializationError].} =
  ctx.representObject(value, ctx.presentTag(array[I, T]))

proc representChild*[O](
  ctx  : var SerializationContext,
  value: ref O,
) =
  if isNil(value): ctx.put(scalarEvent("~", yTagNull, style = ctx.scalarStyleFor(O)))
  else:
    when nimvm: discard
    else:
      let p = cast[pointer](value)
      # when c.anchorStyle == asNone, `referenced` is used as indicator that we are
      # currently in the process of serializing this node. This enables us to
      # detect cycles and raise an error.
      var val = ctx.refs.getOrDefault(
        p, (ctx.nextAnchorId.Anchor, ctx.options.anchorStyle == asNone)
      )
      if val.a != ctx.nextAnchorId.Anchor:
        if ctx.options.anchorStyle == asNone:
          if val.referenced:
            raise newException(YamlSerializationError,
                "tried to serialize cyclic graph with asNone")
        else:
          val = ctx.refs.getOrDefault(p)
          yAssert(val.a != yAnchorNone)
          if not val.referenced:
            ctx.refs[p] = (val.a, true)
          ctx.put(aliasEvent(val.a))
          ctx.overridingScalarStyle = ssAny
          ctx.overridingCollectionStyle = csAny
          return
      ctx.refs[p] = val
      nextAnchor(ctx.nextAnchorId, len(ctx.nextAnchorId) - 1)
      let origPut = ctx.putImpl
      ctx.putImpl = proc(ctx: var SerializationContext, e: Event) =
        var ex = e
        case ex.kind
        of yamlStartMap:
          if ctx.options.anchorStyle != asNone: ex.mapProperties.anchor = val.a
        of yamlStartSeq:
          if ctx.options.anchorStyle != asNone: ex.seqProperties.anchor = val.a
        of yamlScalar:
          if ctx.options.anchorStyle != asNone: ex.scalarProperties.anchor = val.a
          if not ctx.emitTag and guessType(ex.scalarContent) != yTypeNull:
            ex.scalarProperties.tag = yTagQuestionMark
        else: discard
        ctx.putImpl = origPut
        ctx.put(ex)
    ctx.representChild(value[])
    when nimvm: discard
    else:
      if ctx.options.anchorStyle == asNone: ctx.refs[p] = (val.a, false)

proc representChild*[T](
  ctx  : var SerializationContext,
  value: Option[T],
) {.raises: [YamlSerializationError].} =
  ## represents an optional value. If the value is missing, a !!null scalar
  ## will be produced.
  if value.isSome:
    ctx.representChild(value.get())
  else:
    ctx.put(scalarEvent("~", yTagNull, style = ctx.scalarStyleFor(Option[T])))

proc representChild*[O](
  ctx  : var SerializationContext,
  value: O,
) =
  when isImplicitVariantObject(O):
    # todo: this would probably be nicer if constructed with a macro
    var count = 0
    for name, field in fieldPairs(value):
      if count > 0: ctx.representChild(field)
      inc(count)
    if count == 1: ctx.put(scalarEvent("~", yTagNull))
  else:
    ctx.representObject(value, ctx.presentTag(O))

proc construct*[T](
  input : var YamlStream,
  target: var T,
)
    {.raises: [YamlStreamError, YamlConstructionError].} =
  ## Constructs a Nim value from a YAML stream.
  var context = initConstructionContext(input)
  try:
    var e = input.next()
    yAssert(e.kind == yamlStartDoc)

    context.constructChild(target)
    e = input.next()
    yAssert(e.kind == yamlEndDoc)
  except YamlConstructionError as e: raise e
  except YamlStreamError as e: raise e
  except CatchableError as ce:
    # may occur while calling ctx.input()
    var ex = newException(YamlStreamError, "error occurred while constructing")
    ex.parent = ce
    raise ex

proc represent*[T](
  value  : T,
  options: SerializationOptions = SerializationOptions(),
): YamlStream =
  ## Represents a Nim value as ``YamlStream``
  var
    bys = newBufferYamlStream()
    context = initSerializationContext(
      options,
      proc(ctx: var SerializationContext, e: Event) = bys.put(e)
    )
  bys.put(startStreamEvent())
  bys.put(startDocEvent(handles = options.handles))
  context.representChild(value)
  bys.put(endDocEvent())
  bys.put(endStreamEvent())
  if options.anchorStyle == asTidy:
    var ctx = initAnchorContext()
    for item in bys.mitems():
      case item.kind
      of yamlStartMap: ctx.process(item.mapProperties, context.refs)
      of yamlStartSeq: ctx.process(item.seqProperties, context.refs)
      of yamlScalar: ctx.process(item.scalarProperties, context.refs)
      of yamlAlias: item.aliasTarget = ctx.map(item.aliasTarget)
      else: discard
  result = bys
  