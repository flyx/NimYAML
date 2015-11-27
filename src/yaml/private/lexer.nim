import lexbase, unicode, streams

type
    Encoding* = enum
      Unsupported, ## Unsupported encoding
      UTF8,        ## UTF-8
      UTF16LE,     ## UTF-16 Little Endian
      UTF16BE,     ## UTF-16 Big Endian
      UTF32LE,     ## UTF-32 Little Endian
      UTF32BE      ## UTF-32 Big Endian
    
    YamlLexerEventKind* = enum
        yamlTagDirective, yamlYamlDirective,
        yamlEnterDoc, yamlExitDoc, yamlLineStart,
        yamlControlChar, yamlScalar,
        yamlLiteralScalar, yamlFoldedScalar,
        yamlVerbatimTag, yamlTagHandle, yamlTagURI, yamlTagSuffix,
        yamlAnchor, yamlAlias, yamlComment, yamlMajorVersion, yamlMinorVersion,
        yamlStreamEnd, yamlError
    
    YamlLexerEvent* = tuple
        kind: YamlLexerEventKind
        content: string
    
    YamlLexerState = enum
        ylBlock, ylPlainScalar, ylSingleQuotedScalar, ylDoublyQuotedScalar,
        ylEscape, ylLiteralScalar, ylFoldedScalar, ylFlow, ylLineStart,
        ylComment, ylTagHandle, ylTagSuffix, ylVerbatimTag, ylDirective,
        ylMajorVersion, ylMinorVersion, ylDefineTagHandle,
        ylDefineTagHandleInitial, ylDefineTagURI, ylDefineTagURIInitial,
        ylLineEnd
    
    YamlLexer* = object of BaseLexer
        indentations: seq[int]
        encoding: Encoding
        charlen: int
        charoffset: int

const
    UTF8NextLine = toUTF8(Rune(0x85))
    UTF8NonBreakingSpace = toUTF8(Rune(0xA0))
    UTF8LineSeparator = toUTF8(Rune(0x2028))
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

template yieldToken(mKind: YamlLexerEventKind) {.dirty.} =
    yield (kind: mKind, content: content)
    content = ""

template yieldError(message: string) {.dirty.} =
    yield (kind: yamlError, content: message)
    content = ""

template yieldChar(c: char) {.dirty.} =
    yield (kind: yamlControlChar, content: "" & c)

template handleCR() {.dirty.} =
    my.bufpos = lexbase.handleLF(my, my.bufpos + my.charoffset) + my.charlen -
            my.charoffset - 1
    continue

template handleLF() {.dirty.} =
    my.bufpos = lexbase.handleLF(my, my.bufpos + my.charoffset) +
            my.charlen - my.charoffset - 1
    continue

template `or`(r: Rune, i: int): Rune =
    cast[Rune](cast[int](r) or i)

