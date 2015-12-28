## This module provides facilities to generate and interpret
## `YAML <http://yaml.org>`_ character streams. All primitive operations on
## data objects use a `YamlStream <#YamlStream>`_ either as source or as
## output. Because this stream is implemented as iterator, it is possible to
## process YAML input and output sequentially, i.e. without loading the
## processed data structure completely into RAM. This supports the processing of
## large data structures.
##
## As YAML is a strict superset of `JSON <http://json.org>`_, JSON input is
## automatically supported. Additionally, there is functionality available to
## convert any YAML stream into JSON. While JSON is less readable than YAML,
## this enhances interoperability with other languages.

import streams, unicode, lexbase, tables, strutils, json, hashes, queues, macros

type
    YamlTypeHint* = enum
        ## A type hint is a friendly message from the YAML lexer, telling you
        ## it thinks a scalar string probably is of a certain type. You are not
        ## required to adhere to this information. The first matching RegEx will
        ## be the type hint of a scalar string.
        ##
        ## ================== =========================
        ## Name               RegEx
        ## ================== =========================
        ## ``yTypeInteger``   ``0 | -? [1-9] [0-9]*``
        ## ``yTypeFloat``     ``-? [1-9] ( \. [0-9]* [1-9] )? ( e [-+] [1-9] [0-9]* )?``
        ## ``yTypeFloatInf``  ``-? \. (inf | Inf | INF)``
        ## ``yTypeFloatNaN``  ``-? \. (nan | NaN | NAN)``
        ## ``yTypeBoolTrue``  ``y|Y|yes|Yes|YES|true|True|TRUE|on|On|ON``
        ## ``yTypeBoolFalse`` ``n|N|no|No|NO|false|False|FALSE|off|Off|OFF``
        ## ``yTypeNull``      ``~ | null | Null | NULL``
        ## ``yTypeString``    *none*
        ## ``yTypeUnknown``   ``*``
        ## ================== =========================
        ##
        ## The value `yTypeString` is not returned based on RegExes, but for
        ## scalars that are quoted within the YAML input character stream.
        yTypeInteger, yTypeFloat, yTypeFloatInf, yTypeFloatNaN, yTypeBoolTrue,
        yTypeBoolFalse, yTypeNull, yTypeString, yTypeUnknown
    
    YamlStreamEventKind* = enum
        ## Kinds of YAML events that may occur in an ``YamlStream``. Event kinds
        ## are discussed in ``YamlStreamEvent``.
        yamlStartDocument, yamlEndDocument, yamlStartMap, yamlEndMap,
        yamlStartSequence, yamlEndSequence, yamlScalar, yamlAlias,
        yamlError, yamlWarning
    
    TagId* = distinct int ## \
        ## A ``TagId`` identifies a tag URI, like for example 
        ## ``"tag:yaml.org,2002:str"``. The URI corresponding to a ``TagId`` can
        ## be queried from the `YamlTagLibrary <#YamlTagLibrary>`_ which was
        ## used to create this ``TagId`` with
        ## `uri <#uri,YamlTagLibrary,TagId>`_. URI strings are
        ## mapped to ``TagId`` s for efficiency  reasons (you do not need to
        ## compare strings every time) and to be able to discover unknown tag
        ## URIs early in the parsing process.
    AnchorId* = distinct int ## \
        ## An ``AnchorId`` identifies an anchor in the current document. It
        ## becomes invalid as soon as the current document scope is invalidated
        ## (for example, because the parser yielded a ``yamlEndDocument``
        ## event). ``AnchorId`` s exists because of efficiency, much like
        ## ``TagId`` s. The actual anchor name can be queried with
        ## `anchor <#anchor,YamlSequentialParser,AnchorId>`_.
    
    YamlStreamEvent* = object
        ## An element from a `YamlStream <#YamlStream>`_. Events that start an
        ## object (``yamlStartMap``, ``yamlStartSequence``, ``yamlScalar``) have
        ## an optional anchor and a tag associated with them. The anchor will be
        ## set to ``yAnchorNone`` if it doesn't exist.
        ## 
        ## A non-existing tag in the YAML character stream will be resolved to 
        ## the non-specific tags ``?`` or ``!`` according to the YAML
        ## specification. These are by convention mapped to the ``TagId`` s
        ## ``yTagQuestionMark`` and ``yTagExclamationMark`` respectively.
        ## Mapping is done by a `YamlTagLibrary <#YamlTagLibrary>`_.
        ##
        ## The value ``mapMayHaveKeyObjects`` is a hint from a serializer and is
        ## used for choosing an appropriate presentation mode for a YAML map
        ## (flow or block, explicit or implicit) by
        ## `dump <#dump,YamlStream,Stream,YamlTagLibrary,YamlDumpStyle,int>`_.
        ## If it is set to ``false``, the map may only have scalars as keys.
        ##
        ## The value ``scalarType`` is a hint from the lexer, see
        ## `YamlTypeHint <#YamlTypeHint>`_.
        case kind*: YamlStreamEventKind
        of yamlStartMap:
            mapAnchor* : AnchorId
            mapTag*    : TagId
            mapMayHaveKeyObjects* : bool
        of yamlStartSequence:
            seqAnchor* : AnchorId
            seqTag*    : TagId
        of yamlScalar:
            scalarAnchor* : AnchorId
            scalarTag*    : TagId
            scalarContent*: string # may not be nil (but empty)
            scalarType*   : YamlTypeHint
        of yamlEndMap, yamlEndSequence, yamlStartDocument, yamlEndDocument:
            discard
        of yamlAlias:
            aliasTarget* : AnchorId
        of yamlError, yamlWarning:
            description* : string
            line*        : int
            column*      : int
    
    YamlStream* = iterator(): YamlStreamEvent ## \
        ## A ``YamlStream`` is an iterator that yields a well-formed stream of
        ## ``YamlStreamEvents``. Well-formed means that every ``yamlStartMap``
        ## is terminated by a ``yamlEndMap``, every ``yamlStartSequence`` is
        ## terminated by a ``yamlEndSequence`` and every ``yamlStartDocument``
        ## is terminated by a ``yamlEndDocument``. The only exception to this
        ## rule is a ``yamlError``, which may occur anywhere in the stream and
        ## must be the last element in the stream, which may leave any number of
        ## objects open.
        ##
        ## A ``yamlWarning`` may also occur anywhere in the stream, but will not
        ## invalidate the structure of the event stream, and may not abruptly
        ## end the stream as ``yamlError`` does.
        ##
        ## The creator of a ``YamlStream`` is responsible for it being
        ## well-formed. A user of the stream may assume that it is well-formed
        ## and is not required to check for it. The procs in this module will
        ## always yield a well-formed ``YamlStream`` and expect it to be
        ## well-formed if it's an input.
    
    YamlTagLibrary* = object
        ## A ``YamlTagLibrary`` maps tag URIs to ``TagId`` s. YAML tag URIs
        ## that are defined in the YAML specification or in the
        ## `YAML tag repository <http://yaml.org/type/>`_ should be mapped to
        ## the ``TagId`` s defined as constants in this module.
        ##
        ## Three tag libraries are provided with this module:
        ## `failsafeTagLibrary <#failsafeTagLibrary>`_, 
        ## `coreTagLibrary <#coreTagLibrary>`_, and 
        ## `extendedTagLibrary <#extendedTagLibrary>`_.
        ##
        ## If the ``YamlSequentialParser`` encounters a tag which is not part of
        ## the ``YamlTagLibrary``, it will create a new ``TagId`` equal to
        ## ``nextCustomTagId`` and increase that variable. It will be
        ## initialized to `yFirstCustomTagId <#yFirstCustomTagId>`_. If you do
        ## not want to allow unknown tag URIs to be processed, just abort
        ## processing as soon as you encounter the ``yFirstCustomTagId``.
        ##
        ## It is highly recommended to base any ``YamlTagLibrary`` on at least
        ## ``coreTagLibrary``. But it is also possible to use a completely empty
        ## library and treat all URIs as custom tags.
        tags*: Table[string, TagId]
        nextCustomTagId*: TagId 
    
    YamlSequentialParser* = ref object
        ## A parser object. Retains its ``YamlTagLibrary`` across calls to
        ## `parse <#parse,YamlSequentialParser,Stream,YamlStream>`_. Can be used
        ## to access anchor names while parsing a YAML character stream, but
        ## only until the document goes out of scope (i.e. until
        ## ``yamlEndDocument`` is yielded).
        tagLib: YamlTagLibrary
        anchors: OrderedTable[string, AnchorId]
    
    YamlDumpStyle* = enum
        ## Different output styles to use for dumping YAML character streams.
        ##
        ## - ``yDumpMinimal``: Single-line flow-only output which tries to
        ##   use as few characters as possible.
        ## - ``yDumpCanonical``: Canonical YAML output. Writes all tags except
        ##   for the non-specific tags ``?`` and ``!``, uses flow style, quotes
        ##   all string scalars.
        ## - ``yDumpDefault``: Tries to be as human-readable as possible. Uses
        ##   block style by default, but tries to condense maps and sequences
        ##   which only contain scalar nodes into a single line using flow
        ##   style.
        ## - ``yDumpJson``: Omits the ``%YAML`` directive and the ``---``
        ##   marker. Uses flow style. Flattens anchors and aliases, omits tags.
        ##   Output will be parseable as JSON. ``YamlStream`` to dump may only
        ##   contain one document.
        yDumpMinimal, yDumpCanonical, yDumpDefault, yDumpJson, yDumpBlockOnly
