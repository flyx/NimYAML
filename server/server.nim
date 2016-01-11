#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import jester, asyncdispatch, json, streams
import yaml

routes:
    get "/":
        headers["Content-Type"] = "text/plain"
        resp "I am a friendly NimYAML parser webservice."
    post "/":
        var style: YamlPresentationStyle
        case @"style"
        of "minimal": style = ypsMinimal
        of "canonical": style = ypsCanonical
        of "default": style = ypsDefault
        of "json": style = ypsJson
        of "block": style = ypsBlockOnly
        var
            output = newStringStream()
            resultNode = newJObject()
        headers["Access-Control-Allow-Origin"] = "*"
        headers["Pragma"] = "no-cache"
        headers["Cache-Control"] = "no-cache"
        headers["Expires"] = "0"
        echo "INPUT: ", @"input", "STYLE:", @"style"
        try:
            transform(newStringStream(@"input"), output, style)
            resultNode["code"] = %0
            resultNode["output"] = %output.data
            resp resultNode.pretty, "application/json"
        except YamlPresenterStreamError:
            let e = (ref YamlParserError)(getCurrentException().parent)
            resultNode["code"] = %1
            resultNode["line"] = %e.line
            resultNode["column"] = %e.column
            resultNode["message"] = %e.msg
            resultNode["detail"] = %e.lineContent
            resp resultNode.pretty, "application/json"
        
        except YamlPresenterJsonError:
            let e = getCurrentException()
            resultNode["code"] = %2
            resultNode["message"] = %e.msg
            headers["Content-Type"] = "application/json"
            resp resultNode.pretty, "application/json"
        except:
            let e = getCurrentException()
            let msg = "Name: " & $e.name & "\nMessage: " & e.msg & "\nTrace:\n" & 
                      e.getStackTrace
            resp Http500, msg, "text/plain;charset=utf-8"

runForever()
