#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ==================
## Module yaml/taglib
## ==================
##
## The taglib API enables you to define custom tags for the types you are
## using with the serialization API.

import macros
import data

template n(suffix: string): Tag = Tag(nimyamlTagRepositoryPrefix & suffix)

var
  registeredUris {.compileTime.} = newSeq[string]() ## \
    ## Since Table doesn't really work at compile time, we also store
    ## registered URIs here to be able to generate a static compiler error
    ## when the user tries to register an URI more than once.

template setTag*(t: typedesc, tag: Tag) =
  ## Associate the given uri with a certain type. This uri is used as YAML tag
  ## when loading and dumping values of this type.
  when $tag in registeredUris:
    {. fatal: "[NimYAML] URI \"" & uri & "\" registered twice!" .}
  const tconst {.genSym.} = tag
  static:
    registeredUris.add($tag)
  proc yamlTag*(T: typedesc[t]): Tag {.inline, raises: [].} = tconst
    ## autogenerated

template setTag*(t: typedesc, tag: Tag, idName: untyped) =
  ## Like `setTagUri <#setTagUri.t,typedesc,string>`_, but lets
  ## you choose a symbol for the `TagId <#TagId>`_ of the uri. This is only
  ## necessary if you want to implement serialization / construction yourself.
  when $tag in registeredUris:
    {. fatal: "[NimYAML] URI \"" & uri & "\" registered twice!" .}
  const idName* = tag
  static:
    registeredUris.add($tag)
  proc yamlTag*(T: typedesc[t]): Tag {.inline, raises: [].} = idName
    ## autogenerated

template setTagUri*(t: typedesc; uri: string) {.deprecated: "use setTag".} =
  setTag(t, Tag(uri))
template setTagUri*(t: typedesc; uri: string; idName: untyped)
    {.deprecated: "use setTag".} = setTag(t, Tag(uri), idName)

static:
  # standard YAML tags used by serialization
  registeredUris.add($yTagExclamationMark)
  registeredUris.add($yTagQuestionMark)
  registeredUris.add($yTagString)
  registeredUris.add($yTagNull)
  registeredUris.add($yTagBoolean)
  registeredUris.add($yTagFloat)
  registeredUris.add($yTagTimestamp)
  registeredUris.add($yTagValue)
  registeredUris.add($yTagBinary)
  # special tags used by serialization
  registeredUris.add($yTagNimField)

# tags for Nim's standard types
setTag(char, n"system:char", yTagNimChar)
setTag(int8, n"system:int8", yTagNimInt8)
setTag(int16, n"system:int16", yTagNimInt16)
setTag(int32, n"system:int32", yTagNimInt32)
setTag(int64, n"system:int64", yTagNimInt64)
setTag(uint8, n"system:uint8", yTagNimUInt8)
setTag(uint16, n"system:uint16", yTagNimUInt16)
setTag(uint32, n"system:uint32", yTagNimUInt32)
setTag(uint64, n"system:uint64", yTagNimUInt64)
setTag(float32, n"system:float32", yTagNimFloat32)
setTag(float64, n"system:float64", yTagNimFloat64)

proc nimTag*(suffix: string): Tag =
  ## prepends NimYAML's tag repository prefix to the given suffix. For example,
  ## ``nimTag("system:char")`` yields ``"tag:nimyaml.org,2016:system:char"``.
  Tag(nimyamlTagRepositoryPrefix & suffix)

proc initNimYamlTagHandle*(): seq[tuple[handle, uriPrefix: string]] =
  ## returns a seq describing the tag handle ``!n!`` referencing the NimYAML
  ## tag namespace. Can be used with SerializationOptions.
  result = @[("!n!", nimyamlTagRepositoryPrefix)]