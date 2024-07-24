#!/bin/bash
################################################################################
# Purpose: Provide mosquitto listening daemon for motion/motioneye.
# Packages: motion, mosquitto-clients, [motioneye]
# Version: v1.0 
# Author: Roland Ebener
# Date: 2024/22/07
################################################################################

# This config is used by 'mqttsub.sh' You must restart mqttsub.service for 
# changes to take effect. There are many more options that can be configured
# by the user. See main section in this script more configurable option.

#daemon config
debug=1

#mosquitto config
# You need at least a broker ip address. The default topic is the host's name.
broker="192.168.1.252:1883"

#motion config
motion_conf="./motion.conf"

#message bus
AlertBusTopic="ohab/security/AlertBus"
EventBusTopic="ohab/security/EventBus"

################################################################################
##### helper functions #########################################################
################################################################################

function setconfig() { #########################################################
#key :: value :: path/file :: delimiter
#set a config key=value pair in configuration file
local s d 
  [[ -z $1 || -z $2 || -z $3 ]] && return 1 
  [[ ! -f $3 ]] && return 1 || d=${4:=' '}
#key=value already exits, replace line
  [[ -n $(grep "^[^#]\?\s*$1$d.*" "$3" 2>dev/null) ]] && s="$1$d"                      # 'key=value'
  [[ ${1:0:1} =~ '&' && -n $(grep "^#\?\s*$1$d.*" "$3" 2>dev/null) ]] && s="# $1$d"    # '# &key=value' 
  [[ -n $s ]] && { sed -i "/^$s[0-9]*/c $s$2" "$3"; return 0; }                        # inline sed replace line

#key=value does not exist, add it
  s=$1$d$2;s=${s/'&'/'# &'}
  s=$(cat <<EOF
# Added by $(basename $0), $(date '+%Y-%m-%d %H:%M:%S')
$s
EOF
  );echo "$s" >> $3 && return 0 || return 1                                 # echo add line
}

