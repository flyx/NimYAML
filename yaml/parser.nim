#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
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

  State = proc(c: Context, e: var Event): bool {.gcSafe.}

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

  YamlLoadingError* = object of ValueError
    ## Base class for all exceptions that may be raised during the process
    ## of loading a YAML character stream.
    mark*: Mark ## position at which the error has occurred.
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

const defaultProperties = (yAnchorNone, yTagQuestionMark)

# parser states

{.push gcSafe, .}
proc atStreamStart(c: Context, e: var Event): bool
proc atStreamEnd(c: Context, e : var Event): bool
proc beforeDoc(c: Context, e: var Event): bool
proc beforeDocEnd(c: Context, e: var Event): bool
proc afterDirectivesEnd(c: Context, e: var Event): bool
proc beforeImplicitRoot(c: Context, e: var Event): bool
proc atBlockIndentation(c: Context, e: var Event): bool
proc beforeBlockIndentation(c: Context, e: var Event): bool
proc beforeNodeProperties(c: Context, e: var Event): bool
proc afterCompactParent(c: Context, e: var Event): bool
proc afterCompactParentProps(c: Context, e: var Event): bool
proc mergePropsOnNewline(c: Context, e: var Event): bool
proc beforeFlowItemProps(c: Context, e: var Event): bool
proc inBlockSeq(c: Context, e: var Event): bool
proc beforeBlockMapValue(c: Context, e: var Event): bool
proc atBlockIndentationProps(c: Context, e: var Event): bool
proc beforeFlowItem(c: Context, e: var Event): bool
proc afterFlowSeqSep(c: Context, e: var Event): bool
proc afterFlowMapSep(c: Context, e: var Event): bool
proc atBlockMapKeyProps(c: Context, e: var Event): bool
proc afterImplicitKey(c: Context, e: var Event): bool
proc afterBlockParent(c: Context, e: var Event): bool
proc afterBlockParentProps(c: Context, e: var Event): bool
proc afterImplicitPairStart(c: Context, e: var Event): bool
proc beforePairValue(c: Context, e: var Event): bool
proc atEmptyPairKey(c: Context, e: var Event): bool
proc afterFlowMapValue(c: Context, e: var Event): bool
proc afterFlowSeqSepProps(c: Context, e: var Event): bool
proc afterFlowSeqItem(c: Context, e: var Event): bool
proc afterPairValue(c: Context, e: var Event): bool
proc emitCached(c: Context, e: var Event): bool
{.pop.}

template pushLevel(c: Context, newState: State, newIndent: int) =
  debug("parser: push " & newState.astToStr & ", indent = " & $newIndent)
  c.levels.add(Level(state: newState, indentation: newIndent))

template pushLevel(c: Context, newState: State) =
  debug("parser: push " & newState.astToStr)
  c.levels.add(Level(state: newState))

template transition(c: Context, newState: State) =
  debug("parser: transition " & newState.astToStr)
  c.levels[^1].state = newState

template transition(c: Context, newState: State, newIndent) =
  debug("parser: transtion " & newState.astToStr & ", indent = " & $newIndent)
  c.levels[^1] = Level(state: newState, indentation: newIndent)

template updateIndentation(c: Context, newIndent: int) =
  debug("parser: update indent = " & $newIndent)
  c.levels[^1].indentation = newIndent

template popLevel(c: Context) =
  debug("parser: pop")
  discard c.levels.pop()

proc resolveHandle(c: Context, handle: string): string {.raises: [].} =
  for item in c.handles:
    if item.handle == handle:
      return item.uriPrefix
  return ""

proc init[T](c: Context, p: YamlParser, source: T) {.inline.} =
  c.pushLevel(atStreamStart, -2)
  c.nextImpl = proc(s: YamlStream, e: var Event): bool =
    let c = Context(s)
    return c.levels[^1].state(c, e)
  c.lastTokenContextImpl = proc(s: YamlStream, lineContent: var string): bool =
    lineContent = Context(s).lex.currentLine()
    return true
  c.headerProps = defaultProperties
  c.inlineProps = defaultProperties
  c.issueWarnings = p.issueWarnings
  c.lex.init(source)
  c.keyCachePos = 0
  c.caching = false

# interface

proc init*(p: var YamlParser, issueWarnings: bool = false) =
  ## Initializes a YAML parser.
  p.issueWarnings = issueWarnings

proc initYamlParser*(issueWarnings: bool = false): YamlParser =
  ## Creates an initializes YAML parser and returns it
  result.issueWarnings = issueWarnings

proc parse*(p: YamlParser, s: Stream): YamlStream =
  let c = new(Context)
  c.init(p, s)
  return c

proc parse*(p: YamlParser, s: string): YamlStream =
  let c = new(Context)
  c.init(p, s)
  return c

# implementation

proc isEmpty(props: Properties): bool =
  result = props.anchor == yAnchorNone and
           props.tag == yTagQuestionMark

