#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ================
## Module yaml/data
## ================
##
## This module defines the event data structure which serves as internal
## representation of YAML structures. Every YAML document can be described
## as stream of events.

import hashes
import style, private/escaping
export style

type
  Anchor* = distinct string ## \
    ## An ``Anchor`` identifies an anchor in the current document.
    ## It is not necessarily unique and references to an anchor must be
    ## resolved immediately on occurrence.
    ##
    ## Anchor provides the operator `$` for converting to string, `==` for
    ## comparison, and `hash` for usage in a hashmap.

  Tag* = distinct string ## \
    ## A ``Tag`` contains an URI, like for example ``"tag:yaml.org,2002:str"``.

  EventKind* = enum
    ## Kinds of YAML events that may occur in an ``YamlStream``. Event kinds
    ## are discussed in `YamlStreamEvent <#YamlStreamEvent>`_.
    yamlStartStream, yamlEndStream,
    yamlStartDoc, yamlEndDoc, yamlStartMap, yamlEndMap,
    yamlStartSeq, yamlEndSeq, yamlScalar, yamlAlias

  Event* = object
    ## An element from a `YamlStream <#YamlStream>`_. Events that start an
    ## object (``yamlStartMap``, ``yamlStartSeq``, ``yamlScalar``) have
    ## an optional anchor and a tag associated with them. The anchor will be
    ## set to ``yAnchorNone`` if it doesn't exist.
    ##
    ## A missing tag in the YAML character stream generates
    ## the non-specific tags ``?`` or ``!`` according to the YAML
    ## specification. These are by convention mapped to the ``TagId`` s
    ## ``yTagQuestionMark`` and ``yTagExclamationMark`` respectively.
    ## Mapping is done by a `TagLibrary <#TagLibrary>`_.
    ##
    ## ``startPos`` and ``endPos`` are only relevant for events from an input
    ## stream - they are generally ignored if used with events that generate
    ## output.
    startPos*, endPos*: Mark
    case kind*: EventKind
    of yamlStartStream, yamlEndStream: discard
    of yamlStartMap:
      mapProperties*: Properties
      mapStyle*: CollectionStyle
    of yamlStartSeq:
      seqProperties*: Properties
      seqStyle*: CollectionStyle
    of yamlScalar:
      scalarProperties*: Properties
      scalarStyle*  : ScalarStyle
      scalarContent*: string
    of yamlStartDoc:
      explicitDirectivesEnd*: bool
      version*: string
      handles*: seq[tuple[handle, uriPrefix: string]]
    of yamlEndDoc:
      explicitDocumentEnd*: bool
    of yamlEndMap, yamlEndSeq: discard
    of yamlAlias:
      aliasTarget* : Anchor

  Mark* = object
    line*  : Positive = 1
    column*: Positive = 1

  Properties* = tuple[anchor: Anchor, tag: Tag]
  
  YamlLoadingError* = object of ValueError
    ## Base class for all exceptions that may be raised during the process
    ## of loading a YAML character stream.
    mark*: Mark ## position at which the error has occurred.
    lineContent*: string ## \
      ## content of the line where the error was encountered. Includes a
      ## second line with a marker ``^`` at the position where the error
      ## was encountered.

const
  yamlTagRepositoryPrefix* = "tag:yaml.org,2002:"
  nimyamlTagRepositoryPrefix* = "tag:nimyaml.org,2016:"

proc defineTag*(uri: string): Tag =
  ## defines a tag. Use this to optimize away copies of globally defined
  ## Tags.
  result = uri.Tag
  #shallow(result.string) # doesn't work at compile-time

proc defineCoreTag*(name: string): Tag =
  ## defines a tag in YAML's core namespace, ``tag:yaml.org,2002:``
  result = defineTag(yamlTagRepositoryPrefix & name)

const
  yAnchorNone*: Anchor = "".Anchor ## \
    ## yielded when no anchor was defined for a YAML node

  yTagExclamationMark*: Tag = defineTag("!")
  yTagQuestionMark*   : Tag = defineTag("?")

  # failsafe schema

  yTagString*   = defineCoreTag("str")
  yTagSequence* = defineCoreTag("seq")
  yTagMapping*  = defineCoreTag("map")

  # json & core schema

  yTagNull*    = defineCoreTag("null")
  yTagBoolean* = defineCoreTag("bool")
  yTagInteger* = defineCoreTag("int")
  yTagFloat*   = defineCoreTag("float")

  # other language-independent YAML types (from http://yaml.org/type/ )

  yTagOrderedMap* = defineCoreTag("omap")
  yTagPairs*      = defineCoreTag("pairs")
  yTagSet*        = defineCoreTag("set")
  yTagBinary*     = defineCoreTag("binary")
  yTagMerge*      = defineCoreTag("merge")
  yTagTimestamp*  = defineCoreTag("timestamp")
  yTagValue*      = defineCoreTag("value")
  yTagYaml*       = defineCoreTag("yaml")

  # NimYAML specific tags

  yTagNimField*   = defineTag(nimyamlTagRepositoryPrefix & "field")

