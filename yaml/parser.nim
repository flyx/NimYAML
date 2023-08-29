#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## ==================
## Module yaml/parser
## ==================
##
## This is the low-level parser API. A ``YamlParser`` enables you to parse any
## non-nil string or Stream object as YAML character stream.

import tables, strutils, macros, streams
import stream, private/lex, private/internal, private/escaping, data

when defined(nimNoNil):
    {.experimental: "notnil".}

type
  YamlParser* = object
    ## A parser object. Retains its ``TagLibrary`` across calls to
    ## `parse <#parse,YamlParser,Stream>`_. Can be used
    ## to access anchor names while parsing a YAML character stream, but
    ## only until the document goes out of scope (i.e. until
    ## ``yamlEndDocument`` is yielded).
    issueWarnings: bool
  
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

  State = proc(ctx: Context, e: var Event): bool {.gcSafe, raises: [CatchableError].}

  Level = object
    state: State
    indentation: int

  Context = ref object of YamlStream
    handles: seq[tuple[handle, uriPrefix: string]]
    issueWarnings: bool
    lex: Lexer
    levels: seq[Level]
    keyCache: seq[Event]
    keyCachePos: int
    caching: bool

    headerProps, inlineProps: Properties
    headerStart, inlineStart: Mark
    blockIndentation: int

const defaultProperties = (yAnchorNone, yTagQuestionMark)

# parser states

{.push gcSafe, raises: [CatchableError].}
proc atStreamStart(ctx: Context, e: var Event): bool
proc atStreamEnd(ctx: Context, e : var Event): bool {.hint[XCannotRaiseY]: off.}
proc beforeDoc(ctx: Context, e: var Event): bool
proc beforeDocEnd(ctx: Context, e: var Event): bool
proc afterDirectivesEnd(ctx: Context, e: var Event): bool
proc beforeImplicitRoot(ctx: Context, e: var Event): bool
proc atBlockIndentation(ctx: Context, e: var Event): bool
proc beforeBlockIndentation(ctx: Context, e: var Event): bool
proc beforeNodeProperties(ctx: Context, e: var Event): bool
proc afterCompactParent(ctx: Context, e: var Event): bool
proc afterCompactParentProps(ctx: Context, e: var Event): bool
proc mergePropsOnNewline(ctx: Context, e: var Event): bool
proc beforeFlowItemProps(ctx: Context, e: var Event): bool
proc inBlockSeq(ctx: Context, e: var Event): bool
proc beforeBlockMapValue(ctx: Context, e: var Event): bool
proc atBlockIndentationProps(ctx: Context, e: var Event): bool
proc beforeFlowItem(ctx: Context, e: var Event): bool
proc afterFlowSeqSep(ctx: Context, e: var Event): bool
proc afterFlowMapSep(ctx: Context, e: var Event): bool
proc atBlockMapKeyProps(ctx: Context, e: var Event): bool
proc afterImplicitKey(ctx: Context, e: var Event): bool
proc afterBlockParent(ctx: Context, e: var Event): bool
proc afterBlockParentProps(ctx: Context, e: var Event): bool
proc afterImplicitPairStart(ctx: Context, e: var Event): bool
proc beforePairValue(ctx: Context, e: var Event): bool
proc atEmptyPairKey(ctx: Context, e: var Event): bool {.hint[XCannotRaiseY]: off.}
proc afterFlowMapValue(ctx: Context, e: var Event): bool
proc afterFlowSeqSepProps(ctx: Context, e: var Event): bool
proc afterFlowSeqItem(ctx: Context, e: var Event): bool
proc afterPairValue(ctx: Context, e: var Event): bool {.hint[XCannotRaiseY]: off.}
proc emitCached(ctx: Context, e: var Event): bool {.hint[XCannotRaiseY]: off.}
{.pop.}

template pushLevel(ctx: Context, newState: State, newIndent: int) =
  debug("parser: push " & newState.astToStr & ", indent = " & $newIndent)
  ctx.levels.add(Level(state: newState, indentation: newIndent))

template pushLevel(ctx: Context, newState: State) =
  debug("parser: push " & newState.astToStr)
  ctx.levels.add(Level(state: newState))

template transition(ctx: Context, newState: State) =
  debug("parser: transition " & newState.astToStr)
  ctx.levels[^1].state = newState

template transition(ctx: Context, newState: State, newIndent) =
  debug("parser: transtion " & newState.astToStr & ", indent = " & $newIndent)
  ctx.levels[^1] = Level(state: newState, indentation: newIndent)

template updateIndentation(ctx: Context, newIndent: int) =
  debug("parser: update indent = " & $newIndent)
  ctx.levels[^1].indentation = newIndent

template popLevel(ctx: Context) =
  debug("parser: pop")
  discard ctx.levels.pop()

proc resolveHandle(ctx: Context, handle: string): string {.raises: [].} =
  for item in ctx.handles:
    if item.handle == handle:
      return item.uriPrefix
  return ""

proc init[T](ctx: Context, p: YamlParser, source: T) {.inline.} =
  ctx.pushLevel(atStreamStart, -2)
  ctx.nextImpl = proc(s: YamlStream, e: var Event): bool {.raises: [CatchableError].} =
    let c = Context(s)
    return c.levels[^1].state(c, e)
  ctx.lastTokenContextImpl = proc(s: YamlStream, lineContent: var string): bool =
    lineContent = Context(s).lex.currentLine()
    return true
  ctx.headerProps = defaultProperties
  ctx.inlineProps = defaultProperties
  ctx.issueWarnings = p.issueWarnings
  ctx.lex.init(source)
  ctx.keyCachePos = 0
  ctx.caching = false

