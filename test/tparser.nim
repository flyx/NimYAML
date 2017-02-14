#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import os, osproc, terminal, strutils, streams, macros, unittest
import testEventParser, commonTestUtils
import "../yaml"

const
  testSuiteFolder = "yaml-test-suite"
  testSuiteUrl = "https://github.com/yaml/yaml-test-suite.git"

proc echoError(msg: string) =
  styledWriteLine(stdout, fgRed, "[error] ", fgWhite, msg, resetStyle)

proc ensureTestSuiteCloneCorrect(pwd: string) {.compileTime.} =
  let absolutePath = pwd / testSuiteFolder
  if dirExists(absolutePath):
    var isCorrectClone = true
    if dirExists(absolutePath / ".git"):
      let remoteUrl =
          staticExec("cd \"" & absolutePath & "\" && git remote get-url origin").strip
      if remoteUrl != testSuiteUrl:
        isCorrectClone = false
      let branches = staticExec("cd \"" & absolutePath & "\" && git branch").strip
      if "* data" notin branches.splitLines():
        isCorrectClone = false
    if isCorrectClone:
      let updateOutput = staticExec("cd \"" & absolutePath & "\" && git pull")
      #if uError != 0:
      #  echo "could not update yaml-test-suite! please fix this problem and compile again."
      #  echo "output:\n"
      #  echo "$ git pull"
      #  echo updateOutput
      #  quit 1
    else:
      echo testSuiteFolder, " exists, but is not in expected state. Make sure it is a git repo,"
      echo "cloned from ", testSuiteUrl, ", and the data branch"
      echo "is active. Alternatively, delete the folder " & testSuiteFolder & '.'
      quit 1
  else:
    let cloneOutput = staticExec("cd \"" & pwd &
      "\" && git clone " & testSuiteUrl & " -b data")
    #if cError != 0:
    if not(dirExists(absolutePath)) or not(dirExists(absolutePath / ".git")) or
        not(dirExists(absolutePath / "229Q")):
      echo "could not clone ", testSuiteUrl, ". Make sure"
      echo "you are connected to the internet and your proxy settings are correct. output:\n"
      echo "$ git clone ", testSuiteUrl, " -b data"
      echo cloneOutput
      quit 1

proc parserTest(path: string): bool =
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
        echoError("At token #" & $i & ": Expected stream end, got " &
                  $actualEvent.kind)
        return false
      let expectedEvent = expected.next()
      if expectedEvent != actualEvent:
        printDifference(expectedEvent, actualEvent)
        echoError("At token #" & $i &
                  ": Actual tokens do not match expected tokens")
        return false
      i.inc()
    if not expected.finished():
      echoError("Got fewer tokens than expected, first missing " &
                "token: " & $expected.next().kind)
      return false
  except:
    let e = getCurrentException()
    if e.parent of YamlParserError:
      let pe = (ref YamlParserError)(e.parent)
      echo "line ", pe.line, ", column ", pe.column, ": ", pe.msg
      echo pe.lineContent
    else: echo e.msg
    echoError("Catched an exception at token #" & $i &
              " test was not successful")
    return false
  result = true

macro genTests(): untyped =
  let
    pwd = staticExec("pwd").strip
    absolutePath = '"' & (pwd / testSuiteFolder) & '"'
  echo "[tparser] Generating tests from " & absolutePath
  ensureTestSuiteCloneCorrect(pwd)
  result = newStmtList()
  # walkDir for some crude reason does not work with travis build
  let dirItems = staticExec("ls -1d " & absolutePath / "*")
  for dirPath in dirItems.splitLines():
    if dirPath.strip.len == 0: continue
    if dirPath[^4..^1] in [".git", "name", "tags", "meta"]: continue
    let title = slurp(dirPath / "===")
    result.add(newCall("test",
        newLit(strip(title) & " [" &
        dirPath[^4..^1] & ']'), newCall("doAssert", newCall("parserTest",
        newLit(dirPath)))))
  result = newCall("suite", newLit("Parser Tests (from yaml-test-suite)"), result)

genTests()
