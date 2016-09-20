#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## This module provides facilities to generate and interpret
## `YAML <http://yaml.org>`_ character streams. All primitive operations on
## data objects use a `YamlStream <#YamlStream>`_ either as source or as
## output. Because this stream is implemented as iterator, it is possible to
## process YAML input and output sequentially, i.e. without loading the
## processed data structure completely into RAM. This supports the processing of
## large data structures.
##
## As YAML is a strict superset of `JSON <http://json.org>`_, JSON input is
## automatically supported. While JSON is less readable than YAML,
## this enhances interoperability with other languages.

import yaml.common, yaml.dom, yaml.hints, yaml.parser, yaml.presenter,
       yaml.serialization, yaml.stream, yaml.taglib, yaml.tojson
export yaml.common, yaml.dom, yaml.hints, yaml.parser, yaml.presenter,
       yaml.serialization, yaml.stream, yaml.taglib, yaml.tojson