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

-- Small page icons: Twemoji (CC BY 4.0), pinned to a release so the images
-- can't change underneath us.
local ICON_BASE = 'https://cdn.jsdelivr.net/gh/jdecked/twemoji@17.0.3/assets/72x72/'

local POLL_INTERVAL = 1
local WAIT_FOR_RESOLVE_INTERVAL = 5
local RECONNECT_DELAY = 5
-- Discord rate-limits SET_ACTIVITY to about 5 updates per 20 seconds.
local MIN_UPDATE_INTERVAL = 4
local SAVE_PROJECT_TIME_INTERVAL = 30
local CLIP_ORDER_REFRESH_INTERVAL = 30
-- A gap this long between polls means the computer slept; don't count it.
local MAX_POLL_GAP = 30

-- The activity line uses plain descriptions rather than page names: most
-- people seeing the status don't know what the "Fairlight" page is. The page
-- name only appears when hovering the icon.
local PAGES = {
  media = { activity = 'Organizing media', title = 'Media page', icon = '1f5c2' },
  cut = { activity = 'Editing a video', title = 'Cut page', icon = '2702' },
  edit = { activity = 'Editing a video', title = 'Edit page', icon = '1f3ac' },
  fusion = { activity = 'Creating visual effects', title = 'Fusion page', icon = '2728' },
  color = { activity = 'Color grading', title = 'Color page', icon = '1f3a8' },
  fairlight = { activity = 'Mixing audio', title = 'Fairlight page', icon = '1f39a' },
  deliver = { activity = 'Preparing an export', title = 'Deliver page', icon = '1f4e4' },
  photo = { activity = 'Editing photos', title = 'Photo page', icon = '1f4f7' },
}
local RENDER_ICON = '23f3'

local function log(...)
  io.write(os.date('[%Y-%m-%d %H:%M:%S] '), table.concat({ ... }), '\n')
  io.stdout:flush()
end

-- Config -----------------------------------------------------------------------

local dataDir = os.getenv('RESOLVE_RPC_DATA_DIR')
  or os.getenv('APPDATA') and os.getenv('APPDATA') .. '\\resolve-discord-rpc\\'
  or os.getenv('HOME') .. '/Library/Application Support/resolve-discord-rpc/'
local configPath = dataDir .. 'config.json'

