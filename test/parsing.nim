import "../src/yaml/sequential"

import unittest
import streams

proc startDoc(): YamlParserEvent =
    new(result)
    result.kind = yamlStartDocument

proc endDoc(): YamlParserEvent =
    new(result)
    result.kind = yamlEndDocument

proc scalar(content: string, tag: string = "?",
            anchor: string = nil): YamlParserEvent =
    new(result) 
    result.kind = yamlScalar
    result.scalarAnchor = anchor
    result.scalarTag = tag
    result.scalarContent = content

proc startSequence(anchor: string = nil, tag: string = "?"): YamlParserEvent =
    new(result)
    result.kind = yamlStartSequence
    result.objAnchor = anchor
    result.objTag = tag

proc endSequence(): YamlParserEvent =
    new(result)
    result.kind = yamlEndSequence

proc startMap(anchor: string = nil, tag: string = "?"): YamlParserEvent =
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
                if isNil(expected.scalarTag):
                    echo "[\"" & actual.scalarContent &
                         "\".tag] expected <nil>, got " & actual.scalarTag
                elif isNil(actual.scalarTag):
                    echo "[\"" & actual.scalarContent &
                         "\".tag] expected " & expected.scalarTag &
                         ", got <nil>"
                else:
                    echo "[\"" & actual.scalarContent &
                         "\".tag] expected tag " & expected.scalarTag &
                         ", got " & actual.scalarTag
            elif expected.scalarAnchor != actual.scalarAnchor:
                echo "[scalar] expected anchor " & expected.scalarAnchor &
                     ", got " & actual.scalarAnchor
            elif expected.scalarContent != actual.scalarContent:
                let msg = "[scalar] expected content \"" &
                        expected.scalarContent & "\", got \"" &
                        actual.scalarContent & "\" "
                for i in 0..expected.scalarContent.high:
                    if i >= actual.scalarContent.high:
                        echo msg, "(expected more chars, first char missing: ",
                             cast[int](expected.scalarContent[i]), ")"
                        break
                    elif expected.scalarContent[i] != actual.scalarContent[i]:
                        echo msg, "(first different char at pos ", i,
                                ": expected ",
                                cast[int](expected.scalarContent[i]), ", got ",
                                cast[int](actual.scalarContent[i]), ")"
                        break
            else:
                echo "[scalar] Unknown difference"
        of yamlStartMap, yamlStartSequence:
            if expected.objTag != actual.objTag:
                if isNil(expected.objTag):
                    echo "[object.tag] expected <nil>, got " & actual.objTag
                elif isNil(actual.objTag):
                    echo "[object.tag] expected " & expected.objTag &
                         ", got <nil>"
                else:
                    echo ""
        else:
            echo "Unknown difference in event kind " & $expected.kind

template ensure(input: string, expected: varargs[YamlParserEvent]) {.dirty.} =
    var
        i = 0
        parser = initParser()
    
    for token in parser.events(newStringStream(input)):
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
    test "Parsing: Block scalar (literal)":
        ensure("a: |\x0A ab\x0A \x0A cd\x0A ef\x0A \x0A", startDoc(),
               startMap(), scalar("a"), scalar("ab\x0A\x0Acd\x0Aef\x0A"),
               endMap(), endDoc())
    test "Parsing: Block scalar (folded)":
        ensure("a: >\x0A ab\x0A cd\x0A \x0Aef\x0A\x0A\x0Agh\x0A", startDoc(),
               startMap(), scalar("a"), scalar("ab cd\x0Aef\x0Agh\x0A"),
               endMap(), endDoc())
    test "Parsing: Block scalar (keep)":
        ensure("a: |+\x0A ab\x0A \x0A  \x0A", startDoc(), startMap(),
               scalar("a"), scalar("ab\x0A\x0A \x0A"), endMap(), endDoc())
    test "Parsing: Block scalar (strip)":
        ensure("a: |-\x0A ab\x0A \x0A \x0A", startDoc(), startMap(),
               scalar("a"), scalar("ab"), endMap(), endDoc())