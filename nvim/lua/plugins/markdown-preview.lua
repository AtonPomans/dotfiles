return {
    "iamcco/markdown-preview.nvim",
    cmd = { "MarkdownPreviewToggle", "MarkdownPreview", "MarkdownPreviewStop" },
    ft = { "markdown" },
    build = "cd app && npm install",
    init = function()
        vim.g.mkdp_filetypes = { "markdown" }
    end,
    keys = {
        { "<leader>rp", "<cmd>MarkdownPreviewToggle<cr>", ft = "markdown", desc = "Toggle markdown browser preview" },
    },
}
