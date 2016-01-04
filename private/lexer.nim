#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

type
    Encoding = enum
      Unsupported, ## Unsupported encoding
      UTF8,        ## UTF-8
      UTF16LE,     ## UTF-16 Little Endian
      UTF16BE,     ## UTF-16 Big Endian
      UTF32LE,     ## UTF-32 Little Endian
      UTF32BE      ## UTF-32 Big Endian
    
    YamlLexerToken = enum
        # separating tokens
        tDirectivesEnd, tDocumentEnd, tStreamEnd,
        # tokens only in directives
        tTagDirective, tYamlDirective, tUnknownDirective,
        tVersionPart, tTagURI,
        tUnknownDirectiveParam,
        # tokens in directives and content
        tTagHandle, tComment,
        # from here on tokens only in content
        tLineStart,
        # control characters
        tColon, tDash, tQuestionmark, tComma, tOpeningBrace,
        tOpeningBracket, tClosingBrace, tClosingBracket, tPipe, tGreater,
        # block scalar header
        tBlockIndentationIndicator, tPlus,
        # scalar content
        tScalar, tScalarPart,
        # tags
        tVerbatimTag, tTagSuffix,
        # anchoring
        tAnchor, tAlias,
        # error reporting
        tError
            
    YamlLexerState = enum
        # initial states (not started reading any token)
        ylInitial, ylInitialSpaces, ylInitialUnknown, ylInitialContent,
        ylDefineTagHandleInitial, ylDefineTagURIInitial, ylInitialInLine,
        ylLineEnd, ylDirectiveLineEnd,
        # directive reading states
        ylDirective, ylDefineTagHandle, ylDefineTagURI, ylMajorVersion,
        ylMinorVersion, ylUnknownDirectiveParam, ylDirectiveComment,
        # scalar reading states
        ylPlainScalar, ylPlainScalarNone, ylSingleQuotedScalar,
        ylDoublyQuotedScalar, ylEscape, ylBlockScalar, ylBlockScalarHeader,
        ylSpaceAfterPlainScalar, ylSpaceAfterQuotedScalar,
        # indentation
        ylIndentation,
        # comments
        ylComment,
        # tags
        ylTagHandle, ylTagSuffix, ylVerbatimTag,
        # document separation
        ylDashes, ylDots,
        # anchoring
        ylAnchor, ylAlias
    
    YamlTypeHintState = enum
        ythInitial,
        ythF, ythFA, ythFAL, ythFALS, ythFALSE,
        ythN, ythNU, ythNUL, ythNULL,
              ythNO,
        ythO, ythON,
              ythOF, ythOFF,
        ythT, ythTR, ythTRU, ythTRUE,
        ythY, ythYE, ythYES,
        
        ythPoint, ythPointI, ythPointIN, ythPointINF,
                  ythPointN, ythPointNA, ythPointNAN,
        
        ythLowerFA, ythLowerFAL, ythLowerFALS,
        ythLowerNU, ythLowerNUL,
        ythLowerOF,
        ythLowerTR, ythLowerTRU,
        ythLowerYE,
        
        ythPointLowerIN, ythPointLowerN, ythPointLowerNA,
        
        ythMinus, yth0, ythInt, ythDecimal, ythNumE, ythNumEPlusMinus,
        ythExponent, ythNone
    
    YamlLexer = object of BaseLexer
        indentations: seq[int]
        encoding: Encoding
        charlen: int
        charoffset: int
        content*: string # my.content of the last returned token.
        line*, column*: int
        typeHint*: YamlTypeHint

const
    UTF8NextLine           = toUTF8(Rune(0x85))
    UTF8NonBreakingSpace   = toUTF8(Rune(0xA0))
    UTF8LineSeparator      = toUTF8(Rune(0x2028))
    UTF8ParagraphSeparator = toUTF8(Rune(0x2029))

