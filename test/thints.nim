import unittest
import ../yaml/hints

suite "Hints":
  test "Integers":
    # [-+]? [0-9]+
    assert guessType("0") == yTypeInteger
    assert guessType("01") == yTypeInteger
    assert guessType("10") == yTypeInteger
    assert guessType("248") == yTypeInteger
    assert guessType("-4248") == yTypeInteger
    assert guessType("+4248") == yTypeInteger

  test "Floats":
    # [-+]? ( \. [0-9]+ | [0-9]+ ( \. [0-9]* )? ) ( [eE] [-+]? [0-9]+ )?

    # Batch: [-+]? ( \. [0-9]+ | [0-9]+ ( \. [0-9]* )? )
    assert guessType(".5") == yTypeFloat
    assert guessType("+.5") == yTypeFloat
    assert guessType("-.5") == yTypeFloat
    assert guessType("0.5") == yTypeFloat
    assert guessType("+0.5") == yTypeFloat
    assert guessType("-0.5") == yTypeFloat
    assert guessType("5.5") == yTypeFloat
    assert guessType("+5.5") == yTypeFloat
    assert guessType("-5.5") == yTypeFloat
    assert guessType("5.") == yTypeFloat
    assert guessType("+5.") == yTypeFloat
    assert guessType("-5.") == yTypeFloat

    # Batch: [-+]? \. [0-9]+ [eE] [-+]? [0-9]+
    assert guessType(".5e5") == yTypeFloat
    assert guessType("+.5e5") == yTypeFloat
    assert guessType("-.5e5") == yTypeFloat
    assert guessType(".5e+5") == yTypeFloat
    assert guessType("+.5e+5") == yTypeFloat
    assert guessType("-.5e+5") == yTypeFloat
    assert guessType(".5e-5") == yTypeFloat
    assert guessType("+.5e-5") == yTypeFloat
    assert guessType("-.5e-5") == yTypeFloat

    assert guessType(".5e05") == yTypeFloat
    assert guessType("+.5e05") == yTypeFloat
    assert guessType("-.5e05") == yTypeFloat
    assert guessType(".5e+05") == yTypeFloat
    assert guessType("+.5e+05") == yTypeFloat
    assert guessType("-.5e+05") == yTypeFloat
    assert guessType(".5e-05") == yTypeFloat
    assert guessType("+.5e-05") == yTypeFloat
    assert guessType("-.5e-05") == yTypeFloat

    assert guessType(".05e5") == yTypeFloat
    assert guessType("+.05e5") == yTypeFloat
    assert guessType("-.05e5") == yTypeFloat
    assert guessType(".05e+5") == yTypeFloat
    assert guessType("+.05e+5") == yTypeFloat
    assert guessType("-.05e+5") == yTypeFloat
    assert guessType(".05e-5") == yTypeFloat
    assert guessType("+.05e-5") == yTypeFloat
    assert guessType("-.05e-5") == yTypeFloat

    assert guessType(".05e05") == yTypeFloat
    assert guessType("+.05e05") == yTypeFloat
    assert guessType("-.05e05") == yTypeFloat
    assert guessType(".05e+05") == yTypeFloat
    assert guessType("+.05e+05") == yTypeFloat
    assert guessType("-.05e+05") == yTypeFloat
    assert guessType(".05e-05") == yTypeFloat
    assert guessType("+.05e-05") == yTypeFloat
    assert guessType("-.05e-05") == yTypeFloat

    # Batch: [-+]? [0-9]+ \. [0-9]* [eE] [-+]? [0-9]+
    assert guessType("0.5e5") == yTypeFloat
    assert guessType("+0.5e5") == yTypeFloat
    assert guessType("-0.5e5") == yTypeFloat
    assert guessType("0.5e+5") == yTypeFloat
    assert guessType("+0.5e+5") == yTypeFloat
    assert guessType("-0.5e+5") == yTypeFloat
    assert guessType("0.5e-5") == yTypeFloat
    assert guessType("+0.5e-5") == yTypeFloat
    assert guessType("-0.5e-5") == yTypeFloat

    assert guessType("0.5e05") == yTypeFloat
    assert guessType("+0.5e05") == yTypeFloat
    assert guessType("-0.5e05") == yTypeFloat
    assert guessType("0.5e+05") == yTypeFloat
    assert guessType("+0.5e+05") == yTypeFloat
    assert guessType("-0.5e+05") == yTypeFloat
    assert guessType("0.5e-05") == yTypeFloat
    assert guessType("+0.5e-05") == yTypeFloat
    assert guessType("-0.5e-05") == yTypeFloat

    assert guessType("0.05e5") == yTypeFloat
    assert guessType("+0.05e5") == yTypeFloat
    assert guessType("-0.05e5") == yTypeFloat
    assert guessType("0.05e+5") == yTypeFloat
    assert guessType("+0.05e+5") == yTypeFloat
    assert guessType("-0.05e+5") == yTypeFloat
    assert guessType("0.05e-5") == yTypeFloat
    assert guessType("+0.05e-5") == yTypeFloat
    assert guessType("-0.05e-5") == yTypeFloat

    assert guessType("0.05e05") == yTypeFloat
    assert guessType("+0.05e05") == yTypeFloat
    assert guessType("-0.05e05") == yTypeFloat
    assert guessType("0.05e+05") == yTypeFloat
    assert guessType("+0.05e+05") == yTypeFloat
    assert guessType("-0.05e+05") == yTypeFloat
    assert guessType("0.05e-05") == yTypeFloat
    assert guessType("+0.05e-05") == yTypeFloat
    assert guessType("-0.05e-05") == yTypeFloat

    # Batch: [-+]? [0-9]+ [eE] [-+]? [0-9]+
    assert guessType("5e5") == yTypeFloat
    assert guessType("+5e5") == yTypeFloat
    assert guessType("-5e5") == yTypeFloat
    assert guessType("5e+5") == yTypeFloat
    assert guessType("+5e+5") == yTypeFloat
    assert guessType("-5e+5") == yTypeFloat
    assert guessType("5e-5") == yTypeFloat
    assert guessType("+5e-5") == yTypeFloat
    assert guessType("-5e-5") == yTypeFloat

    assert guessType("5e05") == yTypeFloat
    assert guessType("+5e05") == yTypeFloat
    assert guessType("-5e05") == yTypeFloat
    assert guessType("5e+05") == yTypeFloat
    assert guessType("+5e+05") == yTypeFloat
    assert guessType("-5e+05") == yTypeFloat
    assert guessType("5e-05") == yTypeFloat
    assert guessType("+5e-05") == yTypeFloat
    assert guessType("-5e-05") == yTypeFloat

    assert guessType("05e5") == yTypeFloat
    assert guessType("+05e5") == yTypeFloat
    assert guessType("-05e5") == yTypeFloat
    assert guessType("05e+5") == yTypeFloat
    assert guessType("+05e+5") == yTypeFloat
    assert guessType("-05e+5") == yTypeFloat
    assert guessType("05e-5") == yTypeFloat
    assert guessType("+05e-5") == yTypeFloat
    assert guessType("-05e-5") == yTypeFloat

    assert guessType("05e05") == yTypeFloat
    assert guessType("+05e05") == yTypeFloat
    assert guessType("-05e05") == yTypeFloat
    assert guessType("05e+05") == yTypeFloat
    assert guessType("+05e+05") == yTypeFloat
    assert guessType("-05e+05") == yTypeFloat
    assert guessType("05e-05") == yTypeFloat
    assert guessType("+05e-05") == yTypeFloat
    assert guessType("-05e-05") == yTypeFloat

  test "Non-Floats":
    assert guessType(".") != yTypeFloat
    assert guessType("+.") != yTypeFloat
    assert guessType("-.") != yTypeFloat
    assert guessType(".e4") != yTypeFloat
    assert guessType("+.e4") != yTypeFloat
    assert guessType("-.e4") != yTypeFloat

  test "Bool-True":
    assert guessType("y") == yTypeBoolTrue
    assert guessType("Y") == yTypeBoolTrue
    assert guessType("yes") == yTypeBoolTrue
    assert guessType("Yes") == yTypeBoolTrue
    assert guessType("true") == yTypeBoolTrue
    assert guessType("True") == yTypeBoolTrue
    assert guessType("on") == yTypeBoolTrue
    assert guessType("On") == yTypeBoolTrue

  test "Bool-False":
    assert guessType("n") == yTypeBoolFalse
    assert guessType("N") == yTypeBoolFalse
    assert guessType("no") == yTypeBoolFalse
    assert guessType("No") == yTypeBoolFalse
    assert guessType("false") == yTypeBoolFalse
    assert guessType("False") == yTypeBoolFalse
    assert guessType("off") == yTypeBoolFalse
    assert guessType("Off") == yTypeBoolFalse

  test "Non-Bools":
    assert guessType("ye") != yTypeBoolTrue
    assert guessType("yse") != yTypeBoolTrue
    # assert guessType("nO") != yTypeBoolFalse
    assert guessType("flase") != yTypeBoolFalse
