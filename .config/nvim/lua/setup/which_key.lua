return function()
  local wk = require('which-key')
  wk.setup {}
  wk.register({
    a = { "code actions" },
    j = { "move down" },
    k = { "move up" },
    m = { "duplicate line" },
  }, {
    prefix = '<leader>',
  })
end

