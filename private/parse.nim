#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

type
  FastParseLevelKind = enum
    fplUnknown, fplSequence, fplMapKey, fplMapValue, fplSinglePairKey,
    fplSinglePairValue, fplScalar, fplDocument

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

proc callCallback(c: ParserContext, msg: string) {.raises: [YamlParserError].} =
  try:
    if not isNil(c.p.callback):
      c.p.callback(c.lexer.lineNumber, c.p.getColNumber(), c.p.getLineContent(),
          msg)
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
  c.lex.buf = newStringOfCap(256)
  c.tag = yTagQuestionMark
  c.anchor = yAnchorNone

proc objectStart(c: ParserContext, k: static[YamlStreamEventKind],
                 single: bool = false): YamlStreamEvent {.raises: [].} =
  yAssert(c.level.kind == fplUnknown)
  when k == yamlStartMap:
    result = startMapEvent(c.tag, c.anchor)
    if single:
      debug("started single-pair map at " &
          (if c.level.indentation == UnknownIndentation: $c.indentation else:
           $c.level.indentation))
      c.level.kind = fplSinglePairKey
    else:
      debug("started map at " &
          (if c.level.indentation == UnknownIndentation: $c.indentation else:
           $c.level.indentation))
      c.level.kind = fplMapKey
  else:
    result = startSeqEvent(c.tag, c.anchor)
    debug("started sequence at " &
        (if c.level.indentation == UnknownIndentation: $c.indentation else:
         $c.level.indentation))
    c.level.kind = fplSequence
  c.tag = yTagQuestionMark
  c.anchor = yAnchorNone
  if c.level.indentation == UnknownIndentation:
    c.level.indentation = c.indentation
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

proc handleAnchor(c: ParserContext) {.raises: [YamlParserError].} =
  if c.level.kind != fplUnknown: raise c.generateError("Unexpected token")
  if c.anchor != yAnchorNone:
    raise c.generateError("Only one anchor is allowed per node")
  c.anchor = c.nextAnchorId
  c.p.anchors[c.lex.buf] = c.anchor
  c.nextAnchorId = AnchorId(int(c.nextAnchorId) + 1)
  c.lex.buf.setLen(0)

proc continueMultilineScalar(c: ParserContext) {.raises: [].} =
  c.lex.buf.add(if c.newlines == 1: " " else: repeat('\l', c.newlines - 1))
  c.newlines = 0

template startScalar(t: ScalarType) {.dirty.} =
  c.newlines = 0
  c.level.kind = fplScalar
  c.scalarType = t

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

proc handlePossibleMapStart(c: ParserContext, e: var YamlStreamEvent,
    flow: bool = false, single: bool = false): bool =
  result = false
  if c.level.indentation == UnknownIndentation:
    if c.lex.isImplicitKeyStart():
      e = c.objectStart(yamlStartMap, single)
      result = true

proc handleMapKeyIndicator(c: ParserContext, e: var YamlStreamEvent): bool =
  result = false
  case c.level.kind
  of fplUnknown:
    e = c.objectStart(yamlStartMap)
    result = true
  of fplMapValue:
    if c.level.indentation != c.lex.indentation:
      raise c.generateError("Invalid p.indentation of map key indicator")
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
  of fplScalar:
    raise c.generateError(
        "Unexpected map key indicator (expected multiline scalar end)")
  of fplSinglePairKey, fplSinglePairValue, fplDocument:
    internalError("Unexpected level kind: " & $c.level.kind)
  # TODO: why was this there?
  # c.lexer.skipWhitespace()
  # c.indentation = c.lexer.getColNumber(c.lexer.bufpos)

