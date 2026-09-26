#!/usr/bin/env python3
import os,sys
HELPER='/usr/local/libexec/hyper-cs16-fastdl-v8'; CORE='/usr/local/libexec/hyper-cs16-ctl-core-v8'
if len(sys.argv)>=3:
 m={'fastdl-sync':'sync','fastdl-status':'status','fastdl-rebuild':'rebuild','fastdl-clean':'rebuild','fastdl-clear':'rebuild'}
 if sys.argv[1] in m: os.execv(HELPER,[HELPER,m[sys.argv[1]],sys.argv[2]])
os.execv(CORE,[CORE]+sys.argv[1:])