function getconfig() { #########################################################
#key :: path/file :: delimiter
#get a config value from motion:camera config file e.g. 'camera-$1.conf'
#$1=Key $2=path/to/daemoncfg $3=delimiter [default=' ']
  local s d 
  [[ -z $1 || -z $2 ]] && return 1
  [[ ! -f $2 ]] && return 1 || d=${3:=' '}
  s=$(grep "^[^#]\?\s*$1$d.*" "$2" 2>dev/null)
  [[ ${1:0:1} =~ '&' ]] && s=$(grep "^#\?\s*"$1$d".*" "$2" 2>/dev/null)
  s=${s#*$d};s=${s%%' '*}; #s=${s%' #'*}
  [[ -z $s ]] && return 1 || echo $s
  return 0
} 

################################################################################
##### event functions ##########################################################
################################################################################

function set_motion_events(){ ##################################################
#setup motion events. The 'webcontrol_parms 3' is required in 'motion.conf'.
#available events:
#  on_motion_detected,on_area_detected,on_camera_lost,on_camera_found
#  on_event_start,on_event_end,on_picture_save,on_movie_start,on_movie_end
local s sr ary=("on_motion_detected" "on_camera_found" "on_camera_lost" )
  [[ -z $(cat $motion_conf 2>/dev/null | grep "webcontrol_parms.*3") ]] && return 0
#loop ary and set events for current session
  for evt in ${ary[@]};do
    s=$(jq -rn --arg x "$(realpath $0) $evt %t" '$x|@uri')
    cmd="$http_cmd/0/config/set?$evt=$s"
    [[ $debug -eq 1 ]] \
      && { echo "[debug] [set_motion_events] command: '$cmd'"; } \
      || { sr=$($cmd) || return 1; echo "[$(date '+%Y/%m/%d %T')] [event] Motion parameter: $evt set."; }
  done
#apply/write to motion config to make permanent
#  sr=$($http_cmd/0/config/write)
#  [[ $? -eq 0 ]] && { kill -s 1 $(cat /tmp/motion.pid); } #SIGHUP to reload motion config files
}

function on_motion_detected(){ #################################################
#id :: 
#actions to perform on mqtt bus when motion is detected by a camara
local conf deadtime priority
  [[ -z $1 ]] && { echo "[ERR] Please provide a camera id."; return 1; }
  conf="$(dirname $motion_conf 2>/dev/null)/camera-$1}"
  deadtime=$(getconfig "# &DeadTime" "$conf" " ")
  priority=$(getconfig "# &Priority" "$conf" " ")
  deadtime=${deadtime:=5}; priority=${priority:=0}
#setup a temporary file to allow for DeadTime
  tmpf="$run_path/.on_motion_detected.$id"
  [[ -e $tmpf ]] && return 0 || touch $tmpf
#publish to camera specific topic
  $mqtt_cmd/camera/$id/motion/state -m "1";
#publish to general/alert/event topic
  mqtt_cmd0=${mqtt_pub%' -t'*};s="$(hostname)::Camera-$id::AlertSent=$Priority"
  [[ -n $AlertBusTopic && $priority -gt 0 ]] && $mqtt_pub0 -t "$AlertBusTopic" -m "$priority"
  [[ -n $EventBusTopic ]] && $mqtt_pub0 -t "$EventBusTopic" -m "$s"
#time to reset motion on mqtt bus
  ( sleep $deadtime;$mqtt_cmd/camera/$1/motion/state -m "0";rm -f $tmpf 2>/dev/null; exit 0 ) &
}

function on_camera_found(){ ####################################################
#actions to perform on mqtt bus when motion is detected by a camara
local s; unset s
id=${$1:=0} #must have camera id
  $mqtt_cmd/camera/$id/connected -m "1"
  [[ -z $EventBusTopic ]] && return 0
  s="$(hostname)::Camera-$id::found"
  ${mqtt_cmd%' -t'*} -t $EventBusTopic -m $s
}

function on_camera_lost(){ #####################################################
#actions to perform on mqtt bus when motion is detected by a camara
local s; unset s
id=${$1:=0} #must have camera id
  $mqtt_cmd/camera/$id/conected -m "1";
  [[ -z $EventBusTopic ]] && return 0
  s="$(hostname)::Camera-$id::lost"
  ${mqtt_cmd%' -t'*} -t $EventBusTopic -m $s
}

################################################################################
##### api abstractions #########################################################
################################################################################

function run_camapi () { ########################################################
#/id :: cmd :: val
#This function transforms <cmd> to a 'http command' that can be send to a 
# net camera. It will get its config from special '# &keys' in the camera-id.conf
# You must configure '# &cam_api=' and there must be a 'netcam_url=' entry.
local conf api ip ptzcmd cmd cmd1 cmd val sr

#get api, ip:port from config
conf="$(dirname $motion_conf 2>dev/null)/camera-${1:1}"
api=$(getconfig "&cam_api" "$conf" " ") || return 1
ip=$(getconfig "netcam-url" "$conf" " ") || return 1
[[ $debug -eq 1 ]] && echo "[debug] [getptz_cmd] api=$api@$ip :: $2 :: $3."

case $api in 
'foscam1') #api for a foscam up v1.2 e.g. ipcam01
  ptzcmd="$ip/<cmd>&user=admin&pwd="; cmd="decoder_control.cgi?command="
  cmd1="camera_control.cgi?param="; cmd2="set_misc?<cmd>"; val="$3"
  case $2 in
  "up") cmd+="0&onestep=${val:=1}";; 
  "stop") cmd+="1";;
  "down") cmd+="2&onestep=${val:=1}";; 
  "left") cmd+="4&onestep=${val:=1}";; 
  "right") cmd+="6&onestep=${val:=1}";;
  "center") cmd+="25&onestep=0";;  
  "vpatrol") cmd+="26&onestep=${val:=0}";; 
  "hpatrol") cmd+="28&onestep=${val:=0}";; 
  "setpreset") [[ $val -ge 1 && $val -le 32 ]] && cmd+="$(($val*2+28))" || cmd+="";;                 
  "callpreset") [[ $val -ge 1 && $val -le 32 ]] && cmd+="$(($val*2+29))&onestep=0" || cmd+="";;
  "ir") cmd="$cmd1""14&value=$([[ $val -gt 0 ]] && echo 1 || echo 0;)";;
  "led") cmd="$cmd2""led_mode=$([[ $val -gt 0 ]] && echo 1 || echo 2;)"
  esac
  [[ ${cmd: -1} =~ '=' ]] && return 1 #no valid command
  cmd="${ptz_cmd/'<cmd>'/"$cmd"}" 
  [[ $debug -eq 1 ]] && { echo "[debug] [camera] [$1] [$2] command: '$cmd'"; return 0; }
  sr=$(eval $cmd); [[ ${sr#'='*} =~ "\"ok\"" ]] && return 0 || return 1
;;
'foscam2') return 1;;
esac
}

################################################################################
##### action functions #########################################################
################################################################################

function camera_actions () { ###################################################
#/id :: act :: sbj :: payload
#<hostname>/camera/<id>/ptz/<key> <value> >> ../<id>/ptz/<key>/state <value> 
local ptzapi cmd cmd1 cmd val; unset ptz_cmd cmd cmd1 cmd2 val
[[ ${#@} -lt 4 ]] && return 1
case $2 in
'control') 
  run_camapi "$1" "$3" "$4" || return 1
  case $3 in #depending on sbj return ../act/sbj/state
  "ir") $mqtt_cmd/camera""$1/$2/$3/state -m $4;;
  "led") $mqtt_cmd/camera""$1/$2/$3/state -m $4;;
  esac
;;
*) [[ $debug -eq 1 ]] && echo "[debug] [camera] '$2' has no case in \$act."
;;
esac
}

