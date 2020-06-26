#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016-2020 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## =======================
## Module yaml.annotations
## =======================
##
## This module provides annotations for object fields that customize
## (de)serialization behavior of those fields.

template defaultVal*(value : typed) {.pragma.}
  ## This annotation can be put on an object field. During deserialization,
  ## if no value for this field is given, the ``value`` parameter of this
  ## annotation is used as value.
  ##
  ## Example usage:
  ##
  ## .. code-block::
  ##   type MyObject = object
  ##     a {.defaultVal: "foo".}: string
  ##     c {.defaultVal: (1,2).}: tuple[x, y: int]

template sparse*() {.pragma.}
  ## This annotation can be put on an object type. During deserialization,
  ## the input may omit any field that has an ``Option[T]`` type (for any
  ## concrete ``T``) and that field will be treated as if it had the annotation
  ## ``{.defaultVal: none(T).}``.
  ##
  ## Example usage:
  ##
  ## .. code-block::
  ##  type MyObject {.sparse.} = object
  ##    a: Option[string]
  ##    b: Option[int]

template transient*() {.pragma.}
  ## This annotation can be put on an object field. Any object field
  ## carrying this annotation will not be serialized to YAML and cannot be given
  ## a value when deserializing. Giving a value for this field during
  ## deserialization is an error.
  ##
  ## Example usage:
  ##
  ## .. code-block::
  ##   type MyObject = object
  ##     a, b: string
  ##     c: int
  ##   markAsTransient(MyObject, a)
  ##   markAsTransient(MyObject, c)

template ignore*(keys : openarray[string]) {.pragma.}
  ## This annotation can be put on an object type. All keys with the given
  ## names in the input YAML mapping will be ignored when deserializing a value
  ## of this type. This can be used to ignore parts of the YAML structure.
  ##
  ## You may use it with an empty list (``{.ignore: [].}``) to ignore *all*
  ## unknown keys.
  ##
  ## Example usage:
  ##
  ## .. code-block::
  ##   type MyObject {.ignore: ["c"].} = object
  ##     a, b: string

template implicit*() {.pragma.}
  ## This annotation declares a variant object type as implicit.
  ## This requires the type to consist of nothing but a case expression and each
  ## branch of the case expression containing exactly one field - with the
  ## exception that one branch may contain zero fields.
  ##
  ## Example usage:
  ##
  ## .. code-block::
  ##   ContainerKind = enum
  ##     ckString, ckInt
  ##
  ##   type MyObject {.implicit.} = object
  ##     case kind: ContainerKind
  ##     of ckString:
  ##       strVal: string
  ##     of ckInt:
  ##       intVal: int