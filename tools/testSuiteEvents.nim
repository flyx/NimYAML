import ../yaml/stream, ../yaml/parser, ../yaml/taglib, streams

var
  tags = initExtendedTagLibrary()
  p = newYamlParser(tags)
  events = p.parse(newFileStream(stdin))

proc start(name: string, tag: TagId, anchor: AnchorId, finish: bool = true) =
  stdout.write(name)
  if tag != yTagQuestionMark: stdout.write(" <" & tags.uri(tag) & ">")
  if anchor != yAnchorNone: stdout.write(" &" & p.anchorName(anchor))
  if finish: stdout.write("\n")

proc writeEscaped(str: string) =
  for c in str:
    case c
    of '\\': stdout.write("\\\\")
    of '\l': stdout.write("\\n")
    of '\r': stdout.write("\\r")
    of '\0': stdout.write("\\0")
    of '\b': stdout.write("\\b")
    of '\t': stdout.write("\\t")
    else: stdout.write(c)

stdout.write("+STR\n")
while not(events.finished()):
  let cur = events.next()
  case cur.kind
  of yamlStartDoc: stdout.write("+DOC\n")
  of yamlStartMap: start("+MAP", cur.mapTag, cur.mapAnchor)
  of yamlStartSeq: start("+SEQ", cur.seqTag, cur.seqAnchor)
  of yamlEndMap: stdout.write("-MAP\n")
  of yamlEndSeq: stdout.write("-SEQ\n")
  of yamlEndDoc: stdout.write("-DOC\n")
  of yamlScalar:
    var
      isQuoted = false
      tag = cur.scalartag
    if cur.scalarTag == yTagExclamationMark:
      isQuoted = true
      tag = yTagQuestionMark
    start("=VAL", tag, cur.scalarAnchor, false)
    if isQuoted: stdout.write(" \"")
    else: stdout.write(" :")
    writeEscaped(cur.scalarContent)
    stdout.write("\n")
  of yamlAlias:
    stdout.write("=ALI *" & p.anchorName(cur.aliasTarget) & "\n")
stdout.write("-STR\n")