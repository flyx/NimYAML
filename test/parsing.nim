import "../src/yaml"
import streams, tables

import unittest

proc startDoc(): YamlStreamEvent =
    result.kind = yamlStartDocument

proc endDoc(): YamlStreamEvent =
    result.kind = yamlEndDocument

proc scalar(content: string, typeHint: YamlTypeHint,
            tag: TagId = tagQuestionMark, anchor: AnchorId = anchorNone):
           YamlStreamEvent =
    result.kind = yamlScalar
    result.scalarAnchor = anchor
    result.scalarTag = tag
    result.scalarContent = content
    result.scalarType = typeHint

proc scalar(content: string,
            tag: TagId = tagQuestionMark, anchor: AnchorId = anchorNone):
           YamlStreamEvent =
    result = scalar(content, yTypeUnknown, tag, anchor)

proc startSequence(tag: TagId = tagQuestionMark,
                   anchor: AnchorId = anchorNone):
        YamlStreamEvent =
    result.kind = yamlStartSequence
    result.objAnchor = anchor
    result.objTag = tag

proc endSequence(): YamlStreamEvent =
    result.kind = yamlEndSequence

proc startMap(tag: TagId = tagQuestionMark, anchor: AnchorId = anchorNone):
        YamlStreamEvent =
    result.kind = yamlStartMap
    result.objAnchor = anchor
    result.objTag = tag

proc endMap(): YamlStreamEvent =
    result.kind = yamlEndMap

proc alias(target: AnchorId): YamlStreamEvent =
    result.kind = yamlAlias
    result.aliasTarget = target

proc printDifference(expected, actual: YamlStreamEvent) =
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
                echo "[\"", actual.scalarContent, "\".tag] expected tag ",
                     expected.scalarTag, ", got ", actual.scalarTag
            elif expected.scalarAnchor != actual.scalarAnchor:
                echo "[scalar] expected anchor ", expected.scalarAnchor,
                     ", got ", actual.scalarAnchor
            elif expected.scalarContent != actual.scalarContent:
                let msg = "[scalar] expected content \"" &
                        expected.scalarContent & "\", got \"" &
                        actual.scalarContent & "\" "
                if expected.scalarContent.len != actual.scalarContent.len:
                    echo msg, "(length does not match)"
                else:
                    for i in 0..expected.scalarContent.high:
                        if expected.scalarContent[i] != actual.scalarContent[i]:
                            echo msg, "(first different char at pos ", i,
                                    ": expected ",
                                    cast[int](expected.scalarContent[i]),
                                    ", got ",
                                    cast[int](actual.scalarContent[i]), ")"
                            break
            elif expected.scalarType != actual.scalarType:
                echo "[scalar] expected type hint ", expected.scalarType,
                     ", got ", actual.scalarType
            else:
                echo "[scalar] Unknown difference"
        of yamlStartMap, yamlStartSequence:
            if expected.objTag != actual.objTag:
                echo "[object.tag] expected ", expected.objTag, ", got ",
                     actual.objTag
            else:
                echo "[object.tag] Unknown difference"
        of yamlAlias:
            if expected.aliasTarget != actual.aliasTarget:
                echo "[alias] expected ", expected.aliasTarget, ", got ",
                     actual.aliasTarget
            else:
                echo "[alias] Unknown difference"
        else:
            echo "Unknown difference in event kind " & $expected.kind

