========================
Migrating to NimYAML 2.x
========================

NimYAML 2.0.0 introduces some breaking changes, existing code likely needs to be updated.
This document details the changes and describes what needs to be done to migrate existing code.

Module Changes
==============

``import yaml`` now only imports the high-level API for loading and dumping.
You need to manually import lower-level APIs if you need them.

``yaml/serialization`` has been split into:

 * ``yaml/loading``, which provides ``load`` etc
 * ``yaml/dumping``, which provides ``dump`` etc
 * ``yaml/native``, which provides the lower level ``contstruct``, ``represent`` etc

All of these are imported automatically by doing ``import yaml``.

Dumping API
===========

NimYAML 2.0.0 introduces the new object ``Dumper``, which holds configuration for dumping values to YAML.
The dumping API must now be called on an instance of ``Dumper``.
The previous additional arguments to the ``dump`` proc are now part of ``Dumper``.

``yaml/dumping`` provides several procs that return common dumper presets.
These presets were previously the values of ``PresentationStyle``, which has been removed.

Example code for old API:

.. code-block:: nim
  var value = # some value
  var s = newFileStream("out.yaml", fmWrite)
  dump(value, s, tagStyle = tsAll, options = defineOptions(
    style = psCanonical, outputVersion = ov1_2)

Same code for new API:

.. code-block:: nim
  var value = # some value
  var s = newFileStream("out.yaml", fmWrite)
  var dumper = canonicalDumper()
  dumper.presentation.outputVersion = ov1_2
  dumper.dump(value, s)

The previous ``PresentationOptions`` now live in ``dumper.presentation``.
There are also ``SeralizationOptions`` in ``dumper.serialization``.
A preset sets values for both option objects.
You can modify the options afterwards to your liking.

The new API makes use of Nim 2 default values for object fields.
Hence ``defineOptions`` is gone, you can simply use the constructor of ``PresentationOptions``.

Changes to Default Output Style
===============================

Previously, the default output style included

.. code-block:: yaml
  %YAML 1.2
  %TAG !n! tag:nimyaml.org,2016:
  ---

All of this is gone. By default, ``---`` is only emitted if the root node has an anchor or tag.
You can emit the ``%YAML`` directive by setting ``outputVersion`` (see above).
You can emit the ``%TAG`` directive via

.. code-block:: nim
  dumper.serialization.handles = initNimYamlTagHandle()

Previously, the root node had a YAML tag. Now, the tag isn't emitted anymore by default.
You can enable it via

.. code-block:: nim
  dumper.serialization.tagStyle = tsRootOnly

Changes to the ``construct`` and ``represent`` procs
====================================================

This mainly concerns custom constructors and representers.
The required signature of ``constructObject`` and ``representObject`` procs changed.

Old signatures:

.. code-block:: nim
  proc constructObject*(
    s: var YamlStream,
    c: ConstructionContext,
    result: var MyObject,
  ) {.raises: [YamlConstructionError, YamlStreamError].}

  proc representObject*(
    value: MyObject,
    ts   : TagStyle,
    c    : SerializationContext,
    tag  : TagId,
  ): {.raises: [YamlSerializationError].}

New signatures:

.. code-block:: nim
  proc constructObject*(
    ctx   : var ConstructionContext,
    result: var MyObject,
  ) {.raises: [YamlConstructionError, YamlStreamError].}
  
  proc representObject*(
    ctx  : var SerializationContext,
    value: MyObject,
    tag  : TagId,
  ): {.raises: [YamlSerializationError].}

For ``constructObject``, the input ``YamlStream`` can now be found in ``ctx.input``.

