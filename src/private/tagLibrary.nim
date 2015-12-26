proc initTagLibrary*(): YamlTagLibrary =
    result.tags = initTable[string, TagId]()
    result.nextCustomTagId = 1000.TagId

proc registerUri*(tagLib: var YamlTagLibrary, uri: string): TagId =
    tagLib.tags[uri] = tagLib.nextCustomTagId
    result = tagLib.nextCustomTagId
    tagLib.nextCustomTagId = cast[TagId](cast[int](tagLib.nextCustomTagId) + 1)
    
proc uri*(tagLib: YamlTagLibrary, id: TagId): string =
    for iUri, iId in tagLib.tags.pairs:
        if iId == id:
            return iUri
    raise newException(KeyError, "Unknown tag id: " & $id)

proc failsafeTagLibrary*(): YamlTagLibrary =
    result = initTagLibrary()
    result.tags["!"] = tagExclamationMark
    result.tags["?"] = tagQuestionMark
    result.tags["tag:yaml.org,2002:str"] = tagString
    result.tags["tag:yaml.org,2002:seq"] = tagSequence
    result.tags["tag:yaml.org,2002:map"] = tagMap

proc coreTagLibrary*(): YamlTagLibrary =
    result = failsafeTagLibrary()
    result.tags["tag:yaml.org,2002:null"] = tagNull
    result.tags["tag:yaml.org,2002:bool"] = tagBoolean
    result.tags["tag:yaml.org,2002:int"] = tagInteger
    result.tags["tag:yaml.org,2002:float"] = tagFloat

proc extendedTagLibrary*(): YamlTagLibrary =
    result = coreTagLibrary()
    result.tags["tag:yaml.org,2002:omap"] = tagOrderedMap
    result.tags["tag:yaml.org,2002:pairs"] = tagPairs
    result.tags["tag:yaml.org,2002:binary"] = tagBinary
    result.tags["tag:yaml.org,2002:merge"] = tagMerge
    result.tags["tag:yaml.org,2002:timestamp"] = tagTimestamp
    result.tags["tag:yaml.org,2002:value"] = tagValue
    result.tags["tag:yaml.org,2002:yaml"] = tagYaml
