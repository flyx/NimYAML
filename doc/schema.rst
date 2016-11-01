====================
Serialization Schema
====================

This document details the existing mappings in NimYAML from Nim types to YAML
tags. Throughout this document, there are two *tag shorthands* being used:

========= =========================
Shorthand Expansion
========= =========================
``!!``    ``tag:yaml.org,2002:``
``!n!``   ``tag:nimyaml.org,2016:``
========= =========================

The first one is defined by the YAML specification and is used for types from
the YAML failsafe, JSON or core schema. The second one is defined by NimYAML and
is used for types from the Nim standard library.

The YAML tag system has no understanding of generics. This means that NimYAML
must map every generic type instance to a YAML tag that describes that exact
type instance. For example, a ``seq[string]`` is mapped to the tag
``!n!system:seq(tag:yaml.org;2002:string)``.

As you can see, the expanded tag handle of the generic type parameter is added
to the tag of the generic type. To be compliant with the YAML spec, the
following modifications are made:

* Any exclamation marks are removed from the expanded tag. An exclamation mark
  may only occur at the beginning of the tag as defined by the YAML spec.
* Any commas are replaces by semicolons, because they may not occur in a tag
  apart from within the tag handle expansion.

If a type takes multiple generic parameters, the tag handles are separated by
semicolons within the parentheses. Note that this does not guarantee unique tag
handles for every type, but it is currently seen as good enough.

Note that user-defined generic types are currently not officially supported by
NimYAML. Only the generic collection types explicitly listed here use this
mechanism for crafting YAML tags.

Scalar Types
============

The following table defines all non-composed, atomar types that are mapped to
YAML types by NimYAML.

========= ===========================================================
Nim type  YAML tag
========= ===========================================================
char      ``!n!system:char``
string    ``!!string`` (or ``!n!nil:string`` if nil)
int       ``!n!system:int32`` (independent on target architecture)
int8      ``!n!system:int8``
int16     ``!n!system:int16``
int32     ``!n!system:int32``
int64     ``!n!system:int64``
uint      ``!n!system:uint32`` (independent from target architecture)
uint8     ``!n!system:uint8``
uint16    ``!n!system:uint16``
uint32    ``!n!system:uint32``
uint64    ``!n!system:uint64``
float     ``!n!system:float64``
float32   ``!n!system:float32``
float64   ``!n!system:float64``
bool      ``!!bool``
========= ===========================================================

Apart from these standard library types, NimYAML also supports all enum types
as scalar types. They will be serialized to their string representation.

Apart from the types listed here and enum tyes, no atomar types are supported.

Collection Types
================

Collection types in Nim are typically generic. As such, they take their
contained types as parameters inside parentheses as explained above. The
following types are supported:

============ ============================================================ ================================
Nim type     YAML tag                                                     YAML structure
============ ============================================================ ================================
array        ``!n!system:array(?;?)`` (first parameter like ``0..5``)     sequence
seq          ``!n!system:seq(?)`` (or ``!n!nil:seq`` if nil)              sequence
set          ``!n!system:set(?)``                                         sequence
Table        ``!n!tables:Table(?;?)``                                     mapping
OrderedTable ``!n!tables:OrderedTable(?;?)``                              sequence of single-pair mappings
============ ============================================================ ================================

Standard YAML Types
===================

NimYAML does not support all types defined in the YAML specification, **not even
those of the failsafe schema**. The reason is that the failsafe schema is
designed for dynamic type systems where a sequence can contain arbitrarily typed
values. This is not fully translatable into a static type system. NimYAML does
support some mechanisms to make working with heterogeneous collection structures
easier, see `Serialization Overview <serialization.html>`_.

Note that because the specification only defines that an implementation *should*
implement the failsafe schema, NimYAML is still compliant; it has valid reasons
not to implement the schema.

This is a full list of all types defined in the YAML specification or the
`YAML type registry <http://www.yaml.org/type/>`_. It gives an overview of which
types are supported by NimYAML, which may be supported in the future and which
will never be supported.

=============== ============================================
YAML type       Status
=============== ============================================
``!!map``       Cannot be supported
``!!omap``      Cannot be supported
``!!pairs``     Cannot be supported
``!!set``       Cannot be supported
``!!seq``       Cannot be supported
``!!binary``    Currently not supported
``!!bool``      Maps to Nim's ``bool`` type
``!!float``     Not supported (user can choose)
``!!int``       Not supported (user can choose)
``!!merge``     Not supported and unlikely to be implemented
``!!null``      Used for reference types that are ``nil``
``!!str``       Maps to Nim's ``string`` type
``!!timestamp`` Currently not supported
``!!value``     Not supported and unlikely to be implemented
``!!yaml``      Not supported and unlikely to be implemented
=============== ============================================

``!!int`` and ``!!float`` are not supported out of the box to let the user
choose where to map them (for example, ``!!int`` may map to ``int32`` or
``int64``, or the the generic ``int`` whose size is platform-dependent). If one
wants to use ``!!int``or ``!!float``, the process is to create a ``distinct``
type derived from the desired base type and then set its tag using
``setTagUri``.

``!!merge`` and ``!!value`` are not supported because the semantics of these
types would make a multi-pass loading process necessary and if one takes the
tag system seriously, ``!!merge`` can only be used with YAML's collection types,
which, as explained above, cannot be supported.