function motion_actions () { ###################################################
#/id :: act :: sbj :: payload
#<hostname>/motion/<id>/detection ON|OFF >> ../<id>/detection/state ON|OFF 
#<hostname>/motion/<id>/snapshot ON >> ../<id>/snapshot/state OFF
#<hostname>/motion/<id>/get <key> >> ../<id>/config/<key>/state <value>
#<hostname>/motion/<id>/set/<key> <value> >> ../<id>/config/<key>/state <value>
[[ ${#@} -lt 4 ]] && return 0
local sr cmd cfgf mpid; unset sr cmd cfgf mpid
case $2 in 
'detection') #payload=command
  case $4 in
  "ON"|1 ) cmd="$http_cmd""$1/detection/start";;
  "OFF"|0 ) cmd="$http_cmd""$1/detection/pause";;
  *) return 1
  esac
  [[ $debug -eq 1 ]] && { echo "[debug] [motion] [$2] command: '$cmd'"; return 0; }
  [[ -n $cmd ]] && sr=$($cmd)  
  $mqtt_cmd/motion""$1/$2/state -m ${$4^^} 
;;
'snapshot') #payload=command
  case $4 in
  "ON"|1) cmd="$http_cmd""$1/action/snapshot";;
  *) : #do nothing
  esac 
  [[ $debug -eq 1 ]] && { echo "[debug] [motion] [$2] command: '$cmd'"; return 0; }
  [[ -n $cmd ]] && $cmd
  $mqtt_cmd/motion""$1/$2/state -m "OFF" #always send OFF to reset
