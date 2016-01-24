# This code is taken from https://github.com/nimlets/nimlets
# and has been slightly modified to fit our needs.

type
  yaml_version_directive_t* = object
    major*: cint
    minor*: cint
type
  yaml_tag_directive_t* = object
    handle*: cstring
    prefix*: cstring
type
  yaml_encoding_t* {.size: sizeof(cint).} = enum
    YAML_ANY_ENCODING,
    YAML_UTF8_ENCODING,
    YAML_UTF16LE_ENCODING,
    YAML_UTF16BE_ENCODING
type
  yaml_break_t* {.size: sizeof(cint).} = enum
    YAML_ANY_BREAK,
    YAML_CR_BREAK,
    YAML_LN_BREAK,
    YAML_CRLN_BREAK
type
  yaml_error_type_t* {.size: sizeof(cint).} = enum
    YAML_NO_ERROR,
    YAML_MEMORY_ERROR,
    YAML_READER_ERROR,
    YAML_SCANNER_ERROR,
    YAML_PARSER_ERROR,
    YAML_COMPOSER_ERROR,
    YAML_WRITER_ERROR,
    YAML_EMITTER_ERROR
type
  yaml_mark_t* = object
    index*: csize
    line*: csize
    column*: csize
type
  yaml_scalar_style_t* {.size: sizeof(cint).} = enum
    YAML_ANY_SCALAR_STYLE,
    YAML_PLAIN_SCALAR_STYLE,
    YAML_SINGLE_QUOTED_SCALAR_STYLE,
    YAML_DOUBLE_QUOTED_SCALAR_STYLE,
    YAML_LITERAL_SCALAR_STYLE,
    YAML_FOLDED_SCALAR_STYLE
type
  yaml_sequence_style_t* {.size: sizeof(cint).} = enum
    YAML_ANY_SEQUENCE_STYLE,
    YAML_BLOCK_SEQUENCE_STYLE,
    YAML_FLOW_SEQUENCE_STYLE
type
  yaml_mapping_style_t* {.size: sizeof(cint).} = enum
    YAML_ANY_MAPPING_STYLE,
    YAML_BLOCK_MAPPING_STYLE,
    YAML_FLOW_MAPPING_STYLE
type
  yaml_token_type_t* {.size: sizeof(cint).} = enum
    YAML_NO_TOKEN,
    YAML_STREAM_START_TOKEN,
    YAML_STREAM_END_TOKEN,
    YAML_VERSION_DIRECTIVE_TOKEN,
    YAML_TAG_DIRECTIVE_TOKEN,
    YAML_DOCUMENT_START_TOKEN,
    YAML_DOCUMENT_END_TOKEN,
    YAML_BLOCK_SEQUENCE_START_TOKEN,
    YAML_BLOCK_MAPPING_START_TOKEN,
    YAML_BLOCK_END_TOKEN,
    YAML_FLOW_SEQUENCE_START_TOKEN,
    YAML_FLOW_SEQUENCE_END_TOKEN,
    YAML_FLOW_MAPPING_START_TOKEN,
    YAML_FLOW_MAPPING_END_TOKEN,
    YAML_BLOCK_ENTRY_TOKEN,
    YAML_FLOW_ENTRY_TOKEN,
    YAML_KEY_TOKEN,
    YAML_VALUE_TOKEN,
    YAML_ALIAS_TOKEN,
    YAML_ANCHOR_TOKEN,
    YAML_TAG_TOKEN,
    YAML_SCALAR_TOKEN