proc collectionStyle*(event: Event): CollectionStyle =
  ## returns the style of the given collection start event
  case event.kind
  of yamlStartMap: result = event.mapStyle
  of yamlStartSeq: result = event.seqStyle
  else: raise (ref FieldDefect)(msg: "Event " & $event.kind & " has no collectionStyle")

proc startStreamEvent*(): Event =
  return Event(kind: yamlStartStream)

proc endStreamEvent*(): Event =
  return Event(kind: yamlEndStream)

proc startDocEvent*(
  explicit = false,
  version  = "",
  handles  : seq[tuple[handle, uriPrefix: string]] = @[],
  startPos : Mark = Mark(),
  endPos   : Mark = Mark(),
): Event
    {.inline, raises: [].} =
  ## creates a new event that marks the start of a YAML document
  result = Event(startPos: startPos, endPos: endPos,
                 kind: yamlStartDoc, version: version, handles: handles,
                 explicitDirectivesEnd: explicit)

proc endDocEvent*(
  explicit = false,
  startPos : Mark = Mark(),
  endPos   : Mark = Mark(),
): Event
    {.inline, raises: [].} =
  ## creates a new event that marks the end of a YAML document
  result = Event(startPos: startPos, endPos: endPos,
                 kind: yamlEndDoc, explicitDocumentEnd: explicit)

proc startMapEvent*(
  style   : CollectionStyle,
  props   : Properties,
  startPos: Mark = Mark(),
  endPos  : Mark = Mark(),
): Event {.inline, raises: [].} =
  ## creates a new event that marks the start of a YAML mapping
  result = Event(startPos: startPos, endPos: endPos,
                 kind: yamlStartMap, mapProperties: props,
                 mapStyle: style)

proc startMapEvent*(
  style   : CollectionStyle = csAny,
  tag     : Tag             = yTagQuestionMark,
  anchor  : Anchor          = yAnchorNone,
  startPos: Mark            = Mark(),
  endPos  : Mark            = Mark(),
): Event {.inline.} =
  return startMapEvent(style, (anchor, tag), startPos, endPos)

proc endMapEvent*(
  startPos : Mark = Mark(),
  endPos   : Mark = Mark(),
): Event {.inline, raises: [].} =
  ## creates a new event that marks the end of a YAML mapping
  result = Event(startPos: startPos, endPos: endPos, kind: yamlEndMap)

proc startSeqEvent*(
  style   : CollectionStyle,
  props   : Properties,
  startPos: Mark = Mark(),
  endPos  : Mark = Mark(),
): Event {.inline, raises: [].} =
  ## creates a new event that marks the beginning of a YAML sequence
  result = Event(startPos: startPos, endPos: endPos,
                 kind: yamlStartSeq, seqProperties: props,
                 seqStyle: style)

proc startSeqEvent*(
  style   : CollectionStyle = csAny,
  tag     : Tag             = yTagQuestionMark,
  anchor  : Anchor          = yAnchorNone,
  startPos: Mark            = Mark(),
  endPos  : Mark            = Mark(),
): Event {.inline.} =
  return startSeqEvent(style, (anchor, tag), startPos, endPos)

proc endSeqEvent*(
  startPos: Mark = Mark(),
  endPos  : Mark = Mark(),
): Event {.inline, raises: [].} =
  ## creates a new event that marks the end of a YAML sequence
  result = Event(startPos: startPos, endPos: endPos, kind: yamlEndSeq)

proc scalarEvent*(
  content : string,
  props   : Properties,
  style   : ScalarStyle = ssAny,
  startPos: Mark        = Mark(),
  endPos  : Mark        = Mark(),
): Event {.inline, raises: [].} =
  ## creates a new event that represents a YAML scalar
  result = Event(startPos: startPos, endPos: endPos,
                 kind: yamlScalar, scalarProperties: props,
                 scalarContent: content, scalarStyle: style)

