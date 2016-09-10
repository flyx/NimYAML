import ../private/lex

import unittest

type
  TokenWithValue = object
    case kind: LexerToken
    of ltScalarPart, ltQuotedScalar:
      value: string
    else: discard

proc assertEquals(input: string, expected: varargs[TokenWithValue]) =
  let lex = newYamlLexer[StringSource](input)
  

suite "Lexer":
  test "Empty document":
    