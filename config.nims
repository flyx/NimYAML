task build, "Compile the YAML module into a library":
    exec "nim c --app:lib -d:release yaml"
    setCommand "nop"

task tests, "Run all tests":
    exec "nim c -r --verbosity:0 test/tests"
    setCommand "nop"

task lexerTests, "Run lexer tests":
    exec "nim c -r --verbosity:0 test/lexing"
    setCommand "nop"

task parserTests, "Run parser tests":
    exec "nim c --verbosity:0 -r test/parsing"
    setCommand "nop"
