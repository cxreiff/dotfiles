"set runtimepath^=~/.vim runtimepath+=~/.vim/after
"let &packpath = &runtimepath
"source ~/.vimrc

let mapleader = ' '

lua require('plugins')
lua require('commands')
lua require('lualine_init')

lua require('impatient')

set termguicolors
colorscheme aquarium

set noshowmode
set splitright
set splitbelow

set expandtab
set tabstop=2
set softtabstop=2
set shiftwidth=2

let g:rustfmt_autosave = 1
let g:goyo_width = 100
let g:limelight_conceal_guifg = 'DarkGray'

nnoremap <leader>p :Telescope find_files<CR>
nnoremap <leader>o :Telescope live_grep<CR>
nnoremap <leader>h :Telescope help_tags<CR>
nnoremap <leader>g :TZAtaraxis<CR>
nnoremap <leader>j :m+<CR>
nnoremap <leader>k :m-2<CR>
nnoremap <leader>h <<
nnoremap <leader>l >>
nnoremap <leader>m :t.<CR>
nnoremap <leader>f :Format<CR>

nnoremap <leader>t :FTermToggle<CR>
nnoremap <C-t> :FTermToggle<CR>
tnoremap <C-t> <C-n><cmd>:FTermToggle<CR>

packloadall
silent! helptags ALL

