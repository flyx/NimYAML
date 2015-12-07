import "../src/yaml/private/lexer"
import streams, unicode

import unittest

type BasicLexerToken = tuple[kind: YamlLexerTokenKind, content: string]

template ensure(input: string, expected: openarray[BasicLexerToken]) =
    var
        i = 0
        lex: YamlLexer
    lex.open(newStringStream(input))
    for token in lex.tokens:
        if i >= expected.len:
            echo "received more tokens than expected (next token = ",
                 token.kind, ")"
            fail()
            break
        if token.kind != expected[i].kind:
            if token.kind == yamlError:
                echo "got lexer error: " & lex.content
            else:
                echo "wrong token kind (expected ", expected[i].kind, ", got ",
                     token.kind, ")"
            fail()
            break
        if not isNil(expected[i].content):
            if lex.content != expected[i].content:
                echo "wrong token content (", token.kind, ": expected \"",
                     expected[i].content, "\", got \"", lex.content, "\")"
                fail()
                break
        inc(i)
    if i < expected.len:
        echo "received less tokens than expected (first missing = ",
             expected[i].kind, ")"

proc t(kind: YamlLexerTokenKind, content: string): BasicLexerToken =
    (kind: kind, content: content)

suite "Lexing":
    test "YAML Directive":
        ensure("%YAML 1.2", [t(yamlYamlDirective, nil),
                             t(yamlVersionPart, "1"),
                             t(yamlVersionPart, "2"),
                             t(yamlStreamEnd, nil)])
    
    test "TAG Directive":
        ensure("%TAG !t! tag:http://example.com/",
               [t(yamlTagDirective, nil),
                t(yamlTagHandle, "!t!"),
                t(yamlTagURI, "tag:http://example.com/"),
                t(yamlStreamEnd, nil)])
    
    test "Unknown Directive":
        ensure("%FOO bar baz", [t(yamlUnknownDirective, "%FOO"),
                                t(yamlUnknownDirectiveParam, "bar"),
                                t(yamlUnknownDirectiveParam, "baz"),
                                t(yamlStreamEnd, nil)])
    
    test "Comments after Directives":
        ensure("%YAML 1.2 # version\n# at line start\n    # indented\n%FOO",
                [t(yamlYamlDirective, nil),
                 t(yamlVersionPart, "1"),
                 t(yamlVersionPart, "2"),
                 t(yamlComment, " version"),
                 t(yamlComment, " at line start"),
                 t(yamlComment, " indented"),
                 t(yamlUnknownDirective, "%FOO"),
                 t(yamlStreamEnd, nil)])
    
    test "Directives End":
        ensure("---", [t(yamlDirectivesEnd, nil),
                       t(yamlStreamEnd, nil)])
    
    test "Document End":
        ensure("...", [t(yamlLineStart, nil),
                       t(yamlDocumentEnd, nil),
                       t(yamlStreamEnd, nil)])
    
    test "Directive after Document End":
        ensure("content\n...\n%YAML 1.2",
                [t(yamlLineStart, ""),
                 t(yamlScalar, "content"),
                 t(yamlLineStart, ""),
                 t(yamlDocumentEnd, nil),
                 t(yamlYamlDirective, nil),
                 t(yamlVersionPart, "1"),
                 t(yamlVersionPart, "2"),
                 t(yamlStreamEnd, nil)])
    
    test "Plain Scalar (alphanumeric)":
        ensure("abA03rel4", [t(yamlLineStart, ""),
                             t(yamlScalar, "abA03rel4"),
                             t(yamlStreamEnd, nil)])
    
    test "Plain Scalar (with spaces)":
        ensure("test content", [t(yamlLineStart, ""),
                                t(yamlScalar, "test content"),
                                t(yamlStreamEnd, nil)])
    
    test "Plain Scalar (with special chars)":
        ensure(":test ?content -with #special !chars",
               [t(yamlLineStart, nil),
                t(yamlScalar, ":test ?content -with #special !chars"),
                t(yamlStreamEnd, nil)])
    
    test "Plain Scalar (starting with %)":
        ensure("---\n%test", [t(yamlDirectivesEnd, nil),
                              t(yamlLineStart, ""),
                              t(yamlScalar, "%test"),
                              t(yamlStreamEnd, nil)])
    
    test "Single Quoted Scalar":
        ensure("'? test - content! '", [t(yamlLineStart, ""),
                                        t(yamlScalar, "? test - content! "),
                                        t(yamlStreamEnd, nil)])
    
    test "Single Quoted Scalar (escaped single quote inside)":
        ensure("'test '' content'", [t(yamlLineStart, ""),
                                     t(yamlScalar, "test ' content"),
                                     t(yamlStreamEnd, nil)])
    
    test "Doubly Quoted Scalar":
        ensure("\"test content\"", [t(yamlLineStart, ""),
                                    t(yamlScalar, "test content"),
                                    t(yamlStreamEnd, nil)])
    
    test "Doubly Quoted Scalar (escaping)":
        ensure(""""\t\\\0\""""", [t(yamlLineStart, ""),
                                  t(yamlScalar, "\t\\\0\""),
                                  t(yamlStreamEnd, nil)])
    
    test "Doubly Quoted Scalar (unicode escaping)":
        ensure(""""\x42\u4243\U00424344"""",
               [t(yamlLineStart, ""),
               t(yamlScalar, "\x42" & toUTF8(cast[Rune](0x4243)) &
                toUTF8(cast[Rune](0x424344))),
                t(yamlStreamEnd, nil)])
    
    test "Block Array":
        ensure("""
- a
- b""", [t(yamlLineStart, ""), t(yamlDash, nil), t(yamlScalar, "a"),
         t(yamlLineStart, ""), t(yamlDash, nil), t(yamlScalar, "b"), 
         t(yamlStreamEnd, nil)])
    
    test "Block Map with Implicit Keys":
        ensure("""
foo: bar
herp: derp""", [t(yamlLineStart, ""), t(yamlScalar, "foo"), t(yamlColon, nil),
                t(yamlScalar, "bar"), t(yamlLineStart, ""),
                t(yamlScalar, "herp"), t(yamlColon, nil), t(yamlScalar, "derp"),
                t(yamlStreamEnd, nil)])
    
    test "Block Map with Explicit Keys":
        ensure("""
? foo
: bar""", [t(yamlLineStart, ""), t(yamlQuestionmark, nil), t(yamlScalar, "foo"),
           t(yamlLineStart, ""), t(yamlColon, nil), t(yamlScalar, "bar"),
           t(yamlStreamEnd, nil)])
    
    test "Indentation":
        ensure("""
foo:
  bar:
    - baz
    - biz
  herp: derp""",
          [t(yamlLineStart, ""), t(yamlScalar, "foo"), t(yamlColon, nil),
           t(yamlLineStart, "  "), t(yamlScalar, "bar"), t(yamlColon, nil),
           t(yamlLineStart, "    "), t(yamlDash, nil), t(yamlScalar, "baz"),
           t(yamlLineStart, "    "), t(yamlDash, nil), t(yamlScalar, "biz"),
           t(yamlLineStart, "  "), t(yamlScalar, "herp"), t(yamlColon, nil),
           t(yamlScalar, "derp"), t(yamlStreamEnd, nil)])
   
    test "Anchor":
       ensure("foo: &bar", [t(yamlLineStart, ""), t(yamlScalar, "foo"),
                            t(yamlColon, nil), t(yamlAnchor, "bar"),
                            t(yamlStreamEnd, nil)])
    
    test "Alias":
        ensure("foo: *bar", [t(yamlLineStart, ""), t(yamlScalar, "foo"),
                             t(yamlColon, nil), t(yamlAlias, "bar"),
                             t(yamlStreamEnd, nil)])
    
    test "Tag handle":
        ensure("!t!str tagged", [t(yamlLineStart, ""), t(yamlTagHandle, "!t!"),
                                 t(yamlTagSuffix, "str"),
                                t(yamlScalar, "tagged"), t(yamlStreamEnd, nil)])
    
    test "Verbatim tag handle":
         ensure("!<tag:http://example.com/str> tagged",
                 [t(yamlLineStart, ""),
                  t(yamlVerbatimTag, "tag:http://example.com/str"),
                  t(yamlScalar, "tagged"), t(yamlStreamEnd, nil)])