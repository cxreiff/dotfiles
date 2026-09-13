return {
    "nvim-lualine/lualine.nvim",
    opts = {
        options = {
            icons_enabled = false,
            component_separators = { left = '▪', right = '▪'},
            section_separators = { left = '', right = ''},
        },
        sections = {
            lualine_x = { 'filetype' },
        },
    },
}