const
    # failsafe schema

    yTagExclamationMark*: TagId = 0.TagId ## ``!`` non-specific tag
    yTagQuestionMark*   : TagId = 1.TagId ## ``?`` non-specific tag
    yTagString*         : TagId = 2.TagId ## \
        ## `!!str <http://yaml.org/type/str.html >`_ tag
    yTagSequence*       : TagId = 3.TagId ## \
        ## `!!seq <http://yaml.org/type/seq.html>`_ tag
    yTagMap*            : TagId = 4.TagId ## \
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
    
    yFirstCustomTagId* : TagId = 1000.TagId ## \
        ## The first ``TagId`` which should be assigned to an URI that does not
        ## exist in the ``YamlTagLibrary`` which is used for parsing.
    
    yAnchorNone*: AnchorId = (-1).AnchorId ## \
        ## yielded when no anchor was defined for a YAML node

# interface

proc `==`*(left: YamlStreamEvent, right: YamlStreamEvent): bool
    ## compares all existing fields of the given items
    
proc `$`*(event: YamlStreamEvent): string
    ## outputs a human-readable string describing the given event

proc `==`*(left, right: TagId): bool {.borrow.}
proc `$`*(id: TagId): string {.borrow.}
proc hash*(id: TagId): Hash {.borrow.}

