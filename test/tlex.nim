import ../private/lex

import unittest, strutils

const tokensWithValue = [ltScalarPart, ltQuotedScalar]

type
  TokenWithValue = object
    case kind: LexerToken
    of tokensWithValue:
      value: string
    else: discard

proc assertEquals(input: string, expected: varargs[TokenWithValue]) =
  let lex = newYamlLexer(input)
  lex.init()
  for expectedToken in expected:
    let t = lex.next()
    doAssert t == expectedToken.kind, "Wrong token kind: Expected " &
        $expectedToken.kind & ", got " & $t
    if expectedToken.kind in tokensWithValue:
      doAssert lex.buf == expectedToken.value,
          "Wrong token content: Expected " & escape(expectedToken.value) &
          ", got " & escape(lex.buf)

proc se(): TokenWithValue = TokenWithValue(kind: ltStreamEnd)

suite "Lexer":
  test "Empty document":
    assertEquals("", se())