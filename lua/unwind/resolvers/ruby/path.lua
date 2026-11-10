-- lua/unwind/resolvers/ruby/path.lua
-- Ruby stacktrace path pattern parser for regular gems, bundler git gems, and stdlib

local M = {}

--- Normalize directory separators
local function norm(p)
  if not p then return "" end
  return p:gsub("\\", "/")
end

--- Parse regular gem path:
--- Matches patterns like:
---   .../gems/<gem_name>-<gem_version>/<relative_path>
--- Examples:
---   /apps/myapp/shared/bundle/ruby/3.3.0/gems/i18n-1.8.11/lib/i18n.rb
---   /apps/myapp/shared/bundle/ruby/3.3.0/gems/actionpack-8.1.3.1/lib/abstract_controller/base.rb
---@param fpath string
---@return table? { gem_name: string, gem_version: string, relative_path: string }
function M.parse_gem_path(fpath)
  local p = norm(fpath)
  -- Guard against bundler/gems
  if p:find("/bundler/gems/") then
    return nil
  end

  -- Pattern: /gems/([^/]+)/(.*)$
  local gem_folder, rel_path = p:match("/gems/([^/]+)/(.-)$")
  if not gem_folder or not rel_path or rel_path == "" then
    return nil
  end

  -- Separate name and version from folder (e.g. actionpack-8.1.3.1 or i18n-1.8.11 or foo_bar-1.2.3.alpha.1)
  -- Gem versions typically start after the last hyphen followed by a digit
  local gem_name, gem_version = gem_folder:match("^(.-)%-(%d[%w%.%-%_]*)$")
  if not gem_name or not gem_version then
    return nil
  end

  return {
    gem_name = gem_name,
    gem_version = gem_version,
    relative_path = rel_path,
  }
end

--- Parse bundler git gem path:
--- Matches patterns like:
---   .../bundler/gems/<gem_name>-<revision>/<relative_path>
--- Examples:
---   .../ruby/3.3.0/bundler/gems/flux-jobs-9e92dbf2fd24/app/models/job_run.rb
---@param fpath string
---@return table? { gem_name: string, revision: string, relative_path: string }
function M.parse_bundler_git_path(fpath)
  local p = norm(fpath)
  local folder, rel_path = p:match("/bundler/gems/([^/]+)/(.-)$")
  if not folder or not rel_path or rel_path == "" then
    return nil
  end

  -- Separate name and revision: e.g. flux-jobs-9e92dbf2fd24
  -- Revision is usually hex characters (SHA) after the last hyphen
  local name, rev = folder:match("^(.-)%-([%da-fA-F]+)$")
  if not name or not rev then
    -- Fallback: any string after last hyphen
    name, rev = folder:match("^(.-)%-(.*)$")
  end

  if not name or not rev then
    return nil
  end

  return {
    gem_name = name,
    revision = rev,
    relative_path = rel_path,
  }
end

--- Parse Ruby stdlib path:
--- Matches patterns like:
---   /usr/lib/x86_64-linux-gnu/ruby/3.3.0/delegate.rb
---   /usr/lib/ruby/3.3.0/timeout.rb
---   /usr/local/lib/ruby/3.3.0/net/http.rb
--- Or any file ending in .rb under ruby/<version>/
---@param fpath string
---@return table? { stdlib_path: string, module_name: string }
function M.parse_stdlib_path(fpath)
  local p = norm(fpath)
  -- Must not be in /gems/ or /bundler/gems/
  if p:find("/gems/") or p:find("/bundler/gems/") then
    return nil
  end

  -- Look for /ruby/%d+%.%d+%.%d+/(.*%.rb)$ or /ruby/%d+%.%d+/(.*%.rb)$
  local rel = p:match("/ruby/%d+%.%d+[%d%.]*/(.-%.rb)$")
  if rel and rel ~= "" then
    return {
      stdlib_path = rel,
      module_name = rel:gsub("%.rb$", ""),
    }
  end

  -- Or if it's under /lib/ruby/(.*%.rb)$
  local rel2 = p:match("/lib/ruby/(.-%.rb)$")
  if rel2 and rel2 ~= "" and not rel2:find("^gems/") then
    -- strip version component if present (e.g. 3.3.0/delegate.rb -> delegate.rb)
    local stripped = rel2:gsub("^%d+%.%d+[%d%.]*/", "")
    return {
      stdlib_path = stripped,
      module_name = stripped:gsub("%.rb$", ""),
    }
  end

  return nil
end

return M
