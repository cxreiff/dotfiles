return function()
  local telescope = require('telescope')
  local actions = require('telescope.actions')
  telescope.setup {
    defaults = {
      file_ignore_patterns = {
        'node_modules',
        'build',
      },
      mappings = {
        i = {
          ['<ESC>'] = actions.close,
        },
      },
    },
    pickers = {
      buffers = {
        mappings = {
          i = {
            ['<C-d>'] = 'delete_buffer',
          },
        },
      },
    },
  }
  telescope.load_extension('fzf')
  telescope.load_extension('ui-select')
  telescope.load_extension('termfinder')
end

