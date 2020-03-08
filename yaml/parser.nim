#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ==================
## Module yaml.parser
## ==================
##
## This is the low-level parser API. A ``YamlParser`` enables you to parse any
## non-nil string or Stream object as YAML character stream.

import tables, strutils, macros, streams
import taglib, stream, private/lex, private/internal

when defined(nimNoNil):
    {.experimental: "notnil".}
    
type
  WarningCallback* = proc(line, column: int, lineContent: string,
                          message: string)
    ## Callback for parser warnings. Currently, this callback may be called
    ## on two occasions while parsing a YAML document stream:
    ##
    ## - If the version number in the ``%YAML`` directive does not match
    ##   ``1.2``.
    ## - If there is an unknown directive encountered.

  YamlParser* = ref object
    ## A parser object. Retains its ``TagLibrary`` across calls to
    ## `parse <#parse,YamlParser,Stream>`_. Can be used
    ## to access anchor names while parsing a YAML character stream, but
    ## only until the document goes out of scope (i.e. until
    ## ``yamlEndDocument`` is yielded).
    tagLib: TagLibrary
    callback: WarningCallback
    anchors: Table[string, AnchorId]

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
    plainScalarStart: tuple[line, column: int]

  LevelEndResult = enum
    lerNothing, lerOne, lerAdditionalMapEnd

  YamlLoadingError* = object of Exception
    ## Base class for all exceptions that may be raised during the process
    ## of loading a YAML character stream.
    line*: int ## line number (1-based) where the error was encountered
    column*: int ## column number (1-based) where the error was encountered
    lineContent*: string ## \
      ## content of the line where the error was encountered. Includes a
      ## second line with a marker ``^`` at the position where the error
      ## was encountered.

  YamlParserError* = object of YamlLoadingError
    ## A parser error is raised if the character stream that is parsed is
    ## not a valid YAML character stream. This stream cannot and will not be
    ## parsed wholly nor partially and all events that have been emitted by
    ## the YamlStream the parser provides should be discarded.
    ##
    ## A character stream is invalid YAML if and only if at least one of the
    ## following conditions apply:
    ##
    ## - There are invalid characters in an element whose contents is
    ##   restricted to a limited set of characters. For example, there are
    ##   characters in a tag URI which are not valid URI characters.
    ## - An element has invalid indentation. This can happen for example if
    ##   a block list element indicated by ``"- "`` is less indented than
    ##   the element in the previous line, but there is no block sequence
    ##   list open at the same indentation level.
    ## - The YAML structure is invalid. For example, an explicit block map
    ##   indicated by ``"? "`` and ``": "`` may not suddenly have a block
    ##   sequence item (``"- "``) at the same indentation level. Another
    ##   possible violation is closing a flow style object with the wrong
    ##   closing character (``}``, ``]``) or not closing it at all.
    ## - A custom tag shorthand is used that has not previously been
    ##   declared with a ``%TAG`` directive.
    ## - Multiple tags or anchors are defined for the same node.
    ## - An alias is used which does not map to any anchor that has
    ##   previously been declared in the same document.
    ## - An alias has a tag or anchor associated with it.
    ##
    ## Some elements in this list are vague. For a detailed description of a
    ## valid YAML character stream, see the YAML specification.

proc newYamlParser*(tagLib: TagLibrary = initExtendedTagLibrary(),
                    callback: WarningCallback = nil): YamlParser =
  ## Creates a YAML parser. if ``callback`` is not ``nil``, it will be called
  ## whenever the parser yields a warning.
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
  when defined(yamlScalarRepInd):
    result = scalarEvent("", c.tag, c.anchor, srPlain)
  else:
    result = scalarEvent("", c.tag, c.anchor)
  c.tag = yTagQuestionMark
  c.anchor = yAnchorNone

proc currentScalar(c: ParserContext, e: var YamlStreamEvent)
    {.raises: [], inline.} =
  e = YamlStreamEvent(kind: yamlScalar, scalarTag: c.tag,
                      scalarAnchor: c.anchor)
  shallowCopy(e.scalarContent, c.lex.buf)
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

proc advance(c: ParserContext) {.inline, raises: [YamlParserError].} =
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

template implicitScalar(): YamlStreamEvent =
  when defined(yamlScalarRepInd):
    scalarEvent("", yTagQuestionMark, yAnchorNone, srPlain)
  else:
    scalarEvent("", yTagQuestionMark, yAnchorNone)

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
    e = implicitScalar()
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
    # ? - a
    #   - b
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

