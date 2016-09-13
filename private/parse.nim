#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

type
  FastParseLevelKind = enum
    fplUnknown, fplSequence, fplMapKey, fplMapValue, fplSinglePairKey,
    fplSinglePairValue, fplDocument

  FastParseLevel = object
    kind: FastParseLevelKind
    indentation: int

  ParserContext = ref object of YamlStream
    p: YamlParser
    lex: YamlLexer
    storedState: proc(s: YamlStream, e: var YamlStreamEvent): bool
    atSequenceItem: bool
    flowdepth: int
    ancestry: seq[FastParseLevel]
    level: FastParseLevel
    tag: TagId
    anchor: AnchorId
    shorthands: Table[string, string]
    nextAnchorId: AnchorId
    newlines: int
    explicitFlowKey: bool

  LevelEndResult = enum
    lerNothing, lerOne, lerAdditionalMapEnd

proc newYamlParser*(tagLib: TagLibrary = initExtendedTagLibrary(),
                    callback: WarningCallback = nil): YamlParser =
  new(result)
  result.tagLib = tagLib
  result.callback = callback

template debug(message: string) {.dirty.} =
  when defined(yamlDebug):
    try: styledWriteLine(stdout, fgBlue, message)
    except IOError: discard

proc generateError(c: ParserContext, message: string):
    ref YamlParserError {.raises: [].} =
  result = newException(YamlParserError, message)
  (result.line, result.column) = c.lex.curStartPos
  result.lineContent = c.lex.getTokenLine()

proc illegalToken(c: ParserContext, expected: string = ""):
    ref YamlParserError {.raises: [].} =
  var msg = "Illegal token"
  if expected.len > 0: msg.add(" (expected " & expected & ")")
  msg.add(": " & $c.lex.cur)
  result = c.generateError(msg)

proc callCallback(c: ParserContext, msg: string) {.raises: [YamlParserError].} =
  try:
    if not isNil(c.p.callback):
      c.p.callback(c.lex.curStartPos.line, c.lex.curStartPos.column,
          c.lex.getTokenLine(), msg)
  except:
    var e = newException(YamlParserError,
        "Warning callback raised exception: " & getCurrentExceptionMsg())
    e.parent = getCurrentException()
    raise e

proc initLevel(k: FastParseLevelKind): FastParseLevel {.raises: [], inline.} =
  FastParseLevel(kind: k, indentation: UnknownIndentation)

proc emptyScalar(c: ParserContext): YamlStreamEvent {.raises: [], inline.} =
  result = scalarEvent("", c.tag, c.anchor)
  c.tag = yTagQuestionMark
  c.anchor = yAnchorNone

proc currentScalar(c: ParserContext): YamlStreamEvent {.raises: [], inline.} =
  result = YamlStreamEvent(kind: yamlScalar, scalarTag: c.tag,
                           scalarAnchor: c.anchor)
  shallowCopy(result.scalarContent, c.lex.buf)
  c.lex.buf = cast[string not nil](newStringOfCap(256))
  c.tag = yTagQuestionMark
  c.anchor = yAnchorNone

proc objectStart(c: ParserContext, k: static[YamlStreamEventKind],
                 single: bool = false): YamlStreamEvent {.raises: [].} =
  yAssert(c.level.kind == fplUnknown)
  when k == yamlStartMap:
    result = startMapEvent(c.tag, c.anchor)
    if single:
      debug("started single-pair map at " &
          (if c.level.indentation == UnknownIndentation:
              $c.lex.indentation else: $c.level.indentation))
      c.level.kind = fplSinglePairKey
    else:
      debug("started map at " &
          (if c.level.indentation == UnknownIndentation:
              $c.lex.indentation else: $c.level.indentation))
      c.level.kind = fplMapKey
  else:
    result = startSeqEvent(c.tag, c.anchor)
    debug("started sequence at " &
        (if c.level.indentation == UnknownIndentation: $c.lex.indentation else:
         $c.level.indentation))
    c.level.kind = fplSequence
  c.tag = yTagQuestionMark
  c.anchor = yAnchorNone
  if c.level.indentation == UnknownIndentation:
    c.level.indentation = c.lex.indentation
  c.ancestry.add(c.level)
  c.level = initLevel(fplUnknown)

