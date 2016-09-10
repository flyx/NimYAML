import ../private/lex

import unittest, strutils

const tokensWithValue = [ltScalarPart, ltQuotedScalar]

type
  TokenWithValue = object
    case kind: LexerToken
    of tokensWithValue:
      value: string
    of ltIndentation:
      indentation: int
    else: discard

proc assertEquals(input: string, expected: varargs[TokenWithValue]) =
  let lex = newYamlLexer(input)
  lex.init()
  for expectedToken in expected:
    let t = lex.next()
    doAssert t == expectedToken.kind, "Wrong token kind: Expected " &
        $expectedToken.kind & ", got " & $t
    case expectedToken.kind 
    of tokensWithValue:
      doAssert lex.buf == expectedToken.value,
          "Wrong token content: Expected " & escape(expectedToken.value) &
          ", got " & escape(lex.buf)
      lex.buf = ""
    of ltIndentation:
      doAssert lex.indentation == expectedToken.indentation,
          "Wrong indentation length: Expected " & $expectedToken.indentation &
          ", got " & $lex.indentation
    else: discard

proc i(indent: int): TokenWithValue =
  TokenWithValue(kind: ltIndentation, indentation: indent)
proc sp(v: string): TokenWithValue =
  TokenWithValue(kind: ltScalarPart, value: v)
proc qs(v: string): TokenWithValue =
  TokenWithValue(kind: ltQuotedScalar, value: v)
proc se(): TokenWithValue = TokenWithValue(kind: ltStreamEnd)
proc mk(): TokenWithValue = TokenWithValue(kind: ltMapKeyInd)
proc mv(): TokenWithValue = TokenWithValue(kind: ltMapValInd)

suite "Lexer":
  test "Empty document":
    assertEquals("", se())
  
  test "Single-line scalar":
    assertEquals("scalar", i(0), sp("scalar"), se())
  
  test "Multiline scalar":
    assertEquals("scalar\l  line two", i(0), sp("scalar"), i(2),
        sp("line two"), se())
  
  test "Single-line mapping":
    assertEquals("key: value", i(0), sp("key"), mv(), sp("value"), se())
  
  test "Multiline mapping":
    assertEquals("key:\n  value", i(0), sp("key"), mv(), i(2), sp("value"),
        se())
  
  test "Explicit mapping":
    assertEquals("? key\n: value", i(0), mk(), sp("key"), i(0), mv(),
        sp("value"), se())
  
  test "Single-line single-quoted scalar":
    assertEquals("'quoted  scalar'", i(0), qs("quoted  scalar"), se())
  
  test "Multiline single-quoted scalar":
    assertEquals("'quoted\l  multi line  \l\lscalar'", i(0),
    qs("quoted multi line\lscalar"), se())
  
  test "Single-line double-quoted scalar":
    assertEquals("\"quoted  scalar\"", i(0), qs("quoted  scalar"), se())
  
  test "Multiline double-quoted scalar":
    assertEquals("\"quoted\l  multi line  \l\lscalar\"", i(0),
    qs("quoted multi line\lscalar"), se())
  
  test "Escape sequences":
    assertEquals(""""\n\x31\u0032\U00000033"""", i(0), qs("\l123"), se())