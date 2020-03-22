task build, "Compile the YAML module into a library":
  --app:lib
  --d:release
  setCommand "c", "yaml"

task test, "Run all tests":
  --r
  --verbosity:0
  setCommand "c", "test/tests"

task lexerTests, "Run lexer tests":
  --r
  --verbosity:0
  setCommand "c", "test/tlex"

task parserTests, "Run parser tests":
  --r
  --verbosity:0
  setCommand "c", "test/tparser"

task jsonTests, "Run JSON tests":
  --r
  --verbosity:0
  setCommand "c", "test/tjson"

task domTests, "Run DOM tests":
  --r
  --verbosity:0
  setCommand "c", "test/tdom"

task serializationTests, "Run serialization tests":
  --r
  --verbosity:0
  setCommand "c", "test/tserialization"

task quickstartTests, "Run quickstart tests":
  --r
  --verbosity:0
  setCommand "c", "test/tquickstart"

task documentation, "Generate documentation":
  exec "mkdir -p docout"
  withDir "doc":
    exec r"nim c rstPreproc"
    exec r"./rstPreproc -o:tmp.rst index.txt"
    exec r"nim rst2html -o:../docout/index.html tmp.rst"
    exec r"./rstPreproc -o:tmp.rst api.txt"
    exec r"nim rst2html -o:../docout/api.html tmp.rst"
    exec r"./rstPreproc -o:tmp.rst serialization.txt"
    exec r"nim rst2html -o:../docout/serialization.html tmp.rst"
    exec r"nim rst2html -o:../docout/testing.html testing.rst"
    exec r"nim rst2html -o:../docout/schema.html schema.rst"
    exec "cp docutils.css style.css processing.svg ../docout"
  exec r"nim doc2 -o:docout/yaml.html --docSeeSrcUrl:https://github.com/flyx/NimYAML/blob/`git log -n 1 --format=%H` yaml"
  for file in listFiles("yaml"):
    let packageName = file[5..^5]
    exec r"nim doc2 -o:docout/yaml." & packageName &
        ".html --docSeeSrcUrl:https://github.com/flyx/NimYAML/blob/yaml/`git log -n 1 --format=%H` " &
        file
  setCommand "nop"

task bench, "Benchmarking":
  --r
  --w:off
  --hints:off
  --d:release
  setCommand "c", "bench/bench"

task clean, "Remove all generated files":
  exec "rm -rf libyaml.* test/tests test/parsing test/lexing bench/json docout"
  setCommand "nop"

task server, "Compile server daemon":
  --d:release
  --d:yamlScalarRepInd
  setCommand "c", "server/server"

task testSuiteEvents, "Compile the testSuiteEvents tool":
  --d:release
  setCommand "c", "tools/testSuiteEvents"