proc handleBlockSequenceIndicator(c: ParserContext, e: var YamlStreamEvent):
    bool =
  result = false
  case c.level.kind
  of fplUnknown:
    e = c.objectStart(yamlStartSeq)
    result = true
  of fplSequence:
    if c.level.indentation != c.lex.indentation:
      raise c.generateError("Invalid p.indentation of block sequence indicator")
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
  else: raise c.generateError("Illegal sequence item in map")
  # TODO: why was this there?
  # c.lexer.skipWhitespace()
  # c.indentation = c.lexer.getColNumber(c.lexer.bufpos)

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
    c.level = FastParseLevel(kind: fplUnknown, indentation: c.indentation)
  of fplMapValue:
    e = emptyScalar(c)
    result = true
    c.level.kind = fplMapKey
    c.ancestry.add(c.level)
    c.level = FastParseLevel(kind: fplUnknown, indentation: c.indentation)
  of fplScalar, fplSinglePairKey, fplSinglePairValue, fplDocument:
    internalError("Unexpected level kind: " & $c.level.kind)

proc handleFlowItemStart(c: ParserContext, e: var YamlStreamEvent): bool =
  if c.level.kind == fplUnknown and
      c.ancestry[c.ancestry.high].kind == fplSequence:
    result = c.handlePossibleMapStart(e, true, true)

proc handleFlowPlainScalar(c: ParserContext, e: var YamlStreamEvent) =
  while c.lex.cur in {ltScalarPart, ltEmptyLine}:
    c.lex.newlines.inc()
    c.lex.next()
  c.lex.newlines = 0
  e = c.currentScalar()

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
        ident("raises"), newNimNode(nnkBracket).add(ident("YamlParserError"))))

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

parserStates(initial, blockObjectStart, blockAfterPlainScalar, blockAfterObject,
             scalarEnd, objectEnd, expectDocEnd, startDoc, afterDocument,
             closeStream, closeMoreIndentedLevels, emitEmptyScalar, tagHandle,
             anchor, alias, flow, leaveFlowMap, leaveFlowSeq, flowAfterObject,
             leaveFlowSinglePairMap)

proc closeEverything(c: ParserContext) =
  c.lex.indentation = -1
  c.nextImpl = stateCloseMoreIndentedLevels
  c.atSequenceItem = false

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
  of fplScalar:
    if c.scalarType != stFlow:
      case c.chomp
      of ctKeep:
        if c.content.len == 0: c.newlines.inc(-1)
        c.content.addMultiple('\l', c.newlines)
      of ctClip:
        if c.content.len != 0:
          debug("adding clipped newline")
          c.content.add('\l')
      of ctStrip: discard
    e = currentScalar(c)
    c.tag = yTagQuestionMark
    c.anchor = yAnchorNone
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
  c.startToken()
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
    if c.level.indentation != c.indentation:
      raise c.generateError("Invalid p.indentation of map key indicator")
    e = scalarEvent("", yTagQuestionMark, yAnchorNone)
    result = true
    c.level.kind = fplMapValue
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
  of fplMapValue:
    if c.level.indentation != c.indentation:
      raise c.generateError("Invalid p.indentation of map key indicator")
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
  of fplSequence:
    raise c.generateError("Unexpected map value indicator (expected '- ')")
  of fplScalar:
    raise c.generateError(
        "Unexpected map value indicator (expected multiline scalar end)")
  of fplSinglePairKey, fplSinglePairValue, fplDocument:
    internalError("Unexpected level kind: " & $c.level.kind)
  c.lexer.skipWhitespace()
  c.indentation = c.lexer.getColNumber(c.lexer.bufpos)

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
  of fplUnknown, fplScalar, fplSinglePairValue:
    internalError("Unexpected level kind: " & $c.level.kind)
  result

proc leaveFlowLevel(c: ParserContext, e: var YamlStreamEvent): bool =
  c.flowdepth.dec()
  result = (c.endLevel(e) == lerOne) # lerAdditionalMapEnd cannot happen
  if c.flowdepth == 0:
    c.storedState = stateBlockAfterObject
  else:
    c.storedState = stateFlowAfterObject
  c.nextImpl = stateObjectEnd

