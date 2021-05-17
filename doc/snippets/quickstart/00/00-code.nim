import yaml/serialization, streams
type Person = object
  name : string
  age  : int32

var personList = newSeq[Person]()
personList.add(Person(name: "Karl Koch", age: 23))
personList.add(Person(name: "Peter Pan", age: 12))

var s = newFileStream("out.yaml", fmWrite)
dump(personList, s)
s.close()