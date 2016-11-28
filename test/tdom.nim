#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import "../yaml"
import unittest, commonTestUtils, streams, tables

suite "DOM":
  test "Composing simple Scalar":
    let
      input  = newStringStream("scalar")
      result = loadDOM(input)
    assert result.root.kind == yScalar
    assert result.root.content == "scalar"
    assert result.root.tag == "?"
  test "Serializing simple Scalar":
    let input = initYamlDoc(newYamlNode("scalar"))
    var result = serialize(input, initExtendedTagLibrary())
    ensure(result, startDocEvent(), scalarEvent("scalar"), endDocEvent())
  test "Composing sequence":
    let
      input = newStringStream("- !!str a\n- !!bool no")
      result = loadDOM(input)
    assert result.root.kind == ySequence
    assert result.root.tag == "?"
    assert result.root.len == 2
    assert result.root[0].kind == yScalar
    assert result.root[0].tag == "tag:yaml.org,2002:str"
    assert result.root[0].content == "a"
    assert result.root[1].kind == yScalar
    assert result.root[1].tag == "tag:yaml.org,2002:bool"
    assert result.root[1].content == "no"
  test "Serializing sequence":
    let input = initYamlDoc(newYamlNode([
        newYamlNode("a", "tag:yaml.org,2002:str"),
        newYamlNode("no", "tag:yaml.org,2002:bool")]))
    var result = serialize(input, initExtendedTagLibrary())
    ensure(result, startDocEvent(), startSeqEvent(),
           scalarEvent("a", yTagString), scalarEvent("no", yTagBoolean),
           endSeqEvent(), endDocEvent())
  test "Composing mapping":
    let
      input = newStringStream("--- !!map\n!foo bar: [a, b]")
      result = loadDOM(input)
    assert result.root.kind == yMapping
    assert result.root.tag == "tag:yaml.org,2002:map"
    assert result.root.fields.len == 1
    for key, value in result.root.fields.pairs:
      assert key.kind == yScalar
      assert key.tag  == "!foo"
      assert key.content == "bar"
      assert value.kind == ySequence
      assert value.len == 2
  test "Serializing mapping":
    let input = initYamlDoc(newYamlNode([
        (key: newYamlNode("bar"), value: newYamlNode([newYamlNode("a"),
                                                      newYamlNode("b")]))]))
    var result = serialize(input, initExtendedTagLibrary())
    ensure(result, startDocEvent(), startMapEvent(), scalarEvent("bar"),
           startSeqEvent(), scalarEvent("a"), scalarEvent("b"),
           endSeqEvent(), endMapEvent(), endDocEvent())
  test "Composing with anchors":
    let
      input = newStringStream("- &a foo\n- &b bar\n- *a\n- *b")
      result = loadDOM(input)
    assert result.root.kind == ySequence
    assert result.root.len == 4
    assert result.root[0].kind == yScalar
    assert result.root[0].content == "foo"
    assert result.root[1].kind == yScalar
    assert result.root[1].content == "bar"
    assert cast[pointer](result.root[0]) == cast[pointer](result.root[2])
    assert cast[pointer](result.root[1]) == cast[pointer](result.root[3])
  test "Serializing with anchors":
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
  test "Serializing with all anchors":
    let
      a = newYamlNode("a")
      input = initYamlDoc(newYamlNode([a, newYamlNode("b"), a]))
    var result = serialize(input, initExtendedTagLibrary(), asAlways)
    ensure(result, startDocEvent(), startSeqEvent(anchor=0.AnchorId),
           scalarEvent("a", anchor=1.AnchorId),
           scalarEvent("b", anchor=2.AnchorId), aliasEvent(1.AnchorId),
           endSeqEvent(), endDocEvent())