parserState initial:
  c.lex.next()
  case c.lex.cur
  of ltYamlDirective:
    c.lex.next()
    assert c.lex.cur == ltYamlVersion
    if c.lex.buf != "1.2":
      c.callCallback("Version is not 1.2, but " & c.lex.buf)
  of ltTagDirective:
    c.lex.next()
    assert c.lex.cur == ltTagShorthand
    var tagShorthand: string
    shallowCopy(tagShorthand, c.lex.buf)
    c.lex.buf = ""
    c.lex.next()
    assert c.lex.cur == ltTagUri
    c.shorthands[tagShorthand] = c.lex.buf
    c.lex.buf.setLen(0)
  of ltUnknownDirective:
    c.callCallback("Unknown directive: " & c.lex.buf)
    c.lex.buf.setLen(0)
    c.lex.next()
    assert c.lex.cur == ltUnknownDirectiveParams
  of ltIndentation:
    e = startDocEvent()
    result = true
    state = blockObjectStart
  of ltStreamEnd: c.isFinished = true
  of ltDirectivesEnd:
    e = startDocEvent()
    result = true
    state = blockObjectStart
  else: internalError("Unexpected lexer token: " & $c.lex.cur)

parserState blockObjectStart:
  c.next()

  c.lexer.skipIndentation()
  c.indentation = c.lexer.getColNumber(c.lexer.bufpos)
  if c.indentation == 0:
    var success: bool
    c.lexer.directivesEndMarker(success)
    if success:
      c.lexer.bufpos.inc(3)
      c.closeEverything()
      stored = startDoc
      return false
    c.lexer.documentEndMarker(success)
    if success:
      c.closeEverything()
      c.lexer.bufpos.inc(3)
      c.lineEnding()
      discard c.handleLineEnd(false)
      stored = afterDocument
      return false
  if c.atSequenceItem: c.atSequenceItem = false
  elif c.indentation <= c.ancestry[c.ancestry.high].indentation:
    if c.lexer.buf[c.lexer.bufpos] in lineEnd:
      if c.handleLineEnd(true):
        c.closeEverything()
        stored = afterDocument
      return false
    elif c.lexer.buf[c.lexer.bufpos] == '#':
      c.lineEnding()
      if c.handleLineEnd(true):
        c.closeEverything()
        stored = afterDocument
      return false
    else:
      state = closeMoreIndentedLevels
      stored = blockObjectStart
      return false
  elif c.indentation <= c.level.indentation and
      c.lexer.buf[c.lexer.bufpos] in lineEnd:
    if c.handleLineEnd(true):
      c.closeEverything()
      stored = afterDocument
    return false
  if c.level.kind == fplScalar and c.scalarType != stFlow:
    if c.indentation < c.level.indentation:
      if c.lexer.buf[c.lexer.bufpos] == '#':
        # skip all following comment lines
        while c.indentation > c.ancestry[c.ancestry.high].indentation:
          c.lineEnding()
          if c.handleLineEnd(false):
            c.closeEverything()
            stored = afterDocument
            return false
          c.lexer.skipIndentation()
          c.indentation = c.lexer.getColNumber(c.lexer.bufpos)
        if c.indentation > c.ancestry[c.ancestry.high].indentation:
          raise c.lexer.generateError(
              "Invalid content in block scalar after comments")
        state = closeMoreIndentedLevels
        stored = blockObjectStart
        return false
      else:
        raise c.lexer.generateError(
            "Invalid p.indentation (expected p.indentation of at least " &
            $c.level.indentation & " spaces)")
    if c.blockScalarLine():
      c.closeEverything()
      stored = afterDocument
    return false
  case c.lexer.buf[c.lexer.bufpos]
  of '\l':
    c.lexer.lexLF()
    c.newlines.inc()
    if c.level.kind == fplUnknown:
      c.level.indentation = UnknownIndentation
  of '\c':
    c.lexer.lexCR()
    c.newlines.inc()
    if c.level.kind == fplUnknown:
      c.level.indentation = UnknownIndentation
  of EndOfFile:
    c.closeEverything()
    stored = afterDocument
  of '#':
    c.lineEnding()
    if c.handleLineEnd(true):
      c.closeEverything()
      stored = afterDocument
    if c.level.kind == fplUnknown:
      c.level.indentation = UnknownIndentation
  of ':':
    if c.lexer.isPlainSafe(c.lexer.bufpos + 1, cBlock):
      if c.level.kind == fplScalar:
        c.continueMultilineScalar()
        state = blockAfterPlainScalar
      else:
        result = c.handleBlockItemStart(e)
        c.content.reset()
        c.startToken()
        c.plainScalar(cBlock)
        state = blockAfterPlainScalar
    else:
      c.lexer.bufpos.inc()
      result = c.handleMapValueIndicator(e)
  of '\t':
    if c.level.kind == fplScalar:
      c.lexer.skipWhitespace()
      c.continueMultilineScalar()
      state = blockAfterPlainScalar
    else: raise c.lexer.generateError("\\t cannot start any token")
  else:
    if c.level.kind == fplScalar:
      c.continueMultilineScalar()
      state = blockAfterPlainScalar
    else:
      case c.lexer.buf[c.lexer.bufpos]
      of '\'':
        result = c.handleBlockItemStart(e)
        c.content.reset()
        c.startToken()
        c.singleQuotedScalar()
        state = scalarEnd
      of '"':
        result = c.handleBlockItemStart(e)
        c.content.reset()
        c.startToken()
        c.doubleQuotedScalar()
        state = scalarEnd
      of '|', '>':
        if c.blockScalarHeader():
          c.closeEverything()
          stored = afterDocument
      of '-':
        if c.lexer.isPlainSafe(c.lexer.bufpos + 1, cBlock):
          result = c.handleBlockItemStart(e)
          c.content.reset()
          c.startToken()
          c.plainScalar(cBlock)
          state = blockAfterPlainScalar
        else:
          c.lexer.bufpos.inc()
          result = c.handleBlockSequenceIndicator(e)
      of '!':
        result = c.handleBlockItemStart(e)
        state = tagHandle
        stored = blockObjectStart
      of '&':
        result = c.handleBlockItemStart(e)
        state = anchor
        stored = blockObjectStart
      of '*':
        result = c.handleBlockItemStart(e)
        state = alias
        stored = blockAfterObject
      of '[', '{':
        result = c.handleBlockItemStart(e)
        state = flow
      of '?':
        if c.lexer.isPlainSafe(c.lexer.bufpos + 1, cBlock):
          result = c.handleBlockItemStart(e)
          c.content.reset()
          c.startToken()
          c.plainScalar(cBlock)
          state = blockAfterPlainScalar
        else:
          c.lexer.bufpos.inc()
          result = c.handleMapKeyIndicator(e)
      of '@', '`':
        raise c.lexer.generateError(
            "Reserved characters cannot start a plain scalar")
      else:
        result = c.handleBlockItemStart(e)
        c.content.reset()
        c.startToken()
        c.plainScalar(cBlock)
        state = blockAfterPlainScalar

