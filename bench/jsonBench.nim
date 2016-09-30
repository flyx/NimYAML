import "../yaml", commonBench

from nimlets_yaml import objKind

import math, strutils, stopwatch, terminal, algorithm, random, json

proc cmp(left, right: clock): int = cmp(left.nanoseconds(), right.nanoseconds())

type
    ObjectKind = enum
        otMap, otSequence

    Level = tuple
        kind: ObjectKind
        len: int

proc genString(maxLen: int): string =
    let len = random(maxLen)
    result = "\""
    var i = 0
    while i < len - 1:
        let c = cast[char](random(127 - 32) + 32)
        case c
        of '"', '\\':
            result.add('\\')
            result.add(c)
            i += 2
        else:
            result.add(c)
            i += 1
    result.add('\"')

proc genJsonString(size: int, maxStringLen: int): string =
    ## Generates a random JSON string.
    ## size is in KiB, mayStringLen in characters.

    randomize(size * maxStringLen)
    result = "{"

    let targetSize = size * 1024
    var
        indentation = 2
        levels = newSeq[Level]()
        curSize = 1
        justOpened = true
    levels.add((kind: otMap, len: 0))

    while levels.len > 0:
        let
            objectCloseProbability =
                float(levels[levels.high].len + levels.high) * 0.025
            closeObject = random(1.0) <= objectCloseProbability

        if (closeObject and levels.len > 1) or curSize > targetSize:
            indentation -= 2
            if justOpened:
                justOpened = false
            else:
                result.add("\x0A")
                result.add(repeat(' ', indentation))
                curSize += indentation + 1
            case levels[levels.high].kind
            of otMap:
                result.add('}')
            of otSequence:
                result.add(']')
            curSize += 1
            discard levels.pop()
            continue

        levels[levels.high].len += 1

        if justOpened:
            justOpened = false
            result.add("\x0A")
            result.add(repeat(' ', indentation))
            curSize += indentation + 1
        else:
            result.add(",\x0A")
            result.add(repeat(' ', indentation))
            curSize += indentation + 2

        case levels[levels.high].kind
        of otMap:
            let key = genString(maxStringLen)
            result.add(key)
            result.add(": ")
            curSize += key.len + 2
        of otSequence:
            discard

        let
            objectValueProbability =
                0.8 / float(levels.len * levels.len)
            generateObjectValue = random(1.0) <= objectValueProbability

        if generateObjectValue:
            let objectKind = if random(2) == 0: otMap else: otSequence
            case objectKind
            of otMap:
                result.add('{')
            of otSequence:
                result.add('[')
            curSize += 1
            levels.add((kind: objectKind, len: 0))
            justOpened = true
            indentation += 2
        else:
            var s: string
            case random(11)
            of 0..5:
                s = genString(maxStringLen)
            of 6..7:
                s = $random(32000)
            of 8..9:
                s = $(random(424242.4242) - 212121.21)
            of 10:
                case random(3)
                of 0:
                    s = "true"
                of 1:
                    s = "false"
                of 2:
                    s = "null"
                else:
                    discard
            else:
                discard

            result.add(s)
            curSize += s.len

var
    cYaml1k, cYaml10k, cYaml100k, cJson1k, cJson10k, cJson100k,
            cLibYaml1k, cLibYaml10k, cLibYaml100k: int64
    json1k   = genJsonString(1, 32)
    json10k  = genJsonString(10, 32)
    json100k = genJsonString(100, 32)
    tagLib   = initCoreTagLibrary()
    parser = newYamlParser(initCoreTagLibrary())

block:
    multibench(cJson1k, 100):
        let res = parseJson(json1k)
        assert res.kind == JObject

block:
    multibench(cJson10k, 100):
        let res = parseJson(json10k)
        assert res.kind == JObject

block:
    multibench(cJson100k, 100):
        let res = parseJson(json100k)
        assert res.kind == JObject

block:
    multibench(cYaml1k, 100):
        let res = loadToJson(json1k)
        assert res[0].kind == JObject

block:
    multibench(cYaml10k, 100):
        let res = loadToJson(json10k)
        assert res[0].kind == JObject

block:
    multibench(cYaml100k, 100):
        let res = loadToJson(json100k)
        assert res[0].kind == JObject

block:
    multibench(cLibYaml1k, 100):
        let res = nimlets_yaml.load(json1k)
        assert res[0].objKind == nimlets_yaml.YamlObjKind.Map

block:
    multibench(cLibYaml10k, 100):
        let res = nimlets_yaml.load(json10k)
        assert res[0].objKind == nimlets_yaml.YamlObjKind.Map

block:
    multibench(cLibYaml100k, 100):
        let res = nimlets_yaml.load(json100k)
        assert res[0].objKind == nimlets_yaml.YamlObjKind.Map

proc writeResult(caption: string, num: int64) =
    styledWriteLine(stdout, resetStyle, caption, fgGreen, $num, resetStyle, "μs")

setForegroundColor(fgWhite)

writeStyled "Benchmark: Processing JSON input\n"
writeStyled "================================\n"
writeStyled "1k input\n--------\n"
writeResult "NimYAML: ", cYaml1k div 1000
writeResult "JSON:    ", cJson1k div 1000
writeResult "LibYAML: ", cLibYaml1k div 1000
setForegroundColor(fgWhite)
writeStyled "10k input\n---------\n"
writeResult "NimYAML: ", cYaml10k div 1000
writeResult "JSON:    ", cJson10k div 1000
writeResult "LibYAML: ", cLibYaml10k div 1000
setForegroundColor(fgWhite)
writeStyled "100k input\n----------\n"
writeResult "NimYAML: ", cYaml100k div 1000
writeResult "JSON:    ", cJson100k div 1000
writeResult "LibYAML: ", cLibYaml100k div 1000
