#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

proc `==`*(left: YamlStreamEvent, right: YamlStreamEvent): bool =
    if left.kind != right.kind:
        return false
    case left.kind
    of yamlStartDocument, yamlEndDocument, yamlEndMap, yamlEndSequence:
        result = true
    of yamlStartMap:
        result = left.mapAnchor == right.mapAnchor and
                 left.mapTag == right.mapTag
    of yamlStartSequence:
        result = left.seqAnchor == right.seqAnchor and
                 left.seqTag == right.seqTag
    of yamlScalar:
        result = left.scalarAnchor == right.scalarAnchor and
                 left.scalarTag == right.scalarTag and
                 left.scalarContent == right.scalarContent and
                 left.scalarType == right.scalarType
    of yamlAlias:
        result = left.aliasTarget == right.aliasTarget

proc `$`*(event: YamlStreamEvent): string =
    result = $event.kind & '('
    case event.kind
    of yamlEndMap, yamlEndSequence, yamlStartDocument, yamlEndDocument:
        discard
    of yamlStartMap:
        result &= "tag=" & $event.mapTag
        if event.mapAnchor != yAnchorNone:
            result &= ", anchor=" & $event.mapAnchor
    of yamlStartSequence:
        result &= "tag=" & $event.seqTag
        if event.seqAnchor != yAnchorNone:
            result &= ", anchor=" & $event.seqAnchor
    of yamlScalar:
        result &= "tag=" & $event.scalarTag
        if event.scalarAnchor != yAnchorNone:
            result &= ", anchor=" & $event.scalarAnchor
        result &= ", typeHint=" & $event.scalarType
        result &= ", content=\"" & event.scalarContent & '\"'
    of yamlAlias:
        result &= "aliasTarget=" & $event.aliasTarget
    result &= ")"

proc startDocEvent*(): YamlStreamEvent =
    result = YamlStreamEvent(kind: yamlStartDocument)
    
proc endDocEvent*(): YamlStreamEvent =
    result = YamlStreamEvent(kind: yamlEndDocument)
    
proc startMapEvent*(tag: TagId = yTagQuestionMark,
                    anchor: AnchorId = yAnchorNone): YamlStreamEvent =
    result = YamlStreamEvent(kind: yamlStartMap, mapTag: tag, mapAnchor: anchor)
                             
proc endMapEvent*(): YamlStreamEvent =
    result = YamlStreamEvent(kind: yamlEndMap)
    
proc startSeqEvent*(tag: TagId = yTagQuestionMark,
                    anchor: AnchorId = yAnchorNone): YamlStreamEvent =
    result = YamlStreamEvent(kind: yamlStartSequence, seqTag: tag,
                             seqAnchor: anchor)
                             
proc endSeqEvent*(): YamlStreamEvent =
    result = YamlStreamEvent(kind: yamlEndSequence)
    
proc scalarEvent*(content: string = "", tag: TagId = yTagQuestionMark,
                  anchor: AnchorId = yAnchorNone, 
                  typeHint: YamlTypeHint = yTypeUnknown): YamlStreamEvent =
    result = YamlStreamEvent(kind: yamlScalar, scalarTag: tag,
                             scalarAnchor: anchor, scalarContent: content,
                             scalarType: typeHint)