parserState scalarEnd:
  if c.tag == yTagQuestionMark: c.tag = yTagExclamationMark
  e = c.currentScalar()
  result = true
  state = objectEnd
  stored = blockAfterObject

parserState blockAfterPlainScalar:
  c.lexer.skipWhitespace()
  case c.lexer.buf[c.lexer.bufpos]
  of '\l':
    if c.level.kind notin {fplUnknown, fplScalar}:
      c.startToken()
      raise c.generateError("Unexpected scalar")
    startScalar(stFlow)
    c.lexer.lexLF()
    c.newlines.inc()
    state = blockObjectStart
  of '\c':
    if c.level.kind notin {fplUnknown, fplScalar}:
      c.startToken()
      raise c.generateError("Unexpected scalar")
    startScalar(stFlow)
    c.lexer.lexCR()
    c.newlines.inc()
    state = blockObjectStart
  else:
    e = c.currentScalar()
    result = true
    state = objectEnd
    stored = blockAfterObject

parserState blockAfterObject:
  c.lexer.skipWhitespace()
  case c.lexer.buf[c.lexer.bufpos]
  of EndOfFile:
    c.closeEverything()
    stored = afterDocument
  of '\l':
    state = blockObjectStart
    c.lexer.lexLF()
  of '\c':
    state = blockObjectStart
    c.lexer.lexCR()
  of ':':
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
    of fplSequence:
      c.startToken()
      raise c.generateError("Illegal token (expected sequence item)")
    of fplScalar:
      c.startToken()
      raise c.generateError(
          "Multiline scalars may not be implicit map keys")
    of fplSinglePairKey, fplSinglePairValue, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.lexer.bufpos.inc()
    c.lexer.skipWhitespace()
    c.indentation = c.lexer.getColNumber(c.lexer.bufpos)
    state = blockObjectStart
  of '#':
    c.lineEnding()
    if c.handleLineEnd(true):
      c.closeEverything()
      stored = afterDocument
    else: state = blockObjectStart
  else:
    c.startToken()
    raise c.generateError(
        "Illegal token (expected ':', comment or line end)")

