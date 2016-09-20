#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import "../yaml"
import unittest, strutils, streams, tables

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
    of akDog:
      barkometer: int

proc `$`(v: BetterInt): string {.borrow.}
proc `==`(left, right: BetterInt): bool {.borrow.}

setTagUri(TrafficLight, "!tl")
setTagUri(Node, "!example.net:Node")
setTagUri(BetterInt, "!test:BetterInt")

proc representObject*(value: BetterInt, ts: TagStyle = tsNone,
    c: SerializationContext, tag: TagId) {.raises: [].} =
  var
    val = $value
    i = val.len - 3
  while i > 0:
    val.insert("_", i)
    i -= 3
  c.put(scalarEvent(val, tag, yAnchorNone))

proc constructObject*(s: var YamlStream, c: ConstructionContext,
                      result: var BetterInt)
    {.raises: [YamlConstructionError, YamlStreamError].} =
  constructScalarItem(s, item, BetterInt):
    result = BetterInt(parseBiggestInt(item.scalarContent) + 1)

template assertStringEqual(expected, actual: string) =
  for i in countup(0, min(expected.len, actual.len)):
    if expected[i] != actual[i]:
      echo "string mismatch at character #", i, "(expected:\'",
            expected[i], "\', was \'", actual[i], "\'):"
      echo "expected:\n", expected, "\nactual:\n", actual
      assert(false)

proc newNode(v: string): ref Node =
  new(result)
  result.value = v
  result.next = nil

let blockOnly = defineOptions(style=psBlockOnly)