type
  INNER_C_STRUCT_9581966235636552858* = object
    encoding*: yaml_encoding_t
  INNER_C_STRUCT_1221667129857401972* = object
    value*: cstring
  INNER_C_STRUCT_3317256698323717696* = object
    value*: cstring
  INNER_C_STRUCT_5441002398333014240* = object
    handle*: cstring
    suffix*: cstring
  INNER_C_STRUCT_7453632048426669727* = object
    value*: cstring
    length*: csize
    style*: yaml_scalar_style_t
  INNER_C_STRUCT_9783180209656813162* = object
    major*: cint
    minor*: cint
  INNER_C_STRUCT_13940099295483927389* = object
    handle*: cstring
    prefix*: cstring
  INNER_C_UNION_9404448031707501477* = object  {.union.}
    stream_start*: INNER_C_STRUCT_9581966235636552858
    alias*: INNER_C_STRUCT_1221667129857401972
    anchor*: INNER_C_STRUCT_3317256698323717696
    tag*: INNER_C_STRUCT_5441002398333014240
    scalar*: INNER_C_STRUCT_7453632048426669727
    version_directive*: INNER_C_STRUCT_9783180209656813162
    tag_directive*: INNER_C_STRUCT_13940099295483927389
  yaml_token_t* = object
    typ*: yaml_token_type_t
    data*: INNER_C_UNION_9404448031707501477
    start_mark*: yaml_mark_t
    end_mark*: yaml_mark_t
type
  yaml_event_type_t* {.size: sizeof(cint).} = enum
    YAML_NO_EVENT,
    YAML_STREAM_START_EVENT,
    YAML_STREAM_END_EVENT,
    YAML_DOCUMENT_START_EVENT,
    YAML_DOCUMENT_END_EVENT,
    YAML_ALIAS_EVENT,
    YAML_SCALAR_EVENT,
    YAML_SEQUENCE_START_EVENT,
    YAML_SEQUENCE_END_EVENT,
    YAML_MAPPING_START_EVENT,
    YAML_MAPPING_END_EVENT
type
  INNER_C_STRUCT_12590518896704616971* = object
    encoding*: yaml_encoding_t
  INNER_C_STRUCT_2667561393214118032* = object
    start*: ptr yaml_tag_directive_t
    endd*: ptr yaml_tag_directive_t
  INNER_C_STRUCT_8611624117794791642* = object
    version_directive*: ptr yaml_version_directive_t
    tag_directives*: INNER_C_STRUCT_2667561393214118032
    implicit*: cint
  INNER_C_STRUCT_6989068223488568623* = object
    implicit*: cint
  INNER_C_STRUCT_12004643997943399240* = object
    anchor*: cstring
  INNER_C_STRUCT_14974408632587267100* = object
    anchor*: cstring
    tag*: cstring
    value*: cstring
    length*: csize
    plain_implicit*: cint
    quoted_implicit*: cint
    style*: yaml_scalar_style_t
  INNER_C_STRUCT_17970865806594553108* = object
    anchor*: cstring
    tag*: cstring
    implicit*: cint
    style*: yaml_sequence_style_t
  INNER_C_STRUCT_1674767092908407322* = object
    anchor*: cstring
    tag*: cstring
    implicit*: cint
    style*: yaml_mapping_style_t
  INNER_C_UNION_14299011587659785980* = object  {.union.}
    stream_start*: INNER_C_STRUCT_12590518896704616971
    document_start*: INNER_C_STRUCT_8611624117794791642
    document_endd*: INNER_C_STRUCT_6989068223488568623
    alias*: INNER_C_STRUCT_12004643997943399240
    scalar*: INNER_C_STRUCT_14974408632587267100
    sequence_start*: INNER_C_STRUCT_17970865806594553108
    mapping_start*: INNER_C_STRUCT_1674767092908407322
  yaml_event_t* = object
    typ*: yaml_event_type_t
    data*: INNER_C_UNION_14299011587659785980
    start_mark*: yaml_mark_t
    end_mark*: yaml_mark_t
