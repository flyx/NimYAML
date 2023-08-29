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
      result = loadAs[YamlNode](input)
    assert result.kind == yScalar
    assert result.content == "scalar"
    assert result.tag == yTagQuestionMark
  test "Serializing simple Scalar":
    let input = newYamlNode("scalar")
    var result = represent(input)
    ensure(result, startStreamEvent(), startDocEvent(), scalarEvent("scalar"),
        endDocEvent(), endStreamEvent())
  test "Composing sequence":
    let
      input = newStringStream("- !!str a\n- !!bool no")
      result = loadAs[YamlNode](input)
    assert result.kind == ySequence
    assert result.tag == yTagQuestionMark
    assert result.len == 2
    assert result[0].kind == yScalar
    assert result[0].tag == yTagString
    assert result[0].content == "a"
    assert result[1].kind == yScalar
    assert result[1].tag == yTagBoolean
    assert result[1].content == "no"
  test "Serializing sequence":
    let input = newYamlNode([
        newYamlNode("a", yTagString),
        newYamlNode("no", yTagBoolean)])
    var result = represent(input, SerializationOptions(tagStyle: tsAll))
    ensure(result, startStreamEvent(), startDocEvent(), startSeqEvent(),
           scalarEvent("a", yTagString), scalarEvent("no", yTagBoolean),
           endSeqEvent(), endDocEvent(), endStreamEvent())
  test "Composing mapping":
    let
      input = newStringStream("--- !!map\n!foo bar: [a, b]")
      result = loadAs[YamlNode](input)
    assert result.kind == yMapping
    assert result.tag == yTagMapping
    assert result.fields.len == 1
    for key, value in result.fields.pairs:
      assert key.kind == yScalar
      assert $key.tag  == "!foo"
      assert key.content == "bar"
      assert value.kind == ySequence
      assert value.len == 2
  test "Serializing mapping":
    let input = newYamlNode([
        (key: newYamlNode("bar"), value: newYamlNode([newYamlNode("a"),
                                                      newYamlNode("b")]))])
    var result = represent(input)
    ensure(result, startStreamEvent(), startDocEvent(), startMapEvent(),
        scalarEvent("bar"), startSeqEvent(), scalarEvent("a"), scalarEvent("b"),
        endSeqEvent(), endMapEvent(), endDocEvent(), endStreamEvent())
  test "Composing with anchors":
    let
      input = newStringStream("- &a foo\n- &b bar\n- *a\n- *b")
      result = loadAs[YamlNode](input)
    assert result.kind == ySequence
    assert result.len == 4
    assert result[0].kind == yScalar
    assert result[0].content == "foo"
    assert result[1].kind == yScalar
    assert result[1].content == "bar"
    assert cast[pointer](result[0]) == cast[pointer](result[2])
    assert cast[pointer](result[1]) == cast[pointer](result[3])
  test "Serializing with anchors":
    let
      a = newYamlNode("a")
      b = newYamlNode("b")
      input = newYamlNode([a, b, newYamlNode("c"), a, b])
    var result = represent(input)
    ensure(result, startStreamEvent(), startDocEvent(), startSeqEvent(),
           scalarEvent("a", anchor="a".Anchor),
           scalarEvent("b", anchor="b".Anchor), scalarEvent("c"),
           aliasEvent("a".Anchor), aliasEvent("b".Anchor), endSeqEvent(),
           endDocEvent(), endStreamEvent())
  test "Serializing with all anchors":
    let
      a = newYamlNode("a")
      input = newYamlNode([a, newYamlNode("b"), a])
    var result = represent(input, SerializationOptions(anchorStyle: asAlways))
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
    var result = represent(value, SerializationOptions(tagStyle: tsNone))
    ensure(result, startStreamEvent(), startDocEvent(), startMapEvent(),
      scalarEvent("a"), scalarEvent("b"), scalarEvent("c"), startSeqEvent(),
      scalarEvent("d"), scalarEvent("e"), endSeqEvent(), endMapEvent(),
      endDocEvent(), endStreamEvent())