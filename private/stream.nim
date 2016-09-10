#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

when not defined(JS):
  type IteratorYamlStream = ref object of YamlStream
    backend: iterator(): YamlStreamEvent

  proc initYamlStream*(backend: iterator(): YamlStreamEvent): YamlStream =
    result = new(IteratorYamlStream)
    result.peeked = false
    result.isFinished = false
    IteratorYamlStream(result).backend = backend
    result.nextImpl = proc(s: YamlStream, e: var YamlStreamEvent): bool =
      e = IteratorYamlStream(s).backend()
      if finished(IteratorYamlStream(s).backend):
        s.isFinished = true
        result = false
      else: result = true

type
  BufferYamlStream = ref object of YamlStream
    pos: int
    buf: seq[YamlStreamEvent] not nil

proc newBufferYamlStream(): BufferYamlStream not nil =
  BufferYamlStream(peeked: false, isFinished: false, buf: @[], pos: 0,
      nextImpl: proc(s: YamlStream, e: var YamlStreamEvent): bool =
        let bys = BufferYamlStream(s)
        if bys.pos == bys.buf.len:
          result = false
          s.isFinished = true
        else:
          e = bys.buf[bys.pos]
          inc(bys.pos)
          result = true
  )

proc next*(s: YamlStream): YamlStreamEvent =
  if s.peeked:
    s.peeked = false
    shallowCopy(result, s.cached)
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

proc peek*(s: YamlStream): YamlStreamEvent =
  if not s.peeked:
    s.cached = s.next()
    s.peeked = true
  shallowCopy(result, s.cached)

proc `peek=`*(s: YamlStream, value: YamlStreamEvent) =
  s.cached = value
  s.peeked = true

proc finished*(s: YamlStream): bool =
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