# interface

proc init*(p: var YamlParser, issueWarnings: bool = false) =
  ## Initializes a YAML parser.
  p.issueWarnings = issueWarnings

proc initYamlParser*(issueWarnings: bool = false): YamlParser =
  ## Creates an initializes YAML parser and returns it
  result.issueWarnings = issueWarnings

proc parse*(p: YamlParser, s: Stream): YamlStream =
  let ctx = new(Context)
  ctx.init(p, s)
  return ctx

proc parse*(p: YamlParser, s: string): YamlStream =
  let ctx = new(Context)
  ctx.init(p, s)
  return ctx

# implementation

proc isEmpty(props: Properties): bool =
  result = props.anchor == yAnchorNone and
           props.tag == yTagQuestionMark

proc generateError(ctx: Context, message: string):
    ref YamlParserError {.raises: [], .} =
  result = (ref YamlParserError)(
    msg: message, parent: nil, mark: ctx.lex.curStartPos,
    lineContent: ctx.lex.currentLine())

proc safeNext(ctx: Context) =
  try:
    ctx.lex.next()
  except LexerError as e:
    raise (ref YamlParserError)(
      msg: e.msg, parent: nil, mark: Mark(line: e.line, column: e.column),
      lineContent: e.lineContent)

proc parseTag(ctx: Context): Tag =
  let handle = ctx.lex.fullLexeme()
  var uri = ctx.resolveHandle(handle)
  if uri == "":
    raise ctx.generateError("unknown handle: " & escape(handle))
  ctx.safeNext()
  if ctx.lex.cur != Token.Suffix:
    raise ctx.generateError("unexpected token (expected tag suffix): " & $ctx.lex.cur)
  uri.add(ctx.lex.evaluated)
  return Tag(uri)

proc toStyle(t: Token): ScalarStyle =
  return (case t
    of Plain: ssPlain
    of SingleQuoted: ssSingleQuoted
    of DoubleQuoted: ssDoubleQuoted
    of Literal: ssLiteral
    of Folded: ssFolded
    else: ssAny)

proc mergeProps(ctx: Context, src, target: var Properties) =
  if src.tag != yTagQuestionMark:
    if target.tag != yTagQuestionMark:
      raise ctx.generateError("Only one tag allowed per node")
    target.tag = src.tag
    src.tag = yTagQuestionMark
  if src.anchor != yAnchorNone:
    if target.anchor != yAnchorNone:
      raise ctx.generateError("Only one anchor allowed per node")
    target.anchor = src.anchor
    src.anchor = yAnchorNone

proc autoScalarTag(props: Properties, t: Token): Properties =
  result = props
  if t in {Token.SingleQuoted, Token.DoubleQuoted} and
      props.tag == yTagQuestionMark:
    result.tag = yTagExclamationMark

proc atStreamStart(ctx: Context, e: var Event): bool =
  ctx.transition(atStreamEnd)
  ctx.pushLevel(beforeDoc, -1)
  e = Event(startPos: ctx.lex.curStartPos, endPos: ctx.lex.curStartPos, kind: yamlStartStream)
  ctx.safeNext()
  resetHandles(ctx.handles)
  return true

proc atStreamEnd(ctx: Context, e : var Event): bool =
  e = Event(startPos: ctx.lex.curStartPos,
            endPos: ctx.lex.curStartPos, kind: yamlEndStream)
  return true

proc beforeDoc(ctx: Context, e: var Event): bool =
  var version = ""
  var seenDirectives = false
  while true:
    case ctx.lex.cur
    of DocumentEnd:
      if seenDirectives:
        raise ctx.generateError("Missing `---` after directives")
      ctx.safeNext()
    of DirectivesEnd:
      e = startDocEvent(true, version, ctx.handles, ctx.lex.curStartPos, ctx.lex.curEndPos)
      ctx.safeNext()
      ctx.transition(beforeDocEnd)
      ctx.pushLevel(afterDirectivesEnd, -1)
      return true
    of StreamEnd:
      if seenDirectives:
        raise ctx.generateError("Missing `---` after directives")
      ctx.popLevel()
      return false
    of Indentation:
      e = startDocEvent(false, version, ctx.handles, ctx.lex.curStartPos, ctx.lex.curEndPos)
      ctx.transition(beforeDocEnd)
      ctx.pushLevel(beforeImplicitRoot, -1)
      return true
    of YamlDirective:
      seenDirectives = true
      ctx.safeNext()
      if ctx.lex.cur != Token.DirectiveParam:
        raise ctx.generateError("Invalid token (expected YAML version string): " & $ctx.lex.cur)
      elif version != "":
        raise ctx.generateError("Duplicate %YAML")
      version = ctx.lex.fullLexeme()
      if version != "1.2" and ctx.issueWarnings:
        discard # TODO
      ctx.safeNext()
    of TagDirective:
      seenDirectives = true
      ctx.safeNext()
      if ctx.lex.cur != Token.TagHandle:
        raise ctx.generateError("Invalid token (expected tag handle): " & $ctx.lex.cur)
      let tagHandle = ctx.lex.fullLexeme()
      ctx.safeNext()
      if ctx.lex.cur != Token.Suffix:
        raise ctx.generateError("Invalid token (expected tag URI): " & $ctx.lex.cur)
      discard registerHandle(ctx.handles, tagHandle, ctx.lex.evaluated)
      ctx.safeNext()
    of UnknownDirective:
      seenDirectives = true
      # TODO: issue warning
      while true:
        ctx.safeNext()
        if ctx.lex.cur != Token.DirectiveParam: break
    else:
      raise ctx.generateError("Unexpected token (expected directive or document start): " & $ctx.lex.cur)

