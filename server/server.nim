#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import jester, parseopt, asyncdispatch, json, streams, strutils
import packages/docutils/rstgen, packages/docutils/highlite, options
import ../yaml, ../yaml/parser, ../yaml/presenter, server_cfg

router nyRouter:
  get "/webservice/":
    resp(Http200, [("Content-Type", "text/plain")], "I am a friendly NimYAML parser webservice.")
  post "/webservice/":
    var
      resultNode = newJObject()
      msg: string
      retStatus = Http200
      contentType = "application/json"
      headers = @[("Access-Control-Allow-Origin", "*"), ("Pragma", "no-cache"),
        ("Cache-Control", "no-cache"), ("Expires", "0")]
      dumper: Dumper
    try:
      case @"style"
      of "minimal": dumper.setMinimalStyle()
      of "explanatory": dumper.setExplanatoryStyle()
      of "default": dumper.setDefaultStyle()
      of "json": dumper.setJsonStyle()
      of "block": dumper.setBlockOnlyStyle()
      of "tokens":
        try:
          var
            output = "+STR\n"
            parser = initYamlParser(false)
            events = parser.parse(newStringStream(@"input"))
          for event in events: output.add(parser.display(event) & "\n")
          output &= "-STR"
          resultNode["code"] = %0
          resultNode["output"] = %output
          msg = resultNode.pretty
        except YamlStreamError as e:
          raise e.parent
      else:
        retStatus = Http400
        msg = "Invalid style: " & escape(@"style")
        contentType = "text/plain;charset=utf8"
      if len(msg) == 0:
        var
          output = newStringStream()
          highlighted = ""
        dumper.transform(newStringStream(@"input"), output, @"style" == "explanatory")

        # syntax highlighting (stolen and modified from stlib's rstgen)
        var g: GeneralTokenizer
        g.initGeneralTokenizer(output.data)
        while true:
          g.getNextToken(langYaml)
          case g.kind
          of gtEof: break
          of gtNone, gtWhitespace:
            highlighted.add(substr(output.data, g.start, g.length + g.start - 1))
          else:
            highlighted.addf("<span class=\"$2\">$1</span>",
              esc(outHtml, substr(output.data, g.start, g.length+g.start-1)),
              tokenClassToStr[g.kind])

        resultNode["code"] = %0
        resultNode["output"] = %highlighted
        msg = resultNode.pretty
    except YamlParserError as e:
      resultNode["code"] = %1
      resultNode["line"] = %e.mark.line
      resultNode["column"] = %e.mark.column
      resultNode["message"] = %e.msg
      resultNode["detail"] = %e.lineContent
      msg = resultNode.pretty
    except YamlPresenterJsonError as e:
      resultNode["code"] = %2
      resultNode["message"] = %e.msg
      msg = resultNode.pretty
    except CatchableError as e:
      msg = "Name: " & $e.name & "\nMessage: " & e.msg &
          "\nTrace:\n" & e.getStackTrace
      retStatus = Http500
      contentType = "text/plain;charset=utf-8"
    headers.add(("Content-Type", contentType))
    resp retStatus, headers, msg

proc main(port: int, address: string) =
  let settings = newSettings(port=port.Port, bindAddr=address, staticDir=shareDir())
  var jester = initJester(nyrouter, settings=settings)
  jester.serve()

when isMainModule:
  var
    port = 5000
    address = "127.0.0.1"
  for kind, key, value in getOpt():
    case kind
    of cmdArgument:
      echo "unexpected positional argument"
      quit 1
    of cmdLongOption, cmdShortOption:
      case key
      of "p", "port":
        port = parseInt(value)
      of "a", "address":
        address = value
      else:
        echo "Unknown option: ", key
        quit 1
    of cmdEnd:
      discard
  main(port, address)
