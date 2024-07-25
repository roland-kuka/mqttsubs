#!/bin/bash
################################################################################
# Purpose: Provide mosquitto listening daemon for motion/motioneye.
# Packages: motion, mosquitto-clients, [motioneye]
# Version: v1.0 
# Author: Roland Ebener
# Date: 2024/24/07
################################################################################

# This config is used by 'mqttsub.sh' You must restart mqttsub.service for 
# changes to take effect. There are many more options that can be configured
# by the user. See main section in this script more configurable option.

#daemon config
debug=1 #level 2: 1 no http_cmd, no set

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
  [[ -n $(grep "^[^#]\?\s*$1$d.*" "$3") ]] && s="$1$d"                      # 'key=value'
  [[ ${1:0:1} =~ '&' && -n $(grep "^#\?\s*$1$d.*" "$3") ]] && s="# $1$d"    # '# &key=value' 
  [[ -n $s ]] && { sed -i "/^$s[0-9]*/c $s$2" "$3"; return 0; }             # inline sed replace line

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
  s=$(grep "^[^#]\?\s*$1$d.*" "$2")
  [[ ${1:0:1} =~ '&' ]] && { s=$(grep "^#\?\s*$1$d.*" "$2");s=${s/'# &'/}; }
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
    [[ $debug -eq 1 ]] && { echo "[debug] [set_motion_events] command: $cmd."; }
    [[ $debug = 0 ]] && sr=$($cmd)
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
  $mqtt_cmd/camera/$id/connected -m "1";
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
[[ $debug -ne 0 ]] && trap "error_handler" ERR

#get api, ip:port from config
conf="$(dirname $motion_conf 2>/dev/null)/camera-${1:1}.conf"
api=$(getconfig "&cam_api" "$conf" " ") || return 1
ip=$(getconfig "netcam_url" "$conf" " ") || return 1
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
  cmd="curl \"${ptzcmd/'<cmd>'/"$cmd"}\"" 
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
#/id :: act :: key1 :: payload
#<hostname>/camera/<id>/ptz/<key> <value> >> ../<id>/ptz/<key>/state <value> 
local ptzapi cmd cmd1 cmd val; unset ptz_cmd cmd cmd1 cmd2 val
[[ $debug -ne 0 ]] && trap "error_handler" ERR
[[ ${#@} -ne 4 ]] && return 1
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
#/id :: act :: key1 :: payload
#<hostname>/motion/<id>/detection ON|OFF >> ../<id>/detection/state ON|OFF 
#<hostname>/motion/<id>/snapshot ON >> ../<id>/snapshot/state OFF
#<hostname>/motion/<id>/getcf <key> >> ../<id>/config/<key>/state <value>
#<hostname>/motion/<id>/getrt <key> >> ../<id>/run/<key>/state <value>
#<hostname>/motion/<id>/set/<key> <value> >> ../<id>/config/<key>/state <value>
local sr cmd cfgf mpid; unset sr cmd cfgf mpid
[[ $debug -ne 0 ]] && trap "error_handler" ERR
[[ ${#@} -ne 4 ]] && return 0
case $2 in 
'detection') #payload=command
  case $4 in
  "ON"|1 ) cmd="$http_cmd""$1/detection/start";;
  "OFF"|0 ) cmd="$http_cmd""$1/detection/pause";;
  *) return 1
  esac
  [[ $debug -ne 0 ]] && { echo "[debug] [motion] [$2] command: '$cmd'"; return 0; }
  [[ -n $cmd ]] && $cmd 
  $mqtt_cmd/motion""$1/$2/state -m ${$4^^} 
;;
'snapshot') #payload=command
  case $4 in
  "ON"|1) cmd="$http_cmd""$1/action/snapshot";;
  *) : #do nothing
  esac 
  [[ $debug -ne 0 ]] && { echo "[debug] [motion] [$2] command: '$cmd'"; return 0; }
  [[ -n $cmd ]] && $cmd
  $mqtt_cmd/motion""$1/$2/state -m "OFF" #always send OFF to reset