;; 
'getcf') #payload=key
  [[ "${1:1}" -gt 0 ]] && cfgf="camera-${1:1}.conf" || cfgf="motion.conf"
  cmd="getconfig \"$4\" $(dirname $motion_conf)/$cfgf ' '"
  [[ $debug -eq 1 ]] && { echo "[debug] [motion] [$2] [$4] command: '$cmd'"; }
  sr=$(eval $cmd) || return 1 #execute
  [[ -n $sr ]] && $mqtt_cmd/motion""$1/config/$4/state -m $sr
;;
'getrt') #payload=key
  case $4 in #payload
  'detection') 
    cmd="$http_cmd""$1/detection/status";
    [[ $debug -eq 1 ]] && { echo "[debug] [motion] [$2] command: '$cmd'"; return 0; }
    sr=$($cmd) || return 1 #execute
    case $(echo ${sr#*'status'} | tr -d '[:blank:]') in
      'ACTIVE') sr="ON";;'PAUSE') sr="OFF"
    esac;;
  *)
    cmd="$http_cmd""$1/config/get?query=$4"
    [[ $debug -eq 1 ]] && { echo "[debug] [motion] [$2] [$4] command: '$cmd'"; return 0; }
    sr=$($cmd | grep -i "$4") || return 1 #execute
    [[ ! -z $sr && $? -eq 0 ]] && { sr=${sr#*'='};sr=${sr%'Done'*};sr=$(echo $sr | tr -d '[:blank:]'); }   
  esac
  [[ -n $sr ]] && $mqtt_cmd/motion""$1/run/$4/state -m $sr
;;
'set') #sbj=key payload=<new value>
#key must be included in file 'whitelist' in path of $conf_file
  cat $(dirname $conf_file)/whitelist 2>/dev/null | grep "$3" 2>/dev/null \
    || { $mqtt_cmd/motion""$1/config/$3/state -m "#blocked#"; return 1; }
  [[ "${1:1} " -gt 0 ]] && cfgf="camera-${1:1}.conf" || cfgf="motion.conf"
  cmd="setconfig \"$3\" \"$4\" \"$(dirname $motion_conf)/$cfgf\" ' '"
  [[ $debug -eq 1 ]] && { echo "[debug] [motion] [$2] [$3] command: '$cmd'" && return 0; } 
  eval $cmd || return 1 #execute
  if [[ ! ${3:0:1} =~ '&' ]]; then #only if 'key=' default motion config
    mpid=$(ps -eaf | grep "/$motion_conf" | grep -v "pts" | awk '{print $2}')
    [[ -n $mpid ]] || return 1
    kill -s 1 $mpid || { $mqtt_cmd/motion""$1/config/$3/state -m "#ERR#}"; return 0; } 
  fi
  $mqtt_cmd/motion""$1/run/$3/state -m "$4"  
;;  
*) [[ $debug -eq 1 ]] && echo "[debug] [motion] '$2' has no case in \$act."
esac
}

function daemon_actions () { ###################################################
#act :: sbj :: payload
#<hostname>/daemon/control <stop|restart> >> ../daemon/run/<param> OK 
#<hostname>/daemon/get <ssid|wifi|status|debug> >> ../daemon/run/<param>/state 
#<hostname>/daemon/set/<key> <value> >> ../daemon/config/<key>/state <value> 
#<hostname>/daemon/setrt/<key> <value> >> ../daemon/config/<key>/state <value> 
local sr cmd; unset sr cmd
[[ ${#@} -ne 3 ]] && return 0 
case $1 in
"control") #payload=action 
  case $3 in
    "stop") flag_exit="stop";;
    "restart") flag_exit="restart";;
    "reload") kill -s SIGHUP $(cat $run_path/read.pid)
  esac
  [[ $debug -eq 1 ]] && { echo "[debug] [daemon] [$1] command: '$cmd'" && return 0; }
  $cmd || return 1
  $mqtt_cmd/daemon/control/$3 -m "EXECUTED"
