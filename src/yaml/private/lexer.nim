import lexbase, unicode, streams

type
    Encoding* = enum
      Unsupported, ## Unsupported encoding
      UTF8,        ## UTF-8
      UTF16LE,     ## UTF-16 Little Endian
      UTF16BE,     ## UTF-16 Big Endian
      UTF32LE,     ## UTF-32 Little Endian
      UTF32BE      ## UTF-32 Big Endian
    
    YamlLexerToken* = enum
        # separating tokens
        yamlDirectivesEnd, yamlDocumentEnd, yamlStreamEnd,
        # tokens only in directives
        yamlTagDirective, yamlYamlDirective, yamlUnknownDirective,
        yamlVersionPart, yamlTagURI,
        yamlUnknownDirectiveParam,
        # tokens in directives and content
        yamlTagHandle, yamlComment,
        # from here on tokens only in content
        yamlLineStart,
        # control characters
        yamlColon, yamlDash, yamlQuestionmark, yamlComma, yamlOpeningBrace,
        yamlOpeningBracket, yamlClosingBrace, yamlClosingBracket, yamlPipe,
        yamlGreater,
        # block scalar header
        yamlLiteralScalar, yamlFoldedScalar,
        yamlBlockIndentationIndicator, yamlBlockChompingIndicator,
        # scalar content
        yamlScalar, yamlBlockScalarLine,
        # tags
        yamlVerbatimTag, yamlTagSuffix,
        # anchoring
        yamlAnchor, yamlAlias,
        # error reporting
        yamlError
            
    YamlLexerState = enum
        # initial states (not started reading any token)
        ylInitial, ylInitialSpaces, ylInitialUnknown, ylInitialContent,
        ylDefineTagHandleInitial, ylDefineTagURIInitial, ylInitialInLine,
        ylLineEnd, ylDirectiveLineEnd,
        # directive reading states
        ylDirective, ylDefineTagHandle, ylDefineTagURI, ylMajorVersion,
        ylMinorVersion, ylUnknownDirectiveParam, ylDirectiveComment,
        # scalar reading states
        ylPlainScalar, ylSingleQuotedScalar, ylDoublyQuotedScalar,
        ylEscape, ylBlockScalar, ylBlockScalarHeader,
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
    
    YamlLexer* = object of BaseLexer
        indentations: seq[int]
        encoding: Encoding
        charlen: int
        charoffset: int
        content*: string # my.content of the last returned token.
        line*, column*: int

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
        
proc open*(my: var YamlLexer, input: Stream) =
    lexbase.open(my, input)
    my.indentations = newSeq[int]()
    my.detect_encoding()
    my.content = ""
    my.line = 0
    my.column = 0

template yieldToken(kind: YamlLexerToken) {.dirty.} =
    when defined(yamlDebug):
        if kind == yamlScalar:
            echo "Lexer token: yamlScalar(\"", my.content, "\")"
        else:
            echo "Lexer token: ", kind
    
    yield kind
    my.content = ""

template yieldError(message: string) {.dirty.} =
    when defined(yamlDebug):
        echo "Lexer error: " & message
    my.content = message
    yield yamlError
    my.content = ""

template handleCR() {.dirty.} =
    my.bufpos = lexbase.handleLF(my, my.bufpos + my.charoffset) + my.charlen -
            my.charoffset - 1
    my.line.inc()
    curPos = 0

template handleLF() {.dirty.} =
    my.bufpos = lexbase.handleLF(my, my.bufpos + my.charoffset) +
            my.charlen - my.charoffset - 1
    my.line.inc()
    curPos = 0

template `or`(r: Rune, i: int): Rune =
    cast[Rune](cast[int](r) or i)

