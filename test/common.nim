#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import "../yaml"

proc printDifference*(expected, actual: YamlStreamEvent) =
    if expected.kind != actual.kind:
        echo "expected " & $expected.kind & ", got " & $actual.kind
    else:
        case expected.kind
        of yamlScalar:
            if expected.scalarTag != actual.scalarTag:
                echo "[\"", actual.scalarContent, "\".tag] expected tag ",
                     expected.scalarTag, ", got ", actual.scalarTag
            elif expected.scalarAnchor != actual.scalarAnchor:
                echo "[scalarEvent] expected anchor ", expected.scalarAnchor,
                     ", got ", actual.scalarAnchor
            elif expected.scalarContent != actual.scalarContent:
                let msg = "[scalarEvent] expected content \"" &
                        expected.scalarContent & "\", got \"" &
                        actual.scalarContent & "\" "
                if expected.scalarContent.len != actual.scalarContent.len:
                    echo msg, "(length does not match)"
                else:
                    for i in 0..expected.scalarContent.high:
                        if expected.scalarContent[i] != actual.scalarContent[i]:
                            echo msg, "(first different char at pos ", i,
                                    ": expected ",
                                    cast[int](expected.scalarContent[i]),
                                    ", got ",
                                    cast[int](actual.scalarContent[i]), ")"
                            break
            else: echo "[scalarEvent] Unknown difference"
        of yamlStartMap:
            if expected.mapTag != actual.mapTag:
                echo "[map.tag] expected ", expected.mapTag, ", got ",
                     actual.mapTag
            elif expected.mapAnchor != actual.mapAnchor:
                echo "[map.anchor] expected ", expected.mapAnchor, ", got ",
                        actual.mapAnchor
            else: echo "[map.tag] Unknown difference"
        of yamlStartSeq:
            if expected.seqTag != actual.seqTag:
                echo "[seq.tag] expected ", expected.seqTag, ", got ",
                     actual.seqTag
            elif expected.seqAnchor != actual.seqAnchor:
                echo "[seq.anchor] expected ", expected.seqAnchor, ", got ",
                        actual.seqAnchor
            else: echo "[seq] Unknown difference"
        of yamlAlias:
            if expected.aliasTarget != actual.aliasTarget:
                echo "[alias] expected ", expected.aliasTarget, ", got ",
                     actual.aliasTarget
            else: echo "[alias] Unknown difference"
        else: echo "Unknown difference in event kind " & $expected.kind

template ensure*(input: var YamlStream,
                 expected: varargs[YamlStreamEvent]) {.dirty.} =
    var i = 0
    for token in input:
        if i >= expected.len:
            echo "received more tokens than expected (next token = ",
                 token.kind, ")"
            fail()
            break
        if token != expected[i]:
            echo "at token #" & $i & ":"
            printDifference(expected[i], token)
            fail()
            break
        i.inc()