proc detect_encoding(my: var YamlLexer) =
    var numBomChars = 0
    my.encoding = Unsupported
    if my.bufpos == 3:
        # BaseLexer already skipped UTF-8 BOM
        my.encoding = UTF8
    else:
        case my.buf[0]
        of '\0':
            if my.buf[1] == '\0':
                if my.buf[2] == '\0':
                    my.encoding = UTF32LE
                elif my.buf[2] == '\xFE' and my.buf[3] == '\xFF':
                    my.encoding = UTF32BE
                    numBomChars = 4
                else:
                    # this is probably not a unicode character stream,
                    # but we just use the next match in the table
                    my.encoding = UTF16BE
            else:
                # this is how a BOM-less UTF16BE input should actually look like
                my.encoding = UTF16BE
        of '\xFF':
            case my.buf[1]
            of '\xFE':
                if my.buf[2] == '\0' and my.buf[3] == '\0':
                    my.encoding = UTF32LE
                    numBomChars = 4
                else:
                    my.encoding = UTF16LE
                    numBomChars = 2
            of '\0':
                my.encoding = UTF16LE
            else:
                my.encoding = UTF8
        of '\xFE':
            case my.buf[1]
            of '\xFF':
                my.encoding = UTF16BE
                numBomChars = 2
            of '\0':
                my.encoding = UTF16LE
            else:
                my.encoding = UTF8
        else:
            if my.buf[1] == '\0':
                my.encoding = UTF16LE
            else:
                my.encoding = UTF8
    inc(my.bufPos, numBomChars)
    my.charlen = case my.encoding
        of UTF8, Unsupported: 1
        of UTF16LE, UTF16BE:  2
        of UTF32LE, UTF32BE:  4
    my.charoffset = case my.encoding
        of UTF8, Unsupported, UTF16LE, UTF32LE: 0
        of UTF16BE: 1
        of UTF32BE: 3
        
proc open(my: var YamlLexer, input: Stream) =
    lexbase.open(my, input)
    my.indentations = newSeq[int]()
    my.detect_encoding()
    my.content = ""
    my.line = 1
    my.column = 1

template yieldToken(kind: YamlLexerToken) {.dirty.} =
    when defined(yamlDebug):
        if kind == tScalar:
            echo "Lexer token: tScalar(\"", my.content, "\")"
        else:
            echo "Lexer token: ", kind
    yield kind
    my.content = ""

template yieldScalarPart() {.dirty.} =
    case typeHintState
    of ythNULL:
        my.typeHint = yTypeNull
    of ythTRUE, ythON, ythYES, ythY:
        my.typeHint = yTypeBoolTrue
    of ythFALSE, ythOFF, ythNO, ythN:
        my.typeHint = yTypeBoolFalse
    of ythInt, yth0:
        my.typeHint = yTypeInteger
    of ythDecimal, ythExponent:
        my.typeHint = yTypeFloat
    of ythPointINF:
        my.typeHint = yTypeFloatInf
    of ythPointNAN:
        my.typeHint = yTypeFloatNaN
    else:
        my.typeHint = yTypeUnknown
    
    when defined(yamlDebug):
        echo "Lexer token: tScalarPart(\"", my.content, "\".", typeHintState,
             ")"
    yield tScalarPart
    my.content = ""

template yieldLexerError(message: string) {.dirty.} =
    when defined(yamlDebug):
        echo "Lexer error: " & message
    my.content = message
    my.column = curPos
    yield tError
    my.content = ""

template handleCR() {.dirty.} =
    my.bufpos = lexbase.handleCR(my, my.bufpos + my.charoffset) + my.charlen -
            my.charoffset - 1
    my.line.inc()
    curPos = 1

template handleLF() {.dirty.} =
    my.bufpos = lexbase.handleLF(my, my.bufpos + my.charoffset) +
            my.charlen - my.charoffset - 1
    my.line.inc()
    curPos = 1

template `or`(r: Rune, i: int): Rune =
    cast[Rune](cast[int](r) or i)