proc lastTokenContext(s: YamlStream, line, column: var int,
    lineContent: var string): bool =
  let c = ParserContext(s)
  line = c.lex.curStartPos.line
  column = c.lex.curStartPos.column
  lineContent = c.lex.getTokenLine(true)
  result = true

# --- macros for defining parser states ---

template capitalize(s: string): string =
  when declared(strutils.capitalizeAscii): strutils.capitalizeAscii(s)
  else: strutils.capitalize(s)

macro parserStates(names: varargs[untyped]) =
  ## generates proc declaration for each state in list like this:
  ##
  ## proc name(s: YamlStream, e: var YamlStreamEvent):
  ##     bool {.raises: [YamlParserError].}
  result = newStmtList()
  for name in names:
    let nameId = newIdentNode("state" & capitalize(name.strVal))
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
      if child[0].strVal == "state":
        assert child[1].kind == nnkIdent
        var newNameId: NimNode
        if child[1].kind == nnkIdent and child[1].strVal == "stored":
          newNameId = newDotExpr(ident("c"), ident("storedState"))
        else:
          newNameId =
              newIdentNode("state" & capitalize(child[1].strVal))
        target.add(newAssignment(newDotExpr(
            newIdentNode("s"), newIdentNode("nextImpl")), newNameId))
        continue
      elif child[0].strVal == "stored":
        assert child[1].kind == nnkIdent
        let newNameId =
            newIdentNode("state" & capitalize(child[1].strVal))
        target.add(newAssignment(newDotExpr(newIdentNode("c"),
            newIdentNode("storedState")), newNameId))
        continue
    var processed = copyNimNode(child)
    processStateAsgns(child, processed)
    target.add(processed)

macro parserState(name: untyped, impl: untyped) =
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
    nameStr = name.strVal
    nameId = newIdentNode("state" & capitalize(nameStr))
  var procImpl = quote do:
    debug("state: " & `nameStr`)
  if procImpl.kind == nnkStmtList and procImpl.len == 1: procImpl = procImpl[0]
  procImpl = newStmtList(procImpl)
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
             afterDocument, closeMoreIndentedLevels, afterPlainScalarYield,
             emitEmptyScalar, tagHandle, anchor, alias, flow, leaveFlowMap,
             leaveFlowSeq, flowAfterObject, leaveFlowSinglePairMap)

proc closeEverything(c: ParserContext) =
  c.lex.indentation = -1
  c.nextImpl = stateCloseMoreIndentedLevels

proc endLevel(c: ParserContext, e: var YamlStreamEvent):
    LevelEndResult =
  result = lerOne
  case c.level.kind
  of fplSequence: e = endSeqEvent()
  of fplMapKey: e = endMapEvent()
  of fplMapValue, fplSinglePairValue:
    e = emptyScalar(c)
    c.level.kind = fplMapKey
    result = lerAdditionalMapEnd
  of fplUnknown: e = emptyScalar(c)
  of fplDocument:
    when defined(yamlScalarRepInd):
      e = endDocEvent(c.lex.cur == ltDocumentEnd)
    else: e = endDocEvent()
    if c.lex.cur == ltDocumentEnd: c.advance()
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
    e = implicitScalar()
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
  if c.lex.cur != ltIndentation:
    # see comment in handleMapKeyIndicator, this time with structures like
    # a: - a
    #    - b
    c.lex.indentation = c.lex.curStartPos.column - 1

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
  c.advance()

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
    when defined(yamlScalarRepInd): e = startDocEvent(true)
    else: e = startDocEvent()
    result = true
    c.advance()
    state = blockObjectStart
  of ltDocumentEnd:
    c.advance()
    state = afterDocument
  else: internalError("Unexpected lexer token: " & $c.lex.cur)

