#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

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

proc next*(s: YamlStream): YamlStreamEvent =
  yAssert(not s.isFinished)
  if s.peeked:
    s.peeked = false
    shallowCopy(result, s.cached)
  else:
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
      echo cur.getStackTrace()
      var e = newException(YamlStreamError, cur.msg)
      e.parent = cur
      raise e