    #            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ==================
## Module yaml.stream
## ==================
##
## The stream API provides the basic data structure on which all low-level APIs
## operate. It is not named ``streams`` to not confuse it with the modle in the
## stdlib with that name.

import hashes
import private/internal, taglib

when defined(nimNoNil):
    {.experimental: "notnil".}
    
when defined(yamlScalarRepInd):
  type ScalarRepresentationIndicator* = enum
    srPlain, srSingleQuoted, srDoubleQuoted, srLiteral, srFolded

type
  AnchorId* = distinct int ## \
    ## An ``AnchorId`` identifies an anchor in the current document. It
    ## becomes invalid as soon as the current document scope is invalidated
    ## (for example, because the parser yielded a ``yamlEndDocument``
    ## event). ``AnchorId`` s exists because of efficiency, much like
    ## ``TagId`` s. The actual anchor name is a presentation detail and
    ## cannot be queried by the user.

  YamlStreamEventKind* = enum
    ## Kinds of YAML events that may occur in an ``YamlStream``. Event kinds
    ## are discussed in `YamlStreamEvent <#YamlStreamEvent>`_.
    yamlStartDoc, yamlEndDoc, yamlStartMap, yamlEndMap,
    yamlStartSeq, yamlEndSeq, yamlScalar, yamlAlias

  YamlStreamEvent* = object
    ## An element from a `YamlStream <#YamlStream>`_. Events that start an
    ## object (``yamlStartMap``, ``yamlStartSeq``, ``yamlScalar``) have
    ## an optional anchor and a tag associated with them. The anchor will be
    ## set to ``yAnchorNone`` if it doesn't exist.
    ##
    ## A non-existing tag in the YAML character stream will be resolved to
    ## the non-specific tags ``?`` or ``!`` according to the YAML
    ## specification. These are by convention mapped to the ``TagId`` s
    ## ``yTagQuestionMark`` and ``yTagExclamationMark`` respectively.
    ## Mapping is done by a `TagLibrary <#TagLibrary>`_.
    case kind*: YamlStreamEventKind
    of yamlStartMap:
      mapAnchor* : AnchorId
      mapTag*    : TagId
    of yamlStartSeq:
      seqAnchor* : AnchorId
      seqTag*    : TagId
    of yamlScalar:
      scalarAnchor* : AnchorId
      scalarTag*    : TagId
      scalarContent*: string # may not be nil (but empty)
      when defined(yamlScalarRepInd):
        scalarRep*  : ScalarRepresentationIndicator
    of yamlStartDoc:
      when defined(yamlScalarRepInd):
        explicitDirectivesEnd*: bool
      else: discard
    of yamlEndDoc:
      when defined(yamlScalarRepInd):
        explicitDocumentEnd*: bool
    of yamlEndMap, yamlEndSeq: discard
    of yamlAlias:
      aliasTarget* : AnchorId

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
    nextImpl*: proc(s: YamlStream, e: var YamlStreamEvent): bool
    lastTokenContextImpl*:
        proc(s: YamlStream, line, column: var int,
             lineContent: var string): bool {.raises: [].}
    isFinished*: bool
    peeked: bool
    cached: YamlStreamEvent

  YamlStreamError* = object of Exception
    ## Exception that may be raised by a ``YamlStream`` when the underlying
    ## backend raises an exception. The error that has occurred is
    ## available from ``parent``.

const
  yAnchorNone*: AnchorId = (-1).AnchorId ## \
    ## yielded when no anchor was defined for a YAML node

proc `==`*(left, right: AnchorId): bool {.borrow.}
proc `$`*(id: AnchorId): string {.borrow.}
proc hash*(id: AnchorId): Hash {.borrow.}

proc noLastContext(s: YamlStream, line, column: var int,
    lineContent: var string): bool {.raises: [].} =
  (line, column, lineContent) = (-1, -1, "")
  result = false

proc basicInit*(s: YamlStream, lastTokenContextImpl:
    proc(s: YamlStream, line, column: var int, lineContent: var string): bool
    {.raises: [].} = noLastContext) {.raises: [].} =
  ## initialize basic values of the YamlStream. Call this in your constructor
  ## if you subclass YamlStream.
  s.peeked = false
  s.isFinished = false
  s.lastTokenContextImpl = lastTokenContextImpl

when not defined(JS):
  type IteratorYamlStream = ref object of YamlStream
    backend: iterator(): YamlStreamEvent

  proc initYamlStream*(backend: iterator(): YamlStreamEvent): YamlStream
      {.raises: [].} =
    ## Creates a new ``YamlStream`` that uses the given iterator as backend.
    result = new(IteratorYamlStream)
    result.basicInit()
    IteratorYamlStream(result).backend = backend
    result.nextImpl = proc(s: YamlStream, e: var YamlStreamEvent): bool =
      e = IteratorYamlStream(s).backend()
      if finished(IteratorYamlStream(s).backend):
        s.isFinished = true
        result = false
      else: result = true

