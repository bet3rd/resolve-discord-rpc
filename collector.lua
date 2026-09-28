-- Runs under fuscript, DaVinci Resolve's script interpreter, and reports what
-- the user is doing in Resolve. Prints one JSON line to stdout whenever that
-- changes; resolve-rpc.pl turns those lines into a Discord presence.
--
-- Exits when Resolve can't be reached; resolve-rpc.pl restarts it as needed.

local POLL_INTERVAL = 1
local CONNECT_ATTEMPTS = 30

-- Minimal JSON encoder for the flat tables below.
local function encode(value)
  local t = type(value)
  if t == 'nil' then
    return 'null'
  elseif t == 'boolean' then
    return value and 'true' or 'false'
  elseif t == 'number' then
    if value == math.floor(value) then
      return string.format('%.0f', value)
    end
    return tostring(value)
  elseif t == 'string' then
    return '"' .. value:gsub('[%c"\\]', function(c)
      if c == '"' then return '\\"' end
      if c == '\\' then return '\\\\' end
      if c == '\n' then return '\\n' end
      if c == '\t' then return '\\t' end
      return string.format('\\u%04x', c:byte())
    end) .. '"'
  elseif t == 'table' then
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = encode(tostring(k)) .. ':' .. encode(value[k])
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  error('cannot encode ' .. t)
end

-- Resolve is still starting up for a while after its process appears.
local resolve
for _ = 1, CONNECT_ATTEMPTS do
  resolve = Resolve()
  if resolve then break end
  bmd.wait(1)
end
if not resolve then
  io.stderr:write('Could not connect to DaVinci Resolve. Is external scripting enabled?\n')
  os.exit(1)
end

local function renderStatus(project)
  if not project:IsRenderingInProgress() then return nil end

  local render = {}
  for _, job in ipairs(project:GetRenderJobList() or {}) do
    local status = project:GetRenderJobStatus(job.JobId)
    if status and status.JobStatus == 'Rendering' then
      render.percent = status.CompletionPercentage
      render.timeline = job.TimelineName
      break
    end
  end
  return render
end

local function snapshot()
  local info = { page = resolve:GetCurrentPage() }

  local project = resolve:GetProjectManager():GetCurrentProject()
  if project then
    info.project = project:GetName()
    local timeline = project:GetCurrentTimeline()
    if timeline then info.timeline = timeline:GetName() end
    info.render = renderStatus(project)
  end

  return info
end

local last
while true do
  local ok, info = pcall(snapshot)
  if not ok or not info.page and not info.project then
    io.stderr:write('Lost connection to DaVinci Resolve: ', tostring(info), '\n')
    os.exit(1)
  end

  local line = encode(info)
  if line ~= last then
    io.write(line, '\n')
    io.stdout:flush()
    last = line
  end

  bmd.wait(POLL_INTERVAL)
end
