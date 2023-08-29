import yaml, streams
type Person = object
  name: string
  age: int32

var personList = newSeq[Person]()
personList.add(Person(name: "Karl Koch", age: 23))
personList.add(Person(name: "Peter Pan", age: 12))

var s = newFileStream("out.yaml", fmWrite)
var dumper = canonicalDumper()
dumper.serialization.handles = initNimYamlTagHandle()
dumper.presentation.indentationStep = 3
dumper.presentation.newlines = nlLF
dumper.presentation.outputVersion = ov1_1
dumper.dump(personList, s)
s.close()