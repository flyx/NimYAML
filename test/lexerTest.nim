import "../src/yaml/private/lexer"
import streams

var l: YamlLexer

l.open(newStringStream("""%YAML 1.2
%TAG !e! tag:http://flyx.org/etags/
foo1:
   foo2: [
     !!str bar1,
     !foo 'bar''2'
   ]
!<tag:http://flyx.org/tags> mimi: "mi"
"""))

for token in l.tokens:
    echo "(", token.kind, ": ", token.content, ") "