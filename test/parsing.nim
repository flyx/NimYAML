import "../src/yaml/sequential"

import unittest
import streams

proc startDoc(): YamlParserEvent =
    new(result)
    result.kind = yamlStartDocument

proc endDoc(): YamlParserEvent =
    new(result)
    result.kind = yamlEndDocument

proc scalar(content: string,
            anchor: string = nil, tag: string = nil): YamlParserEvent =
    new(result) 
    result.kind = yamlScalar
    result.scalarAnchor = anchor
    result.scalarTag = tag
    result.scalarContent = content

proc startSequence(anchor: string = nil, tag: string = nil): YamlParserEvent =
    new(result)
    result.kind = yamlStartSequence
    result.objAnchor = anchor
    result.objTag = tag

proc endSequence(): YamlParserEvent =
    new(result)
    result.kind = yamlEndSequence

proc startMap(anchor: string = nil, tag: string = nil): YamlParserEvent =
    new(result)
    result.kind = yamlStartMap
    result.objAnchor = anchor
    result.objTag = tag

proc endMap(): YamlParserEvent =
    new(result)
    result.kind = yamlEndMap

proc printDifference(expected, actual: YamlParserEvent) =
    if expected.kind != actual.kind:
        echo "expected " & $expected.kind & ", got " & $actual.kind
        if actual.kind == yamlError:
            echo "Error message: (", actual.line, ", ", actual.column, ") ",
                 actual.description
        elif actual.kind == yamlWarning:
            echo "Warning message: " & actual.description
    else:
        case expected.kind
        of yamlScalar:
            if expected.scalarTag != actual.scalarTag:
                echo "[scalar] expected tag " & expected.scalarTag & ", got " &
                     actual.scalarTag
            elif expected.scalarAnchor != actual.scalarAnchor:
                echo "[scalar] expected anchor " & expected.scalarAnchor &
                     ", got " & actual.scalarAnchor
            elif expected.scalarContent != actual.scalarContent:
                echo "[scalar] expected content \"" & expected.scalarContent &
                     "\", got \"" & actual.scalarContent & "\""
            else:
                echo "[scalar] Unknown difference"
        else:
            echo "Unknown difference in event kind " & $expected.kind

template ensure(input: string, expected: varargs[YamlParserEvent]) {.dirty.} =
    var
        i = 0
    
    for token in events(newStringStream(input)):
        if i >= expected.len:
            echo "received more tokens than expected (next token = ",
                 token.kind, ")"
            fail()
            break
        if token != expected[i]:
            echo "at token #" & $i & ":"
            printDifference(expected[i], token)
            fail()
            break
        i.inc()

suite "Parsing":
    test "Parsing: Simple Scalar":
        ensure("Scalar", startDoc(), scalar("Scalar"), endDoc())
    test "Parsing: Simple Sequence":
        ensure("- item", startDoc(), startSequence(), scalar("item"),
               endSequence(), endDoc())
    test "Parsing: Simple Map":
        ensure("key: value\nkey2: value2", startDoc(), startMap(),
               scalar("key"), scalar("value"), scalar("key2"), scalar("value2"),
               endMap(), endDoc())
    test "Parsing: Explicit Map":
        ensure("? key\n: value\n? key2\n: value2", startDoc(), startMap(),
               scalar("key"), scalar("value"), scalar("key2"), scalar("value2"),
               endMap(), endDoc())
    test "Parsing: Map in Sequence":
        ensure(" - key: value", startDoc(), startSequence(), startMap(),
               scalar("key"), scalar("value"), endMap(), endSequence(),
               endDoc())
    test "Parsing: Sequence in Map":
        ensure("key:\n - item1\n - item2", startDoc(), startMap(),
               scalar("key"), startSequence(), scalar("item1"), scalar("item2"),
               endSequence(), endMap(), endDoc())
    test "Parsing: Sequence in Sequence":
        ensure("- - l1_i1\n  - l1_i2\n- l2_i1", startDoc(), startSequence(),
               startSequence(), scalar("l1_i1"), scalar("l1_i2"), endSequence(),
               scalar("l2_i1"), endSequence(), endDoc())
    test "Parsing: Flow Sequence":
        ensure("[a, b]", startDoc(), startSequence(), scalar("a"), scalar("b"),
               endSequence(), endDoc())
    test "Parsing: Flow Map":
        ensure("{a: b, c: d}", startDoc(), startMap(), scalar("a"), scalar("b"),
               scalar("c"), scalar("d"), endMap(), endDoc())
    test "Parsing: Flow Sequence in Flow Sequence":
        ensure("[a, [b, c]]", startDoc(), startSequence(), scalar("a"),
               startSequence(), scalar("b"), scalar("c"), endSequence(),
               endSequence(), endDoc())
    test "Parsing: Flow Sequence in Flow Map":
        ensure("{a: [b, c]}", startDoc(), startMap(), scalar("a"),
               startSequence(), scalar("b"), scalar("c"), endSequence(),
               endMap(), endDoc())
    test "Parsing: Flow Sequence in Map":
        ensure("a: [b, c]", startDoc(), startMap(), scalar("a"),
               startSequence(), scalar("b"), scalar("c"), endSequence(),
               endMap(), endDoc())
    test "Parsing: Flow Map in Sequence":
        ensure("- {a: b}", startDoc(), startSequence(), startMap(), scalar("a"),
               scalar("b"), endMap(), endSequence(), endDoc())
    test "Parsing: Multiline scalar (top level)":
        ensure("a\nb  \n  c\nd", startDoc(), scalar("a b c d"), endDoc())
    test "Parsing: Multiline scalar (in map)":
        ensure("a: b\n c\nd:\n e\n  f", startDoc(), startMap(), scalar("a"),
               scalar("b c"), scalar("d"), scalar("e f"), endMap(), endDoc())