;; 
'get')
  case $3 in
  'cf') #payload=<config key>
    [[ "${1:1}" -gt 0 ]] && cfgf="camera-${1:1}.conf" || cfgf="motion.conf"
    cmd="getconfig \"$4\" $(dirname $motion_conf)/$cfgf ' '"
    [[ $debug -eq 2 ]] && { echo "[debug] [motion] [$2/$3] command: '$cmd'";return 0; }
    sr=$(eval $cmd) || return 1 #execute
    [[ -n $sr ]] && $mqtt_cmd/motion""$1/config/$4/state -m $sr
  ;;
  'rt') #payload=<runtime param>
    case $4 in #payload
    'detection') 
      cmd="$http_cmd""$1/detection/status";
      [[ $debug -eq 2 ]] && { echo "[debug] [motion] [$2/$3] command: '$cmd'"; return 0; }
      sr=$($cmd) || return 1 #execute
      case $(echo ${sr#*'status'} | tr -d '[:blank:]') in
        'ACTIVE') sr="ON";;'PAUSE') sr="OFF"
      esac;;
    *)
      cmd="$http_cmd""$1/config/get?query=$4"
      [[ $debug -ne 0 ]] && { echo "[debug] [motion] [$2/$3] command: '$cmd'"; return 0; }
      sr=$($cmd | grep -i "$4") || return 1 #execute
      [[ ! -z $sr && $? -eq 0 ]] && { sr=${sr#*'='};sr=${sr%'Done'*};sr=$(echo $sr | tr -d '[:blank:]'); }   
    esac
    [[ -n $sr ]] && $mqtt_cmd/motion""$1/run/$4/state -m $sr
  esac
;;

'set') #sbj=key payload=<new value>
#key must be included in file 'whitelist' in path of $conf_file
  sr=$(cat $(dirname $conf_file)/whitelist 2>/dev/null | grep "$3")
  [[ -z $sr ]] && { $mqtt_cmd/motion""$1/config/$3/state -m "#blocked#"; return 1; }
  [[ "${1:1} " -gt 0 ]] && cfgf="camera-${1:1}.conf" || cfgf="motion.conf"
  cmd="setconfig \"$3\" \"$4\" \"$(dirname $motion_conf)/$cfgf\" ' '"
  [[ $debug -eq 2 ]] && { echo "[debug] [motion] [$2/$3] command: '$cmd'"; return 0; } 
  eval $cmd || return 1 #execute
#  if [[ ! ${3:0:1} =~ '&' ]]; then #only if 'key=' default motion config
#    mpid=$(ps -eaf | grep "/$motion_conf" | grep -v "pts" | awk '{print $2}')
#    [[ -n $mpid ]] || return 1
#    kill -s 1 $mpid || { $mqtt_cmd/motion""$1/config/$3/state -m "#ERR#}"; return 0; } 
#  fi
  $mqtt_cmd/motion""$1/config/$3/state -m "$4"  
;;  
*) [[ $debug -ne 0 ]] && echo "[debug] [motion] '$2' has no case in \$act."
esac
}

function daemon_actions () { ###################################################
#act :: key1 :: key2 :: payload
#<hostname>/daemon/control <stop|restart> >> ../daemon/run/<param> OK 
#<hostname>/daemon/getcf <var> >> ../daemon/config/<param>/state  
#<hostname>/daemon/getrt <ssid|wifi|status|debug> >> ../daemon/run/<param>/state
#<hostname>/daemon/setcf/<key> <value> >> ../daemon/config/<key>/state <value> 
#<hostname>/daemon/setrt/<key> <value> >> ../daemon/run/<key>/state <value> 
local sr cmd; unset sr cmd
[[ $debug -ne 0 ]] && trap "error_handler" ERR
[[ ${#@} -ne 4 ]] && return 0 

case $1 in
"control") #payload=action 
  case $4 in
    "stop") flag_exit="stop";;
    "restart") flag_exit="restart";;
    "reload") kill -s SIGHUP $(cat $run_path/read.pid)
  esac
  [[ $debug -ne 0 ]] && { echo "[debug] [daemon] [$1] command: '$4'" && return 0; }
  $cmd || return 1
  $mqtt_cmd/daemon/control/$4 -m "EXECUTED"
;;
'get')
  case $2 in
  'cf') #payload=<config key>
    cmd="getconfig \"$4\" \"$conf_file\" \"=\""
    [[ $debug -eq 2 ]] && { echo "[debug] [daemon] [$1/$2] command: '$cmd'"; return 0; }
    sr=$(eval $cmd) || return 1 #execute
    $mqtt_cmd/daemon/config/$4/state -m "${sr:=null}"
  ;;
  'rt') #payload=<runtime var>
    case $4 in
      "ssid"|"wifi") sr=$(iwgetid);sr="${sr#*'ESSID:'}";;
      "status") sr=$(status --json);;
    *) [[ "$4" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]] && sr="${!4}" || return 1
    esac
    [[ -z $sr ]] && sr="#ERR#"
    $mqtt_cmd/daemon/run/$4/state -m "$sr"
  esac
