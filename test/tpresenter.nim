import ../yaml
import unittest, strutils
import commonTestUtils

proc inputSingle(events: varargs[Event]): BufferYamlStream =
  result = newBufferYamlStream()
  result.put(startStreamEvent())
  result.put(startDocEvent())
  for event in events: result.put(event)
  result.put(endDocEvent())
  result.put(endStreamEvent())

let minimalOptions = defineOptions(outputVersion = ovNone)

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
    
  test "Compact flow sequence":
    var input = inputSingle(startSeqEvent(), scalarEvent("1"), scalarEvent("2"), endSeqEvent())
    assertOutput(input, "[1, 2]\n")
  
  test "Forced block sequence":
    var input = inputSingle(startSeqEvent(), scalarEvent("1"), scalarEvent("2"), endSeqEvent())
    assertOutput(input, "- 1\n- 2\n", defineOptions(outputVersion = ovNone, containers = cBlock))
  
  test "Forced multiline flow sequence":
    var input = inputSingle(startSeqEvent(), scalarEvent("1"), scalarEvent("2"), endSeqEvent())
    assertOutput(input, "[\n  1,\n  2\n]\n", defineOptions(outputVersion = ovNone, condenseFlow = false))
    
  test "Compact flow mapping":
    var input = inputSingle(startMapEvent(), scalarEvent("1"), scalarEvent("2"), endMapEvent())
    assertOutput(input, "{1: 2}\n", defineOptions(outputVersion = ovNone, containers = cFlow))
  
  test "Simple block mapping":
    var input = inputSingle(startMapEvent(), scalarEvent("1"), scalarEvent("2"), endMapEvent())
    assertOutput(input, "1: 2\n", defineOptions(outputVersion = ovNone))
  
  test "Forced multiline flow mapping":
    var input = inputSingle(startMapEvent(), scalarEvent("1"), scalarEvent("2"), endMapEvent())
    assertOutput(input, "{\n  1: 2\n}\n", defineOptions(outputVersion = ovNone, condenseFlow = false, containers = cFlow))
  
  test "Forced JSON mapping":
    var input = inputSingle(startMapEvent(), scalarEvent("1"), scalarEvent("2"), endMapEvent())
    assertOutput(input, "{\n  \"1\": 2\n}\n", defineOptions(outputVersion = ovNone, condenseFlow = false, containers = cFlow, quoting = sqJson))
  
  test "Nested flow sequence":
    var input = inputSingle(startMapEvent(), scalarEvent("a"), startSeqEvent(), scalarEvent("1"), scalarEvent("2"), endSeqEvent(), endMapEvent())
    assertOutput(input, "a: [1, 2]\n")
  
  test "Nested block sequence":
    var input = inputSingle(startMapEvent(), scalarEvent("a"), startSeqEvent(), scalarEvent("1"), scalarEvent("2"), endSeqEvent(), endMapEvent())
    assertOutput(input, "a:\n  - 1\n  - 2\n", defineOptions(outputVersion = ovNone, containers = cBlock))
  
  test "Compact notation: mapping in sequence":
    var input = inputSingle(startSeqEvent(), scalarEvent("a"), startMapEvent(), scalarEvent("1"), scalarEvent("2"),   
        scalarEvent("3"), scalarEvent("4"), endMapEvent(), endSeqEvent())
    assertOutput(input, "- a\n- 1: 2\n  3: 4\n")
  
  test "No compact notation: sequence in mapping":
    var input = inputSingle(startMapEvent(), scalarEvent("a"), startSeqEvent(), scalarEvent("1"), endSeqEvent(), endMapEvent())
    assertOutput(input, "a:\n  - 1\n", defineOptions(outputVersion = ovNone, containers = cBlock))
  
  test "Compact notation with 4 spaces indentation":
    var input = inputSingle(startSeqEvent(), scalarEvent("a"), startMapEvent(), scalarEvent("1"), scalarEvent("2"),   
        scalarEvent("3"), scalarEvent("4"), endMapEvent(), endSeqEvent())
    assertOutput(input, "-   a\n-   1: 2\n    3: 4\n", defineOptions(outputVersion = ovNone, indentationStep = 4))
  
  test "Compact notation with 4 spaces indentation, more complex input":
    var input = inputSingle(startMapEvent(), scalarEvent("root"), startSeqEvent(), scalarEvent("a"),
        startMapEvent(), scalarEvent("1"), scalarEvent("2"), scalarEvent("3"), scalarEvent("4"), endMapEvent(),
        endSeqEvent(), endMapEvent())
    assertOutput(input, "root:\n    -   a\n    -   1: 2\n        3: 4\n", defineOptions(outputVersion = ovNone, indentationStep = 4))