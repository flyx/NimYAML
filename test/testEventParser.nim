#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import ../yaml, ../yaml/data, ../yaml/private/internal
import lexbase, streams, tables, strutils

type
  LexerToken = enum
    plusStr, minusStr, plusDoc, minusDoc, plusMap, minusMap, plusSeq, minusSeq,
    eqVal, eqAli, chevTag, andAnchor, starAnchor, colonContent, sqContent,
    dqContent, litContent, foContent,
    explDirEnd, explDocEnd, noToken

  StreamPos = enum
    beforeStream, inStream, afterStream

  EventLexer = object of BaseLexer
    content: string

  EventStreamError = object of ValueError

proc nextToken(lex: var EventLexer): LexerToken =
  while true:
    case lex.buf[lex.bufpos]
    of ' ', '\t': lex.bufpos.inc()
    of '\r': lex.bufpos = lex.handleCR(lex.bufpos)
    of '\l': lex.bufpos = lex.handleLF(lex.bufpos)
    else: break
  if lex.buf[lex.bufpos] == EndOfFile: return noToken
  case lex.buf[lex.bufpos]
  of ':', '"', '\'', '|', '>':
    let t = case lex.buf[lex.bufpos]
    of ':': colonContent
    of '"': dqContent
    of '\'': sqContent
    of '|': litContent
    of '>': foContent
    else: colonContent

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
      if lex.buf[lex.bufpos] == EndOfFile:
        raise newException(EventStreamError, "Unclosed tag URI!")
    result = chevTag
    lex.bufpos.inc()
  of '&':
    lex.content = ""
    lex.bufpos.inc()
    while lex.buf[lex.bufpos] notin {' ', '\t', '\r', '\l', EndOfFile}:
      lex.content.add(lex.buf[lex.bufpos])
      lex.bufpos.inc()
    result = andAnchor
  of '*':
    lex.content = ""
    lex.bufpos.inc()
    while lex.buf[lex.bufpos] notin {' ', '\t', '\r', '\l', EndOfFile}:
      lex.content.add(lex.buf[lex.bufpos])
      lex.bufpos.inc()
    result = starAnchor
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
    of "---": result = explDirEnd
    of "...": result = explDocEnd
    else: raise newException(EventStreamError, "Invalid token: " & lex.content)

template assertInEvent(name: string) {.dirty.} =
  if not inEvent:
    raise newException(EventStreamError, "Illegal token: " & name)

template yieldEvent() {.dirty.} =
  if inEvent:
    yield curEvent
    inEvent = false

template setTag(t: Tag) {.dirty.} =
  case curEvent.kind
  of yamlStartSeq: curEvent.seqProperties.tag = t
  of yamlStartMap: curEvent.mapProperties.tag = t
  of yamlScalar: curEvent.scalarProperties.tag = t
  else: discard

template setAnchor(a: Anchor) {.dirty.} =
  case curEvent.kind
  of yamlStartSeq: curEvent.seqProperties.anchor = a
  of yamlStartMap: curEvent.mapProperties.anchor = a
  of yamlScalar: curEvent.scalarProperties.anchor = a
  of yamlAlias: curEvent.aliasTarget = a
  else: discard

template curTag(): Tag =
  var foo: Tag
  case curEvent.kind
  of yamlStartSeq: foo = curEvent.seqProperties.tag
  of yamlStartMap: foo = curEvent.mapProperties.tag
  of yamlScalar: foo = curEvent.scalarProperties.tag
  else: raise newException(EventStreamError,
                           $curEvent.kind & " may not have a tag")
  foo

template setCurTag(val: Tag) =
  case curEvent.kind
  of yamlStartSeq: curEvent.seqProperties.tag = val
  of yamlStartMap: curEvent.mapProperties.tag = val
  of yamlScalar: curEvent.scalarProperties.tag = val
  else: raise newException(EventStreamError,
                           $curEvent.kind & " may not have a tag")

