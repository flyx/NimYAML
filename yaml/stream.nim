    #            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ==================
## Module yaml/stream
## ==================
##
## The stream API provides the basic data structure on which all low-level APIs
## operate. It is not named ``streams`` to not confuse it with the modle in the
## stdlib with that name.

import data

when defined(nimNoNil):
    {.experimental: "notnil".}

type
  YamlStream* = ref object of RootObj ## \
    ## A ``YamlStream`` is an iterator-like object that yields a
    ## well-formed stream of ``YamlStreamEvents``. Well-formed means that
    ## every ``yamlStartMap`` is terminated by a ``yamlEndMap``, every
    ## ``yamlStartSeq`` is terminated by a ``yamlEndSeq`` and every
    ## ``yamlStartDoc`` is terminated by a ``yamlEndDoc``. Moreover, every
    ## emitted mapping has an even number of children.
    ##
    ## The creator of a ``YamlStream`` is responsible for it being
    ## well-formed. A user of the stream may assume that it is well-formed
    ## and is not required to check for it. The procs in this module will
    ## always yield a well-formed ``YamlStream`` and expect it to be
    ## well-formed if they take it as input parameter.
    nextImpl*: proc(s: YamlStream, e: var Event): bool {.gcSafe.}
    lastTokenContextImpl*:
        proc(s: YamlStream, lineContent: var string): bool {.raises: [].}
    peeked: bool
    cached: Event

  YamlStreamError* = object of ValueError
    ## Exception that may be raised by a ``YamlStream`` when the underlying
    ## backend raises an exception. The error that has occurred is
    ## available from ``parent``.

proc noLastContext(s: YamlStream, lineContent: var string): bool {.raises: [].} =
  result = false

proc basicInit*(s: YamlStream, lastTokenContextImpl:
    proc(s: YamlStream, lineContent: var string): bool
    {.raises: [].} = noLastContext) {.raises: [].} =
  ## initialize basic values of the YamlStream. Call this in your constructor
  ## if you subclass YamlStream.
  s.peeked = false
  s.lastTokenContextImpl = lastTokenContextImpl

when not defined(JS):
  type IteratorYamlStream = ref object of YamlStream
    backend: iterator(): Event {.gcSafe.}

  proc initYamlStream*(backend: iterator(): Event {.gcSafe.}): YamlStream
      {.raises: [].} =
    ## Creates a new ``YamlStream`` that uses the given iterator as backend.
    result = new(IteratorYamlStream)
    result.basicInit()
    IteratorYamlStream(result).backend = backend
    result.nextImpl = proc(s: YamlStream, e: var Event): bool {.gcSafe.} =
      e = IteratorYamlStream(s).backend()
      result = true

type
  BufferYamlStream* = ref object of YamlStream
    pos: int
    buf: seq[Event]

proc newBufferYamlStream*(): BufferYamlStream not nil =
  result = cast[BufferYamlStream not nil](new(BufferYamlStream))
  result.basicInit()
  result.buf = @[]
  result.pos = 0
  result.nextImpl = proc(s: YamlStream, e: var Event): bool =
    let bys = BufferYamlStream(s)
    e = bys.buf[bys.pos]
    inc(bys.pos)
    result = true

proc put*(bys: BufferYamlStream, e: Event) {.raises: [].} =
  bys.buf.add(e)

proc next*(s: YamlStream): Event {.raises: [YamlStreamError], gcSafe.} =
  ## Get the next item of the stream. Requires ``finished(s) == true``.
  ## If the backend yields an exception, that exception will be encapsulated
  ## into a ``YamlStreamError``, which will be raised.
  if s.peeked:
    s.peeked = false
    return move(s.cached)
  else:
    try:
      while true:
        if s.nextImpl(s, result): break
    except YamlStreamError:
      raise (ref YamlStreamError)(getCurrentException())
    except Exception:
      let cur = getCurrentException()
      var e = newException(YamlStreamError, cur.msg)
      e.parent = cur
      raise e

proc peek*(s: YamlStream): lent Event {.raises: [YamlStreamError].} =
  ## Get the next item of the stream without advancing the stream.
  ## Requires ``finished(s) == true``. Handles exceptions of the backend like
  ## ``next()``.
  if not s.peeked:
    s.cached = s.next()
    s.peeked = true
  result = s.cached

proc `peek=`*(s: YamlStream, value: Event) {.raises: [].} =
  ## Set the next item of the stream. Will replace a previously peeked item,
  ## if one exists.
  s.cached = value
  s.peeked = true

proc getLastTokenContext*(s: YamlStream, lineContent: var string): bool =
  ## ``true`` if source context information is available about the last returned
  ## token. If ``true``, line, column and lineContent are set to position and
  ## line content where the last token has been read from.
  result = s.lastTokenContextImpl(s, lineContent)

iterator items*(s: YamlStream): Event
    {.raises: [YamlStreamError].} =
  ## Iterate over all items of the stream. You may not use ``peek()`` on the
  ## stream while iterating.
  while true:
    let e = s.next()
    var last = e.kind == yamlEndStream
    yield e
    if last: break

iterator mitems*(bys: BufferYamlStream): var Event {.raises: [].} =
  ## Iterate over all items of the stream. You may not use ``peek()`` on the
  ## stream while iterating.
  for e in bys.buf.mitems(): yield e
