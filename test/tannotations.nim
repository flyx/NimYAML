#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import "../yaml"
import unittest

type
  Config = ref object
    docsRoot* {.defaultVal: "~/.example".}: string
    draftsRoot*: string

  Stuff = ref object
    a {.transient.}: string
    b: string

  Part {.ignore: ["a", "b"].} = ref object
    c: string

  IgnoreAnything {.ignore: [].} = ref object
    warbl: int

  ContainerKind = enum
    ckString, ckInt

  Container {.implicit.} = object
     case kind: ContainerKind
     of ckString:
       strVal: string
     of ckInt:
       intVal: int

  Sparse {.sparse.} = ref object of RootObj
     name*: Option[string]
     description*: Option[string]

  DifferentKeys = object
    xx {.yamlKey: "xy".}: string
    xy {.yamlKey: "zz".}: int
    xz {.yamlKey: "a".}, xa {.yamlKey: "y".}: string

suite "Serialization Annotations":
  test "load default value":
    let input = "draftsRoot: foo"
    var result: Config
    load(input, result)
    assert result.docsRoot == "~/.example", "docsRoot is " & result.docsRoot
    assert result.draftsRoot == "foo", "draftsRoot is " & result.draftsRoot

  test "load into object with transient fields":
    let input = "b: warbl"
    var result: Stuff
    load(input, result)
    assert result.b == "warbl"
    assert result.a == ""

  test "load into object with ignored keys":
    let input = "{a: foo, c: bar, b: baz}"
    var result: Part
    load(input, result)
    assert result.c == "bar"

  test "load into object ignoring all other keys":
    let input = "{tuirae: fg, rtuco: fgh, warbl: 1}"
    var result: IgnoreAnything
    load(input, result)
    assert result.warbl == 1

  test "load implicit variant object":
    let input = "[foo, 13]"
    var result: seq[Container]
    load(input, result)
    assert len(result) == 2
    assert result[0].kind == ckString
    assert result[1].kind == ckInt

  test "load sparse type":
    let input = "{}"
    var result: Sparse
    load(input, result)
    assert result.name.isNone
    assert result.description.isNone

  test "load different keys":
    let input = "{xy: foo, zz: 42, a: bar, y: baz}"
    var result: DifferentKeys
    load(input, result)
    assert result.xx == "foo"
    assert result.xy == 42
    assert result.xz == "bar"
    assert result.xa == "baz"

  test "write different keys":
    let input = DifferentKeys(
      xx: "foo",
      xy: 42,
      xz: "bar",
      xa: "baz"
    )
    var dumper = minimalDumper()
    let result = dumper.dump(input)
    assert result == "{xy: foo, zz: 42, a: bar, y: baz}\n"
