import "../yaml"
import unittest

type
  Config = ref object
    docs_root* {.defaultVal: "~/.example".}: string
    drafts_root*: string

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

suite "Serialization Annotations":
  test "load default value":
    let input = "drafts_root: foo"
    var result: Config
    load(input, result)
    assert result.docs_root == "~/.example", "docs_root is " & result.docs_root
    assert result.drafts_root == "foo", "drafts_root is " & result.drafts_root

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