proc generateError(c: Context, message: string):
    ref YamlParserError {.raises: [], .} =
  result = (ref YamlParserError)(
    msg: message, parent: nil, mark: c.lex.curStartPos,
    lineContent: c.lex.currentLine())

proc parseTag(c: Context): Tag =
  let handle = c.lex.fullLexeme()
  var uri = c.resolveHandle(handle)
  if uri == "":
    raise c.generateError("unknown handle: " & escape(handle))
  c.lex.next()
  if c.lex.cur != Token.Suffix:
    raise c.generateError("unexpected token (expected tag suffix): " & $c.lex.cur)
  uri.add(c.lex.evaluated)
  return Tag(uri)

proc toStyle(t: Token): ScalarStyle =
  return (case t
    of Plain: ssPlain
    of SingleQuoted: ssSingleQuoted
    of DoubleQuoted: ssDoubleQuoted
    of Literal: ssLiteral
    of Folded: ssFolded
    else: ssAny)

proc mergeProps(c: Context, src, target: var Properties) =
  if src.tag != yTagQuestionMark:
    if target.tag != yTagQuestionMark:
      raise c.generateError("Only one tag allowed per node")
    target.tag = src.tag
    src.tag = yTagQuestionMark
  if src.anchor != yAnchorNone:
    if target.anchor != yAnchorNone:
      raise c.generateError("Only one anchor allowed per node")
    target.anchor = src.anchor
    src.anchor = yAnchorNone

proc autoScalarTag(props: Properties, t: Token): Properties =
  result = props
  if t in {Token.SingleQuoted, Token.DoubleQuoted} and
      props.tag == yTagQuestionMark:
    result.tag = yTagExclamationMark

proc atStreamStart(c: Context, e: var Event): bool =
  c.transition(atStreamEnd)
  c.pushLevel(beforeDoc, -1)
  e = Event(startPos: c.lex.curStartPos, endPos: c.lex.curStartPos, kind: yamlStartStream)
  c.lex.next()
  resetHandles(c.handles)
  return true

proc atStreamEnd(c: Context, e : var Event): bool =
  e = Event(startPos: c.lex.curStartPos,
            endPos: c.lex.curStartPos, kind: yamlEndStream)
  return true

proc beforeDoc(c: Context, e: var Event): bool =
  var version = ""
  var seenDirectives = false
  while true:
    case c.lex.cur
    of DocumentEnd:
      if seenDirectives:
        raise c.generateError("Missing `---` after directives")
      c.lex.next()
    of DirectivesEnd:
      e = startDocEvent(true, version, c.handles, c.lex.curStartPos, c.lex.curEndPos)
      c.lex.next()
      c.transition(beforeDocEnd)
      c.pushLevel(afterDirectivesEnd, -1)
      return true
    of StreamEnd:
      if seenDirectives:
        raise c.generateError("Missing `---` after directives")
      c.popLevel()
      return false
    of Indentation:
      e = startDocEvent(false, version, c.handles, c.lex.curStartPos, c.lex.curEndPos)
      c.transition(beforeDocEnd)
      c.pushLevel(beforeImplicitRoot, -1)
      return true
    of YamlDirective:
      seenDirectives = true
      c.lex.next()
      if c.lex.cur != Token.DirectiveParam:
        raise c.generateError("Invalid token (expected YAML version string): " & $c.lex.cur)
      elif version != "":
        raise c.generateError("Duplicate %YAML")
      version = c.lex.fullLexeme()
      if version != "1.2" and c.issueWarnings:
        discard # TODO
      c.lex.next()
    of TagDirective:
      seenDirectives = true
      c.lex.next()
      if c.lex.cur != Token.TagHandle:
        raise c.generateError("Invalid token (expected tag handle): " & $c.lex.cur)
      let tagHandle = c.lex.fullLexeme()
      c.lex.next()
      if c.lex.cur != Token.Suffix:
        raise c.generateError("Invalid token (expected tag URI): " & $c.lex.cur)
      discard registerHandle(c.handles, tagHandle, c.lex.evaluated)
      c.lex.next()
    of UnknownDirective:
      seenDirectives = true
      # TODO: issue warning
      while true:
        c.lex.next()
        if c.lex.cur != Token.DirectiveParam: break
    else:
      raise c.generateError("Unexpected token (expected directive or document start): " & $c.lex.cur)

proc afterDirectivesEnd(c: Context, e: var Event): bool =
  case c.lex.cur
  of nodePropertyKind:
    c.inlineStart = c.lex.curStartPos
    c.pushLevel(beforeNodeProperties)
    return false
  of Indentation:
    c.headerStart = c.inlineStart
    c.transition(atBlockIndentation)
    c.pushLevel(beforeBlockIndentation)
    return false
  of DocumentEnd, DirectivesEnd, StreamEnd:
    e = scalarEvent("", c.inlineProps, ssPlain, c.lex.curStartPos, c.lex.curEndPos)
    c.popLevel()
    return true
  of scalarTokenKind:
    e = scalarEvent(c.lex.evaluated, autoScalarTag(c.inlineProps, c.lex.cur),
                    toStyle(c.lex.cur), c.lex.curStartPos, c.lex.curEndPos)
    c.popLevel()
    c.lex.next()
    return true
  else:
    raise c.generateError("Illegal content at `---`: " & $c.lex.cur)

