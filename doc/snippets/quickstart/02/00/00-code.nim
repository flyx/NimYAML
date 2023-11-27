import yaml, yaml/style, streams

type
  Strings = object
    first {.scalar: ssSingleQuoted.}: string
    second {.scalar: ssLiteral.}: string
    third {.scalar: ssDoubleQuoted.}: string
  
  Numbers {.collection: csFlow.} = object
    start, stop: int32
  
  Root = object
    strings: Strings
    numbers: Numbers
    blockNumbers {.collection: csBlock.}: Numbers

var root = Root(
  strings: Strings(
    first: "foo", second: "bar\n", third: "baz"
  ),
  numbers: Numbers(start: 0, stop: 23),
  blockNumbers: Numbers(start: 23, stop: 42)
)

var s = newFileStream("out.yaml", fmWrite)
Dumper().dump(root, s)
s.close()