parserState objectEnd:
  if c.handleObjectEnd(true):
    e = endMapEvent()
    result = true
  if c.level.kind == fplDocument: state = expectDocEnd
  else: state = stored

parserState expectDocEnd:
  case c.lexer.buf[c.lexer.bufpos]
  of '-':
    var success: bool
    c.lexer.directivesEndMarker(success)
    if success:
      c.lexer.bufpos.inc(3)
      e = endDocEvent()
      result = true
      state = startDoc
      c.ancestry.setLen(0)
    else:
      raise c.generateError("Unexpected content (expected document end)")
  of '.':
    var isDocumentEnd: bool
    c.startToken()
    c.lexer.documentEndMarker(isDocumentEnd)
    if isDocumentEnd:
      c.lexer.bufpos.inc(3)
      c.lineEnding()
      discard c.handleLineEnd(true)
      e = endDocEvent()
      result = true
      state = afterDocument
    else:
      raise c.generateError("Unexpected content (expected document end)")
  of ' ', '\t', '#':
    c.lineEnding()
    if c.handleLineEnd(true):
      c.closeEverything()
      stored = afterDocument
  of '\l': c.lexer.lexLF()
  of '\c': c.lexer.lexCR()
  of EndOfFile:
    e = endDocEvent()
    result = true
    c.isFinished = true
  else:
    c.startToken()
    raise c.generateError("Unexpected content (expected document end)")

parserState startDoc:
  c.initDocValues()
  e = startDocEvent()
  result = true
  state = blockObjectStart

parserState afterDocument:
  case c.lexer.buf[c.lexer.bufpos]
  of '.':
    var isDocumentEnd: bool
    c.startToken()
    c.lexer.documentEndMarker(isDocumentEnd)
    if isDocumentEnd:
      c.lexer.bufpos.inc(3)
      c.lineEnding()
      discard c.handleLineEnd(true)
    else:
      c.initDocValues()
      e = startDocEvent()
      result = true
      state = blockObjectStart
  of '#':
    c.lineEnding()
    discard c.handleLineEnd(true)
  of '\t', ' ':
    if not c.consumeLineIfEmpty(c.newlines):
      c.indentation = c.lexer.getColNumber(c.lexer.bufpos)
      c.initDocValues()
      e = startDocEvent()
      result = true
      state = blockObjectStart
  of EndOfFile: c.isFinished = true
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
    if parent.indentation >= c.indentation:
      if c.atSequenceItem:
        if (c.indentation == c.level.indentation and
            c.level.kind == fplSequence) or
           (c.indentation == parent.indentation and
            c.level.kind == fplUnknown and parent.kind != fplSequence):
          state = stored
          return false
      debug("Closing because parent.indentation (" & $parent.indentation &
            ") >= indentation(" & $c.indentation & ")")
      case c.endLevel(e)
      of lerNothing: discard
      of lerOne: result = true
      of lerAdditionalMapEnd: return true
      discard c.handleObjectEnd(false)
      return result
    if c.level.kind == fplDocument: state = expectDocEnd
    else: state = stored
  elif c.indentation == c.level.indentation:
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
  c.startToken()
  if c.level.kind != fplUnknown: raise c.generateError("Unexpected token")
  if c.anchor != yAnchorNone or c.tag != yTagQuestionMark:
    raise c.generateError("Alias may not have anchor or tag")
  c.content.reset()
  c.anchorName()
  var id: AnchorId
  try: id = c.p.anchors[c.content]
  except KeyError: raise c.generateError("Unknown anchor")
  e = aliasEvent(id)
  result = true
  state = objectEnd

