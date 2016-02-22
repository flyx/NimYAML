import "../yaml"
import unittest, common

suite "DOM":
    test "DOM: Composing simple Scalar":
        let
            input  = newStringStream("scalar")
            result = loadDOM(input)
        assert result.root.kind == yScalar
        assert result.root.content == "scalar"
        assert result.root.tag == "?"
    test "DOM: Serializing simple Scalar":
        let input = initYamlDoc(newYamlNode("scalar"))
        var result = serialize(input, initExtendedTagLibrary())
        ensure(result, startDocEvent(), scalarEvent("scalar"), endDocEvent())
    test "DOM: Composing sequence":
        let
            input = newStringStream("- !!str a\n- !!bool no")
            result = loadDOM(input)
        assert result.root.kind == ySequence
        assert result.root.tag == "?"
        assert result.root.children.len == 2
        assert result.root.children[0].kind == yScalar
        assert result.root.children[0].tag == "tag:yaml.org,2002:str"
        assert result.root.children[0].content == "a"
        assert result.root.children[1].kind == yScalar
        assert result.root.children[1].tag == "tag:yaml.org,2002:bool"
        assert result.root.children[1].content == "no"
    test "DOM: Serializing sequence":
        let input = initYamlDoc(newYamlNode([
                newYamlNode("a", "tag:yaml.org,2002:str"),
                newYamlNode("no", "tag:yaml.org,2002:bool")]))
        var result = serialize(input, initExtendedTagLibrary())
        ensure(result, startDocEvent(), startSeqEvent(),
               scalarEvent("a", yTagString), scalarEvent("no", yTagBoolean),
               endSeqEvent(), endDocEvent())
    test "DOM: Composing mapping":
        let
            input = newStringStream("--- !!map\n!foo bar: [a, b]")
            result = loadDOM(input)
        assert result.root.kind == yMapping
        assert result.root.tag == "tag:yaml.org,2002:map"
        assert result.root.pairs.len == 1
        assert result.root.pairs[0].key.kind == yScalar
        assert result.root.pairs[0].key.tag  == "!foo"
        assert result.root.pairs[0].key.content == "bar"
        assert result.root.pairs[0].value.kind == ySequence
        assert result.root.pairs[0].value.children.len == 2
    test "DOM: Serializing mapping":
        let input = initYamlDoc(newYamlNode([
            (key: newYamlNode("bar"), value: newYamlNode([newYamlNode("a"),
                                                          newYamlNode("b")]))]))
        var result = serialize(input, initExtendedTagLibrary())
        ensure(result, startDocEvent(), startMapEvent(), scalarEvent("bar"),
               startSeqEvent(), scalarEvent("a"), scalarEvent("b"),
               endSeqEvent(), endMapEvent(), endDocEvent())
    test "DOM: Composing with anchors":
        let
            input = newStringStream("- &a foo\n- &b bar\n- *a\n- *b")
            result = loadDOM(input)
        assert result.root.kind == ySequence
        assert result.root.children.len == 4
        assert result.root.children[0].kind == yScalar
        assert result.root.children[0].content == "foo"
        assert result.root.children[1].kind == yScalar
        assert result.root.children[1].content == "bar"
        assert result.root.children[0] == result.root.children[2]
        assert result.root.children[1] == result.root.children[3]
    test "DOM: Serializing with anchors":
        let
            a = newYamlNode("a")
            b = newYamlNode("b")
            input = initYamlDoc(newYamlNode([a, b, newYamlNode("c"), a, b]))
        var result = serialize(input, initExtendedTagLibrary())
        ensure(result, startDocEvent(), startSeqEvent(),
               scalarEvent("a", anchor=0.AnchorId),
               scalarEvent("b", anchor=1.AnchorId), scalarEvent("c"),
               aliasEvent(0.AnchorId), aliasEvent(1.AnchorId), endSeqEvent(),
               endDocEvent())
    test "DOM: Serializing with all anchors":
        let
            a = newYamlNode("a")
            input = initYamlDoc(newYamlNode([a, newYamlNode("b"), a]))
        var result = serialize(input, initExtendedTagLibrary(), asAlways)
        ensure(result, startDocEvent(), startSeqEvent(anchor=0.AnchorId),
               scalarEvent("a", anchor=1.AnchorId),
               scalarEvent("b", anchor=2.AnchorId), aliasEvent(1.AnchorId),
               endSeqEvent(), endDocEvent())