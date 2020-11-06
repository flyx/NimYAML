import hashes
import private/internal

type
  Anchor* = distinct string ## \
    ## An ``Anchor`` identifies an anchor in the current document.
    ## It is not necessarily unique and references to an anchor must be
    ## resolved immediately on occurrence.
    ##
    ## Anchor provides the operator `$` for converting to string, `==` for
    ## comparison, and `hash` for usage in a hashmap.

  TagId* = distinct int ## \
    ## A ``TagId`` identifies a tag URI, like for example
    ## ``"tag:yaml.org,2002:str"``. The URI corresponding to a ``TagId`` can
    ## be queried from the `TagLibrary <#TagLibrary>`_ which was
    ## used to create this ``TagId``; e.g. when you parse a YAML character
    ## stream, the ``TagLibrary`` of the parser is the one which generates
    ## the resulting ``TagId`` s.
    ##
    ## URI strings are mapped to ``TagId`` s for efficiency  reasons (you
    ## do not need to compare strings every time) and to be able to
    ## discover unknown tag URIs early in the parsing process.

  ScalarStyle* = enum
    ## Original style of the scalar (for input),
    ## or desired style of the scalar (for output).
    ssAny, ssPlain, ssSingleQuoted, ssDoubleQuoted, ssLiteral, ssFolded

  CollectionStyle* = enum
    csAny, csBlock, csFlow, csPair

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

  Mark* = tuple[line, column: Positive]

  Properties* = tuple[anchor: Anchor, tag: TagId]

const
  yAnchorNone*: Anchor = "".Anchor ## \
    ## yielded when no anchor was defined for a YAML node

  defaultMark: Mark = (1.Positive, 1.Positive) ## \
    ## used for events that are not generated from input.

  yTagExclamationMark*: TagId = 0.TagId ## ``!`` non-specific tag
  yTagQuestionMark*   : TagId = 1.TagId ## ``?`` non-specific tag

  # failsafe schema

  yTagString*         : TagId = 2.TagId ## \
    ## `!!str <http://yaml.org/type/str.html >`_ tag
  yTagSequence*       : TagId = 3.TagId ## \
    ## `!!seq <http://yaml.org/type/seq.html>`_ tag
  yTagMapping*        : TagId = 4.TagId ## \
    ## `!!map <http://yaml.org/type/map.html>`_ tag

  # json & core schema

  yTagNull*    : TagId = 5.TagId ## \
    ## `!!null <http://yaml.org/type/null.html>`_ tag
  yTagBoolean* : TagId = 6.TagId ## \
    ## `!!bool <http://yaml.org/type/bool.html>`_ tag
  yTagInteger* : TagId = 7.TagId ## \
    ## `!!int <http://yaml.org/type/int.html>`_ tag
  yTagFloat*   : TagId = 8.TagId ## \
    ## `!!float <http://yaml.org/type/float.html>`_ tag

  # other language-independent YAML types (from http://yaml.org/type/ )

  yTagOrderedMap* : TagId = 9.TagId  ## \
    ## `!!omap <http://yaml.org/type/omap.html>`_ tag
  yTagPairs*      : TagId = 10.TagId ## \
    ## `!!pairs <http://yaml.org/type/pairs.html>`_ tag
  yTagSet*        : TagId = 11.TagId ## \
    ## `!!set <http://yaml.org/type/set.html>`_ tag
  yTagBinary*     : TagId = 12.TagId ## \
    ## `!!binary <http://yaml.org/type/binary.html>`_ tag
  yTagMerge*      : TagId = 13.TagId ## \
    ## `!!merge <http://yaml.org/type/merge.html>`_ tag
  yTagTimestamp*  : TagId = 14.TagId ## \
    ## `!!timestamp <http://yaml.org/type/timestamp.html>`_ tag
  yTagValue*      : TagId = 15.TagId ## \
    ## `!!value <http://yaml.org/type/value.html>`_ tag
  yTagYaml*       : TagId = 16.TagId ## \
    ## `!!yaml <http://yaml.org/type/yaml.html>`_ tag

  yTagNimField*   : TagId = 100.TagId ## \
    ## This tag is used in serialization for the name of a field of an
    ## object. It may contain any string scalar that is a valid Nim symbol.

  yFirstStaticTagId* : TagId = 1000.TagId ## \
    ## The first ``TagId`` assigned by the ``setTagId`` templates.

  yFirstCustomTagId* : TagId = 10000.TagId ## \
    ## The first ``TagId`` which should be assigned to an URI that does not
    ## exist in the ``YamlTagLibrary`` which is used for parsing.

  yamlTagRepositoryPrefix* = "tag:yaml.org,2002:"
  nimyamlTagRepositoryPrefix* = "tag:nimyaml.org,2016:"

proc properties*(event: Event): Properties =
  ## returns the tag of the given event
  case event.kind
  of yamlStartMap: result = event.mapProperties
  of yamlStartSeq: result = event.seqProperties
  of yamlScalar: result = event.scalarProperties
  else: raise newException(FieldDefect, "Event " & $event.kind & " has no properties")

proc collectionStyle*(event: Event): CollectionStyle =
  ## returns the style of the given collection start event
  case event.kind
  of yamlStartMap: result = event.mapStyle
  of yamlStartSeq: result = event.seqStyle
  else: raise (ref FieldDefect)(msg: "Event " & $event.kind & " has no collectionStyle")