proc scalarEvent*(
  content : string      = "",
  tag     : Tag         = yTagQuestionMark,
  anchor  : Anchor      = yAnchorNone,
  style   : ScalarStyle = ssAny,
  startPos: Mark        = Mark(),
  endPos  : Mark        = Mark(),
): Event {.inline.} =
  return scalarEvent(content, (anchor, tag), style, startPos, endPos)

proc aliasEvent*(
  target  : Anchor,
  startPos: Mark = Mark(),
  endPos  : Mark = Mark(),
): Event {.inline, raises: [].} =
  ## creates a new event that represents a YAML alias
  result = Event(startPos: startPos, endPos: endPos, kind: yamlAlias, aliasTarget: target)

proc `==`*(left, right: Anchor): bool {.borrow.}
proc `$`*(id: Anchor): string {.borrow.}
proc hash*(id: Anchor): Hash {.borrow.}

proc `==`*(left, right: Tag): bool {.borrow.}
proc `$`*(tag: Tag): string {.borrow.}
proc hash*(tag: Tag): Hash {.borrow.}

proc `==`*(left: Event, right: Event): bool {.raises: [].} =
  ## compares all existing fields of the given items
  if left.kind != right.kind: return false
  case left.kind
  of yamlStartStream, yamlEndStream, yamlStartDoc, yamlEndDoc, yamlEndMap, yamlEndSeq:
    result = true
  of yamlStartMap:
    result = left.mapProperties == right.mapProperties
  of yamlStartSeq:
    result = left.seqProperties == right.seqProperties
  of yamlScalar:
    result = left.scalarProperties == right.scalarProperties and
             left.scalarContent == right.scalarContent
  of yamlAlias: result = left.aliasTarget == right.aliasTarget

proc renderAttrs*(props: Properties, isPlain: bool = true): string =
  result = ""
  if props.anchor != yAnchorNone: result &= " &" & $props.anchor
  case props.tag
  of yTagQuestionMark: discard
  of yTagExclamationMark:
    if isPlain: result &= " <!>"
  else:
    result &= " <" & $props.tag & ">"

proc `$`*(event: Event): string {.raises: [].} =
  ## outputs a human-readable string describing the given event.
  ## This string is compatible to the format used in the yaml test suite.
  case event.kind
  of yamlStartStream: result = "+STR"
  of yamlEndStream: result = "-STR"
  of yamlEndMap: result = "-MAP"
  of yamlEndSeq: result = "-SEQ"
  of yamlStartDoc:
    result = "+DOC"
    if event.explicitDirectivesEnd: result &= " ---"
  of yamlEndDoc:
    result = "-DOC"
    if event.explicitDocumentEnd: result &= " ..."
  of yamlStartMap:
    result = "+MAP" & (if event.mapStyle == csFlow: " {}" else: "") &
      renderAttrs(event.mapProperties)
  of yamlStartSeq:
    result = "+SEQ" & (if event.seqStyle == csFlow: " []" else: "") &
      renderAttrs(event.seqProperties)
  of yamlScalar:
    result = "=VAL" & renderAttrs(event.scalarProperties,
                                  event.scalarStyle == ssPlain or
                                  event.scalarStyle == ssAny)
    case event.scalarStyle
    of ssPlain, ssAny: result &= " :"
    of ssSingleQuoted: result &= " \'"
    of ssDoubleQuoted: result &= " \""
    of ssLiteral: result &= " |"
    of ssFolded: result &= " >"
    result &= yamlTestSuiteEscape(event.scalarContent)
  of yamlAlias: result = "=ALI *" & $event.aliasTarget

proc properties*(event: Event): Properties =
  ## returns the tag of the given event
  case event.kind
  of yamlStartMap: result = event.mapProperties
  of yamlStartSeq: result = event.seqProperties
  of yamlScalar: result = event.scalarProperties
  else: raise newException(FieldDefect, "Event " & $event.kind & " has no properties")

proc emptyProperties*(event: Event): bool =
  ## returns true if the given event does not need to render
  ## any properties if presented into a YAML character stream.
  let props = event.properties()
  case props.tag
  of yTagExclamationMark:
    result = event.kind == yamlScalar and props.anchor == yAnchorNone
  of yTagQuestionMark:
    result = props.anchor == yAnchorNone
  else: result = false

proc hasSpecificTag*(event: Event): bool =
  var props: Properties
  case event.kind
  of yamlStartMap: props = event.mapProperties
  of yamlStartSeq: props = event.seqProperties
  of yamlScalar: props = event.scalarProperties
  else: return false
  case props.tag
  of yTagExclamationMark, yTagQuestionMark: return false
  else: return true