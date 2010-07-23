-- LuaInspect.globals - identifier scope analysis
-- Locates locals, globals, and their definitions.
--
-- (c) D.Manura, 2008-2010, MIT license.

-- based on http://lua-users.org/wiki/DetectingUndefinedVariables

local M = {}

-- Helper function: Parse current node in AST recursively.
local function traverse(ast, scope, globals, level)
  level = level or 1
  scope = scope or {}

  local blockrecurse

  if ast.tag == "Local" or ast.tag == "Localrec" then
    local vnames, vvalues = ast[1], ast[2]
    for i,v in ipairs(vnames) do
      assert(v.tag == "Id")
      local vname = v[1]
      --print(level, "deflocal",v[1])
      local parentscope = getmetatable(scope).__index
      parentscope[vname] = v

      v.localdefinition = v
      v.isdefinition = true
    end
    blockrecurse = 1
  elseif ast.tag == "Id" then
    local vname = ast[1]
    --print(level, "ref", vname, scope[vname])
    if scope[vname] then
      ast.localdefinition = scope[vname]
      scope[vname].isused = true
    end
    --if not scope[vname] then
    --  print(string.format("undefined %s at line %d", vname, ast.lineinfo.first[1]))
    --end
  elseif ast.tag == "Function" then
    local params = ast[1]
    local body = ast[2]
    for i,v in ipairs(params) do
      local vname = v[1]
      assert(v.tag == "Id" or v.tag == "Dots")
      if v.tag == "Id" then
        scope[vname] = v
        v.localdefinition = v
        v.isdefinition = true
        v.isparam = true
      end
    end
    blockrecurse = 1
  elseif ast.tag == "Set" then
    local vrefs, vvalues = ast[1], ast[2]
    for i,v in ipairs(vrefs) do
      if v.tag == 'Id' then
        local vname = v[1]
        if scope[vname] then
          scope[vname].isset = true
        else
          if not globals[vname] then
            globals[vname] = {set=v}
          end
        end
      end
    end
  elseif ast.tag == "Fornum" then
    local v = ast[1]
    local vname = v[1]
    scope[vname] = v
    v.localdefinition = v
    v.isdefinition = true
    blockrecurse = 1
  elseif ast.tag == "Forin" then
    local vnames = ast[1]
    for i,v in ipairs(vnames) do
      local vname = v[1]
      scope[vname] = v
      v.localdefinition = v
      v.isdefinition = true
    end
    blockrecurse = 1
  end

  -- recurse (depth-first search through AST)
  if ast.tag == "Repeat" then
    local scope = scope
    for i,v in ipairs(ast[1]) do
      scope = setmetatable({}, {__index = scope})
      traverse(v, scope, globals, level+1)
    end
    scope = setmetatable({}, {__index = scope})
    traverse(ast[2], scope, globals, level+1)
  else
    for i,v in ipairs(ast) do
      if i ~= blockrecurse and type(v) == "table" then
        local scope = setmetatable({}, {__index = scope})
        traverse(v, scope, globals, level+1)
      end
    end
  end
end

function M.globals(ast)
  -- Default list of defined variables.
  local scope = setmetatable({}, {})
  local globals = {}
  traverse(ast, scope, globals) -- Start check.

  return globals
end



return M