proc startStreamEvent*(): Event =
  return Event(startPos: defaultMark, endPos: defaultMark, kind: yamlStartStream)

proc endStreamEvent*(): Event =
  return Event(startPos: defaultMark, endPos: defaultMark, kind: yamlEndStream)

proc startDocEvent*(explicit: bool = false, version: string = "",
                    handles: seq[tuple[handle, uriPrefix: string]] = @[],
                    startPos, endPos: Mark = defaultMark): Event
    {.inline, raises: [].} =
  ## creates a new event that marks the start of a YAML document
  result = Event(startPos: startPos, endPos: endPos,
                 kind: yamlStartDoc, version: version, handles: handles,
                 explicitDirectivesEnd: explicit)

proc endDocEvent*(explicit: bool = false, startPos, endPos: Mark = defaultMark): Event
    {.inline, raises: [].} =
  ## creates a new event that marks the end of a YAML document
  result = Event(startPos: startPos, endPos: endPos,
                 kind: yamlEndDoc, explicitDocumentEnd: explicit)

proc startMapEvent*(style: CollectionStyle, props: Properties,
                    startPos, endPos: Mark = defaultMark): Event {.inline, raises: [].} =
  ## creates a new event that marks the start of a YAML mapping
  result = Event(startPos: startPos, endPos: endPos,
                 kind: yamlStartMap, mapProperties: props,
                 mapStyle: style)

proc startMapEvent*(style: CollectionStyle = csAny,
                    tag: TagId = yTagQuestionMark,
                    anchor: Anchor = yAnchorNone,
                    startPos, endPos: Mark = defaultMark): Event {.inline.} =
  return startMapEvent(style, (anchor, tag), startPos, endPos)

proc endMapEvent*(startPos, endPos: Mark = defaultMark): Event {.inline, raises: [].} =
  ## creates a new event that marks the end of a YAML mapping
  result = Event(startPos: startPos, endPos: endPos, kind: yamlEndMap)

proc startSeqEvent*(style: CollectionStyle,
                    props: Properties,
                    startPos, endPos: Mark = defaultMark): Event {.inline, raises: [].} =
  ## creates a new event that marks the beginning of a YAML sequence
  result = Event(startPos: startPos, endPos: endPos,
                 kind: yamlStartSeq, seqProperties: props,
                 seqStyle: style)

proc startSeqEvent*(style: CollectionStyle = csAny,
                    tag: TagId = yTagQuestionMark,
                    anchor: Anchor = yAnchorNone,
                    startPos, endPos: Mark = defaultMark): Event {.inline.} =
  return startSeqEvent(style, (anchor, tag), startPos, endPos)

proc endSeqEvent*(startPos, endPos: Mark = defaultMark): Event {.inline, raises: [].} =
  ## creates a new event that marks the end of a YAML sequence
  result = Event(startPos: startPos, endPos: endPos, kind: yamlEndSeq)

proc scalarEvent*(content: string, props: Properties,
                  style: ScalarStyle = ssAny,
                  startPos, endPos: Mark = defaultMark): Event {.inline, raises: [].} =
  ## creates a new event that represents a YAML scalar
  result = Event(startPos: startPos, endPos: endPos,
                 kind: yamlScalar, scalarProperties: props,
                 scalarContent: content, scalarStyle: style)

proc scalarEvent*(content: string = "", tag: TagId = yTagQuestionMark,
                  anchor: Anchor = yAnchorNone,
                  style: ScalarStyle = ssAny,
                  startPos, endPos: Mark = defaultMark): Event {.inline.} =
  return scalarEvent(content, (anchor, tag), style, startPos, endPos)

proc aliasEvent*(target: Anchor, startPos, endPos: Mark = defaultMark): Event {.inline, raises: [].} =
  ## creates a new event that represents a YAML alias
  result = Event(startPos: startPos, endPos: endPos, kind: yamlAlias, aliasTarget: target)

proc `==`*(left, right: Anchor): bool {.borrow, locks: 0.}
proc `$`*(id: Anchor): string {.borrow, locks: 0.}
proc hash*(id: Anchor): Hash {.borrow, locks: 0.}

proc `==`*(left, right: TagId): bool {.borrow, locks: 0.}
proc hash*(id: TagId): Hash {.borrow, locks: 0.}

proc `$`*(id: TagId): string {.raises: [].} =
  case id
  of yTagQuestionMark: "?"
  of yTagExclamationMark: "!"
  of yTagString: "!!str"
  of yTagSequence: "!!seq"
  of yTagMapping: "!!map"
  of yTagNull: "!!null"
  of yTagBoolean: "!!bool"
  of yTagInteger: "!!int"
  of yTagFloat: "!!float"
  of yTagOrderedMap: "!!omap"
  of yTagPairs: "!!pairs"
  of yTagSet: "!!set"
  of yTagBinary: "!!binary"
  of yTagMerge: "!!merge"
  of yTagTimestamp: "!!timestamp"
  of yTagValue: "!!value"
  of yTagYaml: "!!yaml"
  of yTagNimField: "!nim:field"
  else: "<" & $int(id) & ">"

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
  of yTagQuestionmark: discard
  of yTagExclamationmark:
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
  of yamlStartMap: result = "+MAP" & renderAttrs(event.mapProperties)
  of yamlStartSeq: result = "+SEQ" & renderAttrs(event.seqProperties)
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