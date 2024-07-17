#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ===================
## Module yaml/loading
## ===================
##
## The loading API enables you to load a YAML character stream
## into native Nim value. Along with the dumping API, this
## forms the highest-level API of NimYAML.

import std / [ streams ]
import native, parser, private/internal
export native, YamlConstructionError, YamlParserError

proc load*[K](input: Stream | string, target: var K)
    {.raises: [YamlConstructionError, IOError, OSError, YamlParserError].} =
  ## Loads a Nim value from a YAML character stream.
  try:
    var
      parser = initYamlParser()
      events = parser.parse(input)
      e = events.next()
    yAssert(e.kind == yamlStartStream)
    if events.peek().kind != yamlStartDoc:
      raise constructionError(events, e.startPos, "stream contains no documents")
    construct(events, target)
    e = events.next()
    if e.kind != yamlEndStream:
      var ex = (ref YamlConstructionError)(
        mark: e.startPos, msg: "stream contains multiple documents")
      discard events.getLastTokenContext(ex.lineContent)
      raise ex
  except YamlStreamError as e:
    if e.parent of IOError: raise (ref IOError)(e.parent)
    if e.parent of OSError: raise (ref OSError)(e.parent)
    elif e.parent of YamlParserError: raise (ref YamlParserError)(e.parent)
    elif e.parent of YamlConstructionError: raise (ref YamlConstructionError)(e.parent)
    else: internalError("Unexpected exception: " & $e.parent.name)

proc loadAs*[K](input: Stream | string): K {.raises:
    [YamlConstructionError, IOError, OSError, YamlParserError].} =
  ## Loads the given YAML input to a value of the type K and returns it
  load(input, result)

proc loadMultiDoc*[K](input: Stream | string, target: var seq[K]) =
  var
    parser = initYamlParser()
    events = parser.parse(input)
    e = events.next()
  yAssert(e.kind == yamlStartStream)
  try:
    while events.peek().kind == yamlStartDoc:
      var item: K
      construct(events, item)
      target.add(item)
    e = events.next()
    yAssert(e.kind == yamlEndStream)
  except YamlConstructionError as e:
    discard events.getLastTokenContext(e.lineContent)
    raise e
  except YamlStreamError as e:
    if e.parent of IOError: raise (ref IOError)(e.parent)
    elif e.parent of OSError: raise (ref OSError)(e.parent)
    elif e.parent of YamlParserError: raise (ref YamlParserError)(e.parent)
    else: internalError("Unexpected exception: " & $e.parent.name)