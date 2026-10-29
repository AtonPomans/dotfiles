-- Mirror a repo's markdown into an Obsidian vault and open the current file there.
-- Obsidian can't watch folders inside WSL (\\wsl.localhost or mapped drives fail with EISDIR),
-- so the repo is copied one-way into a vault on the Windows drive. Edits made in Obsidian are overwritten.
local M = {}

local is_wsl = vim.fn.has("wsl") == 1
local vault_name = "Obsidian Repos"
local synced_types = { "md", "png", "jpg", "jpeg", "gif", "svg", "webp", "pdf" }

local function run(cmd)
    local result = vim.system(cmd, { text = true, cwd = is_wsl and "/mnt/c" or nil }):wait()
    return vim.trim(result.stdout or "")
end

-- Path as the Obsidian app sees it.
local function app_path(path)
    return is_wsl and run({ "wslpath", "-w", path }) or path
end

local paths
local function get_paths()
    if not paths then
        if is_wsl then
            local home = run({ "wslpath", "-u", run({ "cmd.exe", "/c", "echo %USERPROFILE%" }) })
            paths = {
                vault = home .. "/Documents/" .. vault_name,
                config = home .. "/AppData/Roaming/obsidian/obsidian.json",
            }
        else
            paths = {
                vault = vim.fn.expand("~/Documents/" .. vault_name),
                config = vim.fn.expand("~/.config/obsidian/obsidian.json"),
            }
        end
    end
    return paths
end

local function repo_root(bufnr)
    return vim.fs.root(bufnr, ".git")
end

local function mirror_dir(root)
    return get_paths().vault .. "/" .. vim.fs.basename(root)
end

-- Adds the vault to Obsidian's vault list. Returns false if it was already there.
local function register_vault()
    local p = get_paths()
    local ok, cfg = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(p.config), "\n"))
    end)
    if not ok or type(cfg) ~= "table" then
        cfg = {}
    end
    cfg.vaults = cfg.vaults or {}
    local vault = app_path(p.vault)
    for _, v in pairs(cfg.vaults) do
        -- Windows paths are case-insensitive.
        if v.path and v.path:lower() == vault:lower() then
            return false
        end
    end
    cfg.vaults[vim.fn.sha256(vault):sub(1, 16)] = { path = vault, ts = os.time() * 1000 }
    vim.fn.mkdir(vim.fn.fnamemodify(p.config, ":h"), "p")
    vim.fn.writefile({ vim.json.encode(cfg) }, p.config)
    return true
end

local function obsidian_running()
    if is_wsl then
        return run({ "tasklist.exe", "/FI", "IMAGENAME eq Obsidian.exe", "/NH" }):find("Obsidian.exe", 1, true) ~= nil
    end
    return vim.system({ "pgrep", "-x", "obsidian" }):wait().code == 0
end

-- Copies markdown and images (respecting .gitignore) into the vault, then calls on_done().
local function sync(root, on_done)
    local dest = mirror_dir(root)
    vim.fn.mkdir(dest, "p")
    local cmd = {
        "rsync", "-a", "--delete", "--delete-excluded", "--prune-empty-dirs",
        "--exclude=.git/", "--filter=:- .gitignore", "--include=*/",
    }
    for _, ext in ipairs(synced_types) do
        table.insert(cmd, "--include=*." .. ext)
    end
    vim.list_extend(cmd, { "--exclude=*", root .. "/", dest .. "/" })
    vim.system(cmd, { text = true }, vim.schedule_wrap(function(result)
        if result.code ~= 0 then
            vim.notify("Obsidian sync failed: " .. result.stderr, vim.log.levels.ERROR)
        elseif on_done then
            on_done()
        end
    end))
end

local function open_uri(uri)
    if is_wsl then
        -- explorer.exe rejects obsidian:// URIs; rundll32 hands them to the registered handler.
        vim.system({ "rundll32.exe", "url.dll,FileProtocolHandler", uri }, { cwd = "/mnt/c" })
    else
        vim.ui.open(uri)
    end
end

function M.open()
    local root = repo_root(0)
    if not root then
        vim.notify("Not in a git repo", vim.log.levels.WARN)
        return
    end
    local file = vim.api.nvim_buf_get_name(0)
    local relative = file:match("%.md$") and vim.fs.relpath(root, file)

    -- Obsidian only reads its vault list at startup, so a running instance can't open a new vault yet.
    local was_running = obsidian_running()
    local needs_restart = register_vault() and was_running

    sync(root, function()
        if needs_restart then
            vim.notify("Created the '" .. vault_name .. "' vault. Quit Obsidian, then press this again.", vim.log.levels.WARN)
            return
        end
        local target = mirror_dir(root) .. (relative and "/" .. relative or "")
        local uri = "obsidian://open?path=" .. vim.uri_encode(app_path(target))
        open_uri(uri)
        if not was_running then
            -- A cold start opens the vault but ignores the file, so ask again once it's up.
            vim.defer_fn(function() open_uri(uri) end, 5000)
        end
    end)
end

-- Keep already-mirrored repos up to date as markdown is saved.
vim.api.nvim_create_autocmd("BufWritePost", {
    group = vim.api.nvim_create_augroup("ObsidianMirror", {}),
    pattern = "*.md",
    callback = function(args)
        local root = repo_root(args.buf)
        if root and vim.uv.fs_stat(mirror_dir(root)) then
            sync(root)
        end
    end,
})

return M
