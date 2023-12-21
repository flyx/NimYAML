task build, "Compile the YAML module into a library":
  --app:lib
  --d:release
  setCommand "c", "yaml"

task test, "Run all tests":
  --r
  --verbosity:0
  setCommand "c", "test/tnimregress"

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

task nativeTests, "Run native value tests":
  --r
  --verbosity:0
  setCommand "c", "test/tnative"

task quickstartTests, "Run quickstart tests":
  --r
  --verbosity:0
  setCommand "c", "test/tquickstart"

task hintsTests, "Run hints tests":
  --r
  --verbosity:0
  setCommand "c", "test/thints"

task presenterTests, "Run presenter tests":
  --r
  --verbosity:0
  setCommand "c", "test/tpresenter"

task bench, "Benchmarking":
  --r
  --w:off
  --hints:off
  --d:release
  setCommand "c", "bench/bench"

task clean, "Remove all generated files":
  exec "rm -rf libyaml.* test/tests test/parsing test/lexing bench/json docout"
  setCommand "nop"

task testSuiteEvents, "Compile the testSuiteEvents tool":
  --d:release
  setCommand "c", "tools/testSuiteEvents"