type
  BufferYamlStream* = ref object of YamlStream
    pos: int
    buf: seq[YamlStreamEvent]

proc newBufferYamlStream*(): BufferYamlStream not nil =
  result = cast[BufferYamlStream not nil](new(BufferYamlStream))
  result.basicInit()
  result.buf = @[]
  result.pos = 0
  result.nextImpl = proc(s: YamlStream, e: var YamlStreamEvent): bool =
    let bys = BufferYamlStream(s)
    if bys.pos == bys.buf.len:
      result = false
      s.isFinished = true
    else:
      e = bys.buf[bys.pos]
      inc(bys.pos)
      result = true

proc put*(bys: BufferYamlStream, e: YamlStreamEvent) {.raises: [].} =
  bys.buf.add(e)

proc next*(s: YamlStream): YamlStreamEvent {.raises: [YamlStreamError].} =
  ## Get the next item of the stream. Requires ``finished(s) == true``.
  ## If the backend yields an exception, that exception will be encapsulated
  ## into a ``YamlStreamError``, which will be raised.
  if s.peeked:
    s.peeked = false
    shallowCopy(result, s.cached)
    return
  else:
    yAssert(not s.isFinished)
    try:
      while true:
        if s.nextImpl(s, result): break
        yAssert(not s.isFinished)
    except YamlStreamError:
      let cur = getCurrentException()
      var e = newException(YamlStreamError, cur.msg)
      e.parent = cur.parent
      raise e
    except Exception:
      let cur = getCurrentException()
      var e = newException(YamlStreamError, cur.msg)
      e.parent = cur
      raise e

proc peek*(s: YamlStream): YamlStreamEvent {.raises: [YamlStreamError].} =
  ## Get the next item of the stream without advancing the stream.
  ## Requires ``finished(s) == true``. Handles exceptions of the backend like
  ## ``next()``.
  if not s.peeked:
    shallowCopy(s.cached, s.next())
    s.peeked = true
  shallowCopy(result, s.cached)

proc `peek=`*(s: YamlStream, value: YamlStreamEvent) {.raises: [].} =
  ## Set the next item of the stream. Will replace a previously peeked item,
  ## if one exists.
  s.cached = value
  s.peeked = true

proc finished*(s: YamlStream): bool {.raises: [YamlStreamError].} =
  ## ``true`` if no more items are available in the stream. Handles exceptions
  ## of the backend like ``next()``.
  if s.peeked: result = false
  else:
    try:
      while true:
        if s.isFinished: return true
        if s.nextImpl(s, s.cached):
          s.peeked = true
          return false
    except YamlStreamError:
      let cur = getCurrentException()
      var e = newException(YamlStreamError, cur.msg)
      e.parent = cur.parent
      raise e
    except Exception:
      let cur = getCurrentException()
      var e = newException(YamlStreamError, cur.msg)
      e.parent = cur
      raise e

proc getLastTokenContext*(s: YamlStream, line, column: var int,
    lineContent: var string): bool =
  ## ``true`` if source context information is available about the last returned
  ## token. If ``true``, line, column and lineContent are set to position and
  ## line content where the last token has been read from.
  result = s.lastTokenContextImpl(s, line, column, lineContent)

iterator items*(s: YamlStream): YamlStreamEvent
    {.raises: [YamlStreamError].} =
  ## Iterate over all items of the stream. You may not use ``peek()`` on the
  ## stream while iterating.
  while not s.finished(): yield s.next()

iterator mitems*(bys: BufferYamlStream): var YamlStreamEvent {.raises: [].} =
  ## Iterate over all items of the stream. You may not use ``peek()`` on the
  ## stream while iterating.
  for e in bys.buf.mitems(): yield e

proc `==`*(left: YamlStreamEvent, right: YamlStreamEvent): bool {.raises: [].} =
  ## compares all existing fields of the given items
  if left.kind != right.kind: return false
  case left.kind
  of yamlStartDoc, yamlEndDoc, yamlEndMap, yamlEndSeq: result = true
  of yamlStartMap:
    result = left.mapAnchor == right.mapAnchor and left.mapTag == right.mapTag
  of yamlStartSeq:
    result = left.seqAnchor == right.seqAnchor and left.seqTag == right.seqTag
  of yamlScalar:
    result = left.scalarAnchor == right.scalarAnchor and
             left.scalarTag == right.scalarTag and
             left.scalarContent == right.scalarContent
  of yamlAlias: result = left.aliasTarget == right.aliasTarget

proc renderAttrs(tag: TagId, anchor: AnchorId, isPlain: bool = true): string =
  result = ""
  if anchor != yAnchorNone: result &= " &" & $anchor
  case tag
  of yTagQuestionmark: discard
  of yTagExclamationmark:
    when defined(yamlScalarRepInd):
      if isPlain: result &= " <!>"
  else:
    result &= " <" & $tag & ">"