const YAML_NULL_TAG* = "tag:yaml.org,2002:null"
const YAML_BOOL_TAG* = "tag:yaml.org,2002:bool"
const YAML_STR_TAG* = "tag:yaml.org,2002:str"
const YAML_INT_TAG* = "tag:yaml.org,2002:int"
const YAML_FLOAT_TAG* = "tag:yaml.org,2002:float"
const YAML_TIMESTAMP_TAG* = "tag:yaml.org,2002:timestamp"
const YAML_SEQ_TAG* = "tag:yaml.org,2002:seq"
const YAML_MAP_TAG* = "tag:yaml.org,2002:map"
const YAML_DEFAULT_SCALAR_TAG* = YAML_STR_TAG
const YAML_DEFAULT_SEQUENCE_TAG* = YAML_SEQ_TAG
const YAML_DEFAULT_MAPPING_TAG* = YAML_MAP_TAG
var YAML_VNULL_TAG* = "tag:yaml.org,2002:null"
var YAML_VBOOL_TAG* = "tag:yaml.org,2002:bool"
var YAML_VSTR_TAG* = "tag:yaml.org,2002:str"
var YAML_VINT_TAG* = "tag:yaml.org,2002:int"
var YAML_VFLOAT_TAG* = "tag:yaml.org,2002:float"
var YAML_VTIMESTAMP_TAG* = "tag:yaml.org,2002:timestamp"
var YAML_VSEQ_TAG* = "tag:yaml.org,2002:seq"
var YAML_VMAP_TAG* = "tag:yaml.org,2002:map"
var YAML_VDEFAULT_SCALAR_TAG* = YAML_STR_TAG
var YAML_VDEFAULT_SEQUENCE_TAG* = YAML_SEQ_TAG
var YAML_VDEFAULT_MAPPING_TAG* = YAML_MAP_TAG
type
  yaml_node_type_t* {.size: sizeof(cint).} = enum
    YAML_NO_NODE,
    YAML_SCALAR_NODE,
    YAML_SEQUENCE_NODE,
    YAML_MAPPING_NODE
  yaml_node_t* = yaml_node_s
  yaml_node_item_t* = cint
  yaml_node_pair_t* = object
    key*: cint
    value*: cint
  INNER_C_STRUCT_2771607800107246221* = object
    value*: cstring
    length*: csize
    style*: yaml_scalar_style_t
  INNER_C_STRUCT_16176656515014249903* = object
    start*: ptr yaml_node_item_t
    endd*: ptr yaml_node_item_t
    top*: ptr yaml_node_item_t
  INNER_C_STRUCT_17512274596170441087* = object
    items*: INNER_C_STRUCT_16176656515014249903
    style*: yaml_sequence_style_t
  INNER_C_STRUCT_6534273983681155882* = object
    start*: ptr yaml_node_pair_t
    endd*: ptr yaml_node_pair_t
    top*: ptr yaml_node_pair_t
  INNER_C_STRUCT_11518003446976276318* = object
    pairs*: INNER_C_STRUCT_6534273983681155882
    style*: yaml_mapping_style_t
  INNER_C_UNION_9402779093446787060* = object  {.union.}
    scalar*: INNER_C_STRUCT_2771607800107246221
    sequence*: INNER_C_STRUCT_17512274596170441087
    mapping*: INNER_C_STRUCT_11518003446976276318
  yaml_node_s* = object
    typ*: yaml_node_type_t
    tag*: cstring
    data*: INNER_C_UNION_9402779093446787060
    start_mark*: yaml_mark_t
    end_mark*: yaml_mark_t
type
  INNER_C_STRUCT_2411546260517137131* = object
    start*: ptr yaml_node_t
    endd*: ptr yaml_node_t
    top*: ptr yaml_node_t
  INNER_C_STRUCT_4991458144178661981* = object
    start*: ptr yaml_tag_directive_t
    endd*: ptr yaml_tag_directive_t
  yaml_document_t* = object
    nodes*: INNER_C_STRUCT_2411546260517137131
    version_directive*: ptr yaml_version_directive_t
    tag_directives*: INNER_C_STRUCT_4991458144178661981
    start_implicit*: cint
    end_implicit*: cint
    start_mark*: yaml_mark_t
    end_mark*: yaml_mark_t
type
  yaml_read_handler_t* = proc (data: pointer; buffer: cstring; size: csize;
                               size_read: ptr csize): cint
type
  yaml_simple_key_t* = object
    possible*: cint
    required*: cint
    token_number*: csize
    mark*: yaml_mark_t
