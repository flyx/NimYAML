import "../src/yaml/private/lexer"
import streams, unicode

import unittest

type BasicLexerToken = tuple[kind: YamlLexerToken, content: string,
                             typeHint: YamlLexerTypeHint]

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
            if token == yamlError:
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
        if token == yamlScalarPart:
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
        typeHint: YamlLexerTypeHint = yTypeString): BasicLexerToken =
    (kind: kind, content: content, typeHint: typeHint)

suite "Lexing":
    test "Lexing: YAML Directive":
        ensure("%YAML 1.2", [t(yamlYamlDirective, nil),
                             t(yamlVersionPart, "1"),
                             t(yamlVersionPart, "2"),
                             t(yamlStreamEnd, nil)])
    
    test "Lexing: TAG Directive":
        ensure("%TAG !t! tag:http://example.com/",
               [t(yamlTagDirective, nil),
                t(yamlTagHandle, "!t!"),
                t(yamlTagURI, "tag:http://example.com/"),
                t(yamlStreamEnd, nil)])
    
    test "Lexing: Unknown Directive":
        ensure("%FOO bar baz", [t(yamlUnknownDirective, "%FOO"),
                                t(yamlUnknownDirectiveParam, "bar"),
                                t(yamlUnknownDirectiveParam, "baz"),
                                t(yamlStreamEnd, nil)])
    
    test "Lexing: Comments after Directives":
        ensure("%YAML 1.2 # version\n# at line start\n    # indented\n%FOO",
                [t(yamlYamlDirective, nil),
                 t(yamlVersionPart, "1"),
                 t(yamlVersionPart, "2"),
                 t(yamlComment, " version"),
                 t(yamlComment, " at line start"),
                 t(yamlComment, " indented"),
                 t(yamlUnknownDirective, "%FOO"),
                 t(yamlStreamEnd, nil)])
    
    test "Lexing: Directives End":
        ensure("---", [t(yamlDirectivesEnd, nil),
                       t(yamlStreamEnd, nil)])
    
    test "Lexing: Document End":
        ensure("...", [t(yamlLineStart, nil),
                       t(yamlDocumentEnd, nil),
                       t(yamlStreamEnd, nil)])
    
    test "Lexing: Directive after Document End":
        ensure("content\n...\n%YAML 1.2",
                [t(yamlLineStart, ""),
                 t(yamlScalarPart, "content"),
                 t(yamlLineStart, ""),
                 t(yamlDocumentEnd, nil),
                 t(yamlYamlDirective, nil),
                 t(yamlVersionPart, "1"),
                 t(yamlVersionPart, "2"),
                 t(yamlStreamEnd, nil)])
    
    test "Lexing: Plain Scalar (alphanumeric)":
        ensure("abA03rel4", [t(yamlLineStart, ""),
                             t(yamlScalarPart, "abA03rel4"),
                             t(yamlStreamEnd, nil)])
    
    test "Lexing: Plain Scalar (with spaces)":
        ensure("test content", [t(yamlLineStart, ""),
                                t(yamlScalarPart, "test content"),
                                t(yamlStreamEnd, nil)])
    
    test "Lexing: Plain Scalar (with special chars)":
        ensure(":test ?content -with #special !chars",
               [t(yamlLineStart, nil),
                t(yamlScalarPart, ":test ?content -with #special !chars"),
                t(yamlStreamEnd, nil)])
    
    test "Lexing: Plain Scalar (starting with %)":
        ensure("---\n%test", [t(yamlDirectivesEnd, nil),
                              t(yamlLineStart, ""),
                              t(yamlScalarPart, "%test"),
                              t(yamlStreamEnd, nil)])
    
    test "Lexing: Single Quoted Scalar":
        ensure("'? test - content! '", [t(yamlLineStart, ""),
                                        t(yamlScalar, "? test - content! "),
                                        t(yamlStreamEnd, nil)])
    
    test "Lexing: Single Quoted Scalar (escaped single quote inside)":
        ensure("'test '' content'", [t(yamlLineStart, ""),
                                     t(yamlScalar, "test ' content"),
                                     t(yamlStreamEnd, nil)])
    
    test "Lexing: Doubly Quoted Scalar":
        ensure("\"test content\"", [t(yamlLineStart, ""),
                                    t(yamlScalar, "test content"),
                                    t(yamlStreamEnd, nil)])
    
    test "Lexing: Doubly Quoted Scalar (escaping)":
        ensure(""""\t\\\0\""""", [t(yamlLineStart, ""),
                                  t(yamlScalar, "\t\\\0\""),
                                  t(yamlStreamEnd, nil)])
    
    test "Lexing: Doubly Quoted Scalar (unicode escaping)":
        ensure(""""\x42\u4243\U00424344"""",
               [t(yamlLineStart, ""),
               t(yamlScalar, "\x42" & toUTF8(cast[Rune](0x4243)) &
                toUTF8(cast[Rune](0x424344))),
                t(yamlStreamEnd, nil)])
    
    test "Lexing: Block Array":
        ensure("""
- a
- b""", [t(yamlLineStart, ""), t(yamlDash, nil), t(yamlScalarPart, "a"),
         t(yamlLineStart, ""), t(yamlDash, nil), t(yamlScalarPart, "b"), 
         t(yamlStreamEnd, nil)])
    
    test "Lexing: Block Map with Implicit Keys":
        ensure("""
foo: bar
herp: derp""", [t(yamlLineStart, ""), t(yamlScalarPart, "foo"),
                t(yamlColon, nil), t(yamlScalarPart, "bar"),
                t(yamlLineStart, ""), t(yamlScalarPart, "herp"),
                t(yamlColon, nil), t(yamlScalarPart, "derp"),
                t(yamlStreamEnd, nil)])
    
    test "Lexing: Block Map with Explicit Keys":
        ensure("""
? foo
: bar""", [t(yamlLineStart, ""), t(yamlQuestionmark, nil),
           t(yamlScalarPart, "foo"), t(yamlLineStart, ""), t(yamlColon, nil),
           t(yamlScalarPart, "bar"), t(yamlStreamEnd, nil)])
    
    test "Lexing: Indentation":
        ensure("""
foo:
  bar:
    - baz
    - biz
  herp: derp""",
          [t(yamlLineStart, ""), t(yamlScalarPart, "foo"), t(yamlColon, nil),
           t(yamlLineStart, "  "), t(yamlScalarPart, "bar"), t(yamlColon, nil),
           t(yamlLineStart, "    "), t(yamlDash, nil), t(yamlScalarPart, "baz"),
           t(yamlLineStart, "    "), t(yamlDash, nil), t(yamlScalarPart, "biz"),
           t(yamlLineStart, "  "), t(yamlScalarPart, "herp"), t(yamlColon, nil),
           t(yamlScalarPart, "derp"), t(yamlStreamEnd, nil)])
   
    test "Lexing: Anchor":
       ensure("foo: &bar", [t(yamlLineStart, ""), t(yamlScalarPart, "foo"),
                            t(yamlColon, nil), t(yamlAnchor, "bar"),
                            t(yamlStreamEnd, nil)])
    
    test "Lexing: Alias":
        ensure("foo: *bar", [t(yamlLineStart, ""), t(yamlScalarPart, "foo"),
                             t(yamlColon, nil), t(yamlAlias, "bar"),
                             t(yamlStreamEnd, nil)])
    
    test "Lexing: Tag handle":
        ensure("!t!str tagged", [t(yamlLineStart, ""), t(yamlTagHandle, "!t!"),
                                 t(yamlTagSuffix, "str"),
                                 t(yamlScalarPart, "tagged"),
                                 t(yamlStreamEnd, nil)])
    
    test "Lexing: Verbatim tag handle":
         ensure("!<tag:http://example.com/str> tagged",
                 [t(yamlLineStart, ""),
                  t(yamlVerbatimTag, "tag:http://example.com/str"),
                  t(yamlScalarPart, "tagged"), t(yamlStreamEnd, nil)])
    test "Lexing: Type hints":
        ensure("false\nnull\nstring\n-13\n42.25\n-4e+3\n5.42e78",
               [t(yamlLineStart, ""), t(yamlScalarPart, "false", yTypeBoolean),
                t(yamlLineStart, ""), t(yamlScalarPart, "null", yTypeNull),
                t(yamlLineStart, ""), t(yamlScalarPart, "string", yTypeString),
                t(yamlLineStart, ""), t(yamlScalarPart, "-13", yTypeInteger),
                t(yamlLineStart, ""), t(yamlScalarPart, "42.25", yTypeFloat),
                t(yamlLineStart, ""), t(yamlScalarPart, "-4e+3", yTypeFloat),
                t(yamlLineStart, ""), t(yamlScalarPart, "5.42e78", yTypeFloat),
                t(yamlStreamEnd, nil)])