;;
'getcf') #payload=key
  cmd="getconfig \"$3\" \"$conf_file\" \"=\""
  [[ $debug -eq 1 ]] && { echo "[debug] [daemon] [$1] command: $cmd"; return 0; }
  sr=$(eval $cmd) || return 1 #execute
  $mqtt_cmd/daemon/config/$3/state -m "${sr:=null}"
;;
'getrt') #payload=<runtime var>
  case $3 in
    "ssid"|"wifi") sr=$(iwgetid);sr="${sr#*'ESSID:'}";;
    "status") sr=$(status json);;
  *) sr="${!3}"; [[ -z sr ]] && return 1
  esac
  $mqtt_cmd/daemon/run/$3/state -m "${!3}"
;;
'set') #sbj=key; payload=<new value>
  cmd="setconfig \"$2\" \"$3\" \"$conf_file\" \"=\"" 
  [[ $debug -eq 1 ]] && { echo "[debug] [daemon] [$1] [$2] command: '$cmd'"; return 0; }
  eval $cmd || return 1 #execute
  $mqtt_cmd/daemon/config/$2/state -m "$3"
  #TODO: deamon reload
;;
'setrt') #sbj=<runtime var>; payload=<new value>
  cmd="$2="$(echo "$3")""
  [[ $debug -eq 1 ]] && { echo "[debug] [daemon] [$1] [$2] command: '$cmd'"; return 0; }
  eval $cmd || return 1 #exec
  $mqtt_cmd/daemon/run/$2/state -m "${!2}"; return 0
;;
*) [[ $debug -eq 1 ]] && echo "[debug] [daemon] '$1' has no case in \$act."
esac
}

################################################################################
##### error/debug functions ####################################################
################################################################################

function error_handler () { ####################################################
  local error_code=$?; local error_line=$BASH_LINENO; local error_command=$BASH_COMMAND
  echo "[err] line $error_line: $error_command (exit code: $error_code)"
  # exit 1 #optional if exit is rquired
}

function debug_msg () { ########################################################
echo "[debug] [debug_msg]: ${#@}" :: $1 :: $2 :: $3 :: $4 :: $5
}

################################################################################
##### start/stop functions #####################################################
################################################################################

function start() { #############################################################
###check for running mqttsub.sh process; exit 0 if exists
#get pid of a running mqttsub.sh service
local fldr fifo
unset PID
[[ -f $run_path/mqtt.pid ]] && PID=$(cat "$run_path/mqtt.pid" 2>/dev/null)
[[ -n $PID ]] && echo "[OK] $service is already running [$PID]." && exit 0

#create runtime directories
for fldr in $run_path $log_path; do
  mkdir -p $fldr 2>/dev/null || { echo "[FAIL] Could not create runtime '$fldr'; check your permissions!"; exit 1; }
done
  
#create fifo pipe
fifo="$run_path/fifo" 
[[ ! -p $fifo ]] && { mkfifo $fifo || { echo "[FAIL] Could not create '$fifo'; check your permissions!"; exit 1; }; }

### start mosquitto_sub process ####################
($subscriber -h $broker_ip -p $broker_port -v -t "$topic/#" >$fifo 2>/dev/null & echo $! >&3) 3>"$run_path/mqtt.pid"
PID=$(cat $run_path/mqtt.pid) || { echo "[FAIL] $subscriber did not start!"; exit 1; }

### begin mqtt message read daemon loop ####################
( exec 1>> $run_path/debug.log 2>>$log_path/error.log
  trap "[[ -f $conf_file ]] && source $conf_file" SIGHUP
  [[ $debug -eq 1 ]] && trap "error_handler" ERR
  trap "kill -s 9 $PID;rm $run_path/mqtt.pid" EXIT
  while read msg <$fifo; do
#...split mqtt message; $topic/cat/id/act/sbj <payload>
  unset id cat act sbj val
  val=${msg#*' '};tmp=${msg%%' '*}                            #get payload >> val
  tmp=${tmp/"$topic/"}                                        #remove main topic
  id=$(echo $tmp | cut -d'/' -f 2);                           #get id
  [[ $id == ?(-)+([0-9]) ]] && id="/$id" || unset id          #check if id is valid, else unset!
  tmp=${tmp/"$id/"/"/"}                                       #remove id from tmp

  cat="${tmp%%'/'*}";tmp=${tmp/"$cat/"/}                      #get cat=category [camera|motion|daemon|os]
  act="${tmp%%'/'*}";tmp=${tmp/"$act/"}                       #get act=action [get|set|detection|...]
  sbj=${tmp##*'/'}; [[ $act =~ $sbj ]] && unset $sbj          #get sbj=subject [debug|<config key>|

#...start interpret/filter/actions here
  [[ $debug -eq 1 ]] && { echo "[debug] received: $msg"; debug_msg $cat $id $act $sbj $val; }
  case $cat in
  'camera') camera_actions $id $act $sbj $val;;
  'motion') motion_actions $id $act $sbj $val;;
  'daemon') daemon_actions $act $sbj $val;;
  *) [[ $debug -eq 1 ]] && { echo "[debug] received $msg";echo "[debug] [loop]'$cat' has no case in \$cat."; }
  esac
