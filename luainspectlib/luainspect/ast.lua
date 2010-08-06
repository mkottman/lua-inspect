-- luainspect.ast - Lua Abstract Syntax Tree (AST) and token list operations.
--
-- Two main structures are maintained.  A Metalua-style AST represents the
-- nested syntactic structure obtained from the parse.
-- A separate linear ordered list of tokens represents the syntactic structure
-- from the lexing, including line information (character positions only not row/columns),
-- comments, and keywords, which is originally built from the lineinfo attributes 
-- injected by Metalua into the AST (IMPROVE: it probably would be simpler
-- to obtain this from the lexer directly rather then inferring it from the parsing).
-- During AST manipulations, the lineinfo maintained in the AST is ignored
-- because it was found more difficult to maintain and not in the optimal format.
--
-- The contained code deals with
--   - Building the AST from source.
--   - Building the tokenlist from the AST lineinfo.
--   - Querying the AST+tokenlist.
--   - Modifying the AST+tokenlist (including incremental parsing source -> AST)
--   - Annotating the AST with navigational info (e.g. parent links) to assist queries.
--   - Dumping the AST+tokenlist for debugging.
--
-- (c) 2010 David Manura, MIT License.


--! require 'luainspect.typecheck' (context)

local M = {}


-- CATEGORY: debug
local function DEBUG(...)
  if LUAINSPECT_DEBUG then
    print('DEBUG:', ...)
  end
end


