#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import os, strutils, macros, unittest, sets, algorithm
when not defined(js): import terminal
when (NimMajor, NimMinor) >= (2, 2): import std/staticos
import testEventParser, commonTestUtils
import ../yaml/[ data, parser, stream ]

const
  testSuiteFolder = "yaml-test-suite"

proc echoError(msg: string) =
  when defined(js): echo "[error] ", msg
  else: styledWriteLine(stdout, fgRed, "[error] ", fgWhite, msg, resetStyle)

proc doParserTest(expected, actual: YamlStream, errorExpected: bool): bool =
  var i = 1
  try:
    while true:
      let actualEvent = actual.next()
      let expectedEvent = expected.next()
      if expectedEvent != actualEvent:
        result = errorExpected
        if not result:
          echoError("At event #" & $i &
                    ": Actual events do not match expected events")
          echo ".. expected event:"
          echo "  ", expectedEvent
          echo ".. actual event:"
          echo "  ", actualEvent
          echo ".. difference:"
          when nimvm: discard
          else:
            when not defined(js): stdout.write("  ")
          printDifference(expectedEvent, actualEvent)

        return
      i.inc()
      if actualEvent.kind == yamlEndStream:
        break
    result = not errorExpected
    if not result:
      echo "Expected error, but parsed without error."
  except CatchableError as e:
    result = errorExpected
    if not result:
      echoError("Caught an exception at event #" & $i &
                " test was not successful")
      if e.parent of YamlParserError:
        let pe = (ref YamlParserError)(e.parent)
        echo "line ", pe.mark.line, ", column ", pe.mark.column, ": ", pe.msg
        echo pe.lineContent
      else: echo e.msg

proc parserTest(input, expectedEvents: string, errorExpected : bool): bool =
  # input and expected events are embedded at compile time, since the JS
  # backend cannot read files at runtime.
  var
    parser: YamlParser
  parser.init()
  var
    actual = parser.parse(input)
    expected = parseEventString(expectedEvents)
  result = doParserTest(expected, actual, errorExpected)

# Compile-time file system access for generating the tests.
# std/staticos (Nim 2.2+) works with all backends. On Nim 2.0, os's file system
# procs work at compile time, but are not available when compiling for JS; in
# that case, we fall back to shell commands (requires a POSIX shell).

proc testFileExists(path: string): bool {.compileTime.} =
  when (NimMajor, NimMinor) >= (2, 2): staticos.staticFileExists(path)
  elif not defined(js): fileExists(path)
  else: staticExec("test -e \"" & path & "\" && echo yes").strip == "yes"

proc listDir(dir: string): seq[string] {.compileTime.} =
  ## returns the full paths of all entries in ``dir``, sorted by name.
  when (NimMajor, NimMinor) >= (2, 2):
    for item in staticWalkDir(dir): result.add(item.path)
  elif not defined(js):
    for _, path in walkDir(dir): result.add(path)
  else:
    # only output file names, which we join with ``dir`` ourselves, so that
    # this does not depend on how the shell formats paths.
    for name in staticExec("ls -1 \"" & dir & "\"").splitLines():
      if name.strip.len > 0: result.add(dir / name.strip)
  result.sort()

macro genTests(): untyped =
  let suitePath = currentSourcePath().parentDir / testSuiteFolder
  echo "[tparser] Generating tests from " & suitePath

  var ignored = toHashSet([".git", "name", "tags", "meta"])

  proc genTest(target: var NimNode, dirPath: string, testId: string) {.compileTime.} =
    let title = slurp(dirPath / "===")
    let isErrorTest = testFileExists(dirPath / "error")
    let testName = strip(title) & " [" & testId & ']'

    # TODO: this code executes the test at compile time.
    # sadly it doesn't work currently since the VM doesn't support
    # closure iterators (in parseEventStream).
    #
    #let staticIn = slurp(dirPath / "in.yaml")
    #let staticExpected = slurp(dirPath / "test.event")
    #var parser: YamlParser
    #parser.init()
    #var actual = parser.parse(staticIn)
    #var expected = parseEventString(staticExpected)
    #
    #if not doParserTest(expected, actual, isErrorTest):
    # target.add(newCall("test", newLit(testName & " [comptime]"), newCall("fail")))

    let
      input = slurp(dirPath / "in.yaml")
      expectedEvents = slurp(dirPath / "test.event")
    target.add(newCall("test",
        newLit(testName), newCall("doAssert", newCall("parserTest",
        newLit(input), newLit(expectedEvents), newLit(isErrorTest)))))

  result = newStmtList()

  for dirPath in listDir(suitePath):
    let testId = dirPath.extractFilename
    if ignored.contains(testId): continue
    if testFileExists(dirPath / "==="):
      genTest(result, dirPath, testId)
    else:
      for itemPath in listDir(dirPath):
        let testItemId = testId & "/" & itemPath.extractFilename
        if testFileExists(itemPath / "==="):
          genTest(result, itemPath, testItemId)


  result = newCall("suite", newLit("Parser Tests (from yaml-test-suite)"), result)

genTests()

proc nestingDepth(input: string, maxDepth: Natural): int =
  ## Parses ``input`` and returns the maximum nesting depth of its
  ## collections. Raises the YamlParserError if the parser fails.
  let parser = initYamlParser(maxDepth = maxDepth)
  var
    events = parser.parse(input)
    depth = 0
  try:
    for event in events:
      case event.kind
      of yamlStartMap, yamlStartSeq:
        inc(depth)
        result = max(result, depth)
      of yamlEndMap, yamlEndSeq: dec(depth)
      else: discard
  except YamlStreamError as e:
    raise (ref YamlParserError)(e.parent)

proc flowSeqs(n: int): string = "[".repeat(n) & "]".repeat(n)

suite "Nesting depth":
  test "Default limit":
    check nestingDepth(flowSeqs(defaultMaxDepth), defaultMaxDepth) == defaultMaxDepth
    expect YamlParserError:
      discard nestingDepth(flowSeqs(defaultMaxDepth + 1), defaultMaxDepth)

  test "Error position":
    try:
      discard nestingDepth("[[[a]]]", 2)
      fail()
    except YamlParserError as e:
      check e.mark.line == 1
      check e.mark.column == 3

  test "Flow mappings":
    let input = "{a: ".repeat(10) & "b" & "}".repeat(10)
    check nestingDepth(input, 10) == 10
    expect YamlParserError:
      discard nestingDepth(input, 9)

  test "Block collections":
    var input = ""
    for i in 0..<10: input.add(" ".repeat(i * 2) & "- a:\n")
    check nestingDepth(input, 20) == 20
    expect YamlParserError:
      discard nestingDepth(input, 19)

  test "Implicit pairs in flow sequences":
    # each level is a sequence containing a pair whose key is the next level
    let input = "[".repeat(10) & "a" & "]: b".repeat(9) & "]"
    check nestingDepth(input, 19) == 19
    expect YamlParserError:
      discard nestingDepth(input, 18)

  test "Flow collection as implicit block key":
    let input = flowSeqs(10) & ": a"
    check nestingDepth(input, 11) == 11
    expect YamlParserError:
      discard nestingDepth(input, 10)

  test "Disabled limit":
    # the parser does not recurse, so deep input works without the limit
    check nestingDepth(flowSeqs(100_000), 0) == 100_000
