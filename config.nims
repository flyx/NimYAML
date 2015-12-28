task build, "Compile the YAML module into a library":
    --app:lib
    --d:release
    setCommand "c", "yaml"

task tests, "Run all tests":
    --r
    --verbosity:0
    setCommand "c", "test/tests"

task lexerTests, "Run lexer tests":
    --r
    --verbosity:0
    setCommand "c", "test/lexing"

task parserTests, "Run parser tests":
    --r
    --verbosity:0
    setCommand "c", "test/parsing"
    
task doc, "Generate documentation":
    setCommand "doc2", "yaml"

task bench, "Benchmarking":
    --d:release
    --r
    setCommand "c", "bench/json"

task clean, "Remove all generated files":
    exec "rm -f yaml.html libyaml.* test/tests test/parsing test/lexing"
    setCommand "nop"