type
  yaml_parser_state_t* {.size: sizeof(cint).} = enum
    YAML_PARSE_STREAM_START_STATE,
    YAML_PARSE_IMPLICIT_DOCUMENT_START_STATE,
    YAML_PARSE_DOCUMENT_START_STATE,
    YAML_PARSE_DOCUMENT_CONTENT_STATE,
    YAML_PARSE_DOCUMENT_END_STATE,
    YAML_PARSE_BLOCK_NODE_STATE,
    YAML_PARSE_BLOCK_NODE_OR_INDENTLESS_SEQUENCE_STATE,
    YAML_PARSE_FLOW_NODE_STATE,
    YAML_PARSE_BLOCK_SEQUENCE_FIRST_ENTRY_STATE,
    YAML_PARSE_BLOCK_SEQUENCE_ENTRY_STATE,
    YAML_PARSE_INDENTLESS_SEQUENCE_ENTRY_STATE,
    YAML_PARSE_BLOCK_MAPPING_FIRST_KEY_STATE,
    YAML_PARSE_BLOCK_MAPPING_KEY_STATE,
    YAML_PARSE_BLOCK_MAPPING_VALUE_STATE,
    YAML_PARSE_FLOW_SEQUENCE_FIRST_ENTRY_STATE,
    YAML_PARSE_FLOW_SEQUENCE_ENTRY_STATE,
    YAML_PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_KEY_STATE,
    YAML_PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_VALUE_STATE,
    YAML_PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_END_STATE,
    YAML_PARSE_FLOW_MAPPING_FIRST_KEY_STATE,
    YAML_PARSE_FLOW_MAPPING_KEY_STATE,
    YAML_PARSE_FLOW_MAPPING_VALUE_STATE,
    YAML_PARSE_FLOW_MAPPING_EMPTY_VALUE_STATE,
    YAML_PARSE_END_STATE
type
  yaml_alias_data_t* = object
    anchor*: cstring
    index*: cint
    mark*: yaml_mark_t
type
  INNER_C_STRUCT_16371464751651700497* = object
    start*: cstring
    endd*: cstring
    current*: cstring
  INNER_C_UNION_14844535658673536178* = object  {.union.}
    string*: INNER_C_STRUCT_16371464751651700497
    file*: ptr FILE
  INNER_C_STRUCT_5449995434778144246* = object
    start*: cstring
    endd*: cstring
    pointer*: cstring
    last*: cstring
  INNER_C_STRUCT_1533468219873624615* = object
    start*: cstring
    endd*: cstring
    pointer*: cstring
    last*: cstring
  INNER_C_STRUCT_12302340786945222376* = object
    start*: ptr yaml_token_t
    endd*: ptr yaml_token_t
    head*: ptr yaml_token_t
    tail*: ptr yaml_token_t
  INNER_C_STRUCT_6311148685867902540* = object
    start*: ptr cint
    endd*: ptr cint
    top*: ptr cint
  INNER_C_STRUCT_6741121270717550011* = object
    start*: ptr yaml_simple_key_t
    endd*: ptr yaml_simple_key_t
    top*: ptr yaml_simple_key_t
  INNER_C_STRUCT_14987939425048783309* = object
    start*: ptr yaml_parser_state_t
    endd*: ptr yaml_parser_state_t
    top*: ptr yaml_parser_state_t
  INNER_C_STRUCT_11595967245106118857* = object
    start*: ptr yaml_mark_t
    endd*: ptr yaml_mark_t
    top*: ptr yaml_mark_t
  INNER_C_STRUCT_426684507395569091* = object
    start*: ptr yaml_tag_directive_t
    endd*: ptr yaml_tag_directive_t
    top*: ptr yaml_tag_directive_t
  INNER_C_STRUCT_7828170433486051057* = object
    start*: ptr yaml_alias_data_t
    endd*: ptr yaml_alias_data_t
    top*: ptr yaml_alias_data_t
  yaml_parser_t* = object
    error*: yaml_error_type_t
    problem*: cstring
    problem_offset*: csize
    problem_value*: cint
    problem_mark*: yaml_mark_t
    context*: cstring
    context_mark*: yaml_mark_t
    read_handler*: ptr yaml_read_handler_t
    read_handler_data*: pointer
    input*: INNER_C_UNION_14844535658673536178
    eof*: cint
    buffer*: INNER_C_STRUCT_5449995434778144246
    unread*: csize
    raw_buffer*: INNER_C_STRUCT_1533468219873624615
    encoding*: yaml_encoding_t
    offset*: csize
    mark*: yaml_mark_t
    stream_start_produced*: cint
    stream_end_produced*: cint
    flow_level*: cint
    tokens*: INNER_C_STRUCT_12302340786945222376
    tokens_parsed*: csize
    token_available*: cint
    indents*: INNER_C_STRUCT_6311148685867902540
    indent*: cint
    simple_key_allowed*: cint
    simple_keys*: INNER_C_STRUCT_6741121270717550011
    states*: INNER_C_STRUCT_14987939425048783309
    state*: yaml_parser_state_t
    marks*: INNER_C_STRUCT_11595967245106118857
    tag_directives*: INNER_C_STRUCT_426684507395569091
    aliases*: INNER_C_STRUCT_7828170433486051057
    document*: ptr yaml_document_t