proc beforeImplicitRoot(c: Context, e: var Event): bool =
  if c.lex.cur != Token.Indentation:
    raise c.generateError("Unexpected token (expected line start): " & $c.lex.cur)
  c.inlineStart = c.lex.curEndPos
  c.headerStart = c.lex.curEndPos
  c.updateIndentation(c.lex.recentIndentation())
  c.lex.next()
  case c.lex.cur
  of SeqItemInd, MapKeyInd, MapValueInd:
    c.transition(afterCompactParent)
    return false
  of scalarTokenKind, MapStart, SeqStart:
    c.transition(atBlockIndentationProps)
    return false
  of nodePropertyKind:
    c.transition(atBlockIndentationProps)
    c.pushLevel(beforeNodeProperties)
  else:
    raise c.generateError("Unexpected token (expected collection start): " & $c.lex.cur)

proc atBlockIndentation(c: Context, e: var Event): bool =
  if c.blockIndentation == c.levels[^1].indentation and
      (c.lex.cur != Token.SeqItemInd or
       c.levels[^3].state == inBlockSeq):
    e = scalarEvent("", c.headerProps, ssPlain,
                    c.headerStart, c.headerStart)
    c.headerProps = defaultProperties
    c.popLevel()
    c.popLevel()
    return true
  c.inlineStart = c.lex.curStartPos
  c.updateIndentation(c.lex.recentIndentation())
  case c.lex.cur
  of nodePropertyKind:
    if isEmpty(c.headerProps):
      c.transition(mergePropsOnNewline)
    else:
      c.transition(atBlockIndentationProps)
    c.pushLevel(beforeNodeProperties)
    return false
  of SeqItemInd:
    e = startSeqEvent(csBlock, c.headerProps,
                      c.headerStart, c.lex.curEndPos)
    c.headerProps = defaultProperties
    c.transition(inBlockSeq, c.lex.recentIndentation())
    c.pushLevel(beforeBlockIndentation)
    c.pushLevel(afterCompactParent, c.lex.recentIndentation())
    c.lex.next()
    return true
  of MapKeyInd:
    e = startMapEvent(csBlock, c.headerProps,
                      c.headerStart, c.lex.curEndPos)
    c.headerProps = defaultProperties
    c.transition(beforeBlockMapValue, c.lex.recentIndentation())
    c.pushLevel(beforeBlockIndentation)
    c.pushLevel(afterCompactParent, c.lex.recentIndentation())
    c.lex.next()
    return true
  of Plain, SingleQuoted, DoubleQuoted:
    c.updateIndentation(c.lex.recentIndentation())
    let scalarToken = c.lex.cur
    e = scalarEvent(c.lex.evaluated, c.headerProps,
                    toStyle(c.lex.cur), c.inlineStart, c.lex.curEndPos)
    c.headerProps = defaultProperties
    let headerEnd = c.lex.curStartPos
    c.lex.next()
    if c.lex.cur == Token.MapValueInd:
      if c.lex.lastScalarWasMultiline():
        raise c.generateError("Implicit mapping key may not be multiline")
      let props = e.scalarProperties
      e.scalarProperties = autoScalarTag(defaultProperties, scalarToken)
      c.keyCache.add(move(e))
      e = startMapEvent(csBlock, props, c.headerStart, headerEnd)
      c.transition(afterImplicitKey)
      c.pushLevel(emitCached)
    else:
      e.scalarProperties = autoScalarTag(e.scalarProperties, scalarToken)
      c.popLevel()
    return true
  of Alias:
    e = aliasEvent(c.lex.shortLexeme().Anchor, c.inlineStart, c.lex.curEndPos)
    c.inlineProps = defaultProperties
    let headerEnd = c.lex.curStartPos
    c.lex.next()
    if c.lex.cur == Token.MapValueInd:
      c.keyCache.add(move(e))
      e = startMapEvent(csBlock, c.headerProps, c.headerStart, headerEnd)
      c.headerProps = defaultProperties
      c.transition(afterImplicitKey)
      c.pushLevel(emitCached)
    elif not isEmpty(c.headerProps):
      raise c.generateError("Alias may not have properties")
    else:
      c.popLevel()
    return true
  else:
    c.transition(atBlockIndentationProps)
    return false

