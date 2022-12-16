
# install homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# install brew bundle
brew tap Homebrew/bundle

# install brews
brew bundle --file ~/.config/Brewfile

# install vim-plug
curl -fLo ~/.vim/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

# initialize nvim
nvim --headless -c 'autocmd User PackerComplete quitall' -c 'PackerSync'

