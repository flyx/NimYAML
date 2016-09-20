#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

import hashes

type
  TagId* = distinct int ## \
    ## A ``TagId`` identifies a tag URI, like for example
    ## ``"tag:yaml.org,2002:str"``. The URI corresponding to a ``TagId`` can
    ## be queried from the `TagLibrary <#TagLibrary>`_ which was
    ## used to create this ``TagId``; e.g. when you parse a YAML character
    ## stream, the ``TagLibrary`` of the parser is the one which generates
    ## the resulting ``TagId`` s.
    ##
    ## URI strings are mapped to ``TagId`` s for efficiency  reasons (you
    ## do not need to compare strings every time) and to be able to
    ## discover unknown tag URIs early in the parsing process.

  AnchorId* = distinct int ## \
    ## An ``AnchorId`` identifies an anchor in the current document. It
    ## becomes invalid as soon as the current document scope is invalidated
    ## (for example, because the parser yielded a ``yamlEndDocument``
    ## event). ``AnchorId`` s exists because of efficiency, much like
    ## ``TagId`` s. The actual anchor name is a presentation detail and
    ## cannot be queried by the user.

proc `==`*(left, right: TagId): bool {.borrow.}
proc hash*(id: TagId): Hash {.borrow.}

proc `==`*(left, right: AnchorId): bool {.borrow.}
proc `$`*(id: AnchorId): string {.borrow.}
proc hash*(id: AnchorId): Hash {.borrow.}
