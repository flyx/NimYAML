import yaml, yaml/data, streams
type Person = object
  name: string

setTagUri(Person, nimTag("demo:Person"), yTagPerson)

var
  s = newFileStream("in.yaml", fmRead)
  context = newConstructionContext()
  parser = initYamlParser(serializationTagLibrary)
  events = parser.parse(s)

assert events.next().kind == yamlStartStream
assert events.next().kind == yamlStartDoc
assert events.next().kind == yamlStartSeq
var nextEvent = events.peek()
while nextEvent.kind != yamlEndSeq:
  var curTag = nextEvent.properties().tag
  if curTag == yTagQuestionMark:
    # we only support implicitly tagged scalars
    assert nextEvent.kind == yamlScalar
    case guessType(nextEvent.scalarContent)
    of yTypeInteger: curTag = yTagInteger
    of yTypeBoolTrue, yTypeBoolFalse:
      curTag = yTagBoolean
    of yTypeUnknown: curTag = yTagString
    else: assert false, "Type not supported!"
  elif curTag == yTagExclamationMark:
    curTag = yTagString
  case curTag
  of yTagString:
    var s: string
    events.constructChild(context, s)
    echo "got string: ", s
  of yTagInteger:
    var i: int32
    events.constructChild(context, i)
    echo "got integer: ", i
  of yTagBoolean:
    var b: bool
    events.constructChild(context, b)
    echo "got boolean: ", b
  of yTagPerson:
    var p: Person
    events.constructChild(context, p)
    echo "got Person with name: ", p.name
  else: assert false, "unsupported tag: " & $curTag
  nextEvent = events.peek()
assert events.next().kind == yamlEndSeq
assert events.next().kind == yamlEndDoc
assert events.next().kind == yamlEndStream
s.close()