#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import "../yaml"
import unittest, strutils, tables, times, math, options
import commonTestUtils

type
  MyTuple = tuple
    str: string
    i: int32
    b: bool

  TrafficLight = enum
    tlGreen, tlYellow, tlRed

  Person = object
    firstnamechar: char
    surname: string
    age: int32

  Node = object
    value: string
    next: ref Node

  BetterInt = distinct int

  AnimalKind = enum
    akCat, akDog

  Animal = object
    name: string
    case kind: AnimalKind
    of akCat:
      purringIntensity: int
    of akDog: barkometer: int

  DumbEnum = enum
    deA, deB, deC

  NonVariantWithTransient = object
    a {.transient.}, b, c {.transient.}, d: string

  VariantWithTransient = object
    gStorable: string
    gTemporary {.transient.}: string
    case kind: DumbEnum
    of deA:
      cStorable: string
      cTemporary {.transient.}: string
    of deB:
      alwaysThere: int
    of deC:
      neverThere {.transient.}: int

  WithDefault = object
    a, b {.defaultVal: "b".}, c, d {.defaultVal: "d".}: string

  WithIgnoredField {.ignore: ["z"].} = object
    x, y: int

  Parent = object of RootObj
    i*: int
  Child = object of Parent
    s*: string

proc `$`(v: BetterInt): string {.borrow.}
proc `==`(left, right: BetterInt): bool {.borrow.}

setTag(TrafficLight, Tag("!tl"))
setTag(Node, Tag("!example.net:Node"))
setTag(BetterInt, Tag("!test:BetterInt"))

const yamlDir = "---"
const yamlTagDirs = "%TAG !n! tag:nimyaml.org,2016:\n---"

proc representObject*(
  ctx  : var SerializationContext,
  value: BetterInt,
  tag  : Tag
) {.raises: [].} =
  var
    val = $value
    i = val.len - 3
  while i > 0:
    val.insert("_", i)
    i -= 3
  ctx.put(scalarEvent(val, tag, yAnchorNone))

proc constructObject*(
  ctx   : var ConstructionContext,
  result: var BetterInt,
) {.raises: [YamlConstructionError, YamlStreamError].} =
  ctx.input.constructScalarItem(item, BetterInt):
    result = BetterInt(parseBiggestInt(item.scalarContent) + 1)

template expectConstructionError(li, co: int, message: string, body: typed) =
  try:
    body
    echo "Expected YamlConstructionError, but none was raised!"
    fail()
  except YamlConstructionError as e:
    doAssert li == e.mark.line, "Expected error line " & $li & ", was " & $e.mark.line
    doAssert co == e.mark.column, "Expected error column " & $co & ", was " & $e.mark.column
    doAssert message == e.msg, "Expected error message \n" & escape(message) &
        ", got \n" & escape(e.msg)

proc newNode(v: string): ref Node =
  new(result)
  result.value = v
  result.next = nil

template dualTest(name: string, body: untyped) =
  test name:
    body

  # fix for compiler problem (comptime doesn't work when included from tests.nim)
  # possibly this issue: https://github.com/nim-lang/Nim/issues/18103
  when isMainModule:
    test name & " [comptime]":
      static: body

