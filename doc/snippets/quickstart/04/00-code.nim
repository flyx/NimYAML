import yaml/serialization, streams
type
  Node = ref NodeObj
  NodeObj = object
    name: string
    left, right: Node

var node1: Node

var s = newFileStream("in.yaml")
load(s, node1)
s.close()