type
  yaml_write_handler_t* = proc (data: pointer; buffer: cstring; size: csize): cint
type
  yaml_emitter_state_t* {.size: sizeof(cint).} = enum
    YAML_EMIT_STREAM_START_STATE,
    YAML_EMIT_FIRST_DOCUMENT_START_STATE,
    YAML_EMIT_DOCUMENT_START_STATE,
    YAML_EMIT_DOCUMENT_CONTENT_STATE,
    YAML_EMIT_DOCUMENT_END_STATE,
    YAML_EMIT_FLOW_SEQUENCE_FIRST_ITEM_STATE,
    YAML_EMIT_FLOW_SEQUENCE_ITEM_STATE,
    YAML_EMIT_FLOW_MAPPING_FIRST_KEY_STATE,
    YAML_EMIT_FLOW_MAPPING_KEY_STATE,
    YAML_EMIT_FLOW_MAPPING_SIMPLE_VALUE_STATE,
    YAML_EMIT_FLOW_MAPPING_VALUE_STATE,
    YAML_EMIT_BLOCK_SEQUENCE_FIRST_ITEM_STATE,
    YAML_EMIT_BLOCK_SEQUENCE_ITEM_STATE,
    YAML_EMIT_BLOCK_MAPPING_FIRST_KEY_STATE,
    YAML_EMIT_BLOCK_MAPPING_KEY_STATE,
    YAML_EMIT_BLOCK_MAPPING_SIMPLE_VALUE_STATE,
    YAML_EMIT_BLOCK_MAPPING_VALUE_STATE,
    YAML_EMIT_END_STATE
