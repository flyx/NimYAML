#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import os, terminal
import tmlParser, common
import "../yaml"

const gitCmd =
        "git clone https://github.com/ingydotnet/yaml-dev-kit.git -b data"

proc echoError(msg: string) =
    styledWriteLine(stdout, fgRed, "[error] ", fgWhite, msg, resetStyle)

proc echoInfo(msg: string) =
    styledWriteLine(stdout, fgGreen, "[info] ", fgWhite, msg, resetStyle)

removeDir("yaml-dev-kit")
if execShellCmd(gitCmd) != 0:
    echoError("Could not check out yaml-dev-kit (no internet connection?)")
    quit(1)

var gotErrors = false

try:
    for kind, dirPath in walkDir("yaml-dev-kit"):
        block curTest:
            if kind == pcDir:
                if dirPath[^4..^1] in [".git", "name", "tags"]: continue
                var
                    tagLib = initExtendedTagLibrary()
                    parser = newYamlParser(tagLib)
                    actual = parser.parse(newFileStream(dirPath / "in.yaml"))
                    expected = parseTmlStream(
                            newFileStream(dirPath / "test.event"), tagLib)
                styledWriteLine(stdout, fgGreen, "[test] ", fgWhite,
                                expandSymlink(dirPath / "==="), resetStyle)
                while not actual.finished():
                    let actualEvent = actual.next()
                    if expected.finished():
                        echoError("Expected stream end, got " &
                                  $actualEvent.kind)
                        gotErrors = true
                        break curTest
                    let expectedEvent = expected.next()
                    if expectedEvent != actualEvent:
                        printDifference(expectedEvent, actualEvent)
                        echoError("Actual tokens do not match expected tokens")
                        gotErrors = true
                        break curTest
                if not expected.finished():
                    echoError(
                        "Got fewer tokens than expected, first missing token: " &
                        $expected.next().kind)
                    gotErrors = true
except YamlStreamError:
    let e = getCurrentException()
    if e.parent of YamlParserError:
        let pe = (ref YamlParserError)(e.parent)
        echo "line ", pe.line, ", column ", pe.column, ": ", pe.msg
        echo pe.lineContent
    raise getCurrentException().parent

if gotErrors:
    echoError("There were errors while running the tests")
    quit(1)
else:
    echoInfo("All tests were successful")
    quit(0)