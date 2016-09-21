#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ==================
## Module yaml.taglib
## ==================
##
## The taglib API enables you to query real names of tags emitted by the parser
## and create own tags. It also enables you to define tags for types used with
## the serialization API.

import tables, macros
import common

type
  TagLibrary* = ref object
    ## A ``TagLibrary`` maps tag URIs to ``TagId`` s.
    ##
    ## When `YamlParser <#YamlParser>`_ encounters tags not existing in the
    ## tag library, it will use
    ## `registerUri <#registerUri,TagLibrary,string>`_ to add
    ## the tag to the library.
    ##
    ## You can base your tag library on common tag libraries by initializing
    ## them with `initFailsafeTagLibrary <#initFailsafeTagLibrary>`_,
    ## `initCoreTagLibrary <#initCoreTagLibrary>`_ or
    ## `initExtendedTagLibrary <#initExtendedTagLibrary>`_.
    tags*: Table[string, TagId]
    nextCustomTagId*: TagId
    secondaryPrefix*: string

const
  # failsafe schema

  yTagExclamationMark*: TagId = 0.TagId ## ``!`` non-specific tag
  yTagQuestionMark*   : TagId = 1.TagId ## ``?`` non-specific tag
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

  yTagNimNilString* : TagId = 101.TagId ## for strings that are nil
  yTagNimNilSeq*    : TagId = 102.TagId ## \
    ## for seqs that are nil. This tag is used regardless of the seq's generic
    ## type parameter.

  yFirstCustomTagId* : TagId = 1000.TagId ## \
    ## The first ``TagId`` which should be assigned to an URI that does not
    ## exist in the ``YamlTagLibrary`` which is used for parsing.

  yAnchorNone*: AnchorId = (-1).AnchorId ## \
    ## yielded when no anchor was defined for a YAML node

  yamlTagRepositoryPrefix* = "tag:yaml.org,2002:"

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

proc initTagLibrary*(): TagLibrary {.raises: [].} =
  ## initializes the ``tags`` table and sets ``nextCustomTagId`` to
  ## ``yFirstCustomTagId``.
  new(result)
  result.tags = initTable[string, TagId]()
  result.secondaryPrefix = yamlTagRepositoryPrefix
  result.nextCustomTagId = yFirstCustomTagId

proc registerUri*(tagLib: TagLibrary, uri: string): TagId {.raises: [].} =
  ## registers a custom tag URI with a ``TagLibrary``. The URI will get
  ## the ``TagId`` ``nextCustomTagId``, which will be incremented.
  tagLib.tags[uri] = tagLib.nextCustomTagId
  result = tagLib.nextCustomTagId
  tagLib.nextCustomTagId = cast[TagId](cast[int](tagLib.nextCustomTagId) + 1)

proc uri*(tagLib: TagLibrary, id: TagId): string {.raises: [KeyError].} =
  ## retrieve the URI a ``TagId`` maps to.
  for iUri, iId in tagLib.tags.pairs:
    if iId == id: return iUri
  raise newException(KeyError, "Unknown tag id: " & $id)

proc initFailsafeTagLibrary*(): TagLibrary {.raises: [].} =
  ## Contains only:
  ## - ``!``
  ## - ``?``
  ## - ``!!str``
  ## - ``!!map``
  ## - ``!!seq``
  result = initTagLibrary()
  result.tags["!"] = yTagExclamationMark
  result.tags["?"] = yTagQuestionMark
  result.tags["tag:yaml.org,2002:str"] = yTagString
  result.tags["tag:yaml.org,2002:seq"] = yTagSequence
  result.tags["tag:yaml.org,2002:map"] = yTagMapping

proc initCoreTagLibrary*(): TagLibrary {.raises: [].} =
  ## Contains everything in ``initFailsafeTagLibrary`` plus:
  ## - ``!!null``
  ## - ``!!bool``
  ## - ``!!int``
  ## - ``!!float``
  result = initFailsafeTagLibrary()
  result.tags["tag:yaml.org,2002:null"]  = yTagNull
  result.tags["tag:yaml.org,2002:bool"]  = yTagBoolean
  result.tags["tag:yaml.org,2002:int"]   = yTagInteger
  result.tags["tag:yaml.org,2002:float"] = yTagFloat

proc initExtendedTagLibrary*(): TagLibrary {.raises: [].} =
  ## Contains everything from ``initCoreTagLibrary`` plus:
  ## - ``!!omap``
  ## - ``!!pairs``
  ## - ``!!set``
  ## - ``!!binary``
  ## - ``!!merge``
  ## - ``!!timestamp``
  ## - ``!!value``
  ## - ``!!yaml``
  result = initCoreTagLibrary()
  result.tags["tag:yaml.org,2002:omap"]      = yTagOrderedMap
  result.tags["tag:yaml.org,2002:pairs"]     = yTagPairs
  result.tags["tag:yaml.org,2002:binary"]    = yTagBinary
  result.tags["tag:yaml.org,2002:merge"]     = yTagMerge
  result.tags["tag:yaml.org,2002:timestamp"] = yTagTimestamp
  result.tags["tag:yaml.org,2002:value"]     = yTagValue
  result.tags["tag:yaml.org,2002:yaml"]      = yTagYaml