type
  INNER_C_STRUCT_12749614999235445465* = object
    buffer*: cstring
    size*: csize
    size_written*: ptr csize
  INNER_C_UNION_12199099344959672631* = object  {.union.}
    string*: INNER_C_STRUCT_12749614999235445465
    file*: ptr FILE
  INNER_C_STRUCT_12563198298657885016* = object
    start*: cstring
    endd*: cstring
    pointer*: cstring
    last*: cstring
  INNER_C_STRUCT_2333930655588273530* = object
    start*: cstring
    endd*: cstring
    pointer*: cstring
    last*: cstring
  INNER_C_STRUCT_3757196451896818589* = object
    start*: ptr yaml_emitter_state_t
    endd*: ptr yaml_emitter_state_t
    top*: ptr yaml_emitter_state_t
  INNER_C_STRUCT_394143963162845597* = object
    start*: ptr yaml_event_t
    endd*: ptr yaml_event_t
    head*: ptr yaml_event_t
    tail*: ptr yaml_event_t
  INNER_C_STRUCT_16850922517203281724* = object
    start*: ptr cint
    endd*: ptr cint
    top*: ptr cint
  INNER_C_STRUCT_12260090914027529514* = object
    start*: ptr yaml_tag_directive_t
    endd*: ptr yaml_tag_directive_t
    top*: ptr yaml_tag_directive_t
  INNER_C_STRUCT_1556210231363541236* = object
    anchor*: cstring
    anchor_length*: csize
    alias*: cint
  INNER_C_STRUCT_17739845129940504956* = object
    handle*: cstring
    handle_length*: csize
    suffix*: cstring
    suffix_length*: csize
  INNER_C_STRUCT_2932767511639488752* = object
    value*: cstring
    length*: csize
    multiline*: cint
    flow_plain_allowed*: cint
    block_plain_allowed*: cint
    single_quoted_allowed*: cint
    block_allowed*: cint
    style*: yaml_scalar_style_t
  INNER_C_STRUCT_11864533033166503222* = object
    references*: cint
    anchor*: cint
    serialized*: cint
  yaml_emitter_t* = object
    error*: yaml_error_type_t
    problem*: cstring
    write_handler*: ptr yaml_write_handler_t
    write_handler_data*: pointer
    output*: INNER_C_UNION_12199099344959672631
    buffer*: INNER_C_STRUCT_12563198298657885016
    raw_buffer*: INNER_C_STRUCT_2333930655588273530
    encoding*: yaml_encoding_t
    canonical*: cint
    best_indent*: cint
    best_width*: cint
    unicode*: cint
    line_break*: yaml_break_t
    states*: INNER_C_STRUCT_3757196451896818589
    state*: yaml_emitter_state_t
    events*: INNER_C_STRUCT_394143963162845597
    indents*: INNER_C_STRUCT_16850922517203281724
    tag_directives*: INNER_C_STRUCT_12260090914027529514
    indent*: cint
    flow_level*: cint
    root_context*: cint
    sequence_context*: cint
    mapping_context*: cint
    simple_key_context*: cint
    line*: cint
    column*: cint
    whitespace*: cint
    indention*: cint
    open_ended*: cint
    anchor_data*: INNER_C_STRUCT_1556210231363541236
    tag_data*: INNER_C_STRUCT_17739845129940504956
    scalar_data*: INNER_C_STRUCT_2932767511639488752
    opened*: cint
    closed*: cint
    anchors*: ptr INNER_C_STRUCT_11864533033166503222
    last_anchor_id*: cint
    document*: ptr yaml_document_t

{.push importc, cdecl.}
proc yaml_get_version_string*(): cstring
proc yaml_get_version*(major: ptr cint; minor: ptr cint; patch: ptr cint)
proc yaml_token_delete*(token: ptr yaml_token_t)
proc yaml_stream_start_event_initialize*(event: ptr yaml_event_t;
    encoding: yaml_encoding_t): cint
proc yaml_stream_end_event_initialize*(event: ptr yaml_event_t): cint
proc yaml_document_start_event_initialize*(event: ptr yaml_event_t;
    version_directive: ptr yaml_version_directive_t;
    tag_directives_start: ptr yaml_tag_directive_t;
    tag_directives_end: ptr yaml_tag_directive_t; implicit: cint): cint
proc yaml_document_end_event_initialize*(event: ptr yaml_event_t; implicit: cint): cint
proc yaml_alias_event_initialize*(event: ptr yaml_event_t;
                                  anchor: cstring): cint
proc yaml_scalar_event_initialize*(event: ptr yaml_event_t;
                                   anchor: cstring;
                                   tag: cstring; value: cstring;
                                   length: cint; plain_implicit: cint;
                                   quoted_implicit: cint;
                                   style: yaml_scalar_style_t): cint
proc yaml_sequence_start_event_initialize*(event: ptr yaml_event_t;
    anchor: cstring; tag: cstring; implicit: cint;
    style: yaml_sequence_style_t): cint
proc yaml_sequence_end_event_initialize*(event: ptr yaml_event_t): cint
proc yaml_mapping_start_event_initialize*(event: ptr yaml_event_t;
    anchor: cstring; tag: cstring; implicit: cint;
    style: yaml_mapping_style_t): cint
proc yaml_mapping_end_event_initialize*(event: ptr yaml_event_t): cint
proc yaml_event_delete*(event: ptr yaml_event_t)
proc yaml_document_initialize*(document: ptr yaml_document_t;
                               version_directive: ptr yaml_version_directive_t;
                               tag_directives_start: ptr yaml_tag_directive_t;
                               tag_directives_end: ptr yaml_tag_directive_t;
                               start_implicit: cint; end_implicit: cint): cint
