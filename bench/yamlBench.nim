import "../yaml", common
import math, strutils, stopwatch, terminal, algorithm, random

from nimlets_yaml import objKind

type
    Level = tuple
        kind: YamlNodeKind
        len: int

proc genString(maxLen: int): string =
    let len = random(maxLen)
    result = ""
    for i in 1 .. len: result.add(cast[char](random(127 - 32) + 32))

proc genBlockString(): string =
    let lines = 5 + random(10)
    let flow = random(2) == 0
    result = ""
    for i in 1 .. lines:
        let lineLen = 32 + random(12)
        for i in i .. lineLen: result.add(cast[char](random(127 - 33) + 33))
        result.add(if flow: ' ' else: '\l')
    result.add('\l')

proc genKey(): string =
    let genPossiblePlainKey = random(1.0) < 0.75
    if genPossiblePlainKey:
        result = ""
        let len = random(24) + 1
        for i in 1 .. len:
            let c = random(26 + 26 + 10)
            if c < 26: result.add(char(c + 65))
            elif c < 52: result.add(char(c + 97 - 26))
            else: result.add(char(c + 48 - 52)) 
    else: result = genString(31) & char(random(26) + 65)

proc genYamlString(size: int, maxStringLen: int,
                   style: PresentationStyle): string =
    ## Generates a random YAML string.
    ## size is in KiB, mayStringLen in characters.
    
    randomize(size * maxStringLen * ord(style))
    
    let targetSize = size * 1024
    var
        target = newStringStream()
        input = iterator(): YamlStreamEvent =
            var
                levels = newSeq[Level]()
                curSize = 1
            levels.add((kind: yMapping, len: 0))
            yield startDocEvent()
            yield startMapEvent()
            
            while levels.len > 0:
                let
                    objectCloseProbability =
                        float(levels[levels.high].len + levels.high) * 0.025
                    closeObject = random(1.0) <= objectCloseProbability
        
                if (closeObject and levels.len > 1) or curSize > targetSize:
                    case levels[levels.high].kind
                    of yMapping: yield endMapEvent()
                    of ySequence: yield endSeqEvent()
                    else: assert(false)
                    curSize += 1
                    discard levels.pop()
                    continue
        
                levels[levels.high].len += 1
                if levels[levels.high].kind == yMapping:
                    let key = genKey()
                    yield scalarEvent(key)
    
                let
                    objectValueProbability =
                        0.8 / float(levels.len * levels.len)
                    generateObjectValue = random(1.0) <= objectValueProbability
                    hasTag = random(2) == 0
                var tag = yTagQuestionMark
    
                if generateObjectValue:
                    let objectKind = if random(3) == 0: ySequence else: yMapping
                    case objectKind
                    of yMapping:
                        if hasTag: tag = yTagMapping
                        yield startMapEvent(tag)
                    of ySequence:
                        if hasTag: tag = yTagSequence
                        yield startSeqEvent(tag)
                    else: assert(false)
                    curSize += 1
                    levels.add((kind: objectKind, len: 0))
                else:
                    var s: string
                    case random(11)
                    of 0..4:
                        s = genString(maxStringLen)
                        if hasTag: tag = yTagString
                    of 5:
                        s = genBlockString()
                    of 6..7:
                        s = $random(32000)
                        if hasTag: tag = yTagInteger
                    of 8..9:
                        s = $(random(424242.4242) - 212121.21)
                        if hasTag: tag = yTagFloat
                    of 10:
                        case random(3)
                        of 0:
                            s = "true"
                            if hasTag: tag = yTagBoolean
                        of 1:
                            s = "false"
                            if hasTag: tag = yTagBoolean
                        of 2:
                            s = "null"
                            if hasTag: tag = yTagNull
                        else: discard
                    else: discard
        
                    yield scalarEvent(s, tag)
                    curSize += s.len
            yield endDocEvent()
    var yStream = initYamlStream(input)
    present(yStream, target, initExtendedTagLibrary(),
            defineOptions(style=style, outputVersion=ov1_1))
    result = target.data
    
var
    cYaml1k, cYaml10k, cYaml100k, cLibYaml1k, cLibYaml10k, cLibYaml100k: int64
    yaml1k   = genYamlString(1, 32, psDefault)
    yaml10k  = genYamlString(10, 32, psDefault)
    yaml100k = genYamlString(100, 32, psDefault)
    tagLib   = initExtendedTagLibrary()
    parser = newYamlParser(tagLib)

block:
    multibench(cYaml1k, 100):
        var s = newStringStream(yaml1k)
        let res = loadDOM(s)
        assert res.root.kind == yMapping

block:
    multibench(cYaml10k, 100):
        var s = newStringStream(yaml10k)
        let res = loadDOM(s)
        assert res.root.kind == yMapping

block:
    multibench(cYaml100k, 100):
        var s = newStringStream(yaml100k)
        let res = loadDOM(s)
        assert res.root.kind == yMapping

block:
    multibench(cLibYaml1k, 100):
        let res = nimlets_yaml.load(yaml1k)
        assert res[0].objKind == nimlets_yaml.YamlObjKind.Map

block:
    multibench(cLibYaml10k, 100):
        let res = nimlets_yaml.load(yaml10k)
        assert res[0].objKind == nimlets_yaml.YamlObjKind.Map

block:
    multibench(cLibYaml100k, 100):
        let res = nimlets_yaml.load(yaml100k)
        assert res[0].objKind == nimlets_yaml.YamlObjKind.Map

proc writeResult(caption: string, num: int64) =
    styledWriteLine(stdout, resetStyle, caption, fgGreen, $num, resetStyle, "μs")

setForegroundColor(fgWhite)

writeStyled "Benchmark: Processing YAML input\n"
writeStyled "================================\n"
writeStyled "1k input\n--------\n"
writeResult "NimYAML: ", cYaml1k div 1000
writeResult "LibYAML: ", cLibYaml1k div 1000
setForegroundColor(fgWhite)
writeStyled "10k input\n---------\n"
writeResult "NimYAML: ", cYaml10k div 1000
writeResult "LibYAML: ", cLibYaml10k div 1000
setForegroundColor(fgWhite)
writeStyled "100k input\n----------\n"
writeResult "NimYAML: ", cYaml100k div 1000
writeResult "LibYAML: ", cLibYaml100k div 1000