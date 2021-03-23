import yaml, streams
type Mob = object
  level, experience: int32
  drops: seq[string]

setTag(Mob, Tag("!Mob"))
setTag(seq[string], Tag("!Drops"))

var mob = Mob(level: 42, experience: 1800, drops:
    @["Sword of Mob Slaying"])
var s = newFileStream("out.yaml", fmWrite)
dump(mob, s, tagStyle = tsAll)
s.close()