import "../src/yaml/private/lexer"
import streams

import unittest

type BasicLexerEvent = tuple[kind: YamlLexerEventKind, content: string]

template ensure(input: string, expected: openarray[BasicLexerEvent]) =
    var
        i = 0
        lex: YamlLexer
    lex.open(newStringStream(input))
    for token in lex.tokens:
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

proc t(kind: YamlLexerEventKind, content: string): BasicLexerEvent =
    (kind: kind, content: content)

suite "Lexing":
    test "YAML directive":
        ensure("%YAML 1.2", [t(yamlYamlDirective, nil),
                             t(yamlMajorVersion, "1"),
                             t(yamlMinorVersion, "2"),
                             t(yamlStreamEnd, nil)])
    
    test "TAG directive":
        ensure("%TAG !t! tag:http://example.com/",
               [t(yamlTagDirective, nil),
                t(yamlTagHandle, "!t!"),
                t(yamlTagURI, "tag:http://example.com/"),
                t(yamlStreamEnd, nil)])
    
    test "Unknown directive":
        ensure("%FOO bar baz", [t(yamlUnknownDirective, "%FOO"),
                                t(yamlUnknownDirectiveParam, "bar"),
                                t(yamlUnknownDirectiveParam, "baz"),
                                t(yamlStreamEnd, nil)])
    
    test "Comments after directives":
        ensure("%YAML 1.2 # version\n# at line start\n    # indented\n%FOO",
                [t(yamlYamlDirective, nil),
                 t(yamlMajorVersion, "1"),
                 t(yamlMinorVersion, "2"),
                 t(yamlComment, " version"),
                 t(yamlComment, " at line start"),
                 t(yamlComment, " indented"),
                 t(yamlUnknownDirective, "%FOO"),
                 t(yamlStreamEnd, nil)])
    
    test "Directives end":
        ensure("---", [t(yamlDirectivesEnd, nil),
                       t(yamlStreamEnd, nil)])
    
    test "Document end":
        ensure("...", [t(yamlDocumentEnd, nil),
                       t(yamlStreamEnd, nil)])
    
    test "Plain Scalar (alphanumeric)":
        ensure("abA03rel4", [t(yamlLineStart, nil),
                             t(yamlScalar, "abA03rel4"),
                             t(yamlStreamEnd, nil)])
    
    test "Plain Scalar (with spaces)":
        ensure("test content", [t(yamlLineStart, nil),
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
        ensure("'? test - content! '", [t(yamlLineStart, nil),
                                        t(yamlScalar, "? test - content! "),
                                        t(yamlStreamEnd, nil)])
    
    test "Single Quoted Scalar (escaped single quote inside)":
        ensure("'test '' content'", [t(yamlLineStart, nil),
                                     t(yamlScalar, "test ' content"),
                                     t(yamlStreamEnd, nil)])