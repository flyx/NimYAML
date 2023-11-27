#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## .. importdoc::
##   yaml/loading.nim, yaml/dumping.nim, yaml/annotations.nim, yaml/taglib.nim,
##   yaml/style.nim, yaml/dom.nim, yaml/tojson.nim,
##   yaml/parser.nim, yaml/presenter.nim, yaml/data.nim, yaml/stream.nim  
##
## This is the root module of NimYAML, a package that provides facilities to
## generate and interpret `YAML <http://yaml.org>`_ character streams. Importing
## this package will import NimYAML's high level loading & dumping API.
## Additional APIs must be imported explicitly.
##
## There is no code in this package, all functionality is available via the
## exported sub-packages. You can import parts of the API by importing
## certain sub-packages only.
##
## High Level Loading & Dumping
## ============================
##
## .. code-block::
##
##   import yaml
##   # or alternatively:
##   import yaml / [loading, dumping, annotations, taglib, dom]
##
## Enables you to load YAML data directly into native Nim types and reversely
## dump native Nim types into YAML documents. This API corresponds to the full
## **Load** / **Dump** process as defined in the
## `YAML specification <https://yaml.org/spec/1.2.2/#31-processes>`_.
##
## The module `module yaml/loading`_ provides the `load`_ and `loadAs`_ procs
## which load a single YAML document into a native Nim value.
##
## The `module yaml/dumping`_ provides the `Dumper`_ object together with its
## `dump`_ methods that serialize a given Nim value into YAML.
##
## The `module yaml/annotations`_ provides various pragmas that allow you to
## define how certain aspects of your types are to be serialized, e.g. whether
## ``Optional`` fields may be omitted.
##
## The `module yaml/taglib`_ provides facilities that customize the YAML tags
## that are generated for your types. The primary usage for tags in the context
## of NimYAML is to define the type of a value in a heterogeneous collection node.
##
## The following additional APIs extend the basic high-level API:
##
## DOM API
## -------
##
## *Also exported by default, no import necessary*
##
## The `module yaml/dom`_ enables you to load YAML into `YamlNode`_ objects and
## dump those back into YAML. This gives you a structured view of your YAML
## stream. The DOM API provides the types and their handling, which can then
## be used via the loading & dumping API.
##
## You can use ``YamlNode`` objects inside other objects to hold subtrees of
## the input YAML, or you can load the whole YAML into a ``YamlNode``.
##
## ``YamlNode`` corresponds to the **Representation (Node Graph)** stage
## defined in the
## `YAML specification <https://yaml.org/spec/1.2.2/#31-processes>`_.
##
## Style API
## ---------
##
## .. code-block::
##
##   # needs explicit import to use:
##   import yaml/style
##
## The `module yaml/style`_ lets you define the preferred YAML node style of
## your objects and fields, giving you a greater control over how your
## generated YAML looks.
##
## JSON API
## --------
##
## .. code-block::
##
##   # needs explicit import to use:
##   import yaml/tojson
##
## The `module yaml/tojson`_ enables you to load YAML input into the stdlib's
## ``JsonNode`` structure. This can be useful for other libraries that expect
## JSON input. Mind that the loading & dumping API is able to read & write
## JSON files (since YAML  is a superset of JSON), you don't need the JSON
## API for that.
##
##
## Low Level Event Handling
## ========================
##
## NimYAML exposes lower-level APIs that allow you to access the different
## steps used for YAML loading & dumping. These APIs have at their core a
## `YamlStream`_ which is an object that supplies a stream of `Event`_.
## This corresponds to the **Serialization (Event Tree)** stage defined in the
## `YAML specification <https://yaml.org/spec/1.2.2/#31-processes>`_.
##
## Parsing & Presenting API
## ------------------------
##
## .. code-block::
##
##   # needs explicit import to use:
##   import yaml / [parser, presenter, stream, data]
##
## Provides `parse`_, a proc that feeds a ``YamlStream`` from YAML input,
## and `present`_, which consumes a ``YamlStream`` and writes out YAML. 
## You can use a `BufferYamlStream`_ to supply manually generated events.
##
## Native API
## ----------
##
## .. code-block::
##
##   # needs explicit import to use:
##   import yaml/native
##
## This part of the API takes care of generating Nim values from a
## ``YamlStream`` via `construct`_, and transforming them back into a
## ``YamlStream`` via `represent`_. This complements the Event API.
##
## Typically, you'd only access this API when defining custom constructors
## and representers.
##
##
## Hints API
## ---------
##
## .. code-block::
##
##   # needs explicit import to use:
##   import yaml/hints
##
## Provides type guessing, i.e. figuring out which type would be appropriate
## for a certain YAML scalar.

# top level API
import yaml / [annotations, loading, dumping, taglib]
export annotations, loading, dumping, taglib

when not defined(gcArc) or defined(gcOrc):
  # YAML DOM may contain cycles and therefore will leak memory if used with
  # ARC but without ORC. In that case it won't be available.
  import yaml/dom
  export dom
