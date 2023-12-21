import macros

type
  Container = object
    foo: string

proc canBeImplicit(t: typedesc): string {.compileTime.} =
  ## returns empty string if type can be implicit, else the reason why it can't
  let tDesc = getType(t)
  if tDesc.kind != nnkObjectTy: return "type is not an object, but a " & $tDesc.kind
  return ""

const res = canBeImplicit(Container)
assert len(res) == 0, "unexpected error for canBeImplicit: " & res
