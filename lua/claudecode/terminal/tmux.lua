--- Terminal provider for tmux split panes
-- @module claudecode.terminal.tmux

--- @type TerminalProvider
local M = {}

local logger = require("claudecode.logger")

local state = { tmux_pane_id = nil, config = nil }

--- Check if we're running inside tmux
--- @return boolean
function M.is_available()
  -- Check if vim object exists and has env property
  if vim and vim.env then
    return vim.env.TMUX ~= nil
  end
  -- Fallback to os.getenv
  return os.getenv("TMUX") ~= nil
end

--- Setup the tmux provider
--- @param config table Configuration from terminal.lua
function M.setup(config)
  state.config = config
end

--- Get the current tmux pane ID
--- @return string|nil
local function get_current_pane()
  local result = vim.system({ "tmux", "display-message", "-p", "#{pane_id}" }, { text = true }):wait()
  if result.code == 0 and result.stdout then
    return vim.trim(result.stdout)
  end
  return nil
end

--- Check if a tmux pane exists
--- @param pane_id string
--- @return boolean
local function pane_exists(pane_id)
  if not pane_id then
    return false
  end
  -- Get all pane IDs and check if our pane_id exists
  local result = vim.system({ "tmux", "list-panes", "-a", "-F", "#{pane_id}" }, { text = true }):wait()
  if result.code == 0 and result.stdout then
    -- Check if pane_id is in the output
    for line in result.stdout:gmatch("[^\n]+") do
      if vim.trim(line) == pane_id then
        return true
      end
    end
  end
  return false
end

--- Focus a tmux pane
--- @param pane_id string
local function focus_pane(pane_id)
  if pane_id then
    vim.system({ "tmux", "select-pane", "-t", pane_id }):wait()
  end
end

--- Kill a tmux pane
--- @param pane_id string
local function kill_pane(pane_id)
  if pane_id and pane_exists(pane_id) then
    vim.system({ "tmux", "kill-pane", "-t", pane_id }):wait()
  end
end

--- Check if current focus is on the terminal pane
--- @return boolean
local function is_terminal_focused()
  if not state.tmux_pane_id or not pane_exists(state.tmux_pane_id) then
    return false
  end
  local current = get_current_pane()
  return current == state.tmux_pane_id
end

--- Build environment flags for tmux command
--- @param env_table table
--- @return table Array of environment flag arguments
local function build_env_flags(env_table)
  local env_flags = {}
  for k, v in pairs(env_table or {}) do
    table.insert(env_flags, "-e")
    table.insert(env_flags, string.format("%s=%s", k, v))
  end
  return env_flags
end

--- Open a new tmux pane with claude command
--- @param cmd string The command to run
--- @param env table Environment variables
--- @param config table Terminal configuration
--- @param focus boolean Whether to focus the terminal after opening
function M.open(cmd, env, config, focus)
  focus = focus ~= false -- Default to true

  -- If pane already exists and is visible, just focus it if requested
  if state.tmux_pane_id and pane_exists(state.tmux_pane_id) then
    if focus then
      focus_pane(state.tmux_pane_id)
    end
    return
  end

  -- Save original pane ID before creating new one
  local original_pane_id = get_current_pane()

  -- Build environment flags
  local env_flags = build_env_flags(env)

  -- Build tmux command arguments
  local args = { "tmux", "split-window", "-P", "-F", "#{pane_id}" }

  -- Add split direction
  if config.tmux_split_direction == "v" then
    table.insert(args, "-v")
  else
    table.insert(args, "-h")
  end

  -- Add size
  local size_str = config.tmux_pane_size or "30%"
  if string.find(size_str, "%%") then
    -- Remove % and use -p for percentage
    table.insert(args, "-p")
    table.insert(args, tostring(string.gsub(size_str, "%%", "")))
  else
    -- Use -l for fixed size
    table.insert(args, "-l")
    table.insert(args, size_str)
  end

  -- Add position flag if needed
  if config.split_side == "left" then
    table.insert(args, "-b")
  end

  -- Add environment variables
  for _, flag in ipairs(env_flags) do
    table.insert(args, flag)
  end

  -- Add working directory
  table.insert(args, "-c")
  table.insert(args, vim.fn.getcwd())

  -- Add the command to run
  -- If cmd contains spaces, we need to pass it as a single argument
  table.insert(args, cmd)

  logger.debug("terminal.tmux", "Opening tmux pane with args: " .. vim.inspect(args))

  -- Execute the command using vim.system
  local result = vim.system(args, { text = true }):wait()
  if result.code == 0 and result.stdout and vim.trim(result.stdout) ~= "" then
    state.tmux_pane_id = vim.trim(result.stdout)
    logger.debug("terminal.tmux", "Created tmux pane: " .. (state.tmux_pane_id or "nil"))
    -- Return focus to original pane if not focusing the new one
    if not focus and original_pane_id then
      focus_pane(original_pane_id)
    end
  else
    logger.error(
      "terminal.tmux",
      "Failed to create tmux pane: " .. vim.inspect(args) .. " Error: " .. (result.stderr or "unknown")
    )
  end
end

--- Close the managed tmux pane
function M.close()
  if state.tmux_pane_id then
    kill_pane(state.tmux_pane_id)
    state.tmux_pane_id = nil
  end
end

--- Simple toggle: show/hide the tmux pane
--- @param cmd string The command to run
--- @param env table Environment variables
--- @param config table Terminal configuration
function M.simple_toggle(cmd, env, config)
  if state.tmux_pane_id and pane_exists(state.tmux_pane_id) then
    -- Pane exists, close it
    M.close()
  else
    -- Pane doesn't exist, open it
    M.open(cmd, env, config, true)
  end
end

--- Smart focus toggle: switch to terminal if not focused, hide if currently focused
--- @param cmd string The command to run
--- @param env table Environment variables
--- @param config table Terminal configuration
function M.focus_toggle(cmd, env, config)
  if state.tmux_pane_id and pane_exists(state.tmux_pane_id) then
    if is_terminal_focused() then
      -- Terminal is focused, close it
      M.close()
    else
      -- Terminal exists but not focused, focus it
      focus_pane(state.tmux_pane_id)
    end
  else
    -- Terminal doesn't exist, open it with focus
    M.open(cmd, env, config, true)
  end
end

--- Get the buffer number of the active terminal (not applicable for tmux)
--- @return nil Always returns nil as tmux panes don't have Neovim buffers
function M.get_active_bufnr()
  -- tmux panes don't have associated Neovim buffers
  return nil
end

return M