proc atBlockIndentationProps(c: Context, e: var Event): bool =
  c.updateIndentation(c.lex.recentIndentation())
  case c.lex.cur
  of MapValueInd:
    c.keyCache.add(scalarEvent("", c.inlineProps, ssPlain, c.inlineStart, c.lex.curEndPos))
    c.inlineProps = defaultProperties
    e = startMapEvent(csBlock, c.headerProps, c.lex.curStartPos, c.lex.curEndPos)
    c.headerProps = defaultProperties
    c.transition(afterImplicitKey)
    c.pushLevel(emitCached)
    return true
  of Plain, SingleQuoted, DoubleQuoted:
    e = scalarEvent(c.lex.evaluated, autoScalarTag(c.inlineProps, c.lex.cur),
                    toStyle(c.lex.cur), c.inlineStart, c.lex.curEndPos)
    c.inlineProps = defaultProperties
    let headerEnd = c.lex.curStartPos
    c.lex.next()
    if c.lex.cur == Token.MapValueInd:
      if c.lex.lastScalarWasMultiline():
        raise c.generateError("Implicit mapping key may not be multiline")
      c.keyCache.add(move(e))
      e = startMapEvent(csBlock, c.headerProps, c.headerStart, headerEnd)
      c.headerProps = defaultProperties
      c.transition(afterImplicitKey)
      c.pushLevel(emitCached)
    else:
      c.mergeProps(c.headerProps, e.scalarProperties)
      c.popLevel()
    return true
  of MapStart, SeqStart:
    let
      startPos = c.lex.curStartPos
      indent = c.lex.currentIndentation()
      levelDepth = c.levels.len
    c.transition(beforeFlowItemProps)
    c.caching = true
    while c.levels.len >= levelDepth:
      c.keyCache.add(c.next())
    c.caching = false
    if c.lex.cur == Token.MapValueInd:
      c.pushLevel(afterImplicitKey, indent)
      c.pushLevel(emitCached)
      if c.lex.curStartPos.line != startPos.line:
        raise c.generateError("Implicit mapping key may not be multiline")
      e = startMapEvent(csBlock, c.headerProps, c.headerStart, startPos)
      c.headerProps = defaultProperties
      return true
    else:
      c.pushLevel(emitCached)
      return false
  of Literal, Folded:
    c.mergeProps(c.inlineProps, c.headerProps)
    e = scalarEvent(c.lex.evaluated, c.headerProps, toStyle(c.lex.cur),
                    c.inlineStart, c.lex.curEndPos)
    c.headerProps = defaultProperties
    c.lex.next()
    c.popLevel()
    return true
  of Indentation:
    c.lex.next()
    c.transition(atBlockIndentation)
    return false
  of StreamEnd, DocumentEnd, DirectivesEnd:
    e = scalarEvent("", c.inlineProps, ssPlain, c.inlineStart, c.lex.curStartPos)
    c.inlineProps = defaultProperties
    c.popLevel()
    return true
  else:
    raise c.generateError("Unexpected token (expected block content): " & $c.lex.cur)

proc beforeNodeProperties(c: Context, e: var Event): bool =
  case c.lex.cur
  of TagHandle:
    if c.inlineProps.tag != yTagQuestionMark:
      raise c.generateError("Only one tag allowed per node")
    c.inlineProps.tag = c.parseTag()
  of VerbatimTag:
    if c.inlineProps.tag != yTagQuestionMark:
      raise c.generateError("Only one tag allowed per node")
    c.inlineProps.tag = Tag(move(c.lex.evaluated))
  of Token.Anchor:
    if c.inlineProps.anchor != yAnchorNone:
      raise c.generateError("Only one anchor allowed per node")
    c.inlineProps.anchor = c.lex.shortLexeme().Anchor
  of Indentation:
    c.mergeProps(c.inlineProps, c.headerProps)
    c.popLevel()
    return false
  of Alias:
    raise c.generateError("Alias may not have node properties")
  else:
    c.popLevel()
    return false
  c.lex.next()
  return false

proc afterCompactParent(c: Context, e: var Event): bool =
  c.inlineStart = c.lex.curStartPos
  case c.lex.cur
  of nodePropertyKind:
    c.transition(afterCompactParentProps)
    c.pushLevel(beforeNodeProperties)
  of SeqItemInd:
    e = startSeqEvent(csBlock, c.headerProps, c.headerStart, c.lex.curEndPos)
    c.headerProps = defaultProperties
    c.transition(inBlockSeq, c.lex.recentIndentation())
    c.pushLevel(beforeBlockIndentation)
    c.pushLevel(afterCompactParent, c.lex.recentIndentation())
    c.lex.next()
    return true
  of MapKeyInd:
    e = startMapEvent(csBlock, c.headerProps, c.headerStart, c.lex.curEndPos)
    c.headerProps = defaultProperties
    c.transition(beforeBlockMapValue, c.lex.recentIndentation())
    c.pushLevel(beforeBlockIndentation)
    c.pushLevel(afterCompactParent, c.lex.recentIndentation)
    c.lex.next()
    return true
  else:
    c.transition(afterCompactParentProps)
    return false

