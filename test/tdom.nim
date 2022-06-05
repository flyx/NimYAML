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
    assert result.root.tag == yTagQuestionMark
  test "Serializing simple Scalar":
    let input = initYamlDoc(newYamlNode("scalar"))
    var result = serialize(input)
    ensure(result, startStreamEvent(), startDocEvent(), scalarEvent("scalar"),
        endDocEvent(), endStreamEvent())
  test "Composing sequence":
    let
      input = newStringStream("- !!str a\n- !!bool no")
      result = loadDOM(input)
    assert result.root.kind == ySequence
    assert result.root.tag == yTagQuestionMark
    assert result.root.len == 2
    assert result.root[0].kind == yScalar
    assert result.root[0].tag == yTagString
    assert result.root[0].content == "a"
    assert result.root[1].kind == yScalar
    assert result.root[1].tag == yTagBoolean
    assert result.root[1].content == "no"
  test "Serializing sequence":
    let input = initYamlDoc(newYamlNode([
        newYamlNode("a", yTagString),
        newYamlNode("no", yTagBoolean)]))
    var result = serialize(input)
    ensure(result, startStreamEvent(), startDocEvent(), startSeqEvent(),
           scalarEvent("a", yTagString), scalarEvent("no", yTagBoolean),
           endSeqEvent(), endDocEvent(), endStreamEvent())
  test "Composing mapping":
    let
      input = newStringStream("--- !!map\n!foo bar: [a, b]")
      result = loadDOM(input)
    assert result.root.kind == yMapping
    assert result.root.tag == yTagMapping
    assert result.root.fields.len == 1
    for key, value in result.root.fields.pairs:
      assert key.kind == yScalar
      assert $key.tag  == "!foo"
      assert key.content == "bar"
      assert value.kind == ySequence
      assert value.len == 2
  test "Serializing mapping":
    let input = initYamlDoc(newYamlNode([
        (key: newYamlNode("bar"), value: newYamlNode([newYamlNode("a"),
                                                      newYamlNode("b")]))]))
    var result = serialize(input)
    ensure(result, startStreamEvent(), startDocEvent(), startMapEvent(),
        scalarEvent("bar"), startSeqEvent(), scalarEvent("a"), scalarEvent("b"),
        endSeqEvent(), endMapEvent(), endDocEvent(), endStreamEvent())
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
    var result = serialize(input)
    ensure(result, startStreamEvent(), startDocEvent(), startSeqEvent(),
           scalarEvent("a", anchor="a".Anchor),
           scalarEvent("b", anchor="b".Anchor), scalarEvent("c"),
           aliasEvent("a".Anchor), aliasEvent("b".Anchor), endSeqEvent(),
           endDocEvent(), endStreamEvent())
  test "Serializing with all anchors":
    let
      a = newYamlNode("a")
      input = initYamlDoc(newYamlNode([a, newYamlNode("b"), a]))
    var result = serialize(input, asAlways)
    ensure(result, startStreamEvent(), startDocEvent(),
           startSeqEvent(anchor="a".Anchor),
           scalarEvent("a", anchor = "b".Anchor),
           scalarEvent("b", anchor="c".Anchor), aliasEvent("b".Anchor),
           endSeqEvent(), endDocEvent(), endStreamEvent())
  test "Deserialize parts of the input into YamlNode":
    let
      input = "a: b\nc: [d, e]"
    type Root = object
      a: string
      c: YamlNode
    var result = loadAs[Root](input)
    assert result.a == "b"
    assert result.c.kind == ySequence
    assert result.c.len == 2
    assert result.c[0].kind == yScalar
    assert result.c[0].content == "d"
    assert result.c[1].kind == yScalar
    assert result.c[1].content == "e"
  test "Serialize value that contains a YamlNode":
    type Root = object
      a: string
      c: YamlNode
    let value = Root(
      a: "b",
      c: newYamlNode([newYamlNode("d"), newYamlNode("e")]))
    var result = represent(value, tsNone, handles = @[])
    ensure(result, startStreamEvent(), startDocEvent(), startMapEvent(),
      scalarEvent("a"), scalarEvent("b"), scalarEvent("c"), startSeqEvent(),
      scalarEvent("d"), scalarEvent("e"), endSeqEvent(), endMapEvent(),
      endDocEvent(), endStreamEvent())