template ensure(input: string, expected: varargs[YamlStreamEvent]) {.dirty.} =
    var
        parser = newParser(tagLib)
        i = 0
        events = parser.parse(newStringStream(input))
    
    for token in events():
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
    setup:
        var tagLib = coreTagLibrary()
    
    test "Parsing: Simple Scalar":
        ensure("Scalar", startDoc(), scalar("Scalar"), endDoc())
    test "Parsing: Simple Sequence":
        ensure("- false", startDoc(), startSequence(),
               scalar("false", yTypeBoolean), endSequence(), endDoc())
    test "Parsing: Simple Map":
        ensure("42: value\nkey2: -7.5", startDoc(), startMap(),
               scalar("42", yTypeInteger), scalar("value"), scalar("key2"),
               scalar("-7.5", yTypeFloat), endMap(), endDoc())
    test "Parsing: Explicit Map":
        ensure("? null\n: value\n? true\n: value2", startDoc(), startMap(),
               scalar("null", yTypeNull), scalar("value"),
               scalar("true", yTypeBoolean), scalar("value2"),
               endMap(), endDoc())
    test "Parsing: Mixed Map (explicit to implicit)":
        ensure("? a\n: 13\n1.5: d", startDoc(), startMap(), scalar("a"),
               scalar("13", yTypeInteger), scalar("1.5", yTypeFloat),
               scalar("d"), endMap(), endDoc())
    test "Parsing: Mixed Map (implicit to explicit)":
        ensure("a: 4.2\n? 23\n: d", startDoc(), startMap(), scalar("a"),
               scalar("4.2", yTypeFloat), scalar("23", yTypeInteger),
               scalar("d"), endMap(), endDoc())
    test "Parsing: Missing values in map":
        ensure("? a\n? b\nc:", startDoc(), startMap(), scalar("a"), scalar(""),
               scalar("b"), scalar(""), scalar("c"), scalar(""), endMap(),
               endDoc())
    test "Parsing: Missing keys in map":
        ensure(": a\n: b", startDoc(), startMap(), scalar(""), scalar("a"),
               scalar(""), scalar("b"), endMap(), endDoc())
    test "Parsing: Multiline scalars in explicit map":
        ensure("? a\n  true\n: null\n  d\n? e\n  42", startDoc(), startMap(),
               scalar("a true"), scalar("null d"), scalar("e 42"), scalar(""),
               endMap(), endDoc())
    test "Parsing: Map in Sequence":
        ensure(" - key: value\n   key2: value2\n -\n   key3: value3",
               startDoc(), startSequence(), startMap(), scalar("key"),
               scalar("value"), scalar("key2"), scalar("value2"), endMap(),
               startMap(), scalar("key3"), scalar("value3"), endMap(),
               endSequence(), endDoc())
    test "Parsing: Sequence in Map":
        ensure("key:\n - item1\n - item2", startDoc(), startMap(),
               scalar("key"), startSequence(), scalar("item1"), scalar("item2"),
               endSequence(), endMap(), endDoc())
    test "Parsing: Sequence in Sequence":
        ensure("- - l1_i1\n  - l1_i2\n- l2_i1", startDoc(), startSequence(),
               startSequence(), scalar("l1_i1"), scalar("l1_i2"), endSequence(),
               scalar("l2_i1"), endSequence(), endDoc())
    test "Parsing: Flow Sequence":
        ensure("[2, b]", startDoc(), startSequence(), scalar("2", yTypeInteger),
               scalar("b"), endSequence(), endDoc())
    test "Parsing: Flow Map":
        ensure("{a: true, 1.337: d}", startDoc(), startMap(), scalar("a"),
               scalar("true", yTypeBoolean), scalar("1.337", yTypeFloat),
               scalar("d"), endMap(), endDoc())
    test "Parsing: Flow Sequence in Flow Sequence":
        ensure("[a, [b, c]]", startDoc(), startSequence(), scalar("a"),
               startSequence(), scalar("b"), scalar("c"), endSequence(),
               endSequence(), endDoc())
    test "Parsing: Flow Sequence in Flow Map":
        ensure("{a: [b, c], [d, e]: f}", startDoc(), startMap(), scalar("a"),
               startSequence(), scalar("b"), scalar("c"), endSequence(),
               startSequence(), scalar("d"), scalar("e"), endSequence(),
               scalar("f"), endMap(), endDoc())
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
    test "Parsing: non-specific tags of quoted strings":
        ensure("\"a\"", startDoc(),
               scalar("a", yTypeString, tagExclamationMark), endDoc())
    test "Parsing: explicit non-specific tag":
        ensure("! a", startDoc(), scalar("a", tagExclamationMark), endDoc())
    test "Parsing: secondary tag handle resolution":
        ensure("!!str a", startDoc(), scalar("a", tagString), endDoc())
    test "Parsing: resolving custom tag handles":
        let fooId = tagLib.registerUri("tag:example.com,2015:foo")
        ensure("%TAG !t! tag:example.com,2015:\n---\n!t!foo a", startDoc(),
               scalar("a", fooId), endDoc())
    test "Parsing: tags in sequence":
        ensure(" - !!str a\n - b\n - !!int c\n - d", startDoc(),
               startSequence(), scalar("a", tagString), scalar("b"),
               scalar("c", tagInteger), scalar("d"), endSequence(), endDoc())
    test "Parsing: tags in implicit map":
        ensure("!!str a: b\nc: !!int d\ne: !!str f\ng: h", startDoc(), startMap(),
               scalar("a", tagString), scalar("b"), scalar("c"),
               scalar("d", tagInteger), scalar("e"), scalar("f", tagString),
               scalar("g"), scalar("h"), endMap(), endDoc())
    test "Parsing: tags in explicit map":
        ensure("? !!str a\n: !!int b\n? c\n: !!str d", startDoc(), startMap(),
               scalar("a", tagString), scalar("b", tagInteger), scalar("c"),
               scalar("d", tagString), endMap(), endDoc())
    test "Parsing: tags for flow objects":
        ensure("!!map { k: !!seq [ a, !!str b] }", startDoc(), startMap(tagMap),
               scalar("k"), startSequence(tagSequence), scalar("a"),
               scalar("b", tagString), endSequence(), endMap(), endDoc())
    test "Parsing: Tag after directives end":
        ensure("--- !!str\nfoo", startDoc(), scalar("foo", tagString), endDoc())
    test "Parsing: Simple Anchor":
        ensure("&a str", startDoc(), scalar("str", tagQuestionMark,
                                            0.AnchorId), endDoc())
    test "Parsing: Anchors in sequence":
        ensure(" - &a a\n - b\n - &c c\n - &a d", startDoc(), startSequence(),
               scalar("a", tagQuestionMark, 0.AnchorId), scalar("b"),
               scalar("c", tagQuestionMark, 1.AnchorId),
               scalar("d", tagQuestionMark, 0.AnchorId), endSequence(),
               endDoc())
    test "Parsing: Anchors in map":
        ensure("&a a: b\nc: &d d", startDoc(), startMap(),
               scalar("a", tagQuestionMark, 0.AnchorId),
               scalar("b"), scalar("c"),
               scalar("d", tagQuestionMark, 1.AnchorId),
               endMap(), endDoc())
    test "Parsing: Anchors and tags":
        ensure(" - &a !!str a\n - !!int b\n - &c !!int c\n - &d d", startDoc(),
               startSequence(), scalar("a", tagString, 0.AnchorId),
               scalar("b", tagInteger), scalar("c", tagInteger, 1.AnchorId),
               scalar("d", tagQuestionMark, 2.AnchorId), endSequence(),
               endDoc())
    test "Parsing: Aliases in sequence":
        ensure(" - &a a\n - &b b\n - *a\n - *b", startDoc(), startSequence(),
               scalar("a", tagQuestionMark, 0.AnchorId),
               scalar("b", tagQuestionMark, 1.AnchorId), alias(0.AnchorId),
               alias(1.AnchorId), endSequence(), endDoc())
    test "Parsing: Aliases in map":
        ensure("&a a: &b b\n*a: *b", startDoc(), startMap(),
               scalar("a", tagQuestionMark, 0.AnchorId),
               scalar("b", tagQuestionMark, 1.AnchorId), alias(0.AnchorId),
               alias(1.AnchorId), endMap(), endDoc())
    test "Parsing: Aliases in flow":
        ensure("{ &a [a, &b b]: *b, *a: [c, *b, d]}", startDoc(), startMap(),
               startSequence(tagQuestionMark, 0.AnchorId), scalar("a"),
               scalar("b", tagQuestionMark, 1.AnchorId), endSequence(),
               alias(1.AnchorId), alias(0.AnchorId), startSequence(),
               scalar("c"), alias(1.AnchorId), scalar("d"), endSequence(),
               endMap(), endDoc())
    test "Parsing: Tags on empty scalars":
        ensure("!!str : a\nb: !!int\n!!str : !!str", startDoc(), startMap(),
               scalar("", tagString), scalar("a"), scalar("b"),
               scalar("", tagInteger), scalar("", tagString),
               scalar("", tagString), endMap(), endDoc())
    test "Parsing: Anchors on empty scalars":
        ensure("&a : a\nb: &b\n&c : &a", startDoc(), startMap(),
               scalar("", tagQuestionMark, 0.AnchorId), scalar("a"),
               scalar("b"), scalar("", tagQuestionMark, 1.AnchorId),
               scalar("", tagQuestionMark, 2.AnchorId),
               scalar("", tagQuestionMark, 0.AnchorId), endMap(), endDoc())