proc afterCompactParentProps(c: Context, e: var Event): bool =
  c.updateIndentation(c.lex.recentIndentation())
  case c.lex.cur
  of nodePropertyKind:
    c.pushLevel(beforeNodeProperties)
    return false
  of Indentation:
    c.headerStart = c.inlineStart
    c.transition(atBlockIndentation, c.levels[^3].indentation)
    c.pushLevel(beforeBlockIndentation)
    return false
  of MapValueInd:
    c.keyCache.add(scalarEvent("", c.inlineProps, ssPlain, c.inlineStart, c.lex.curStartPos))
    c.inlineProps = defaultProperties
    e = startMapEvent(csBlock, defaultProperties, c.lex.curStartPos, c.lex.curStartPos)
    c.transition(afterImplicitKey)
    c.pushLevel(emitCached)
    return true
  of Alias:
    e = aliasEvent(c.lex.shortLexeme().Anchor, c.inlineStart, c.lex.curEndPos)
    let headerEnd = c.lex.curStartPos
    c.lex.next()
    if c.lex.cur == Token.MapValueInd:
      c.keyCache.add(move(e))
      e = startMapEvent(csBlock, defaultProperties, headerEnd, headerEnd)
      c.transition(afterImplicitKey)
      c.pushLevel(emitCached)
    else:
      c.popLevel()
    return true
  of scalarTokenKind:
    e = scalarEvent(c.lex.evaluated, autoScalarTag(c.inlineProps, c.lex.cur),
                    toStyle(c.lex.cur), c.inlineStart, c.lex.curEndPos)
    c.inlineProps = defaultProperties
    let headerEnd = c.lex.curStartPos
    c.updateIndentation(c.lex.recentIndentation())
    c.lex.next()
    if c.lex.cur == Token.MapValueInd:
      if c.lex.lastScalarWasMultiline():
        raise c.generateError("Implicit mapping key may not be multiline")
      c.keyCache.add(move(e))
      e = startMapEvent(csBlock, defaultProperties, headerEnd, headerEnd)
      c.transition(afterImplicitKey)
      c.pushLevel(emitCached)
    else:
      c.popLevel()
    return true
  of MapStart, SeqStart, StreamEnd, DocumentEnd, DirectivesEnd:
    c.transition(atBlockIndentationProps)
    return false
  else:
    raise c.generateError("Unexpected token (expected newline or flow item start: " & $c.lex.cur)

proc afterBlockParent(c: Context, e: var Event): bool =
  c.inlineStart = c.lex.curStartPos
  case c.lex.cur
  of nodePropertyKind:
    c.transition(afterBlockParentProps)
    c.pushLevel(beforeNodeProperties)
  of SeqItemInd, MapKeyInd:
    raise c.generateError("Compact notation not allowed after implicit key")
  else:
    c.transition(afterBlockParentProps)
  return false

proc afterBlockParentProps(c: Context, e: var Event): bool =
  c.updateIndentation(c.lex.recentIndentation())
  case c.lex.cur
  of nodePropertyKind:
    c.pushLevel(beforeNodeProperties)
    return false
  of MapValueInd:
    raise c.generateError("Compact notation not allowed after implicit key")
  of scalarTokenKind:
    e = scalarEvent(c.lex.evaluated, autoScalarTag(c.inlineProps, c.lex.cur),
                    toStyle(c.lex.cur), c.inlineStart, c.lex.curEndPos)
    c.inlineProps = defaultProperties
    c.lex.next()
    if c.lex.cur == Token.MapValueInd:
      raise c.generateError("Compact notation not allowed after implicit key")
    c.popLevel()
    return true
  else:
    c.transition(afterCompactParentProps)
    return false

proc mergePropsOnNewline(c: Context, e: var Event): bool =
  c.updateIndentation(c.lex.recentIndentation())
  if c.lex.cur == Token.Indentation:
    c.mergeProps(c.inlineProps, c.headerProps)
  c.transition(afterCompactParentProps)
  return false

proc beforeDocEnd(c: Context, e: var Event): bool =
  case c.lex.cur
  of DocumentEnd:
    e = endDocEvent(true, c.lex.curStartPos, c.lex.curEndPos)
    c.transition(beforeDoc)
    c.lex.next()
    resetHandles(c.handles)
  of StreamEnd:
    e = endDocEvent(false, c.lex.curStartPos, c.lex.curEndPos)
    c.popLevel()
  of DirectivesEnd:
    e = endDocEvent(false, c.lex.curStartPos, c.lex.curStartPos)
    c.transition(beforeDoc)
    resetHandles(c.handles)
  else:
    raise c.generateError("Unexpected token (expected document end): " & $c.lex.cur)
  return true

proc inBlockSeq(c: Context, e: var Event): bool =
  if c.blockIndentation > c.levels[^1].indentation:
    raise c.generateError("Invalid indentation: got " & $c.blockIndentation & ", expected " & $c.levels[^1].indentation)
  case c.lex.cur
  of SeqItemInd:
    c.lex.next()
    c.pushLevel(beforeBlockIndentation)
    c.pushLevel(afterCompactParent, c.blockIndentation)
    return false
  else:
    if c.levels[^3].indentation == c.levels[^1].indentation:
      e = endSeqEvent(c.lex.curStartPos, c.lex.curEndPos)
      c.popLevel()
      c.popLevel()
      return true
    else:
      raise c.generateError("Illegal token (expected block sequence indicator): " & $c.lex.cur)

