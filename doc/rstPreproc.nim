## This is a tool for preprocessing rst files. Lines starting with ``%`` will
## get substituted by nicely layouted included nim and yaml code.
##
## The syntax of substituted lines is ``'%' jsonfile '%' jsonpath``. *jsonfile*
## shall be the path to a JSON file. *jsonpath* shall be a path to some node in
## that JSON file.
##
## Usage:
##
##     rstPreproc -o:path <infile>
##
## *path* is the output path. If omitted, it will be equal to infile with its
## suffix substituted by ``.rst``. *infile* is the source rst file.

import parseopt2, json, streams, tables, strutils, os

var
  infile = ""
  path: string = nil
for kind, key, val in getopt():
  case kind
  of cmdArgument:
    if infile == "":
      if key == "":
        echo "invalid input file with empty name!"
        quit 1
      infile = key
    else:
      echo "Only one input file is supported!"
      quit 1
  of cmdLongOption, cmdShortOption:
    case key
    of "out", "o":
      if isNil(path): path = val
      else:
        echo "Duplicate output path!"
        quit 1
    else:
      echo "Unknown option: ", key
      quit 1
  of cmdEnd: assert(false) # cannot happen

if infile == "":
  echo "Missing input file!"
  quit 1

if isNil(path):
  for i in countdown(infile.len - 1, 0):
    if infile[i] == '.':
      if infile[i..^1] == ".rst": path = infile & ".rst"
      else: path = infile[0..i] & "rst"
      break
  if isNil(path): path = infile & ".rst"

var tmpOut = newFileStream(path, fmWrite)

proc append(s: string) =
  tmpOut.writeLine(s)

proc gotoPath(root: JsonNode, path: string): JsonNode =
  doAssert path[0] == '/'
  if path.len == 1: return root
  doAssert root.kind == JObject
  for i in 1..<path.len:
    if path[i] == '/':
      return gotoPath(root.getFields()[path[1..<i]], path[i+1 .. ^1])
  return root.getFields()[path[1..^1]]

const headingChars = ['-', '`', ':', '\'']

proc outputExamples(node: JsonNode, prefix: string, level: int = 0) =
  case node.kind
  of JObject:
    for key, value in node.getFields():
      append(key)
      let headingChar = if level >= headingChars.len: headingChars[^1] else:
          headingChars[level]
      append(repeat(headingChar, key.len) & '\l')
      outputExamples(value, prefix, level + 1)
  of JArray:
    let elems = node.getElems()
    case elems.len
    of 2:
      append(".. raw:: html")
      append("  <table class=\"quickstart-example\"><thead><tr><th>code.nim</th>")
      append("  <th>" & elems[1].getStr() &
             ".yaml</th></tr></thead><tbody><tr><td>\n")
      append(".. code:: nim")
      append("   :file: " & prefix & elems[0].getStr() & ".nim\n")
      append(".. raw:: html")
      append("  </td>\n  <td>\n")
      append(".. code:: yaml")
      append("   :file: " & prefix & elems[0].getStr() & '.' &
             elems[1].getStr() & ".yaml\n")
      append(".. raw:: html")
      append("  </td></tr></tbody></table>\n")
    else:
      echo "Unexpected number of elements in array: ", elems.len
      quit 1
  else:
    echo "Unexpected node kind: ", node.kind
    quit 1

var lineNum = 0
for line in infile.lines():
  if line.len > 0 and line[0] == '%':
    var
      jsonFile: string = nil
      jsonPath: string = nil
    for i in 1..<line.len:
      if line[i] == '%':
        jsonFile = line[1 .. i - 1]
        jsonPath = line[i + 1 .. ^1]
        break
    if isNil(jsonFile):
      echo "Second % missing in line " & $lineNum & "! content:\n"
      echo line
      quit 1
    let root = parseFile(jsonFile)
    var prefix = ""
    for i in countdown(jsonFile.len - 1, 0):
      if jsonFile[i] == '/':
        prefix = jsonFile[0..i]
        break
    outputExamples(root.gotoPath(jsonPath), prefix)
  else:
    append(line)