#...end interpret/filter/actions
#  [[ -n $flag_exit ]] && break #stop or restart
  done #exit message read daemon loop; this happens when mosquitto_sub pid is killed!
  $mqtt_cmd/$service/LWT -m "$lwt_disconnect"
  echo "[OK] $service stopped."
#  [[ -n $flag_exit ]] && ($0 $flag_exit) #restart daemon from mqtt
) & echo $! >"$run_path/read.pid" #subshell daemon end

### started mqtt message daemon ####################
$mqtt_cmd/$service/LWT -m "$lwt_connect"
echo "[OK] Started $service [$(cat $run_path/mqtt.pid)]"
}

function stop() { ##############################################################
#stop a running mqtt-subscribe service by sending TERM to mosquitto_sub pid.
# this will kill mosquitto sub break the daemon while read loop causing mqtt-subscribe
# to finish and exit
  [[ -f "$run_path/mqtt.pid" ]] \
    && { kill -s 9 $(cat "$run_path/mqtt.pid" 2>/dev/null);echo "[OK] $service stopped."; return $?; }
  echo "[INFO] $service is not running."; return 1
}

function status () { ###########################################################
  PID=$(cat "$run_path/mqtt.pid" 2>/dev/null)
  [[ -z $PID ]] && { echo "[INFO] $service is not running."; return 0; }
  json="{\"name\":\"$service\",\"status\":\"running\",\"pid\":\"$PID\",\"topic\":\"$topic\",\"broker\":\"$broker_ip\"}"
  msg="[OK] $service is running  [$PID].\n...Listening to topic '$topic' @ broker $broker_ip\n"
  [[ $1 =~ 'json' ]] && echo $json || echo -e "$msg"
  return 0
}

#TODO: function watchdog () { #########################################################
# this will scan motion.log for fatal daemon error and then try to restart via http command
# key: "[0:motion] [ERR] [ALL] motion_watchdog: Thread 1 - Watchdog timeout did NOT restart, killing it!"
#  [[ -f $run_path/watchdog.pid ]] && return 0
#  ( trap rm $RUNPATH/watchdog.pid 2>/dev/null EXIT
#    (tail -Fn0 "$motion_log" & echo $! >&3) 3>"$run_path/watchdog.pid" | \
#    while read line ; do
#      $(echo $line | grep "\\[0:motion\\].* \\[ERR\\].*killing it!" >/dev/null 2>&1) || continue
#      $http_cmd/0/action/restart && $mqtt_pub/$lwt_topic -m "$lwt_connect"
#      echo "[$(date '+%Y/%m/%d %T')] [WD] [WRN] Restart motion daemon via http command."
#  done ) &
#}