parserState blockLineStart:
  case c.lex.cur
  of ltIndentation: c.advance()
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
  of ltBlockScalarHeader:
    c.lex.indentation = c.ancestry[^1].indentation
    c.advance()
    assert c.lex.cur in  {ltBlockScalar, ltStreamEnd}
    if c.level.indentation == UnknownIndentation:
      c.level.indentation = c.lex.indentation
    c.advance()
    state = scalarEnd
  of ltScalarPart:
    let needsValueIndicator = c.level.kind == fplMapKey
    result = c.handleBlockItemStart(e)
    c.plainScalarStart = c.lex.curStartPos
    while true:
      c.advance()
      case c.lex.cur
      of ltIndentation:
        if c.lex.indentation <= c.ancestry[^1].indentation:
          if needsValueIndicator and
              c.lex.indentation == c.ancestry[^1].indentation:
            raise c.generateError("Illegal multiline implicit key")
          break
        c.lex.newlines.inc()
      of ltScalarPart: discard
      of ltEmptyLine: c.lex.newlines.inc()
      else: break
    if needsValueIndicator and c.lex.cur != ltMapValInd:
      raise c.generateError("Missing mapping value indicator (`:`)")
    c.lex.newlines = 0
    state = plainScalarEnd
    stored = blockAfterObject
  of ltSeqItemInd:
    result = c.handleBlockSequenceIndicator(e)
  of ltTagHandle, ltLiteralTag:
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
  of ltStreamEnd:
    c.closeEverything()
    stored = afterDocument
  else:
    raise c.generateError("Unexpected token: " & $c.lex.cur)

parserState scalarEnd:
  if c.tag == yTagQuestionMark: c.tag = yTagExclamationMark
  c.currentScalar(e)
  when defined(yamlScalarRepInd):
    case c.lex.scalarKind
    of skSingleQuoted: e.scalarRep = srSingleQuoted
    of skDoubleQuoted: e.scalarRep = srDoubleQuoted
    of skLiteral: e.scalarRep = srLiteral
    of skFolded: e.scalarRep = srFolded
  result = true
  state = objectEnd
  stored = blockAfterObject

parserState plainScalarEnd:
  c.currentScalar(e)
  result = true
  c.lastTokenContextImpl = proc(s: YamlStream, line, column: var int,
      lineContent: var string): bool {.raises: [].} =
    let c = ParserContext(s)
    (line, column) = c.plainScalarStart
    lineContent = c.lex.getTokenLine(c.plainScalarStart, true)
    result = true
  state = afterPlainScalarYield
  stored = blockAfterObject

parserState afterPlainScalarYield:
  c.lastTokenContextImpl = lastTokenContext
  state = objectEnd

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
      e = implicitScalar()
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
    when defined(yamlScalarRepInd): e = endDocEvent(true)
    else: e = endDocEvent()
    result = true
    state = afterDocument
    c.advance()
  of ltStreamEnd:
    e = endDocEvent()
    result = true
    c.isFinished = true
  else:
    raise c.generateError("Unexpected token (expected document end): " &
        $c.lex.cur)

parserState startDoc:
  c.initDocValues()
  when defined(yamlScalarRepInd):
    e = startDocEvent(c.lex.cur == ltDirectivesEnd)
  else: e = startDocEvent()
  result = true
  c.advance()
  state = blockObjectStart

parserState afterDocument:
  case c.lex.cur
  of ltStreamEnd: c.isFinished = true
  of ltEmptyLine: c.advance()
  else:
    c.initDocValues()
    state = initial

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
          debug("Not closing because sequence indicator")
          return false
      debug("Closing because parent.indentation (" & $parent.indentation &
            ") >= indentation(" & $c.lex.indentation & ")")
      case c.endLevel(e)
      of lerNothing: discard
      of lerOne: result = true
      of lerAdditionalMapEnd: return true
      discard c.handleObjectEnd(false)
      return result
    debug("Not closing level because parent.indentation (" &
        $parent.indentation & ") < indentation(" & $c.lex.indentation &
        ")")
    if c.level.kind == fplDocument: state = expectDocEnd
    else: state = stored
  elif c.lex.indentation == c.level.indentation:
    debug("Closing document")
    let res = c.endLevel(e)
    yAssert(res == lerOne)
    result = true
    state = stored
  else:
    state = stored

parserState emitEmptyScalar:
  e = implicitScalar()
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
    state = leaveFlowMap
  of ltBracketClose:
    yAssert(c.level.kind == fplUnknown)
    c.level = c.ancestry.pop()
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
    c.currentScalar(e)
    when defined(yamlScalarRepInd):
      case c.lex.scalarKind
      of skSingleQuoted: e.scalarRep = srSingleQuoted
      of skDoubleQuoted: e.scalarRep = srDoubleQuoted
      of skLiteral: e.scalarRep = srLiteral
      of skFolded: e.scalarRep = srFolded
    result = true
    state = objectEnd
    stored = flowAfterObject
    c.advance()
  of ltTagHandle, ltLiteralTag:
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
    c.currentScalar(e)
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
  of ltBraceClose:
    case c.level.kind
    of fplMapKey, fplMapValue: discard
    of fplSequence, fplSinglePairValue:
      raise c.generateError("Unexpected token (expected ']')")
    of fplUnknown, fplSinglePairKey, fplDocument:
      internalError("Unexpected level kind: " & $c.level.kind)
    # we need the extra state for possibly emitting an additional empty value.
    state = leaveFlowMap
    return false
  of ltComma:
    case c.level.kind
    of fplSequence: discard
    of fplMapValue:
      e = implicitScalar()
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
    c.explicitFlowKey = false
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