proc initDocValues(c: ParserContext) {.raises: [].} =
  c.shorthands = initTable[string, string]()
  c.p.anchors = initTable[string, AnchorId]()
  c.shorthands["!"] = "!"
  c.shorthands["!!"] = "tag:yaml.org,2002:"
  c.nextAnchorId = 0.AnchorId
  c.level = initLevel(fplUnknown)
  c.tag = yTagQuestionMark
  c.anchor = yAnchorNone
  c.ancestry.add(FastParseLevel(kind: fplDocument, indentation: -1))

proc advance(c: ParserContext) {.inline.} =
  try: c.lex.next()
  except YamlLexerError:
    let e = (ref YamlLexerError)(getCurrentException())
    let pe = newException(YamlParserError, e.msg)
    pe.line = e.line
    pe.column = e.column
    pe.lineContent = e.lineContent
    raise pe

proc handleAnchor(c: ParserContext) {.raises: [YamlParserError].} =
  if c.level.kind != fplUnknown: raise c.generateError("Unexpected token")
  if c.anchor != yAnchorNone:
    raise c.generateError("Only one anchor is allowed per node")
  c.anchor = c.nextAnchorId
  c.p.anchors[c.lex.buf] = c.anchor
  c.nextAnchorId = AnchorId(int(c.nextAnchorId) + 1)
  c.lex.buf.setLen(0)
  c.advance()

proc continueMultilineScalar(c: ParserContext) {.raises: [].} =
  c.lex.buf.add(if c.newlines == 1: " " else: repeat('\l', c.newlines - 1))
  c.newlines = 0

proc handleTagHandle(c: ParserContext) {.raises: [YamlParserError].} =
  if c.level.kind != fplUnknown: raise c.generateError("Unexpected tag handle")
  if c.tag != yTagQuestionMark:
    raise c.generateError("Only one tag handle is allowed per node")
  if c.lex.cur == ltTagHandle:
    var tagUri = ""
    try:
      tagUri.add(c.shorthands[c.lex.buf[0..c.lex.shorthandEnd]])
      tagUri.add(c.lex.buf[c.lex.shorthandEnd + 1 .. ^1])
    except KeyError:
      raise c.generateError(
          "Undefined tag shorthand: " & c.lex.buf[0..c.lex.shorthandEnd])
    try: c.tag = c.p.tagLib.tags[tagUri]
    except KeyError: c.tag = c.p.tagLib.registerUri(tagUri)
  else:
    try: c.tag = c.p.tagLib.tags[c.lex.buf]
    except KeyError: c.tag = c.p.tagLib.registerUri(c.lex.buf)
  c.lex.buf.setLen(0)
  c.advance()

proc handlePossibleMapStart(c: ParserContext, e: var YamlStreamEvent,
    flow: bool = false, single: bool = false): bool =
  result = false
  if c.level.indentation == UnknownIndentation:
    if c.lex.isImplicitKeyStart():
      e = c.objectStart(yamlStartMap, single)
      result = true
    c.level.indentation = c.lex.indentation

proc handleMapKeyIndicator(c: ParserContext, e: var YamlStreamEvent): bool =
  result = false
  case c.level.kind
  of fplUnknown:
    e = c.objectStart(yamlStartMap)
    result = true
  of fplMapValue:
    if c.level.indentation != c.lex.indentation:
      raise c.generateError("Invalid p.indentation of map key indicator " &
          "(expected" & $c.level.indentation & ", got " & $c.lex.indentation &
          ")")
    e = scalarEvent("", yTagQuestionMark, yAnchorNone)
    result = true
    c.level.kind = fplMapKey
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
  of fplMapKey:
    if c.level.indentation != c.lex.indentation:
      raise c.generateError("Invalid p.indentation of map key indicator")
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
  of fplSequence:
    raise c.generateError("Unexpected map key indicator (expected '- ')")
  of fplSinglePairKey, fplSinglePairValue, fplDocument:
    internalError("Unexpected level kind: " & $c.level.kind)
  c.advance()
  if c.lex.cur != ltIndentation:
    # this enables the parser to properly parse compact structures, like
    # a: - a
    #    - b
    # and such. At the first `-`, the indentation must equal its level to be
    # parsed properly.   
    c.lex.indentation = c.lex.curStartPos.column - 1

