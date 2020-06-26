import yaml, streams
type
  Person = object
    name: string

  ContainerKind = enum
    ckString, ckInt, ckBool, ckPerson, ckNone

  # {.implicit.} tells NimYAML to use Container
  # as implicit type.
  # only possible with variant object types where
  # each branch contains at most one object.
  Container {.implicit.} = object
    case kind: ContainerKind
    of ckString:
      strVal: string
    of ckInt:
      intVal: int
    of ckBool:
      boolVal: bool
    of ckPerson:
      personVal: Person
    of ckNone:
      discard

setTagUri(Person, nimTag("demo:Person"))

var list: seq[Container]

var s = newFileStream("in.yaml")
load(s, list)
s.close()

assert(list[0].kind == ckString)
assert(list[0].strVal == "this is a string")
# and so on