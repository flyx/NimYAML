#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import ../yaml, ../yaml/data

proc escapeNewlines(s: string): string =
  result = ""
  for c in s:
    case c
    of '\l': result.add("\\n")
    of '\t': result.add("\\t")
    of '\\': result.add("\\\\")
    else: result.add(c)

proc printDifference(entity: string, expected, actual: Properties): bool =
  result = false
  if expected.tag != actual.tag:
    echo "[", entity, ".tag] expected ", $expected.tag, ", got ", $actual.tag
    result = true
  if expected.anchor != actual.anchor:
    echo "[", entity, ".anchor] expected ", $expected.anchor, ", got ", $actual.anchor
    result = true

proc printDifference*(expected, actual: Event) =
  if expected.kind != actual.kind:
    echo "expected ", expected.kind, ", got ", $actual.kind
  else:
    case expected.kind
    of yamlScalar:
      if not printDifference("scalar", expected.scalarProperties, actual.scalarProperties):
        if expected.scalarContent != actual.scalarContent:
          let msg = "[scalarEvent] content mismatch!\nexpected: " &
                escapeNewlines(expected.scalarContent) &
                "\ngot     : " & escapeNewlines(actual.scalarContent)
          if expected.scalarContent.len != actual.scalarContent.len:
            echo msg, "\n(length does not match)"
          else:
            for i in 0..expected.scalarContent.high:
              if expected.scalarContent[i] != actual.scalarContent[i]:
                echo msg, "\n(first different char at pos ", i, ": expected ",
                    cast[int](expected.scalarContent[i]), ", got ",
                    cast[int](actual.scalarContent[i]), ")"
                break
        else: echo "[scalar] Unknown difference"
    of yamlStartMap:
      if not printDifference("map", expected.mapProperties, actual.mapProperties):
        echo "[map] Unknown difference"
    of yamlStartSeq:
      if not printDifference("seq", expected.seqProperties, actual.seqProperties):
        echo "[seq] Unknown difference"
    of yamlAlias:
      if expected.aliasTarget != actual.aliasTarget:
        echo "[alias] expected ", expected.aliasTarget, ", got ",
           actual.aliasTarget
      else: echo "[alias] Unknown difference"
    else: echo "Unknown difference in event kind " & $expected.kind

template ensure*(input: var YamlStream,
                 expected: varargs[Event]) {.dirty.} =
  var i = 0
  for token in input:
    if i >= expected.len:
      echo "received more tokens than expected (next token = ", token.kind, ")"
      fail()
      break
    if token != expected[i]:
      echo "at event #" & $i & ":"
      printDifference(expected[i], token)
      fail()
      break
    i.inc()