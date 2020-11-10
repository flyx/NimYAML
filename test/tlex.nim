import ../yaml/private/lex

import unittest, strutils

const
  tokensWithValue =
    {Token.Plain, Token.SingleQuoted, Token.DoubleQuoted, Token.Literal,
     Token.Folded, Token.Suffix, Token.VerbatimTag,
     Token.UnknownDirective}
  tokensWithFullLexeme =
    {Token.DirectiveParam, Token.TagHandle}
  tokensWithShortLexeme = {Token.Anchor, Token.Alias}


type
  TokenWithValue = object
    case kind: Token
    of tokensWithValue:
      value: string
    of tokensWithFullLexeme:
      lexeme: string
    of tokensWithShortLexeme:
      slexeme: string
    of Indentation:
      indentation: int
    else: discard

proc actualRepr(lex: Lexer, t: Token): string =
  result = $t
  case t
  of tokensWithValue + {Token.TagHandle}:
    result.add("(" & escape(lex.evaluated) & ")")
  of Indentation:
    result.add("(" & $lex.currentIndentation() & ")")
  else: discard

proc assertEquals(input: string, expected: varargs[TokenWithValue]) =
  var
    lex: Lexer
    i = 0
  lex.init(input)
  for expectedToken in expected:
    inc(i)
    try:
      lex.next()
      doAssert lex.cur == expectedToken.kind, "Wrong token kind at #" & $i &
          ": Expected " & $expectedToken.kind & ", got " &
          lex.actualRepr(lex.cur)
      case expectedToken.kind
      of tokensWithValue:
        doAssert lex.evaluated == expectedToken.value, "Wrong token content at #" &
            $i & ": Expected " & escape(expectedToken.value) &
            ", got " & escape(lex.evaluated)
      of tokensWithFullLexeme:
        doAssert lex.fullLexeme() == expectedToken.lexeme, "Wrong token lexeme at #" &
            $i & ": Expected" & escape(expectedToken.lexeme) &
            ", got " & escape(lex.fullLexeme())
      of tokensWithShortLexeme:
        doAssert lex.shortLexeme() == expectedToken.slexeme, "Wrong token slexeme at #" &
            $i & ": Expected" & escape(expectedToken.slexeme) &
            ", got " & escape(lex.shortLexeme())
      of Indentation:
        doAssert lex.currentIndentation() == expectedToken.indentation,
            "Wrong indentation length at #" & $i & ": Expected " &
            $expectedToken.indentation & ", got " & $lex.currentIndentation()
      else: discard
    except LexerError:
      let e = (ref LexerError)(getCurrentException())
      echo "Error at line", e.line, ", column", e.column, ":", e.msg
      echo e.lineContent
      assert false

proc i(indent: int): TokenWithValue =
  TokenWithValue(kind: Token.Indentation, indentation: indent)
proc pl(v: string): TokenWithValue =
  TokenWithValue(kind: Token.Plain, value: v)
proc sq(v: string): TokenWithValue =
  TokenWithValue(kind: Token.SingleQuoted, value: v)
proc dq(v: string): TokenWithValue =
  TokenWithValue(kind: Token.DoubleQuoted, value: v)
proc e(): TokenWithValue = TokenWithValue(kind: Token.StreamEnd)
proc mk(): TokenWithValue = TokenWithValue(kind: Token.MapKeyInd)
proc mv(): TokenWithValue = TokenWithValue(kind: Token.MapValueInd)
proc si(): TokenWithValue = TokenWithValue(kind: Token.SeqItemInd)
proc dy(): TokenWithValue = TokenWithValue(kind: Token.YamlDirective)
proc dt(): TokenWithValue = TokenWithValue(kind: Token.TagDirective)
proc du(v: string): TokenWithValue =
  TokenWithValue(kind: Token.UnknownDirective, value: v)
proc dp(v: string): TokenWithValue =
  TokenWithValue(kind: Token.DirectiveParam, lexeme: v)
proc th(v: string): TokenWithValue =
  TokenWithValue(kind: Token.TagHandle, lexeme: v)
proc ts(v: string): TokenWithValue =
  TokenWithValue(kind: Token.Suffix, value: v)
proc tv(v: string): TokenWithValue =
  TokenWithValue(kind: Token.VerbatimTag, value: v)
proc dirE(): TokenWithValue = TokenWithValue(kind: Token.DirectivesEnd)
proc docE(): TokenWithValue = TokenWithValue(kind: Token.DocumentEnd)
proc ls(v: string): TokenWithValue = TokenWithValue(kind: Token.Literal, value: v)
proc fs(v: string): TokenWithValue = TokenWithValue(kind: Token.Folded, value: v)
proc ss(): TokenWithValue = TokenWithValue(kind: Token.SeqStart)
proc se(): TokenWithValue = TokenWithValue(kind: Token.SeqEnd)
proc ms(): TokenWithValue = TokenWithValue(kind: Token.MapStart)
proc me(): TokenWithValue = TokenWithValue(kind: Token.MapEnd)
proc sep(): TokenWithValue = TokenWithValue(kind: Token.SeqSep)
proc an(v: string): TokenWithValue = TokenWithValue(kind: Token.Anchor, slexeme: v)
proc al(v: string): TokenWithValue = TokenWithValue(kind: Token.Alias, slexeme: v)

