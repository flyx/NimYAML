import unittest, os, osproc, macros, strutils, streams

proc inputTest(path: string): bool =
  let
    inFileOrig = path / "01-in.yaml"
    inFileDest = path / "in.yaml"
    codeFileOrig = path / "00-code.nim"
    codeFileDest = path / "code.nim"
    exeFileDest = when defined(windows): path / "code.exe" else: path / "code"
    currentDir = getCurrentDir()
    basePath = currentDir / ".."
    absolutePath = currentDir / path
  copyFile(inFileOrig, inFileDest)
  copyFile(codeFileOrig, codeFileDest)
  defer:
    removeFile(inFileDest)
    removeFile(codeFileDest)
  var process = startProcess("nim c --hints:off -p:" & escape(basePath) &
      " code.nim", path, [], nil, {poStdErrToStdOut, poEvalCommand})
  setCurrentDir(currentDir) # workaround for https://github.com/nim-lang/Nim/issues/4867
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
    setCurrentDir(currentDir) # workaround for https://github.com/nim-lang/Nim/issues/4867
    if process.waitForExit() != 0:
      echo "executable output:"
      echo "==================\n"
      echo process.outputStream().readAll()
      result = false
    else: result = true

proc outputTest(path: string): bool =
  let
    codeFileOrig = path / "00-code.nim"
    codeFileDest = path / "code.nim"
    exeFileDest = when defined(windows): path / "code.exe" else: path / "code"
    currentDir = getCurrentDir()
    basePath = currentDir / ".."
    absolutePath = currentDir / path
  copyFile(codeFileOrig, codeFileDest)
  defer: removeFile(codeFileDest)
  var process = startProcess("nim c --hints:off -p:" & escape(basePath) &
      " code.nim", path, [], nil, {poStdErrToStdOut, poEvalCommand})
  defer: process.close()
  setCurrentDir(currentDir) # workaround for https://github.com/nim-lang/Nim/issues/4867
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
    setCurrentDir(currentDir) # workaround for https://github.com/nim-lang/Nim/issues/4867
    if process.waitForExit() != 0:
      echo "executable output:"
      echo "==================\n"
      echo process.outputStream().readAll()
      result = false
    else:
      var
        expected = open(path / "01-out.yaml", fmRead)
        actual = open(path / "out.yaml", fmRead)
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
  let title = titlePrefix & slurp(path / "title").splitLines()[0]
  if fileExists(path / "00-code.nim"):
    var test = newCall("test", newLit(title))
    if fileExists(path / "01-in.yaml"):
      test.add(newCall("doAssert", newCall("inputTest", newLit(path))))
    elif fileExists(path / "01-out.yaml"):
      test.add(newCall("doAssert", newCall("outputTest", newLit(path))))
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

macro genTests(): untyped = testsFor("../doc/snippets/quickstart")

genTests()