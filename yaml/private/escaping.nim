#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

proc yamlTestSuiteEscape*(s: string): string =
  result = ""
  for c in s:
    case c
    of '\l': result.add("\\n")
    of '\c': result.add("\\r")
    of '\\': result.add("\\\\")
    of '\b': result.add("\\b")
    of '\t': result.add("\\t")
    else: result.add(c)