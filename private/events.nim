#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

proc `==`*(left: YamlStreamEvent, right: YamlStreamEvent): bool =
    if left.kind != right.kind:
        return false
    case left.kind
    of yamlStartDoc, yamlEndDoc, yamlEndMap, yamlEndSeq: result = true
    of yamlStartMap:
        result = left.mapAnchor == right.mapAnchor and
                 left.mapTag == right.mapTag
    of yamlStartSeq:
        result = left.seqAnchor == right.seqAnchor and
                 left.seqTag == right.seqTag
    of yamlScalar:
        result = left.scalarAnchor == right.scalarAnchor and
                 left.scalarTag == right.scalarTag and
                 left.scalarContent == right.scalarContent
    of yamlAlias: result = left.aliasTarget == right.aliasTarget

proc `$`*(event: YamlStreamEvent): string =
    result = $event.kind & '('
    case event.kind
    of yamlEndMap, yamlEndSeq, yamlStartDoc, yamlEndDoc: discard
    of yamlStartMap:
        result &= "tag=" & $event.mapTag
        if event.mapAnchor != yAnchorNone:
            result &= ", anchor=" & $event.mapAnchor
    of yamlStartSeq:
        result &= "tag=" & $event.seqTag
        if event.seqAnchor != yAnchorNone:
            result &= ", anchor=" & $event.seqAnchor
    of yamlScalar:
        result &= "tag=" & $event.scalarTag
        if event.scalarAnchor != yAnchorNone:
            result &= ", anchor=" & $event.scalarAnchor
        result &= ", content=\"" & event.scalarContent & '\"'
    of yamlAlias:
        result &= "aliasTarget=" & $event.aliasTarget
    result &= ")"

proc tag*(event: YamlStreamEvent): TagId =
    case event.kind
    of yamlStartMap: result = event.mapTag
    of yamlStartSeq: result = event.seqTag
    of yamlScalar: result = event.scalarTag
    else: raise newException(FieldError, "Event " & $event.kind & " has no tag")

proc startDocEvent*(): YamlStreamEvent =
    result = YamlStreamEvent(kind: yamlStartDoc)
    
proc endDocEvent*(): YamlStreamEvent =
    result = YamlStreamEvent(kind: yamlEndDoc)
    
proc startMapEvent*(tag: TagId = yTagQuestionMark,
                    anchor: AnchorId = yAnchorNone): YamlStreamEvent =
    result = YamlStreamEvent(kind: yamlStartMap, mapTag: tag, mapAnchor: anchor)
                             
proc endMapEvent*(): YamlStreamEvent =
    result = YamlStreamEvent(kind: yamlEndMap)
    
proc startSeqEvent*(tag: TagId = yTagQuestionMark,
                    anchor: AnchorId = yAnchorNone): YamlStreamEvent =
    result = YamlStreamEvent(kind: yamlStartSeq, seqTag: tag,
                             seqAnchor: anchor)
                             
proc endSeqEvent*(): YamlStreamEvent =
    result = YamlStreamEvent(kind: yamlEndSeq)
    
proc scalarEvent*(content: string = "", tag: TagId = yTagQuestionMark,
                  anchor: AnchorId = yAnchorNone): YamlStreamEvent =
    result = YamlStreamEvent(kind: yamlScalar, scalarTag: tag,
                             scalarAnchor: anchor, scalarContent: content)

proc aliasEvent*(anchor: AnchorId): YamlStreamEvent =
  result = YamlStreamEvent(kind: yamlAlias, aliasTarget: anchor)