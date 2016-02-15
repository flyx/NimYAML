task build, "Compile the YAML module into a library":
    --app:lib
    --d:release
    setCommand "c", "yaml"

task tests, "Run all tests":
    --r
    --verbosity:0
    setCommand "c", "test/tests"

task parserTests, "Run parser tests":
    --r
    --verbosity:0
    setCommand "c", "test/parsing"

task serializationTests, "Run serialization tests":
    --r
    --verbosity:0
    setCommand "c", "test/serializing"

task documentation, "Generate documentation":
    exec "mkdir -p docout"
    exec r"nim doc2 -o:docout/yaml.html --docSeeSrcUrl:https://github.com/flyx/NimYAML/blob/`git log -n 1 --format=%H` yaml"
    exec r"nim rst2html -o:docout/index.html doc/index.txt"
    exec r"nim rst2html -o:docout/api.html doc/api.txt"
    exec "cp doc/docutils.css doc/style.css doc/testing.html doc/processing.svg docout"
    setCommand "nop"

task bench, "Benchmarking":
    --d:release
    --r
    --w:off
    --hints:off
    setCommand "c", "bench/json"

task clean, "Remove all generated files":
    exec "rm -f libyaml.* test/tests test/parsing test/lexing docout"
    setCommand "nop"

task server, "Compile server daemon":
    --d:release
    setCommand "c", "server/server"