iterator tokens*(my: var YamlLexer): YamlLexerEvent =
    var
        content = ""
        unicodeChar: Rune = cast[Rune](0)
        escapeLength = 0
        expectedEscapeLength = 0
        lastSpecialChar: char = '\0'
        flowDepth = 0
        state = ylLineStart
    while true:
        let c = my.buf[my.bufpos + my.charoffset]
        case state
        of ylLineEnd:
            case c
            of '\r':
                state = ylLineStart
                handleCR()
            of '\x0A':
                state = ylLineStart
                handleLF()
            of EndOfFile:
                yieldToken(yamlStreamEnd)
                break
            else:
                yieldError("Internal error! Please report this bug.")
        of ylSingleQuotedScalar:
            if lastSpecialChar != '\0':
                # ' is the only special char
                case c
                of '\'':
                    content.add(c)
                    lastSpecialChar = '\0'
                of EndOfFile, '\r', '\x0A':
                    yieldToken(yamlScalar)
                    lastSpecialChar = '\0'
                    state = ylLineEnd
                    continue
                else:
                    yieldToken(yamlScalar)
                    lastSpecialChar = '\0'
                    state = if flowDepth > 0: ylFlow else: ylBlock
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
                    content.add(c)
        of ylDoublyQuotedScalar:
            case c
            of '"':
                yieldToken(yamlScalar)
                state = if flowDepth > 0: ylFlow else: ylBlock
            of EndOfFile:
                yieldError("Unterminated doubly quoted string")
                yieldToken(yamlStreamEnd)
                break
            of '\\':
                state = ylEscape
                escapeLength = 0
            of '\r':
                content.add("\x0A")
                handleCR()
            of '\x0A':
                content.add(c)
                handleLF()
            else:
                content.add(c)
        of ylEscape:
            if escapeLength == 0:
                expectedEscapeLength = 0
                case c
                of EndOfFile:
                    yieldError("Unterminated doubly quoted string")
                of '0':       content.add('\0')
                of 'a':       content.add('\x07')
                of 'b':       content.add('\x08')
                of '\t', 't': content.add('\t')
                of 'n':       content.add('\x0A')
                of 'v':       content.add('\v')
                of 'f':       content.add('\f')
                of 'r':       content.add('\r')
                of 'e':       content.add('\e')
                of ' ':       content.add(' ')
                of '"':       content.add('"')
                of '/':       content.add('/')
                of '\\':      content.add('\\')
                of 'N':       content.add(UTF8NextLine)
                of '_':       content.add(UTF8NonBreakingSpace)
                of 'L':       content.add(UTF8LineSeparator)
                of 'P':       content.add(UTF8ParagraphSeparator)
                of 'x': unicodeChar = cast[Rune](0); expectedEscapeLength = 3
                of 'u': unicodeChar = cast[Rune](0); expectedEscapeLength = 5
                of 'U': unicodeChar = cast[Rune](0); expectedEscapeLength = 9
                else:
                    yieldError("Unsupported escape sequence: \\" & c)
                if expectedEscapeLength == 0: state = ylDoublyQuotedScalar
            else:
                case c
                of EndOFFile:
                    yieldError("Unterminated escape sequence")
                    state = ylLineEnd
                    continue
                of '0' .. '9':
                    unicodeChar = unicodechar or
                            (cast[int](c) - 0x30) shl ((4 - escapeLength) * 8)
                of 'A' .. 'F':
                    unicodeChar = unicodechar or
                            (cast[int](c) - 0x37) shl ((4 - escapeLength) * 8)
                of 'a' .. 'f':
                    unicodeChar = unicodechar or
                            (cast[int](c) - 0x57) shl ((4 - escapeLength) * 8)
                else:
                    yieldError("unsupported char in unicode escape sequence: " & c)
                    escapeLength = 0
                    state = ylDoublyQuotedScalar
                    continue
            inc(escapeLength)
            if escapeLength == expectedEscapeLength and escapeLength > 0:
                content.add(toUTF8(unicodeChar))
                state = ylDoublyQuotedScalar
        
        of ylPlainScalar:
            if lastSpecialChar != '\0':
                case c
                of ' ', '\t', EndOfFile, '\r', '\x0A':
                    yieldToken(yamlScalar)
                    state = if flowDepth > 0: ylFlow else: ylBlock
                    continue
                else:
                    content.add(lastSpecialChar)
                    lastSpecialChar = '\0'
            
            case c
            of EndOfFile, '\r', '\x0A':
                yieldToken(yamlScalar)
                state = ylLineEnd
                continue
            of ':', '#':
                lastSpecialChar = c
            of ',':
                if flowDepth > 0: lastSpecialChar = c
                else: content.add(c)
            of '[', ']', '{', '}':
                yieldToken(yamlScalar)
                state = if flowDepth > 0: ylFlow else: ylBlock
                continue
            else:
                content.add(c)
                
        of ylFlow, ylBlock:
            if lastSpecialChar != '\0':
                case c
                of ' ', '\t', '\r', '\x0A', EndOfFile:
                    case lastSpecialChar
                    of '#':
                        content = "#"
                        state = ylComment
                        lastSpecialChar = '\0'
                    else:
                        yieldChar(lastSpecialChar)
                        lastSpecialChar = '\0'
                elif lastSpecialChar == '!':
                    case c
                    of '<':
                        state = ylVerbatimTag
                        lastSpecialChar = '\0'
                        my.bufpos += my.charlen
                    else:
                        state = ylTagHandle
                        content = "!"
                        lastSpecialChar = '\0'
                else:
                    content.add(lastSpecialChar)
                    lastSpecialChar = '\0'
                    state = ylPlainScalar
                continue
            case c
            of EndOfFile:
                yieldError("Unterminated flow content")
                state = ylLineEnd
                continue
            of '\r', '\x0A':
                state = ylLineEnd
                continue
            of ',':
                if state == ylFlow:
                    yieldChar(c)
                else:
                    content = "" & c
                    state = ylPlainScalar
            of '[', '{':
                inc(flowDepth)
                yieldChar(c)
            of ']', '}':
                if state == ylBlock:
                    yieldError(c & " encountered while in block mode")
                else:
                    inc(flowDepth, -1)
                    yieldChar(c)
                    if flowDepth == 0:
                        state = ylBlock
            of '#':
                lastSpecialChar = '#'
            of '"':
                content = ""
                state = ylDoublyQuotedScalar
            of '\'':
                content = ""
                state = ylSingleQuotedScalar
            of '!':
                lastSpecialChar = '!'
            of '&':
                yieldError("TODO: anchors")
            of '*':
                yieldError("TODO: links")
            of ' ':
                discard
            of '-':
                if state == ylBlock:
                    lastSpecialChar = '-'
                else:
                    content = "" & c
                    state = ylPlainScalar
            of '?', ':':
                lastSpecialChar = c
            of '\t':
                discard
            else:
                content = "" & c
                state = ylPlainScalar
        of ylComment:
            case c
            of EndOfFile, '\r', '\x0A':
                yieldToken(yamlComment)
                state = ylLineEnd
                continue
            else:
                content.add(c)
        of ylLineStart:
            case c
            of EndOfFile, '\r', '\x0A':
                yieldToken(yamlLineStart)
                state = ylLineEnd
                continue
            of ' ':
                content.add(' ')
            of '%':
                yieldToken(yamlLineStart)
                if content.len == 0:
                    content.add(c)
                    state = ylDirective
                else:
                    state = if flowDepth > 0: ylFlow else: ylBlock
                    continue
            else:
                yieldToken(yamlLineStart)
                state = if flowDepth > 0: ylFlow else: ylBlock
                continue
        of ylLiteralScalar, ylFoldedScalar:
            discard
        of ylTagHandle:
            case c
            of '!':
                content.add(c)
                yieldToken(yamlTagHandle)
                state = ylTagSuffix
            of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-':
                content.add(c)
            of ' ', '\t', EndOfFile, '\r', '\x0A':
                var suffix = content[1..^1]
                content = "!"
                yieldToken(yamlTagHandle)
                content = suffix
                yieldToken(yamlTagSuffix)
                if c in ['\r', '\x0A', EndOfFile]:
                    state = ylLineEnd
                    continue
                else:
                    state = if flowDepth > 0: ylFlow else: ylBlock
            else:
                yieldError("Invalid character in tag handle: " & c)
                content = ""
                state = if flowDepth > 0: ylFlow else: ylBlock
        of ylTagSuffix:
            case c
            of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@',
               '&', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')':
                content.add(c)
            of ' ', '\t', EndOfFile, '\r', '\x0A':
                yieldToken(yamlTagSuffix)
                if c in ['\r', '\x0A', EndOfFile]:
                    state = ylLineEnd
                    continue
                else:
                    state = if flowDepth > 0: ylFlow else: ylBlock
            else:
                yieldError("Invalid character in tag suffix: " & c)
                state = if flowDepth > 0: ylFlow else: ylBlock
        of ylVerbatimTag:
            case c
            of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@',
               '&', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')':
                content.add(c)
            of '>':
                yieldToken(yamlVerbatimTag)
                state = if flowDepth > 0: ylFlow else: ylBlock
            of EndOfFile, '\r', '\x0A':
                yieldError("Unfinished verbatim tag")
                state = ylLineEnd
                continue
            else:
                yieldError("Invalid character in tag URI: " & c)
                content = ""
                state = if flowDepth > 0: ylFlow else: ylBlock
        of ylDirective:
            case c
            of ' ', '\t', '\r', '\x0A', EndOfFile:
                if content == "%YAML":
                    yieldToken(yamlYamlDirective)
                    state = ylMajorVersion
                elif content == "%TAG":
                    yieldToken(yamlTagDirective)
                    state = ylDefineTagHandleInitial
                else:
                    yieldError("Unknown directive: " & content)
                    state = if flowDepth > 0: ylFlow else: ylBlock
                if c == EndOfFile:
                    continue
            else:
                content.add(c)
        of ylMajorVersion, ylMinorVersion:
            case c
            of '0' .. '9':
                content.add(c)
            of '.':
                if state == ylMajorVersion:
                    yieldToken(yamlMajorVersion)
                    state = ylMinorVersion
                else:
                    yieldError("Duplicate '.' char in YAML version.")
                    state = if flowDepth > 0: ylFlow else: ylBlock
            of EndOfFile, '\r', '\x0A':
                if state == ylMinorVersion:
                    yieldToken(yamlMinorVersion)
                else:
                    yieldError("Missing YAML minor version")
                state = ylLineEnd
                continue
            else:
                yieldError("Invalid character in YAML version: " & c)
                state = if flowDepth > 0: ylFlow else: ylBlock
        of ylDefineTagHandleInitial:
            case c
            of ' ', '\t':
                discard
            of EndOfFile, '\r', '\x0A':
                yieldError("Unfinished %TAG directive")
                state = ylLineEnd
                continue
            of '!':
                content.add(c)
                state = ylDefineTagHandle
            else:
                yieldError("Unexpected character in %TAG directive: " & c)
                state = if flowDepth > 0: ylFlow else: ylBlock
        of ylDefineTagHandle:
            case c
            of '!':
                content.add(c)
                yieldToken(yamlTagHandle)
                state = ylDefineTagURIInitial
            of 'a' .. 'z', 'A' .. 'Z', '-':
                content.add(c)
            of EndOfFile, '\r', '\x0A':
                yieldError("Unfinished %TAG directive")
                state = ylLineEnd
                continue
            else:
                yieldError("Unexpected char in %TAG directive: " & c)
                state = if flowDepth > 0: ylFlow else: ylBlock
        of ylDefineTagURIInitial:
            case c
            of '\t', ' ':
                content.add(c)
            of '\x0A', '\r', EndOfFile:
                yieldError("Unfinished %TAG directive")
                state = ylLineEnd
                continue
            else:
                if content.len == 0:
                    yieldError("Missing whitespace in %TAG directive")
                content = ""
                state = ylDefineTagURI
                continue
        of ylDefineTagURI:
            case c
            of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '#', ';', '/', '?', ':', '@',
               '&', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')':
                content.add(c)
            of '\x0A', '\r', EndOfFile:
                yieldToken(yamlTagURI)
                state = ylLineEnd
                continue
            else:
                yieldError("Invalid URI character: " & c)
                state = if flowDepth > 0: ylFlow else: ylBlock
                continue
        
        my.bufpos += my.charlen