local g, api, env, v = vim.g, vim.api, vim.env, vim.v
if g.loaded_unnest then
	return
end
g.loaded_unnest = true

env.VISUAL = v.progpath
env.EDITOR = v.progpath

-- Ensure server is started to get current socket path (v.servername)
-- This also sets NVIM environment variable for child processes
if v.servername == '' then
	vim.fn.serverstart()
end

api.nvim_create_user_command("UnnestEdit", function(cmd)
	require("unnest").ex_edit(cmd)
end, {
	nargs = 1,
	desc = "Run {cmd} in a terminal buffer in curent window. If it opens a Nvim instance with a file path, the file will be opened in the parent Nvim instance, and the child Nvim instance will be closed right away.",
	complete = "shellcmdline",
})

--- Get ancestor PIDs of the current process
--- @return table pids List of ancestor PIDs
local function get_ancestor_pids()
	local pids = {}
	local current_pid = vim.fn.getpid()

	-- Trace parent processes up to init (PID 1)
	while current_pid and current_pid > 1 do
		local result = vim.fn.system('ps -o ppid= -p ' .. current_pid)
		-- Check if command failed (non-zero exit code)
		if vim.v.shell_error ~= 0 then
			break
		end
		local ppid = tonumber(vim.trim(result))
		if not ppid or ppid <= 1 then
			break
		end
		table.insert(pids, ppid)
		current_pid = ppid
	end

	return pids
end

--- Extract PID from socket path (e.g., "/path/nvim.12345.0" -> 12345)
--- @param socket_path string
--- @return number|nil pid
local function get_pid_from_socket(socket_path)
	local pid = socket_path:match('nvim%.(%d+)%.%d+$')
	return pid and tonumber(pid) or nil
end

--- Find an available parent Neovim socket to connect to
--- Prioritizes sockets whose PID is an ancestor of current process
--- @return number|nil parent_chan The channel number if successful
--- @return string|nil socket_path The socket path if successful
local function find_parent_socket()
	local current_socket = v.servername
	local ancestor_pids = get_ancestor_pids()

	-- Get socket base directory: /var/folders/.../nvim.{user}
	local socket_base_dir = vim.fn.fnamemodify(current_socket, ':h:h')

	-- Find all socket files in the socket base directory
	local sockets = vim.fn.globpath(socket_base_dir, '*/nvim.*.0', false, true)

	-- Build list of valid parent sockets, categorized by whether they're ancestors
	local ancestor_parents = {}
	local other_parents = {}

	for _, socket in ipairs(sockets) do
		if socket ~= current_socket then
			local socket_pid = get_pid_from_socket(socket)

			local success, chan = pcall(vim.fn.sockconnect, "pipe", socket, { rpc = true })
			if success and chan and chan > 0 then
				-- Check if the parent has unnest plugin
				local has_unnest_success, has_unnest = pcall(
					vim.fn.rpcrequest,
					chan,
					'nvim_exec_lua',
					'return pcall(require, "unnest")',
					{}
				)
				if has_unnest_success and has_unnest then
					local mtime = vim.fn.getftime(socket)
					local parent_info = { socket = socket, chan = chan, mtime = mtime, pid = socket_pid }

					-- Check if this socket's PID is an ancestor
					local is_ancestor = false
					for _, ancestor_pid in ipairs(ancestor_pids) do
						if socket_pid == ancestor_pid then
							is_ancestor = true
							break
						end
					end

					if is_ancestor then
						table.insert(ancestor_parents, parent_info)
					else
						table.insert(other_parents, parent_info)
					end
				else
					vim.fn.chanclose(chan)
				end
			end
		end
	end

	-- Prefer ancestor parents, then fall back to other parents
	local candidates = #ancestor_parents > 0 and ancestor_parents or other_parents

	if #candidates == 0 then
		return nil, nil
	end

	-- Sort by modification time (newest first) within the chosen category
	table.sort(candidates, function(a, b)
		return a.mtime > b.mtime
	end)

	-- Close all channels except the selected one
	local selected = candidates[1]
	for i = 2, #candidates do
		vim.fn.chanclose(candidates[i].chan)
	end

	-- Also close channels from the non-selected category
	local non_selected = #ancestor_parents > 0 and other_parents or ancestor_parents
	for _, parent in ipairs(non_selected) do
		vim.fn.chanclose(parent.chan)
	end

	return selected.chan, selected.socket
end

local parent_chan, parent_socket = find_parent_socket()

if not parent_chan then
	-- This is expected when running Neovim outside of :terminal or
	-- when no parent Neovim instance with unnest plugin is found
	return
end


local parent = require("unnest.nvim"):new(parent_chan)

api.nvim_create_autocmd("VimEnter", {
	callback = function()

		if env.NVIM_UNNEST_NOWAIT then
			parent.rpcnotify.nvim_cmd({
				cmd = "edit",
				args = { api.nvim_buf_get_name(0) },
			}, {})
			vim.cmd("qall!")
			return
		end

		local winlayout = vim.fn.winlayout()
		local commands = require("unnest").winlayout_to_cmds(winlayout)

		parent.rpcnotify.nvim_command("tabnew")
		vim.iter(commands):each(parent.rpcnotify.nvim_command)

		-- New tabpage should also stimulate cwd of nested Nvim
		parent.rpcnotify.nvim_command("tcd " .. vim.fn.fnameescape(vim.fn.getcwd(-1, 0)))

		if vim.v.testing == 1 then
			parent.rpcnotify.nvim_tabpage_set_var(0, "unnest_socket", v.servername)
		end

		local tabpagenr = parent.nvim_call_function("tabpagenr", {}) --[[@as integer]]

		parent.rpcnotify.nvim_create_autocmd("TabClosed", {
			command = ([[if expand("<afile>") == %s | call rpcnotify(sockconnect('pipe', '%s', #{ rpc: v:true }), 'nvim_command', 'quitall!') | endif]]):format(
				tabpagenr,
				v.servername
			),
			once = true,
		})
	end,
})
