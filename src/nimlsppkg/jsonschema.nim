import macros
import ast_pattern_matching
import json
import sequtils
import options
import strutils
import tables

proc extractKinds(node: NimNode): tuple[kinds: seq[string], isArray: bool] =
  if node.kind == nnkIdent:
    return (kinds: @[$node], isArray: false)
  elif node.kind == nnkInfix and node[0].kind == nnkIdent and $node[0] == "or":
    result.kinds = @[$node[2]]
    result.kinds.insert(extractKinds(node[1]).kinds)
    result.isArray = false
  elif node.kind == nnkBracket:
    return (kinds: node[0].extractKinds.kinds, isArray: true)
  else:
    raise newException(AssertionError, "Unknown node kind: " & $node.kind)

proc matchDefinition(pattern: NimNode): tuple[name: string, kinds: tuple[kinds: seq[string], isArray: bool], optional: bool] {.compileTime.} =
  matchAst(pattern):
  of nnkCall(
    `name` @ nnkIdent,
    nnkStmtList(
      `kind`
    )
  ):
    return (name: $name, kinds: kind.extractKinds, optional: false)
  of nnkInfix(
    ident"?:",
    `name` @ nnkIdent,
    `kind`
  ):
    return (name: $name, kinds: kind.extractKinds, optional: true)

proc matchDefinitions(definitions: NimNode): seq[tuple[name: string, kinds: tuple[kinds: seq[string], isArray: bool], optional: bool]] {.compileTime.} =
  result = @[]
  for definition in definitions:
    result.add matchDefinition(definition)

