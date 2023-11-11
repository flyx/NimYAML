#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## =================
## Module yaml/style
## =================
##
## The style API provides enums describing the style of YAML nodes.
## It also provides custom pragmas with which you can define the style
## with which values should be serialized.

type
  ScalarStyle* = enum
    ## Original style of the scalar (for input),
    ## or desired style of the scalar (for output).
    ssAny, ssPlain, ssSingleQuoted, ssDoubleQuoted, ssLiteral, ssFolded

  CollectionStyle* = enum
    ## Original style of the collection (for input).
    ## or desired style of the collection (for output).
    csAny, csBlock, csFlow, csPair

template scalar*(style: ScalarStyle) {.pragma.}
  ## This annotation can be put on an object field or on a type.
  ## It causes the value in the field or a value of this type
  ## to be presented with the given scalar style if possible.
  ## Ignored if the value does not serialize to a scalar.
  ##
  ## A pragma on a field overrides a pragma on the field's type.

template collection*(style: CollectionStyle) {.pragma.}
  ## This annotation can be put on an object field or on a type.
  ## It causes the value in the field or a value of this type
  ## to be presented with the given collection style if possible.
  ## Ignored if the value does not serialize to a collection.
  ##
  ## A pragma on a field overrides a pragma on the field's type.