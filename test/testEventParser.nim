#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import "../yaml"
import lexbase

type
    LexerToken = enum
        plusStr, minusStr, plusDoc, minusDoc, plusMap, minusMap, plusSeq,
        minusSeq, eqVal, eqAli, chevTag, andAnchor, quotContent, colonContent,
        noToken
    
    StreamPos = enum
        beforeStream, inStream, afterStream

    EventLexer = object of BaseLexer
        content: string
    
    EventStreamError = object of Exception

proc nextToken(lex: var EventLexer): LexerToken =
    while true:
        case lex.buf[lex.bufpos]
        of ' ', '\t': lex.bufpos.inc()
        of '\r': lex.bufpos = lex.handleCR(lex.bufpos)
        of '\l': lex.bufpos = lex.handleLF(lex.bufpos)
        else: break
    if lex.buf[lex.bufpos] == EndOfFile: return noToken
    case lex.buf[lex.bufpos]
    of ':', '"':
        let t = if lex.buf[lex.bufpos] == ':': colonContent else: quotContent
        lex.content = ""
        lex.bufpos.inc()
        while true:
            case lex.buf[lex.bufpos]
            of EndOfFile: break
            of '\c':
                lex.bufpos = lex.handleCR(lex.bufpos)
                break
            of '\l':
                lex.bufpos = lex.handleLF(lex.bufpos)
                break
            of '\\':
                lex.bufpos.inc()
                case lex.buf[lex.bufpos]
                of 'n': lex.content.add('\l')
                of 'r': lex.content.add('\r')
                of '0': lex.content.add('\0')
                of 'b': lex.content.add('\b')
                of 't': lex.content.add('\t')
                of '\\': lex.content.add('\\')
                else: raise newException(EventStreamError,
                        "Unknown escape character: " & lex.buf[lex.bufpos])
            else: lex.content.add(lex.buf[lex.bufpos])
            lex.bufpos.inc()
        result = t
    of '<':
        lex.content = ""
        lex.bufpos.inc()
        while lex.buf[lex.bufpos] != '>':
            lex.content.add(lex.buf[lex.bufpos])
            lex.bufpos.inc()
        result = chevTag
        lex.bufpos.inc()
    of '&':
        lex.content = ""
        lex.bufpos.inc()
        while lex.buf[lex.bufpos] notin {' ', '\t', '\r', '\l', EndOfFile}:
            lex.content.add(lex.buf[lex.bufpos])
            lex.bufpos.inc()
        result = andAnchor
    else:
        lex.content = ""
        while lex.buf[lex.bufpos] notin {' ', '\t', '\r', '\l', EndOfFile}:
            lex.content.add(lex.buf[lex.bufpos])
            lex.bufpos.inc()
        case lex.content
        of "+STR": result = plusStr
        of "-STR": result = minusStr
        of "+DOC": result = plusDoc
        of "-DOC": result = minusDoc
        of "+MAP": result = plusMap
        of "-MAP": result = minusMap
        of "+SEQ": result = plusSeq
        of "-SEQ": result = minusSeq
        of "=VAL": result = eqVal
        of "=ALI": result = eqAli
        else: raise newException(EventStreamError,
                                 "Invalid token: " & lex.content)

template assertInStream() {.dirty.} =
    if streamPos != inStream:
        raise newException(EventStreamError, "Missing +STR")

template assertInEvent(name: string) {.dirty.} =
    if not inEvent:
        raise newException(EventStreamError, "Illegal token: " & name)

template yieldEvent() {.dirty.} =
    if inEvent:
        yield curEvent
        inEvent = false

template setTag(t: TagId) {.dirty.} =
    case curEvent.kind
    of yamlStartSequence: curEvent.seqTag = t
    of yamlStartMap: curEvent.mapTag = t
    of yamlScalar: curEvent.scalarTag = t
    else: discard

template setAnchor(a: AnchorId) {.dirty.} =
    case curEvent.kind
    of yamlStartSequence: curEvent.seqAnchor = a
    of yamlStartMap: curEvent.mapAnchor = a
    of yamlScalar: curEvent.scalarAnchor = a
    of yamlAlias: curEvent.aliasTarget = a
    else: discard

