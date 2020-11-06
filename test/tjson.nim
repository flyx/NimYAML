#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import "../yaml"

import unittest, json

proc ensureEqual(yamlIn, jsonIn: string) =
  try:
    var
      parser = initYamlParser(initCoreTagLibrary(), true)
      s = parser.parse(yamlIn)
      yamlResult = constructJson(s)
      jsonResult = parseJson(jsonIn)
    assert yamlResult.len == 1
    assert(jsonResult == yamlResult[0], "Expected: " & $jsonResult & ", got: " &
        $yamlResult[0])
  except YamlStreamError:
    let e = (ref YamlParserError)(getCurrentException().parent)
    echo "error occurred: " & e.msg
    echo "line: ", e.mark.line, ", column: ", e.mark.column
    echo e.lineContent
    raise e

suite "Constructing JSON":
  test "Simple Sequence":
    ensureEqual("- 1\n- 2\n- 3", "[1, 2, 3]")

  test "Simple Map":
    ensureEqual("a: b\nc: d", """{"a": "b", "c": "d"}""")

  test "Complex Structure":
    ensureEqual("""
%YAML 1.2
---
Foo:
  - - a
    - b
    - c
  - bla: blubb
Numbers, bools, special values:
 - 1
 - true
 - ~
 - 42.23
 - no
""", """{
"Foo": [
    [ "a", "b", "c"],
    { "bla": "blubb"}
],
"Numbers, bools, special values": [
    1, true, null, 42.23, false
]
}""")