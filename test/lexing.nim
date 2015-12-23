import streams, unicode, lexbase

import unittest

type
    YamlTypeHint* = enum
        yTypeInteger, yTypeFloat, yTypeBoolean, yTypeNull, yTypeString,
        yTypeUnknown
include "../src/private/lexer"

type BasicLexerToken = tuple[kind: YamlLexerToken, content: string,
                             typeHint: YamlTypeHint]

template ensure(input: string, expected: openarray[BasicLexerToken]) =
    var
        i = 0
        lex: YamlLexer
    lex.open(newStringStream(input))
    for token in lex.tokens:
        if i >= expected.len:
            echo "received more tokens than expected (next token = ",
                 token, ")"
            fail()
            break
        if token != expected[i].kind:
            if token == tError:
                echo "got lexer error: " & lex.content
            else:
                echo "wrong token kind (expected ", expected[i], ", got ",
                     token, ")"
            fail()
            break
        if not isNil(expected[i].content):
            if lex.content != expected[i].content:
                echo "wrong token content (", token, ": expected \"",
                     expected[i].content, "\", got \"", lex.content, "\")"
                fail()
                break
        if token == tScalarPart:
            if lex.typeHint != expected[i].typeHint:
                echo "wrong type hint (expected ", expected[i].typeHint,
                     ", got ", lex.typeHint, ")"
                fail()
                break
        inc(i)
    if i < expected.len:
        echo "received less tokens than expected (first missing = ",
             expected[i].kind, ")"

proc t(kind: YamlLexerToken, content: string,
        typeHint: YamlTypeHint = yTypeUnknown): BasicLexerToken =
    (kind: kind, content: content, typeHint: typeHint)

