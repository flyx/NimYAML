#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import os, terminal, strutils, streams, macros, unittest, sets
import testEventParser, commonTestUtils
import ../yaml/[ data, parser, stream ]

const
  testSuiteFolder = "yaml-test-suite"

proc echoError(msg: string) =
  styledWriteLine(stdout, fgRed, "[error] ", fgWhite, msg, resetStyle)

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
          else: stdout.write("  ")
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

proc parserTest(path: string, errorExpected : bool): bool =
  var
    parser: YamlParser
  parser.init()
  var
    actualIn = newFileStream(path / "in.yaml")
    actual = parser.parse(actualIn)
    expectedIn = newFileStream(path / "test.event")
    expected = parseEventStream(expectedIn)
  defer:
    actualIn.close()
    expectedIn.close()
  result = doParserTest(expected, actual, errorExpected)

macro genTests(): untyped =
  let
    pwd = staticExec("pwd").strip
    absolutePath = '"' & (pwd / testSuiteFolder) & '"'
  echo "[tparser] Generating tests from " & absolutePath
  discard staticExec("git submodule init && git submodule update --remote")

  var ignored = toHashSet([".git", "name", "tags", "meta"])
  
  proc genTest(target: var NimNode, dirPath: string, testId: string) {.compileTime.} =
    let title = slurp(dirPath / "===")
    let isErrorTest = fileExists(dirPath / "error")
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
    
    target.add(newCall("test",
        newLit(testName), newCall("doAssert", newCall("parserTest",
        newLit(dirPath), newLit(isErrorTest)))))
  
  result = newStmtList()
  
  # walkDir for some crude reason does not work with travis build
  let dirItems = staticExec("ls -1d " & absolutePath / "*")
  for dirPath in dirItems.splitLines():
    if dirPath.strip.len == 0: continue
    let testId = dirPath[^4..^1]
    if ignored.contains(testId): continue
    if fileExists(dirPath / "==="):
      genTest(result, dirPath, testId)
    else:
      let testItems = staticExec("ls -1d " & dirPath / "*")
      var start = len(dirPath) + 1
      for itemPath in testItems.splitLines():
        if itemPath.strip.len == 0: continue
        let testItemId = testId / itemPath[start..^1]
        if fileExists(itemPath / "==="):
          genTest(result, itemPath, testItemId)
        
    
  result = newCall("suite", newLit("Parser Tests (from yaml-test-suite)"), result)

genTests()