macro jsonSchema*(pattern: untyped): untyped =
  echo pattern.treeRepr
  var types: seq[tuple[name: string, extends: string, definitions: seq[tuple[name: string, kinds: tuple[kinds: seq[string], isArray: bool], optional: bool]]]] = @[]
  for part in pattern:
    matchAst(part):
    of nnkCall(
      `objectName` @ nnkIdent,
      `definitions` @ nnkStmtList
    ):
      let defs = definitions.matchDefinitions
      types.add (name: $objectName, extends: nil, definitions: defs)
    of nnkCommand(
      `objectName` @ nnkIdent,
      nnkCommand(
        ident"extends",
        `extends` @ nnkIdent
      ),
      `definitions` @ nnkStmtList
    ):
      let defs = definitions.matchDefinitions
      types.add (name: $objectName, extends: $extends, definitions: defs)

  var
    typeDefinitions = newStmtList()
    validationBodies = initOrderedTable[string, NimNode]()
    creatorBodies = initOrderedTable[string, NimNode]()
    createArgs  = initOrderedTable[string, NimNode]()
  let
    data = newIdentNode("data")
    fields = newIdentNode("fields")
    traverse = newIdentNode("traverse")
    ret = newIdentNode("ret")
    i = newIdentNode("i")
  for t in types:
    let name = newIdentNode(t.name)
    creatorBodies[t.name] = newStmtList()
    typeDefinitions.add quote do:
      type `name` = distinct JsonNode

    var
      requiredFields = 0
      validations = newStmtList()
    createArgs[t.name] = nnkFormalParams.newTree(name)
    for field in t.definitions:
      let
        fname = field.name
        aname = newIdentNode(field.name)
        cname = if field.kinds.isArray:
            i
          else:
            quote do:
              `data`[`fname`]
      var
        checks: seq[NimNode] = @[]
        argumentChoices: seq[NimNode] = @[]
      for kind in field.kinds.kinds:
        let tKind = if kind == "any" or field.kinds.isArray:
            newIdentNode("JsonNode")
          else:
            newIdentNode(kind)
        if field.kinds.isArray:
          if argumentChoices.len == 0:
            argumentChoices.add tkind
        else:
          argumentChoices.add tkind
        var creatorAsgn: NimNode
        if kind.toLowerASCII in ["int", "string", "float", "bool"]:
          let
            jkind = newIdentNode("J" & kind)
          checks.add quote do:
            `cname`.kind != `jkind`
          if field.optional:
            creatorAsgn = quote do:
              %`aname`.get
          else:
            creatorAsgn = quote do:
              %`aname`
        elif kind == "any":
          checks.add newLit(false)
          if field.optional:
            creatorAsgn = quote do:
              `aname`.get
          else:
            creatorAsgn = quote do:
              `aname`
        else:
          let kindNode = newIdentNode(kind)
          checks.add quote do:
            (`traverse` and not `cname`.isValid(`kindNode`))
          if field.optional:
            creatorAsgn = quote do:
              `aname`.get.JsonNode
          else:
            creatorAsgn = quote do:
              `aname`.JsonNode
        if field.kinds.isArray:
          if field.optional:
            creatorBodies[t.name].add quote do:
              if `aname`.isSome:
                if `aname`.get.kind != JArray:
                  raise newException(AssertionError, "Unable to add non-JArray kind as array")
                `ret`[`fname`] = `aname`.get
          else:
            creatorBodies[t.name].add quote do:
              if `aname`.kind != JArray:
                raise newException(AssertionError, "Unable to add non-JArray kind as array")
              `ret`[`fname`] = `aname`
          break
        else:
          if field.optional:
            creatorBodies[t.name].add quote do:
              when `aname` is Option[`tkind`]:
                if `aname`.isSome:
                  `ret`[`fname`] = `creatorAsgn`
          else:
            creatorBodies[t.name].add quote do:
              when `aname` is `tkind`:
                `ret`[`fname`] = `creatorAsgn`
      echo checks.repr
      while checks.len != 1:
        let newFirst = nnkInfix.newTree(newIdentNode("and"), checks[0], checks[1])
        checks = checks[2..^1]
        checks.insert(newFirst)
      while argumentChoices.len != 1:
        let newFirst = nnkInfix.newTree(newIdentNode("or"), argumentChoices[0], argumentChoices[1])
        argumentChoices = argumentChoices[2..^1]
        argumentChoices.insert(newFirst)
      if field.optional:
        createArgs[t.name].add nnkIdentDefs.newTree(aname, nnkBracketExpr.newTree(newIdentNode("Option"), argumentChoices[0]), newEmptyNode())
      else:
        createArgs[t.name].add nnkIdentDefs.newTree(aname, argumentChoices[0], newEmptyNode())
      echo field.kinds
      let
        check = checks[0]
        checkStmt = if field.kinds.isArray:
            quote do:
              if `data`[`fname`].kind != JArray: return false
              for `i` in `data`[`fname`]:
                if `check`: return false
          else:
            quote do:
              if `check`: return false
      if field.optional:
        validations.add quote do:
          if `data`.hasKey(`fname`):
            `fields` += 1
            `checkStmt`
      else:
        requiredFields += 1
        validations.add quote do:
          if not `data`.hasKey(`fname`): return false
          `checkStmt`

    if t.extends == nil:
      validationBodies[t.name] = quote do:
        var `fields` = `requiredFields`
        `validations`
    else:
      let extends = validationBodies[t.extends]
      validationBodies[t.name] = quote do:
        `extends`
        `fields` += `requiredFields`
        `validations`
      for i in countdown(createArgs[t.extends].len - 1, 1):
        createArgs[t.name].insert(1, createArgs[t.extends][i])
      creatorBodies[t.name].insert(0, creatorBodies[t.extends])

    echo createArgs[t.name].repr

  for kind, body in creatorBodies.pairs:
    echo kind, body.repr
  var validators = newStmtList()
  for kind, body in validationBodies.pairs:
    let kindIdent = newIdentNode(kind)
    validators.add quote do:
      proc isValid(`data`: JsonNode, kind: typedesc[`kindIdent`], `traverse` = true): bool =
        if `data`.kind != JObject: return false
        `body`
        if `fields` != `data`.len: return false
        return true
  var creators = newStmtList()
  for t in types:
    let
      creatorBody = creatorBodies[t.name]
      kindIdent = newIdentNode(t.name)
    var creatorArgs = createArgs[t.name]
    creatorArgs.insert(1, nnkIdentDefs.newTree(newIdentNode("kind"), nnkBracketExpr.newTree(newIdentNode("typedesc"), kindIdent), newEmptyNode()))
    var createProc = quote do:
      proc create() =
        var `ret` = newJObject()
        `creatorBody`
        return `ret`.`kindIdent`
    createProc[3] = creatorArgs
    creators.add createProc

  result = quote do:
    `typeDefinitions`
    `validators`
    `creators`
  echo result.repr

when isMainModule:
  jsonSchema:
    CancelParams:
      id: int or string or float
      something?: float

    WrapsCancelParams:
      cp: CancelParams
      name: string

    ExtendsCancelParams extends CancelParams:
      name: string

    WithArray:
      test: [int or float]
      bob: [any]

  var wcp = create(WrapsCancelParams, create(CancelParams, 10, none(float)), "Hello")
  echo wcp.JsonNode.isValid(WrapsCancelParams) == true
  wcp.JsonNode["cp"] = %*{"notcancelparams": true}
  echo wcp.JsonNode.isValid(WrapsCancelParams) == false
  echo wcp.JsonNode.isValid(WrapsCancelParams, false) == true
  var ecp = create(ExtendsCancelParams, 10, some(5.3), "Hello")
  echo ecp.JsonNode.isValid(ExtendsCancelParams) == true


