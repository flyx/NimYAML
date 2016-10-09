#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import os, osproc, terminal, strutils, streams, macros, unittest
import testEventParser, commonTestUtils
import "../yaml"

const devKitFolder = "yaml-dev-kit"

proc echoError(msg: string) =
  styledWriteLine(stdout, fgRed, "[error] ", fgWhite, msg, resetStyle)

proc ensureDevKitCloneCorrect() {.compileTime.} =
  if dirExists(devKitFolder):
    var isCorrectClone = true
    if dirExists(devKitFolder / ".git"):
      let remoteUrl =
          staticExec("cd " & devKitFolder & " && git remote get-url origin")
      if remoteUrl != "https://github.com/ingydotnet/yaml-dev-kit.git":
        isCorrectClone = false
      let branches = staticExec("cd " & devKitFolder & " && git branch")
      if "* data" notin branches.splitLines():
        isCorrectClone = false
    if isCorrectClone:
      let updateOutput = staticExec("git pull")
      #if uError != 0:
      #  echo "could not update yaml-dev-kit! please fix this problem and compile again."
      #  echo "output:\n"
      #  echo "$ git pull"
      #  echo updateOutput
      #  quit 1
    else:
      echo devKitFolder, " exists, but is not in expected state. Make sure it is a git repo,"
      echo "cloned from https://github.com/ingydotnet/yaml-dev-kit.git, and the data branch"
      echo "is active. Alternatively, delete the folder " & devKitFolder & '.'
      quit 1
  else:
    let cloneOutput = staticExec("git clone https://github.com/ingydotnet/yaml-dev-kit.git -b data")
    #if cError != 0:
    if not dirExists(devKitFolder):
      echo "could not clone https://github.com/ingydotnet/yaml-dev-kit.git. Make sure"
      echo "you are connected to the internet and your proxy settings are correct. output:\n"
      echo "$ git clone https://github.com/ingydotnet/yaml-dev-kit.git"
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
  ensureDevKitCloneCorrect()
  result = newStmtList()
  let pwd = staticExec("pwd")
  for kind, dirName in walkDir(devKitFolder, true):
    if kind == pcDir:
      if dirName in [".git", "name", "tags", "meta"]: continue
      # see https://github.com/nim-lang/Nim/issues/4871
      let title = slurp(pwd / devKitFolder / dirName / "===")
      result.add(newCall("test",
          newLit(strip(title) & " [" &
          dirName & ']'), newCall("doAssert", newCall("parserTest",
          newLit(devKitFolder / dirName)))))
  result = newCall("suite", newLit("Parser Tests (from yaml-dev-kit)"), result)

genTests()