#TODO: function heartbeat () { ########################################################
#  [[ -f $run_path/heartbeat.pid ]] && return 0
#  ( trap rm $run_path/hearbeat.pid EXIT
#    while :;do
#    local js
#      js+="{\"Time\": \"$(date +%Y-%m-%d' '%T)\","
#      js+="\"Uptime\": \"$(cat /proc/uptime | cut -d ' ' -f 1)\","
#      js+="\"ip\": \"$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')\""
#      js+=" }"; $mqtt_cmd/tele/json -m "$js"
#      sleep "$tele_interval"
#  done ) & echo "$!" >"$run_path/heartbeat.pid"
#}

################################################################################
##### info functions ###########################################################
################################################################################

function display_usage () { ####################################################
msg=$(cat <<EOF
##### ABOUT ####################################################################
mqttsubs.sh is a bash script to enable control of motioneye via the mqtt protocol. 
 It uses mosquitto-clients package to subscribe- and publish to '$topic/#'.
  
Usage: $(basename $ME) [start|stop|restart|status]
EOF
); echo -e "$msg"
}

################################################################################
##### main #####################################################################
################################################################################
ME="$(readlink -f $0)";ME="${ME//' '/$'\ '}"
conf_file=${conf_file:="./mqttsubs.conf"}
[[ -f $conf_file ]] && source "$conf_file"

#-- following can be part of a config file -------------------------------------
#defaults daemon
service="${service:="mqttsubs"}"
debug=${debug:=0}
#TODO: prog_path=${prog_path:="/usr/sbin"} #path where mqttsub.sh will be installed
run_path="${run_path:="/var/run/mqttsubs"}"
log_path="${log_path:="/var/log/mqttsubs"}"

#defaults mosquitto
subscriber="${subscriber:="/usr/bin/mosquitto_sub"}"
publisher="${publisher:="/usr/bin/mosquitto_pub"}"
broker=${broker:="127.0.0.1:1883"}
topic="${topic:=$(hostname)}"
lwt_topic="${lwt_topic:="cameras/LWT"}"
lwt_connect="${lwt_connect:="online"}"
lwt_disconnect="${lwt_disconnect:="offline"}"

#defaults motion
motion_conf=${motion_conf:="/etc/motioneye/motion.conf"}
motion=${motion:="127.0.0.1:7999"}

#defaults messages
DeadTime=${DeadTime:=5}
Priority=${Priority:=0}

#message bus
AlertBusTopic="ohab/security/AlertBus"
EventBusTopic="ohab/security/EventBus"

#defaults heartbeat
#TODO: tele_interval=${tele_interval:=300}

#-- end config file ------------------------------------------------------------

#set roots
broker_ip="${broker%:*}";broker_port="${broker/"$broker_ip"/}"; broker_port="${broker_port/:/}"
motion_ip="${motion%:*}";motion_port="${motion/"$motion_ip"/}"; motion_port="${motion_port/:/}"
http_cmd="curl -s http://$motion_ip:$motion_port"
mqtt_cmd="$publisher -h $broker_ip -p $broker_port -t $topic"

#check root
[[ $(id -u) -ne 0 ]] && { echo "[ERR] You must be root to run this."; exit 1; }

case $1 in
'start') start; set_motion_events;;
'stop') stop;;
'restart') stop;sleep 2;start;;
'status') status "$1";;
'debug_on') $mqtt_cmd/daemon/set -m "debug=1";;
'debug_off') $mqtt_cmd/daemon/set -m "debug=0";;  
'camera_ptz') camera_action "$1" "control" "$2" "$3";;
'on_motion_detected') on_motion_detected "$2";;
'on_camera_lost') on_camera_lost "$2";;
'on_camera_found') on_camera_found "$2";;
#'on_movie_start') :;; #on_event 'on_movie_start' "$2";;
#'on_movie_end') :;; #on_event 'on_movie_end' "$2";;
*) display_usage
esac