proc handleBlockSequenceIndicator(c: ParserContext, e: var YamlStreamEvent):
    bool =
  result = false
  case c.level.kind
  of fplUnknown:
    e = c.objectStart(yamlStartSeq)
    result = true
  of fplSequence:
    if c.level.indentation != c.lex.indentation:
      raise c.generateError(
          "Invalid p.indentation of block sequence indicator (expected " &
          $c.level.indentation & ", got " & $c.lex.indentation & ")")
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
  else: raise c.generateError("Illegal sequence item in map")
  c.advance()
  if c.lex.cur != ltIndentation:
    # see comment in previous proc, this time with structures like
    # - - a
    #   - b
    c.lex.indentation = c.lex.curStartPos.column - 1

proc handleBlockItemStart(c: ParserContext, e: var YamlStreamEvent): bool =
  result = false
  case c.level.kind
  of fplUnknown:
    result = c.handlePossibleMapStart(e)
  of fplSequence:
    raise c.generateError(
        "Unexpected token (expected block sequence indicator)")
  of fplMapKey:
    c.ancestry.add(c.level)
    c.level = FastParseLevel(kind: fplUnknown, indentation: c.lex.indentation)
  of fplMapValue:
    e = emptyScalar(c)
    result = true
    c.level.kind = fplMapKey
    c.ancestry.add(c.level)
    c.level = FastParseLevel(kind: fplUnknown, indentation: c.lex.indentation)
  of fplSinglePairKey, fplSinglePairValue, fplDocument:
    internalError("Unexpected level kind: " & $c.level.kind)

proc handleFlowItemStart(c: ParserContext, e: var YamlStreamEvent): bool =
  if c.level.kind == fplUnknown and
      c.ancestry[c.ancestry.high].kind == fplSequence:
    result = c.handlePossibleMapStart(e, true, true)
  else: result = false

proc handleFlowPlainScalar(c: ParserContext) =
  while c.lex.cur in {ltScalarPart, ltEmptyLine}:
    c.lex.newlines.inc()
    c.advance()
  c.lex.newlines = 0

# --- macros for defining parser states ---

template capitalize(s: string): string =
  when declared(strutils.capitalizeAscii): strutils.capitalizeAscii(s)
  else: strutils.capitalize(s)

macro parserStates(names: varargs[untyped]): typed =
  ## generates proc declaration for each state in list like this:
  ##
  ## proc name(s: YamlStream, e: var YamlStreamEvent):
  ##     bool {.raises: [YamlParserError].}
  result = newStmtList()
  for name in names:
    let nameId = newIdentNode("state" & capitalize($name.ident))
    result.add(newProc(nameId, [ident("bool"), newIdentDefs(ident("s"),
        ident("YamlStream")), newIdentDefs(ident("e"), newNimNode(nnkVarTy).add(
            ident("YamlStreamEvent")))], newEmptyNode()))
    result[0][4] = newNimNode(nnkPragma).add(newNimNode(nnkExprColonExpr).add(
        ident("raises"), newNimNode(nnkBracket).add(ident("YamlParserError"),
        ident("YamlLexerError"))))

proc processStateAsgns(source, target: NimNode) {.compileTime.} =
  ## copies children of source to target and replaces all assignments
  ## `state = [name]` with the appropriate code for changing states.
  for child in source.children:
    if child.kind == nnkAsgn and child[0].kind == nnkIdent:
      if $child[0].ident == "state":
        assert child[1].kind == nnkIdent
        var newNameId: NimNode
        if child[1].kind == nnkIdent and $child[1].ident == "stored":
          newNameId = newDotExpr(ident("c"), ident("storedState"))
        else:
          newNameId =
              newIdentNode("state" & capitalize($child[1].ident))
        target.add(newAssignment(newDotExpr(
            newIdentNode("s"), newIdentNode("nextImpl")), newNameId))
        continue
      elif $child[0].ident == "stored":
        assert child[1].kind == nnkIdent
        let newNameId =
            newIdentNode("state" & capitalize($child[1].ident))
        target.add(newAssignment(newDotExpr(newIdentNode("c"),
            newIdentNode("storedState")), newNameId))
        continue
    var processed = copyNimNode(child)
    processStateAsgns(child, processed)
    target.add(processed)

