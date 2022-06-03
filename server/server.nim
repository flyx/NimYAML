#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import jester, cligen, asyncdispatch, json, streams, strutils
import packages/docutils/rstgen, packages/docutils/highlite, options
import ../yaml, server_cfg

router nyRouter:
  get "/webservice/":
    resp(Http200, [("Content-Type", "text/plain")], "I am a friendly NimYAML parser webservice.")
  post "/webservice/":
    var
      style: PresentationStyle
      resultNode = newJObject()
      msg: string
      retStatus = Http200
      contentType = "application/json"
      headers = @[("Access-Control-Allow-Origin", "*"), ("Pragma", "no-cache"),
        ("Cache-Control", "no-cache"), ("Expires", "0")]
    try:
      case @"style"
      of "minimal": style = psMinimal
      of "canonical": style = psCanonical
      of "default": style = psDefault
      of "json": style = psJson
      of "block": style = psBlockOnly
      of "tokens":
        var
          output = "+STR\n"
          parser = initYamlParser(false)
          events = parser.parse(newStringStream(@"input"))
        for event in events: output.add(parser.display(event) & "\n")
        output &= "-STR"
        resultNode["code"] = %0
        resultNode["output"] = %output
        msg = resultNode.pretty
      else:
        retStatus = Http400
        msg = "Invalid style: " & escape(@"style")
        contentType = "text/plain;charset=utf8"
      if len(msg) == 0:
        var
          output = newStringStream()
          highlighted = ""
        transform(newStringStream(@"input"), output, defineOptions(style), true)

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
    except YamlParserError:
      let e = (ref YamlParserError)(getCurrentException())
      resultNode["code"] = %1
      resultNode["line"] = %e.mark.line
      resultNode["column"] = %e.mark.column
      resultNode["message"] = %e.msg
      resultNode["detail"] = %e.lineContent
      msg = resultNode.pretty
    except YamlPresenterJsonError:
      let e = getCurrentException()
      resultNode["code"] = %2
      resultNode["message"] = %e.msg
      msg = resultNode.pretty
    except:
      let e = getCurrentException()
      msg = "Name: " & $e.name & "\nMessage: " & e.msg &
          "\nTrace:\n" & e.getStackTrace
      retStatus = Http500
      contentType = "text/plain;charset=utf-8"
    headers.add(("Content-Type", contentType))
    resp retStatus, headers, msg

proc main(port = 5000, address = "127.0.0.1") =
  let settings = newSettings(port=port.Port, bindAddr=address, staticDir=shareDir())
  var jester = initJester(nyrouter, settings=settings)
  jester.serve()

when isMainModule:
  dispatch(main)
