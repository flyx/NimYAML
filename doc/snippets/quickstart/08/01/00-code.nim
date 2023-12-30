import yaml, yaml/data, yaml/parser, yaml/hints, streams
type Person = object
  name: string

setTag(Person, Tag("!Person"), yTagPerson)

var
  s = newFileStream("in.yaml", fmRead)
  yamlParser = initYamlParser()
  events = yamlParser.parse(s)
  context = initConstructionContext(events)

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
    context.constructChild(s)
    echo "got string: ", s
  of yTagInteger:
    var i: int32
    context.constructChild(i)
    echo "got integer: ", i
  of yTagBoolean:
    var b: bool
    context.constructChild(b)
    echo "got boolean: ", b
  of yTagPerson:
    var p: Person
    context.constructChild(p)
    echo "got Person with name: ", p.name
  else: assert false, "unsupported tag: " & $curTag
  nextEvent = events.peek()
assert events.next().kind == yamlEndSeq
assert events.next().kind == yamlEndDoc
assert events.next().kind == yamlEndStream
s.close()