import yaml
type Person = object
  name: string
  age: int32

var personList: seq[Person]
personList.add(Person(name: "Karl Koch", age: 23))
personList.add(Person(name: "Peter Pan", age: 12))

var s = newFileStream("out.yaml")
dump(personList, s, options = defineOptions(
    style = psCanonical,
    indentationStep = 3,
    newlines = nlLF,
    outputVersion = ov1_1))
s.close()