template curTag(): TagId =
    var foo: TagId
    case curEvent.kind
    of yamlStartSequence: foo = curEvent.seqTag
    of yamlStartMap: foo = curEvent.mapTag
    of yamlScalar: foo = curEvent.scalarTag
    else: raise newException(EventStreamError,
                             $curEvent.kind & " may not have a tag")
    foo

template setCurTag(val: TagId) =
    case curEvent.kind
    of yamlStartSequence: curEvent.seqTag = val
    of yamlStartMap: curEvent.mapTag = val
    of yamlScalar: curEvent.scalarTag = val
    else: raise newException(EventStreamError,
                             $curEvent.kind & " may not have a tag")

template curAnchor(): AnchorId =
    var foo: AnchorId
    case curEvent.kind
    of yamlStartSequence: foo = curEvent.seqAnchor
    of yamlStartMap: foo = curEvent.mapAnchor
    of yamlScalar: foo = curEvent.scalarAnchor
    of yamlAlias: foo = curEvent.aliasTarget
    else: raise newException(EventStreamError,
                             $curEvent.kind & "may not have an anchor")
    foo

template setCurAnchor(val: AnchorId) =
    case curEvent.kind
    of yamlStartSequence: curEvent.seqAnchor = val
    of yamlStartMap: curEvent.mapAnchor = val
    of yamlScalar: curEvent.scalarAnchor = val
    of yamlAlias: curEvent.aliasTarget = val
    else: raise newException(EventStreamError,
                             $curEvent.kind & " may not have an anchor")
 
template eventStart(k: YamlStreamEventKind) {.dirty.} =
    assertInStream()
    yieldEvent()
    reset(curEvent)
    curEvent.kind = k
    setTag(yTagQuestionMark)
    setAnchor(yAnchorNone)
    inEvent = true

proc parseEventStream*(input: Stream, tagLib: TagLibrary): YamlStream =
    var backend = iterator(): YamlStreamEvent =
        var lex: EventLexer
        lex.open(input)
        var
            inEvent = false
            curEvent: YamlStreamEvent
            streamPos = beforeStream
            anchors = initTable[string, AnchorId]()
            nextAnchorId = 0.AnchorId
        while lex.buf[lex.bufpos] != EndOfFile:
            let token = lex.nextToken()
            case token
            of plusStr:
                if streamPos != beforeStream:
                    raise newException(EventStreamError, "Illegal +STR")
                streamPos = inStream
            of minusStr:
                if streamPos != inStream:
                    raise newException(EventStreamError, "Illegal -STR")
                if inEvent: yield curEvent
                inEvent = false
                streamPos = afterStream
            of plusDoc: eventStart(yamlStartDocument)
            of minusDoc: eventStart(yamlEndDocument)
            of plusMap: eventStart(yamlStartMap)
            of minusMap: eventStart(yamlEndMap)
            of plusSeq: eventStart(yamlStartSequence)
            of minusSeq: eventStart(yamlEndSequence)
            of eqVal: eventStart(yamlScalar)
            of eqAli: eventStart(yamlAlias)
            of chevTag:
                assertInEvent("tag")
                if curTag() != yTagQuestionMark:
                    raise newException(EventStreamError,
                                       "Duplicate tag in " & $curEvent.kind)
                try:
                  setCurTag(tagLib.tags[lex.content])
                except KeyError: setCurTag(tagLib.registerUri(lex.content))
            of andAnchor:
                assertInEvent("anchor")
                if curAnchor() != yAnchorNone:
                    raise newException(EventStreamError,
                                       "Duplicate anchor in " & $curEvent.kind)
                if curEvent.kind == yamlAlias:
                    curEvent.aliasTarget = anchors[lex.content]
                else:
                    anchors[lex.content] = nextAnchorId
                    setCurAnchor(nextAnchorId)
                    nextAnchorId = (AnchorId)(((int)nextAnchorId) + 1)
            of quotContent:
                assertInEvent("scalar content")
                if curTag() == yTagQuestionMark: setCurTag(yTagExclamationMark)
                if curEvent.kind != yamlScalar:
                    raise newException(EventStreamError,
                            "scalar content in non-scalar tag")
                curEvent.scalarContent = lex.content
            of colonContent:
                assertInEvent("scalar content")
                curEvent.scalarContent = lex.content
                if curEvent.kind != yamlScalar:
                    raise newException(EventStreamError,
                            "scalar content in non-scalar tag")
            of noToken: discard
    result = initYamlStream(backend)