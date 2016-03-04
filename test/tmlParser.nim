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
        minusSeq, eqVal, chevTag, quotContent, colonContent, noToken
    
    StreamPos = enum
        beforeStream, inStream, afterStream

    TmlLexer = object of BaseLexer
        content: string
    
    TmlError = object of Exception

proc nextToken(lex: var TmlLexer): LexerToken =
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
                of '\\': lex.content.add('\\')
                else: raise newException(TmlError,
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
    else:
        lex.content = ""
        while lex.buf[lex.bufpos] notin {' ', '\t', '\r', '\l', '\0'}:
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
        else: raise newException(TmlError, "Invalid token: " & lex.content)

template assertInStream() {.dirty.} =
    if streamPos != inStream: raise newException(TmlError, "Missing +STR")

template assertInEvent(name: string) {.dirty.} =
    if not inEvent: raise newException(TmlError, "Illegal token: " & name)

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
    else: discard

template curTag(): TagId =
    var foo: TagId
    case curEvent.kind
    of yamlStartSequence: foo = curEvent.seqTag
    of yamlStartMap: foo = curEvent.mapTag
    of yamlScalar: foo = curEvent.scalarTag
    else: raise newException(TmlError, $curEvent.kind & " may not have a tag")
    foo

template setCurTag(val: TagId) =
    case curEvent.kind
    of yamlStartSequence: curEvent.seqTag = val
    of yamlStartMap: curEvent.mapTag = val
    of yamlScalar: curEvent.scalarTag = val
    else: raise newException(TmlError, $curEvent.kind & " may not have a tag")
        
template eventStart(k: YamlStreamEventKind) {.dirty.} =
    assertInStream()
    yieldEvent()
    reset(curEvent)
    curEvent.kind = k
    setTag(yTagQuestionMark)
    setAnchor(yAnchorNone)
    inEvent = true

proc parseTmlStream*(input: Stream, tagLib: TagLibrary): YamlStream =
    var backend = iterator(): YamlStreamEvent =
        var lex: TmlLexer
        lex.open(input)
        var
            inEvent = false
            curEvent: YamlStreamEvent
            streamPos = beforeStream
        while lex.buf[lex.bufpos] != EndOfFile:
            let token = lex.nextToken()
            case token
            of plusStr:
                if streamPos != beforeStream:
                    raise newException(TmlError, "Illegal +STR")
                streamPos = inStream
            of minusStr:
                if streamPos != inStream:
                    raise newException(TmlError, "Illegal -STR")
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
            of chevTag:
                assertInEvent("tag")
                if curTag() != yTagQuestionMark:
                    raise newException(TmlError, "Duplicate tag")
                try:
                  setCurTag(tagLib.tags[lex.content])
                except KeyError: setCurTag(tagLib.registerUri(lex.content))
            of quotContent:
                assertInEvent("scalar content")
                if curTag() == yTagQuestionMark: setCurTag(yTagExclamationMark)
                if curEvent.kind != yamlScalar:
                    raise newException(TmlError,
                            "scalar content in non-scalar tag")
                curEvent.scalarContent = lex.content
            of colonContent:
                assertInEvent("scalar content")
                curEvent.scalarContent = lex.content
                if curEvent.kind != yamlScalar:
                    raise newException(TmlError,
                            "scalar content in non-scalar tag")
            of noToken: discard
    result = initYamlStream(backend)