macro parserState(name: untyped, impl: untyped): typed =
  ## Creates a parser state. Every parser state is a proc with the signature
  ##
  ## proc(s: YamlStream, e: var YamlStreamEvent):
  ##     bool {.raises: [YamlParserError].}
  ##
  ## The proc name will be prefixed with "state" and the original name will be
  ## capitalized, so a state "foo" will yield a proc named "stateFoo".
  ##
  ## Inside the proc, you have access to the ParserContext with the let variable
  ## `c`. You can change the parser state by a assignment `state = [newState]`.
  ## The [newState] must have been declared with states(...) previously.
  let
    nameStr = $name.ident
    nameId = newIdentNode("state" & capitalize(nameStr))
  var procImpl = quote do:
    debug("state: " & `nameStr`)
  procImpl.add(newLetStmt(ident("c"), newCall("ParserContext", ident("s"))))
  procImpl.add(newAssignment(newIdentNode("result"), newLit(false)))
  assert impl.kind == nnkStmtList
  processStateAsgns(impl, procImpl)
  result = newProc(nameId, [ident("bool"),
      newIdentDefs(ident("s"), ident("YamlStream")), newIdentDefs(ident("e"),
      newNimNode(nnkVarTy).add(ident("YamlStreamEvent")))], procImpl)

# --- parser states ---

parserStates(initial, blockLineStart, blockObjectStart, blockAfterObject,
             scalarEnd, plainScalarEnd, objectEnd, expectDocEnd, startDoc,
             afterDocument, closeStream, closeMoreIndentedLevels, 
             emitEmptyScalar, tagHandle, anchor, alias, flow, leaveFlowMap,
             leaveFlowSeq, flowAfterObject, leaveFlowSinglePairMap)

proc closeEverything(c: ParserContext) =
  c.lex.indentation = -1
  c.nextImpl = stateCloseMoreIndentedLevels

proc endLevel(c: ParserContext, e: var YamlStreamEvent):
    LevelEndResult =
  result = lerOne
  case c.level.kind
  of fplSequence:
    e = endSeqEvent()
  of fplMapKey:
    e = endMapEvent()
  of fplMapValue, fplSinglePairValue:
    e = emptyScalar(c)
    c.level.kind = fplMapKey
    result = lerAdditionalMapEnd
  of fplUnknown:
    if c.ancestry.len > 1:
      e = emptyScalar(c) # don't yield scalar for empty doc
    else:
      result = lerNothing
  of fplDocument:
    e = endDocEvent()
  of fplSinglePairKey:
    internalError("Unexpected level kind: " & $c.level.kind)

proc handleMapValueIndicator(c: ParserContext, e: var YamlStreamEvent): bool =
  result = false
  case c.level.kind
  of fplUnknown:
    if c.level.indentation == UnknownIndentation:
      e = c.objectStart(yamlStartMap)
      result = true
      c.storedState = c.nextImpl
      c.nextImpl = stateEmitEmptyScalar
    else:
      e = emptyScalar(c)
      result = true
    c.ancestry[c.ancestry.high].kind = fplMapValue
  of fplMapKey:
    if c.level.indentation != c.lex.indentation:
      raise c.generateError("Invalid p.indentation of map key indicator")
    e = scalarEvent("", yTagQuestionMark, yAnchorNone)
    result = true
    c.level.kind = fplMapValue
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
  of fplMapValue:
    if c.level.indentation != c.lex.indentation:
      raise c.generateError("Invalid p.indentation of map key indicator")
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
  of fplSequence:
    raise c.generateError("Unexpected map value indicator (expected '- ')")
  of fplSinglePairKey, fplSinglePairValue, fplDocument:
    internalError("Unexpected level kind: " & $c.level.kind)
  c.advance()

template handleObjectEnd(c: ParserContext, mayHaveEmptyValue: bool = false):
    bool =
  var result = false
  c.level = c.ancestry.pop()
  when mayHaveEmptyValue:
    if c.level.kind == fplSinglePairValue:
      result = true
      c.level = c.ancestry.pop()
  case c.level.kind
  of fplMapKey: c.level.kind = fplMapValue
  of fplSinglePairKey: c.level.kind = fplSinglePairValue
  of fplMapValue: c.level.kind = fplMapKey
  of fplSequence, fplDocument: discard
  of fplUnknown, fplSinglePairValue:
    internalError("Unexpected level kind: " & $c.level.kind)
  result