proc beforeBlockMapKey(c: Context, e: var Event): bool =
  if c.blockIndentation > c.levels[^1].indentation:
    raise c.generateError("Invalid indentation: got " & $c.blockIndentation & ", expected " & $c.levels[^1].indentation)
  c.inlineStart = c.lex.curStartPos
  case c.lex.cur
  of MapKeyInd:
    c.transition(beforeBlockMapValue)
    c.pushLevel(beforeBlockIndentation)
    c.pushLevel(afterCompactParent, c.blockIndentation)
    c.lex.next()
    return false
  of nodePropertyKind:
    c.transition(atBlockMapKeyProps)
    c.pushLevel(beforeNodeProperties)
    return false
  of Plain, SingleQuoted, DoubleQuoted:
    c.transition(atBlockMapKeyProps)
    return false
  of Alias:
    e = aliasEvent(c.lex.shortLexeme().Anchor, c.inlineStart, c.lex.curEndPos)
    c.lex.next()
    c.transition(afterImplicitKey)
    return true
  of MapValueInd:
    e = scalarEvent("", defaultProperties, ssPlain, c.lex.curStartPos, c.lex.curEndPos)
    c.transition(beforeBlockMapValue)
    return true
  else:
    raise c.generateError("Unexpected token (expected mapping key): " & $c.lex.cur)

proc atBlockMapKeyProps(c: Context, e: var Event): bool =
  case c.lex.cur
  of nodePropertyKind:
    c.pushLevel(beforeNodeProperties)
  of Alias:
    e = aliasEvent(c.lex.shortLexeme().Anchor, c.inlineStart, c.lex.curEndPos)
  of Plain, SingleQuoted, DoubleQuoted:
    e = scalarEvent(c.lex.evaluated, autoScalarTag(c.inlineProps, c.lex.cur),
                    toStyle(c.lex.cur), c.inlineStart, c.lex.curEndPos)
    c.inlineProps = defaultProperties
    if c.lex.lastScalarWasMultiline():
      raise c.generateError("Implicit mapping key may not be multiline")
  of MapValueInd:
    e = scalarEvent("", c.inlineProps, ssPlain, c.inlineStart, c.lex.curStartPos)
    c.inlineProps = defaultProperties
    c.transition(afterImplicitKey)
    return true
  else:
    raise c.generateError("Unexpected token (expected implicit mapping key): " & $c.lex.cur)
  c.lex.next()
  c.transition(afterImplicitKey)
  return true

proc afterImplicitKey(c: Context, e: var Event): bool =
  if c.lex.cur != Token.MapValueInd:
    raise c.generateError("Unexpected token (expected ':'): " & $c.lex.cur)
  c.lex.next()
  c.transition(beforeBlockMapKey)
  c.pushLevel(beforeBlockIndentation)
  c.pushLevel(afterBlockParent, max(0, c.levels[^2].indentation))
  return false

proc beforeBlockMapValue(c: Context, e: var Event): bool =
  if c.blockIndentation > c.levels[^1].indentation:
    raise c.generateError("Invalid indentation")
  case c.lex.cur
  of MapValueInd:
    c.transition(beforeBlockMapKey)
    c.pushLevel(beforeBlockIndentation)
    c.pushLevel(afterCompactParent, c.blockIndentation)
    c.lex.next()
  of MapKeyInd, Plain, SingleQuoted, DoubleQuoted, nodePropertyKind:
    # the value is allowed to be missing after an explicit key
    e = scalarEvent("", defaultProperties, ssPlain, c.lex.curStartPos, c.lex.curEndPos)
    c.transition(beforeBlockMapKey)
    return true
  else:
    raise c.generateError("Unexpected token (expected mapping value): " & $c.lex.cur)

proc beforeBlockIndentation(c: Context, e: var Event): bool =
  proc endBlockNode(e: var Event) =
    if c.levels[^1].state == beforeBlockMapKey:
      e = endMapEvent(c.lex.curStartPos, c.lex.curEndPos)
    elif c.levels[^1].state == beforeBlockMapValue:
      e = scalarEvent("", defaultProperties, ssPlain, c.lex.curStartPos, c.lex.curEndPos)
      c.transition(beforeBlockMapKey)
      c.pushLevel(beforeBlockIndentation)
      return
    elif c.levels[^1].state == inBlockSeq:
      e = endSeqEvent(c.lex.curStartPos, c.lex.curEndPos)
    elif c.levels[^1].state == atBlockIndentation:
      e = scalarEvent("", c.headerProps, ssPlain, c.headerStart, c.headerStart)
      c.headerProps = defaultProperties
    elif c.levels[^1].state == beforeBlockIndentation:
      raise c.generateError("Unexpected double beforeBlockIndentation")
    else:
      raise c.generateError("Internal error (please report this bug): unexpected state at endBlockNode")
    c.popLevel()
  c.popLevel()
  case c.lex.cur
  of Indentation:
    c.blockIndentation = c.lex.currentIndentation()
    if c.blockIndentation < c.levels[^1].indentation:
      endBlockNode(e)
      return true
    else:
      c.lex.next()
      return false
  of StreamEnd, DocumentEnd, DirectivesEnd:
    c.blockIndentation = 0
    if c.levels[^1].state != beforeDocEnd:
      endBlockNode(e)
      return true
    else:
      return false
  else:
    raise c.generateError("Unexpected content after node in block context (expected newline): " & $c.lex.cur)

