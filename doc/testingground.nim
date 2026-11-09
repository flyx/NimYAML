#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2026 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## The processing backend of the testing ground on the web documentation.
## Compiled to JavaScript (``nim testingGround``) and run as a Web Worker in
## the user's browser, so that the input never leaves the user's machine.
##
## The worker receives messages ``{input: string, style: string}`` and answers
## with one of:
##
## - ``{code: 0, output: string}``: success. ``output`` is HTML.
## - ``{code: 1, line, column: int, message, detail: string}``: parser error.
## - ``{code: 2, message: string}``: presenter error.
## - ``{code: 3, message: string}``: unexpected error.
##
## All strings except ``output`` are plain text.

when not defined(js):
  {.error: "the testing ground must be compiled with the JS backend".}

import std/[streams, strutils, jsffi]
import packages/docutils/highlite
import ../yaml, ../yaml/[parser, presenter, stream]

proc escapeHtml(s: string): string =
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    of '\'': result.add("&#39;")
    else: result.add(c)

proc highlightYaml(code: string): string =
  ## Returns ``code`` as HTML with syntax highlighting.
  # highlite reads up to and including a terminating NUL character. Native Nim
  # strings have one implicitly, JS strings do not.
  let buf = code & '\0'
  var g: GeneralTokenizer
  g.initGeneralTokenizer(buf)
  while true:
    g.getNextToken(langYaml)
    let token = escapeHtml(buf.substr(g.start, g.start + g.length - 1))
    case g.kind
    of gtEof: break
    of gtNone, gtWhitespace: result.add(token)
    else:
      result.addf("<span class=\"$2\">$1</span>", token, tokenClassToStr[g.kind])

proc tokens(input: string): string =
  ## Returns the event stream of ``input`` in the yaml-test-suite format.
  var
    parser = initYamlParser(false)
    events = parser.parse(newStringStream(input))
  try:
    for event in events: result.add(parser.display(event) & "\n")
  except YamlStreamError as e:
    if e.parent of YamlParserError: raise (ref YamlParserError)(e.parent)
    raise e

proc process(input, style: string): JsObject =
  result = newJsObject()
  try:
    var dumper: Dumper
    case style
    of "minimal": dumper.setMinimalStyle()
    of "explanatory": dumper.setExplanatoryStyle()
    of "default": dumper.setDefaultStyle()
    of "json": dumper.setJsonStyle()
    of "block": dumper.setBlockOnlyStyle()
    of "tokens":
      result.code = 0
      result.output = cstring(escapeHtml(tokens(input)))
      return
    else:
      result.code = 3
      result.message = cstring("Invalid style: " & escape(style))
      return
    let output = dumper.transform(input, style == "explanatory")
    result.code = 0
    result.output = cstring(highlightYaml(output))
  except YamlParserError as e:
    result.code = 1
    result.line = e.mark.line
    result.column = e.mark.column
    result.message = cstring(e.msg)
    result.detail = cstring(e.lineContent)
  except YamlPresenterJsonError as e:
    result.code = 2
    result.message = cstring(e.msg)
  except Exception as e:
    # catches Defects, too: a bug in NimYAML should be reported in the page
    # instead of killing the worker.
    result.code = 3
    result.message = cstring($e.name & ": " & e.msg)

proc processYaml(input, style: cstring): JsObject {.exportc.} =
  process($input, $style)

# Web Worker entry point. Only active when loaded as a worker, so the script
# can also be loaded elsewhere (e.g. in node.js for testing).
{.emit: """
if (typeof WorkerGlobalScope !== "undefined" && self instanceof WorkerGlobalScope) {
  self.onmessage = function(e) {
    self.postMessage(processYaml(e.data.input, e.data.style));
  };
}
""".}