suite "Serialization":
  dualTest "Load integer without fixed length":
    var input = "-4247"
    var result: int
    load(input, result)
    assert result == -4247, "result is " & $result

    input = $(int64(int32.high) + 1'i64)
    var gotException = false
    try: load(input, result)
    except YamlConstructionError: gotException = true
    assert gotException, "Expected exception, got none."

  test "Dump integer without fixed length":
    var input = -4247
    var output = blockOnlyDumper().dump(input)
    assertStringEqual  "\"-4247\"\n", output

    when sizeof(int) == sizeof(int64):
      input = int(int32.high) + 1
      var gotException = false
      try: output = blockOnlyDumper().dump(input)
      except YamlSerializationError: gotException = true
      assert gotException, "Expected exception, got none."

  dualTest "Load Hex byte (0xFF)":
    let input = "0xFF"
    var result: byte
    load(input, result)
    assert(result == 255)

  dualTest "Load Hex byte (0xC)":
    let input = "0xC"
    var result: byte
    load(input, result)
    assert(result == 12)

  dualTest "Load Octal byte (0o14)":
    let input = "0o14"
    var result: byte
    load(input, result)
    assert(result == 12)

  dualTest "Load byte (14)":
    let input = "14"
    var result: byte
    load(input, result)
    assert(result == 14)

  dualTest "Load Hex int (0xFF)":
    let input = "0xFF"
    var result: int
    load(input, result)
    assert(result == 255)

  dualTest "Load Hex int (0xC)":
    let input = "0xC"
    var result: int
    load(input, result)
    assert(result == 12)

  dualTest "Load Octal int (0o14)":
    let input = "0o14"
    var result: int
    load(input, result)
    assert(result == 12)

  dualTest "Load int (14)":
    let input = "14"
    var result: int
    load(input, result)
    assert(result == 14)

  dualTest "Load floats":
    let input = "[6.8523015e+5, 685.230_15e+03, 685_230.15, -.inf, .NaN]"
    var result: seq[float]
    load(input, result)
    for i in 0..2:
      assert result[i] == 6.8523015e+5
    assert result[3] == NegInf
    assert classify(result[4]) == fcNan

  test "Load timestamps":
    let input = "[2001-12-15T02:59:43.1Z, 2001-12-14t21:59:43.10-05:00, 2001-12-14 21:59:43.10-5]"
    var result: seq[Time]
    load(input, result)
    assert result.len() == 3
    # currently, there is no good way of checking the result content, because
    # the parsed Time may have any timezone offset.

  dualTest "Load string sequence":
    let input = " - a\n - b"
    var result: seq[string]
    load(input, result)
    assert result.len == 2
    assert result[0] == "a"
    assert result[1] == "b"

  test "Dump string sequence":
    var input = @["a", "b"]
    var output = blockOnlyDumper().dump(input)
    assertStringEqual "- a\n- b\n", output

  dualTest "Load char set":
    let input = "- a\n- b"
    var result: set[char]
    load(input, result)
    assert result.card == 2
    assert 'a' in result
    assert 'b' in result

  test "Dump char set":
    var input = {'a', 'b'}
    var output = blockOnlyDumper().dump(input)
    assertStringEqual "- a\n- b\n", output

  dualTest "Load array":
    let input = "- 23\n- 42\n- 47"
    var result: array[0..2, int32]
    load(input, result)
    assert result[0] == 23
    assert result[1] == 42
    assert result[2] == 47

  test "Dump array":
    let input = [23'i32, 42'i32, 47'i32]
    var output = blockOnlyDumper().dump(input)
    assertStringEqual "- 23\n- 42\n- 47\n", output

  dualTest "Load Option":
    let input = "- Some\n- !!null ~"
    var result: array[0..1, Option[string]]
    load(input, result)
    assert result[0].isSome
    assert result[0].get() == "Some"
    assert not result[1].isSome

  test "Dump Option":
    let input = [none(int32), some(42'i32), none(int32)]
    let output = blockOnlyDumper().dump(input)
    assertStringEqual "- !!null ~\n- 42\n- !!null ~\n", output

  dualTest "Load Table[int, string]":
    let input = "23: dreiundzwanzig\n42: zweiundvierzig"
    var result: Table[int32, string]
    load(input, result)
    assert result.len == 2
    assert result[23] == "dreiundzwanzig"
    assert result[42] == "zweiundvierzig"

  test "Dump Table[int, string]":
    var input = initTable[int32, string]()
    input[23] = "dreiundzwanzig"
    input[42] = "zweiundvierzig"
    var output = blockOnlyDumper().dump(input)
    assertStringEqual("23: dreiundzwanzig\n42: zweiundvierzig\n",
        output)

  dualTest "Load OrderedTable[tuple[int32, int32], string]":
    let input = "- {a: 23, b: 42}: drzw\n- {a: 13, b: 47}: drsi"
    var result: OrderedTable[tuple[a, b: int32], string]
    load(input, result)
    var i = 0
    for key, value in result.pairs:
      case i
      of 0:
        assert key == (a: 23'i32, b: 42'i32)
        assert value == "drzw"
      of 1:
        assert key == (a: 13'i32, b: 47'i32)
        assert value == "drsi"
      else: assert false
      i.inc()

  test "Dump OrderedTable[tuple[int32, int32], string]":
    var input = initOrderedTable[tuple[a, b: int32], string]()
    input[(a: 23'i32, b: 42'i32)] = "dreiundzwanzigzweiundvierzig"
    input[(a: 13'i32, b: 47'i32)] = "dreizehnsiebenundvierzig"
    var dumper = blockOnlyDumper()
    dumper.serialization.tagStyle = tsRootOnly
    dumper.serialization.handles = initNimYamlTagHandle()
    var output = dumper.dump(input)
    assertStringEqual(yamlTagDirs &
        " !n!tables:OrderedTable(tag:nimyaml.org;2016:tuple(tag:nimyaml.org;2016:system:int32;tag:nimyaml.org;2016:system:int32);tag:yaml.org;2002:str)\n" &
        "- ? a: 23\n" &
        "    b: 42\n" &
        "  : dreiundzwanzigzweiundvierzig\n" &
        "- ? a: 13\n" &
        "    b: 47\n" &
        "  : dreizehnsiebenundvierzig\n", output)

  dualTest "Load Sequences in Sequence":
    let input = " - [1, 2, 3]\n - [4, 5]\n - [6]"
    var result: seq[seq[int32]]
    load(input, result)
    assert result.len == 3
    assert result[0] == @[1.int32, 2.int32, 3.int32]
    assert result[1] == @[4.int32, 5.int32]
    assert result[2] == @[6.int32]

  test "Dump Sequences in Sequence":
    let input = @[@[1.int32, 2.int32, 3.int32], @[4.int32, 5.int32], @[6.int32]]
    var output = Dumper().dump(input)
    assertStringEqual "- [1, 2, 3]\n- [4, 5]\n- [6]\n", output

  dualTest "Load Enum":
    let input =
      "!<tag:nimyaml.org,2016:system:seq(tl)>\n- !tl tlRed\n- tlGreen\n- tlYellow"
    var result: seq[TrafficLight]
    load(input, result)
    assert result.len == 3
    assert result[0] == tlRed
    assert result[1] == tlGreen
    assert result[2] == tlYellow

  test "Dump Enum":
    let input = @[tlRed, tlGreen, tlYellow]
    var output = blockOnlyDumper().dump(input)
    assertStringEqual "- tlRed\n- tlGreen\n- tlYellow\n", output

  dualTest "Load Tuple":
    let input = "str: value\ni: 42\nb: true"
    var result: MyTuple
    load(input, result)
    assert result.str == "value"
    assert result.i == 42
    assert result.b == true

  test "Dump Tuple":
    let input = (str: "value", i: 42.int32, b: true)
    var output = Dumper().dump(input)
    assertStringEqual "str: value\ni: 42\nb: true\n", output

  test "Load Tuple - unknown field":
    let input = "str: value\nfoo: bar\ni: 42\nb: true"
    var result: MyTuple
    expectConstructionError(2, 1, "While constructing MyTuple: Unknown field: \"foo\""):
      load(input, result)

  test "Load Tuple - missing field":
    let input = "str: value\nb: true"
    var result: MyTuple
    expectConstructionError(1, 1, "While constructing MyTuple: Missing field: \"i\""):
      load(input, result)

  test "Load Tuple - duplicate field":
    let input = "str: value\ni: 42\nb: true\nb: true"
    var result: MyTuple
    expectConstructionError(4, 1, "While constructing MyTuple: Duplicate field: \"b\""):
      load(input, result)

  dualTest "Load Multiple Documents":
    let input = "1\n---\n2"
    var result: seq[int]
    loadMultiDoc(input, result)
    assert(result.len == 2)
    assert result[0] == 1
    assert result[1] == 2

  dualTest "Load Multiple Documents (Single Doc)":
    let input = "1"
    var result: seq[int]
    loadMultiDoc(input, result)
    assert(result.len == 1)
    assert result[0] == 1

  dualTest "Load custom object":
    let input = "firstnamechar: P\nsurname: Pan\nage: 12"
    var result: Person
    load(input, result)
    assert result.firstnamechar == 'P'
    assert result.surname == "Pan"
    assert result.age == 12

  test "Dump custom object":
    let input = Person(firstnamechar: 'P', surname: "Pan", age: 12)
    var output = blockOnlyDumper().dump(input)
    assertStringEqual(
        "firstnamechar: P\nsurname: Pan\nage: 12\n", output)

  test "Load custom object - unknown field":
    let input = "  firstnamechar: P\n  surname: Pan\n  age: 12\n  occupation: free"
    var result: Person
    expectConstructionError(4, 3, "While constructing Person: Unknown field: \"occupation\""):
      load(input, result)

  test "Load custom object - missing field":
    let input = "surname: Pan\nage: 12\n  "
    var result: Person
    expectConstructionError(1, 1, "While constructing Person: Missing field: \"firstnamechar\""):
      load(input, result)

  test "Load custom object - duplicate field":
    let input = "firstnamechar: P\nsurname: Pan\nage: 12\nsurname: Pan"
    var result: Person
    expectConstructionError(4, 1, "While constructing Person: Duplicate field: \"surname\""):
      load(input, result)

  dualTest "Load sequence with explicit tags":
    let input = yamlTagDirs & " !n!system:seq(" &
        "tag:yaml.org;2002:str)\n- !!str one\n- !!str two"
    var result: seq[string]
    load(input, result)
    assert result[0] == "one"
    assert result[1] == "two"

  test "Dump sequence with explicit tags":
    let input = @["one", "two"]
    var dumper = blockOnlyDumper()
    dumper.serialization.tagStyle = tsAll
    dumper.serialization.handles = initNimYamlTagHandle()
    var output = dumper.dump(input)
    assertStringEqual(yamlTagDirs & " !n!system:seq(" &
        "tag:yaml.org;2002:str)\n- !!str one\n- !!str two\n", output)

  dualTest "Load custom object with explicit root tag":
    let input =
        "--- !<tag:nimyaml.org,2016:custom:Person>\nfirstnamechar: P\nsurname: Pan\nage: 12"
    var result: Person
    load(input, result)
    assert result.firstnamechar == 'P'
    assert result.surname == "Pan"
    assert result.age == 12

  test "Dump custom object with explicit root tag":
    let input = Person(firstnamechar: 'P', surname: "Pan", age: 12)
    var dumper = blockOnlyDumper()
    dumper.serialization.tagStyle = tsRootOnly
    dumper.serialization.handles = initNimYamlTagHandle()
    var output = dumper.dump(input)
    assertStringEqual(yamlTagDirs &
        " !n!custom:Person\nfirstnamechar: P\nsurname: Pan\nage: 12\n", output)

  dualTest "Load object with inherited fields":
    let input =
      "i: 4\ns: hello"
    var result: Child
    load(input, result)
    assert result.i == 4
    assert result.s == "hello"

  dualTest "Load custom variant object":
    let input =
      "---\n- - name: Bastet\n  - kind: akCat\n  - purringIntensity: 7\n" &
      "- - name: Anubis\n  - kind: akDog\n  - barkometer: 13"
    var result: seq[Animal]
    load(input, result)
    assert result.len == 2
    assert result[0].name == "Bastet"
    assert result[0].kind == akCat
    assert result[0].purringIntensity == 7
    assert result[1].name == "Anubis"
    assert result[1].kind == akDog
    assert result[1].barkometer == 13

  test "Dump custom variant object":
    let input = @[Animal(name: "Bastet", kind: akCat, purringIntensity: 7),
                  Animal(name: "Anubis", kind: akDog, barkometer: 13)]
    var output = blockOnlyDumper().dump(input)
    assertStringEqual "" &
        "- - name: Bastet\n" &
        "  - kind: akCat\n" &
        "  - purringIntensity: 7\n" &
        "- - name: Anubis\n" &
        "  - kind: akDog\n" &
        "  - barkometer: 13\n", output

  test "Load custom variant object - missing field":
    let input = "[{name: Bastet}, {kind: akCat}]"
    var result: Animal
    expectConstructionError(1, 1, "While constructing Animal: Missing field: \"purringIntensity\""):
      load(input, result)

  dualTest "Load non-variant object with transient fields":
    let input = "{b: b, d: d}"
    var result: NonVariantWithTransient
    load(input, result)
    assert result.a.len == 0
    assert result.b == "b"
    assert result.c.len == 0
    assert result.d == "d"

  test "Load non-variant object with transient fields - unknown field":
    let input = "{b: b, c: c, d: d}"
    var result: NonVariantWithTransient
    expectConstructionError(1, 8, "While constructing NonVariantWithTransient: Field \"c\" is transient and may not occur in input"):
      load(input, result)

  test "Dump non-variant object with transient fields":
    let input = NonVariantWithTransient(a: "a", b: "b", c: "c", d: "d")
    let output = blockOnlyDumper().dump(input)
    assertStringEqual "b: b\nd: d\n", output

  dualTest "Load variant object with transient fields":
    let input = "[[gStorable: gs, kind: deA, cStorable: cs], [gStorable: a, kind: deC]]"
    var result: seq[VariantWithTransient]
    load(input, result)
    assert result.len == 2
    assert result[0].kind == deA
    assert result[0].gStorable == "gs"
    assert result[0].cStorable == "cs"
    assert result[1].kind == deC
    assert result[1].gStorable == "a"

  test "Load variant object with transient fields, error":
    let input = "[gStorable: gc, kind: deC, neverThere: foo]"
    var result: VariantWithTransient
    expectConstructionError(1, 28, "While constructing VariantWithTransient: Field \"neverThere\" is transient and may not occur in input"):
      load(input, result)

  test "Dump variant object with transient fields":
    let input = @[VariantWithTransient(kind: deA, gStorable: "gs",
        gTemporary: "gt", cStorable: "cs", cTemporary: "ct"),
        VariantWithTransient(kind: deC, gStorable: "a", gTemporary: "b",
        neverThere: 42)]
    let output = blockOnlyDumper().dump(input)
    assertStringEqual "" &
        "- - gStorable: gs\n" &
        "  - kind: deA\n" &
        "  - cStorable: cs\n" &
        "- - gStorable: a\n" &
        "  - kind: deC\n", output

  dualTest "Load object with ignored key":
    let input = "[{x: 1, y: 2}, {x: 3, z: 4, y: 5}, {z: [1, 2, 3], x: 4, y: 5}]"
    var result: seq[WithIgnoredField]
    load(input, result)
    assert result.len == 3
    assert result[0].x == 1
    assert result[0].y == 2
    assert result[1].x == 3
    assert result[1].y == 5
    assert result[2].x == 4
    assert result[2].y == 5

  test "Load object with ignored key - unknown field":
    let input = "{x: 1, y: 2, zz: 3}"
    var result: WithIgnoredField
    expectConstructionError(1, 14, "While constructing WithIgnoredField: Unknown field: \"zz\""):
      load(input, result)

  when not defined(JS):
    test "Dump cyclic data structure":
      var
        a = newNode("a")
        b = newNode("b")
        c = newNode("c")
      a.next = b
      b.next = c
      c.next = a
      var dumper = blockOnlyDumper()
      dumper.serialization.tagStyle = tsRootOnly
      var output = dumper.dump(a)
      assertStringEqual yamlDir & " !example.net:Node &a\n" &
          "value: a\n" &
          "next:\n" &
          "  value: b\n" &
          "  next:\n" &
          "    value: c\n" &
          "    next: *a\n", output

    test "Load cyclic data structure":
      let input = yamlTagDirs & """ !n!system:seq(example.net:Node)
  - &a
    value: a
    next: &b
      value: b
      next: &c
        value: c
        next: *a
  - *b
  - *c
  """
      var result: seq[ref Node]
      try: load(input, result)
      except YamlConstructionError:
        let ex = (ref YamlConstructionError)(getCurrentException())
        echo "line ", ex.mark.line, ", column ", ex.mark.column, ": ", ex.msg
        echo ex.lineContent
        raise ex

      assert(result.len == 3)
      assert(result[0].value == "a")
      assert(result[1].value == "b")
      assert(result[2].value == "c")
      assert(result[0].next == result[1])
      assert(result[1].next == result[2])
      assert(result[2].next == result[0])

  dualTest "Load object with default values":
    let input = "a: abc\nc: dce"
    var result: WithDefault
    load(input, result)
    assert result.a == "abc"
    assert result.b == "b"
    assert result.c == "dce"
    assert result.d == "d"

  dualTest "Load object with partly default values":
    let input = "a: abc\nb: bcd\nc: cde"
    var result: WithDefault
    load(input, result)
    assert result.a == "abc"
    assert result.b == "bcd"
    assert result.c == "cde"
    assert result.d == "d"

  dualTest "Custom constructObject":
    let input = "- 1\n- !test:BetterInt 2"
    var result: seq[BetterInt]
    load(input, result)
    assert(result.len == 2)
    assert(result[0] == 2.BetterInt)
    assert(result[1] == 3.BetterInt)

  test "Custom representObject":
    let input = @[1.BetterInt, 9998887.BetterInt, 98312.BetterInt]
    var dumper = blockOnlyDumper()
    dumper.serialization.tagStyle = tsAll
    dumper.serialization.handles = initNimYamlTagHandle()
    var output = dumper.dump(input)
    assertStringEqual yamlTagDirs & " !n!system:seq(test:BetterInt)\n" &
        "- !test:BetterInt 1\n" &
        "- !test:BetterInt 9_998_887\n" &
        "- !test:BetterInt 98_312\n", output