proc afterDirectivesEnd(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.inlineStart = ctx.lex.curStartPos
    ctx.pushLevel(beforeNodeProperties)
    return false
  of Indentation:
    ctx.headerStart = ctx.inlineStart
    ctx.transition(atBlockIndentation)
    ctx.pushLevel(beforeBlockIndentation)
    return false
  of DocumentEnd, DirectivesEnd, StreamEnd:
    e = scalarEvent("", ctx.inlineProps, ssPlain, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.popLevel()
    return true
  of scalarTokenKind:
    e = scalarEvent(ctx.lex.evaluated, autoScalarTag(ctx.inlineProps, ctx.lex.cur),
                    toStyle(ctx.lex.cur), ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.popLevel()
    ctx.safeNext()
    return true
  else:
    raise ctx.generateError("Illegal content at `---`: " & $ctx.lex.cur)

proc beforeImplicitRoot(ctx: Context, e: var Event): bool =
  if ctx.lex.cur != Token.Indentation:
    raise ctx.generateError("Unexpected token (expected line start): " & $ctx.lex.cur)
  ctx.inlineStart = ctx.lex.curEndPos
  ctx.headerStart = ctx.lex.curEndPos
  ctx.updateIndentation(ctx.lex.recentIndentation())
  ctx.safeNext()
  case ctx.lex.cur
  of SeqItemInd, MapKeyInd, MapValueInd:
    ctx.transition(afterCompactParent)
    return false
  of scalarTokenKind, MapStart, SeqStart:
    ctx.transition(atBlockIndentationProps)
    return false
  of nodePropertyKind:
    ctx.transition(atBlockIndentationProps)
    ctx.pushLevel(beforeNodeProperties)
  else:
    raise ctx.generateError("Unexpected token (expected collection start): " & $ctx.lex.cur)

proc atBlockIndentation(ctx: Context, e: var Event): bool =
  if ctx.blockIndentation == ctx.levels[^1].indentation and
      (ctx.lex.cur != Token.SeqItemInd or
       ctx.levels[^3].state == inBlockSeq):
    e = scalarEvent("", ctx.headerProps, ssPlain,
                    ctx.headerStart, ctx.headerStart)
    ctx.headerProps = defaultProperties
    ctx.popLevel()
    ctx.popLevel()
    return true
  ctx.inlineStart = ctx.lex.curStartPos
  ctx.updateIndentation(ctx.lex.recentIndentation())
  case ctx.lex.cur
  of nodePropertyKind:
    if isEmpty(ctx.headerProps):
      ctx.transition(mergePropsOnNewline)
    else:
      ctx.transition(atBlockIndentationProps)
    ctx.pushLevel(beforeNodeProperties)
    return false
  of SeqItemInd:
    e = startSeqEvent(csBlock, ctx.headerProps,
                      ctx.headerStart, ctx.lex.curEndPos)
    ctx.headerProps = defaultProperties
    ctx.transition(inBlockSeq, ctx.lex.recentIndentation())
    ctx.pushLevel(beforeBlockIndentation)
    ctx.pushLevel(afterCompactParent, ctx.lex.recentIndentation())
    ctx.safeNext()
    return true
  of MapKeyInd:
    e = startMapEvent(csBlock, ctx.headerProps,
                      ctx.headerStart, ctx.lex.curEndPos)
    ctx.headerProps = defaultProperties
    ctx.transition(beforeBlockMapValue, ctx.lex.recentIndentation())
    ctx.pushLevel(beforeBlockIndentation)
    ctx.pushLevel(afterCompactParent, ctx.lex.recentIndentation())
    ctx.safeNext()
    return true
  of Plain, SingleQuoted, DoubleQuoted:
    ctx.updateIndentation(ctx.lex.recentIndentation())
    let scalarToken = ctx.lex.cur
    e = scalarEvent(ctx.lex.evaluated, ctx.headerProps,
                    toStyle(ctx.lex.cur), ctx.inlineStart, ctx.lex.curEndPos)
    ctx.headerProps = defaultProperties
    let headerEnd = ctx.lex.curStartPos
    ctx.safeNext()
    if ctx.lex.cur == Token.MapValueInd:
      if ctx.lex.lastScalarWasMultiline():
        raise ctx.generateError("Implicit mapping key may not be multiline")
      let props = e.scalarProperties
      e.scalarProperties = autoScalarTag(defaultProperties, scalarToken)
      ctx.keyCache.add(move(e))
      e = startMapEvent(csBlock, props, ctx.headerStart, headerEnd)
      ctx.transition(afterImplicitKey)
      ctx.pushLevel(emitCached)
    else:
      e.scalarProperties = autoScalarTag(e.scalarProperties, scalarToken)
      ctx.popLevel()
    return true
  of Alias:
    e = aliasEvent(ctx.lex.shortLexeme().Anchor, ctx.inlineStart, ctx.lex.curEndPos)
    ctx.inlineProps = defaultProperties
    let headerEnd = ctx.lex.curStartPos
    ctx.safeNext()
    if ctx.lex.cur == Token.MapValueInd:
      ctx.keyCache.add(move(e))
      e = startMapEvent(csBlock, ctx.headerProps, ctx.headerStart, headerEnd)
      ctx.headerProps = defaultProperties
      ctx.transition(afterImplicitKey)
      ctx.pushLevel(emitCached)
    elif not isEmpty(ctx.headerProps):
      raise ctx.generateError("Alias may not have properties")
    else:
      ctx.popLevel()
    return true
  else:
    ctx.transition(atBlockIndentationProps)
    return false

proc atBlockIndentationProps(ctx: Context, e: var Event): bool =
  ctx.updateIndentation(ctx.lex.recentIndentation())
  case ctx.lex.cur
  of MapValueInd:
    ctx.keyCache.add(scalarEvent("", ctx.inlineProps, ssPlain, ctx.inlineStart, ctx.lex.curEndPos))
    ctx.inlineProps = defaultProperties
    e = startMapEvent(csBlock, ctx.headerProps, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.headerProps = defaultProperties
    ctx.transition(afterImplicitKey)
    ctx.pushLevel(emitCached)
    return true
  of Plain, SingleQuoted, DoubleQuoted:
    e = scalarEvent(ctx.lex.evaluated, autoScalarTag(ctx.inlineProps, ctx.lex.cur),
                    toStyle(ctx.lex.cur), ctx.inlineStart, ctx.lex.curEndPos)
    ctx.inlineProps = defaultProperties
    let headerEnd = ctx.lex.curStartPos
    ctx.safeNext()
    if ctx.lex.cur == Token.MapValueInd:
      if ctx.lex.lastScalarWasMultiline():
        raise ctx.generateError("Implicit mapping key may not be multiline")
      ctx.keyCache.add(move(e))
      e = startMapEvent(csBlock, ctx.headerProps, ctx.headerStart, headerEnd)
      ctx.headerProps = defaultProperties
      ctx.transition(afterImplicitKey)
      ctx.pushLevel(emitCached)
    else:
      ctx.mergeProps(ctx.headerProps, e.scalarProperties)
      ctx.popLevel()
    return true
  of MapStart, SeqStart:
    let
      startPos = ctx.lex.curStartPos
      indent = ctx.lex.currentIndentation()
      levelDepth = ctx.levels.len
    ctx.transition(beforeFlowItemProps)
    ctx.caching = true
    while ctx.levels.len >= levelDepth:
      ctx.keyCache.add(ctx.next())
    ctx.caching = false
    if ctx.lex.cur == Token.MapValueInd:
      ctx.pushLevel(afterImplicitKey, indent)
      ctx.pushLevel(emitCached)
      if ctx.lex.curStartPos.line != startPos.line:
        raise ctx.generateError("Implicit mapping key may not be multiline")
      e = startMapEvent(csBlock, ctx.headerProps, ctx.headerStart, startPos)
      ctx.headerProps = defaultProperties
      return true
    else:
      ctx.pushLevel(emitCached)
      return false
  of Literal, Folded:
    ctx.mergeProps(ctx.inlineProps, ctx.headerProps)
    e = scalarEvent(ctx.lex.evaluated, ctx.headerProps, toStyle(ctx.lex.cur),
                    ctx.inlineStart, ctx.lex.curEndPos)
    ctx.headerProps = defaultProperties
    ctx.safeNext()
    ctx.popLevel()
    return true
  of Indentation:
    ctx.safeNext()
    ctx.transition(atBlockIndentation)
    return false
  of StreamEnd, DocumentEnd, DirectivesEnd:
    e = scalarEvent("", ctx.inlineProps, ssPlain, ctx.inlineStart, ctx.lex.curStartPos)
    ctx.inlineProps = defaultProperties
    ctx.popLevel()
    return true
  else:
    raise ctx.generateError("Unexpected token (expected block content): " & $ctx.lex.cur)

proc beforeNodeProperties(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of TagHandle:
    if ctx.inlineProps.tag != yTagQuestionMark:
      raise ctx.generateError("Only one tag allowed per node")
    ctx.inlineProps.tag = ctx.parseTag()
  of VerbatimTag:
    if ctx.inlineProps.tag != yTagQuestionMark:
      raise ctx.generateError("Only one tag allowed per node")
    ctx.inlineProps.tag = Tag(move(ctx.lex.evaluated))
  of Token.Anchor:
    if ctx.inlineProps.anchor != yAnchorNone:
      raise ctx.generateError("Only one anchor allowed per node")
    ctx.inlineProps.anchor = ctx.lex.shortLexeme().Anchor
  of Indentation:
    ctx.mergeProps(ctx.inlineProps, ctx.headerProps)
    ctx.popLevel()
    return false
  of Alias:
    raise ctx.generateError("Alias may not have node properties")
  else:
    ctx.popLevel()
    return false
  ctx.safeNext()
  return false

proc afterCompactParent(ctx: Context, e: var Event): bool =
  ctx.inlineStart = ctx.lex.curStartPos
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.transition(afterCompactParentProps)
    ctx.pushLevel(beforeNodeProperties)
  of SeqItemInd:
    e = startSeqEvent(csBlock, ctx.headerProps, ctx.headerStart, ctx.lex.curEndPos)
    ctx.headerProps = defaultProperties
    ctx.transition(inBlockSeq, ctx.lex.recentIndentation())
    ctx.pushLevel(beforeBlockIndentation)
    ctx.pushLevel(afterCompactParent, ctx.lex.recentIndentation())
    ctx.safeNext()
    return true
  of MapKeyInd:
    e = startMapEvent(csBlock, ctx.headerProps, ctx.headerStart, ctx.lex.curEndPos)
    ctx.headerProps = defaultProperties
    ctx.transition(beforeBlockMapValue, ctx.lex.recentIndentation())
    ctx.pushLevel(beforeBlockIndentation)
    ctx.pushLevel(afterCompactParent, ctx.lex.recentIndentation)
    ctx.safeNext()
    return true
  else:
    ctx.transition(afterCompactParentProps)
    return false

proc afterCompactParentProps(ctx: Context, e: var Event): bool =
  ctx.updateIndentation(ctx.lex.recentIndentation())
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.pushLevel(beforeNodeProperties)
    return false
  of Indentation:
    ctx.headerStart = ctx.inlineStart
    ctx.transition(atBlockIndentation, ctx.levels[^3].indentation)
    ctx.pushLevel(beforeBlockIndentation)
    return false
  of MapValueInd:
    ctx.keyCache.add(scalarEvent("", ctx.inlineProps, ssPlain, ctx.inlineStart, ctx.lex.curStartPos))
    ctx.inlineProps = defaultProperties
    e = startMapEvent(csBlock, defaultProperties, ctx.lex.curStartPos, ctx.lex.curStartPos)
    ctx.transition(afterImplicitKey)
    ctx.pushLevel(emitCached)
    return true
  of Alias:
    e = aliasEvent(ctx.lex.shortLexeme().Anchor, ctx.inlineStart, ctx.lex.curEndPos)
    let headerEnd = ctx.lex.curStartPos
    ctx.safeNext()
    if ctx.lex.cur == Token.MapValueInd:
      ctx.keyCache.add(move(e))
      e = startMapEvent(csBlock, defaultProperties, headerEnd, headerEnd)
      ctx.transition(afterImplicitKey)
      ctx.pushLevel(emitCached)
    else:
      ctx.popLevel()
    return true
  of scalarTokenKind:
    e = scalarEvent(ctx.lex.evaluated, autoScalarTag(ctx.inlineProps, ctx.lex.cur),
                    toStyle(ctx.lex.cur), ctx.inlineStart, ctx.lex.curEndPos)
    ctx.inlineProps = defaultProperties
    let headerEnd = ctx.lex.curStartPos
    ctx.updateIndentation(ctx.lex.recentIndentation())
    ctx.safeNext()
    if ctx.lex.cur == Token.MapValueInd:
      if ctx.lex.lastScalarWasMultiline():
        raise ctx.generateError("Implicit mapping key may not be multiline")
      ctx.keyCache.add(move(e))
      e = startMapEvent(csBlock, defaultProperties, headerEnd, headerEnd)
      ctx.transition(afterImplicitKey)
      ctx.pushLevel(emitCached)
    else:
      ctx.popLevel()
    return true
  of MapStart, SeqStart, StreamEnd, DocumentEnd, DirectivesEnd:
    ctx.transition(atBlockIndentationProps)
    return false
  else:
    raise ctx.generateError("Unexpected token (expected newline or flow item start: " & $ctx.lex.cur)

proc afterBlockParent(ctx: Context, e: var Event): bool =
  ctx.inlineStart = ctx.lex.curStartPos
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.transition(afterBlockParentProps)
    ctx.pushLevel(beforeNodeProperties)
  of SeqItemInd, MapKeyInd:
    raise ctx.generateError("Compact notation not allowed after implicit key")
  else:
    ctx.transition(afterBlockParentProps)
  return false

proc afterBlockParentProps(ctx: Context, e: var Event): bool =
  ctx.updateIndentation(ctx.lex.recentIndentation())
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.pushLevel(beforeNodeProperties)
    return false
  of MapValueInd:
    raise ctx.generateError("Compact notation not allowed after implicit key")
  of scalarTokenKind:
    e = scalarEvent(ctx.lex.evaluated, autoScalarTag(ctx.inlineProps, ctx.lex.cur),
                    toStyle(ctx.lex.cur), ctx.inlineStart, ctx.lex.curEndPos)
    ctx.inlineProps = defaultProperties
    ctx.safeNext()
    if ctx.lex.cur == Token.MapValueInd:
      raise ctx.generateError("Compact notation not allowed after implicit key")
    ctx.popLevel()
    return true
  else:
    ctx.transition(afterCompactParentProps)
    return false

proc mergePropsOnNewline(ctx: Context, e: var Event): bool =
  ctx.updateIndentation(ctx.lex.recentIndentation())
  if ctx.lex.cur == Token.Indentation:
    ctx.mergeProps(ctx.inlineProps, ctx.headerProps)
  ctx.transition(afterCompactParentProps)
  return false

proc beforeDocEnd(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of DocumentEnd:
    e = endDocEvent(true, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.transition(beforeDoc)
    ctx.safeNext()
    resetHandles(ctx.handles)
  of StreamEnd:
    e = endDocEvent(false, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.popLevel()
  of DirectivesEnd:
    e = endDocEvent(false, ctx.lex.curStartPos, ctx.lex.curStartPos)
    ctx.transition(beforeDoc)
    resetHandles(ctx.handles)
  else:
    raise ctx.generateError("Unexpected token (expected document end): " & $ctx.lex.cur)
  return true

proc inBlockSeq(ctx: Context, e: var Event): bool =
  if ctx.blockIndentation > ctx.levels[^1].indentation:
    raise ctx.generateError("Invalid indentation: got " & $ctx.blockIndentation & ", expected " & $ctx.levels[^1].indentation)
  case ctx.lex.cur
  of SeqItemInd:
    ctx.safeNext()
    ctx.pushLevel(beforeBlockIndentation)
    ctx.pushLevel(afterCompactParent, ctx.blockIndentation)
    return false
  else:
    if ctx.levels[^3].indentation == ctx.levels[^1].indentation:
      e = endSeqEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
      ctx.popLevel()
      ctx.popLevel()
      return true
    else:
      raise ctx.generateError("Illegal token (expected block sequence indicator): " & $ctx.lex.cur)

proc beforeBlockMapKey(ctx: Context, e: var Event): bool =
  if ctx.blockIndentation > ctx.levels[^1].indentation:
    raise ctx.generateError("Invalid indentation: got " & $ctx.blockIndentation & ", expected " & $ctx.levels[^1].indentation)
  ctx.inlineStart = ctx.lex.curStartPos
  case ctx.lex.cur
  of MapKeyInd:
    ctx.transition(beforeBlockMapValue)
    ctx.pushLevel(beforeBlockIndentation)
    ctx.pushLevel(afterCompactParent, ctx.blockIndentation)
    ctx.safeNext()
    return false
  of nodePropertyKind:
    ctx.transition(atBlockMapKeyProps)
    ctx.pushLevel(beforeNodeProperties)
    return false
  of Plain, SingleQuoted, DoubleQuoted:
    ctx.transition(atBlockMapKeyProps)
    return false
  of Alias:
    e = aliasEvent(ctx.lex.shortLexeme().Anchor, ctx.inlineStart, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.transition(afterImplicitKey)
    return true
  of MapValueInd:
    e = scalarEvent("", defaultProperties, ssPlain, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.transition(beforeBlockMapValue)
    return true
  else:
    raise ctx.generateError("Unexpected token (expected mapping key): " & $ctx.lex.cur)

proc atBlockMapKeyProps(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.pushLevel(beforeNodeProperties)
  of Alias:
    e = aliasEvent(ctx.lex.shortLexeme().Anchor, ctx.inlineStart, ctx.lex.curEndPos)
  of Plain, SingleQuoted, DoubleQuoted:
    e = scalarEvent(ctx.lex.evaluated, autoScalarTag(ctx.inlineProps, ctx.lex.cur),
                    toStyle(ctx.lex.cur), ctx.inlineStart, ctx.lex.curEndPos)
    ctx.inlineProps = defaultProperties
    if ctx.lex.lastScalarWasMultiline():
      raise ctx.generateError("Implicit mapping key may not be multiline")
  of MapValueInd:
    e = scalarEvent("", ctx.inlineProps, ssPlain, ctx.inlineStart, ctx.lex.curStartPos)
    ctx.inlineProps = defaultProperties
    ctx.transition(afterImplicitKey)
    return true
  else:
    raise ctx.generateError("Unexpected token (expected implicit mapping key): " & $ctx.lex.cur)
  ctx.safeNext()
  ctx.transition(afterImplicitKey)
  return true

proc afterImplicitKey(ctx: Context, e: var Event): bool =
  if ctx.lex.cur != Token.MapValueInd:
    raise ctx.generateError("Unexpected token (expected ':'): " & $ctx.lex.cur)
  ctx.safeNext()
  ctx.transition(beforeBlockMapKey)
  ctx.pushLevel(beforeBlockIndentation)
  ctx.pushLevel(afterBlockParent, max(0, ctx.levels[^2].indentation))
  return false

proc beforeBlockMapValue(ctx: Context, e: var Event): bool =
  if ctx.blockIndentation > ctx.levels[^1].indentation:
    raise ctx.generateError("Invalid indentation")
  case ctx.lex.cur
  of MapValueInd:
    ctx.transition(beforeBlockMapKey)
    ctx.pushLevel(beforeBlockIndentation)
    ctx.pushLevel(afterCompactParent, ctx.blockIndentation)
    ctx.safeNext()
  of MapKeyInd, Plain, SingleQuoted, DoubleQuoted, nodePropertyKind:
    # the value is allowed to be missing after an explicit key
    e = scalarEvent("", defaultProperties, ssPlain, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.transition(beforeBlockMapKey)
    return true
  else:
    raise ctx.generateError("Unexpected token (expected mapping value): " & $ctx.lex.cur)

proc beforeBlockIndentation(ctx: Context, e: var Event): bool =
  proc endBlockNode(e: var Event) =
    if ctx.levels[^1].state == beforeBlockMapKey:
      e = endMapEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
    elif ctx.levels[^1].state == beforeBlockMapValue:
      e = scalarEvent("", defaultProperties, ssPlain, ctx.lex.curStartPos, ctx.lex.curEndPos)
      ctx.transition(beforeBlockMapKey)
      ctx.pushLevel(beforeBlockIndentation)
      return
    elif ctx.levels[^1].state == inBlockSeq:
      e = endSeqEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
    elif ctx.levels[^1].state == atBlockIndentation:
      e = scalarEvent("", ctx.headerProps, ssPlain, ctx.headerStart, ctx.headerStart)
      ctx.headerProps = defaultProperties
    elif ctx.levels[^1].state == beforeBlockIndentation:
      raise ctx.generateError("Unexpected double beforeBlockIndentation")
    else:
      raise ctx.generateError("Internal error (please report this bug): unexpected state at endBlockNode")
    ctx.popLevel()
  ctx.popLevel()
  case ctx.lex.cur
  of Indentation:
    ctx.blockIndentation = ctx.lex.currentIndentation()
    if ctx.blockIndentation < ctx.levels[^1].indentation:
      endBlockNode(e)
      return true
    else:
      ctx.safeNext()
      return false
  of StreamEnd, DocumentEnd, DirectivesEnd:
    ctx.blockIndentation = 0
    if ctx.levels[^1].state != beforeDocEnd:
      endBlockNode(e)
      return true
    else:
      return false
  else:
    raise ctx.generateError("Unexpected content after node in block context (expected newline): " & $ctx.lex.cur)

proc beforeFlowItem(ctx: Context, e: var Event): bool =
  ctx.inlineStart = ctx.lex.curStartPos
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.transition(beforeFlowItemProps)
    ctx.pushLevel(beforeNodeProperties)
  of Alias:
    e = aliasEvent(ctx.lex.shortLexeme().Anchor, ctx.inlineStart, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.popLevel()
    return true
  else:
    ctx.transition(beforeFlowItemProps)
  return false

proc beforeFlowItemProps(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of nodePropertyKind:
    ctx.pushLevel(beforeNodeProperties)
  of Alias:
    e = aliasEvent(ctx.lex.shortLexeme().Anchor, ctx.inlineStart, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.popLevel()
  of scalarTokenKind:
    e = scalarEvent(ctx.lex.evaluated, autoScalarTag(ctx.inlineProps, ctx.lex.cur),
                    toStyle(ctx.lex.cur), ctx.inlineStart, ctx.lex.curEndPos)
    ctx.inlineProps = defaultProperties
    ctx.safeNext()
    ctx.popLevel()
  of MapStart:
    e = startMapEvent(csFlow, ctx.inlineProps, ctx.inlineStart, ctx.lex.curEndPos)
    ctx.transition(afterFlowMapSep)
    ctx.safeNext()
  of SeqStart:
    e = startSeqEvent(csFlow, ctx.inlineProps, ctx.inlineStart, ctx.lex.curEndPos)
    ctx.transition(afterFlowSeqSep)
    ctx.safeNext()
  of MapEnd, SeqEnd, SeqSep, MapValueInd:
    e = scalarEvent("", ctx.inlineProps, ssPlain, ctx.inlineStart, ctx.lex.curEndPos)
    ctx.popLevel()
  else:
    raise ctx.generateError("Unexpected token (expected flow node): " & $ctx.lex.cur)
  ctx.inlineProps = defaultProperties
  return true

proc afterFlowMapKey(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of MapValueInd:
    ctx.transition(afterFlowMapValue)
    ctx.pushLevel(beforeFlowItem)
    ctx.safeNext()
    return false
  of SeqSep, MapEnd:
    e = scalarEvent("", defaultProperties, ssPlain, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.transition(afterFlowMapValue)
    return true
  else:
    raise ctx.generateError("Unexpected token (expected ':'): " & $ctx.lex.cur)

proc afterFlowMapValue(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of SeqSep:
    ctx.transition(afterFlowMapSep)
    ctx.safeNext()
    return false
  of MapEnd:
    e = endMapEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.popLevel()
    return true
  of Plain, SingleQuoted, DoubleQuoted, MapKeyInd, Token.Anchor, Alias, MapStart, SeqStart:
    raise ctx.generateError("Missing ','")
  else:
    raise ctx.generateError("Unexpected token (expected ',' or '}'): " & $ctx.lex.cur)

proc afterFlowSeqItem(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of SeqSep:
    ctx.transition(afterFlowSeqSep)
    ctx.safeNext()
    return false
  of SeqEnd:
    e = endSeqEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.popLevel()
    return true
  of Plain, SingleQuoted, DoubleQuoted, MapKeyInd, Token.Anchor, Alias, MapStart, SeqStart:
    raise ctx.generateError("Missing ','")
  else:
    raise ctx.generateError("Unexpected token (expected ',' or ']'): " & $ctx.lex.cur)

proc afterFlowMapSep(ctx: Context, e: var Event): bool =
  case ctx.lex.cur
  of MapKeyInd:
    ctx.safeNext()
  of MapEnd:
    e = endMapEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.popLevel()
    return true
  of SeqSep:
    raise ctx.generateError("Missing mapping entry between commas (use '?' for an empty mapping entry)")
  else: discard
  ctx.transition(afterFlowMapKey)
  ctx.pushLevel(beforeFlowItem)
  return false

proc afterFlowSeqSep(ctx: Context, e: var Event): bool =
  ctx.inlineStart = ctx.lex.curStartPos
  case ctx.lex.cur
  of SeqSep:
    e = scalarEvent("", defaultProperties, ssPlain, ctx.lex.curStartPos, ctx.lex.curStartPos)
    ctx.safeNext()
    return true
  of nodePropertyKind:
    ctx.transition(afterFlowSeqSepProps)
    ctx.pushLevel(beforeNodeProperties)
    return false
  of Plain, SingleQuoted, DoubleQuoted, MapStart, SeqStart:
    ctx.transition(afterFlowSeqSepProps)
    return false
  of MapKeyInd:
    ctx.transition(afterFlowSeqSepProps)
    e = startMapEvent(csFlow, defaultProperties, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.transition(afterFlowSeqItem)
    ctx.pushLevel(beforePairValue)
    ctx.pushLevel(beforeFlowItem)
    return true
  of MapValueInd:
    ctx.transition(afterFlowSeqItem)
    e = startMapEvent(csFlow, defaultProperties, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.pushLevel(atEmptyPairKey)
    return true
  of SeqEnd:
    e = endSeqEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.safeNext()
    ctx.popLevel()
    return true
  else:
    ctx.transition(afterFlowSeqItem)
    ctx.pushLevel(beforeFlowItem)
    return false

proc afterFlowSeqSepProps(ctx: Context, e: var Event): bool =
  # here we handle potential implicit single pairs within flow sequences.
  ctx.transition(afterFlowSeqItem)
  case ctx.lex.cur
  of Plain, SingleQuoted, DoubleQuoted:
    e = scalarEvent(ctx.lex.evaluated, autoScalarTag(ctx.inlineProps, ctx.lex.cur),
                    toStyle(ctx.lex.cur), ctx.inlineStart, ctx.lex.curEndPos)
    ctx.inlineProps = defaultProperties
    ctx.safeNext()
    if ctx.lex.cur == Token.MapValueInd:
      ctx.pushLevel(afterImplicitPairStart)
      if ctx.caching:
        ctx.keyCache.add(startMapEvent(csFlow, defaultProperties, ctx.lex.curStartPos, ctx.lex.curStartPos))
      else:
        ctx.keyCache.add(move(e))
        e = startMapEvent(csFlow, defaultProperties, ctx.lex.curStartPos, ctx.lex.curStartPos)
        ctx.pushLevel(emitCached)
    return true
  of MapStart, SeqStart:
    let
      startPos = ctx.lex.curStartPos
      indent = ctx.levels[^1].indentation
      cacheStart = ctx.keyCache.len
      levelDepth = ctx.levels.len
      alreadyCaching = ctx.caching
    ctx.pushLevel(beforeFlowItemProps)
    ctx.caching = true
    while ctx.levels.len > levelDepth:
      ctx.keyCache.add(ctx.next())
    ctx.caching = alreadyCaching
    if ctx.lex.cur == Token.MapValueInd:
      ctx.pushLevel(afterImplicitPairStart, indent)
      if ctx.lex.curStartPos.line != startPos.line:
        raise ctx.generateError("Implicit mapping key may not be multiline")
      if not alreadyCaching:
        ctx.pushLevel(emitCached)
        e = startMapEvent(csPair, defaultProperties, startPos, startPos)
        return true
      else:
        # we are already filling a cache.
        # so we just squeeze the map start in.
        ctx.keyCache.insert(startMapEvent(csPair, defaultProperties, startPos, startPos), cacheStart)
        return false
    else:
      if not alreadyCaching:
        ctx.pushLevel(emitCached)
      return false
  else:
    ctx.pushLevel(beforeFlowItem)
    return false

proc atEmptyPairKey(ctx: Context, e: var Event): bool =
  ctx.transition(beforePairValue)
  e = scalarEvent("", defaultProperties, ssPlain, ctx.lex.curStartPos, ctx.lex.curStartPos)
  return true

proc beforePairValue(ctx: Context, e: var Event): bool =
  if ctx.lex.cur == Token.MapValueInd:
    ctx.transition(afterPairValue)
    ctx.pushLevel(beforeFlowItem)
    ctx.safeNext()
    return false
  else:
    # pair ends here without value
    e = scalarEvent("", defaultProperties, ssPlain, ctx.lex.curStartPos, ctx.lex.curEndPos)
    ctx.popLevel()
    return true

proc afterImplicitPairStart(ctx: Context, e: var Event): bool =
  ctx.safeNext()
  ctx.transition(afterPairValue)
  ctx.pushLevel(beforeFlowItem)
  return false

proc afterPairValue(ctx: Context, e: var Event): bool =
  e = endMapEvent(ctx.lex.curStartPos, ctx.lex.curEndPos)
  ctx.popLevel()
  return true

proc emitCached(ctx: Context, e: var Event): bool =
  debug("emitCollection key: pos = " & $ctx.keyCachePos & ", len = " & $ctx.keyCache.len)
  yAssert(ctx.keyCachePos < ctx.keyCache.len)
  e = move(ctx.keyCache[ctx.keyCachePos])
  inc(ctx.keyCachePos)
  if ctx.keyCachePos == len(ctx.keyCache):
    ctx.keyCache.setLen(0)
    ctx.keyCachePos = 0
    ctx.popLevel()
  return true

proc display*(p: YamlParser, event: Event): string =
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
  of yamlStartStream: result = "+STR"
  of yamlEndStream: result = "-STR"
  of yamlEndMap: result = "-MAP"
  of yamlEndSeq: result = "-SEQ"
  of yamlStartDoc:
    result = "+DOC"
    if event.explicitDirectivesEnd: result &= " ---"
  of yamlEndDoc:
    result = "-DOC"
    if event.explicitDocumentEnd: result &= " ..."
  of yamlStartMap:
    result = "+MAP" & renderAttrs(event.mapProperties, true)
  of yamlStartSeq:
    result = "+SEQ" & renderAttrs(event.seqProperties, true)
  of yamlScalar:
    result = "=VAL" & renderAttrs(event.scalarProperties,
                                  event.scalarStyle in {ssPlain, ssFolded, ssLiteral})
    case event.scalarStyle
    of ssPlain, ssAny: result &= " :"
    of ssSingleQuoted: result &= " \'"
    of ssDoubleQuoted: result &= " \""
    of ssLiteral: result &= " |"
    of ssFolded: result &= " >"
    result &= yamlTestSuiteEscape(event.scalarContent)
  of yamlAlias: result = "=ALI *" & $event.aliasTarget