proc yaml_document_delete*(document: ptr yaml_document_t)
proc yaml_document_get_node*(document: ptr yaml_document_t; index: cint): ptr yaml_node_t
proc yaml_document_get_root_node*(document: ptr yaml_document_t): ptr yaml_node_t
proc yaml_document_add_scalar*(document: ptr yaml_document_t;
                               tag: cstring; value: cstring;
                               length: cint; style: yaml_scalar_style_t): cint
proc yaml_document_add_sequence*(document: ptr yaml_document_t;
                                 tag: cstring;
                                 style: yaml_sequence_style_t): cint
proc yaml_document_add_mapping*(document: ptr yaml_document_t;
                                tag: cstring;
                                style: yaml_mapping_style_t): cint
proc yaml_document_append_sequence_item*(document: ptr yaml_document_t;
    sequence: cint; item: cint): cint
proc yaml_document_append_mapping_pair*(document: ptr yaml_document_t;
                                        mapping: cint; key: cint; value: cint): cint
proc yaml_parser_initialize*(parser: ptr yaml_parser_t): cint
proc yaml_parser_delete*(parser: ptr yaml_parser_t)
proc yaml_parser_set_input_string*(parser: ptr yaml_parser_t; input: cstring;
                                   size: csize)
proc yaml_parser_set_input_file*(parser: ptr yaml_parser_t; file: ptr FILE)
proc yaml_parser_set_input*(parser: ptr yaml_parser_t;
                            handler: ptr yaml_read_handler_t; data: pointer)
proc yaml_parser_set_encoding*(parser: ptr yaml_parser_t;
                               encoding: yaml_encoding_t)
proc yaml_parser_scan*(parser: ptr yaml_parser_t; token: ptr yaml_token_t): cint
proc yaml_parser_parse*(parser: ptr yaml_parser_t; event: ptr yaml_event_t): cint
proc yaml_parser_load*(parser: ptr yaml_parser_t; document: ptr yaml_document_t): cint
proc yaml_emitter_initialize*(emitter: ptr yaml_emitter_t): cint
proc yaml_emitter_delete*(emitter: ptr yaml_emitter_t)
proc yaml_emitter_set_output_string*(emitter: ptr yaml_emitter_t;
                                     output: cstring; size: csize;
                                     size_written: ptr csize)
proc yaml_emitter_set_output_file*(emitter: ptr yaml_emitter_t; file: ptr FILE)
proc yaml_emitter_set_output*(emitter: ptr yaml_emitter_t;
                              handler: ptr yaml_write_handler_t; data: pointer)
proc yaml_emitter_set_encoding*(emitter: ptr yaml_emitter_t;
                                encoding: yaml_encoding_t)
proc yaml_emitter_set_canonical*(emitter: ptr yaml_emitter_t; canonical: cint)
proc yaml_emitter_set_indent*(emitter: ptr yaml_emitter_t; indent: cint)
proc yaml_emitter_set_width*(emitter: ptr yaml_emitter_t; width: cint)
proc yaml_emitter_set_unicode*(emitter: ptr yaml_emitter_t; unicode: cint)
proc yaml_emitter_set_break*(emitter: ptr yaml_emitter_t;
                             line_break: yaml_break_t)
proc yaml_emitter_emit*(emitter: ptr yaml_emitter_t; event: ptr yaml_event_t): cint
proc yaml_emitter_open*(emitter: ptr yaml_emitter_t): cint
proc yaml_emitter_close*(emitter: ptr yaml_emitter_t): cint
proc yaml_emitter_dump*(emitter: ptr yaml_emitter_t;
                        document: ptr yaml_document_t): cint
proc yaml_emitter_flush*(emitter: ptr yaml_emitter_t): cint
{.pop.}

when system.hostOS == "linux":
  {.link: "/usr/lib/x86_64-linux-gnu/libyaml-0.so.2".}
elif system.hostOS == "macosx":
  {.link: "/Users/flyx/.nix-profile/lib/libyaml-0.2.dylib"}