proc beforeFlowItem(c: Context, e: var Event): bool =
  c.inlineStart = c.lex.curStartPos
  case c.lex.cur
  of nodePropertyKind:
    c.transition(beforeFlowItemProps)
    c.pushLevel(beforeNodeProperties)
  of Alias:
    e = aliasEvent(c.lex.shortLexeme().Anchor, c.inlineStart, c.lex.curEndPos)
    c.lex.next()
    c.popLevel()
    return true
  else:
    c.transition(beforeFlowItemProps)
  return false

proc beforeFlowItemProps(c: Context, e: var Event): bool =
  case c.lex.cur
  of nodePropertyKind:
    c.pushLevel(beforeNodeProperties)
  of Alias:
    e = aliasEvent(c.lex.shortLexeme().Anchor, c.inlineStart, c.lex.curEndPos)
    c.lex.next()
    c.popLevel()
  of scalarTokenKind:
    e = scalarEvent(c.lex.evaluated, autoScalarTag(c.inlineProps, c.lex.cur),
                    toStyle(c.lex.cur), c.inlineStart, c.lex.curEndPos)
    c.inlineProps = defaultProperties
    c.lex.next()
    c.popLevel()
  of MapStart:
    e = startMapEvent(csFlow, c.inlineProps, c.inlineStart, c.lex.curEndPos)
    c.transition(afterFlowMapSep)
    c.lex.next()
  of SeqStart:
    e = startSeqEvent(csFlow, c.inlineProps, c.inlineStart, c.lex.curEndPos)
    c.transition(afterFlowSeqSep)
    c.lex.next()
  of MapEnd, SeqEnd, SeqSep, MapValueInd:
    e = scalarEvent("", c.inlineProps, ssPlain, c.inlineStart, c.lex.curEndPos)
    c.popLevel()
  else:
    raise c.generateError("Unexpected token (expected flow node): " & $c.lex.cur)
  c.inlineProps = defaultProperties
  return true

proc afterFlowMapKey(c: Context, e: var Event): bool =
  case c.lex.cur
  of MapValueInd:
    c.transition(afterFlowMapValue)
    c.pushLevel(beforeFlowItem)
    c.lex.next()
    return false
  of SeqSep, MapEnd:
    e = scalarEvent("", defaultProperties, ssPlain, c.lex.curStartPos, c.lex.curEndPos)
    c.transition(afterFlowMapValue)
    return true
  else:
    raise c.generateError("Unexpected token (expected ':'): " & $c.lex.cur)

proc afterFlowMapValue(c: Context, e: var Event): bool =
  case c.lex.cur
  of SeqSep:
    c.transition(afterFlowMapSep)
    c.lex.next()
    return false
  of MapEnd:
    e = endMapEvent(c.lex.curStartPos, c.lex.curEndPos)
    c.lex.next()
    c.popLevel()
    return true
  of Plain, SingleQuoted, DoubleQuoted, MapKeyInd, Token.Anchor, Alias, MapStart, SeqStart:
    raise c.generateError("Missing ','")
  else:
    raise c.generateError("Unexpected token (expected ',' or '}'): " & $c.lex.cur)

proc afterFlowSeqItem(c: Context, e: var Event): bool =
  case c.lex.cur
  of SeqSep:
    c.transition(afterFlowSeqSep)
    c.lex.next()
    return false
  of SeqEnd:
    e = endSeqEvent(c.lex.curStartPos, c.lex.curEndPos)
    c.lex.next()
    c.popLevel()
    return true
  of Plain, SingleQuoted, DoubleQuoted, MapKeyInd, Token.Anchor, Alias, MapStart, SeqStart:
    raise c.generateError("Missing ','")
  else:
    raise c.generateError("Unexpected token (expected ',' or ']'): " & $c.lex.cur)

proc afterFlowMapSep(c: Context, e: var Event): bool =
  case c.lex.cur
  of MapKeyInd:
    c.lex.next()
  of MapEnd:
    e = endMapEvent(c.lex.curStartPos, c.lex.curEndPos)
    c.lex.next()
    c.popLevel()
    return true
  of SeqSep:
    raise c.generateError("Missing mapping entry between commas (use '?' for an empty mapping entry)")
  else: discard
  c.transition(afterFlowMapKey)
  c.pushLevel(beforeFlowItem)
  return false

