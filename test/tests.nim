#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

{.warning[UnusedImport]: off.}
import tlex, tjson, tnative, tparser, tannotations, thints, tpresenter

# tquickstart compiles and runs the documentation examples as native
# executables, which is not possible from the JS backend.
when not defined(js):
  import tquickstart

when not defined(gcArc) or defined(gcOrc):
  import tdom