proc leaveFlowLevel(c: ParserContext, e: var YamlStreamEvent): bool =
  c.flowdepth.dec()
  result = (c.endLevel(e) == lerOne) # lerAdditionalMapEnd cannot happen
  if c.flowdepth == 0:
    c.lex.setFlow(false)
    c.storedState = stateBlockAfterObject
  else:
    c.storedState = stateFlowAfterObject
  c.nextImpl = stateObjectEnd

parserState initial:
  case c.lex.cur
  of ltYamlDirective:
    c.advance()
    assert c.lex.cur == ltYamlVersion, $c.lex.cur
    if c.lex.buf != "1.2":
      c.callCallback("Version is not 1.2, but " & c.lex.buf)
    c.lex.buf.setLen(0)
    c.advance()
  of ltTagDirective:
    c.advance()
    assert c.lex.cur == ltTagShorthand
    var tagShorthand: string
    shallowCopy(tagShorthand, c.lex.buf)
    c.lex.buf = ""
    c.advance()
    assert c.lex.cur == ltTagUri
    c.shorthands[tagShorthand] = c.lex.buf
    c.lex.buf.setLen(0)
    c.advance()
  of ltUnknownDirective:
    c.callCallback("Unknown directive: " & c.lex.buf)
    c.lex.buf.setLen(0)
    c.advance()
    if c.lex.cur == ltUnknownDirectiveParams:
      c.lex.buf.setLen(0)
      c.advance()
  of ltIndentation:
    e = startDocEvent()
    result = true
    state = blockObjectStart
  of ltStreamEnd: c.isFinished = true
  of ltDirectivesEnd:
    e = startDocEvent()
    result = true
    c.advance()
    state = blockObjectStart
  else: internalError("Unexpected lexer token: " & $c.lex.cur)

parserState blockLineStart:
  case c.lex.cur
  of ltIndentation: discard
  of ltEmptyLine: c.advance()
  of ltStreamEnd:
    c.closeEverything()
    stored = afterDocument
  else:
    if c.lex.indentation <= c.ancestry[^1].indentation:
      state = closeMoreIndentedLevels
      stored = blockObjectStart
    else:
      state = blockObjectStart

parserState blockObjectStart:
  case c.lex.cur
  of ltEmptyLine: c.advance()
  of ltIndentation:
    c.advance()
    c.level.indentation = UnknownIndentation
    state = blockLineStart
  of ltDirectivesEnd:
    c.closeEverything()
    stored = startDoc
  of ltDocumentEnd:
    c.closeEverything()
    stored = afterDocument
  of ltMapKeyInd:
    result = c.handleMapKeyIndicator(e)
  of ltMapValInd:
    result = c.handleMapValueIndicator(e)
  of ltQuotedScalar:
    result = c.handleBlockItemStart(e)
    c.advance()
    state = scalarEnd
  of ltScalarPart:
    result = c.handleBlockItemStart(e)
    while true:
      c.advance()
      c.lex.newlines.inc()
      case c.lex.cur
      of ltEmptyLine: c.lex.newlines.inc()
      of ltIndentation:
        if c.lex.indentation <= c.ancestry[^1].indentation: break
      of ltScalarPart: discard
      else: break
    c.lex.newlines = 0
    state = plainScalarEnd
    stored = blockAfterObject
  of ltSeqItemInd:
    result = c.handleBlockSequenceIndicator(e)
  of ltTagHandle:
    result = c.handleBlockItemStart(e)
    state = tagHandle
    stored = blockObjectStart
  of ltAnchor:
    result = c.handleBlockItemStart(e)
    state = anchor
    stored = blockObjectStart
  of ltAlias:
    result = c.handleBlockItemStart(e)
    state = alias
    stored = blockAfterObject
  of ltBraceOpen, ltBracketOpen:
    result = c.handleBlockItemStart(e)
    c.lex.setFlow(true)
    state = flow
  else:
    raise c.generateError("Unexpected token: " & $c.lex.cur)

parserState scalarEnd:
  if c.tag == yTagQuestionMark: c.tag = yTagExclamationMark
  e = c.currentScalar()
  result = true
  state = objectEnd
  stored = blockAfterObject

