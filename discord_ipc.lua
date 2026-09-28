-- Discord IPC client in pure LuaJIT, using the FFI to reach the OS directly:
-- a Unix domain socket on macOS/Linux, a named pipe on Windows. Runs under
-- fuscript, which is LuaJIT with the FFI enabled.
--
--   local ipc = dofile('discord_ipc.lua')
--   local conn = assert(ipc.connect(clientId))
--   conn:setActivity(pid, activity)   -- activity = nil clears it
--   local ok, err = conn:poll(1)      -- waits up to 1 s, handles pings
--   conn:close()

local ffi = require('ffi')
local bit = require('bit')

local OP_HANDSHAKE, OP_FRAME, OP_CLOSE, OP_PING, OP_PONG = 0, 1, 2, 3, 4

local M = {}

-- JSON encoder for the tables sent to Discord.
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
M.encode = encode

local function u32le(n)
  return string.char(
    bit.band(n, 0xff), bit.band(bit.rshift(n, 8), 0xff),
    bit.band(bit.rshift(n, 16), 0xff), bit.band(bit.rshift(n, 24), 0xff))
end

local function readU32le(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return a + b * 0x100 + c * 0x10000 + d * 0x1000000
end

-- Transports. Each returns an object with write(data) -> ok,
-- read(timeoutSec) -> data ('' on timeout) or nil on error, and close().

local transport

if ffi.os == 'Windows' then
  ffi.cdef [[
    typedef void *HANDLE;
    HANDLE CreateFileA(const char *name, uint32_t access, uint32_t share, void *security,
                       uint32_t disposition, uint32_t flags, HANDLE templateFile);
    int WriteFile(HANDLE h, const void *buf, uint32_t n, uint32_t *written, void *overlapped);
    int ReadFile(HANDLE h, void *buf, uint32_t n, uint32_t *read, void *overlapped);
    int PeekNamedPipe(HANDLE h, void *buf, uint32_t n, uint32_t *read, uint32_t *available, uint32_t *left);
    int CloseHandle(HANDLE h);
    uint32_t GetCurrentProcessId(void);
    void Sleep(uint32_t ms);
  ]]
  local C = ffi.C
  local GENERIC_READ_WRITE = 0xC0000000
  local OPEN_EXISTING = 3
  local INVALID_HANDLE = ffi.cast('HANDLE', -1)

  M.getpid = function() return tonumber(C.GetCurrentProcessId()) end

  transport = function()
    for i = 0, 9 do
      local h = C.CreateFileA('\\\\.\\pipe\\discord-ipc-' .. i, GENERIC_READ_WRITE, 0, nil, OPEN_EXISTING, 0, nil)
      if h ~= INVALID_HANDLE then
        local count = ffi.new('uint32_t[1]')
        local available = ffi.new('uint32_t[1]')
        local pipe = {}

        function pipe.write(data)
          return C.WriteFile(h, data, #data, count, nil) ~= 0 and count[0] == #data
        end

        -- ReadFile on a pipe blocks, so only read what PeekNamedPipe says is there.
        function pipe.read(timeout)
          local deadline = os.clock() + timeout
          repeat
            if C.PeekNamedPipe(h, nil, 0, nil, available, nil) == 0 then return nil end
            if available[0] > 0 then
              local buf = ffi.new('uint8_t[?]', available[0])
              if C.ReadFile(h, buf, available[0], count, nil) == 0 then return nil end
              return ffi.string(buf, count[0])
            end
            C.Sleep(20)
          until os.clock() >= deadline
          return ''
        end

        function pipe.close() C.CloseHandle(h) end

        return pipe, '\\\\.\\pipe\\discord-ipc-' .. i
      end
    end
    return nil, 'Discord is not running (no IPC pipe found)'
  end
else
  ffi.cdef [[
    int socket(int domain, int type, int protocol);
    int connect(int fd, const void *addr, uint32_t len);
    int setsockopt(int fd, int level, int name, const void *value, uint32_t len);
    long send(int fd, const void *buf, size_t n, int flags);
    long recv(int fd, void *buf, size_t n, int flags);
    int close(int fd);
    struct pollfd { int fd; short events; short revents; };
    int poll(struct pollfd *fds, unsigned long count, int timeout);
    int getpid(void);
    char *getenv(const char *name);
  ]]
  local C = ffi.C
  local isMac = ffi.os == 'OSX'
  local AF_UNIX, SOCK_STREAM, POLLIN = 1, 1, 1
  -- Without these, writing to a socket Discord closed kills the process.
  local SOL_SOCKET, SO_NOSIGPIPE = 0xffff, 0x1022
  local MSG_NOSIGNAL = isMac and 0 or 0x4000

  if isMac then
    ffi.cdef [[ struct sockaddr_un { uint8_t sun_len; uint8_t sun_family; char sun_path[104]; }; ]]
  else
    ffi.cdef [[ struct sockaddr_un { unsigned short sun_family; char sun_path[108]; }; ]]
  end

  M.getpid = function() return tonumber(C.getpid()) end

  local function socketDirs()
    local dirs = {}
    for _, name in ipairs({ 'XDG_RUNTIME_DIR', 'TMPDIR', 'TMP', 'TEMP' }) do
      local value = C.getenv(name)
      if value ~= nil then dirs[#dirs + 1] = (ffi.string(value):gsub('/+$', '')) end
    end
    dirs[#dirs + 1] = '/tmp'
    return dirs
  end

  transport = function()
    for _, dir in ipairs(socketDirs()) do
      for i = 0, 9 do
        local path = dir .. '/discord-ipc-' .. i
        local fd = C.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 then return nil, 'socket() failed' end

        local addr = ffi.new('struct sockaddr_un')
        addr.sun_family = AF_UNIX
        if isMac then addr.sun_len = ffi.sizeof(addr) end
        ffi.copy(addr.sun_path, path)

        if C.connect(fd, addr, ffi.sizeof(addr)) == 0 then
          if isMac then
            C.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, ffi.new('int[1]', 1), 4)
          end
          local pfd = ffi.new('struct pollfd[1]')
          pfd[0].fd = fd
          pfd[0].events = POLLIN
          local buf = ffi.new('uint8_t[65536]')
          local sock = {}

          function sock.write(data)
            return C.send(fd, data, #data, MSG_NOSIGNAL) == #data
          end

          function sock.read(timeout)
            local ready = C.poll(pfd, 1, math.floor(timeout * 1000))
            if ready < 0 then return nil end
            if ready == 0 then return '' end
            local n = C.recv(fd, buf, 65536, 0)
            if n <= 0 then return nil end
            return ffi.string(buf, n)
          end

          function sock.close() C.close(fd) end

          return sock, path
        end
        C.close(fd)
      end
    end
    return nil, 'Discord is not running (no IPC socket found)'
  end
end

-- Connection ------------------------------------------------------------------

local Connection = {}
Connection.__index = Connection

function Connection:send(op, payload)
  local body = encode(payload)
  if not self.io.write(u32le(op) .. u32le(#body) .. body) then
    self:close()
    return false
  end
  return true
end

-- Reads whatever Discord has sent, waiting up to `timeout` seconds. Returns
-- false and a reason once the connection is gone.
function Connection:poll(timeout)
  if not self.io then return false, 'closed' end
  local data = self.io.read(timeout or 0)
  if not data then
    self:close()
    return false, 'connection lost'
  end
  self.buffer = self.buffer .. data

  while #self.buffer >= 8 do
    local op, len = readU32le(self.buffer, 1), readU32le(self.buffer, 5)
    if #self.buffer < 8 + len then break end
    local body = self.buffer:sub(9, 8 + len)
    self.buffer = self.buffer:sub(9 + len)

    if op == OP_PING then
      self.io.write(u32le(OP_PONG) .. u32le(#body) .. body)
    elseif op == OP_CLOSE then
      self:close()
      return false, 'closed by Discord: ' .. body
    elseif op == OP_FRAME then
      if body:find('"evt":"READY"', 1, true) then
        self.ready = true
        self.user = body:match('"username":"([^"]*)"')
      elseif body:find('"evt":"ERROR"', 1, true) then
        self.lastError = body:match('"message":"([^"]*)"') or body
      end
    end
  end
  return true
end

function Connection:setActivity(pid, activity)
  self.nonce = self.nonce + 1
  return self:send(OP_FRAME, {
    cmd = 'SET_ACTIVITY',
    args = { pid = pid, activity = activity },
    nonce = tostring(self.nonce),
  })
end

function Connection:close()
  if self.io then self.io.close() end
  self.io = nil
  self.ready = false
end

-- Connects and handshakes; waits up to 5 s for Discord's READY.
function M.connect(clientId)
  local channel, where = transport()
  if not channel then return nil, where end

  local conn = setmetatable({ io = channel, buffer = '', nonce = 0, ready = false, path = where }, Connection)
  if not conn:send(OP_HANDSHAKE, { v = 1, client_id = clientId }) then
    return nil, 'handshake failed'
  end
  for _ = 1, 50 do
    local ok, err = conn:poll(0.1)
    if not ok then return nil, err end
    if conn.ready then return conn end
  end
  conn:close()
  return nil, 'Discord did not answer the handshake'
end

return M
