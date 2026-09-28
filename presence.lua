-- Discord Rich Presence for DaVinci Resolve, in a single script.
--
-- Runs under fuscript (Resolve's script interpreter) for as long as the user
-- is logged in: it waits for Resolve to open, shows what's happening in it on
-- Discord, and clears the presence when Resolve quits. Talks to Discord
-- through discord_ipc.lua, which uses LuaJIT's FFI, so the same script works
-- on macOS and Windows with nothing else installed.

local scriptDir = debug.getinfo(1, 'S').source:match('^@(.*[/\\])') or ''
local ipc = dofile(scriptDir .. 'discord_ipc.lua')

-- Discord application "DaVinci Resolve"; its name is what shows after
-- "Playing". Can be overridden with "clientId" in config.json.
local DEFAULT_CLIENT_ID = '1554134762598310018'
-- Logo by Blackmagic Design, via Wikimedia Commons (CC BY-SA 4.0).
local DEFAULT_LARGE_IMAGE = 'https://upload.wikimedia.org/wikipedia/commons/4/4d/DaVinci_Resolve_Studio.png'

local POLL_INTERVAL = 1
local WAIT_FOR_RESOLVE_INTERVAL = 5
local RECONNECT_DELAY = 5
-- Discord rate-limits SET_ACTIVITY to about 5 updates per 20 seconds.
local MIN_UPDATE_INTERVAL = 4

-- Plain descriptions rather than page names: most people seeing the status
-- don't know what the "Fairlight" or "Deliver" page is.
local PAGE_ACTIVITY = {
  media = 'Organizing media',
  cut = 'Editing a video',
  edit = 'Editing a video',
  fusion = 'Creating visual effects',
  color = 'Color grading',
  fairlight = 'Mixing audio',
  deliver = 'Preparing an export',
  photo = 'Editing photos',
}

local function log(...)
  io.write(os.date('[%Y-%m-%d %H:%M:%S] '), table.concat({ ... }), '\n')
  io.stdout:flush()
end

-- Config -----------------------------------------------------------------------

local configPath = os.getenv('APPDATA')
  and os.getenv('APPDATA') .. '\\resolve-discord-rpc\\config.json'
  or os.getenv('HOME') .. '/Library/Application Support/resolve-discord-rpc/config.json'

-- config.json is a flat object of strings and booleans, so a pattern match
-- is enough to read it.
local function loadConfig()
  local config = {
    clientId = DEFAULT_CLIENT_ID,
    largeImage = DEFAULT_LARGE_IMAGE,
    showProject = true,
    showTimeline = false,
  }
  local file = io.open(configPath, 'r')
  if not file then return config end
  local raw = file:read('*a')
  file:close()

  for key, value in raw:gmatch('"([%w_]+)"%s*:%s*("?[^,}\n]-"?)%s*[,}\n]') do
    if value == 'true' then
      config[key] = true
    elseif value == 'false' then
      config[key] = false
    elseif value:match('^".*"$') then
      config[key] = value:sub(2, -2)
    end
  end
  return config
end

-- Resolve ------------------------------------------------------------------------

local function renderStatus(project)
  if not project:IsRenderingInProgress() then return nil end

  local render = {}
  for _, job in ipairs(project:GetRenderJobList() or {}) do
    local status = project:GetRenderJobStatus(job.JobId)
    if status and status.JobStatus == 'Rendering' then
      render.percent = status.CompletionPercentage
      break
    end
  end
  return render
end

local function snapshot(resolve)
  local info = { page = resolve:GetCurrentPage() }

  local project = resolve:GetProjectManager():GetCurrentProject()
  if project then
    info.project = project:GetName()
    local timeline = project:GetCurrentTimeline()
    if timeline then info.timeline = timeline:GetName() end
    info.render = renderStatus(project)
  end

  if not info.page and not info.project then error('no answer from Resolve') end
  return info
end

-- Discord rejects details/state/text fields outside 2..128 characters. Lua
-- strings are bytes, so trim on a UTF-8 character boundary.
local function fitText(text)
  if not text or text == '' then return nil end
  if #text > 128 then
    text = text:sub(1, 125):gsub('[\128-\191]*[\192-\255]?[\128-\191]*$', '') .. '...'
  end
  while #text < 2 do text = text .. ' ' end
  return text
end

local function buildActivity(info, config, sessionStart)
  local activity = {
    state = PAGE_ACTIVITY[info.page or ''] or 'Working in DaVinci Resolve',
    timestamps = { start = sessionStart },
    assets = { large_text = 'DaVinci Resolve' },
  }
  if config.largeImage ~= '' then activity.assets.large_image = config.largeImage end

  if info.render then
    activity.state = info.render.percent
      and string.format('Rendering · %d%%', math.floor(info.render.percent))
      or 'Rendering'
  end

  local details = {}
  if config.showProject and info.project then details[#details + 1] = info.project end
  if config.showTimeline and info.timeline then details[#details + 1] = info.timeline end
  activity.details = fitText(table.concat(details, ' · '))
  activity.state = fitText(activity.state)
  return activity
end

-- Main loop ------------------------------------------------------------------------

local pid = ipc.getpid()
local conn, connClientId
local nextConnectAt = 0
local lastSent, lastSentAt = nil, 0
local lastError

local function dropDiscord(reason)
  if conn then
    log('Disconnected from Discord: ', reason)
    conn:close()
  end
  conn, lastSent = nil, nil
  nextConnectAt = os.time() + RECONNECT_DELAY
end

local function runSession(resolve)
  local sessionStart = os.time() * 1000
  log('Connected to DaVinci Resolve')

  while true do
    local ok, info = pcall(snapshot, resolve)
    if not ok then
      log('DaVinci Resolve closed')
      return
    end

    local config = loadConfig()
    if conn and connClientId ~= config.clientId then dropDiscord('client id changed') end

    if not conn and os.time() >= nextConnectAt then
      local err
      conn, err = ipc.connect(config.clientId)
      if conn then
        connClientId = config.clientId
        lastError = nil
        log('Connected to Discord (', conn.path, ') as ', tostring(conn.user))
      else
        nextConnectAt = os.time() + RECONNECT_DELAY
        if err ~= lastError then log(err) end
        lastError = err
      end
    end

    if conn and os.time() - lastSentAt >= MIN_UPDATE_INTERVAL then
      local activity = buildActivity(info, config, sessionStart)
      local key = ipc.encode(activity)
      if key ~= lastSent then
        if conn:setActivity(pid, activity) then
          log('Set activity: ', key)
          lastSent, lastSentAt = key, os.time()
        end
      end
    end

    if conn then
      local alive, why = conn:poll(POLL_INTERVAL)
      if not alive then dropDiscord(why) end
      if conn and conn.lastError then
        log('Discord error: ', conn.lastError)
        conn.lastError = nil
      end
    else
      bmd.wait(POLL_INTERVAL)
    end
  end
end

-- The launch agent appends stdout to this log; start it over once it's big.
local MAX_LOG_SIZE = 1024 * 1024
local logPath = configPath:gsub('config%.json$', 'presence.log')
local logFile = io.open(logPath, 'r')
if logFile then
  local size = logFile:seek('end')
  logFile:close()
  if size > MAX_LOG_SIZE then io.open(logPath, 'w'):close() end
end

log('Started')
while true do
  local resolve = Resolve()
  if resolve then
    runSession(resolve)
    -- Closing the connection makes Discord clear the presence.
    dropDiscord('DaVinci Resolve closed')
    nextConnectAt = 0
  end
  bmd.wait(WAIT_FOR_RESOLVE_INTERVAL)
end
