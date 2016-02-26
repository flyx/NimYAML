import "../yaml"
import unittest, strutils

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
    
    BetterInt = int

setTagUriForType(TrafficLight, "!tl")
setTagUriForType(Node, "!example.net:Node")
setTagUriForType(BetterInt, "!test:BetterInt")

proc representObject*(value: BetterInt, ts: TagStyle = tsNone,
                      c: SerializationContext): RawYamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        var
            val = $value
            i = val.len - 3
        while i > 0:
            val.insert("_", i)
            i -= 3
        yield scalarEvent(val, presentTag(BetterInt, ts), yAnchorNone)

proc constructObject*(s: var YamlStream, c: ConstructionContext,
                      result: var BetterInt)
        {.raises: [YamlConstructionError, YamlStreamError].} =
    constructScalarItem(s, item, BetterInt):
        result = BetterInt(parseBiggestInt(item.scalarContent) + 1)

template assertStringEqual(expected, actual: string) =
    for i in countup(0, min(expected.len, actual.len)):
        if expected[i] != actual[i]:
            echo "string mismatch at character #", i, ":"
            echo "expected:\n", expected, "\nactual:\n", actual
            assert(false)

proc newNode(v: string): ref Node =
    new(result)
    result.value = v
    result.next = nil

suite "Serialization":
    test "Serialization: Load string sequence":
        let input = newStringStream(" - a\n - b")
        var result: seq[string]
        load(input, result)
        assert result.len == 2
        assert result[0] == "a"
        assert result[1] == "b"
    
    test "Serialization: Represent string sequence":
        var input = @["a", "b"]
        var output = newStringStream()
        dump(input, output, psBlockOnly, tsNone)
        assertStringEqual "%YAML 1.2\n--- \n- a\n- b", output.data
    
    test "Serialization: Load Table[int, string]":
        let input = newStringStream("23: dreiundzwanzig\n42: zweiundvierzig")
        var result: Table[int32, string]
        load(input, result)
        assert result.len == 2
        assert result[23] == "dreiundzwanzig"
        assert result[42] == "zweiundvierzig"
    
    test "Serialization: Represent Table[int, string]":
        var input = initTable[int32, string]()
        input[23] = "dreiundzwanzig"
        input[42] = "zweiundvierzig"
        var output = newStringStream()
        dump(input, output, psBlockOnly, tsNone)
        assertStringEqual(
                "%YAML 1.2\n--- \n23: dreiundzwanzig\n42: zweiundvierzig",
                output.data)
    
    test "Serialization: Load Sequences in Sequence":
        let input = newStringStream(" - [1, 2, 3]\n - [4, 5]\n - [6]")
        var result: seq[seq[int32]]
        load(input, result)
        assert result.len == 3
        assert result[0] == @[1.int32, 2.int32, 3.int32]
        assert result[1] == @[4.int32, 5.int32]
        assert result[2] == @[6.int32]
    
    test "Serialization: Represent Sequences in Sequence":
        let input = @[@[1.int32, 2.int32, 3.int32], @[4.int32, 5.int32],
                      @[6.int32]]
        var output = newStringStream()
        dump(input, output, psDefault, tsNone)
        assertStringEqual "%YAML 1.2\n--- \n- [1, 2, 3]\n- [4, 5]\n- [6]",
                          output.data
    
    test "Serialization: Load Enum":
        let input = newStringStream("!nim:system:seq(tl)\n- !tl tlRed\n- tlGreen\n- tlYellow")
        var result: seq[TrafficLight]
        load(input, result)
        assert result.len == 3
        assert result[0] == tlRed
        assert result[1] == tlGreen
        assert result[2] == tlYellow
    
    test "Serialization: Represent Enum":
        let input = @[tlRed, tlGreen, tlYellow]
        var output = newStringStream()
        dump(input, output, psBlockOnly, tsNone)
        assertStringEqual "%YAML 1.2\n--- \n- tlRed\n- tlGreen\n- tlYellow",
                          output.data
    
    test "Serialization: Load Tuple":
        let input = newStringStream("str: value\ni: 42\nb: true")
        var result: MyTuple
        load(input, result)
        assert result.str == "value"
        assert result.i == 42
        assert result.b == true

    test "Serialization: Represent Tuple":
        let input = (str: "value", i: 42.int32, b: true)
        var output = newStringStream()
        dump(input, output, psDefault, tsNone)
        assertStringEqual "%YAML 1.2\n--- \nstr: value\ni: 42\nb: y",
                          output.data
    
    test "Serialization: Load custom object":
        let input = newStringStream("firstnamechar: P\nsurname: Pan\nage: 12")
        var result: Person
        load(input, result)
        assert result.firstnamechar == 'P'
        assert result.surname   == "Pan"
        assert result.age == 12
    
    test "Serialization: Represent custom object":
        let input = Person(firstnamechar: 'P', surname: "Pan", age: 12)
        var output = newStringStream()
        dump(input, output, psBlockOnly, tsNone)
        assertStringEqual(
                "%YAML 1.2\n--- \nfirstnamechar: P\nsurname: Pan\nage: 12",
                output.data)
    
    test "Serialization: Load sequence with explicit tags":
        let input = newStringStream("--- !nim:system:seq(" &
                "tag:yaml.org,2002:str)\n- !!str one\n- !!str two")
        var result: seq[string]
        load(input, result)
        assert result[0] == "one"
        assert result[1] == "two"
    
    test "Serialization: Represent sequence with explicit tags":
        let input = @["one", "two"]
        var output = newStringStream()
        dump(input, output, psBlockOnly, tsAll)
        assertStringEqual("%YAML 1.2\n--- !nim:system:seq(" &
                "tag:yaml.org,2002:str) \n- !!str one\n- !!str two",
                output.data)
    
    test "Serialization: Load custom object with explicit root tag":
        let input = newStringStream(
            "--- !nim:custom:Person\nfirstnamechar: P\nsurname: Pan\nage: 12")
        var result: Person
        load(input, result)
        assert result.firstnamechar == 'P'
        assert result.surname   == "Pan"
        assert result.age       == 12
    
    test "Serialization: Represent custom object with explicit root tag":
        let input = Person(firstnamechar: 'P', surname: "Pan", age: 12)
        var output = newStringStream()
        dump(input, output, psBlockOnly, tsRootOnly)
        assertStringEqual("%YAML 1.2\n" &
                "--- !nim:custom:Person \nfirstnamechar: P\nsurname: Pan\nage: 12",
                output.data)
    
    test "Serialization: Represent cyclic data structure":
        var
            a = newNode("a")
            b = newNode("b")
            c = newNode("c")
        a.next = b
        b.next = c
        c.next = a
        var output = newStringStream()
        dump(a, output, psBlockOnly, tsRootOnly)
        assertStringEqual """%YAML 1.2
--- !example.net:Node &a 
value: a
next: 
  value: b
  next: 
    value: c
    next: *a""", output.data
    
    test "Serialization: Load cyclic data structure":
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
    
    test "Serialization: Load nil values":
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
    
    test "Serialization: Represent nil values":
        var input = newSeq[ref string]()
        input.add(nil)
        input.add(new string)
        input[1][] = "~"
        var output = newStringStream()
        dump(input, output, psBlockOnly, tsRootOnly)
        assertStringEqual "%YAML 1.2\n--- !nim:system:seq(tag:yaml.org,2002:str) \n- !!null ~\n- !!str ~",
                output.data
    
    test "Serialization: Custom constructObject":
        let input = newStringStream("- 1\n- !test:BetterInt 2")
        var result: seq[BetterInt]
        load(input, result)
        assert(result.len == 2)
        assert(result[0] == 2)
        assert(result[1] == 3)
    
    test "Serialization: Custom representObject":
        let input = @[1.BetterInt, 9998887.BetterInt, 98312.BetterInt]
        var output = newStringStream()
        dump(input, output, psBlockOnly, tsAll)
        assertStringEqual """%YAML 1.2
--- !nim:system:seq(test:BetterInt) 
- !test:BetterInt 1
- !test:BetterInt 9_998_887
- !test:BetterInt 98_312""", output.data