proc compileCommand(file: string) =
  setCommand "c", file
  # Nim 2.2.14+ spawns a separate codegen process by default, which parses the
  # raw command line and fails when a task switches commands via setCommand.
  # This must come after setCommand, which re-enables spawnCodegen.
  when (NimMajor, NimMinor, NimPatch) >= (2, 2, 14):
    switch("spawnCodegen", "off")

task build, "Compile the YAML module into a library":
  --app:lib
  --d:release
  compileCommand "yaml"

task test, "Run all tests":
  --r
  --verbosity:0
  compileCommand "test/tests"

task lexerTests, "Run lexer tests":
  --r
  --verbosity:0
  compileCommand "test/tlex"

task parserTests, "Run parser tests":
  --r
  --verbosity:0
  compileCommand "test/tparser"

task jsonTests, "Run JSON tests":
  --r
  --verbosity:0
  compileCommand "test/tjson"

task domTests, "Run DOM tests":
  --r
  --verbosity:0
  compileCommand "test/tdom"

task nativeTests, "Run native value tests":
  --r
  --verbosity:0
  compileCommand "test/tnative"

task quickstartTests, "Run quickstart tests":
  --r
  --verbosity:0
  compileCommand "test/tquickstart"

task hintsTests, "Run hints tests":
  --r
  --verbosity:0
  compileCommand "test/thints"

task presenterTests, "Run presenter tests":
  --r
  --verbosity:0
  compileCommand "test/tpresenter"

task annotationTests, "Run annotation tests":
  --r
  --verbosity:0
  compileCommand "test/tannotations"

task bench, "Benchmarking":
  --r
  --w:off
  --hints:off
  --d:release
  compileCommand "bench/bench"

task clean, "Remove all generated files":
  exec "rm -rf libyaml.* test/tests test/parsing test/lexing bench/json docout"
  setCommand "nop"

task testSuiteEvents, "Compile the testSuiteEvents tool":
  --d:release
  compileCommand "tools/testSuiteEvents"
