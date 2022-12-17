---@type {decode: fun(s: string): table; encode: fun(t: table): string}
local json = require '3rd/json_lua/json'
local vlq = require 'scripts/text/vlq'

-- TODO: maybe replace the return nil with proper error (to make pcall and diag better)

---@alias location {line:integer, column:integer}
---@class m
local smap = {}

---@class sourcemap : m
---@field   version        integer       #file version
---@field   file           string?       #name of the generated code that this source map is associated with
---@field   sourceRoot     string?       #source root; this value is prepended to the indivitual entries in the "source" field
---@field   sources        string[]      #list of original sources used by the "mappings" field
---@field   sourcesContent (string?)[]?  #list of source content when the "source" can't be hosted
---@field   names          string[]      #list of symbol names used by the "mappings" field
---@field   mappings       string        #string with the encoded mapping data

---@param t sourcemap #sourcemap-like
local function intosourcemap(t)
  return setmetatable(t, {__index= smap}) --[[@as sourcemap]]
end

--local indexmap_mt = {__index= m}  (niy)
-- @alias section {offset: location; url: string?; map: sourcemap?}
-- @class indexmap : m
-- @field   version        integer       #file version
-- @field   file           string?       #name of the generated code that this source map is associated with
-- @field   sections       section[]     #sections with their own sourcemaps (sorted and non-overlapping)

---create a new empty sourcemap object
---@param file string
---@param sourceRoot string
---@return sourcemap
---@private
function smap.new(file, sourceRoot)
  return intosourcemap({
    version= 3,
    file= file,
    sourceRoot= sourceRoot,
    sources= {},
    --sourcesContent= {},
    names= {},
    mappings= ""
  })
end

---decode a JSON-encoded source map
---@param jsonstr string
---@return sourcemap? #nil if it was not a valid JSON or not a valid source map
---@private
function smap.decode(jsonstr)
  local yes, r = pcall(json.decode, jsonstr)
  if not yes
  or                     'number' ~= type(r.version)
  or r.file and          'string' ~= type(r.file)
  or r.sourceRoot and    'string' ~= type(r.sourceRoot)
  or                      'table' ~= type(r.sources)
  or r.sourcesContent and 'table' ~= type(r.sourcesContent)
  or                      'table' ~= type(r.names)
  or                     'string' ~= type(r.mappings)
    then return nil end
  return intosourcemap(r)
end

---encode the source map into JSON
---@param self sourcemap
---@return string
function smap.encode(self)
  local mt = getmetatable(self)
  assert(sourcemap_mt == mt, "not a sourcemap, don't wanna deal with that")
  local r = json.encode(setmetatable(self, nil))
  setmetatable(self, mt)
  return r
end

---returns the path for the source by its index; the index is assumed to be correct
---@param self sourcemap
---@param idx integer #an index in `sources`
---@return string
function smap.getsourcepath(self, idx)
  local root = self.sourceRoot
  if not root
    then root = ""
  elseif 0 < #root and '/' ~= root:sub(-1)
    then root = root..'/'
  end
  return root..self.sources[idx]
end

---returns the content for the source by its index; the index is assumed to be correct
---@param self sourcemap
---@param idx integer #an index in `sources`
---@return string? #nil if the source could not be reached/read
function smap.getsourcecontent(self, idx)
  if self.sourcesContent and self.sourcesContent[idx]
    then return self.sourcesContent[idx]
  end
  local path = self:getsourcepath(idx)
  -- YYY/ZZZ
  if "http" ~= path:sub(1, 4)
    then
      local file = io.open(path, 'r')
      if not file then return nil end
      local buf = file:read('a')
      file:close()
      return buf
  end
  return nil
end

---transform a location in `file` to it's original location in one of `sources` (which is return as its index)
---@param self sourcemap
---@param infile location #location in `file`
---@return location #location in the source
---@return integer #index of the source in `sources`
function smap.forward(self, infile)
  return {}, 0
end

local function _playground()
  local root = "tests/smap/"
  local name = "helloworld"
  local function readfile(ext, n)
    local f = assert(io.open(root..(n or name).."."..ext))
    ---@type string
    local b = f:read('a')
    f:close()
    return b
  end

  local osource = readfile('coffee')
  local csource = readfile('js')
  local self = assert(smap.decode(readfile('js.map')))

  ---@class segment
  ---@field   cline  integer   #ksadfklasd (TODO)
  ---@field   idx    integer   #index in `sources`
  ---@field   oloc   location  #location in original source
  ---@field   name   integer   #index in `names`

  ---@type segment[][]
  local lines = {}
  local at, len = 1, #self.mappings
  while at <= len
    do
      local semi = self.mappings:find(';', at) or len+1
      local line = self.mappings:sub(at, semi-1)

      local abs_cline = 1
      local abs_idx = 1
      local abs_oline = 1
      local abs_ocol = 1
      local abs_name = 1

      ---@type segment[]
      local segments = {}
      local att, lenn = 1, #line
      while att <= lenn
        do
          local comm = line:find(',', att) or lenn+1
          local segment = line:sub(att, comm-1)

          local rel_cline -- 0-based starting column of the current line
              , rel_idx   -- (optional) 0-based index in `sources`
              , rel_oline -- (optional) 0-based starting line in original source
              , rel_ocol  -- (optional) 0-based starting column in original source
              , rel_name  -- (optional) 0-based index in `names`
            = vlq.decode(segment)

          ---@type segment
          local it = {cline= abs_cline+rel_cline}
          abs_cline = it.cline
          if rel_idx
            then
              it.idx = abs_idx+rel_idx
              abs_idx = it.idx
              it.oloc = {line= abs_oline+rel_oline, column= abs_ocol+rel_ocol}
              abs_oline = it.oloc.line
              abs_ocol = it.oloc.column
              if rel_name
                then
                  it.name = abs_name+rel_name
                  abs_name = it.name
              end
          end

          segments[#segments+1] = it
          att = comm+1
      end


      lines[#lines+1] = segments
      at = semi+1
  end

  for k,v in ipairs(lines)
    do
      print("line "..k)
      for _,it in ipairs(v)
        do print("", it.cline-1, it.oloc.column-1)
      end
  end

  -- local infile = {}
  -- local insource, sourceidx = self:forward(infile)
end
_playground()

return smap