template curAnchor(): Anchor =
  var foo: Anchor
  case curEvent.kind
  of yamlStartSeq: foo = curEvent.seqProperties.anchor
  of yamlStartMap: foo = curEvent.mapProperties.anchor
  of yamlScalar: foo = curEvent.scalarProperties.anchor
  of yamlAlias: foo = curEvent.aliasTarget
  else: raise newException(EventStreamError,
                           $curEvent.kind & "may not have an anchor")
  foo

template setCurAnchor(val: Anchor) =
  case curEvent.kind
  of yamlStartSeq: curEvent.seqProperties.anchor = val
  of yamlStartMap: curEvent.mapProperties.anchor = val
  of yamlScalar: curEvent.scalarProperties.anchor = val
  of yamlAlias: curEvent.aliasTarget = val
  else: raise newException(EventStreamError,
                           $curEvent.kind & " may not have an anchor")

template eventStart(k: EventKind) {.dirty.} =
  if streamPos == beforeStream:
    yield Event(kind: yamlStartStream)
    streamPos = inStream
  else: yieldEvent()
  curEvent = Event(kind: k)
  setTag(yTagQuestionMark)
  setAnchor(yAnchorNone)
  inEvent = true

proc parseEventStream*(input: Stream, tagLib: TagLibrary): YamlStream =
  var backend = iterator(): Event =
    var lex: EventLexer
    lex.open(input)
    var
      inEvent = false
      curEvent: Event
      streamPos: StreamPos = beforeStream
    while lex.buf[lex.bufpos] != EndOfFile:
      let token = lex.nextToken()
      case token
      of plusStr:
        if streamPos != beforeStream:
          raise newException(EventStreamError, "Illegal +STR")
        streamPos = inStream
        eventStart(yamlStartStream)
      of minusStr:
        if streamPos != inStream:
          raise newException(EventStreamError, "Illegal -STR")
        streamPos = afterStream
        eventStart(yamlEndStream)
      of plusDoc: eventStart(yamlStartDoc)
      of minusDoc: eventStart(yamlEndDoc)
      of plusMap: eventStart(yamlStartMap)
      of minusMap: eventStart(yamlEndMap)
      of plusSeq: eventStart(yamlStartSeq)
      of minusSeq: eventStart(yamlEndSeq)
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
        setCurAnchor(lex.content.Anchor)
      of starAnchor:
        assertInEvent("alias")
        if curEvent.kind != yamlAlias:
          raise newException(EventStreamError, "Unexpected alias: " &
              escape(lex.content))
        elif curEvent.aliasTarget != yAnchorNone:
          raise newException(EventStreamError, "Duplicate alias target: " &
              escape(lex.content))
        else:
          curEvent.aliasTarget = lex.content.Anchor
      of colonContent:
        assertInEvent("scalar content")
        curEvent.scalarContent = lex.content
        if curEvent.kind != yamlScalar:
          raise newException(EventStreamError,
                             "scalar content in non-scalar tag")
      of sqContent:
        assertInEvent("scalar content")
        curEvent.scalarContent = lex.content
        if curTag() == yTagQuestionMark: setCurTag(yTagExclamationMark)
        curEvent.scalarStyle = ssSingleQuoted
      of dqContent:
        assertInEvent("scalar content")
        curEvent.scalarContent = lex.content
        if curTag() == yTagQuestionMark: setCurTag(yTagExclamationMark)
        curEvent.scalarStyle = ssDoubleQuoted
      of litContent:
        assertInEvent("scalar content")
        curEvent.scalarContent = lex.content
        curEvent.scalarStyle = ssLiteral
      of foContent:
        assertInEvent("scalar content")
        curEvent.scalarContent = lex.content
        curEvent.scalarStyle = ssFolded
      of explDirEnd:
        assertInEvent("explicit directives end")
        if curEvent.kind != yamlStartDoc:
          raise newException(EventStreamError,
                             "Unexpected explicit directives end")
      of explDocEnd:
        if curEvent.kind != yamlEndDoc:
          raise newException(EventStreamError,
                             "Unexpected explicit document end")
      of noToken: discard
    yieldEvent()
    if streamPos == inStream:
      yield Event(kind: yamlEndStream)
  result = initYamlStream(backend)