import std/[os, strutils]

proc compileCommand(file: string, backend = "c") =
  setCommand backend, file
  # Nim 2.2.14+ spawns a separate codegen process by default, which parses the
  # raw command line and fails when a task switches commands via setCommand.
  # This must come after setCommand, which re-enables spawnCodegen.
  when (NimMajor, NimMinor, NimPatch) >= (2, 2, 14):
    switch("spawnCodegen", "off")
  if backend == "js":
    # Nim's global config enables threads, which is ignored when the JS backend
    # is known up front (`nim js`), but not when a task switches to it. The
    # threads switch is ignored after that, but `backend:js` disables threads.
    switch("backend", "js")

const
  # tests that cannot run on the JS backend.
  # tquickstart compiles and runs the documentation examples as native
  # executables.
  nativeOnlyTests = ["tquickstart"]

proc selectedTest(): string =
  ## Returns the test given as argument after the task name
  ## (e.g. ``tlex`` in ``nim test tlex``), or "" if none was given.
  var sawTask = false
  for i in 1..paramCount():
    let p = paramStr(i)
    if p.len == 0 or p[0] == '-': continue
    if sawTask: return p
    sawTask = true
  return ""

proc runTests(backend: string) =
  --r
  --verbosity:0
  let name = selectedTest()
  if name.len == 0:
    # tests.nim imports all tests, except native-only ones on JS
    compileCommand "test/tests", backend
    return
  if not fileExists("test/" & name & ".nim") or name in ["tests"]:
    var available: seq[string]
    for f in listFiles("test"):
      let (_, n, ext) = splitFile(f)
      if ext == ".nim" and n.len > 1 and n[0] == 't' and n != "tests" and
          not n.startsWith("test"):
        available.add(n)
    quit "Unknown test: " & name & "\nAvailable tests: " & available.join(", ")
  if backend == "js" and name in nativeOnlyTests:
    quit "Test " & name & " cannot run with the JS backend"
  compileCommand "test/" & name, backend

task build, "Compile the YAML module into a library":
  --app:lib
  --d:release
  compileCommand "yaml"

task test, "Run all tests with the C backend, or a single one (e.g. `nim test tlex`)":
  runTests("c")

task testJS, "Run all tests with the JS backend, or a single one (e.g. `nim testJS tlex`)":
  runTests("js")

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
