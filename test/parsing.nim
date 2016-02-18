import "../yaml"

import unittest

proc printDifference(expected, actual: YamlStreamEvent) =
    if expected.kind != actual.kind:
        echo "expected " & $expected.kind & ", got " & $actual.kind
    else:
        case expected.kind
        of yamlScalar:
            if expected.scalarTag != actual.scalarTag:
                echo "[\"", actual.scalarContent, "\".tag] expected tag ",
                     expected.scalarTag, ", got ", actual.scalarTag
            elif expected.scalarAnchor != actual.scalarAnchor:
                echo "[scalarEvent] expected anchor ", expected.scalarAnchor,
                     ", got ", actual.scalarAnchor
            elif expected.scalarContent != actual.scalarContent:
                let msg = "[scalarEvent] expected content \"" &
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
            else:
                echo "[scalarEvent] Unknown difference"
        of yamlStartMap:
            if expected.mapTag != actual.mapTag:
                echo "[map.tag] expected ", expected.mapTag, ", got ",
                     actual.mapTag
            else:
                echo "[map.tag] Unknown difference"
        of yamlStartSequence:
            if expected.seqTag != actual.seqTag:
                echo "[seq.tag] expected ", expected.seqTag, ", got ",
                     actual.seqTag
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
        i = 0
        parser = newYamlParser(tagLib)
        events = parser.parse(newStringStream(input))
    try:
        for token in events:
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
    except YamlParserError:
        let e = cast[ref YamlParserError](getCurrentException())
        echo "Parser error:", getCurrentExceptionMsg()
        echo e.lineContent
        fail()