parserState plainScalarEnd:
  e = c.currentScalar()
  result = true
  state = objectEnd
  stored = blockAfterObject

parserState blockAfterObject:
  case c.lex.cur
  of ltIndentation, ltEmptyLine:
    c.advance()
    state = blockLineStart
  of ltMapValInd:
    case c.level.kind
    of fplUnknown:
      e = c.objectStart(yamlStartMap)
      result = true
    of fplMapKey:
      e = scalarEvent("", yTagQuestionMark, yAnchorNone)
      result = true
      c.level.kind = fplMapValue
      c.ancestry.add(c.level)
      c.level = initLevel(fplUnknown)
    of fplMapValue:
      c.level.kind = fplMapValue
      c.ancestry.add(c.level)
      c.level = initLevel(fplUnknown)
    of fplSequence: raise c.illegalToken("sequence item")
    of fplSinglePairKey, fplSinglePairValue, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.advance()
    state = blockObjectStart
  of ltDirectivesEnd:
    c.closeEverything()
    stored = startDoc
    c.advance()
  of ltStreamEnd:
    c.closeEverything()
    stored = afterDocument
  else: raise c.illegalToken("':', comment or line end")

parserState objectEnd:
  if c.handleObjectEnd(true):
    e = endMapEvent()
    result = true
  if c.level.kind == fplDocument: state = expectDocEnd
  else: state = stored

parserState expectDocEnd:
  case c.lex.cur
  of ltIndentation, ltEmptyLine: c.advance()
  of ltDirectivesEnd:
    e = endDocEvent()
    result = true
    state = startDoc
    c.ancestry.setLen(0)
  of ltDocumentEnd:
    e = endDocEvent()
    result = true
    state = afterDocument
  of ltStreamEnd:
    e = endDocEvent()
    result = true
    c.isFinished = true
  else:
    raise c.generateError("Unexpected token (expected document end): " &
        $c.lex.cur)

parserState startDoc:
  c.initDocValues()
  e = startDocEvent()
  result = true
  state = blockObjectStart

parserState afterDocument:
  case c.lex.cur
  of ltStreamEnd: c.isFinished = true
  of ltIndentation, ltEmptyLine, ltDocumentEnd: c.advance()
  else:
    c.initDocValues()
    state = initial

parserState closeStream:
  case c.level.kind
  of fplUnknown: discard c.ancestry.pop()
  of fplDocument: discard
  else:
    case c.endLevel(e)
    of lerNothing: discard
    of lerOne: result = true
    of lerAdditionalMapEnd: return true
    c.level = c.ancestry.pop()
    if result: return
  e = endDocEvent()
  result = true
  c.isFinished = true

parserState closeMoreIndentedLevels:
  if c.ancestry.len > 0:
    let parent = c.ancestry[c.ancestry.high]
    if parent.indentation >= c.lex.indentation:
      if c.lex.cur == ltSeqItemInd:
        if (c.lex.indentation == c.level.indentation and
            c.level.kind == fplSequence) or
           (c.lex.indentation == parent.indentation and
            c.level.kind == fplUnknown and parent.kind != fplSequence):
          state = stored
          return false
      debug("Closing because parent.indentation (" & $parent.indentation &
            ") >= indentation(" & $c.lex.indentation & ")")
      case c.endLevel(e)
      of lerNothing: discard
      of lerOne: result = true
      of lerAdditionalMapEnd: return true
      discard c.handleObjectEnd(false)
      return result
    if c.level.kind == fplDocument: state = expectDocEnd
    else: state = stored
  elif c.lex.indentation == c.level.indentation:
    let res = c.endLevel(e)
    yAssert(res == lerOne)
    result = true
    state = stored
  else:
    state = stored

parserState emitEmptyScalar:
  e = scalarEvent("", yTagQuestionMark, yAnchorNone)
  result = true
  state = stored

parserState tagHandle:
  c.handleTagHandle()
  state = stored

parserState anchor:
  c.handleAnchor()
  state = stored

parserState alias:
  if c.level.kind != fplUnknown: raise c.generateError("Unexpected token")
  if c.anchor != yAnchorNone or c.tag != yTagQuestionMark:
    raise c.generateError("Alias may not have anchor or tag")
  var id: AnchorId
  try: id = c.p.anchors[c.lex.buf]
  except KeyError: raise c.generateError("Unknown anchor")
  c.lex.buf.setLen(0)
  e = aliasEvent(id)
  c.advance()
  result = true
  state = objectEnd

