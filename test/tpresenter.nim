#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import std/[ options, strutils ]
import ../yaml/[ presenter, data, stream ]
import unittest
import commonTestUtils

proc inputSingle(events: varargs[Event]): BufferYamlStream =
  result = newBufferYamlStream()
  result.put(startStreamEvent())
  result.put(startDocEvent())
  for event in events: result.put(event)
  result.put(endDocEvent())
  result.put(endStreamEvent())

let minimalOptions = PresentationOptions(outputVersion: ovNone)

proc assertOutput(
    input: YamlStream, expected: string,
    options: PresentationOptions = minimalOptions) =
  var output = present(input, options)
  assertStringEqual expected, output

suite "Presenter":
  test "Scalar with tag":
    var input = inputSingle(scalarEvent("droggeljug", yTagString))
    assertOutput(input, "--- !!str\ndroggeljug\n")
  
  test "Scalar without tag":
    var input = inputSingle(scalarEvent("droggeljug"))
    assertOutput(input, "droggeljug\n")
  
  test "Root block scalar":
    var input = inputSingle(scalarEvent("I am a dwarf and I'm digging a hole\n  diggy diggy hole\n  diggy diggy hole\n"))
    assertOutput(input,
      "--- |\n" &
      "I am a dwarf and I'm digging a hole\n" & 
      "  diggy diggy hole\n" &
      "  diggy diggy hole\n",
      PresentationOptions(maxLineLength: some(40)))
    
  test "Compact flow sequence":
    var input = inputSingle(startSeqEvent(), scalarEvent("1"), scalarEvent("2"), endSeqEvent())
    assertOutput(input, "[1, 2]\n")
  
  test "Forced block sequence":
    var input = inputSingle(startSeqEvent(), scalarEvent("1"), scalarEvent("2"), endSeqEvent())
    assertOutput(input, "- 1\n- 2\n", PresentationOptions(outputVersion: ovNone, containers: cBlock))
  
  test "Forced multiline flow sequence":
    var input = inputSingle(startSeqEvent(), scalarEvent("1"), scalarEvent("2"), endSeqEvent())
    assertOutput(input, "[\n  1,\n  2\n]\n", PresentationOptions(outputVersion: ovNone, condenseFlow: false))
    
  test "Compact flow mapping":
    var input = inputSingle(startMapEvent(), scalarEvent("1"), scalarEvent("2"), endMapEvent())
    assertOutput(input, "{1: 2}\n", PresentationOptions(outputVersion: ovNone, containers: cFlow))
  
  test "Simple block mapping":
    var input = inputSingle(startMapEvent(), scalarEvent("1"), scalarEvent("2"), endMapEvent())
    assertOutput(input, "1: 2\n", PresentationOptions(outputVersion: ovNone))
  
  test "Forced multiline flow mapping":
    var input = inputSingle(startMapEvent(), scalarEvent("1"), scalarEvent("2"), endMapEvent())
    assertOutput(input, "{\n  1: 2\n}\n", PresentationOptions(outputVersion: ovNone, condenseFlow: false, containers: cFlow))
  
  test "Forced JSON mapping":
    var input = inputSingle(startMapEvent(), scalarEvent("1"), scalarEvent("2"), endMapEvent())
    assertOutput(input, "{\n  \"1\": 2\n}\n", PresentationOptions(outputVersion: ovNone, condenseFlow: false, containers: cFlow, quoting: sqJson))
  
  test "Nested flow sequence":
    var input = inputSingle(startMapEvent(), scalarEvent("a"), startSeqEvent(), scalarEvent("1"), scalarEvent("2"), endSeqEvent(), endMapEvent())
    assertOutput(input, "a: [1, 2]\n")
  
  test "Nested block sequence":
    var input = inputSingle(startMapEvent(), scalarEvent("a"), startSeqEvent(), scalarEvent("1"), scalarEvent("2"), endSeqEvent(), endMapEvent())
    assertOutput(input, "a:\n  - 1\n  - 2\n", PresentationOptions(outputVersion: ovNone, containers: cBlock))
  
  test "Compact notation: mapping in sequence":
    var input = inputSingle(startSeqEvent(), scalarEvent("a"), startMapEvent(), scalarEvent("1"), scalarEvent("2"),   
        scalarEvent("3"), scalarEvent("4"), endMapEvent(), endSeqEvent())
    assertOutput(input, "- a\n- 1: 2\n  3: 4\n")
  
  test "No compact notation: sequence in mapping":
    var input = inputSingle(startMapEvent(), scalarEvent("a"), startSeqEvent(), scalarEvent("1"), endSeqEvent(), endMapEvent())
    assertOutput(input, "a:\n  - 1\n", PresentationOptions(outputVersion: ovNone, containers: cBlock))
  
  test "Compact notation with 4 spaces indentation":
    var input = inputSingle(startSeqEvent(), scalarEvent("a"), startMapEvent(), scalarEvent("1"), scalarEvent("2"),   
        scalarEvent("3"), scalarEvent("4"), endMapEvent(), endSeqEvent())
    assertOutput(input, "-   a\n-   1: 2\n    3: 4\n", PresentationOptions(outputVersion: ovNone, indentationStep: 4))
  
  test "Compact notation with 4 spaces indentation, more complex input":
    var input = inputSingle(startMapEvent(), scalarEvent("root"), startSeqEvent(), scalarEvent("a"),
        startMapEvent(), scalarEvent("1"), scalarEvent("2"), scalarEvent("3"), scalarEvent("4"), endMapEvent(),
        endSeqEvent(), endMapEvent())
    assertOutput(input, "root:\n    -   a\n    -   1: 2\n        3: 4\n", PresentationOptions(outputVersion: ovNone, indentationStep: 4))
  
  test "Scalar output with explicit style set":
    var input = inputSingle(
      startSeqEvent(), scalarEvent("plain", style = ssPlain),
      scalarEvent("@noplain", style = ssPlain),
      scalarEvent("literal\n", style = ssLiteral),
      scalarEvent("nofolded ", style = ssFolded),
      scalarEvent("folded scalar", style = ssFolded),
      scalarEvent("single'", style = ssSingleQuoted),
      endSeqEvent()
    )
    assertOutput(input, "- plain\n" &
      "- \"@noplain\"\n" &
      "- |\n" &
      "  literal\n" &
      "- \"nofolded \"\n" &
      "- >-\n" &
      "  folded scalar\n" &
      "- 'single'''\n")
      
  test "Collection output with explicit style set":
    var input = inputSingle(
      startMapEvent(), scalarEvent("a", style = ssDoubleQuoted),
      startSeqEvent(style = csFlow), scalarEvent("b"), scalarEvent("c"), scalarEvent("d"), endSeqEvent(),
      scalarEvent("? e"), startSeqEvent(style = csBlock), scalarEvent("f"), endSeqEvent(),
      scalarEvent("g"), startMapEvent(), scalarEvent("h"), scalarEvent("i"), endMapEvent(),
      scalarEvent("j"), startMapEvent(), scalarEvent("k", style = ssLiteral), scalarEvent("l"), endMapEvent(),
      endMapEvent()
    )
    assertOutput(input, "\"a\": [b, c, d]\n" &
      "\"? e\":\n" &
      "  - f\n" &
      "g: {h: i}\n" &
      "j:\n" &
      "  ? |-\n" &
      "    k\n" &
      "  : l\n")
  
  test "Block mapping with multiline keys":
    var input = inputSingle(
      startMapEvent(), scalarEvent(repeat("a", 18)), scalarEvent("b"),
      scalarEvent(repeat("\"", 8)), scalarEvent("c"),
      scalarEvent(repeat("d", 17)), scalarEvent("e"), endMapEvent())
    assertOutput(input, "? \"aaaaaaaaaaaaaaa\\\n" &
      "  aaa\"\n" &
      ": b\n" &
      "? \"\\\"\\\"\\\"\\\"\\\"\\\"\\\"\\\n" &
      "  \\\"\"\n" &
      ": c\n" &
      "ddddddddddddddddd:\n" &
      "  e\n", PresentationOptions(maxLineLength: some(19)))