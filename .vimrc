
call plug#begin()
Plug 'vim-airline/vim-airline'
Plug 'tpope/vim-sensible'
Plug 'tpope/vim-surround'
Plug 'tpope/vim-fugitive'
Plug 'tpope/vim-vinegar'
Plug 'tpope/vim-commentary'
Plug 'rust-lang/rust.vim'
Plug 'junegunn/goyo.vim'
Plug 'junegunn/limelight.vim'
Plug 'vim-airline/vim-airline-themes'
Plug 'sainnhe/everforest'
Plug 'w0ng/vim-hybrid'
Plug 'AlessandroYorba/Alduin'
Plug 'AlessandroYorba/Sierra'
Plug 'franbach/miramare'
call plug#end()

syntax enable
set background=dark
colorscheme alduin

set number
set shm+=I
set belloff=all
set ttimeoutlen=10
set mouse=a

let mapleader = ' '
let g:rustfmt_autosave = 1
let g:Hexokinase_highlighters = ['foreground']
let g:limelight_conceal_guifg = 'DarkGray'
let g:goyo_width = 100

nnoremap <leader>g :Goyo<CR>
nnoremap <silent> <leader>t :wa \| vertical botright term ++kill=term<CR>
nnoremap <leader>j :m+<CR>
nnoremap <leader>k :m-2<CR>
nnoremap <leader>h <<
nnoremap <leader>l >>
nnoremap <leader>m :t.<CR>

autocmd! User GoyoEnter Limelight
autocmd! User GoyoLeave Limelight!

packloadall
silent! helptags ALL
