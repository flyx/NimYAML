import unittest
import ../yaml/hints

suite "Hints":
  test "Int":
    # [-+]? [0-9]+
    assert guessType("0") == yTypeInteger
    assert guessType("01") == yTypeInteger
    assert guessType("10") == yTypeInteger
    assert guessType("248") == yTypeInteger
    assert guessType("-4248") == yTypeInteger
    assert guessType("+4248") == yTypeInteger

  test "Non-Int":
    assert guessType("0+0") != yTypeInteger
    assert guessType("0-1") != yTypeInteger
    assert guessType("1x0") != yTypeInteger
    assert guessType("248e") != yTypeInteger
    assert guessType("-4248 4") != yTypeInteger
    assert guessType("+-4248") != yTypeInteger

  test "Float":
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

  test "Non-Float":
    assert guessType(".") != yTypeFloat
    assert guessType("+.") != yTypeFloat
    assert guessType("-.") != yTypeFloat
    assert guessType(".e4") != yTypeFloat
    assert guessType("+.e4") != yTypeFloat
    assert guessType("-.e4") != yTypeFloat

  test "Bool-True":
    # ``true | True | TRUE``
    assert guessType("true") == yTypeBoolTrue
    assert guessType("True") == yTypeBoolTrue
    assert guessType("TRUE") == yTypeBoolTrue

  test "Bool-False":
    # ``false | False | FALSE``
    assert guessType("false") == yTypeBoolFalse
    assert guessType("False") == yTypeBoolFalse
    assert guessType("FALSE") == yTypeBoolFalse

  test "Non-Bool":
    # y, yes, on should not be treated as bool
    assert guessType("y") notin {yTypeBoolTrue, yTypeBoolFalse}
    assert guessType("Y") notin {yTypeBoolTrue, yTypeBoolFalse}
    assert guessType("yes") notin {yTypeBoolTrue, yTypeBoolFalse}
    assert guessType("Yes") notin {yTypeBoolTrue, yTypeBoolFalse}
    assert guessType("on") notin {yTypeBoolTrue, yTypeBoolFalse}
    assert guessType("On") notin {yTypeBoolTrue, yTypeBoolFalse}

    # n, no, off should not be treated as bool
    assert guessType("n") notin {yTypeBoolFalse, yTypeBoolFalse}
    assert guessType("N") notin {yTypeBoolFalse, yTypeBoolFalse}
    assert guessType("no") notin {yTypeBoolFalse, yTypeBoolFalse}
    assert guessType("No") notin {yTypeBoolFalse, yTypeBoolFalse}
    assert guessType("off") notin {yTypeBoolFalse, yTypeBoolFalse}
    assert guessType("Off") notin {yTypeBoolFalse, yTypeBoolFalse}

    # miss-cased words should not be treated as bool
    assert guessType("tRUE") notin {yTypeBoolTrue, yTypeBoolFalse}
    assert guessType("TRue") notin {yTypeBoolTrue, yTypeBoolFalse}
    assert guessType("fAlse") notin {yTypeBoolTrue, yTypeBoolFalse}
    assert guessType("FALSe") notin {yTypeBoolTrue, yTypeBoolFalse}

    # miss-spelled words should not be treated as bool
    assert guessType("ye") notin {yTypeBoolTrue, yTypeBoolFalse}
    assert guessType("yse") notin {yTypeBoolTrue, yTypeBoolFalse}
    assert guessType("nO") notin {yTypeBoolTrue, yTypeBoolFalse}
    assert guessType("flase") notin {yTypeBoolTrue, yTypeBoolFalse}

  test "Inf":
    # ``[-+]? ( \.inf | \.Inf | \.INF )``
    assert guessType(".inf") == yTypeFloatInf
    assert guessType(".Inf") == yTypeFloatInf
    assert guessType(".INF") == yTypeFloatInf

    assert guessType("+.inf") == yTypeFloatInf
    assert guessType("+.Inf") == yTypeFloatInf
    assert guessType("+.INF") == yTypeFloatInf

    assert guessType("-.inf") == yTypeFloatInf
    assert guessType("-.Inf") == yTypeFloatInf
    assert guessType("-.INF") == yTypeFloatInf

  test "Non-Inf":
    assert guessType(".InF") != yTypeFloatInf
    assert guessType(".INf") != yTypeFloatInf

  test "NaN":
    # ``\.nan | \.NaN | \.NAN``
    assert guessType(".nan") == yTypeFloatNaN
    assert guessType(".NaN") == yTypeFloatNaN
    assert guessType(".NAN") == yTypeFloatNaN

  test "Non-NaN":
    assert guessType(".nAn") != yTypeFloatNaN
    assert guessType(".Nan") != yTypeFloatNaN
    assert guessType(".nAN") != yTypeFloatNaN

  test "Null":
    # ``null | Null | NULL | ~``
    assert guessType("null") == yTypeNull
    assert guessType("Null") == yTypeNull
    assert guessType("NULL") == yTypeNull
    assert guessType("~") == yTypeNull

  test "Non-Null":
    assert guessType("NuLL") != yTypeNull
    assert guessType("NUll") != yTypeNull
    assert guessType("NULl") != yTypeNull
    assert guessType("nULL") != yTypeNull
    assert guessType("~~") != yTypeNull