suite "Lexer":
  test "Empty document":
    assertEquals("", e())

  test "Single-line scalar":
    assertEquals("scalar", i(0), pl("scalar"), e())

  test "Multiline scalar":
    assertEquals("scalar\l  line two", i(0), pl("scalar line two"), e())

  test "Single-line mapping":
    assertEquals("key: value", i(0), pl("key"), mv(), pl("value"), e())

  test "Multiline mapping":
    assertEquals("key:\n  value", i(0), pl("key"), mv(), i(2), pl("value"),
        e())

  test "Explicit mapping":
    assertEquals("? key\n: value", i(0), mk(), pl("key"), i(0), mv(),
        pl("value"), e())

  test "Sequence":
    assertEquals("- a\n- b", i(0), si(), pl("a"), i(0), si(), pl("b"), e())

  test "Single-line single-quoted scalar":
    assertEquals("'quoted  scalar'", i(0), sq("quoted  scalar"), e())

  test "Multiline single-quoted scalar":
    assertEquals("'quoted\l  multi line  \l\lscalar'", i(0),
    sq("quoted multi line\lscalar"), e())

  test "Single-line double-quoted scalar":
    assertEquals("\"quoted  scalar\"", i(0), dq("quoted  scalar"), e())

  test "Multiline double-quoted scalar":
    assertEquals("\"quoted\l  multi line  \l\lscalar\"", i(0),
    dq("quoted multi line\lscalar"), e())

  test "Escape sequences":
    assertEquals(""""\n\x31\u0032\U00000033"""", i(0), dq("\l123"), e())

  test "Directives":
    assertEquals("%YAML 1.2\n---\n%TAG\n...\n\n%TAG ! example.html",
        dy(), dp("1.2"), dirE(), i(0), pl("%TAG"), docE(), dt(),
        th("!"), ts("example.html"), e())

  test "Markers and Unknown Directive":
    assertEquals("---\n---\n...\n%UNKNOWN warbl", dirE(), dirE(),
        docE(), du("UNKNOWN"), dp("warbl"), e())

  test "Block scalar":
    assertEquals("|\l  a\l\l  b\l # comment", i(0), ls("a\l\lb\l"), e())

  test "Block Scalars":
    assertEquals("one : >2-\l   foo\l  bar\ltwo: |+\l bar\l  baz", i(0),
        pl("one"), mv(), fs(" foo\nbar"), i(0), pl("two"), mv(),
        ls("bar\l baz"), e())

  test "Flow indicators":
    assertEquals("bla]: {c: d, [e]: f}", i(0), pl("bla]"), mv(), ms(), pl("c"),
        mv(), pl("d"), sep(), ss(), pl("e"), se(), mv(), pl("f"), me(), e())

  test "Adjacent map values in flow style":
    assertEquals("{\"foo\":bar, [1]\l :egg}", i(0), ms(), dq("foo"), mv(),
        pl("bar"), sep(), ss(), pl("1"), se(), mv(), pl("egg"), me(), e())

  test "Tag handles":
    assertEquals("- !!str string\l- !local local\l- !e! e", i(0), si(),
        th("!!"), ts("str"), pl("string"), i(0), si(), th("!"), ts("local"),
        pl("local"), i(0), si(), th("!e!"), ts(""), pl("e"), e())

  test "Literal tag handle":
    assertEquals("!<tag:yaml.org,2002:str> string", i(0),
        tv("tag:yaml.org,2002:str"), pl("string"), e())

  test "Anchors and aliases":
    assertEquals("&a foo: {&b b: *a, *b : c}", i(0), an("a"), pl("foo"), mv(),
        ms(), an("b"), pl("b"), mv(), al("a"), sep(), al("b"), mv(), pl("c"),
        me(), e())

  test "Space at implicit key":
    assertEquals("foo   :\n  bar", i(0), pl("foo"), mv(), i(2), pl("bar"), e())

  test "inline anchor at implicit key":
    assertEquals("top6: \l  &anchor6 'key6' : scalar6", i(0), pl("top6"), mv(),
                 i(2), an("anchor6"), sq("key6"), mv(), pl("scalar6"), e())

  test "adjacent anchors":
    assertEquals("foo: &a\n  &b bar", i(0), pl("foo"), mv(), an("a"), i(2),
        an("b"), pl("bar"), e())

  test "comment at empty key/value pair":
    assertEquals(": # foo\nbar:", i(0), mv(), i(0), pl("bar"), mv(), e())

  test "Map in Sequence":
    assertEquals("""-
  a: b
  c: d
""", i(0), si(), i(2), pl("a"), mv(), pl("b"), i(2), pl("c"), mv(), pl("d"), e())

  test "dir end after multiline scalar":
    assertEquals("foo:\n  bar\n  baz\n---\nderp", i(0), pl("foo"), mv(), i(2),
                 pl("bar baz"), dirE(), i(0), pl("derp"), e())

  test "Sequence with compact maps":
    assertEquals("- a: drzw\n- b", i(0), si(), pl("a"), mv(), pl("drzw"), i(0), si(), pl("b"), e())

  test "Empty lines":
    assertEquals("""block: foo

  bar

    baz
flow: {
  foo

  bar: baz


  mi
}""", i(0), pl("block"), mv(), pl("foo\nbar\nbaz"),
    i(0), pl("flow"), mv(), ms(), pl("foo\nbar"), mv(),
    pl("baz\n\nmi"), me(), e())