iterator tokens*(my: var YamlLexer): YamlLexerToken {.closure.} =
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
        state = ylInitial # lexer state
        lastIndentationLength = 0
            # after parsing the indentation of the line, this will hold the
            # indentation length of the current line. Needed for checking where
            # a block scalar ends.
        blockScalarIndentation = -1
            # when parsing a block scalar, this will be set to the indentation
            # of the line that starts the flow scalar.
        curPos = 0
    
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
                my.column = 0
                state = ylDashes
                continue
            of '.':
                yieldToken(yamlLineStart)
                my.column = 0
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
                    yieldToken(yamlDirectivesEnd)
                    state = ylInitialInLine
                of 1:
                    my.content = ""
                    yieldToken(yamlLineStart)
                    lastSpecialChar = '-'
                    state = ylInitialInLine
                else:
                    let tmp = my.content
                    my.content = ""
                    yieldToken(yamlLineStart)
                    my.content = tmp
                    my.column = curPos
                    state = ylPlainScalar
                continue
            else:
                state = ylPlainScalar
                continue
        of ylDots:
            case c
            of '.':
                my.content.add(c)
            of ' ', '\t', '\r', '\x0A', EndOfFile:
                case my.content.len
                of 3:
                    yieldToken(yamlDocumentEnd)
                    state = ylDirectiveLineEnd
                else:
                    state = ylPlainScalar
                continue
            else:
                state = ylPlainScalar
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
                yieldToken(yamlStreamEnd)
                break
            of ' ', '\t':
                discard
            of '#':
                state = ylDirectiveComment
            else:
                yieldError("Unexpected content at end of directive: " & c)
        of ylLineEnd:
            case c
            of '\r':
                handleCR()
            of '\x0A':
                handleLF()
            of EndOfFile:
                yieldToken(yamlStreamEnd)
                break
            else:
                yieldError("Internal error: Unexpected char at line end: " & c)
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
                    yieldToken(yamlScalar)
                    lastSpecialChar = '\0'
                    state = ylLineEnd
                    continue
                else:
                    yieldToken(yamlScalar)
                    lastSpecialChar = '\0'
                    state = ylSpaceAfterQuotedScalar
                    continue
            else:
                case c
                of '\'':
                    lastSpecialChar = c
                of EndOfFile:
                    yieldError("Unterminated single quoted string")
                    yieldToken(yamlStreamEnd)
                    break
                else:
                    my.content.add(c)
        of ylDoublyQuotedScalar:
            case c
            of '"':
                yieldToken(yamlScalar)
                state = ylSpaceAfterQuotedScalar
            of EndOfFile:
                yieldError("Unterminated doubly quoted string")
                yieldToken(yamlStreamEnd)
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
                    yieldError("Unterminated doubly quoted string")
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
                    yieldError("Unsupported escape sequence: \\" & c)
                if expectedEscapeLength == 0: state = ylDoublyQuotedScalar
            else:
                let digitPosition = expectedEscapeLength - escapeLength - 1
                case c
                of EndOFFile:
                    yieldError("Unterminated escape sequence")
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
                    yieldError("unsupported char in unicode escape sequence: " &
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
                    yieldError("Missing space before comment start")
                state = ylComment
                trailingSpace = ""
            else:
                trailingSpace = ""
                state = ylInitialInLine
                continue
        
        of ylPlainScalar:
            case c
            of EndOfFile, '\r', '\x0A':
                yieldToken(yamlScalar)
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
                yieldToken(yamlScalar)
                state = ylInitialInLine
                continue
            else:
                my.content.add(c)
        
        of ylSpaceAfterPlainScalar:
            if lastSpecialChar != '\0':
                case c
                of ' ', '\t', EndOfFile, '\r', '\x0A':
                    yieldToken(yamlScalar)
                    state = ylInitialInLine
                else:
                    my.content.add(trailingSpace)
                    my.content.add(lastSpecialChar)
                    lastSpecialChar = '\0'
                    trailingSpace = ""
                    state = ylPlainScalar
                continue
            
            case c
            of EndOfFile, '\r', '\x0A':
                trailingSpace = ""
                yieldToken(yamlScalar)
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
                    state = ylPlainScalar
            of ':', '#':
                lastSpecialChar = c
            of '[', ']', '{', '}':
                yieldToken(yamlScalar)
                trailingSpace = ""
                state = ylInitialInLine
                continue
            else:
                my.content.add(trailingSpace)
                my.content.add(c)
                trailingSpace = ""
                state = ylPlainScalar
                
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
                        yieldToken(yamlColon)
                    of '?':
                        yieldToken(yamlQuestionmark)
                    of '-':
                        yieldToken(yamlDash)
                    of ',':
                        yieldToken(yamlComma)
                    else:
                        yieldError("Unexpected special char: \"" &
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
                else:
                    my.content.add(lastSpecialChar)
                    lastSpecialChar = '\0'
                    my.column = curPos - 1
                    state = ylPlainScalar
                continue
            case c
            of '\r', '\x0A', EndOfFile:
                state = ylLineEnd
                continue
            of ',':
                if flowDepth > 0:
                    yieldToken(yamlComma)
                else:
                    my.content = "" & c
                    my.column = curPos
                    state = ylPlainScalar
            of '[':
                inc(flowDepth)
                yieldToken(yamlOpeningBracket)
            of '{':
                inc(flowDepth)
                yieldToken(yamlOpeningBrace)
            of ']':
                yieldToken(yamlClosingBracket)
                if flowDepth > 0:
                    inc(flowDepth, -1)
            of '}':
                yieldToken(yamlClosingBrace)
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
                lastSpecialChar = '!'
            of '&':
                state = ylAnchor
            of '*':
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
            of '?', ':':
                lastSpecialChar = c
            of '|':
                yieldToken(yamlPipe)
                state = ylBlockScalarHeader
            of '>':
                yieldToken(yamlGreater)
                state = ylBlockScalarHeader
            of '\t':
                discard
            else:
                my.content = "" & c
                my.column = curPos
                state = ylPlainScalar
        of ylComment, ylDirectiveComment:
            case c
            of EndOfFile, '\r', '\x0A':
                yieldToken(yamlComment)
                case state
                of ylComment:
                    state = ylLineEnd
                of ylDirectiveComment:
                    state = ylDirectiveLineEnd
                else:
                    yieldError("Should never happen")
                continue
            else:
                my.content.add(c)
        of ylIndentation:
            case c
            of EndOfFile, '\r', '\x0A':
                lastIndentationLength = my.content.len
                yieldToken(yamlLineStart)
                state = ylLineEnd
                continue
            of ' ':
                my.content.add(' ')
            else:
                lastIndentationLength =  my.content.len
                yieldToken(yamlLineStart)
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
                yieldToken(yamlTagHandle)
                state = ylTagSuffix
            of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-':
                my.content.add(c)
            of ' ', '\t', EndOfFile, '\r', '\x0A':
                var suffix = my.content[1..^1]
                my.content = "!"
                yieldToken(yamlTagHandle)
                my.content = suffix
                yieldToken(yamlTagSuffix)
                state = ylInitialInLine
                continue
            else:
                yieldError("Invalid character in tag handle: " & c)
                my.content = ""
                state = ylInitialInLine
        of ylTagSuffix:
            case c
            of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@',
               '&', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')':
                my.content.add(c)
            of ' ', '\t', EndOfFile, '\r', '\x0A':
                yieldToken(yamlTagSuffix)
                state = ylInitialInLine
                continue
            else:
                yieldError("Invalid character in tag suffix: " & c)
                state = ylInitialInLine
        of ylVerbatimTag:
            case c
            of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@',
               '&', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')':
                my.content.add(c)
            of '>':
                yieldToken(yamlVerbatimTag)
                state = ylInitialInLine
            of EndOfFile, '\r', '\x0A':
                yieldError("Unfinished verbatim tag")
                state = ylLineEnd
                continue
            else:
                yieldError("Invalid character in tag URI: " & c)
                my.content = ""
                state = ylInitialInLine
        of ylDirective:
            case c
            of ' ', '\t', '\r', '\x0A', EndOfFile:
                if my.content == "%YAML":
                    yieldToken(yamlYamlDirective)
                    state = ylMajorVersion
                elif my.content == "%TAG":
                    yieldToken(yamlTagDirective)
                    state = ylDefineTagHandleInitial
                else:
                    yieldToken(yamlUnknownDirective)
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
                yieldToken(yamlUnknownDirectiveParam)
                state = ylInitialUnknown
                continue
            else:
                my.content.add(c)
        of ylMajorVersion:
            case c
            of '0' .. '9':
                my.content.add(c)
            of '.':
                yieldToken(yamlVersionPart)
                state = ylMinorVersion
            of EndOfFile, '\r', '\x0A', ' ', '\t':
                yieldError("Missing YAML minor version.")
                state = ylDirectiveLineEnd
                continue
            else:
                yieldError("Invalid character in YAML version: " & c)
                state = ylInitialUnknown
        of ylMinorVersion:
            case c
            of '0' .. '9':
                my.content.add(c)
            of EndOfFile, '\r', '\x0A', ' ', '\t':
                yieldToken(yamlVersionPart)
                state = ylDirectiveLineEnd
                continue
            else:
                yieldError("Invalid character in YAML version: " & c)
                state = ylInitialUnknown
        of ylDefineTagHandleInitial:
            case c
            of ' ', '\t':
                discard
            of EndOfFile, '\r', '\x0A':
                yieldError("Unfinished %TAG directive")
                state = ylDirectiveLineEnd
                continue
            of '!':
                my.content.add(c)
                state = ylDefineTagHandle
            else:
                yieldError("Unexpected character in %TAG directive: " & c)
                state = ylInitialInLine
        of ylDefineTagHandle:
            case c
            of '!':
                my.content.add(c)
                yieldToken(yamlTagHandle)
                state = ylDefineTagURIInitial
            of 'a' .. 'z', 'A' .. 'Z', '-':
                my.content.add(c)
            of EndOfFile, '\r', '\x0A':
                yieldError("Unfinished %TAG directive")
                state = ylDirectiveLineEnd
                continue
            else:
                yieldError("Unexpected char in %TAG directive: " & c)
                state = ylInitialInLine
        of ylDefineTagURIInitial:
            case c
            of '\t', ' ':
                my.content.add(c)
            of '\x0A', '\r', EndOfFile:
                yieldError("Unfinished %TAG directive")
                state = ylDirectiveLineEnd
                continue
            else:
                if my.content.len == 0:
                    yieldError("Missing whitespace in %TAG directive")
                my.content = ""
                state = ylDefineTagURI
                continue
        of ylDefineTagURI:
            case c
            of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@',
               '&', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')':
                my.content.add(c)
            of '\x0A', '\r', EndOfFile, ' ', '\t':
                yieldToken(yamlTagURI)
                state = ylDirectiveLineEnd
                continue
            else:
                yieldError("Invalid URI character: " & c)
                state = ylInitialInLine
                continue
        of ylBlockScalarHeader:
            case c
            of '0' .. '9':
                my.content = "" & c
                yieldToken(yamlBlockIndentationIndicator)
            of '+', '-':
                my.content = "" & c
                yieldToken(yamlBlockChompingIndicator)
            of '\r', '\x0A', EndOfFile:
                blockScalarIndentation = lastIndentationLength
                state = ylLineEnd
                continue
            else:
                yieldError("Unexpected character in block scalar header: " & c)
        of ylBlockScalar:
            case c
            of EndOfFile, '\r', '\x0A':
                yieldToken(yamlBlockScalarLine)
                state = ylLineEnd
                continue
            else:
                my.content.add(c)
        of ylAnchor:
            case c
            of EndOfFile, '\r', '\x0A', ' ', '\t', '{', '}', '[', ']':
                yieldToken(yamlAnchor)
                state = ylInitialInLine
                continue
            else:
                my.content.add(c)
        of ylAlias:
            case c
            of EndOfFile, '\r', '\x0A', ' ', '\t', '{', '}', '[', ']':
                yieldToken(yamlAlias)
                state = ylInitialInLine
                continue
            else:
                my.content.add(c)
        
        my.bufpos += my.charlen
        curPos.inc