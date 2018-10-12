#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

template internalError*(s: string) =
  # Note: to get the internal stacktrace that caused the error
  # compile with the `d:debug` flag.
  when not defined(release):
    let ii = instantiationInfo()
    echo "[NimYAML] Error in file ", ii.filename, " at line ", ii.line, ":"
    echo s
    when not defined(JS):
      echo "[NimYAML] Stacktrace:"
      try:
        writeStackTrace()
        let exc = getCurrentException()
        if not isNil(exc.parent):
          echo "Internal stacktrace:"
          echo getStackTrace(exc.parent)
      except: discard
    echo "[NimYAML] Please report this bug."
    quit 1

template yAssert*(e: typed) =
  when not defined(release):
    if not e:
      let ii = instantiationInfo()
      echo "[NimYAML] Error in file ", ii.filename, " at line ", ii.line, ":"
      echo "assertion failed!"
      when not defined(JS):
        echo "[NimYAML] Stacktrace:"
        try:
          writeStackTrace()
          let exc = getCurrentException()
          if not isNil(exc.parent):
            echo "Internal stacktrace:"
            echo getStackTrace(exc.parent)
        except: discard
      echo "[NimYAML] Please report this bug."
      quit 1

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