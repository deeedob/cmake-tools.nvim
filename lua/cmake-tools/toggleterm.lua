local has_toggleterm, toggleterm = pcall(require, "toggleterm.terminal")
local log = require("cmake-tools.log")

---@class M : executor, runner
local M = {
  executor = {
    term = nil,
    cmd = nil,
    is_running = false,
    has_error = false,

    watcher = nil,
    watcher_cnt = 0,
    cmd_pid = nil,
  },
  runner = {
    term = nil,
    cmd = nil,
    is_running = false,
    has_error = false,

    watcher = nil,
    watcher_cnt = 0,
    cmd_pid = nil,
  },
}

local function trim_str(s)
  return s:match("^%s*(.-)%s*$")
end

local function empty(s)
  return s == nil or s == ""
end

local function extract_job_id(chunk)
  local job_id = string.match(chunk, "job_id=<(%d+)>")
  return job_id
end

function M.show(opts)
  if M[opts.type].term then
    M[opts.type].term:open()
  end
end

function M.close(opts)
  if M[opts.type].term then
    M[opts.type].term:close()
  end
end

function M.run(cmd, env_script, env, args, cwd, opts, on_exit, on_output)
  if opts.type ~= "executor" and opts.type ~= "runner" then
    log.error("Terminal type must be 'executor' or 'runner', got: " .. opts.type)
    return
  end

  if M.has_active_job(opts) then
    return
  end

  if empty(cmd) then
    log.error("cmd is empty")
    return
  end

  -- check if path is dir and expand
  if cwd and vim.fn.isdirectory(vim.fn.expand(cwd)) == 0 then
    cwd = nil
  end

  -- Construct the command. Wrap it inside a new shell and print the pid of
  -- this process, so that we can later look for that information.
  local cmd_line = 'sh -c \'echo "job_id=<$$>"; exec ' .. trim_str(cmd)
  for k, v in pairs(args) do
    if type(v) == "string" and not empty(v) then
      cmd_line = cmd_line .. " " .. trim_str(v)
    else
      log.error("Arg error: (" .. k(", ") .. v .. ")")
      return
    end
  end
  cmd_line = cmd_line .. "'"
  M[opts.type].cmd = cmd_line

  if M[opts.type].term then
    -- Reuse
    M[opts.type].term:change_dir(cwd, true)
  else
    -- Create new
    M[opts.type].watcher = vim.uv.new_timer()
    M[opts.type].term = toggleterm.Terminal:new({
      id = M[opts.type].term_id,
      dir = cwd,
      -- env = {},
      direction = opts.direction,
      close_on_exit = opts.close_on_exit,
      auto_scroll = opts.auto_scroll,

      -- on_open = function(t) end,
      on_stdout = function(term, job, data, name)
        -- Search @data until we have found the pid of the cmd
        if not M[opts.type].cmd_pid and M[opts.type].is_running then
          M[opts.type].cmd_pid = extract_job_id(table.concat(data))
          -- Found the cmd pid
          if M[opts.type].cmd_pid then
            -- Start a timer that watches the process
            M[opts.type].watcher:start(
              100,
              500,
              vim.schedule_wrap(function()
                -- TODO: make configurable?
                if M[opts.type].watcher_cnt == 100 then
                  log.error("Command is taking a long time")
                end
                -- info contains: { name, pid, ppid }
                local watch_info = vim.api.nvim_get_proc(tonumber(M[opts.type].cmd_pid))
                if watch_info == nil then
                  -- Started @cmd has finished executing
                  M[opts.type].is_running = false
                  M[opts.type].cmd_pid = nil
                  M[opts.type].cmd = nil
                  M[opts.type].watcher_cnt = 0
                  M[opts.type].watcher:stop()

                  if term.close_on_exit then
                    term:close()
                    if vim.api.nvim_buf_is_loaded(term.bufnr) then
                      vim.api.nvim_buf_delete(term.bufnr, { force = true })
                    end
                  end

                  if on_exit ~= nil then
                    on_exit(0)
                  end
                end
                M[opts.type].watcher_cnt = M[opts.type].watcher_cnt + 1
              end)
            )
          end
        end
      end, -- callback for processing output on stdout

      on_stderr = function(term, job, data, name)
        on_output(nil, data)
      end,

      -- gets called when contained shell in terminal closes
      on_exit = function(term, job, exit_code, name)
        on_exit(exit_code)
      end,
    })
  end

  if not M[opts.type].term:is_open() then
    M[opts.type].term:open()
  end

  M[opts.type].has_error = false
  M[opts.type].is_running = true -- gets monitored by the timers
  -- TODO: When re-using we have to make sure no
  -- other command is currently running in that shell
  M[opts.type].term:send(M[opts.type].cmd, true)
end

function M.has_active_job(opts)
  if M[opts.type].has_error then
    log.warn("A CMake terminal has errors")
  end
  if M[opts.type].is_running then
    log.info("A CMake task is already running or has errors.")
    return true
  end
  return false
end

function M.stop(opts)
  if M[opts.type].term then
    M[opts.type].term:shutdown()
  end
end

---Check if the executor is installed and can be used
---@return string|boolean
function M.is_installed()
  if not has_toggleterm then
    return "toggleterm plugin is missing, please install it"
  end
  return true
end

return M