proc initSerializationTagLibrary*(): TagLibrary =
  result = initTagLibrary()
  result.tags["!"] = yTagExclamationMark
  result.tags["?"] = yTagQuestionMark
  result.tags["tag:yaml.org,2002:str"]       = yTagString
  result.tags["tag:yaml.org,2002:null"]      = yTagNull
  result.tags["tag:yaml.org,2002:bool"]      = yTagBoolean
  result.tags["tag:yaml.org,2002:float"]     = yTagFloat
  result.tags["tag:yaml.org,2002:timestamp"] = yTagTimestamp
  result.tags["tag:yaml.org,2002:value"]     = yTagValue
  result.tags["tag:yaml.org,2002:binary"]    = yTagBinary
  result.tags["!nim:field"]                  = yTagNimField
  result.tags["!nim:nil:string"]             = yTagNimNilString
  result.tags["!nim:nil:seq"]                = yTagNimNilSeq

var
  serializationTagLibrary* = initSerializationTagLibrary() ## \
    ## contains all local tags that are used for type serialization. Does
    ## not contain any of the specific default tags for sequences or maps,
    ## as those are not suited for Nim's static type system.
    ##
    ## Should not be modified manually. Will be extended by
    ## `serializable <#serializable,stmt,stmt>`_.

var
  nextStaticTagId {.compileTime.} = 100.TagId ## \
    ## used for generating unique TagIds with ``setTagUri``.
  registeredUris {.compileTime.} = newSeq[string]() ## \
    ## Since Table doesn't really work at compile time, we also store
    ## registered URIs here to be able to generate a static compiler error
    ## when the user tries to register an URI more than once.

template setTagUri*(t: typedesc, uri: string): typed =
  ## Associate the given uri with a certain type. This uri is used as YAML tag
  ## when loading and dumping values of this type.
  when uri in registeredUris:
    {. fatal: "[NimYAML] URI \"" & uri & "\" registered twice!" .}
  const id {.genSym.} = nextStaticTagId
  static:
    registeredUris.add(uri)
    nextStaticTagId = TagId(int(nextStaticTagId) + 1)
  when nextStaticTagId == yFirstCustomTagId:
    {.fatal: "Too many tags!".}
  serializationTagLibrary.tags[uri] = id
  proc yamlTag*(T: typedesc[t]): TagId {.inline, raises: [].} = id
    ## autogenerated

template setTagUri*(t: typedesc, uri: string, idName: untyped): typed =
  ## Like `setTagUri <#setTagUri.t,typedesc,string>`_, but lets
  ## you choose a symbol for the `TagId <#TagId>`_ of the uri. This is only
  ## necessary if you want to implement serialization / construction yourself.
  when uri in registeredUris:
    {. fatal: "[NimYAML] URI \"" & uri & "\" registered twice!" .}
  const idName* = nextStaticTagId
  static:
    registeredUris.add(uri)
    nextStaticTagId = TagId(int(nextStaticTagId) + 1)
  serializationTagLibrary.tags[uri] = idName
  proc yamlTag*(T: typedesc[t]): TagId {.inline, raises: [].} = idName
    ## autogenerated

proc canBeImplicit(t: typedesc): bool {.compileTime.} =
  let tDesc = getType(t)
  if tDesc.kind != nnkObjectTy: return false
  if tDesc[2].len != 1: return false
  if tDesc[2][0].kind != nnkRecCase: return false
  var foundEmptyBranch = false
  for i in 1.. tDesc[2][0].len - 1:
    case tDesc[2][0][i][1].len # branch contents
    of 0:
      if foundEmptyBranch: return false
      else: foundEmptyBranch = true
    of 1: discard
    else: return false
  return true

template markAsImplicit*(t: typedesc): typed =
  ## Mark a variant object type as implicit. This requires the type to consist
  ## of nothing but a case expression and each branch of the case expression
  ## containing exactly one field - with the exception that one branch may
  ## contain zero fields.
  when canBeImplicit(t):
    # this will be checked by means of compiles(implicitVariantObject(...))
    proc implicitVariantObject*(unused: t) = discard
  else:
    {. fatal: "This type cannot be marked as implicit" .}

static:
  # standard YAML tags used by serialization
  registeredUris.add("!")
  registeredUris.add("?")
  registeredUris.add("tag:yaml.org,2002:str")
  registeredUris.add("tag:yaml.org,2002:null")
  registeredUris.add("tag:yaml.org,2002:bool")
  registeredUris.add("tag:yaml.org,2002:float")
  registeredUris.add("tag:yaml.org,2002:timestamp")
  registeredUris.add("tag:yaml.org,2002:value")
  registeredUris.add("tag:yaml.org,2002:binary")
  # special tags used by serialization
  registeredUris.add("!nim:field")
  registeredUris.add("!nim:nil:string")
  registeredUris.add("!nim:nil:seq")

# tags for Nim's standard types
setTagUri(char, "!nim:system:char", yTagNimChar)
setTagUri(int8, "!nim:system:int8", yTagNimInt8)
setTagUri(int16, "!nim:system:int16", yTagNimInt16)
setTagUri(int32, "!nim:system:int32", yTagNimInt32)
setTagUri(int64, "!nim:system:int64", yTagNimInt64)
setTagUri(uint8, "!nim:system:uint8", yTagNimUInt8)
setTagUri(uint16, "!nim:system:uint16", yTagNimUInt16)
setTagUri(uint32, "!nim:system:uint32", yTagNimUInt32)
setTagUri(uint64, "!nim:system:uint64", yTagNimUInt64)
setTagUri(float32, "!nim:system:float32", yTagNimFloat32)
setTagUri(float64, "!nim:system:float64", yTagNimFloat64)