macro typeHintStateMachine(c: untyped, content: untyped): stmt =
    assert content.kind == nnkStmtList
    result = newNimNode(nnkCaseStmt, content).add(copyNimNode(c))
    for branch in content.children:
        assert branch.kind == nnkOfBranch
        var 
            charBranch = newNimNode(nnkOfBranch, branch)
            i = 0
            stateBranches = newNimNode(nnkCaseStmt, branch).add(
                    newIdentNode("typeHintState"))
        while branch[i].kind != nnkStmtList:
            charBranch.add(copyNimTree(branch[i]))
            inc(i)
        for rule in branch[i].children:
            assert rule.kind == nnkInfix
            assert ($rule[0].ident == "=>")
            var stateBranch = newNimNode(nnkOfBranch, rule)
            case rule[1].kind
            of nnkBracket:
                for item in rule[1].children:
                    stateBranch.add(item)
            of nnkIdent:
                stateBranch.add(rule[1])
            else:
                assert false
            if rule[2].kind == nnkNilLit:
                stateBranch.add(newStmtList(newNimNode(nnkDiscardStmt).add(
                        newEmptyNode())))
            else:
                stateBranch.add(newStmtList(newAssignment(
                        newIdentNode("typeHintState"), copyNimTree(rule[2]))))
            stateBranches.add(stateBranch)
        stateBranches.add(newNimNode(nnkElse).add(newStmtList(newAssignment(
                newIdentNode("typeHintState"), newIdentNode("ythNone")),
                newAssignment(newIdentNode("state"),
                newIdentNode("ylPlainScalarNone")))))
        charBranch.add(newStmtList(stateBranches))
        result.add(charBranch)
    result.add(newNimNode(nnkElse).add(newStmtList(newAssignment(
                newIdentNode("typeHintState"), newIdentNode("ythNone")),
                newAssignment(newIdentNode("state"),
                newIdentNode("ylPlainScalarNone")))))

template advanceTypeHint(ch: char) {.dirty.} =
    typeHintStateMachine ch:
    of '.':
        [yth0, ythInt]         => ythDecimal
        [ythInitial, ythMinus] => ythPoint
    of '+': ythNumE => ythNumEPlusMinus
    of '-':
        ythInitial => ythMinus
        ythNumE    => ythNumEPlusMinus
    of '0':
        [ythInitial, ythMinus]      => yth0
        [ythNumE, ythNumEPlusMinus] => ythExponent
    of '1'..'9':
        [ythInitial, ythMinus]            => ythInt
        [ythNumE, ythNumEPlusMinus]       => ythExponent
        [ythInt, ythDecimal, ythExponent] => nil
    of 'a':
        ythF           => ythLowerFA
        ythPointN      => ythPointNA
        ythPointLowerN => ythPointLowerNA
    of 'A':
        ythF      => ythFA
        ythPointN => ythPointNA
    of 'e':
        [yth0, ythInt, ythDecimal] => ythNumE
        ythLowerFALS => ythFALSE
        ythLowerTRU  => ythTRUE
        ythY         => ythLowerYE
    of 'E':
        [yth0, ythInt, ythDecimal] => ythNumE
        ythFALS => ythFALSE
        ythTRU  => ythTRUE
        ythY    => ythYE
    of 'f':
        ythInitial      => ythF
        ythO            => ythLowerOF
        ythLowerOF      => ythOFF
        ythPointLowerIN => ythPointINF
    of 'F':
        ythInitial => ythF
        ythO       => ythOF
        ythOF      => ythOFF
        ythPointIN => ythPointINF
    of 'i', 'I': ythPoint => ythPointI
    of 'l':
        ythLowerNU  => ythLowerNUL
        ythLowerNUL => ythNULL
        ythLowerFA  => ythLowerFAL
    of 'L':
        ythNU  => ythNUL
        ythNUL => ythNULL
        ythFA  => ythFAL
    of 'n':
        ythInitial      => ythN
        ythO            => ythON
        ythPoint        => ythPointLowerN
        ythPointI       => ythPointLowerIN
        ythPointLowerNA => ythPointNAN
    of 'N':
        ythInitial => ythN
        ythO       => ythON
        ythPoint   => ythPointN
        ythPointI  => ythPointIN
        ythPointNA => ythPointNAN
    of 'o', 'O':
        ythInitial => ythO
        ythN       => ythNO
    of 'r': ythT => ythLowerTR
    of 'R': ythT => ythTR
    of 's':
        ythLowerFAL => ythLowerFALS
        ythLowerYE  => ythYES
    of 'S':
        ythFAL => ythFALS
        ythYE  => ythYES
    of 't', 'T': ythInitial => ythT
    of 'u':
        ythN       => ythLowerNU
        ythLowerTR => ythLowerTRU
    of 'U':
        ythN  => ythNU
        ythTR => ythTRU
    of 'y', 'Y': ythInitial => ythY

