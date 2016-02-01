import "../yaml/serialization"
import unittest

type
    MyTuple = tuple
        str: string
        i: int32
        b: bool
    
    TrafficLight = enum
        tlGreen, tlYellow, tlRed
    
    Person = object
        firstname, surname: string
        age: int32
    
    Node = object
        value: string
        next: ref Node

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
    setup:
        var tagLib = serializationTagLibrary

    test "Serialization: Load string sequence":
        let input = newStringStream(" - a\n - b")
        var
            result: seq[string]
            parser = newYamlParser(tagLib)
            events = parser.parse(input)
        construct(events, result)
        assert result.len == 2
        assert result[0] == "a"
        assert result[1] == "b"
    
    test "Serialization: Serialize string sequence":
        var input = @["a", "b"]
        var output = newStringStream()
        dump(input, output, psBlockOnly, tsNone)
        assertStringEqual "%YAML 1.2\n--- \n- a\n- b", output.data
    
    test "Serialization: Load Table[int, string]":
        let input = newStringStream("23: dreiundzwanzig\n42: zweiundvierzig")
        var
            result: Table[int32, string]
            parser = newYamlParser(tagLib)
            events = parser.parse(input)
        construct(events, result)
        assert result.len == 2
        assert result[23] == "dreiundzwanzig"
        assert result[42] == "zweiundvierzig"
    
    test "Serialization: Serialize Table[int, string]":
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
        var
            result: seq[seq[int32]]
            parser = newYamlParser(tagLib)
            events = parser.parse(input)
        construct(events, result)
        assert result.len == 3
        assert result[0] == @[1.int32, 2.int32, 3.int32]
        assert result[1] == @[4.int32, 5.int32]
        assert result[2] == @[6.int32]
    
    test "Serialization: Serialize Sequences in Sequence":
        let input = @[@[1.int32, 2.int32, 3.int32], @[4.int32, 5.int32],
                      @[6.int32]]
        var output = newStringStream()
        dump(input, output, psDefault, tsNone)
        assertStringEqual "%YAML 1.2\n--- \n- [1, 2, 3]\n- [4, 5]\n- [6]",
                          output.data
    
    test "Serialization: Load Enum":
        let input = newStringStream("- tlRed\n- tlGreen\n- tlYellow")
        var
            result: seq[TrafficLight]
            parser = newYamlParser(tagLib)
            events = parser.parse(input)
        construct(events, result)
        assert result.len == 3
        assert result[0] == tlRed
        assert result[1] == tlGreen
        assert result[2] == tlYellow
    
    test "Serialization: Serialize Enum":
        let input = @[tlRed, tlGreen, tlYellow]
        var output = newStringStream()
        dump(input, output, psBlockOnly, tsNone)
        assertStringEqual "%YAML 1.2\n--- \n- tlRed\n- tlGreen\n- tlYellow",
                          output.data
    
    test "Serialization: Load Tuple":
        let input = newStringStream("str: value\ni: 42\nb: true")
        var
            result: MyTuple
            parser = newYamlParser(tagLib)
            events = parser.parse(input)
        construct(events, result)
        assert result.str == "value"
        assert result.i == 42
        assert result.b == true

    test "Serialization: Serialize Tuple":
        let input = (str: "value", i: 42.int32, b: true)
        var output = newStringStream()
        dump(input, output, psDefault, tsNone)
        assertStringEqual "%YAML 1.2\n--- \nstr: value\ni: 42\nb: y",
                          output.data
    
    test "Serialization: Load custom object":
        let input = newStringStream("firstname: Peter\nsurname: Pan\nage: 12")
        var
            result: Person
            parser = newYamlParser(tagLib)
            events = parser.parse(input)
        construct(events, result)
        assert result.firstname == "Peter"
        assert result.surname   == "Pan"
        assert result.age == 12
    
    test "Serialization: Serialize custom object":
        let input = Person(firstname: "Peter", surname: "Pan", age: 12)
        var output = newStringStream()
        dump(input, output, psBlockOnly, tsNone)
        assertStringEqual(
                "%YAML 1.2\n--- \nfirstname: Peter\nsurname: Pan\nage: 12",
                output.data)
    
    test "Serialization: Load sequence with explicit tags":
        let input = newStringStream("--- !nim:system:seq(" &
                "tag:yaml.org,2002:str)\n- !!str one\n- !!str two")
        var
            result: seq[string]
            parser = newYamlParser(tagLib)
            events = parser.parse(input)
        construct(events, result)
        assert result[0] == "one"
        assert result[1] == "two"
    
    test "Serialization: Serialize sequence with explicit tags":
        let input = @["one", "two"]
        var output = newStringStream()
        dump(input, output, psBlockOnly, tsAll)
        assertStringEqual("%YAML 1.2\n--- !nim:system:seq(" &
                "tag:yaml.org,2002:str) \n- !!str one\n- !!str two",
                output.data)
    
    test "Serialization: Load custom object with explicit root tag":
        let input = newStringStream(
            "--- !nim:custom:Person\nfirstname: Peter\nsurname: Pan\nage: 12")
        var
            result: Person
            parser = newYamlParser(tagLib)
            events = parser.parse(input)
        construct(events, result)
        assert result.firstname == "Peter"
        assert result.surname   == "Pan"
        assert result.age       == 12
    
    test "Serialization: Serialize custom object with explicit root tag":
        let input = Person(firstname: "Peter", surname: "Pan", age: 12)
        var output = newStringStream()
        dump(input, output, psBlockOnly, tsRootOnly)
        assertStringEqual("%YAML 1.2\n" &
                "--- !nim:custom:Person \nfirstname: Peter\nsurname: Pan\nage: 12",
                output.data)
    
    test "Serialization: Serialize cyclic data structure":
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
--- !nim:custom:Node &a 
value: a
next: 
  value: b
  next: 
    value: c
    next: *a""", output.data
    
    test "Serialization: Load cyclic data structure":
        let input = newStringStream("""%YAML 1.2
--- !nim:system:seq(nim:custom:Node)
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
        var
            result: seq[ref Node]
            parser = newYamlParser(tagLib)
            events = parser.parse(input)
        construct(events, result)
        assert(result.len == 3)
        assert(result[0].value == "a")
        assert(result[1].value == "b")
        assert(result[2].value == "c")
        assert(result[0].next == result[1])
        assert(result[1].next == result[2])
        assert(result[2].next == result[0])
        