-- config.json is a flat object of strings and booleans, so a pattern match
-- is enough to read it.
local function loadConfig()
  local config = {
    clientId = DEFAULT_CLIENT_ID,
    largeImage = DEFAULT_LARGE_IMAGE,
    showProject = true,
    showTimeline = true,
    showClipPosition = true,
    showPageIcons = true,
    projectTimer = true,
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

-- Time spent per project ------------------------------------------------------------

-- project-time.tsv: one line per project, "<unique id>\t<seconds>\t<name>".
-- The name is only there to make the file readable.
local timesPath = dataDir .. 'project-time.tsv'
local projectTimes = {}

local function loadProjectTimes()
  local file = io.open(timesPath, 'r')
  if not file then return end
  for line in file:lines() do
    local id, seconds, name = line:match('^([^\t]+)\t(%d+)\t?(.*)$')
    if id then projectTimes[id] = { seconds = tonumber(seconds), name = name } end
  end
  file:close()
end

local function saveProjectTimes()
  local ids = {}
  for id in pairs(projectTimes) do ids[#ids + 1] = id end
  table.sort(ids)

  local file = io.open(timesPath .. '.tmp', 'w')
  if not file then return end
  for _, id in ipairs(ids) do
    local entry = projectTimes[id]
    file:write(id, '\t', string.format('%d', entry.seconds), '\t', (entry.name or ''):gsub('[\t\r\n]', ' '), '\n')
  end
  file:close()
  os.remove(timesPath)
  os.rename(timesPath .. '.tmp', timesPath)
end

-- The project being timed, and when its timer "started": now minus the time
-- already spent on it, so Discord's elapsed timer shows the project's total.
local timed
local lastTrackedAt, lastSavedAt = 0, 0

local function trackProjectTime(info)
  local now = os.time()
  if timed and timed.id ~= info.projectId then
    timed = nil
    saveProjectTimes()
    lastSavedAt = now
  end

  if info.projectId then
    if not timed then
      local stored = projectTimes[info.projectId]
      timed = { id = info.projectId, startedAt = now - (stored and stored.seconds or 0) }
    elseif now - lastTrackedAt > MAX_POLL_GAP then
      timed.startedAt = timed.startedAt + (now - lastTrackedAt)
    end
    projectTimes[timed.id] = { seconds = now - timed.startedAt, name = info.project }
  end
  lastTrackedAt = now

  if now - lastSavedAt >= SAVE_PROJECT_TIME_INTERVAL then
    saveProjectTimes()
    lastSavedAt = now
  end
  return timed and timed.startedAt
end

local function stopProjectTime()
  if timed then saveProjectTimes() end
  timed = nil
end

-- Resolve ------------------------------------------------------------------------

-- Position of the clip under the playhead among the clips the Color page
-- lists: every video item that can be graded, i.e. has a node graph (effects
-- such as a Fusion camera shake don't). Listing every clip takes a few calls
-- per clip, so the order is cached per timeline.
local clipOrder = { positions = {}, total = 0, builtAt = 0 }

local function clipPosition(timeline)
  local item = timeline:GetCurrentVideoItem()
  if not item then return nil end
  local id = item:GetUniqueId()
  local timelineId = timeline:GetUniqueId()

  if clipOrder.timelineId ~= timelineId or clipOrder.positions[id] == nil
      or os.time() - clipOrder.builtAt >= CLIP_ORDER_REFRESH_INTERVAL then
    local clips = {}
    for track = 1, timeline:GetTrackCount('video') or 0 do
      for _, clip in ipairs(timeline:GetItemListInTrack('video', track) or {}) do
        clips[#clips + 1] = {
          id = clip:GetUniqueId(),
          start = clip:GetStart(),
          track = track,
          gradable = clip:GetNodeGraph() ~= nil,
        }
      end
    end
    table.sort(clips, function(a, b)
      if a.start ~= b.start then return a.start < b.start end
      return a.track < b.track
    end)
    -- Ungradable items map to false, so selecting one doesn't trigger a
    -- rebuild on every poll.
    local positions, total = {}, 0
    for _, clip in ipairs(clips) do
      if clip.gradable then
        total = total + 1
        positions[clip.id] = total
      else
        positions[clip.id] = false
      end
    end
    clipOrder = { timelineId = timelineId, positions = positions, total = total, builtAt = os.time() }
  end

  local index = clipOrder.positions[id]
  if index then return { index = index, total = clipOrder.total } end
end

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

local function snapshot(resolve, config)
  local info = { page = resolve:GetCurrentPage() }

  local project = resolve:GetProjectManager():GetCurrentProject()
  if project then
    info.project = project:GetName()
    info.projectId = project:GetUniqueId()
    local timeline = project:GetCurrentTimeline()
    if timeline then
      info.timeline = timeline:GetName()
      if info.page == 'color' and config.showClipPosition then
        info.clip = clipPosition(timeline)
      end
    end
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

-- `startedAt` is in seconds: when the session or the project's timer started.
local function buildActivity(info, config, startedAt)
  local page = PAGES[info.page or '']
  local state = page and page.activity or 'Working in DaVinci Resolve'
  local icon, iconText = page and page.icon, page and page.title

  if info.render then
    state = info.render.percent
      and string.format('Rendering · %d%%', math.floor(info.render.percent))
      or 'Rendering'
    icon, iconText = RENDER_ICON, 'Rendering'
  elseif (info.page == 'edit' or info.page == 'cut') and config.showTimeline and info.timeline then
    state = state .. ' · ' .. info.timeline
  elseif info.page == 'color' and info.clip then
    state = string.format('%s · clip %d of %d', state, info.clip.index, info.clip.total)
  end

  local activity = {
    details = config.showProject and fitText(info.project) or nil,
    state = fitText(state),
    timestamps = { start = startedAt * 1000 },
    assets = { large_text = 'DaVinci Resolve' },
  }
  if config.largeImage ~= '' then activity.assets.large_image = config.largeImage end
  if config.showPageIcons and icon then
    activity.assets.small_image = ICON_BASE .. icon .. '.png'
    activity.assets.small_text = iconText
  end
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
  local sessionStart = os.time()
  log('Connected to DaVinci Resolve')

  while true do
    local config = loadConfig()
    local ok, info = pcall(snapshot, resolve, config)
    if not ok then
      log('DaVinci Resolve closed')
      stopProjectTime()
      return
    end

    local projectStart = trackProjectTime(info)
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
      local startedAt = config.projectTimer and projectStart or sessionStart
      local activity = buildActivity(info, config, startedAt)
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

-- Lets tests load this file for its functions without starting the loop.
if os.getenv('RESOLVE_RPC_TEST') then
  return {
    buildActivity = buildActivity,
    snapshot = snapshot,
    loadConfig = loadConfig,
    trackProjectTime = trackProjectTime,
    stopProjectTime = stopProjectTime,
    loadProjectTimes = loadProjectTimes,
    projectTimes = function() return projectTimes end,
  }
end

loadProjectTimes()

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