parserState flow:
  case c.lex.cur
  of ltBraceOpen:
    if c.handleFlowItemStart(e): return true
    e = c.objectStart(yamlStartMap)
    result = true
    c.flowdepth.inc()
    c.explicitFlowKey = false
    c.advance()
  of ltBracketOpen:
    if c.handleFlowItemStart(e): return true
    e = c.objectStart(yamlStartSeq)
    result = true
    c.flowdepth.inc()
    c.advance()
  of ltBraceClose:
    yAssert(c.level.kind == fplUnknown)
    c.level = c.ancestry.pop()
    c.advance()
    state = leaveFlowMap
  of ltBracketClose:
    yAssert(c.level.kind == fplUnknown)
    c.level = c.ancestry.pop()
    c.advance()
    state = leaveFlowSeq
  of ltComma:
    yAssert(c.level.kind == fplUnknown)
    c.level = c.ancestry.pop()
    case c.level.kind
    of fplSequence:
      e = c.emptyScalar()
      result = true
    of fplMapValue:
      e = c.emptyScalar()
      result = true
      c.level.kind = fplMapKey
      c.explicitFlowKey = false
    of fplMapKey:
      e = c.emptyScalar()
      c.level.kind = fplMapValue
      return true
    of fplSinglePairValue:
      e = c.emptyScalar()
      result = true
      c.level = c.ancestry.pop()
      state = leaveFlowSinglePairMap
      stored = flow
    of fplUnknown, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
    c.advance()
  of ltMapValInd:
    c.level = c.ancestry.pop()
    case c.level.kind
    of fplSequence:
      e = startMapEvent(c.tag, c.anchor)
      result = true
      debug("started single-pair map at " &
          (if c.level.indentation == UnknownIndentation:
           $c.lex.indentation else: $c.level.indentation))
      c.tag = yTagQuestionMark
      c.anchor = yAnchorNone
      if c.level.indentation == UnknownIndentation:
        c.level.indentation = c.lex.indentation
      c.ancestry.add(c.level)
      c.level = initLevel(fplSinglePairKey)
    of fplMapValue, fplSinglePairValue:
      raise c.generateError("Unexpected token (expected ',')")
    of fplMapKey:
      e = c.emptyScalar()
      result = true
      c.level.kind = fplMapValue
    of fplSinglePairKey:
      e = c.emptyScalar()
      result = true
      c.level.kind = fplSinglePairValue
    of fplUnknown, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    if c.level.kind != fplSinglePairKey: c.advance()
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
  of ltQuotedScalar:
    if c.handleFlowItemStart(e): return true
    if c.tag == yTagQuestionMark: c.tag = yTagExclamationMark
    e = c.currentScalar()
    result = true
    state = objectEnd
    stored = flowAfterObject
    c.advance()
  of ltTagHandle:
    if c.handleFlowItemStart(e): return true
    c.handleTagHandle()
  of ltAnchor:
    if c.handleFlowItemStart(e): return true
    c.handleAnchor()
  of ltAlias:
    state = alias
    stored = flowAfterObject
  of ltMapKeyInd:
    if c.explicitFlowKey:
      raise c.generateError("Duplicate '?' in flow mapping")
    elif c.level.kind == fplUnknown:
      case c.ancestry[c.ancestry.high].kind
      of fplMapKey, fplMapValue, fplDocument: discard
      of fplSequence:
        e = c.objectStart(yamlStartMap, true)
        result = true
      else:
        raise c.generateError("Unexpected token")
    c.explicitFlowKey = true
    c.advance()
  of ltScalarPart:
    if c.handleFlowItemStart(e): return true
    c.handleFlowPlainScalar()
    e = c.currentScalar()
    result = true
    state = objectEnd
    stored = flowAfterObject
  else:
    raise c.generateError("Unexpected toked: " & $c.lex.cur)