proc afterFlowSeqSep(c: Context, e: var Event): bool =
  c.inlineStart = c.lex.curStartPos
  case c.lex.cur
  of SeqSep:
    e = scalarEvent("", defaultProperties, ssPlain, c.lex.curStartPos, c.lex.curStartPos)
    c.lex.next()
    return true
  of nodePropertyKind:
    c.transition(afterFlowSeqSepProps)
    c.pushLevel(beforeNodeProperties)
    return false
  of Plain, SingleQuoted, DoubleQuoted, MapStart, SeqStart:
    c.transition(afterFlowSeqSepProps)
    return false
  of MapKeyInd:
    c.transition(afterFlowSeqSepProps)
    e = startMapEvent(csFlow, defaultProperties, c.lex.curStartPos, c.lex.curEndPos)
    c.lex.next()
    c.transition(afterFlowSeqItem)
    c.pushLevel(beforePairValue)
    c.pushLevel(beforeFlowItem)
    return true
  of MapValueInd:
    c.transition(afterFlowSeqItem)
    e = startMapEvent(csFlow, defaultProperties, c.lex.curStartPos, c.lex.curEndPos)
    c.pushLevel(atEmptyPairKey)
    return true
  of SeqEnd:
    e = endSeqEvent(c.lex.curStartPos, c.lex.curEndPos)
    c.lex.next()
    c.popLevel()
    return true
  else:
    c.transition(afterFlowSeqItem)
    c.pushLevel(beforeFlowItem)
    return false

proc afterFlowSeqSepProps(c: Context, e: var Event): bool =
  # here we handle potential implicit single pairs within flow sequences.
  c.transition(afterFlowSeqItem)
  case c.lex.cur
  of Plain, SingleQuoted, DoubleQuoted:
    e = scalarEvent(c.lex.evaluated, autoScalarTag(c.inlineProps, c.lex.cur),
                    toStyle(c.lex.cur), c.inlineStart, c.lex.curEndPos)
    c.inlineProps = defaultProperties
    c.lex.next()
    if c.lex.cur == Token.MapValueInd:
      c.pushLevel(afterImplicitPairStart)
      if c.caching:
        c.keyCache.add(startMapEvent(csFlow, defaultProperties, c.lex.curStartPos, c.lex.curStartPos))
      else:
        c.keyCache.add(move(e))
        e = startMapEvent(csFlow, defaultProperties, c.lex.curStartPos, c.lex.curStartPos)
        c.pushLevel(emitCached)
    return true
  of MapStart, SeqStart:
    let
      startPos = c.lex.curStartPos
      indent = c.levels[^1].indentation
      cacheStart = c.keyCache.len
      levelDepth = c.levels.len
      alreadyCaching = c.caching
    c.pushLevel(beforeFlowItemProps)
    c.caching = true
    while c.levels.len > levelDepth:
      c.keyCache.add(c.next())
    c.caching = alreadyCaching
    if c.lex.cur == Token.MapValueInd:
      c.pushLevel(afterImplicitPairStart, indent)
      if c.lex.curStartPos.line != startPos.line:
        raise c.generateError("Implicit mapping key may not be multiline")
      if not alreadyCaching:
        c.pushLevel(emitCached)
        e = startMapEvent(csPair, defaultProperties, startPos, startPos)
        return true
      else:
        # we are already filling a cache.
        # so we just squeeze the map start in.
        c.keyCache.insert(startMapEvent(csPair, defaultProperties, startPos, startPos), cacheStart)
        return false
    else:
      if not alreadyCaching:
        c.pushLevel(emitCached)
      return false
  else:
    c.pushLevel(beforeFlowItem)
    return false

proc atEmptyPairKey(c: Context, e: var Event): bool =
  c.transition(beforePairValue)
  e = scalarEvent("", defaultProperties, ssPlain, c.lex.curStartPos, c.lex.curStartPos)
  return true

proc beforePairValue(c: Context, e: var Event): bool =
  if c.lex.cur == Token.MapValueInd:
    c.transition(afterPairValue)
    c.pushLevel(beforeFlowItem)
    c.lex.next()
    return false
  else:
    # pair ends here without value
    e = scalarEvent("", defaultProperties, ssPlain, c.lex.curStartPos, c.lex.curEndPos)
    c.popLevel()
    return true

proc afterImplicitPairStart(c: Context, e: var Event): bool =
  c.lex.next()
  c.transition(afterPairValue)
  c.pushLevel(beforeFlowItem)
  return false

proc afterPairValue(c: Context, e: var Event): bool =
  e = endMapEvent(c.lex.curStartPos, c.lex.curEndPos)
  c.popLevel()
  return true

proc emitCached(c: Context, e: var Event): bool =
  debug("emitCollection key: pos = " & $c.keyCachePos & ", len = " & $c.keyCache.len)
  yAssert(c.keyCachePos < c.keyCache.len)
  e = move(c.keyCache[c.keyCachePos])
  inc(c.keyCachePos)
  if c.keyCachePos == len(c.keyCache):
    c.keyCache.setLen(0)
    c.keyCachePos = 0
    c.popLevel()
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