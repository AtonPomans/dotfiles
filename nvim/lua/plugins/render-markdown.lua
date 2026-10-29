-- Renders headings, code blocks, tables, and checkboxes inside the editor.
return {
    "MeanderingProgrammer/render-markdown.nvim",
    dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-tree/nvim-web-devicons" },
    ft = { "markdown" },
    opts = {},
    keys = {
        { "<leader>rm", "<cmd>RenderMarkdown toggle<cr>", ft = "markdown", desc = "Toggle in-editor markdown rendering" },
    },
}
