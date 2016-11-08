import unittest, os, osproc, macros, strutils, streams

proc inputTest(basePath, path, nimPath: string): bool =
  let
    absolutePath = basePath / path
    inFileOrig = absolutePath / "01-in.yaml"
    inFileDest = absolutePath / "in.yaml"
    codeFileOrig = absolutePath / "00-code.nim"
    codeFileDest = absolutePath / "code.nim"
    exeFileDest = when defined(windows): absolutePath / "code.exe" else:
        absolutePath / "code"
  copyFile(inFileOrig, inFileDest)
  copyFile(codeFileOrig, codeFileDest)
  defer:
    removeFile(inFileDest)
    removeFile(codeFileDest)
  var process = startProcess(nimPath & " c --hints:off -p:" & escape(basePath) &
      " code.nim", absolutePath, [], nil, {poStdErrToStdOut, poEvalCommand})
  defer:
    process.close()
  if process.waitForExit() != 0:
    echo "compiler output:"
    echo "================\n"
    echo process.outputStream().readAll()
    result = false
  else:
    defer: removeFile(exeFileDest)
    process.close()
    process = startProcess(absolutePath / "code", absolutePath, [], nil,
        {poStdErrToStdOut, poEvalCommand})
    if process.waitForExit() != 0:
      echo "executable output:"
      echo "==================\n"
      echo process.outputStream().readAll()
      result = false
    else: result = true

proc outputTest(basePath, path, nimPath: string): bool =
  let
    absolutePath = basePath / path
    codeFileOrig = absolutePath / "00-code.nim"
    codeFileDest = absolutePath / "code.nim"
    exeFileDest = when defined(windows): absolutePath / "code.exe" else:
        absolutePath / "code"
    outFileExpected = absolutePath / "01-out.yaml"
    outFileActual = absolutePath / "out.yaml"
  copyFile(codeFileOrig, codeFileDest)
  defer: removeFile(codeFileDest)
  var process = startProcess(nimPath & " c --hints:off -p:" & escape(basePath) &
      " code.nim", absolutePath, [], nil, {poStdErrToStdOut, poEvalCommand})
  defer: process.close()
  if process.waitForExit() != 0:
    echo "compiler output:"
    echo "================\n"
    echo process.outputStream().readAll()
    result = false
  else:
    defer: removeFile(exeFileDest)
    process.close()
    process = startProcess(absolutePath / "code", absolutePath, [], nil,
        {poStdErrToStdOut, poEvalCommand})
    if process.waitForExit() != 0:
      echo "executable output:"
      echo "==================\n"
      echo process.outputStream().readAll()
      result = false
    else:
      defer: removeFile(outFileActual)
      var
        expected = open(outFileExpected, fmRead)
        actual = open(outFileActual, fmRead)
        lineNumber = 1
      defer:
        expected.close()
        actual.close()
      var
        expectedLine = ""
        actualLine = ""
      while true:
        if expected.readLine(expectedLine):
          if actual.readLine(actualLine):
            if expectedLine != actualLine:
              echo "difference at line #", lineNumber, ':'
              echo "expected: ", escape(expectedLine)
              echo "  actual: ", escape(actualLine)
              return false
          else:
            echo "actual output has fewer lines than expected; ",
                "first missing line: #", lineNumber
            echo "expected: ", escape(expectedLine)
            return false
        else:
          if actual.readLine(actualLine):
            echo "actual output has more lines than expected; ",
                "first unexpected line: #", lineNumber
            echo "content: ", escape(actualLine)
            return false
          else: break
        lineNumber.inc()
      result = true

proc testsFor(path: string, root: bool = true, titlePrefix: string = ""):
    NimNode {.compileTime.} =
  result = newStmtList()
  let
    baseDir = staticExec("pwd")
    nimPathRaw = staticExec("which nim")
    nimPath = if nimPathRaw[0] == '/': nimPathRaw else: baseDir / nimPathRaw
    title = titlePrefix & slurp(baseDir / path / "title").splitLines()[0]
  if fileExists(path / "00-code.nim"):
    var test = newCall("test", newLit(title))
    if fileExists(path / "01-in.yaml"):
      test.add(newCall("doAssert", newCall("inputTest", newLit(baseDir),
          newLit(path), newLit(nimPath))))
    elif fileExists(path / "01-out.yaml"):
      test.add(newCall("doAssert", newCall("outputTest", newLit(baseDir),
          newLit(path), newLit(nimPath))))
    else:
      echo "Error: neither 01-in.yaml nor 01-out.yaml exists in " & path & '!'
      quit 1
    result.add(test)
  for kind, childPath in walkDir(path):
    if kind == pcDir:
      if childPath != path / "nimcache":
        result.add(testsFor(childPath, false, if root: "" else: title & ' '))
  if root:
    result = newCall("suite", newLit(title), result)

macro genTests(): untyped = testsFor("doc/snippets/quickstart")

genTests()