-- Remove any sheband ("#!") line from Lua source string.
-- CATEGORY: Lua parsing
function M.remove_shebang(src)
  local shebang = src:match("^#![^\r\n]*")
  return shebang and (" "):rep(#shebang) .. src:sub(#shebang+1) or src
end


-- Custom version of loadstring that parses out line number info
-- CATEGORY: Lua parsing
function M.loadstring(src)
  local f, err = loadstring(src, "")
  if f then
    return f
  else
    err = err:gsub('^%[string ""%]:', "")
    local linenum = assert(err:match("(%d+):"))
    local colnum = 0
    local linenum2 = err:match("^%d+: '[^']+' expected %(to close '[^']+' at line (%d+)")
    return nil, err, linenum, colnum, linenum2
  end
end


-- helper for ast_from_string.  Raises on error.
-- FIX? filename currently ignored in Metalua
-- CATEGORY: Lua parsing
local function ast_from_string_helper(src, filename)
  filename = filename or '(string)'
  local  lx  = mlp.lexer:newstream (src, filename)
  local  ast = mlp.chunk(lx)
  return ast
end


-- Converts Lua source string to Lua AST (via mlp/gg).
-- CATEGORY: Lua parsing
function M.ast_from_string(src, filename)
  local ok, ast = pcall(ast_from_string_helper, src, filename)
  if not ok then
    local err = ast
    err = err:match('[^\n]*')
    err = err:gsub("^.-:%s*line", "line")
        -- mlp.chunk prepending this is undesirable.   error(msg,0) would be better in gg.lua. Reported.
        -- TODO-Metalua: remove when fixed in Metalua.
    local linenum, colnum = err:match("line (%d+), char (%d+)")
    if not linenum then
      -- Metalua libraries may return "...gg.lua:56: .../mlp_misc.lua:179: End-of-file expected"
      -- without the normal line/char numbers given things like "if x then end end".  Should be
      -- fixed probably with gg.parse_error in _chunk in mlp_misc.lua.
      -- TODO-Metalua: remove when fixed in Metalua.
      linenum = editor.LineCount - 1
      colnum = 0
    end
    local linenum2 = nil
    return nil, err, linenum, colnum, linenum2
  else
    return ast
  end
end


-- Simple comment parser.  Returns Metalua-style comment.
-- CATEGORY: Lua lexing
local function quick_parse_comment(src)
  local s = src:match"^%-%-([^\n]*)()\n$"
  if s then return {s, 1, #src, 'short'} end
  local _, s = src:match(lexer.lexer.patterns.long_comment .. '\r?\n?$')
  if s then return {s, 1, #src, 'long'} end
  return nil
end
--FIX:check new-line correctness
--note: currently requiring \n at end of single line comment to avoid
-- incremental compilation with `--x\nf()` and removing \n from still
-- recognizing as comment `--x`.
-- currently allowing \r\n at end of long comment since Metalua includes
-- it in lineinfo of long comment (FIX:Metalua?)


-- Gets length of longest prefix string in both provided strings.
-- Returns max n such that text1:sub(1,n) == text2:sub(1,n) and n <= max(#text1,#text2)
-- CATEGORY: string utility
local function longest_prefix(text1, text2)
  local nmin = 0
  local nmax = math.min(#text1, #text2)
  while nmax > nmin do
    local nmid = math.ceil((nmin+nmax)/2)
    if text1:sub(1,nmid) == text2:sub(1,nmid) then
      nmin = nmid
    else
      nmax = nmid-1
    end
  end
  return nmin
end


-- Gets length of longest postfix string in both provided strings.
-- Returns max n such that text1:sub(-n) == text2:sub(-n) and n <= max(#text1,#text2)
-- CATEGORY: string utility
local function longest_postfix(text1, text2)
  local nmin = 0
  local nmax = math.min(#text1, #text2)
  while nmax > nmin do
    local nmid = math.ceil((nmin+nmax)/2)
    if text1:sub(-nmid) == text2:sub(-nmid) then --[*]
      nmin = nmid
    else
      nmax = nmid-1
    end
  end
  return nmin
end  -- differs from longest_prefix only on line [*]



-- Determines AST node that must be re-evaluated upon changing code string from
-- `src` to `bsrc`, given previous AST `top_ast` and tokenlist `tokenlist` corresponding to `src`.
-- note: decorates ast1 as side-effect
-- CATEGORY: AST/tokenlist manipulation
function M.invalidated_code(top_ast, tokenlist, src, bsrc)
  -- Converts posiiton range in src to position range in bsrc.
  local function range_transform(src_fpos, src_lpos)
    local src_nlpos = #src - src_lpos
    local bsrc_fpos = src_fpos
    local bsrc_lpos = #bsrc - src_nlpos
    return bsrc_fpos, bsrc_lpos
  end

  if src == bsrc then return end -- up-to-date
  
  local npre = longest_prefix(src, bsrc)
  local npost = math.min(#src-npre, longest_postfix(src, bsrc))
    -- note: min to avoid overlap ambiguity
    
  -- Find range of positions in src that differences correspond to.
  -- note: for zero byte range, src_pos2 = src_pos1 - 1.
  local src_fpos, src_lpos = 1 + npre, #src - npost
  
  -- Find smallest AST node in ast containing src range above,
  -- optionally contained comment or whitespace
  local match_ast, match_comment, iswhitespace =
      M.smallest_ast_in_range(top_ast, tokenlist, src, src_fpos, src_lpos)

  DEBUG('invalidate-smallest:', match_ast and (match_ast.tag or 'notag'), match_comment, iswhitespace)

  if iswhitespace then
    local bsrc_fpos, bsrc_lpos = range_transform(src_fpos, src_lpos)
    if bsrc:sub(bsrc_fpos, bsrc_lpos):match'^%s*$' then -- whitespace replaced with whitespace
      if not bsrc:sub(bsrc_fpos-1, bsrc_lpos+1):match'%s' then
        DEBUG('edit:white-space-eliminated')
        -- whitespace eliminated, continue
      else
        return src_fpos, src_lpos, bsrc_fpos, bsrc_lpos, nil, 'whitespace'
      end
    end -- else continue
  elseif match_comment then
    local srcm_fpos, srcm_lpos = match_comment.fpos, match_comment.lpos
    local bsrcm_fpos, bsrcm_lpos = range_transform(srcm_fpos, srcm_lpos)
    -- If new text is not a single comment, then invalidate containing statementblock instead.
    local m2text = bsrc:sub(bsrcm_fpos, bsrcm_lpos)
    DEBUG('inc-compile-comment[' .. m2text .. ']')
    if quick_parse_comment(m2text) then  -- comment replaced with comment
      return srcm_fpos, srcm_lpos, bsrcm_fpos, bsrcm_lpos, match_comment, 'comment'
    end -- else continue
  else -- statementblock modified
    match_ast = M.get_containing_statementblock(match_ast, top_ast)
    local srcm_fpos, srcm_lpos = M.ast_pos_range(match_ast, tokenlist)
    local bsrcm_fpos, bsrc_lpos = range_transform(srcm_fpos, srcm_lpos)
    local m2text = bsrc:sub(bsrcm_fpos, bsrc_lpos)
    DEBUG('inc-compile-statblock:', match_ast and match_ast.tag, '[' .. m2text .. ']')
    if loadstring(m2text) then -- statementblock replaced with statementblock 
      return srcm_fpos, srcm_lpos, bsrcm_fpos, bsrc_lpos, match_ast, 'statblock'
    end -- else continue
  end

  -- otherwise invalidate entire AST.
  -- IMPROVE:performance: we don't always need to invalidate the entire AST here.
  return nil, nil, nil, nil, top_ast, 'full'
end


-- Walks AST `ast` in arbitrary order, visiting each node `n`, executing `fdown(n)` (if specified)
-- when doing down and `fup(n)` (if specified) when going if.
-- CATEGORY: AST walk
function M.walk(ast, fdown, fup)
  assert(type(ast) == 'table')
  if fdown then fdown(ast) end
  for _,bast in ipairs(ast) do
    if type(bast) == 'table' then
      M.walk(bast, fdown, fup)
    end
  end
  if fup then fup(ast) end
end


-- Replaces contents of table t1 with contents of table t2.
-- Does not change metatable (if any).
-- This function is useful for swapping one AST node with another
-- while preserving any references to the node.
-- CATEGORY: table utility
function M.switchtable(t1, t2)
  for k in pairs(t1) do t1[k] = nil end
  for k in pairs(t2) do t1[k] = t2[k] end
end


-- Inserts all elements in list bt at index i in list t.
-- CATEGORY: table utility
local function tinsertlist(t, i, bt)
  for bi=#bt,1,-1 do
    table.insert(t, i, bt[bi])
  end
end


-- Gets list of keyword positions related to node ast in source src
-- note: ast must be visible, i.e. have lineinfo (e.g. unlike `Id "self" definition).
-- Note: includes operators.
-- Note: Assumes ast Metalua-style lineinfo is valid.
-- CATEGORY: tokenlist build
function M.get_keywords(ast, src)
  local list = {}
  if not ast.lineinfo then return list end
  -- examine space between each pair of children i and j.
  -- special cases: 0 is before first child and #ast+1 is after last child
  local i = 0
  while i <= #ast do
    -- j is node following i that has lineinfo
    local j = i+1; while j < #ast+1 and not ast[j].lineinfo do j=j+1 end

    -- Get position range [fpos,lpos] between subsequent children.
    local fpos
    if i == 0 then  -- before first child
      fpos = ast.lineinfo.first[3]
    else
      local last = ast[i].lineinfo.last; local c = last.comments
      fpos = (c and #c > 0 and c[#c][3] or last[3]) + 1
    end
    local lpos
    if j == #ast+1 then  -- after last child
      lpos = ast.lineinfo.last[3]
    else
      local first = ast[j].lineinfo.first; local c = first.comments
      --DEBUG('first', ast.tag, first[3], src:sub(first[3], first[3]+3))
      lpos = (c and #c > 0 and c[1][2] or first[3]) - 1
    end
    
    -- Find keyword in range.
    local spos = fpos
    repeat
      local mfpos, tok, mlppos = src:match("^%s*()(%a+)()", spos)
      if not mfpos then
        mfpos, tok, mlppos = src:match("^%s*()(%p+)()", spos)
      end
      --DEBUG('look', ast.tag, #ast,i,j,'*', mfpos, tok, mlppos, fpos, lpos, src:sub(fpos, fpos+5))
      if mfpos and mlppos-1 <= lpos then
        list[#list+1] = mfpos
        list[#list+1] = mlppos-1
      end
      spos = mlppos
    until not spos or spos > lpos
    -- note: finds single keyword.  in `local function` returns only `local`
    --DEBUG(i,j ,'test[' .. src:sub(fpos, lpos) .. ']')
    
    i = j  -- next
   
    --DESIGN:Lua: comment: string.match accepts a start position but not a stop position
  end
  return list
end
-- Q:Metalua: does ast.lineinfo[loc].comments imply #ast.lineinfo[loc].comments > 0 ?



-- Generates ordered list of tokens in top_ast/src.
-- Note: currently ignores operators and parens.
-- Note: Modifies ast.
-- Note: Assumes ast Metalua-style lineinfo is valid.
-- CATEGORY: AST/tokenlist query
local isterminal = {Nil=true, Dots=true, True=true, False=true, Number=true, String=true,
  Dots=true, Id=true}
local function compare_tokens_(atoken, btoken) return atoken.fpos < btoken.fpos end
function M.ast_to_tokenlist(top_ast, src)
  local tokens = {}
  local isseen = {}
  M.walk(top_ast, function(ast)
    if isterminal[ast.tag] then -- Extract terminal
      local token = ast
      if ast.lineinfo then
        token.fpos, token.lpos, token.ast = ast.lineinfo.first[3], ast.lineinfo.last[3], ast
        table.insert(tokens, token)
      end
    else -- Extract non-terminal
      local keywordposlist = M.get_keywords(ast, src)
      for i=1,#keywordposlist,2 do
        local fpos, lpos = keywordposlist[i], keywordposlist[i+1]
        local toktext = src:sub(fpos, lpos)
        local token = {tag='Keyword', fpos=fpos, lpos=lpos, ast=ast, toktext}
        table.insert(tokens, token)
      end
    end
    -- Extract comments
    for i=1,2 do
      local comments = ast.lineinfo and ast.lineinfo[i==1 and 'first' or 'last'].comments
      if comments then for _, comment in ipairs(comments) do
        if not isseen[comment] then
          comment.tag = 'Comment'
          local token = comment
          token.fpos, token.lpos, token.ast = comment[2], comment[3], comment
          table.insert(tokens, token)
          isseen[comment] = true
        end
      end end
    end
    
  end)
  table.sort(tokens, compare_tokens_)
  return tokens
end


-- Gets tokenlist range [fidx,lidx] covered by ast/tokenlist.  Returns nil,nil if not found.
-- CATEGORY: AST/tokenlist query
function M.ast_idx_range_in_tokenlist(tokenlist, ast)
  -- Get list of primary nodes under ast.
  local isold = {}; M.walk(ast, function(ast) isold[ast] = true end)
  -- Get range.
  local fidx, lidx
  for idx=1,#tokenlist do
    local token = tokenlist[idx]
    if isold[token.ast] then
      lidx = idx
      if not fidx then fidx = idx end
    end
  end
  return fidx, lidx
end


-- Get index range in tokenlist overlapped by character position range [fpos, lpos].
-- Partially overlapped tokens are included.  If position range between tokens, then fidx is last token and lidx is first token
-- (which implies lidx = fidx - 1)
-- CATEGORY: tokenlist query
function M.tokenlist_idx_range_over_pos_range(tokenlist, fpos, lpos)
  -- note: careful with zero-width range (lpos == fpos - 1)
  local fidx, lidx
  for idx=1,#tokenlist do
    local token = tokenlist[idx]
    --if (token.fpos >= fpos and token.fpos <= lpos) or (token.lpos >= fpos and token.lpos <= lpos) then -- token overlaps range
    if fpos <= token.lpos and lpos >= token.fpos then -- range overlaps token
      if not fidx then fidx = idx end
      lidx = idx
    end
  end
  if not fidx then -- on fail, check between tokens
    for idx=1,#tokenlist+1 do
      local tokfpos, toklpos = tokenlist[idx-1] and tokenlist[idx-1].lpos, tokenlist[idx] and tokenlist[idx].fpos
      if (not tokfpos or fpos > tokfpos) and (not toklpos or lpos < toklpos) then -- range between tokens
        return idx, idx-1
      end
    end
  end
  assert(fidx and lidx)
  return fidx, lidx
end

-- Remove tokens in tokenlist covered by ast. 
-- CATEGORY: tokenlist manipulation
local function remove_ast_in_tokenlist(tokenlist, ast)
  local fidx, lidx  = M.ast_idx_range_in_tokenlist(tokenlist, ast)
  if fidx then  -- note: fidx implies lidx
    for idx=lidx,fidx,-1 do table.remove(tokenlist, idx) end
  end
end


-- Insert tokens from btokenlist into tokenlist.  Preserves sort.
-- CATEGORY: tokenlist manipulation
local function insert_tokenlist(tokenlist, btokenlist)
  local ftoken = btokenlist[1]
  if ftoken then
    -- Get index in tokenlist in which to insert tokens in btokenlist.
    local fidx
    for idx=1,#tokenlist do
      if tokenlist[idx].fpos > ftoken.fpos then fidx = idx; break end
    end
    fidx = fidx or #tokenlist + 1  -- else append

    -- Insert tokens.
    tinsertlist(tokenlist, fidx, btokenlist)
  end
end


-- Get character position range covered by ast in tokenlist.  Returns nil,nil if not found
-- CATEGORY: AST/tokenlist query
function M.ast_pos_range(ast, tokenlist)
  local fidx, lidx  = M.ast_idx_range_in_tokenlist(tokenlist, ast)
  if fidx then
    return tokenlist[fidx].fpos, tokenlist[lidx].lpos
    else
    return nil, nil
  end
end


-- Gets smallest AST node inside top_ast/tokenlist/src
-- completely containing position range [pos1, pos2].
-- careful: "function" is not part of the `Function node.
-- If range is inside comment, returns comment also.
-- If corresponding source `src` is specified (may be nil)
-- and range is inside whitespace, then returns true in third return value.
--FIX: maybe src no longer needs to be passed
-- CATEGORY: AST/tokenlist query
function M.smallest_ast_in_range(top_ast, tokenlist, src, pos1, pos2)
  local f0idx, l0idx = M.tokenlist_idx_range_over_pos_range(tokenlist, pos1, pos2)
  
  -- Find enclosing AST.
  if top_ast[1] and not top_ast[1].parent then M.mark_parents(top_ast) end
  local fidx, lidx = f0idx, l0idx
  while tokenlist[fidx] and not tokenlist[fidx].ast.parent do fidx = fidx - 1 end
  while tokenlist[lidx] and not tokenlist[lidx].ast.parent do lidx = lidx + 1 end
  -- DEBUG(fidx, lidx, f0idx, l0idx, #tokenlist, pos1, pos2, tokenlist[fidx], tokenlist[lidx])
  local ast = not (tokenlist[fidx] and tokenlist[lidx]) and top_ast or
      M.common_ast_parent(tokenlist[fidx].ast, tokenlist[lidx].ast, top_ast)
  -- DEBUG('m2', tokenlist[fidx], tokenlist[lidx], top_ast, ast, ast and ast.tag)
  if src and l0idx == f0idx - 1 then -- e.g.whitespace (FIX-currently includes non-whitespace too)
    local iswhitespace
    if pos2 == pos1 - 1  then -- zero length
      if src:sub(pos2, pos1):match'%s' then iswhitespace = true end -- either right or left %s
    elseif src:sub(pos1,pos2):match'^%s+$' then
      iswhitespace = true
    end
    if iswhitespace then
      return ast, nil, true
    else
      return ast, nil, nil
    end
  elseif l0idx == f0idx and tokenlist[l0idx].tag == 'Comment' then
    return ast, tokenlist[l0idx], nil
  else
    return ast, nil, nil
  end
end
--IMPROVE: handle string edits and maybe others


-- Gets index of bast in ast (nil if not found).
-- CATEGORY: AST query
function M.ast_idx(ast, bast)
  for idx=1,#ast do
    if ast[idx] == bast then return idx end
  end
  return nil
end


-- Gets parent of ast and index of ast in parent.
-- Root node top_ast must also be provided.  Returns nil, nil if ast is root.
-- Note: may call mark_parents.
-- CATEGORY: AST query
function M.ast_parent_idx(top_ast, ast)
  if ast == top_ast then return nil, nil end
  if not ast.parent then M.mark_parents(top_ast) end; assert(ast.parent)
  local idx = M.ast_idx(ast.parent, ast)
  return ast.parent, idx
end


-- Gets common parent of aast and bast.  Always returns value.
-- Must provide root top_ast too.
-- CATEGORY: AST query
function M.common_ast_parent(aast, bast, top_ast)
  if top_ast[1] and not top_ast[1].parent then M.mark_parents(top_ast) end
  local isparent = {}
  local tast = bast; repeat isparent[tast] = true; tast = tast.parent until not tast
  local uast = aast; repeat if isparent[uast] then return uast end; uast = uast.parent until not uast
  assert(false)
end


-- Replaces old_ast with new_ast/new_tokenlist in top_ast/tokenlist.
-- Note: assumes new_ast is a block.  assumes old_ast is a statement or block.
-- CATEGORY: AST/tokenlist
function M.replace_statements(top_ast, tokenlist, old_ast, new_ast, new_tokenlist)
  remove_ast_in_tokenlist(tokenlist, old_ast)
  insert_tokenlist(tokenlist, new_tokenlist)
  if old_ast == top_ast then -- special case: no parent
    M.switchtable(old_ast, new_ast) -- note: safe since block is not in tokenlist.
  else
    local parent_ast, idx = M.ast_parent_idx(top_ast, old_ast)
    table.remove(parent_ast, idx)
    tinsertlist(parent_ast, idx, new_ast)
  end

  -- fixup annotations
  for _,bast in ipairs(new_ast) do
    if top_ast.tag2 then M.mark_tag2(bast, bast.tag == 'Do' and 'StatBlock' or 'Block') end
    if old_ast.parent then M.mark_parents(bast, old_ast.parent) end
  end
end


-- Adjust lineinfo in tokenlist.
-- All char positions starting at pos1 are shifted by delta number of chars.
-- CATEGORY: tokenlist
function M.adjust_lineinfo(tokenlist, pos1, delta)
  for _,token in ipairs(tokenlist) do
    if token.fpos >= pos1 then
       token.fpos = token.fpos + delta
    end
    if token.lpos >= pos1 then
      token.lpos = token.lpos + delta
    end
  end
end


-- For each node n in ast, set n.parent to parent node of n.
-- Assumes ast.parent will be parent_ast (may be nil)
-- CATEGORY: AST query
function M.mark_parents(ast, parent_ast)
  ast.parent = parent_ast
  for _,ast2 in ipairs(ast) do
    if type(ast2) == 'table' then
      M.mark_parents(ast2, ast)
    end
  end
end


-- Calls mark_parents(ast) if ast not marked.
-- CATEGORY: AST query
local function ensure_parents_marked(ast)
  if ast[1] and not ast[1].parent then M.mark_parents(ast) end
end


-- For each node n in ast, set n.tag2 to context string:
-- 'Block' - node is block
-- 'Stat' - node is statement
-- 'StatBlock' - node is statement and block (i.e. `Do)
-- 'Exp' - node is expression
-- 'Explist' - node is expression list (or identifier list)
-- 'Pair' - node is key-value pair in table constructor
-- note: ast.tag2 will be set to context.
-- CATEGORY: AST query
local iscertainstat = {Do=true, Set=true, While=true, Repeat=true, If=true,
  Fornum=true, Forin=true, Local=true, Localrec=true, Return=true, Break=true}
function M.mark_tag2(ast, context)
  context = context or 'Block'
  ast.tag2 = context
  for i,bast in ipairs(ast) do
    if type(bast) == 'table' then
      local nextcontext
      if bast.tag == 'Do' then
        nextcontext = 'StatBlock'
      elseif iscertainstat[bast.tag] then
        nextcontext = 'Stat'
      elseif bast.tag == 'Call' or bast.tag == 'Invoke' then
        nextcontext = context == 'Block' and 'Stat' or 'Exp'
        --DESIGN:Metalua: these calls actually contain expression lists,
        --  but the expression list is not represented as a complete node
        --  by Metalua (as blocks are in `Do statements)
      elseif bast.tag == 'Pair' then
        nextcontext = 'Pair'
      elseif not bast.tag then
        if ast.tag == 'Set' or ast.tag == 'Local' or ast.tag == 'Localrec'
          or ast.tag == 'Forin' and i <= 2
          or ast.tag == 'Function'  and i == 1
        then
          nextcontext = 'Explist'
        else 
          nextcontext = 'Block'
        end
      else
        nextcontext = 'Exp'
      end
      M.mark_tag2(bast, nextcontext)
    end
  end
end


-- Gets smallest statement or block containing or being `ast`.
-- The AST root node `top_ast` must also be provided.
-- Note: may decorate AST as side-effect (mark_tag2/mark_parents).
-- top_ast is assumed a block, so this is always successful.
-- CATEGORY: AST query
function M.get_containing_statementblock(ast, top_ast)
  if not top_ast.tag2 then M.mark_tag2(top_ast) end
  if ast.tag2 == 'Stat' or ast.tag2 == 'StatBlock' or ast.tag2 == 'Block' then
    return ast
  else
    ensure_parents_marked(top_ast)
    return M.get_containing_statementblock(ast.parent, top_ast)
  end
end


-- Finds smallest statement, block, or comment AST  in ast/tokenlist containing position
-- range [fpos, lpos].  If allowexpand is true (default nil) and located AST
-- coincides with position range, then next containing statement is used
-- instead (this allows multiple calls to further expand the statement selection).
-- CATEGORY: AST query
function M.select_statementblockcomment(ast, tokenlist, fpos, lpos, allowexpand)
--IMPROVE: rename ast to top_ast
  local match_ast, comment_ast = M.smallest_ast_in_range(ast, tokenlist, nil, fpos, lpos)
  local select_ast = comment_ast or M.get_containing_statementblock(match_ast, ast)
  local nfpos, nlpos = M.ast_pos_range(select_ast, tokenlist)
  --DEBUG('s', nfpos, nlpos, fpos, lpos, match_ast.tag, select_ast.tag)
  if allowexpand and fpos == nfpos and lpos == nlpos then
    if comment_ast then
      -- Select enclosing statement.
      select_ast = match_ast
      nfpos, nlpos = M.ast_pos_range(select_ast, tokenlist)
    else
      -- note: multiple times may be needed to expand selection.  For example, in
      --   `for x=1,2 do f() end` both the statement `f()` and block `f()` have
      --   the same position range.
      ensure_parents_marked(ast)
      while select_ast.parent and fpos == nfpos and lpos == nlpos do
        select_ast = M.get_containing_statementblock(select_ast.parent, ast)
        nfpos, nlpos = M.ast_pos_range(select_ast, tokenlist)
      end
    end
  end
  return nfpos, nlpos
end


-- My own object dumper.
-- Intended for debugging, not serialization, with compact formatting.
-- Robust against recursion.
-- Renders Metalua table tag fields specially {tag=X, ...} --> "`X{...}".
-- On first call, only pass parameter o.
-- CATEGORY: AST debug
local ignore_keys_ = {lineinfo=true, tag=true}
local norecurse_keys_ = {parent=true, ast=true}
local function dumpstring_key_(k, isseen, newindent)
  local ks = type(k) == 'string' and k:match'^[%a_][%w_]*$' and k or
             '[' .. M.dumpstring(k, isseen, newindent) .. ']'
  return ks
end
local function sort_keys_(a, b)
  if type(a) == 'number' and type(b) == 'number' then
    return a < b
  elseif type(a) == 'number' then
    return false
  elseif type(b) == 'number' then
    return true
  elseif type(a) == 'string' and type(b) == 'string' then
    return a < b
  else
    return tostring(a) < tostring(b) -- arbitrary
  end
end
function M.dumpstring(o, isseen, indent, key)
  isseen = isseen or {}
  indent = indent or ''

  if type(o) == 'table' then
    if isseen[o] or norecurse_keys_[key] then
      return (type(o.tag) == 'string' and '`' .. o.tag .. ':' or '') .. tostring(o)
    else isseen[o] = true end -- avoid recursion

    local tag = o.tag
    local s = (tag and '`' .. tag or '') .. '{'
    local newindent = indent .. '  '

    local ks = {}; for k in pairs(o) do ks[#ks+1] = k end
    table.sort(ks, sort_keys_)
    --for i,k in ipairs(ks) do print ('keys', k) end

    local forcenummultiline
    for k in pairs(o) do
       if type(k) == 'number' and type(o[k]) == 'table' then forcenummultiline = true end
    end

    -- inline elements
    local used = {}
    for _,k in ipairs(ks) do
      if ignore_keys_[k] then used[k] = true
      elseif (type(k) ~= 'number' or not forcenummultiline) and
              type(k) ~= 'table' and (type(o[k]) ~= 'table' or norecurse_keys_[k])
      then
        s = s .. dumpstring_key_(k, isseen, newindent) .. '=' .. M.dumpstring(o[k], isseen, newindent, k) .. ', '
        used[k] = true
      end
    end

    -- elements on separate lines
    local done
    for _,k in ipairs(ks) do
      if not used[k] then
        if not done then s = s .. '\n'; done = true end
        s = s .. newindent .. dumpstring_key_(k) .. '=' .. M.dumpstring(o[k], isseen, newindent, k) .. ',\n'
      end
    end
    s = s:gsub(',(%s*)$', '%1')
    s = s .. (done and indent or '') .. '}'
    return s
  elseif type(o) == 'string' then
    return string.format('%q', o)
  else
    return tostring(o)
  end
end


-- Converts tokenlist to string representation for debugging.
-- CATEGORY: tokenlist debug
function M.dump_tokenlist(tokenlist)
  local ts = {}
  for i,token in ipairs(tokenlist) do
    ts[#ts+1] = 'tok.' .. i .. ': [' .. token.fpos .. ',' .. token.lpos .. '] '
       .. tostring(token[1]) .. tostring(token.ast.tag)
  end
  return table.concat(ts, '\n')
end


return M




--FIX:Q: does this handle Unicode ok?

--FIX:Metalua: In `local --[[x]] function --[[y]] f() end`,
--   'x' comment omitted from AST.

--FIX:Metalua: `do --[[x]] end` doesn't generate comments in AST.
--  `if x then --[[x]] end` and `while 1 do --[[x]] end` generates
--   comments in first/last of block

--FIX:Metalua: `--[[x]] f() --[[y]]` returns lineinfo around `f()`.
--  `--[[x]] --[[y]]` returns lineinfo around everything.

--FIX:Metalua: `while 1 do --[[x]] --[[y]] end` returns first > last
--   lineinfo for contained block

--FIX?:Metalua: loadstring parses "--x" but metalua omits the comment in the AST

--FIX?:Metalua: `local x` is generating `Local{{`Id{x}}, {}}`, which
--  has no lineinfo on {}.  This is contrary to the Metalua
--  spec: `Local{ {ident+} {expr+}? }.
--  Other things like `self` also generate no lineinfo.
--  The ast2.lineinfo test above avoids this.

--FIX:Metalua: Metalua shouldn't overwrite ipairs/pairs.  Note: Metalua version
--  doesn't set errorlevel correctly.

--Q:Metalua: Why does `return --[[y]]  z  --[[x]]` have
--  lineinfo.first.comments, lineinfo.last.comments,
--  plus lineinfo.comments (which is the same as lineinfo.first.comments) ?

--CAUTION:Metalua: `do  f()   end` returns lineinfo around `do  f()   end`, while
--  `while 1 do  f()  end` returns lineinfo around `f()` for inner block.

--CAUTION:Metalua: The lineinfo on Metalua comments is inconsistent with other
--   nodes
        
--CAUTION:Metalua: lineinfo of table in `f{}` is [3,2], of `f{ x,y }` it's [4,6].
--  This is inconsistent with `x={}` which is [3,4] and `f""` which is [1,2]
--  for the string.

--CAUTION:Metalua: only the `function()` form of `Function includes `function`
--   in lineinfo.  'function' is part of `Localrec and `Set in syntactic sugar form.


--[=[TESTSUITE
-- utilities
local ops = {}
ops['=='] = function(a,b) return a == b end
local function check(opname, a, b)
  local op = assert(ops[opname])
  if not op(a,b) then
    error("fail == " .. tostring(a) .. " " .. tostring(b))
  end
end

-- test longest_prefix/longest_postfix
local function pr(text1, text2)
  local lastv
  local function same(v)
    assert(not lastv or v == lastv); lastv = v; return v
  end
  local function test1(text1, text2) -- test prefix/postfix
    same(longest_prefix(text1, text2))
    same(longest_postfix(text1:reverse(), text2:reverse()))
  end
  local function test2(text1, text2) -- test swap
    test1(text1, text2)
    test1(text2, text1)
  end
  for _,extra in ipairs{"", "x", "xy", "xyz"} do -- test extra chars
    test2(text1, text2..extra)
    test2(text2, text1..extra)
  end
  return lastv
end
check('==', pr("",""), 0)
check('==', pr("a",""), 0)
check('==', pr("a","a"), 1)
check('==', pr("ab",""), 0)
check('==', pr("ab","a"), 1)
check('==', pr("ab","ab"), 2)
check('==', pr("abcdefg","abcdefgh"), 7)

print 'DONE'
--]=]