;;
'set')
  case $2 in
  'cf') #key2=<config key>; payload=<new value>
    cmd="setconfig \"$3\" \"$4\" \"$conf_file\" \"=\"" 
    [[ $debug -eq 2 ]] && { echo "[debug] [daemon] [$1/$2] command: '$cmd'"; return 0; }
    eval $cmd || return 1 #execute
    $mqtt_cmd/daemon/config/$3/state -m "$4"
    #TODO: deamon reload
  ;;
  'rt') #key2=<runtime var>; payload=<new value>
    [[ "$3" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]] && cmd="$3=$4" || return 1
    [[ $debug -ne 2 ]] && { echo "[debug] [daemon] [$1/$2] Command: '$cmd'"; return 0; }
    eval $cmd 2>/dev/null || return 1 #exec
    $mqtt_cmd/daemon/run/$3/state -m "${!3}"; return 0
  esac
;;
*) [[ $debug -ne 0 ]] && echo "[debug] [daemon] '$1' has no case in \$act."
esac
}

function os_actions () { ###################################################
#act :: payload
#<hostname>/oscmd/<cmd> <args> >> ../oscmd/json "<json>" 
[[ $debug -ne 0 ]] && trap "error_handler" ERR
[[ ${#@} -ne 2 ]] && return 0 
case $1 in
'demo') cmd="demo $2"; sr="result of pseudo just for demo";;
'ls') return 0; cmd="ls $2"; sr="$(echo $(eval "$cmd"))";;
*) return 0
esac
json="{\"$topic\":{\"exec\":{\"cmd\":\"$1\",\"args\":\"$2\",\"res\":\""$sr"\"}}}"
$mqtt_cmd/oscmd/json -m "$json"
}

################################################################################
##### error/debug functions ####################################################
################################################################################

function error_handler () { ####################################################
  local error_code=$?; local error_line=$BASH_LINENO; local error_command=$BASH_COMMAND
  echo "[err] line $error_line: $error_command (exit code: $error_code)"
  # exit 1 #optional if exit is desired
}

function trap_term () {
local pid files f
#restore redirect
  exec 1>&3 2>&4
#send LWT offline message to mqtt4
  [[ -n $lwt_topic ]] && $mqtt_cmd/$lwt_topic -m "${lwt_disconnect:="offline"}"  
#delete files we created in $run_path
  files="mqtt.pid read.pid fifo heartbeat.pid watchdog.pid" #list of files to delete in $run_path
  for f in $files;do rm $run_path/$f 2>/dev/null; done
#finally get mosquitto_sub pid we started and terminate
  pid=$(ps -eaf | grep "$subscriber.*$topic" | grep -v "pts" | head -1 | awk '{print $2}') #mosquitto pid
  [[ -z $pid ]] && kill -s SIGTERM $pid 2>/dev/null
}

################################################################################
##### start/stop functions #####################################################
################################################################################

