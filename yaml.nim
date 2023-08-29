#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015-2023 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## This is the parent module of NimYAML, a package that provides facilities to
## generate and interpret `YAML <http://yaml.org>`_ character streams. Importing
## this package will import NimYAML's high level loading & dumping API.
## Additional APIs must be imported explicitly.
##
## There is no code in this package, all functionality is available from the
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
##   import yaml / [loading, dumping, annotations]
##
## Enables you to load YAML data directly into native Nim types and reversely
## dump native Nim types into YAML documents. This API corresponds to the full
## **Load** / **Dump** process as defined in the
## `YAML specification <https://yaml.org/spec/1.2.2/#31-processes>`_.
##
## The following additional APIs extend the basic high-level API:
##
## DOM API
## -------
##
## .. code-block::
##
##   import yaml / [loading, dumping, dom]
##
## Enables you to load YAML into ``YamlNode`` objects and dump those back into
## YAML. This gives you a structured view of your YAML stream. The DOM API
## provides the types and their handling, which can then be used via the
## loading & dumping API.
##
## You can use ``YamlNode`` objects inside other objects to hold subtrees of
## the input YAML, or you can load the whole YAML into a ``YamlNode``.
##
## ``YamlNode`` corresponds to the **Representation (Node Graph)** stage
## defined in the
## `YAML specification <https://yaml.org/spec/1.2.2/#31-processes>`_.
##
## JSON API
## --------
##
## .. code-block::
##
##   import yaml/tojson
##
## Enables you to load YAML input into the stdlib's ``JsonNode`` structure.
## This can be useful for other libraries that expect JSON input. Note that
## the loading & dumping API is able to read & write JSON files, you don't need
## the JSON API for that.
##
## Taglib API
## ----------
##
## .. code-block::
##
##   import yaml/taglib
##
## This API allows you to customize the YAML tags used for the Nim types you're
## serializing. The primary usage for tags in the context of NimYAML is to
## define the type of a value in a heterogeneous collection node.
##
## Low Level Event Handling
## ========================
##
## NimYAML exposes lower-level APIs that allow you to access the different
## steps used for YAML loading & dumping. These APIs have at their core a
## ``YamlStream`` which is an object that supplies ``Event``s. This corresponds
## to the **Serialization (Event Tree)** stage defined in the
## `YAML specification <https://yaml.org/spec/1.2.2/#31-processes>`_.
##
## Parsing & Presenting API
## ------------------------
##
## .. code-block::
##
##   import yaml / [parser, presenter, stream, data]
##
## Provides ``parse``, a proc that feeds a ``YamlStream`` from YAML input,
## and ``present``, which consumes a ``YamlStream`` and writes out YAML. 
## You can use a ``BufferYamlStream`` to supply manually generated events.
##
## Native API
## ----------
##
## .. code-block::
##
##   import yaml/native
##
## This part of the API takes care of generating Nim values from a
## ``YamlStream`` via ``construct``, and transforming them back into a
## ``YamlStream`` via ``represent``. This complements the Event API.
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
