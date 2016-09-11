import ../private/lex

import unittest, strutils

const tokensWithValue =
    {ltScalarPart, ltQuotedScalar, ltYamlVersion, ltTagShorthand, ltTagUri,
     ltUnknownDirective, ltUnknownDirectiveParams, ltLiteralTag, ltAnchor,
     ltAlias}

type
  TokenWithValue = object
    case kind: LexerToken
    of tokensWithValue:
      value: string
    of ltIndentation:
      indentation: int
    of ltBlockScalarHeader:
      folded: bool
      chomp: ChompType
    of ltTagHandle:
      handle, suffix: string
    else: discard

proc actualRepr(lex: YamlLexer, t: LexerToken): string =
  result = $t
  case t
  of tokensWithValue + {ltTagHandle}:
    result.add("(" & escape(lex.buf) & ")")
  of ltIndentation:
    result.add("(" & $lex.indentation & ")")
  of ltBlockScalarHeader:
    result.add("(" & $lex.folded & ", " & $lex.chomp & ")")
  else: discard

proc assertEquals(input: string, expected: varargs[TokenWithValue]) =
  let lex = newYamlLexer(input)
  var
    i = 0
    blockScalarEnd = -1
    flowDepth = 0
  for expectedToken in expected:
    inc(i)
    try:
      lex.next()
      doAssert lex.cur == expectedToken.kind, "Wrong token kind at #" & $i &
          ": Expected " & $expectedToken.kind & ", got " &
          lex.actualRepr(lex.cur)
      case expectedToken.kind
      of tokensWithValue:
        doAssert lex.buf == expectedToken.value, "Wrong token content at #" &
            $i & ": Expected " & escape(expectedToken.value) &
            ", got " & escape(lex.buf)
        lex.buf = ""
      of ltIndentation:
        doAssert lex.indentation == expectedToken.indentation,
            "Wrong indentation length at #" & $i & ": Expected " &
            $expectedToken.indentation & ", got " & $lex.indentation
        if lex.indentation <= blockScalarEnd:
          lex.endBlockScalar()
          blockScalarEnd = -1
      of ltBlockScalarHeader:
        doAssert lex.folded == expectedToken.folded,
            "Wrong folded indicator at #" & $i & ": Expected " &
            $expectedToken.folded & ", got " & $lex.folded
        doAssert lex.chomp == expectedToken.chomp,
            "Wrong chomp indicator at #" & $i & ": Expected " &
            $expectedToken.chomp & ", got " & $lex.chomp
        blockScalarEnd = lex.indentation
      of ltBraceOpen, ltBracketOpen:
        inc(flowDepth)
        if flowDepth == 1: lex.setFlow(true)
      of ltBraceClose, ltBracketClose:
        dec(flowDepth)
        if flowDepth == 0: lex.setFlow(false)
      of ltTagHandle:
        let
          handle = lex.buf.substr(0, lex.shorthandEnd)
          suffix = lex.buf.substr(lex.shorthandEnd + 1)
        doAssert handle == expectedToken.handle,
            "Wrong handle at #" & $i & ": Expected " & expectedToken.handle &
            ", got " & handle
        doAssert suffix == expectedToken.suffix,
            "Wrong suffix at #" & $i & ": Expected " & expectedToken.suffix &
            ", got " & suffix
        lex.buf = ""
      else: discard
    except YamlLexerError:
      let e = (ref YamlLexerError)(getCurrentException())
      echo "Error at line " & $e.line & ", column " & $e.column & ":"
      echo e.lineContent
      assert false

proc assertLookahead(input: string, expected: bool, tokensBefore: int = 1) =
  let lex = newYamlLexer(input)
  var flowDepth = 0
  for i in 0..tokensBefore:
    lex.next()
    case lex.cur
    of ltBraceOpen, ltBracketOpen:
      inc(flowDepth)
      if flowDepth == 1: lex.setFlow(true)
    of ltBraceClose, ltBracketClose:
      dec(flowDepth)
      if flowDepth == 0: lex.setFlow(false)
    else: discard
  doAssert lex.isImplicitKeyStart() == expected

proc i(indent: int): TokenWithValue =
  TokenWithValue(kind: ltIndentation, indentation: indent)
proc sp(v: string): TokenWithValue =
  TokenWithValue(kind: ltScalarPart, value: v)
proc qs(v: string): TokenWithValue =
  TokenWithValue(kind: ltQuotedScalar, value: v)
proc se(): TokenWithValue = TokenWithValue(kind: ltStreamEnd)
proc mk(): TokenWithValue = TokenWithValue(kind: ltMapKeyInd)
proc mv(): TokenWithValue = TokenWithValue(kind: ltMapValInd)
proc si(): TokenWithValue = TokenWithValue(kind: ltSeqItemInd)
proc dy(): TokenWithValue = TokenWithValue(kind: ltYamlDirective)
proc dt(): TokenWithValue = TokenWithValue(kind: ltTagDirective)
proc du(v: string): TokenWithValue =
  TokenWithValue(kind: ltUnknownDirective, value: v)