function start() { #############################################################
###check for running mqttsub.sh process; exit 0 if exists

local pid f fifo
#get mosquitto_pid we start identified by $subscriber and $topic
  pid=$(ps -eaf | grep "$subscriber.*$topic" | grep -v "pts" | head -1 | awk '{print $2}') #mosquitto pid
  [[ -n $pid ]] && echo "[OK] $service is already running [$pid]." && exit 0

#create runtime directories; TODO: avoid root privileges
for f in $run_path $log_path; do
  mkdir -p $f 2>/dev/null || { echo "[FAIL] Could not create runtime '$f'; check your permissions!"; exit 1; }
done
  
#create fifo pipe for mosquitto_sub mqtt messages received
fifo="$run_path/fifo" 
[[ ! -p $fifo ]] && { mkfifo $fifo || { echo "[FAIL] Could not create '$fifo'; check your permissions!"; exit 1; }; }

### start mosquitto_sub process ####################
($subscriber -h $broker_ip -p $broker_port -v -t "$topic/#" >$fifo 2>/dev/null & echo $! >&3) 3>"$run_path/mqtt.pid"
PID=$(cat $run_path/mqtt.pid 2>/dev/null) || { echo "[FAIL] $subscriber did not start!"; exit 1; }

( ### subshell daemon loop ####################
  [[ $debug -ne 0 ]] && trap "error_handler" ERR
#redirect output  
  exec 3>&1 4>&2;exec 1>> $run_path/debug.log 2>>$log_path/error.log
#set traps to handle signals
  trap "[[ -f $conf_file ]] && source $conf_file" SIGHUP
  trap "trap_term" EXIT SIGTERM
#start main daemon loop
  while read msg <$fifo; do
#...split mqtt message; $topic/cat/id/act/sbj <payload>
  unset id cat act sbj val
  tmp=${msg%%' '*};tmp=${tmp/"$topic/"}                       #get topic; remove $topic                              #
  id=$(echo $tmp | cut -d'/' -f 2);                           #get id (=2nd item)
  [[ $id == ?(-)+([0-9]) ]] && id="/$id" || unset id          #check if id is valid, else unset!
  tmp=${tmp/"$id/"/"/"}                                       #remove id
  cat="${tmp%%'/'*}";tmp=${tmp/"$cat/"/}                      #get cat=category [camera|motion|daemon|os]
  act="${tmp%%'/'*}";tmp=${tmp/"$act/"}                       #get act=action [get|set|detection|snapshot|control|<cmd>...]
  key1="${tmp%%'/'*}";tmp=${tmp/"$key1/"}                     #key1 [rt|cf|..|<var>]
  key2="${tmp##*'/'}"                                         #key2 [<var>]
  val=${msg#*' '}                                             #get payload >> val
#...start interpret/filter/actions here
  [[ $debug -ne 0 ]] && { echo "[debug] [received] $msg"; echo "[debug] [cat|id|act|sbj val] $cat|$id|$act|$sbj $val"; }
  case $cat in
  'camera') camera_actions $id $act $key1 "$val";;
  'motion') motion_actions $id $act $key1 "$val";;
  'daemon') daemon_actions $act $key1 $key2 "$val";;
  'oscmd') os_actions $act "$val";;
  *) [[ $debug -eq 1 ]] && { echo "[debug] received $msg";echo "[debug] [loop]'$cat' has no case in \$cat."; }
  esac
#...end interpret/filter/actions
#TODO: [[ -n $flag_exit ]] && break #stop or restart
  done #exit message read daemon loop; this happens when mosquitto_sub pid is killed!
#TODO: [[ -n $flag_exit ]] && ($0 $flag_exit) #restart daemon from mqtt
) & echo $! >"$run_path/read.pid" ### end subshell daemon loop

### started mqtt message daemon ####################
  [[ -n $lwt_topic ]] && $mqtt_cmd/$lwt_topic -m "${lwt_connect:="online"}"
  echo "[OK] Started $service [$(cat $run_path/mqtt.pid)]"
}

function stop() { ##############################################################
#stop a running mqtt-subscribe service by sending SIGTERM to mosquitto_sub pid.
# this will terminate mosquitto_sub and break the daemon's while read loop
# causing 'mqttsubs.sh' exit gracefully.
local pid
  pid=$(ps -eaf | grep "$subscriber.*$topic" | grep -v "pts" | head -1 | awk '{print $2}') #mosquitto pid
  [[ -n $pid ]] && { kill -s SIGTERM $pid 2>/dev/null;echo "[OK] $service stopped."; return 0; }
  echo "[INFO] $service is not running."; return 1
}

function status () { ###########################################################
local pid
  pid=$(ps -eaf | grep "$subscriber.*$topic" | head -1 | awk '{print $2}')
  [[ -z $pid ]] && { echo "[INFO] $service is not running."; exit 1; }
  json="{\"$topic\":{\"service\":{\"name\":\"$service\",\"status\":\"running\",\"pid\":\"$pid\",\"topic\":\"$topic\",\"broker\":\"$broker_ip\"}}}"
  msg="[OK] $service is running  [$pid].\n...Listening to topic '$topic' @ broker $broker_ip\n"
  [[ $1 =~ '--json' ]] && echo $json || echo -e "$msg"
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
lwt_topic="${lwt_topic:="LWT"}"
lwt_connect="${lwt_connect:="online"}"
lwt_disconnect="${lwt_disconnect:="offline"}"

#defaults motion
motion_conf=${motion_conf:="/etc/motioneye/motion.conf"}
motion=${motion:="127.0.0.1:7999"}

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
'status') status "$2";;
'debug_on') $mqtt_cmd/daemon/set/rt/debug -m "1";;
'debug_off') $mqtt_cmd/daemon/set/rt/debug -m "0";;  
'camera_ptz') camera_action "$1" "control" "$2" "$3";;
'on_motion_detected') on_motion_detected "$2";;
'on_camera_lost') on_camera_lost "$2";;
'on_camera_found') on_camera_found "$2";;
#'on_movie_start') :;; #on_event 'on_movie_start' "$2";;
#'on_movie_end') :;; #on_event 'on_movie_end' "$2";;
*) display_usage
esac
