# ttysvr
#
# call with `svr [variant] [seconds]`
# e.g. `svr maze 1000` for maze screensaver after 1000 seconds.
#
svr() { TMOUT=$2; trap "ttysvr $1; zle reset-prompt" ALRM }
svr_off() { TMOUT=0 }
# ttysvr end

