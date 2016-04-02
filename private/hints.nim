#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

type
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
    
    ythMinus, yth0, ythInt, ythDecimal, ythNumE, ythNumEPlusMinus, ythExponent

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
        for item in rule[1].children: stateBranch.add(item)
      of nnkIdent: stateBranch.add(rule[1])
      else: assert false
      if rule[2].kind == nnkNilLit:
        stateBranch.add(newStmtList(newNimNode(nnkDiscardStmt).add(
                        newEmptyNode())))
      else:
        stateBranch.add(newStmtList(newAssignment(
                        newIdentNode("typeHintState"), copyNimTree(rule[2]))))
      stateBranches.add(stateBranch)
    stateBranches.add(newNimNode(nnkElse).add(newStmtList(
        newNimNode(nnkReturnStmt).add(newIdentNode("yTypeUnknown")))))
    charBranch.add(newStmtList(stateBranches))
    result.add(charBranch)
  result.add(newNimNode(nnkElse).add(newStmtList(
             newNimNode(nnkReturnStmt).add(newIdentNode("yTypeUnknown")))))

template advanceTypeHint(ch: char) {.dirty.} =
  typeHintStateMachine ch:
  of '~': ythInitial => ythNULL
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

proc guessType*(scalar: string): TypeHint =
  var typeHintState: YamlTypeHintState = ythInitial
  for c in scalar: advanceTypeHint(c)
  case typeHintState
  of ythNULL: result = yTypeNull
  of ythTRUE, ythON, ythYES, ythY: result = yTypeBoolTrue
  of ythFALSE, ythOFF, ythNO, ythN: result = yTypeBoolFalse
  of ythInt, yth0: result = yTypeInteger
  of ythDecimal, ythExponent: result = yTypeFloat
  of ythPointINF: result = yTypeFloatInf
  of ythPointNAN: result = yTypeFloatNaN
  else: result = yTypeUnknown