suite "Parsing":
    setup:
        var tagLib = initCoreTagLibrary()
    teardown:
        discard
    
    test "Parsing: Simple scalarEvent":
        ensure("scalarEvent", startDocEvent(), scalarEvent("scalarEvent"), endDocEvent())
    test "Parsing: Simple Sequence":
        ensure("- off", startDocEvent(), startSeqEvent(),
               scalarEvent("off"), endSeqEvent(), endDocEvent())
    test "Parsing: Simple Map":
        ensure("42: value\nkey2: -7.5", startDocEvent(), startMapEvent(),
               scalarEvent("42"), scalarEvent("value"), scalarEvent("key2"),
               scalarEvent("-7.5"), endMapEvent(), endDocEvent())
    test "Parsing: Explicit Map":
        ensure("? null\n: value\n? ON\n: value2", startDocEvent(), startMapEvent(),
               scalarEvent("null"), scalarEvent("value"),
               scalarEvent("ON"), scalarEvent("value2"),
               endMapEvent(), endDocEvent())
    test "Parsing: Mixed Map (explicit to implicit)":
        ensure("? a\n: 13\n1.5: d", startDocEvent(), startMapEvent(), scalarEvent("a"),
               scalarEvent("13"), scalarEvent("1.5"),
               scalarEvent("d"), endMapEvent(), endDocEvent())
    test "Parsing: Mixed Map (implicit to explicit)":
        ensure("a: 4.2\n? 23\n: d", startDocEvent(), startMapEvent(), scalarEvent("a"),
               scalarEvent("4.2"), scalarEvent("23"),
               scalarEvent("d"), endMapEvent(), endDocEvent())
    test "Parsing: Missing values in map":
        ensure("? a\n? b\nc:", startDocEvent(), startMapEvent(), scalarEvent("a"), scalarEvent(""),
               scalarEvent("b"), scalarEvent(""), scalarEvent("c"), scalarEvent(""), endMapEvent(),
               endDocEvent())
    test "Parsing: Missing keys in map":
        ensure(": a\n: b", startDocEvent(), startMapEvent(), scalarEvent(""), scalarEvent("a"),
               scalarEvent(""), scalarEvent("b"), endMapEvent(), endDocEvent())
    test "Parsing: Multiline scalarEvents in explicit map":
        ensure("? a\n  true\n: null\n  d\n? e\n  42", startDocEvent(), startMapEvent(),
               scalarEvent("a true"), scalarEvent("null d"), scalarEvent("e 42"), scalarEvent(""),
               endMapEvent(), endDocEvent())
    test "Parsing: Map in Sequence":
        ensure(" - key: value\n   key2: value2\n -\n   key3: value3",
               startDocEvent(), startSeqEvent(), startMapEvent(), scalarEvent("key"),
               scalarEvent("value"), scalarEvent("key2"), scalarEvent("value2"), endMapEvent(),
               startMapEvent(), scalarEvent("key3"), scalarEvent("value3"), endMapEvent(),
               endSeqEvent(), endDocEvent())
    test "Parsing: Sequence in Map":
        ensure("key:\n - item1\n - item2", startDocEvent(), startMapEvent(),
               scalarEvent("key"), startSeqEvent(), scalarEvent("item1"), scalarEvent("item2"),
               endSeqEvent(), endMapEvent(), endDocEvent())
    test "Parsing: Sequence in Sequence":
        ensure("- - l1_i1\n  - l1_i2\n- l2_i1", startDocEvent(), startSeqEvent(),
               startSeqEvent(), scalarEvent("l1_i1"), scalarEvent("l1_i2"), endSeqEvent(),
               scalarEvent("l2_i1"), endSeqEvent(), endDocEvent())
    test "Parsing: Flow Sequence":
        ensure("[2, b]", startDocEvent(), startSeqEvent(), scalarEvent("2"),
               scalarEvent("b"), endSeqEvent(), endDocEvent())
    test "Parsing: Flow Map":
        ensure("{a: Y, 1.337: d}", startDocEvent(), startMapEvent(), scalarEvent("a"),
               scalarEvent("Y"), scalarEvent("1.337"),
               scalarEvent("d"), endMapEvent(), endDocEvent())
    test "Parsing: Flow Sequence in Flow Sequence":
        ensure("[a, [b, c]]", startDocEvent(), startSeqEvent(), scalarEvent("a"),
               startSeqEvent(), scalarEvent("b"), scalarEvent("c"), endSeqEvent(),
               endSeqEvent(), endDocEvent())
    test "Parsing: Flow Sequence in Flow Map":
        ensure("{a: [b, c], [d, e]: f}", startDocEvent(), startMapEvent(), scalarEvent("a"),
               startSeqEvent(), scalarEvent("b"), scalarEvent("c"), endSeqEvent(),
               startSeqEvent(), scalarEvent("d"), scalarEvent("e"), endSeqEvent(),
               scalarEvent("f"), endMapEvent(), endDocEvent())
    test "Parsing: Flow Sequence in Map":
        ensure("a: [b, c]", startDocEvent(), startMapEvent(), scalarEvent("a"),
               startSeqEvent(), scalarEvent("b"), scalarEvent("c"), endSeqEvent(),
               endMapEvent(), endDocEvent())
    test "Parsing: Flow Map in Sequence":
        ensure("- {a: b}", startDocEvent(), startSeqEvent(), startMapEvent(), scalarEvent("a"),
               scalarEvent("b"), endMapEvent(), endSeqEvent(), endDocEvent())
    test "Parsing: Multiline scalar (top level)":
        ensure("a\nb  \n  c\nd", startDocEvent(), scalarEvent("a b c d"), endDocEvent())
    test "Parsing: Multiline scalar (in map)":
        ensure("a: b\n c\nd:\n e\n  f", startDocEvent(), startMapEvent(), scalarEvent("a"),
               scalarEvent("b c"), scalarEvent("d"), scalarEvent("e f"), endMapEvent(), endDocEvent())
    test "Parsing: Block scalar (literal)":
        ensure("a: |\x0A ab\x0A \x0A cd\x0A ef\x0A \x0A", startDocEvent(),
               startMapEvent(), scalarEvent("a"), scalarEvent("ab\x0A\x0Acd\x0Aef\x0A", yTagExclamationmark),
               endMapEvent(), endDocEvent())
    test "Parsing: Block scalar (folded)":
        ensure("a: >\x0A ab\x0A cd\x0A \x0A ef\x0A\x0A\x0A gh\x0A", startDocEvent(),
               startMapEvent(), scalarEvent("a"), scalarEvent("ab cd\x0Aef\x0A\x0Agh\x0A", yTagExclamationmark),
               endMapEvent(), endDocEvent())
    test "Parsing: Block scalar (keep)":
        ensure("a: |+\x0A ab\x0A \x0A  \x0A", startDocEvent(), startMapEvent(),
               scalarEvent("a"), scalarEvent("ab\x0A\x0A \x0A", yTagExclamationmark), endMapEvent(), endDocEvent())
    test "Parsing: Block scalar (strip)":
        ensure("a: |-\x0A ab\x0A \x0A \x0A", startDocEvent(), startMapEvent(),
               scalarEvent("a"), scalarEvent("ab", yTagExclamationmark), endMapEvent(), endDocEvent())
    test "Parsing: non-specific tags of quoted strings":
        ensure("\"a\"", startDocEvent(),
               scalarEvent("a", yTagExclamationMark), endDocEvent())
    test "Parsing: explicit non-specific tag":
        ensure("! a", startDocEvent(), scalarEvent("a", yTagExclamationMark), endDocEvent())
    test "Parsing: secondary tag handle resolution":
        ensure("!!str a", startDocEvent(), scalarEvent("a", yTagString), endDocEvent())
    test "Parsing: resolving custom tag handles":
        let fooId = tagLib.registerUri("tag:example.com,2015:foo")
        ensure("%TAG !t! tag:example.com,2015:\n---\n!t!foo a", startDocEvent(),
               scalarEvent("a", fooId), endDocEvent())
    test "Parsing: tags in sequence":
        ensure(" - !!str a\n - b\n - !!int c\n - d", startDocEvent(),
               startSeqEvent(), scalarEvent("a", yTagString), scalarEvent("b"),
               scalarEvent("c", yTagInteger), scalarEvent("d"), endSeqEvent(), endDocEvent())
    test "Parsing: tags in implicit map":
        ensure("!!str a: b\nc: !!int d\ne: !!str f\ng: h", startDocEvent(), startMapEvent(),
               scalarEvent("a", yTagString), scalarEvent("b"), scalarEvent("c"),
               scalarEvent("d", yTagInteger), scalarEvent("e"), scalarEvent("f", yTagString),
               scalarEvent("g"), scalarEvent("h"), endMapEvent(), endDocEvent())
    test "Parsing: tags in explicit map":
        ensure("? !!str a\n: !!int b\n? c\n: !!str d", startDocEvent(), startMapEvent(),
               scalarEvent("a", yTagString), scalarEvent("b", yTagInteger), scalarEvent("c"),
               scalarEvent("d", yTagString), endMapEvent(), endDocEvent())
    test "Parsing: tags for block objects":
        ensure("--- !!map\nfoo: !!seq\n  - a\n  - !!str b\n!!str bar: !!str baz",
               startDocEvent(), startMapEvent(yTagMap), scalarEvent("foo"),
               startSeqEvent(yTagSequence), scalarEvent("a"), scalarEvent("b", yTagString),
               endSeqEvent(), scalarEvent("bar", yTagString),
               scalarEvent("baz", yTagString), endMapEvent(), endDocEvent())
    test "Parsing: root tag for block sequence":
        ensure("--- !!seq\n- a", startDocEvent(), startSeqEvent(yTagSequence),
                scalarEvent("a"), endSeqEvent(), endDocEvent())
    test "Parsing: root tag for explicit block map":
        ensure("--- !!map\n? a\n: b", startDocEvent(), startMapEvent(yTagMap),
                scalarEvent("a"), scalarEvent("b"), endMapEvent(), endDocEvent())
    test "Parsing: tags for flow objects":
        ensure("!!map { k: !!seq [ a, !!str b] }", startDocEvent(), startMapEvent(yTagMap),
               scalarEvent("k"), startSeqEvent(yTagSequence), scalarEvent("a"),
               scalarEvent("b", yTagString), endSeqEvent(), endMapEvent(), endDocEvent())
    test "Parsing: Tag after directives end":
        ensure("--- !!str\nfoo", startDocEvent(), scalarEvent("foo", yTagString), endDocEvent())
    test "Parsing: Simple Anchor":
        ensure("&a str", startDocEvent(), scalarEvent("str", yTagQuestionMark,
                                            0.AnchorId), endDocEvent())
    test "Parsing: Anchors in sequence":
        ensure(" - &a a\n - b\n - &c c\n - &a d", startDocEvent(), startSeqEvent(),
               scalarEvent("a", yTagQuestionMark, 0.AnchorId), scalarEvent("b"),
               scalarEvent("c", yTagQuestionMark, 1.AnchorId),
               scalarEvent("d", yTagQuestionMark, 2.AnchorId), endSeqEvent(),
               endDocEvent())
    test "Parsing: Anchors in map":
        ensure("&a a: b\nc: &d d", startDocEvent(), startMapEvent(),
               scalarEvent("a", yTagQuestionMark, 0.AnchorId),
               scalarEvent("b"), scalarEvent("c"),
               scalarEvent("d", yTagQuestionMark, 1.AnchorId),
               endMapEvent(), endDocEvent())
    test "Parsing: Anchors and tags":
        ensure(" - &a !!str a\n - !!int b\n - &c !!int c\n - &d d", startDocEvent(),
               startSeqEvent(), scalarEvent("a", yTagString, 0.AnchorId),
               scalarEvent("b", yTagInteger), scalarEvent("c", yTagInteger, 1.AnchorId),
               scalarEvent("d", yTagQuestionMark, 2.AnchorId), endSeqEvent(),
               endDocEvent())
    test "Parsing: Aliases in sequence":
        ensure(" - &a a\n - &b b\n - *a\n - *b", startDocEvent(), startSeqEvent(),
               scalarEvent("a", yTagQuestionMark, 0.AnchorId),
               scalarEvent("b", yTagQuestionMark, 1.AnchorId), aliasEvent(0.AnchorId),
               aliasEvent(1.AnchorId), endSeqEvent(), endDocEvent())
    test "Parsing: Aliases in map":
        ensure("&a a: &b b\n*a : *b", startDocEvent(), startMapEvent(),
               scalarEvent("a", yTagQuestionMark, 0.AnchorId),
               scalarEvent("b", yTagQuestionMark, 1.AnchorId), aliasEvent(0.AnchorId),
               aliasEvent(1.AnchorId), endMapEvent(), endDocEvent())
    test "Parsing: Aliases in flow":
        ensure("{ &a [a, &b b]: *b, *a : [c, *b, d]}", startDocEvent(), startMapEvent(),
               startSeqEvent(yTagQuestionMark, 0.AnchorId), scalarEvent("a"),
               scalarEvent("b", yTagQuestionMark, 1.AnchorId), endSeqEvent(),
               aliasEvent(1.AnchorId), aliasEvent(0.AnchorId), startSeqEvent(),
               scalarEvent("c"), aliasEvent(1.AnchorId), scalarEvent("d"), endSeqEvent(),
               endMapEvent(), endDocEvent())
    test "Parsing: Tags on empty scalars":
        ensure("!!str : a\nb: !!int\n!!str : !!str", startDocEvent(), startMapEvent(),
               scalarEvent("", yTagString), scalarEvent("a"), scalarEvent("b"),
               scalarEvent("", yTagInteger), scalarEvent("", yTagString),
               scalarEvent("", yTagString), endMapEvent(), endDocEvent())
    test "Parsing: Anchors on empty scalars":
        ensure("&a : a\nb: &b\n&c : &a", startDocEvent(), startMapEvent(),
               scalarEvent("", yTagQuestionMark, 0.AnchorId), scalarEvent("a"),
               scalarEvent("b"), scalarEvent("", yTagQuestionMark, 1.AnchorId),
               scalarEvent("", yTagQuestionMark, 2.AnchorId),
               scalarEvent("", yTagQuestionMark, 3.AnchorId), endMapEvent(), endDocEvent())
    test "Parsing: Whitespace before end of flow content":
        ensure("- [a, b, c ]", startDocEvent(), startSeqEvent(),
               startSeqEvent(), scalarEvent("a"), scalarEvent("b"),
               scalarEvent("c"), endSeqEvent(), endSeqEvent(), endDocEvent())
    test "Parsing: Empty lines after document":
        ensure(":\n\n", startDocEvent(), startMapEvent(), scalarEvent(""),
               scalarEvent(""), endMapEvent(), endDocEvent())
    test "Parsing: Empty lines between map elements":
        ensure("1: 2\n\n\n3: 4", startDocEvent(), startMapEvent(),
               scalarEvent("1"), scalarEvent("2"), scalarEvent("3"),
               scalarEvent("4"), endMapEvent(), endDocEvent())