iterator tokens(my: var YamlLexer): YamlLexerToken {.closure.} =
    var
        # the following three values are used for parsing escaped unicode chars
        
        unicodeChar: Rune = cast[Rune](0)
        escapeLength = 0
        expectedEscapeLength = 0
        
        trailingSpace = ""
            # used to temporarily store whitespace after a plain scalar
        lastSpecialChar: char = '\0'
            # stores chars that behave differently dependent on the following
            # char. handling will be deferred to next loop iteration.
        flowDepth = 0
            # Lexer must know whether it parses block or flow style. Therefore,
            # it counts the number of open flow arrays / maps here
        state: YamlLexerState = ylInitial # lexer state
        typeHintState: YamlTypeHintState = ythInitial
            # for giving type hints of plain scalars
        lastIndentationLength = 0
            # after parsing the indentation of the line, this will hold the
            # indentation length of the current line. Needed for checking where
            # a block scalar ends.
        blockScalarIndentation = -1
            # when parsing a block scalar, this will be set to the indentation
            # of the line that starts the flow scalar.
        curPos = 1
    
    while true:
        let c = my.buf[my.bufpos + my.charoffset]
        case state
        of ylInitial:
            case c
            of '%':
                state = ylDirective
                continue
            of ' ', '\t':
                state = ylInitialSpaces
                continue
            of '#':
                state = ylDirectiveComment
            else:
                state = ylInitialContent
                continue
        of ylInitialSpaces:
            case c
            of ' ', '\t':
                my.content.add(c)
            of '#':
                my.content = ""
                state = ylDirectiveComment
            of EndOfFile, '\r', '\x0A':
                state = ylDirectiveLineEnd
                continue
            else:
                state = ylIndentation
                continue
        of ylInitialContent:
            case c
            of '-':
                my.column = curPos
                state = ylDashes
                continue
            of '.':
                yieldToken(tLineStart)
                my.column = curPos
                state = ylDots
                continue
            else:
                state = ylIndentation
                continue
        of ylDashes:
            case c
            of '-':
                my.content.add(c)
            of ' ', '\t', '\r', '\x0A', EndOfFile:
                case my.content.len
                of 3:
                    yieldToken(tDirectivesEnd)
                    state = ylInitialInLine
                of 1:
                    my.content = ""
                    yieldToken(tLineStart)
                    lastSpecialChar = '-'
                    state = ylInitialInLine
                else:
                    let tmp = my.content
                    my.content = ""
                    yieldToken(tLineStart)
                    my.content = tmp
                    my.column = curPos
                    state = ylPlainScalarNone
                    typeHintState = ythNone
                continue
            else:
                let tmp = my.content
                my.content = ""
                yieldToken(tLineStart)
                my.content = tmp
                if my.content.len == 1:
                    typeHintState = ythMinus
                    state = ylPlainScalar
                else:
                    typeHintState = ythNone
                    state = ylPlainScalarNone
                continue
        of ylDots:
            case c
            of '.':
                my.content.add(c)
            of ' ', '\t', '\r', '\x0A', EndOfFile:
                case my.content.len
                of 3:
                    yieldToken(tDocumentEnd)
                    state = ylDirectiveLineEnd
                else:
                    state = ylPlainScalarNone
                    typeHintState = ythNone
                continue
            else:
                state = ylPlainScalarNone
                typeHintState = ythNone
                continue
        of ylDirectiveLineEnd:
            case c
            of '\r':
                handleCR()
                state = ylInitial
                continue
            of '\x0A':
                handleLF()
                state = ylInitial
                continue
            of EndOfFile:
                yieldToken(tStreamEnd)
                break
            of ' ', '\t':
                discard
            of '#':
                state = ylDirectiveComment
            else:
                yieldLexerError("Unexpected content at end of directive: " & c)
        of ylLineEnd:
            case c
            of '\r':
                handleCR()
            of '\x0A':
                handleLF()
            of EndOfFile:
                yieldToken(tStreamEnd)
                break
            else:
                yieldLexerError("Internal error: Unexpected char at line end: " & c)
            state = ylInitialContent
            continue
        of ylSingleQuotedScalar:
            if lastSpecialChar != '\0':
                # ' is the only special char
                case c
                of '\'':
                    my.content.add(c)
                    lastSpecialChar = '\0'
                of EndOfFile, '\r', '\x0A':
                    yieldToken(tScalar)
                    lastSpecialChar = '\0'
                    state = ylLineEnd
                    continue
                else:
                    yieldToken(tScalar)
                    lastSpecialChar = '\0'
                    state = ylSpaceAfterQuotedScalar
                    continue
            else:
                case c
                of '\'':
                    lastSpecialChar = c
                of EndOfFile:
                    yieldLexerError("Unterminated single quoted string")
                    yieldToken(tStreamEnd)
                    break
                else:
                    my.content.add(c)
        of ylDoublyQuotedScalar:
            case c
            of '"':
                yieldToken(tScalar)
                state = ylSpaceAfterQuotedScalar
            of EndOfFile:
                yieldLexerError("Unterminated doubly quoted string")
                yieldToken(tStreamEnd)
                break
            of '\\':
                state = ylEscape
                escapeLength = 0
            of '\r':
                my.content.add("\x0A")
                handleCR()
            of '\x0A':
                my.content.add(c)
                handleLF()
            else:
                my.content.add(c)
        of ylEscape:
            if escapeLength == 0:
                expectedEscapeLength = 0
                case c
                of EndOfFile:
                    yieldLexerError("Unterminated doubly quoted string")
                of '0':       my.content.add('\0')
                of 'a':       my.content.add('\x07')
                of 'b':       my.content.add('\x08')
                of '\t', 't': my.content.add('\t')
                of 'n':       my.content.add('\x0A')
                of 'v':       my.content.add('\v')
                of 'f':       my.content.add('\f')
                of 'r':       my.content.add('\r')
                of 'e':       my.content.add('\e')
                of ' ':       my.content.add(' ')
                of '"':       my.content.add('"')
                of '/':       my.content.add('/')
                of '\\':      my.content.add('\\')
                of 'N':       my.content.add(UTF8NextLine)
                of '_':       my.content.add(UTF8NonBreakingSpace)
                of 'L':       my.content.add(UTF8LineSeparator)
                of 'P':       my.content.add(UTF8ParagraphSeparator)
                of 'x': unicodeChar = cast[Rune](0); expectedEscapeLength = 3
                of 'u': unicodeChar = cast[Rune](0); expectedEscapeLength = 5
                of 'U': unicodeChar = cast[Rune](0); expectedEscapeLength = 9
                else:
                    yieldLexerError("Unsupported escape sequence: \\" & c)
                if expectedEscapeLength == 0: state = ylDoublyQuotedScalar
            else:
                let digitPosition = expectedEscapeLength - escapeLength - 1
                case c
                of EndOFFile:
                    yieldLexerError("Unterminated escape sequence")
                    state = ylLineEnd
                    continue
                of '0' .. '9':
                    unicodeChar = unicodechar or
                            (cast[int](c) - 0x30) shl (digitPosition * 4)
                of 'A' .. 'F':
                    unicodeChar = unicodechar or
                            (cast[int](c) - 0x37) shl (digitPosition * 4)
                of 'a' .. 'f':
                    unicodeChar = unicodechar or
                            (cast[int](c) - 0x57) shl (digitPosition * 4)
                else:
                    yieldLexerError("unsupported char in unicode escape sequence: " &
                               c)
                    escapeLength = 0
                    state = ylDoublyQuotedScalar
                    continue
            inc(escapeLength)
            if escapeLength == expectedEscapeLength and escapeLength > 0:
                my.content.add(toUTF8(unicodeChar))
                state = ylDoublyQuotedScalar
        
        of ylSpaceAfterQuotedScalar:
            case c
            of ' ', '\t':
                trailingSpace.add(c)
            of '#':
                if trailingSpace.len > 0:
                    yieldLexerError("Missing space before comment start")
                state = ylComment
                trailingSpace = ""
            else:
                trailingSpace = ""
                state = ylInitialInLine
                continue
        
        of ylPlainScalar:
            case c
            of EndOfFile, '\r', '\x0A':
                yieldScalarPart()
                state = ylLineEnd
                continue
            of ':':
                lastSpecialChar = c
                state = ylSpaceAfterPlainScalar
            of ' ':
                state = ylSpaceAfterPlainScalar
                continue
            of ',':
                if flowDepth > 0:
                    lastSpecialChar = c
                    state = ylSpaceAfterPlainScalar
                else:
                    my.content.add(c)
                    state = ylPlainScalarNone
                    typeHintState = ythNone
            of '[', ']', '{', '}':
                yieldScalarPart()
                state = ylInitialInLine
                continue
            else:
                advanceTypeHint(c)
                my.content.add(c)
        
        of ylPlainScalarNone:
            case c
            of EndOfFile, '\r', '\x0A':
                yieldScalarPart()
                state = ylLineEnd
                continue
            of ':':
                lastSpecialChar = c
                state = ylSpaceAfterPlainScalar
            of ' ':
                state = ylSpaceAfterPlainScalar
                continue
            of ',':
                if flowDepth > 0:
                    lastSpecialChar = c
                    state = ylSpaceAfterPlainScalar
                else:
                    my.content.add(c)
            of '[', ']', '{', '}':
                yieldScalarPart()
                state = ylInitialInLine
                continue
            else:
                my.content.add(c)
        
        of ylSpaceAfterPlainScalar:
            if lastSpecialChar != '\0':
                case c
                of ' ', '\t', EndOfFile, '\r', '\x0A':
                    yieldScalarPart()
                    state = ylInitialInLine
                else:
                    my.content.add(trailingSpace)
                    my.content.add(lastSpecialChar)
                    lastSpecialChar = '\0'
                    trailingSpace = ""
                    state = ylPlainScalarNone
                    typeHintState = ythNone
                continue
            
            case c
            of EndOfFile, '\r', '\x0A':
                trailingSpace = ""
                yieldScalarPart()
                state = ylLineEnd
                continue
            of ' ', '\t':
                trailingSpace.add(c)
            of ',':
                if flowDepth > 0:
                    lastSpecialChar = c
                else:
                    my.content.add(trailingSpace)
                    my.content.add(c)
                    trailingSpace = ""
                    state = ylPlainScalarNone
                    typeHintState = ythNone
            of ':', '#':
                lastSpecialChar = c
            of '[', ']', '{', '}':
                yieldScalarPart()
                trailingSpace = ""
                state = ylInitialInLine
                continue
            else:
                my.content.add(trailingSpace)
                my.content.add(c)
                trailingSpace = ""
                state = ylPlainScalarNone
                typeHintState = ythNone
                
        of ylInitialInLine:
            if lastSpecialChar != '\0':
                my.column = curPos - 1
                case c
                of ' ', '\t', '\r', '\x0A', EndOfFile:
                    case lastSpecialChar
                    of '#':
                        my.content = "#"
                        state = ylComment
                    of ':':
                        yieldToken(tColon)
                    of '?':
                        yieldToken(tQuestionmark)
                    of '-':
                        yieldToken(tDash)
                    of ',':
                        yieldToken(tComma)
                    of '!':
                        my.content = "!"
                        yieldToken(tTagHandle)
                        my.content = ""
                        yieldToken(tTagSuffix)
                    else:
                        yieldLexerError("Unexpected special char: \"" &
                                   lastSpecialChar & "\"")
                    lastSpecialChar = '\0'
                elif lastSpecialChar == '!':
                    case c
                    of '<':
                        state = ylVerbatimTag
                        lastSpecialChar = '\0'
                        my.bufpos += my.charlen
                    else:
                        state = ylTagHandle
                        my.content = "!"
                        lastSpecialChar = '\0'
                    my.column = curPos - 1
                else:
                    my.content.add(lastSpecialChar)
                    advanceTypeHint(lastSpecialChar)
                    lastSpecialChar = '\0'
                    my.column = curPos - 1
                    state = ylPlainScalar
                    typeHintState = ythInitial
                continue
            case c
            of '\r', '\x0A', EndOfFile:
                state = ylLineEnd
                continue
            of ',':
                if flowDepth > 0:
                    yieldToken(tComma)
                else:
                    my.content = "" & c
                    my.column = curPos
                    state = ylPlainScalar
                    typeHintState = ythInitial
                    advanceTypeHint(c)
            of '[':
                inc(flowDepth)
                yieldToken(tOpeningBracket)
            of '{':
                inc(flowDepth)
                yieldToken(tOpeningBrace)
            of ']':
                yieldToken(tClosingBracket)
                if flowDepth > 0:
                    inc(flowDepth, -1)
            of '}':
                yieldToken(tClosingBrace)
                if flowDepth > 0:
                    inc(flowDepth, -1)
            of '#':
                lastSpecialChar = '#'
            of '"':
                my.column = curPos
                state = ylDoublyQuotedScalar
            of '\'':
                my.column = curPos
                state = ylSingleQuotedScalar
            of '!':
                my.column = curPos
                lastSpecialChar = '!'
            of '&':
                my.column = curPos
                state = ylAnchor
            of '*':
                my.column = curPos
                state = ylAlias
            of ' ':
                discard
            of '-':
                if flowDepth == 0:
                    lastSpecialChar = '-'
                else:
                    my.content = "" & c
                    my.column = curPos
                    state = ylPlainScalar
                    typeHintState = ythInitial
                    advanceTypeHint(c)
            of '?', ':':
                my.column = curPos
                lastSpecialChar = c
            of '|':
                yieldToken(tPipe)
                state = ylBlockScalarHeader
            of '>':
                yieldToken(tGreater)
                state = ylBlockScalarHeader
            of '\t':
                discard
            else:
                my.content = "" & c
                my.column = curPos
                state = ylPlainScalar
                typeHintState = ythInitial
                advanceTypeHint(c)
        of ylComment, ylDirectiveComment:
            case c
            of EndOfFile, '\r', '\x0A':
                yieldToken(tComment)
                case state
                of ylComment:
                    state = ylLineEnd
                of ylDirectiveComment:
                    state = ylDirectiveLineEnd
                else:
                    yieldLexerError("Should never happen")
                continue
            else:
                my.content.add(c)
        of ylIndentation:
            case c
            of EndOfFile, '\r', '\x0A':
                lastIndentationLength = my.content.len
                yieldToken(tLineStart)
                state = ylLineEnd
                continue
            of ' ':
                my.content.add(' ')
            else:
                lastIndentationLength =  my.content.len
                yieldToken(tLineStart)
                if blockScalarIndentation != -1:
                    if lastIndentationLength <= blockScalarIndentation:
                        blockScalarIndentation = -1
                    else:
                        state = ylBlockScalar
                        continue
                state = ylInitialInLine
                continue
        of ylTagHandle:
            case c
            of '!':
                my.content.add(c)
                yieldToken(tTagHandle)
                state = ylTagSuffix
            of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-':
                my.content.add(c)
            of '#', ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '_', '.',
               '~', '*', '\'', '(', ')':
               let suffix = my.content[1..^1]
               my.content = "!"
               yield(tTagHandle)
               my.content = suffix
               state = ylTagSuffix
            of ' ', '\t', EndOfFile, '\r', '\x0A':
                let suffix = my.content[1..^1]
                my.content = "!"
                yieldToken(tTagHandle)
                my.content = suffix
                yieldToken(tTagSuffix)
                state = ylInitialInLine
                continue
            else:
                yieldLexerError("Invalid character in tag handle: " & c)
                my.content = ""
                state = ylInitialInLine
        of ylTagSuffix:
            case c
            of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@',
               '&', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')':
                my.content.add(c)
            of ' ', '\t', EndOfFile, '\r', '\x0A':
                yieldToken(tTagSuffix)
                state = ylInitialInLine
                continue
            else:
                yieldLexerError("Invalid character in tag suffix: " & c)
                state = ylInitialInLine
        of ylVerbatimTag:
            case c
            of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@',
               '&', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')':
                my.content.add(c)
            of '>':
                yieldToken(tVerbatimTag)
                state = ylInitialInLine
            of EndOfFile, '\r', '\x0A':
                yieldLexerError("Unfinished verbatim tag")
                state = ylLineEnd
                continue
            else:
                yieldLexerError("Invalid character in tag URI: " & c)
                my.content = ""
                state = ylInitialInLine
        of ylDirective:
            case c
            of ' ', '\t', '\r', '\x0A', EndOfFile:
                if my.content == "%YAML":
                    yieldToken(tYamlDirective)
                    state = ylMajorVersion
                elif my.content == "%TAG":
                    yieldToken(tTagDirective)
                    state = ylDefineTagHandleInitial
                else:
                    yieldToken(tUnknownDirective)
                    state = ylInitialUnknown
                if c == EndOfFile:
                    continue
            else:
                my.content.add(c)
        of ylInitialUnknown:
            case c
            of ' ', '\t':
                discard
            of '\r', '\x0A', EndOfFile:
                state = ylDirectiveLineEnd
                continue
            of '#':
                state = ylDirectiveComment
                continue
            else:
                state = ylUnknownDirectiveParam
                continue
        of ylUnknownDirectiveParam:
            case c
            of '\r', '\x0A', EndOfFile, ' ', '\t':
                yieldToken(tUnknownDirectiveParam)
                state = ylInitialUnknown
                continue
            else:
                my.content.add(c)
        of ylMajorVersion:
            case c
            of '0' .. '9':
                my.content.add(c)
            of '.':
                yieldToken(tVersionPart)
                state = ylMinorVersion
            of EndOfFile, '\r', '\x0A', ' ', '\t':
                yieldLexerError("Missing YAML minor version.")
                state = ylDirectiveLineEnd
                continue
            else:
                yieldLexerError("Invalid character in YAML version: " & c)
                state = ylInitialUnknown
        of ylMinorVersion:
            case c
            of '0' .. '9':
                my.content.add(c)
            of EndOfFile, '\r', '\x0A', ' ', '\t':
                yieldToken(tVersionPart)
                state = ylDirectiveLineEnd
                continue
            else:
                yieldLexerError("Invalid character in YAML version: " & c)
                state = ylInitialUnknown
        of ylDefineTagHandleInitial:
            case c
            of ' ', '\t':
                discard
            of EndOfFile, '\r', '\x0A':
                yieldLexerError("Unfinished %TAG directive")
                state = ylDirectiveLineEnd
                continue
            of '!':
                my.content.add(c)
                state = ylDefineTagHandle
            else:
                yieldLexerError("Unexpected character in %TAG directive: " & c)
                state = ylInitialInLine
        of ylDefineTagHandle:
            case c
            of '!':
                my.content.add(c)
                yieldToken(tTagHandle)
                state = ylDefineTagURIInitial
            of 'a' .. 'z', 'A' .. 'Z', '-':
                my.content.add(c)
            of EndOfFile, '\r', '\x0A':
                yieldLexerError("Unfinished %TAG directive")
                state = ylDirectiveLineEnd
                continue
            else:
                yieldLexerError("Unexpected char in %TAG directive: " & c)
                state = ylInitialInLine
        of ylDefineTagURIInitial:
            case c
            of '\t', ' ':
                my.content.add(c)
            of '\x0A', '\r', EndOfFile:
                yieldLexerError("Unfinished %TAG directive")
                state = ylDirectiveLineEnd
                continue
            else:
                if my.content.len == 0:
                    yieldLexerError("Missing whitespace in %TAG directive")
                my.content = ""
                state = ylDefineTagURI
                continue
        of ylDefineTagURI:
            case c
            of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@',
               '&', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')':
                my.content.add(c)
            of '\x0A', '\r', EndOfFile, ' ', '\t':
                yieldToken(tTagURI)
                state = ylDirectiveLineEnd
                continue
            else:
                yieldLexerError("Invalid URI character: " & c)
                state = ylInitialInLine
                continue
        of ylBlockScalarHeader:
            case c
            of '0' .. '9':
                my.content = "" & c
                yieldToken(tBlockIndentationIndicator)
            of '+':
                yieldToken(tPlus)
            of '-':
                yieldToken(tDash)
            of '\r', '\x0A', EndOfFile:
                blockScalarIndentation = lastIndentationLength
                state = ylLineEnd
                continue
            else:
                yieldLexerError("Unexpected character in block scalar header: " & c)
        of ylBlockScalar:
            case c
            of EndOfFile, '\r', '\x0A':
                yieldScalarPart()
                state = ylLineEnd
                continue
            else:
                my.content.add(c)
        of ylAnchor:
            case c
            of EndOfFile, '\r', '\x0A', ' ', '\t', '{', '}', '[', ']':
                yieldToken(tAnchor)
                state = ylInitialInLine
                continue
            else:
                my.content.add(c)
        of ylAlias:
            if lastSpecialChar != '\0':
                case c
                of EndOfFile, '\r', '\x0A', ' ', '\t', '{', '}', '[', ']':
                    yieldToken(tAlias)
                    state = ylInitialInLine
                    continue
                else:
                    my.content.add(lastSpecialChar)
                    lastSpecialChar = '\0'
            case c
            of EndOfFile, '\r', '\x0A', ' ', '\t', '{', '}', '[', ']':
                yieldToken(tAlias)
                state = ylInitialInLine
                continue
            of ':':
                lastSpecialChar = ':'
            of ',':
                if flowDepth > 0:
                    yieldToken(tAlias)
                    state = ylInitialInLine
                    continue
                my.content.add(c)
            else:
                my.content.add(c)
        
        my.bufpos += my.charlen
        curPos.inc