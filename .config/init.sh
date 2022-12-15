
# install homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# initial nvim packer install
nvim --headless -c 'autocmd User PackerComplete quitall' -c 'PackerSync'

# install nerd font
git clone git@github.com:ryanoasis/nerd-fonts.git --depth=1
cd nerd-fonts; ./install.sh; rm -rf -- nerd-fonts