proc dp(v: string): TokenWithValue =
  TokenWithValue(kind: ltUnknownDirectiveParams, value: v)
proc yv(v: string): TokenWithValue =
  TokenWithValue(kind: ltYamlVersion, value: v)
proc ts(v: string): TokenWithValue =
  TokenWithValue(kind: ltTagShorthand, value: v)
proc tu(v: string): TokenWithValue =
  TokenWithValue(kind: ltTagUri, value: v)
proc dirE(): TokenWithValue = TokenWithValue(kind: ltDirectivesEnd)
proc docE(): TokenWithValue = TokenWithValue(kind: ltDocumentEnd)
proc bs(folded: bool, chomp: ChompType): TokenWithValue =
  TokenWithValue(kind: ltBlockScalarHeader, folded: folded, chomp: chomp)
proc el(): TokenWithValue = TokenWithValue(kind: ltEmptyLine)
proc ao(): TokenWithValue = TokenWithValue(kind: ltBracketOpen)
proc ac(): TokenWithValue = TokenWithValue(kind: ltBracketClose)
proc oo(): TokenWithValue = TokenWithValue(kind: ltBraceOpen)
proc oc(): TokenWithValue = TokenWithValue(kind: ltBraceClose)
proc c(): TokenWithValue = TokenWithValue(kind: ltComma)
proc th(handle, suffix: string): TokenWithValue =
  TokenWithValue(kind: ltTagHandle, handle: handle, suffix: suffix)
proc lt(v: string): TokenWithValue =
  TokenWithValue(kind: ltLiteralTag, value: v)
proc an(v: string): TokenWithValue = TokenWithValue(kind: ltAnchor, value: v)
proc al(v: string): TokenWithValue = TokenWithValue(kind: ltAlias, value: v)

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

  test "Sequence":
    assertEquals("- a\n- b", i(0), si(), sp("a"), i(0), si(), sp("b"), se())

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

  test "Directives":
    assertEquals("%YAML 1.2\n---\n%TAG\n...\n\n%TAG ! example.html",
        dy(), yv("1.2"), dirE(), i(0), sp("%TAG"), i(0), docE(), dt(),
        ts("!"), tu("example.html"), se())

  test "Markers and Unknown Directive":
    assertEquals("---\n---\n...\n%UNKNOWN warbl", dirE(), dirE(), i(0),
        docE(), du("UNKNOWN"), dp("warbl"), se())

  test "Block scalar":
    assertEquals("|\l  a\l\l  b\l # comment", i(0), bs(false, ctClip), i(2),
        sp("a"), el(), i(2), sp("b"), i(1), se())

  test "Block Scalars":
    assertEquals("one : >2-\l   foo\l  bar\ltwo: |+\l bar\l  baz", i(0),
        sp("one"), mv(), bs(true, ctStrip), i(3), sp(" foo"), i(2), sp("bar"),
        i(0), sp("two"), mv(), bs(false, ctKeep), i(1), sp("bar"), i(2),
        sp(" baz"), se())

  test "Flow indicators":
    assertEquals("bla]: {c: d, [e]: f}", i(0), sp("bla]"), mv(), oo(), sp("c"),
        mv(), sp("d"), c(), ao(), sp("e"), ac(), mv(), sp("f"), oc(), se())

  test "Adjacent map values in flow style":
    assertEquals("{\"foo\":bar, [1]\l:egg}", i(0), oo(), qs("foo"), mv(),
        sp("bar"), c(), ao(), sp("1"), ac(), mv(), sp("egg"), oc(), se())

  test "Tag handles":
    assertEquals("- !!str string\l- !local local\l- !e! e", i(0), si(),
        th("!!", "str"), sp("string"), i(0), si(), th("!", "local"),
        sp("local"), i(0), si(), th("!e!", ""), sp("e"), se())

  test "Literal tag handle":
    assertEquals("!<tag:yaml.org,2002:str> string", i(0),
        lt("tag:yaml.org,2002:str"), sp("string"), se())

  test "Anchors and aliases":
    assertEquals("&a foo: {&b b: *a, *b : c}", i(0), an("a"), sp("foo"), mv(),
        oo(), an("b"), sp("b"), mv(), al("a"), c(), al("b"), mv(), sp("c"),
        oc(), se())

suite "Lookahead":
  test "Simple Scalar":
    assertLookahead("abcde", false)

  test "Simple Mapping":
    assertLookahead("a: b", true)

  test "Colon inside plain scalar":
    assertLookahead("abc:de", false)

  test "Colon inside quoted scalar":
    assertLookahead("'abc: de'", false)

  test "Quotes inside plain scalar":
    assertLookahead("abc\'\"de: foo", true)

  test "Flow indicator inside plain scalar":
    assertLookahead("abc}]: de", true)

  test "Complex key":
    assertLookahead("[1, 2, \"3\"]: foo", true)

  test "Flow value":
    assertLookahead("{a: b}", false)

  test "In flow context":
    assertLookahead("[ abcde]: foo", false, 2)

  test "Adjacent value":
    assertLookahead("[\"abc\":de]", true, 2)