parserState flow:
  c.lexer.skipWhitespaceCommentsAndNewlines()
  case c.lexer.buf[c.lexer.bufpos]
  of '{':
    if c.handleFlowItemStart(e): return true
    e = c.objectStart(yamlStartMap)
    result = true
    c.flowdepth.inc()
    c.lexer.bufpos.inc()
    c.explicitFlowKey = false
  of '[':
    if c.handleFlowItemStart(e): return true
    e = c.objectStart(yamlStartSeq)
    result = true
    c.flowdepth.inc()
    c.lexer.bufpos.inc()
  of '}':
    yAssert(c.level.kind == fplUnknown)
    c.level = c.ancestry.pop()
    c.lexer.bufpos.inc()
    state = leaveFlowMap
  of ']':
    yAssert(c.level.kind == fplUnknown)
    c.level = c.ancestry.pop()
    c.lexer.bufpos.inc()
    state = leaveFlowSeq
  of ',':
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
    of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
    c.lexer.bufpos.inc()
  of ':':
    if c.lexer.isPlainSafe(c.lexer.bufpos + 1, cFlow):
      if c.handleFlowItemStart(e): return true
      c.handleFlowPlainScalar(e)
      result = true
      state = objectEnd
      stored = flowAfterObject
    else:
      c.level = c.ancestry.pop()
      case c.level.kind
      of fplSequence:
        e = startMapEvent(c.tag, c.anchor)
        result = true
        debug("started single-pair map at " &
            (if c.level.indentation == UnknownIndentation:
             $c.indentation else: $c.level.indentation))
        c.tag = yTagQuestionMark
        c.anchor = yAnchorNone
        if c.level.indentation == UnknownIndentation:
          c.level.indentation = c.indentation
        c.ancestry.add(c.level)
        c.level = initLevel(fplSinglePairKey)
      of fplMapValue, fplSinglePairValue:
        c.startToken()
        raise c.generateError("Unexpected token (expected ',')")
      of fplMapKey:
        e = c.emptyScalar()
        result = true
        c.level.kind = fplMapValue
      of fplSinglePairKey:
        e = c.emptyScalar()
        result = true
        c.level.kind = fplSinglePairValue
      of fplUnknown, fplScalar, fplDocument:
        internalError("Unexpected level kind: " & $c.level.kind)
      if c.level.kind != fplSinglePairKey: c.lexer.bufpos.inc()
      c.ancestry.add(c.level)
      c.level = initLevel(fplUnknown)
  of '\'':
    if c.handleFlowItemStart(e): return true
    c.content.reset()
    c.startToken()
    c.singleQuotedScalar()
    if c.tag == yTagQuestionMark: c.tag = yTagExclamationMark
    e = c.currentScalar()
    result = true
    state = objectEnd
    stored = flowAfterObject
  of '"':
    if c.handleFlowItemStart(e): return true
    c.content.reset()
    c.startToken()
    c.doubleQuotedScalar()
    if c.tag == yTagQuestionMark: c.tag = yTagExclamationMark
    e = c.currentScalar()
    result = true
    state = objectEnd
    stored = flowAfterObject
  of '!':
    if c.handleFlowItemStart(e): return true
    c.handleTagHandle()
  of '&':
    if c.handleFlowItemStart(e): return true
    c.handleAnchor()
  of '*':
    state = alias
    stored = flowAfterObject
  of '?':
    if c.lexer.isPlainSafe(c.lexer.bufpos + 1, cFlow):
      if c.handleFlowItemStart(e): return true
      c.handleFlowPlainScalar(e)
      result = true
      state = objectEnd
      stored = flowAfterObject
    elif c.explicitFlowKey:
      c.startToken()
      raise c.generateError("Duplicate '?' in flow mapping")
    elif c.level.kind == fplUnknown:
      case c.ancestry[c.ancestry.high].kind
      of fplMapKey, fplMapValue, fplDocument: discard
      of fplSequence:
        e = c.objectStart(yamlStartMap, true)
        result = true
      else:
        c.startToken()
        raise c.generateError("Unexpected token")
      c.explicitFlowKey = true
      c.lexer.bufpos.inc()
    else:
      c.explicitFlowKey = true
      c.lexer.bufpos.inc()
  else:
    if c.handleFlowItemStart(e): return true
    c.handleFlowPlainScalar(e)
    result = true
    state = objectEnd
    stored = flowAfterObject

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
    c.startToken()
    raise c.generateError("Unexpected token (expected ']')")
  of fplSinglePairValue:
    c.startToken()
    raise c.generateError("Unexpected token (expected ']')")
  of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
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
    c.startToken()
    raise c.generateError("Unexpected token (expected '}')")
  of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
    internalError("Unexpected level kind: " & $c.level.kind)
  result = c.leaveFlowLevel(e)