proc `==`*(left, right: AnchorId): bool {.borrow.}
proc `$`*(id: AnchorId): string {.borrow.}
proc hash*(id: AnchorId): Hash {.borrow.}

proc initTagLibrary*(): YamlTagLibrary
    ## initializes the ``tags`` table and sets ``nextCustomTagId`` to
    ## ``yFirstCustomTagId``.

proc registerUri*(tagLib: var YamlTagLibrary, uri: string): TagId
    ## registers a custom tag URI with a ``YamlTagLibrary``. The URI will get
    ## the ``TagId`` ``nextCustomTagId``, which will be incremented.
    
proc uri*(tagLib: YamlTagLibrary, id: TagId): string
    ## retrieve the URI a ``TagId`` maps to.

# these should be consts, but the Nim VM still has problems handling tables
# properly, so we use constructor procs instead.

proc failsafeTagLibrary*(): YamlTagLibrary
    ## Contains only:
    ## - ``!``
    ## - ``?``
    ## - ``!!str``
    ## - ``!!map``
    ## - ``!!seq``
    
proc coreTagLibrary*(): YamlTagLibrary
    ## Contains everything in ``failsafeTagLibrary`` plus:
    ## - ``!!null``
    ## - ``!!bool``
    ## - ``!!int``
    ## - ``!!float``
    
proc extendedTagLibrary*(): YamlTagLibrary
    ## Contains everything in ``coreTagLibrary`` plus:
    ## - ``!!omap``
    ## - ``!!pairs``
    ## - ``!!set``
    ## - ``!!binary``
    ## - ``!!merge``
    ## - ``!!timestamp``
    ## - ``!!value``
    ## - ``!!yaml``

proc newParser*(tagLib: YamlTagLibrary): YamlSequentialParser
    ## Instanciates a parser

proc anchor*(parser: YamlSequentialParser, id: AnchorId): string
    ## Get the anchor name which an ``AnchorId`` maps to

proc parse*(parser: YamlSequentialParser, s: Stream): YamlStream
    ## Parse a YAML character stream. ``s`` must be readable.

proc parseToJson*(s: Stream): seq[JsonNode]
    ## Parse a YAML character stream to the standard library's in-memory JSON
    ## representation. The input may not contain any tags apart from those in
    ## ``coreTagLibrary``. Anchors and aliases will be resolved. Maps in the
    ## input must not contain non-scalars as keys.
    ##
    ## **Warning:** The special float values ``[+-]Inf`` and ``NaN`` will be
    ## parsed into Nim's JSON structure without error. However, they cannot be
    ## rendered to a JSON character stream, because these values are not part
    ## of the JSON specification. Nim's JSON implementation currently does not
    ## check for these values and will output invalid JSON when rendering one
    ## of these values into a JSON character stream.
    
proc parseToJson*(s: string): seq[JsonNode]
    ## see `parseToJson <#parseToJson,Stream,seq[JsonNode]>`_

proc dump*(s: YamlStream, target: Stream, tagLib: YamlTagLibrary,
           style: YamlDumpStyle = yDumpDefault, indentationStep: int = 2)
    ## Convert ``s`` to a YAML character stream and write it to ``target``.
    
proc transform*(input: Stream, output: Stream, style: YamlDumpStyle,
                indentationStep: int = 2)
    ## Parser ``input`` as YAML character stream and then dump it to ``output``
    ## without resolving any tags, anchors and aliases.

# implementation

include private.lexer
include private.tagLibrary
include private.sequential
include private.json
include private.dumper