suite "Serialization":
  test "Load integer without fixed length":
    var input = newStringStream("-4247")
    var result: int
    load(input, result)
    assert result == -4247, "result is " & $result

    input = newStringStream($(int64(int32.high) + 1'i64))
    var gotException = false
    try: load(input, result)
    except: gotException = true
    assert gotException, "Expected exception, got none."

  test "Dump integer without fixed length":
    var input = -4247
    var output = dump(input, tsNone, asTidy, blockOnly)
    assertStringEqual "%YAML 1.2\n--- \n\"-4247\"", output

    when sizeof(int) == sizeof(int64):
      input = int(int32.high) + 1
      var gotException = false
      try: output = dump(input, tsNone, asTidy, blockOnly)
      except: gotException = true
      assert gotException, "Expected exception, got none."

  test "Load Hex byte (0xFF)":
    let input = newStringStream("0xFF")
    var result: byte
    load(input, result)
    assert(result == 255)

  test "Load Hex byte (0xC)":
    let input = newStringStream("0xC")
    var result: byte
    load(input, result)
    assert(result == 12)

  test "Load Octal byte (0o14)":
    let input = newStringStream("0o14")
    var result: byte
    load(input, result)
    assert(result == 12)

  test "Load byte (14)":
    let input = newStringStream("14")
    var result: byte
    load(input, result)
    assert(result == 14)

  test "Load Hex int (0xFF)":
    let input = newStringStream("0xFF")
    var result: int
    load(input, result)
    assert(result == 255)

  test "Load Hex int (0xC)":
    let input = newStringStream("0xC")
    var result: int
    load(input, result)
    assert(result == 12)

  test "Load Octal int (0o14)":
    let input = newStringStream("0o14")
    var result: int
    load(input, result)
    assert(result == 12)

  test "Load int (14)":
    let input = newStringStream("14")
    var result: int
    load(input, result)
    assert(result == 14)

  test "Load nil string":
    let input = newStringStream("!nim:nil:string \"\"")
    var result: string
    load(input, result)
    assert isNil(result)

  test "Dump nil string":
    let input: string = nil
    var output = dump(input, tsNone, asTidy, blockOnly)
    assertStringEqual "%YAML 1.2\n--- \n!nim:nil:string \"\"", output

  test "Load string sequence":
    let input = newStringStream(" - a\n - b")
    var result: seq[string]
    load(input, result)
    assert result.len == 2
    assert result[0] == "a"
    assert result[1] == "b"

  test "Dump string sequence":
    var input = @["a", "b"]
    var output = dump(input, tsNone, asTidy, blockOnly)
    assertStringEqual "%YAML 1.2\n--- \n- a\n- b", output

  test "Load nil seq":
    let input = newStringStream("!nim:nil:seq \"\"")
    var result: seq[int]
    load(input, result)
    assert isNil(result)

  test "Dump nil seq":
    let input: seq[int] = nil
    var output = dump(input, tsNone, asTidy, blockOnly)
    assertStringEqual "%YAML 1.2\n--- \n!nim:nil:seq \"\"", output

  test "Load char set":
    let input = newStringStream("- a\n- b")
    var result: set[char]
    load(input, result)
    assert result.card == 2
    assert 'a' in result
    assert 'b' in result

  test "Dump char set":
    var input = {'a', 'b'}
    var output = dump(input, tsNone, asTidy, blockOnly)
    assertStringEqual "%YAML 1.2\n--- \n- a\n- b", output

  test "Load array":
    let input = newStringStream("- 23\n- 42\n- 47")
    var result: array[0..2, int32]
    load(input, result)
    assert result[0] == 23
    assert result[1] == 42
    assert result[2] == 47

  test "Dump array":
    let input = [23'i32, 42'i32, 47'i32]
    var output = dump(input, tsNone, asTidy, blockOnly)
    assertStringEqual "%YAML 1.2\n--- \n- 23\n- 42\n- 47", output

  test "Load Table[int, string]":
    let input = newStringStream("23: dreiundzwanzig\n42: zweiundvierzig")
    var result: Table[int32, string]
    load(input, result)
    assert result.len == 2
    assert result[23] == "dreiundzwanzig"
    assert result[42] == "zweiundvierzig"

  test "Dump Table[int, string]":
    var input = initTable[int32, string]()
    input[23] = "dreiundzwanzig"
    input[42] = "zweiundvierzig"
    var output = dump(input, tsNone, asTidy, blockOnly)
    assertStringEqual("%YAML 1.2\n--- \n23: dreiundzwanzig\n42: zweiundvierzig",
        output)

  test "Load OrderedTable[tuple[int32, int32], string]":
    let input = newStringStream("- {a: 23, b: 42}: drzw\n- {a: 13, b: 47}: drsi")
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
    input.add((a: 23'i32, b: 42'i32), "dreiundzwanzigzweiundvierzig")
    input.add((a: 13'i32, b: 47'i32), "dreizehnsiebenundvierzig")
    var output = dump(input, tsRootOnly, asTidy, blockOnly)
    assertStringEqual("""%YAML 1.2
--- !nim:tables:OrderedTable(nim:tuple(nim:system:int32,nim:system:int32),tag:yaml.org,2002:str) 
- 
  ? 
    a: 23
    b: 42
  : dreiundzwanzigzweiundvierzig
- 
  ? 
    a: 13
    b: 47
  : dreizehnsiebenundvierzig""", output)

  test "Load Sequences in Sequence":
    let input = newStringStream(" - [1, 2, 3]\n - [4, 5]\n - [6]")
    var result: seq[seq[int32]]
    load(input, result)
    assert result.len == 3
    assert result[0] == @[1.int32, 2.int32, 3.int32]
    assert result[1] == @[4.int32, 5.int32]
    assert result[2] == @[6.int32]

  test "Dump Sequences in Sequence":
    let input = @[@[1.int32, 2.int32, 3.int32], @[4.int32, 5.int32], @[6.int32]]
    var output = dump(input, tsNone)
    assertStringEqual "%YAML 1.2\n--- \n- [1, 2, 3]\n- [4, 5]\n- [6]", output

  test "Load Enum":
    let input =
      newStringStream("!nim:system:seq(tl)\n- !tl tlRed\n- tlGreen\n- tlYellow")
    var result: seq[TrafficLight]
    load(input, result)
    assert result.len == 3
    assert result[0] == tlRed
    assert result[1] == tlGreen
    assert result[2] == tlYellow

  test "Dump Enum":
    let input = @[tlRed, tlGreen, tlYellow]
    var output = dump(input, tsNone, asTidy, blockOnly)
    assertStringEqual "%YAML 1.2\n--- \n- tlRed\n- tlGreen\n- tlYellow", output

  test "Load Tuple":
    let input = newStringStream("str: value\ni: 42\nb: true")
    var result: MyTuple
    load(input, result)
    assert result.str == "value"
    assert result.i == 42
    assert result.b == true

  test "Dump Tuple":
    let input = (str: "value", i: 42.int32, b: true)
    var output = dump(input, tsNone)
    assertStringEqual "%YAML 1.2\n--- \nstr: value\ni: 42\nb: y", output

  test "Load Multiple Documents":
    let input = newStringStream("1\n---\n2")
    var result: seq[int]
    loadMultiDoc(input, result)
    assert(result.len == 2)
    assert result[0] == 1
    assert result[1] == 2

  test "Load Multiple Documents (Single Doc)":
    let input = newStringStream("1")
    var result: seq[int]
    loadMultiDoc(input, result)
    assert(result.len == 1)
    assert result[0] == 1

  test "Load custom object":
    let input = newStringStream("firstnamechar: P\nsurname: Pan\nage: 12")
    var result: Person
    load(input, result)
    assert result.firstnamechar == 'P'
    assert result.surname   == "Pan"
    assert result.age == 12

  test "Dump custom object":
    let input = Person(firstnamechar: 'P', surname: "Pan", age: 12)
    var output = dump(input, tsNone, asTidy, blockOnly)
    assertStringEqual(
        "%YAML 1.2\n--- \nfirstnamechar: P\nsurname: Pan\nage: 12", output)

  test "Load sequence with explicit tags":
    let input = newStringStream("--- !nim:system:seq(" &
        "tag:yaml.org,2002:str)\n- !!str one\n- !!str two")
    var result: seq[string]
    load(input, result)
    assert result[0] == "one"
    assert result[1] == "two"

  test "Dump sequence with explicit tags":
    let input = @["one", "two"]
    var output = dump(input, tsAll, asTidy, blockOnly)
    assertStringEqual("%YAML 1.2\n--- !nim:system:seq(" &
        "tag:yaml.org,2002:str) \n- !!str one\n- !!str two", output)

  test "Load custom object with explicit root tag":
    let input = newStringStream(
        "--- !nim:custom:Person\nfirstnamechar: P\nsurname: Pan\nage: 12")
    var result: Person
    load(input, result)
    assert result.firstnamechar == 'P'
    assert result.surname   == "Pan"
    assert result.age       == 12

  test "Dump custom object with explicit root tag":
    let input = Person(firstnamechar: 'P', surname: "Pan", age: 12)
    var output = dump(input, tsRootOnly, asTidy, blockOnly)
    assertStringEqual("%YAML 1.2\n" &
        "--- !nim:custom:Person \nfirstnamechar: P\nsurname: Pan\nage: 12",
        output)

  test "Load custom variant object":
    let input = newStringStream(
      "---\n- - name: Bastet\n  - kind: akCat\n  - purringIntensity: 7\n" &
      "- - name: Anubis\n  - kind: akDog\n  - barkometer: 13")
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
    var output = dump(input, tsNone, asTidy, blockOnly)
    assertStringEqual """%YAML 1.2
--- 
- 
  - 
    name: Bastet
  - 
    kind: akCat
  - 
    purringIntensity: 7
- 
  - 
    name: Anubis
  - 
    kind: akDog
  - 
    barkometer: 13""", output

  test "Dump cyclic data structure":
    var
      a = newNode("a")
      b = newNode("b")
      c = newNode("c")
    a.next = b
    b.next = c
    c.next = a
    var output = dump(a, tsRootOnly, asTidy, blockOnly)
    assertStringEqual """%YAML 1.2
--- !example.net:Node &a 
value: a
next: 
  value: b
  next: 
    value: c
    next: *a""", output

  test "Load cyclic data structure":
    let input = newStringStream("""%YAML 1.2
--- !nim:system:seq(example.net:Node) 
- &a 
  value: a
  next: &b 
    value: b
    next: &c 
      value: c
      next: *a
- *b
- *c
""")
    var result: seq[ref Node]
    try: load(input, result)
    except YamlConstructionError:
      let ex = (ref YamlConstructionError)(getCurrentException())
      echo "line ", ex.line, ", column ", ex.column, ": ", ex.msg
      echo ex.lineContent
      raise ex

    assert(result.len == 3)
    assert(result[0].value == "a")
    assert(result[1].value == "b")
    assert(result[2].value == "c")
    assert(result[0].next == result[1])
    assert(result[1].next == result[2])
    assert(result[2].next == result[0])

  test "Load nil values":
    let input = newStringStream("- ~\n- !!str ~")
    var result: seq[ref string]
    try: load(input, result)
    except YamlConstructionError:
      let ex = (ref YamlConstructionError)(getCurrentException())
      echo "line ", ex.line, ", column ", ex.column, ": ", ex.msg
      echo ex.lineContent
      raise ex

    assert(result.len == 2)
    assert(result[0] == nil)
    assert(result[1][] == "~")

  test "Dump nil values":
    var input = newSeq[ref string]()
    input.add(nil)
    input.add(new string)
    input[1][] = "~"
    var output = dump(input, tsRootOnly, asTidy, blockOnly)
    assertStringEqual(
        "%YAML 1.2\n--- !nim:system:seq(tag:yaml.org,2002:str) \n- !!null ~\n- !!str ~",
        output)

  test "Custom constructObject":
    let input = newStringStream("- 1\n- !test:BetterInt 2")
    var result: seq[BetterInt]
    load(input, result)
    assert(result.len == 2)
    assert(result[0] == 2.BetterInt)
    assert(result[1] == 3.BetterInt)

  test "Custom representObject":
    let input = @[1.BetterInt, 9998887.BetterInt, 98312.BetterInt]
    var output = dump(input, tsAll, asTidy, blockOnly)
    assertStringEqual """%YAML 1.2
--- !nim:system:seq(test:BetterInt) 
- !test:BetterInt 1
- !test:BetterInt 9_998_887
- !test:BetterInt 98_312""", output
