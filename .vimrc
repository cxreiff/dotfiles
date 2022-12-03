set number
syntax enable
filetype plugin indent on
set shm+=I

call plug#begin()
Plug 'vim-airline/vim-airline'
Plug 'tpope/vim-surround'
Plug 'tpope/vim-fugitive'
Plug 'preservim/nerdtree'
Plug 'mhinz/vim-signify'
Plug 'jiangmiao/auto-pairs'
Plug 'neoclide/coc.nvim', {'branch': 'release'}
Plug 'rust-lang/rust.vim'
Plug 'RRethy/vim-hexokinase', { 'do': 'make hexokinase' }
Plug 'junegunn/fzf.vim'
Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'junegunn/goyo.vim'
Plug 'junegunn/limelight.vim'
Plug 'sainnhe/everforest'
call plug#end()

set background=dark
colorscheme everforest

let g:rustfmt_autosave = 1
let g:Hexokinase_highlighters = ['foreground']
let g:limelight_conceal_guifg = 'DarkGray'
let NERDTreeAutoDeleteBuffer = 1
let NERDTreeMinimalUI = 1
let NERDTreeDirArrows = 1

autocmd! User GoyoEnter Limelight
autocmd! User GoyoLeave Limelight!

" Open the existing NERDTree on each new tab.
autocmd BufWinEnter * if getcmdwintype() == '' | silent NERDTreeMirror | endif

" Exit Vim if NERDTree is the only window remaining in the only tab.
autocmd BufEnter * if tabpagenr('$') == 1 && winnr('$') == 1 && exists('b:NERDTree') && b:NERDTree.isTabTree() | quit | endif

" Close the tab if NERDTree is the only window remaining in it.
autocmd BufEnter * if winnr('$') == 1 && exists('b:NERDTree') && b:NERDTree.isTabTree() | quit | endif

nnoremap <silent> <C-p> :Files<CR>
nnoremap <silent> <C-l> :Rg<CR>
nnoremap <C-d> :NERDTreeToggle<CR>

packloadall
silent! helptags ALL
