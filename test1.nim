import yaml, macros

type
  FooKind = enum
    fooInt, fooBool, fooNone
  FooKind2 = enum
    fooAddString, fooAddNone
  
  Foo = object
    a: string
    case b: FooKind
    of fooInt:
      c: int32
    of fooBool:
      d: bool
    of fooNone:
      discard
    case c2: FooKind2
    of fooAddString:
      e: string
    of fooAddNone:
      discard

var o = newFileStream(stdout)
var f = Foo(a: "a", b: fooBool, d: true)

dump(f, o)