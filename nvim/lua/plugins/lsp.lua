-- Popular stacks. These only need Node or ship as standalone binaries, so every machine gets them.
local servers = {
    -- Web
    "ts_ls", "eslint", "biome", "html", "cssls", "tailwindcss", "emmet_ls", "jsonls",
    -- Python
    "pyright", "ruff",
    -- Lua, C/C++, PHP, SQL
    "lua_ls", "clangd", "intelephense", "sqlls",
    -- Shell, Docker, config files
    "bashls", "dockerls", "docker_compose_language_service", "yamlls", "taplo",
    -- Markdown / writing
    "marksman", "ltex_plus",
}

-- These fail to install or run without their toolchain, so a machine only gets the ones
-- whose executable is on PATH.
local toolchain_servers = {
    jdtls = "java",
    omnisharp = "dotnet",
    gopls = "go",
    rust_analyzer = "cargo",
    zls = "zig",
    ruby_lsp = "ruby",
}

-- Replaced above (ltex -> ltex_plus; quick_lint_js reported false errors next to ts_ls).
-- Excluded in case an older version of this config already installed them.
local superseded = { "ltex", "quick_lint_js" }

return {
    "neovim/nvim-lspconfig",
    dependencies = {
        "williamboman/mason.nvim",
        "williamboman/mason-lspconfig.nvim",
        "hrsh7th/cmp-nvim-lsp",
        "hrsh7th/cmp-buffer",
        "hrsh7th/cmp-path",
        "hrsh7th/cmp-cmdline",
        "hrsh7th/nvim-cmp",
        "L3MON4D3/LuaSnip",
        "saadparwaiz1/cmp_luasnip",
        "j-hui/fidget.nvim",
        "b0o/SchemaStore.nvim",
        -- Neovim API types for lua_ls when editing this config.
        { "folke/lazydev.nvim", opts = { library = { { path = "${3rd}/luv/library", words = { "vim%.uv" } } } } },
    },

    config = function()
        local cmp = require('cmp')
        local cmp_lsp = require("cmp_nvim_lsp")

        local ensure_installed = vim.deepcopy(servers)
        local disabled = vim.deepcopy(superseded)
        local missing_toolchain = {}
        for server, executable in pairs(toolchain_servers) do
            if vim.fn.executable(executable) == 1 then
                table.insert(ensure_installed, server)
            else
                table.insert(disabled, server)
                missing_toolchain[server] = executable
            end
        end

        require("fidget").setup({})
        require("mason").setup()

        -- mason-lspconfig v2 starts servers with vim.lsp.enable() and ignores `handlers`,
        -- so server settings go through vim.lsp.config() ("*" applies to every server).
        vim.lsp.config("*", {
            capabilities = vim.tbl_deep_extend(
                "force",
                {},
                vim.lsp.protocol.make_client_capabilities(),
                cmp_lsp.default_capabilities()),
        })

        vim.lsp.config("lua_ls", {
            settings = {
                Lua = {
                    runtime = { version = "Lua 5.1" },
                    diagnostics = {
                        globals = { "bit", "vim", "it", "describe", "before_each", "after_each" },
                    }
                }
            }
        })

        vim.lsp.config("zls", {
            settings = {
                zls = {
                    enable_inlay_hints = true,
                    enable_snippets = true,
                    warn_style = true,
                },
            },
        })
        vim.g.zig_fmt_parse_errors = 0
        vim.g.zig_fmt_autosave = 0

        vim.lsp.config("pyright", {
            -- Use the project's virtualenv (e.g. uv's .venv) so third-party imports resolve.
            before_init = function(_, config)
                local venv = vim.fs.find(".venv", { path = config.root_dir, upward = true, type = "directory" })[1]
                    or vim.env.VIRTUAL_ENV
                -- Mutate in place: the client already holds a reference to this settings table.
                config.settings.python = config.settings.python or {}
                config.settings.python.pythonPath = venv
                    and vim.fs.joinpath(venv, vim.fn.has("win32") == 1 and "Scripts/python.exe" or "bin/python")
            end,
        })

        vim.lsp.config("ruff", {
            -- Pyright provides hover for Python.
            on_init = function(client)
                client.server_capabilities.hoverProvider = false
            end,
        })

        vim.lsp.config("ts_ls", {
            -- Leave JS/TS formatting to the project's formatter (Biome or ESLint).
            on_init = function(client)
                client.server_capabilities.documentFormattingProvider = false
                client.server_capabilities.documentRangeFormattingProvider = false
            end,
        })

        vim.lsp.config("cssls", {
            -- Tailwind's @theme/@apply/@custom-variant are valid in Tailwind projects.
            settings = { css = { lint = { unknownAtRules = "ignore" } } },
        })

        vim.lsp.config("jsonls", {
            settings = {
                json = {
                    schemas = require("schemastore").json.schemas(),
                    validate = { enable = true },
                },
            },
        })

        -- lspconfig roots Biome at the lockfile, so a biome.json in a subfolder (e.g. frontend/)
        -- is never read. Prefer the nearest biome.json and fall back to lspconfig's logic.
        local lspconfig_biome_root = vim.lsp.config.biome.root_dir
        vim.lsp.config("biome", {
            root_dir = function(bufnr, on_dir)
                local root = vim.fs.root(bufnr, { "biome.json", "biome.jsonc" })
                if root then
                    on_dir(root)
                elseif type(lspconfig_biome_root) == "function" then
                    lspconfig_biome_root(bufnr, on_dir)
                end
            end,
            -- Use the project's pinned Biome, which monorepos may hoist to a parent node_modules.
            cmd = function(dispatchers, config)
                local node_modules = vim.fs.find(function(name, path)
                    return name == "node_modules" and vim.uv.fs_stat(vim.fs.joinpath(path, name, ".bin", "biome")) ~= nil
                end, { path = config.root_dir, upward = true })[1]
                local biome = node_modules and vim.fs.joinpath(node_modules, ".bin", "biome") or "biome"
                return vim.lsp.rpc.start({ biome, "lsp-proxy" }, dispatchers)
            end,
        })

        local mason_lspconfig = require("mason-lspconfig")
        mason_lspconfig.setup({
            ensure_installed = ensure_installed,
            automatic_enable = { exclude = disabled },
        })

        -- bashls lints with shellcheck when it's on PATH (Mason puts its bin dir on PATH).
        -- Skipped in headless sessions, like mason-lspconfig's ensure_installed.
        local registry = require("mason-registry")
        registry.refresh(vim.schedule_wrap(function()
            local ok, shellcheck = pcall(registry.get_package, "shellcheck")
            if ok and #vim.api.nvim_list_uis() > 0 and not shellcheck:is_installed() and not shellcheck:is_installing() then
                shellcheck:install()
            end
        end))

        -- Stacks not listed above: the first time a filetype has no server, say how to get one.
        local function serves(server, ft)
            local config = vim.lsp.config[server]
            return config ~= nil and vim.tbl_contains(config.filetypes or {}, ft)
        end
        local hinted = {}
        vim.api.nvim_create_autocmd("FileType", {
            group = vim.api.nvim_create_augroup("LspInstallHint", {}),
            callback = function(args)
                local ft = args.match
                if hinted[ft] or vim.bo[args.buf].buftype ~= "" then
                    return
                end
                hinted[ft] = true
                local candidates = vim.list_extend(vim.deepcopy(ensure_installed), mason_lspconfig.get_installed_servers())
                for _, server in ipairs(candidates) do
                    if not vim.tbl_contains(disabled, server) and serves(server, ft) then
                        return
                    end
                end
                for server, executable in pairs(missing_toolchain) do
                    if serves(server, ft) then
                        vim.notify(("%s needs `%s` on PATH for %s files"):format(server, executable, ft))
                        return
                    end
                end
                if #mason_lspconfig.get_available_servers({ filetype = ft }) > 0 then
                    vim.notify(("No language server for %s files. Run :LspInstall to pick one."):format(ft))
                end
            end,
        })

        local cmp_select = { behavior = cmp.SelectBehavior.Select }

        cmp.setup({
            snippet = {
                expand = function(args)
                    require('luasnip').lsp_expand(args.body) -- For `luasnip` users.
                end,
            },
            mapping = cmp.mapping.preset.insert({
                ['<C-p>'] = cmp.mapping.select_prev_item(cmp_select),
                ['<C-n>'] = cmp.mapping.select_next_item(cmp_select),
                ['<C-y>'] = cmp.mapping.confirm({ select = true }),
                ["<C-Space>"] = cmp.mapping.complete(),
            }),
            sources = cmp.config.sources({
                { name = 'nvim_lsp' },
                { name = 'luasnip' }, -- For luasnip users.
                { name = 'path' }, -- file path suggestions
            }, {
                    { name = 'buffer' },
                })
        })

        vim.diagnostic.config({
            -- update_in_insert = true,
            -- Neovim 0.11 stopped showing messages inline by default; show warnings and errors inline.
            virtual_text = { severity = { min = vim.diagnostic.severity.WARN } },
            severity_sort = true,
            float = {
                focusable = false,
                style = "minimal",
                border = "rounded",
                source = true,
                header = "",
                prefix = "",
            },
        })
    end
}
