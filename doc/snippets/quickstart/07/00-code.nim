import yaml
type Person = object
  name : string
  age  : int32

var personList: seq[Person]

var s = newFileStream("in.yaml")
load(s, personList)
s.close()