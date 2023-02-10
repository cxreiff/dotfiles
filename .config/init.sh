
# install homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# install brew bundle
brew tap Homebrew/bundle

# install brews
brew bundle --file ~/.config/Brewfile

# install vim-plug
curl -fLo ~/.vim/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

# install irssi plugins
curl https://scripts.irssi.org/scripts/adv_windowlist.pl --create-dirs -o ~/.irssi/scripts/autorun/adv_windowlist.pl
curl https://scripts.irssi.org/scripts/nickcolor.pl --create-dirs -o ~/.irssi/scripts/autorun/nickcolor.pl
curl https://scripts.irssi.org/scripts/usercount.pl --create-dirs -o ~/.irssi/scripts/autorun/usercount.pl
curl https://scripts.irssi.org/scripts/mouse.pl --create-dirs -o ~/.irssi/scripts/autorun/mouse.pl

