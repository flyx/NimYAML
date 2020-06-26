## This is a tool for preprocessing rst files. Lines starting with ``%`` will
## get substituted by nicely layouted nim and yaml code included from file in
## the snippets tree.
##
## The syntax of substituted lines is ``'%' path '%' level``. *path* shall be
## a path relative to the *snippets* directory. *level* shall be the level depth
## of the first title that should be produced.
##
## Usage:
##
##     rstPreproc -o:path <infile>
##
## *path* is the output path. If omitted, it will be equal to infile with its
## suffix substituted by ``.rst``. *infile* is the source rst file.
##
## The reason for this complex approach is to have all snippets used in the docs
## available as source files for automatic testing. This way, we can make sure
## that the code in the docs actually works.

import parseopt2, streams, tables, strutils, os, options

var
  infile = ""
  path = none(string)
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
      if path.isNone: path = some(val)
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

if path.isNone:
  for i in countdown(infile.len - 1, 0):
    if infile[i] == '.':
      if infile[i..^1] == ".rst": path = some(infile & ".rst")
      else: path = some(infile[0..i] & "rst")
      break
  if path.isNone: path = some(infile & ".rst")

var tmpOut = newFileStream(path.get(), fmWrite)

proc append(s: string) =
  tmpOut.writeLine(s)

const headingChars = ['=', '-', '`', ':', '\'']

proc outputExamples(curPath: string, level: int = 0) =
  let titlePath = curPath / "title"
  if fileExists(titlePath):
    let titleFile = open(titlePath, fmRead)
    defer: titleFile.close()
    var title = ""
    if titleFile.readLine(title):
      let headingChar = if level >= headingChars.len: headingChars[^1] else:
          headingChars[level]
      append(title)
      append(repeat(headingChar, title.len) & '\l')

  # process content files under this directory

  var codeFiles = newSeq[string]()
  for kind, filePath in walkDir(curPath, true):
    if kind == pcFile:
      if filePath != "title": codeFiles.add(filePath)
  case codeFiles.len
  of 0: discard
  of 1:
    let (_, _, extension) = codeFiles[0].splitFile()
    append(".. code:: " & extension[1..^1])
    append("   :file: " & (curPath / codeFiles[0]) & '\l')
  of 2:
    append(".. raw:: html")
    append("  <table class=\"quickstart-example\"><thead><tr>")
    for codeFile in codeFiles:
      append("    <th>" & codeFile[3..^1] & "</th>")
    append("  </th></tr></thead><tbody><tr><td>\n")

    var first = true
    for codeFile in codeFiles:
      if first: first = false
      else: append(".. raw:: html\n  </td>\n  <td>\n")
      let (_, _, extension) = codeFile.splitFile()
      append(".. code:: " & extension[1..^1])
      append("   :file: " & (curPath / codeFile) & '\l')

    append(".. raw:: html")
    append("  </td></tr></tbody></table>\n")
  else:
    echo "Unexpected number of files in ", curPath, ": ", codeFiles.len

  # process child directories

  for kind, dirPath in walkDir(curPath):
    if kind == pcDir:
      outputExamples(dirPath, level + 1)

var lineNum = 0
for line in infile.lines():
  if line.len > 0 and line[0] == '%':
    var
      srcPath = none(string)
      level = 0
    for i in 1..<line.len:
      if line[i] == '%':
        srcPath = some(line[1 .. i - 1])
        level = parseInt(line[i + 1 .. ^1])
        break
    if srcPath.isNone:
      echo "Second % missing in line " & $lineNum & "! content:\n"
      echo line
      quit 1
    outputExamples("snippets" / srcPath.get(), level)
  else:
    append(line)