parserState leaveFlowSinglePairMap:
  e = endMapEvent()
  result = true
  state = stored

parserState flowAfterObject:
  c.lexer.skipWhitespaceCommentsAndNewlines()
  case c.lexer.buf[c.lexer.bufpos]
  of ']':
    case c.level.kind
    of fplSequence: discard
    of fplMapKey, fplMapValue:
      c.startToken()
      raise c.generateError("Unexpected token (expected '}')")
    of fplSinglePairValue:
      c.level = c.ancestry.pop()
      yAssert(c.level.kind == fplSequence)
      e = endMapEvent()
      return true
    of fplScalar, fplUnknown, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.lexer.bufpos.inc()
    result = c.leaveFlowLevel(e)
  of '}':
    case c.level.kind
    of fplMapKey, fplMapValue: discard
    of fplSequence, fplSinglePairValue:
      c.startToken()
      raise c.generateError("Unexpected token (expected ']')")
    of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.lexer.bufpos.inc()
    result = c.leaveFlowLevel(e)
  of ',':
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
    of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
    state = flow
    c.lexer.bufpos.inc()
  of ':':
    case c.level.kind
    of fplSequence, fplMapKey:
      c.startToken()
      raise c.generateError("Unexpected token (expected ',')")
    of fplMapValue, fplSinglePairValue: discard
    of fplUnknown, fplScalar, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    c.ancestry.add(c.level)
    c.level = initLevel(fplUnknown)
    state = flow
    c.lexer.bufpos.inc()
  of '#':
    c.lineEnding()
    if c.handleLineEnd(true):
      c.startToken()
      raise c.generateError("Unclosed flow content")
  of EndOfFile:
    c.startToken()
    raise c.generateError("Unclosed flow content")
  else:
    c.startToken()
    raise c.generateError("Unexpected content (expected flow indicator)")

# --- parser initialization ---

proc init(c: ParserContext, p: YamlParser) =
  c.p = p
  c.ancestry = newSeq[FastParseLevel]()
  c.initDocValues()
  c.flowdepth = 0
  c.isFinished = false
  c.peeked = false
  c.nextImpl = stateInitial

proc parse*(p: YamlParser, s: Stream): YamlStream =
  let c = new(ParserContext)
  c.init(p)
  try: c.lex = newYamlLexer(s)
  except:
    let e = newException(YamlParserError,
        "Error while opening stream: " & getCurrentExceptionMsg())
    e.parent = getCurrentException()
    e.line = 1
    e.column = 1
    e.lineContent = ""
    raise e
  result = c

proc parse*(p: YamlParser, str: string): YamlStream =
  let c = new(ParserContext)
  c.init(p)
  c.lex = newYamlLexer(str)
  result = c