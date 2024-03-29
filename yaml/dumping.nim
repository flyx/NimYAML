#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ===================
## Module yaml/dumping
## ===================
##
## The dumping API enables you to dump native Nim values as
## YAML character stream. Along with the loading API, this
## forms the highest-level API of NimYAML.

import std/streams
import parser, presenter, native, private/internal, taglib
export native

type
  Dumper* = object
    ## Holds configuration for dumping Nim values.
    ## Default initialization yields the style that can be set via
    ## ``setDefaultStyle``.
    presentation* : PresentationOptions
    serialization*: SerializationOptions 

proc setMinimalStyle*(dumper: var Dumper) =
  ## Output preset. Tries to output single line flow-only output.
  dumper.presentation = PresentationOptions(
    newlines: nlNone,
    containers: cFlow,
    directivesEnd: deIfNecessary,
    suppressAttrs: false,
    quoting: sqJson,
    condenseFlow: true,
    explicitKeys: false,
    maxLineLength: none(int)
  )
  dumper.serialization = SerializationOptions(
    tagStyle: tsNone,
    anchorStyle: asTidy
  )

proc minimalDumper*(): Dumper =
  result.setMinimalStyle()
  
proc setExplanatoryStyle*(dumper: var Dumper) =
  ## Output preset. Generates specific tags for all nodes, uses flow style,
  ## quotes all string scalars. Enables the ``!n!`` tag shorthand.
  dumper.presentation = PresentationOptions(
    containers: cFlow,
    directivesEnd: deAlways,
    suppressAttrs: false,
    quoting: sqDouble,
    condenseFlow: false,
    explicitKeys: true
  )
  dumper.serialization = SerializationOptions(
    tagStyle: tsAll,
    anchorStyle: asTidy,
    handles: initNimYamlTagHandle()
  )

proc setCanonicalStyle*(dumper: var Dumper)
    {. deprecated: "renamed to setExplanatoryStyle" .} =
  dumper.setExplanatoryStyle()

proc explanatoryDumper*(): Dumper =
  result.setExplanatoryStyle()

proc canonicalDumper*(): Dumper
    {. deprecated: "renamed to explanatoryDumper" .} =
  result.setExplanatoryStyle()

proc setDefaultStyle*(dumper: var Dumper) =
  ## Output preset. Uses block style by default, but flow style for collections
  ## that only contain scalar values.
  dumper.presentation = PresentationOptions()
  dumper.serialization = SerializationOptions()

proc setJsonStyle*(dumper: var Dumper) =
  ## Output preset. Uses flow style, omits tags, anchors and all other non-JSON
  ## entities, formats all scalars as corresponding JSON values.
  dumper.presentation = PresentationOptions(
    containers: cFlow,
    directivesEnd: deNever,
    suppressAttrs: true,
    quoting: sqJson,
    condenseFlow: false,
    explicitKeys: false,
    outputVersion: ovNone
  )
  dumper.serialization = SerializationOptions(
    tagStyle: tsNone,
    anchorStyle: asNone
  )

proc jsonDumper*(): Dumper =
  result.setJsonStyle()

proc setBlockOnlyStyle*(dumper: var Dumper) =
  ## Output preset. Uses block style exclusively.
  dumper.presentation = PresentationOptions(
    containers: cBlock,
    directivesEnd: deIfNecessary,
    suppressAttrs: false,
    quoting: sqUnset,
    condenseFlow: true,
    explicitKeys: false
  )
  dumper.serialization = SerializationOptions(
    tagStyle: tsNone,
    anchorStyle: asTidy
  )

proc blockOnlyDumper*(): Dumper =
  result.setBlockOnlyStyle()

proc dump*[K](
  dumper: Dumper,
  value: K,
  target: Stream,
) {.raises: [
  YamlPresenterJsonError, YamlPresenterOutputError,
  YamlSerializationError
].} =
  ## Dump a Nim value as YAML into the given stream.
  var events = represent(value, dumper.serialization)
  try: present(events, target, dumper.presentation)
  except YamlStreamError as e:
    internalError("Unexpected exception: " & $e.name)
  
proc dump*[K](
  dumper: Dumper,
  value: K,
): string {.hint[XCannotRaiseY]: off, raises: [
  YamlPresenterJsonError, YamlPresenterOutputError,
  YamlSerializationError
].} =
  ## Dump a Nim value as YAML into a string.
  var events = represent(value, dumper.serialization)
  try: result = present(events, dumper.presentation)
  except YamlStreamError as e:
    internalError("Unexpected exception: " & $e.name)

proc transform*(
  dumper : Dumper,
  input  : Stream | string,
  output : Stream,
  resolveToCoreYamlTags: bool = false,
) {.raises: [
  IOError, OSError, YamlParserError, YamlPresenterJsonError,
  YamlPresenterOutputError
].} =
  ## Parse ``input`` as YAML character stream and then dump it to ``output``
  ## using the given presentation options.
  ## If ``resolveToCoreYamlTags`` is ``true``, non-specific tags will
  ## be replaced by specific tags according to the YAML core schema.
  transform(input, output, dumper.presentation, resolveToCoreYamlTags)

proc transform*(
  dumper : Dumper,
  input  : Stream | string,
  resolveToCoreYamlTags: bool = false,
): string {.raises: [
  IOError, OSError, YamlParserError, YamlPresenterJsonError,
  YamlPresenterOutputError
].} =
  ## Parse ``input`` as YAML character stream and then dump it
  ## using the given presentation options. Returns the resulting string.
  ## If ``resolveToCoreYamlTags`` is ``true``, non-specific tags will
  ## be replaced by specific tags according to the YAML core schema.
  result = transform(input, dumper.presentation, resolveToCoreYamlTags)
