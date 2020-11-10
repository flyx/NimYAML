#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import tables
import ../data

template internalError*(s: string) =
  # Note: to get the internal stacktrace that caused the error
  # compile with the `d:debug` flag.
  when not defined(release):
    let ii = instantiationInfo()
    echo "[NimYAML] Error in file ", ii.filename, " at line ", ii.line, ":"
    echo s
    when not defined(JS):
      echo "[NimYAML] Stacktrace:"
      try:
        writeStackTrace()
        let exc = getCurrentException()
        if not isNil(exc.parent):
          echo "Internal stacktrace:"
          echo getStackTrace(exc.parent)
      except: discard
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
        except: discard
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
    inc(s[i])

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
    target: var Properties, refs: Table[pointer, tuple[a: Anchor, referenced: bool]]) =
  if target.anchor == yAnchorNone: return
  for key, val in refs:
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