proc `$`*(event: YamlStreamEvent): string {.raises: [].} =
  ## outputs a human-readable string describing the given event.
  ## This string is compatible to the format used in the yaml test suite.
  case event.kind
  of yamlEndMap: result = "-MAP"
  of yamlEndSeq: result = "-SEQ"
  of yamlStartDoc:
    result = "+DOC"
    when defined(yamlScalarRepInd):
      if event.explicitDirectivesEnd: result &= " ---"
  of yamlEndDoc:
    result = "-DOC"
    when defined(yamlScalarRepInd):
      if event.explicitDocumentEnd: result &= " ..."
  of yamlStartMap: result = "+MAP" & renderAttrs(event.mapTag, event.mapAnchor)
  of yamlStartSeq: result = "+SEQ" & renderAttrs(event.seqTag, event.seqAnchor)
  of yamlScalar:
    when defined(yamlScalarRepInd):
      result = "=VAL" & renderAttrs(event.scalarTag, event.scalarAnchor,
                                    event.scalarRep == srPlain)
      case event.scalarRep
      of srPlain: result &= " :"
      of srSingleQuoted: result &= " \'"
      of srDoubleQuoted: result &= " \""
      of srLiteral: result &= " |"
      of srFolded: result &= " >"
    else:
      result = "=VAL" & renderAttrs(event.scalarTag, event.scalarAnchor,
                                    false)
      if event.scalarTag == yTagExclamationmark: result &= " \""
      else: result &= " :"
    result &= yamlTestSuiteEscape(event.scalarContent)
  of yamlAlias: result = "=ALI *" & $event.aliasTarget

proc tag*(event: YamlStreamEvent): TagId {.raises: [FieldError].} =
  ## returns the tag of the given event
  case event.kind
  of yamlStartMap: result = event.mapTag
  of yamlStartSeq: result = event.seqTag
  of yamlScalar: result = event.scalarTag
  else: raise newException(FieldError, "Event " & $event.kind & " has no tag")

when defined(yamlScalarRepInd):
  proc startDocEvent*(explicit: bool = false): YamlStreamEvent
      {.inline, raises: [].} =
    ## creates a new event that marks the start of a YAML document
    result = YamlStreamEvent(kind: yamlStartDoc,
                             explicitDirectivesEnd: explicit)

  proc endDocEvent*(explicit: bool = false): YamlStreamEvent
      {.inline, raises: [].} =
    ## creates a new event that marks the end of a YAML document
    result = YamlStreamEvent(kind: yamlEndDoc, explicitDocumentEnd: explicit)
else:
  proc startDocEvent*(): YamlStreamEvent {.inline, raises: [].} =
    ## creates a new event that marks the start of a YAML document
    result = YamlStreamEvent(kind: yamlStartDoc)

  proc endDocEvent*(): YamlStreamEvent {.inline, raises: [].} =
    ## creates a new event that marks the end of a YAML document
    result = YamlStreamEvent(kind: yamlEndDoc)

proc startMapEvent*(tag: TagId = yTagQuestionMark,
    anchor: AnchorId = yAnchorNone): YamlStreamEvent {.inline, raises: [].} =
  ## creates a new event that marks the start of a YAML mapping
  result = YamlStreamEvent(kind: yamlStartMap, mapTag: tag, mapAnchor: anchor)

proc endMapEvent*(): YamlStreamEvent {.inline, raises: [].} =
  ## creates a new event that marks the end of a YAML mapping
  result = YamlStreamEvent(kind: yamlEndMap)

proc startSeqEvent*(tag: TagId = yTagQuestionMark,
    anchor: AnchorId = yAnchorNone): YamlStreamEvent {.inline, raises: [].} =
  ## creates a new event that marks the beginning of a YAML sequence
  result = YamlStreamEvent(kind: yamlStartSeq, seqTag: tag, seqAnchor: anchor)

proc endSeqEvent*(): YamlStreamEvent {.inline, raises: [].} =
  ## creates a new event that marks the end of a YAML sequence
  result = YamlStreamEvent(kind: yamlEndSeq)

when defined(yamlScalarRepInd):
  proc scalarEvent*(content: string = "", tag: TagId = yTagQuestionMark,
      anchor: AnchorId = yAnchorNone,
      scalarRep: ScalarRepresentationIndicator = srPlain):
      YamlStreamEvent {.inline, raises: [].} =
    ## creates a new event that represents a YAML scalar
    result = YamlStreamEvent(kind: yamlScalar, scalarTag: tag,
                            scalarAnchor: anchor, scalarContent: content,
                            scalarRep: scalarRep)
else:
  proc scalarEvent*(content: string = "", tag: TagId = yTagQuestionMark,
      anchor: AnchorId = yAnchorNone): YamlStreamEvent {.inline, raises: [].} =
    ## creates a new event that represents a YAML scalar
    result = YamlStreamEvent(kind: yamlScalar, scalarTag: tag,
                            scalarAnchor: anchor, scalarContent: content)

proc aliasEvent*(anchor: AnchorId): YamlStreamEvent {.inline, raises: [].} =
  ## creates a new event that represents a YAML alias
  result = YamlStreamEvent(kind: yamlAlias, aliasTarget: anchor)
