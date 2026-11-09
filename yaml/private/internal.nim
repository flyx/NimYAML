#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import tables
import ../data

# Tracking refs by identity (for anchors and aliases). On native backends, this
# uses raw pointers. The JS backend has no raw pointers (casting a ref to
# ``pointer`` generates invalid code), so there we use a JS ``Map``, which
# compares object keys by identity.
when defined(js):
  type
    RefPtr* = ref object
      ## opaque reference to an arbitrary ref value
    RefTable*[V] {.importjs: "Map".} = ref object
      ## maps refs, compared by identity, to values of type ``V``

  proc toRefPtr*[T](r: ref T): RefPtr {.importjs: "(#)".}
  proc fromRefPtr*[T](p: RefPtr): T {.importjs: "(#)".}

  proc initRefTable*[V](): RefTable[V] {.importjs: "new Map()".}
  proc hasKey*[V](t: RefTable[V], key: RefPtr): bool {.importjs: "#.has(#)".}
  proc jsGet[V](t: RefTable[V], key: RefPtr): V {.importjs: "#.get(#)".}
  proc jsSet[V](t: RefTable[V], key: RefPtr, val: V) {.importjs: "#.set(#, #)".}
  proc jsValues[V](t: RefTable[V]): seq[V] {.importjs: "Array.from(#.values())".}

  proc `[]=`*[V](t: RefTable[V], key: RefPtr, val: V) =
    var copy = val # do not alias the caller's value
    t.jsSet(key, copy)

  proc getOrDefault*[V](t: RefTable[V], key: RefPtr, default: V): V =
    if t.hasKey(key): t.jsGet(key) else: default

  proc getOrDefault*[V](t: RefTable[V], key: RefPtr): V =
    if t.hasKey(key): result = t.jsGet(key)

  iterator values*[V](t: RefTable[V]): V =
    for v in t.jsValues(): yield v
else:
  type
    RefPtr* = pointer
    RefTable*[V] = Table[pointer, V]

  template toRefPtr*(r: ref): RefPtr = cast[pointer](r)
  proc fromRefPtr*[T](p: RefPtr): T {.inline.} = cast[T](p)

  proc initRefTable*[V](): RefTable[V] = initTable[pointer, V]()

template internalError*(s: string) =
  # Note: to get the internal stacktrace that caused the error
  # compile with the `d:debug` flag.
  when not defined(release):
    let ii = instantiationInfo()
    echo "[NimYAML] Error in file ", ii.filename, " at line ", ii.line, ":"
    echo s
    when not defined(JS):
      try:
        var exc = getCurrentException()
        while not isNil(exc):
          echo "… stacktrace [", exc.name, ": ", exc.msg, "]"
          echo getStackTrace(exc)
          exc = exc.parent
      except CatchableError: discard
    echo "[NimYAML] Please report this bug."
    quit 1

template yAssert*(e: typed) =
  when not defined(release):
    if not e:
      let ii = instantiationInfo()
      echo "[NimYAML] Error in file ", ii.filename, " at line ", ii.line, ":"
      echo "assertion failed!"
      when not defined(JS):
        echo "[NimYAML] Stacktrace:"
        try:
          writeStackTrace()
          let exc = getCurrentException()
          if not isNil(exc.parent):
            echo "Internal stacktrace:"
            echo getStackTrace(exc.parent)
        except CatchableError: discard
      echo "[NimYAML] Please report this bug."
      quit 1

proc nextAnchor*(s: var string, i: int) =
  if s[i] == 'z':
    s[i] = 'a'
    if i == 0:
      s.add('a')
    else:
      s[i] = 'a'
      nextAnchor(s, i - 1)
  else:
    s[i] = char(int(s[i]) + 1)

template resetHandles*(handles: var seq[tuple[handle, uriPrefix: string]]) {.dirty.} =
  handles.setLen(0)
  handles.add(("!", "!"))
  handles.add(("!!", yamlTagRepositoryPrefix))

proc registerHandle*(handles: var seq[tuple[handle, uriPrefix: string]], handle, uriPrefix: string): bool =
  for i in countup(0, len(handles)-1):
    if handles[i].handle == handle:
      handles[i].uriPrefix = uriPrefix
      return false
  handles.add((handle, uriPrefix))
  return false

type
  AnchorContext* = object
    nextAnchorId: string
    mapping: Table[Anchor, Anchor]

proc initAnchorContext*(): AnchorContext =
  return AnchorContext(nextAnchorId: "a", mapping: initTable[Anchor, Anchor]())

proc process*(context: var AnchorContext,
    target: var Properties, refs: RefTable[tuple[a: Anchor, referenced: bool]]) =
  if target.anchor == yAnchorNone: return
  for val in refs.values:
    if val.a == target.anchor:
      if not val.referenced:
        target.anchor = yAnchorNone
        return
      break
  if context.mapping.hasKey(target.anchor):
    target.anchor = context.mapping.getOrDefault(target.anchor)
  else:
    let old = move(target.anchor)
    target.anchor = context.nextAnchorId.Anchor
    nextAnchor(context.nextAnchorId, len(context.nextAnchorId)-1)
    context.mapping[old] = target.anchor

proc map*(context: AnchorContext, anchor: Anchor): Anchor =
  return context.mapping.getOrDefault(anchor)