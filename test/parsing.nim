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
            echo "Error message: " & actual.description
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
        ensure("key: value", startDoc(), startMap(), scalar("key"),
               scalar("value"), endMap(), endDoc())