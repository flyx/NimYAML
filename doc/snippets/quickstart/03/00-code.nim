import yaml.serialization, streams
type
  Node = ref NodeObj
  NodeObj = object
    name: string
    left, right: Node

var node1, node2, node3: Node
new(node1); new(node2); new(node3)
node1.name = "Node 1"
node2.name = "Node 2"
node3.name = "Node 3"
node1.left = node2
node1.right = node3
node2.right = node3
node3.left = node1

var s = newFileStream("out.yaml", fmWrite)
dump(node1, s)
s.close()