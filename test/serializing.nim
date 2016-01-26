import "../yaml/serialization"
import unittest

serializable:
    type
        Person = object
            firstname, surname: string
            age: int32

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
        assert output.data == "%YAML 1.2\n--- \n- a\n- b"
    
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
        assert output.data == "%YAML 1.2\n--- \n23: dreiundzwanzig\n42: zweiundvierzig"
    
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
        assert output.data == "%YAML 1.2\n--- \n- [1, 2, 3]\n- [4, 5]\n- [6]"
    
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
        assert output.data == "%YAML 1.2\n--- \nfirstname: Peter\nsurname: Pan\nage: 12"
    
    test "Serialization: Load sequence with explicit tags":
        let input = newStringStream(
            "--- !nim:seq(tag:yaml.org,2002:str)\n- !!str one\n- !!str two")
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
        assert output.data == "%YAML 1.2\n--- !nim:seq(tag:yaml.org,2002:str) \n- !!str one\n- !!str two"
    
    test "Serialization: Load custom object with explicit root tag":
        let input = newStringStream(
            "--- !nim:Person\nfirstname: Peter\nsurname: Pan\nage: 12")
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
        assert output.data == "%YAML 1.2\n--- !nim:Person \nfirstname: Peter\nsurname: Pan\nage: 12"