#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import os, osproc, terminal, strutils, streams, macros, unittest, sets
import testEventParser, commonTestUtils
import "../yaml"

const
  testSuiteFolder = "yaml-test-suite"

proc echoError(msg: string) =
  styledWriteLine(stdout, fgRed, "[error] ", fgWhite, msg, resetStyle)


proc parserTest(path: string, errorExpected : bool): bool =
  var
    tagLib = initExtendedTagLibrary()
    parser = newYamlParser(tagLib)
    actualIn = newFileStream(path / "in.yaml")
    actual = parser.parse(actualIn)
    expectedIn = newFileStream(path / "test.event")
    expected = parseEventStream(expectedIn, tagLib)
  defer:
    actualIn.close()
    expectedIn.close()
  var i = 1
  try:
    while not actual.finished():
      let actualEvent = actual.next()
      if expected.finished():
        result = errorExpected
        if not result:
          echoError("At token #" & $i & ": Expected stream end, got " &
                    $actualEvent.kind)
        return
      let expectedEvent = expected.next()
      if expectedEvent != actualEvent:
        result = errorExpected
        if not result:
          printDifference(expectedEvent, actualEvent)
          echoError("At token #" & $i &
                    ": Actual tokens do not match expected tokens")
        return
      i.inc()
    if not expected.finished():
      result = errorExpected
      if not result:
        echoError("Got fewer tokens than expected, first missing " &
                  "token: " & $expected.next().kind)
      return
    result = not errorExpected
    if not result:
      echo "Expected error, but parsed without error."
  except:
    result = errorExpected
    if not result:
      let e = getCurrentException()
      if e.parent of YamlParserError:
        let pe = (ref YamlParserError)(e.parent)
        echo "line ", pe.line, ", column ", pe.column, ": ", pe.msg
        echo pe.lineContent
      else: echo e.msg
      echoError("Catched an exception at token #" & $i &
                " test was not successful")

macro genTests(): untyped =
  let
    pwd = staticExec("pwd").strip
    absolutePath = '"' & (pwd / testSuiteFolder) & '"'
  echo "[tparser] Generating tests from " & absolutePath
  discard staticExec("git submodule init && git submodule update --remote")

  let errorTests = toSet(staticExec("cd " & (absolutePath / "tags" / "error") &
                         " && ls -1d *").splitLines())
  let ignored = toSet(["3MYT", "JDH8", ".git", "name", "tags", "meta"])

  result = newStmtList()
  # walkDir for some crude reason does not work with travis build
  let dirItems = staticExec("ls -1d " & absolutePath / "*")
  for dirPath in dirItems.splitLines():
    if dirPath.strip.len == 0: continue
    let testId = dirPath[^4..^1]
    if ignored.contains(testId): continue
    let title = slurp(dirPath / "===")

    result.add(newCall("test",
        newLit(strip(title) & " [" &
        testId & ']'), newCall("doAssert", newCall("parserTest",
        newLit(dirPath), newLit(errorTests.contains(testId))))))
  result = newCall("suite", newLit("Parser Tests (from yaml-test-suite)"), result)

genTests()
