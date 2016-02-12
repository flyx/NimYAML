import "../yaml"

import unittest, json

proc wc(line, column: int, lineContent: string, message: string) =
    echo "Warning (", line, ",", column, "): ", message, "\n", lineContent

proc ensureEqual(yamlIn, jsonIn: string) =
    var
        parser = newYamlParser(initCoreTagLibrary(), wc)
        s = parser.parse(newStringStream(yamlIn))
        yamlResult = constructJson(s)
        jsonResult = parseJson(jsonIn)
    assert yamlResult.len == 1
    assert(jsonResult == yamlResult[0])

suite "Constructing JSON":
    test "Constructing JSON: Simple Sequence":
        ensureEqual("- 1\n- 2\n- 3", "[1, 2, 3]")
    
    test "Constructing JSON: Simple Map":
        ensureEqual("a: b\nc: d", """{"a": "b", "c": "d"}""")
    
    test "Constructing JSON: Complex Structure":
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