suite "Lexing":
    test "Lexing: YAML Directive":
        ensure("%YAML 1.2", [t(tYamlDirective, nil),
                             t(tVersionPart, "1"),
                             t(tVersionPart, "2"),
                             t(tStreamEnd, nil)])
    
    test "Lexing: TAG Directive":
        ensure("%TAG !t! tag:http://example.com/",
               [t(tTagDirective, nil),
                t(tTagHandle, "!t!"),
                t(tTagURI, "tag:http://example.com/"),
                t(tStreamEnd, nil)])
    
    test "Lexing: Unknown Directive":
        ensure("%FOO bar baz", [t(tUnknownDirective, "%FOO"),
                                t(tUnknownDirectiveParam, "bar"),
                                t(tUnknownDirectiveParam, "baz"),
                                t(tStreamEnd, nil)])
    
    test "Lexing: Comments after Directives":
        ensure("%YAML 1.2 # version\n# at line start\n    # indented\n%FOO",
                [t(tYamlDirective, nil),
                 t(tVersionPart, "1"),
                 t(tVersionPart, "2"),
                 t(tComment, " version"),
                 t(tComment, " at line start"),
                 t(tComment, " indented"),
                 t(tUnknownDirective, "%FOO"),
                 t(tStreamEnd, nil)])
    
    test "Lexing: Directives End":
        ensure("---", [t(tDirectivesEnd, nil),
                       t(tStreamEnd, nil)])
    
    test "Lexing: Document End":
        ensure("...", [t(tLineStart, nil),
                       t(tDocumentEnd, nil),
                       t(tStreamEnd, nil)])
    
    test "Lexing: Directive after Document End":
        ensure("content\n...\n%YAML 1.2",
                [t(tLineStart, ""),
                 t(tScalarPart, "content"),
                 t(tLineStart, ""),
                 t(tDocumentEnd, nil),
                 t(tYamlDirective, nil),
                 t(tVersionPart, "1"),
                 t(tVersionPart, "2"),
                 t(tStreamEnd, nil)])
    
    test "Lexing: Plain Scalar (alphanumeric)":
        ensure("abA03rel4", [t(tLineStart, ""),
                             t(tScalarPart, "abA03rel4"),
                             t(tStreamEnd, nil)])
    
    test "Lexing: Plain Scalar (with spaces)":
        ensure("test content", [t(tLineStart, ""),
                                t(tScalarPart, "test content"),
                                t(tStreamEnd, nil)])
    
    test "Lexing: Plain Scalar (with special chars)":
        ensure(":test ?content -with #special !chars",
               [t(tLineStart, nil),
                t(tScalarPart, ":test ?content -with #special !chars"),
                t(tStreamEnd, nil)])
    
    test "Lexing: Plain Scalar (starting with %)":
        ensure("---\n%test", [t(tDirectivesEnd, nil),
                              t(tLineStart, ""),
                              t(tScalarPart, "%test"),
                              t(tStreamEnd, nil)])
    
    test "Lexing: Single Quoted Scalar":
        ensure("'? test - content! '", [t(tLineStart, ""),
                                        t(tScalar, "? test - content! "),
                                        t(tStreamEnd, nil)])
    
    test "Lexing: Single Quoted Scalar (escaped single quote inside)":
        ensure("'test '' content'", [t(tLineStart, ""),
                                     t(tScalar, "test ' content"),
                                     t(tStreamEnd, nil)])
    
    test "Lexing: Doubly Quoted Scalar":
        ensure("\"test content\"", [t(tLineStart, ""),
                                    t(tScalar, "test content"),
                                    t(tStreamEnd, nil)])
    
    test "Lexing: Doubly Quoted Scalar (escaping)":
        ensure(""""\t\\\0\""""", [t(tLineStart, ""),
                                  t(tScalar, "\t\\\0\""),
                                  t(tStreamEnd, nil)])
    
    test "Lexing: Doubly Quoted Scalar (unicode escaping)":
        ensure(""""\x42\u4243\U00424344"""",
               [t(tLineStart, ""),
               t(tScalar, "\x42" & toUTF8(cast[Rune](0x4243)) &
                toUTF8(cast[Rune](0x424344))),
                t(tStreamEnd, nil)])
    
    test "Lexing: Block Array":
        ensure("""
- a
- b""", [t(tLineStart, ""), t(tDash, nil), t(tScalarPart, "a"),
         t(tLineStart, ""), t(tDash, nil), t(tScalarPart, "b"), 
         t(tStreamEnd, nil)])
    
    test "Lexing: Block Map with Implicit Keys":
        ensure("""
foo: bar
herp: derp""", [t(tLineStart, ""), t(tScalarPart, "foo"),
                t(tColon, nil), t(tScalarPart, "bar"),
                t(tLineStart, ""), t(tScalarPart, "herp"),
                t(tColon, nil), t(tScalarPart, "derp"),
                t(tStreamEnd, nil)])
    
    test "Lexing: Block Map with Explicit Keys":
        ensure("""
? foo
: bar""", [t(tLineStart, ""), t(tQuestionmark, nil),
           t(tScalarPart, "foo"), t(tLineStart, ""), t(tColon, nil),
           t(tScalarPart, "bar"), t(tStreamEnd, nil)])
    
    test "Lexing: Indentation":
        ensure("""
foo:
  bar:
    - baz
    - biz
  herp: derp""",
          [t(tLineStart, ""), t(tScalarPart, "foo"), t(tColon, nil),
           t(tLineStart, "  "), t(tScalarPart, "bar"), t(tColon, nil),
           t(tLineStart, "    "), t(tDash, nil), t(tScalarPart, "baz"),
           t(tLineStart, "    "), t(tDash, nil), t(tScalarPart, "biz"),
           t(tLineStart, "  "), t(tScalarPart, "herp"), t(tColon, nil),
           t(tScalarPart, "derp"), t(tStreamEnd, nil)])
   
    test "Lexing: Anchor":
       ensure("foo: &bar", [t(tLineStart, ""), t(tScalarPart, "foo"),
                            t(tColon, nil), t(tAnchor, "bar"),
                            t(tStreamEnd, nil)])
    
    test "Lexing: Alias":
        ensure("foo: *bar", [t(tLineStart, ""), t(tScalarPart, "foo"),
                             t(tColon, nil), t(tAlias, "bar"),
                             t(tStreamEnd, nil)])
    
    test "Lexing: Tag handle":
        ensure("!t!str tagged", [t(tLineStart, ""), t(tTagHandle, "!t!"),
                                 t(tTagSuffix, "str"),
                                 t(tScalarPart, "tagged"),
                                 t(tStreamEnd, nil)])
    
    test "Lexing: Verbatim tag handle":
         ensure("!<tag:http://example.com/str> tagged",
                 [t(tLineStart, ""),
                  t(tVerbatimTag, "tag:http://example.com/str"),
                  t(tScalarPart, "tagged"), t(tStreamEnd, nil)])
    test "Lexing: Type hints":
        ensure("false\nnull\nunknown\n\"string\"\n-13\n42.25\n-4e+3\n5.42e78",
               [t(tLineStart, ""), t(tScalarPart, "false", yTypeBoolean),
                t(tLineStart, ""), t(tScalarPart, "null", yTypeNull),
                t(tLineStart, ""), t(tScalarPart, "unknown", yTypeUnknown),
                t(tLineStart, ""), t(tScalar, "string", yTypeString),
                t(tLineStart, ""), t(tScalarPart, "-13", yTypeInteger),
                t(tLineStart, ""), t(tScalarPart, "42.25", yTypeFloat),
                t(tLineStart, ""), t(tScalarPart, "-4e+3", yTypeFloat),
                t(tLineStart, ""), t(tScalarPart, "5.42e78", yTypeFloat),
                t(tStreamEnd, nil)])