parserState leaveFlowMap:
  case c.level.kind
  of fplMapValue:
    e = c.emptyScalar()
    c.level.kind = fplMapKey
    return true
  of fplMapKey:
    if c.tag != yTagQuestionMark or c.anchor != yAnchorNone or
        c.explicitFlowKey:
      e = c.emptyScalar()
      c.level.kind = fplMapValue
      c.explicitFlowKey = false
      return true
  of fplSequence:
    raise c.generateError("Unexpected token (expected ']')")
  of fplSinglePairValue:
    raise c.generateError("Unexpected token (expected ']')")
  of fplUnknown, fplSinglePairKey, fplDocument:
    internalError("Unexpected level kind: " & $c.level.kind)
  result = c.leaveFlowLevel(e)

parserState leaveFlowSeq:
  case c.level.kind
  of fplSequence:
    if c.tag != yTagQuestionMark or c.anchor != yAnchorNone:
      e = c.emptyScalar()
      return true
  of fplSinglePairValue:
    e = c.emptyScalar()
    c.level = c.ancestry.pop()
    state = leaveFlowSinglePairMap
    stored = leaveFlowSeq
    return true
  of fplMapKey, fplMapValue:
    raise c.generateError("Unexpected token (expected '}')")
  of fplUnknown, fplSinglePairKey, fplDocument:
    internalError("Unexpected level kind: " & $c.level.kind)
  result = c.leaveFlowLevel(e)

parserState leaveFlowSinglePairMap:
  e = endMapEvent()
  result = true
  state = stored

parserState flowAfterObject:
  case c.lex.cur
  of ltBracketClose:
    case c.level.kind
    of fplSequence: discard
    of fplMapKey, fplMapValue:
      raise c.generateError("Unexpected token (expected '}')")
    of fplSinglePairValue:
      c.level = c.ancestry.pop()
      yAssert(c.level.kind == fplSequence)
      e = endMapEvent()
      return true
    of fplUnknown, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    result = c.leaveFlowLevel(e)
    c.advance()
  of ltBraceClose:
    case c.level.kind
    of fplMapKey, fplMapValue: discard
    of fplSequence, fplSinglePairValue:
      raise c.generateError("Unexpected token (expected ']')")
    of fplUnknown, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    result = c.leaveFlowLevel(e)
    c.advance()
  of ltComma:
    case c.level.kind
    of fplSequence: discard
    of fplMapValue:
      e = scalarEvent("", yTagQuestionMark, yAnchorNone)
      result = true
      c.level.kind = fplMapKey
      c.explicitFlowKey = false
    of fplSinglePairValue:
      c.level = c.ancestry.pop()
      yAssert(c.level.kind == fplSequence)
      e = endMapEvent()
      result = true
    of fplMapKey: c.explicitFlowKey = false
    of fplUnknown, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
    state = flow
    c.advance()
  of ltMapValInd:
    case c.level.kind
    of fplSequence, fplMapKey:
      raise c.generateError("Unexpected token (expected ',')")
    of fplMapValue, fplSinglePairValue: discard
    of fplUnknown, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
    state = flow
    c.advance()
  of ltStreamEnd:
    raise c.generateError("Unclosed flow content")
  else:
    raise c.generateError("Unexpected content (expected flow indicator)")

proc lastTokenContext(s: YamlStream, line, column: var int,
    lineContent: var string): bool =
  let c = ParserContext(s)
  line = c.lex.curStartPos.line
  column = c.lex.curStartPos.column
  lineContent = c.lex.getTokenLine(true)
  result = true

# --- parser initialization ---

proc init(c: ParserContext, p: YamlParser) =
  c.p = p
  c.ancestry = newSeq[FastParseLevel]()
  c.initDocValues()
  c.flowdepth = 0
  c.isFinished = false
  c.peeked = false
  c.nextImpl = stateInitial
  c.explicitFlowKey = false
  c.lastTokenContextImpl = lastTokenContext
  c.advance()
  
proc parse*(p: YamlParser, s: Stream): YamlStream =
  let c = new(ParserContext)
  try: c.lex = newYamlLexer(s)
  except:
    let e = newException(YamlParserError,
        "Error while opening stream: " & getCurrentExceptionMsg())
    e.parent = getCurrentException()
    e.line = 1
    e.column = 1
    e.lineContent = ""
    raise e
  c.init(p)
  result = c

proc parse*(p: YamlParser, str: string): YamlStream =
  let c = new(ParserContext)
  c.lex = newYamlLexer(str)
  c.init(p)
  result = c