# --- parser initialization ---

proc init(c: ParserContext, p: YamlParser) {.raises: [YamlParserError].} =
  # this try/except should not be necessary because basicInit cannot raise
  # anything. however, compiling to JS does not work without it.
  try: c.basicInit(lastTokenContext)
  except: discard
  c.p = p
  c.ancestry = newSeq[FastParseLevel]()
  c.initDocValues()
  c.flowdepth = 0
  c.nextImpl = stateInitial
  c.explicitFlowKey = false
  c.advance()

when not defined(JS):
  proc parse*(p: YamlParser, s: Stream): YamlStream
      {.raises: [YamlParserError].} =
    ## Parse the given stream as YAML character stream.
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

proc parse*(p: YamlParser, str: string): YamlStream
    {.raises: [YamlParserError].} =
  ## Parse the given string as YAML character stream.
  let c = new(ParserContext)
  c.lex = newYamlLexer(str)
  c.init(p)
  result = c

proc anchorName*(p: YamlParser, anchor: AnchorId): string {.raises: [].} =
  ## Retrieve the textual representation of the given anchor as it occurred in
  ## the input (without the leading `&`). Returns the empty string for unknown
  ## anchors.
  for representation, value in p.anchors:
    if value == anchor: return representation
  return ""

proc renderAttrs(p: YamlParser, tag: TagId, anchor: AnchorId,
                 isPlain: bool): string =
  result = ""
  if anchor != yAnchorNone: result &= " &" & p.anchorName(anchor)
  case tag
  of yTagQuestionmark: discard
  of yTagExclamationmark:
    when defined(yamlScalarRepInd):
      if isPlain: result &= " <!>"
  else:
    result &= " <" & p.taglib.uri(tag) & ">"

proc display*(p: YamlParser, event: YamlStreamEvent): string
    {.raises: [KeyError].} =
  ## Generate a representation of the given event with proper visualization of
  ## anchor and tag (if any). The generated representation is conformant to the
  ## format used in the yaml test suite.
  ##
  ## This proc is an informed version of ``$`` on ``YamlStreamEvent`` which can
  ## properly display the anchor and tag name as it occurs in the input.
  ## However, it shall only be used while using the streaming API because after
  ## finishing the parsing of a document, the parser drops all information about
  ## anchor and tag names.
  case event.kind
  of yamlEndMap: result = "-MAP"
  of yamlEndSeq: result = "-SEQ"
  of yamlStartDoc:
    result = "+DOC"
    when defined(yamlScalarRepInd):
      if event.explicitDirectivesEnd: result &= " ---"
  of yamlEndDoc:
    result = "-DOC"
    when defined(yamlScalarRepInd):
      if event.explicitDocumentEnd: result &= " ..."
  of yamlStartMap:
    result = "+MAP" & p.renderAttrs(event.mapTag, event.mapAnchor, true)
  of yamlStartSeq:
    result = "+SEQ" & p.renderAttrs(event.seqTag, event.seqAnchor, true)
  of yamlScalar:
    when defined(yamlScalarRepInd):
      result = "=VAL" & p.renderAttrs(event.scalarTag, event.scalarAnchor,
                                      event.scalarRep == srPlain)
      case event.scalarRep
      of srPlain: result &= " :"
      of srSingleQuoted: result &= " \'"
      of srDoubleQuoted: result &= " \""
      of srLiteral: result &= " |"
      of srFolded: result &= " >"
    else:
      let isPlain = event.scalarTag == yTagExclamationmark
      result = "=VAL" & p.renderAttrs(event.scalarTag, event.scalarAnchor,
                                      isPlain)
      if isPlain: result &= " :"
      else: result &= " \""
    result &= yamlTestSuiteEscape(event.scalarContent)
  of yamlAlias: result = "=ALI *" & p.anchorName(event.aliasTarget)