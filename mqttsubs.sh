#!/bin/bash
################################################################################
# Purpose: Provide mosquitto listening daemon for motion/motioneye.            #
# Packages: motion, mosquitto-clients, [motioneye]                             #
# Version: v1.0                                                                #
# Author: Roland Ebener                                                        #
# Date: 2024/08/09                                                             #
################################################################################

#:L10 #ADJUST CODE IF THIS LINE CHANGES #>>> create pubstats.conf...$(sed -n 12,35p $0)...

# This config is used by 'mqttsub.sh' You must restart mqttsub.service or send
# SIGHUP to a started/running pid for changes to take effect.

#daemon config
#debug=0
debug=2

#mosquitto config
#subscriber="/usr/bin/mosquitto_sub"
#publisher="/usr/bin/mosquitto_pub"
#broker="127.0.0.1:1883"
broker="192.168.1.252:1883" # You need at least a broker ip address.
#topic="$(hostname)
#lwt_topic="LWT"
#lwt_connect="online"
#lwt_disconnect="offline"
#AlertBusTopic="ohab/security/AlertBus"
#EventBusTopic="ohab/security/EventBus"

#motion config
#motion_conf="/etc/motioneye/motion.conf"
motion_conf="$(dirname $(readlink -f "$0"))/motion.conf"
#motion"127.0.0.1:7999"
motion="192.168.1.129:7999"

#:L36 #ADJUST CODE IF THIS LINE CHANGES #>>> create pubstats.conf...$(sed -n 12,35p $0)...

################################################################################
##### HELPER FUNCTIONS #########################################################
################################################################################

function setconfig() { #########################################################
#key :: value :: path/file :: delimiter:=' '
#set a config key??value pair in configuration file
local s d 
  [[ -z $1 || -z $2 || -z $3 ]] && return 1 
  [[ ! -f $3 ]] && return 1 || d=${4:=' '}
#key=value already exits, replace line
  [[ -n $(grep "^[^#]\?\s*$1$d.*" "$3") ]] && s="$1$d"                      # 'key??value'
  [[ ${1:0:1} =~ [\&@] && -n $(grep "^#\?\s*$1$d.*" "$3") ]] && s="# $1$d"  # '# [&@]key??value' 
  [[ -n $s ]] && { sed -i "/^$s[0-9]*/c $s$2" "$3"; return 0; }             # inline sed replace line

#key=value does not exist, then add it
  s=$1$d$2;s=${s/'&'/'# &'}; s=${s/'@'/'# @'} #add '# ' to [&@] parameters
  cat >> $3 2>/dev/null <<EOF
# Added by $(basename $0), $(date '+%Y-%m-%d %H:%M:%S')
$s
EOF
return $?
}
function getconfig() { #########################################################
#key :: path/file :: delimiter:=' ' 
#get value for key??value in a configuration file
local s d 
  [[ -z $1 || -z $2 ]] && return 1
  [[ ! -f $2 ]] && return 1 || d=${3:=' '}
  s=$(grep "^[^#]\?\s*$1$d.*" "$2")                                          # 'key??value'
  [[ ${1:0:1} =~ [\&@] ]] && { s=$(grep "^#\?\s*$1$d.*" "$2");s=${s/'# &'/};s=${s/'# @'/}; } # '# [&@]key??value' 
  s=${s#*$d};s=${s%%' '*}; [[ -z $s ]] && return 1 || echo $s
  return 0
} 
function send_to_log () {
#topic :: severity :: message
local log_ufi="$log_path/$service.log" dat="$(date "+%Y-%m-%d %H:%M:%S")" 
  msg="[$dat] [$1] [${2^^}] $3"
  echo $msg #>> "$log_ufi"; return 0
}

################################################################################
##### EVENT FUNCTIONS ##########################################################
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
    s=$(jq -rn --arg x "$ME $evt %t" '$x|@uri')
    cmd="$http_cmd/0/config/set?$evt=$s"
    [[ $debug -ne 0 ]]  && send_to_log "set_motion_events" "debug" "cmd: '$cmd'"
    [[ $debug -eq 0 ]] && sr=$($cmd)
  done
#apply/write to motion config to make permanent
#  sr=$($http_cmd/0/config/write)
#  [[ $? -eq 0 ]] && { kill -s SIGHUP $(cat /tmp/motion.pid); } #SIGHUP to reload motion config files
  return 0
}

function on_motion_detected(){ #################################################
#id :: 
#actions to perform on mqtt bus when motion is detected by a camara
local tmpf cfgf deadtime priority msg mqtt_cmd0
  [[ -z $1 ]] && { echo "[ERR] Please provide a camera id."; return 1; }
#temporary file to allow for DeadTime, return 0 if exists
  tmpf="$run_path/.on_motion_detected.$1"
  [[ -f $tmpf ]] && return 0 || touch $tmpf  
#get config for motion detected
  cfgf="$(dirname $motion_conf 2>/dev/null)/camera-$1}"
  deadtime=$(getconfig "# &DeadTime" "$cfgf" " ")
  priority=$(getconfig "# &Priority" "$cfgf" " ")
  deadtime=${deadtime:=5}; priority=${priority:=0}
#publish to camera specific topic
  $mqtt_cmd/camera/$1/motion/state -m "1";
#publish to general/alert/event topic
  mqtt_cmd0=${mqtt_cmd%' -t'*};msg="$(hostname)::Camera-$1::AlertSent=$priority"
  [[ -n $AlertBusTopic && $priority -gt 0 ]] && $mqtt_cmd0 -t "$AlertBusTopic" -m "$priority"
  [[ -n $EventBusTopic ]] && $mqtt_cmd0 -t "$EventBusTopic" -m "$msg"
#time to reset motion on mqtt bus
  ( sleep $deadtime;$mqtt_cmd/camera/$1/motion/state -m "0";rm -f $tmpf 2>/dev/null; exit 0 ) &
  return 0
}

function on_camera_found(){ ####################################################
#actions to perform on mqtt bus when motion is detected by a camara
local s; unset s
  [[ -z $1 ]] && { echo "[ERR] Please provide a camera id."; return 1; }
  $mqtt_cmd/camera/$1/connected/state -m "1"
  [[ -z $EventBusTopic ]] && return 0
  s="$(hostname)::Camera-$1::found"
  ${mqtt_cmd%' -t'*} -t $EventBusTopic -m $s
  return 0
}

function on_camera_lost(){ #####################################################
#actions to perform on mqtt bus when motion is detected by a camara
local s; unset s
  [[ -z $1 ]] && { echo "[ERR] Please provide a camera id."; return 1; }
  $mqtt_cmd/camera/$1/connected/state -m "0";
  [[ -z $EventBusTopic ]] && return 0
  s="$(hostname)::Camera-$1::lost"
  ${mqtt_cmd%' -t'*} -t $EventBusTopic -m $s
  return 0
}

################################################################################
##### CAM APIs #################################################################
################################################################################

function run_camapi () { #######################################################
#/id :: cmd :: val
#This function transforms <cmd> to a 'http command' that can be send to a 
# net camera. It will get its config from special '# &keys' in the camera-id.conf
# You must configure '# &cam_api=' and there must be a 'netcam_url='.
local cfgf api ip ptzcmd cmd cmd1 cmd val sr

#get api, ip:port from config
cfgf="$(dirname $motion_conf 2>/dev/null)/camera-${1///}.conf"
api=$(getconfig "&cam_api" "$cfgf" " ") || return 1
ip=$(getconfig "netcam_url" "$cfgf" " ") || return 1
[[ $debug -eq 0 ]] && send_to_log "run_camapi" "debug" "api=$api@$ip."

case $api in 
'foscam1') #api for a foscam up v1.2 e.g. ipcam01
  ptzcmd="$ip/<cmd>&user=admin&pwd="; cmd="decoder_control.cgi?command="
  cmd1="camera_control.cgi?param="; cmd2="set_misc?"; val="$3"
  case "$2" in
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
  [[ $debug -ne 0 ]] && { send_to_log "run_camapi" "debug" "exec: $cmd"; return 0; }
  sr=$(eval $cmd); [[ ${sr#'='*} =~ "\"ok\"" ]] && return 0 || return 1
;;
'foscam2') return 1;;
esac
}

################################################################################
##### DAEMON FUNCTIONS #########################################################
################################################################################

function camera_actions () { ###################################################
#/id :/: act :/: key1 :#: payload
#<hostname>/camera/<id>/ptz/<key> <value> >> ../<id>/ptz/<key>/state <value> 
[[ $debug -ne 0 ]] && send_to_log "motion_actions" "debug" "[\$1::\$2::\$3::\$4] >> $1::$2::$3::$4"
[[ ${#@} -ne 4 ]] && return 1
[[ "${1///}" -eq 0 ]] && return 1 #camid must be specified and -ne 0
case $2 in
'control') 
  run_camapi "$1" "$3" "$4" || return 1
  case $3 in #depending on sbj return ../act/sbj/state
  "ir") $mqtt_cmd/camera""$1/$2/$3/state -m $4;;
  "led") $mqtt_cmd/camera""$1/$2/$3/state -m $4;;
  esac
;;
'detection'|'snapshot'|'get'|'set') motion_actions $1 $2 $3 $4;;
*) send_to_log "camera_actions" "debug" "'$2' has no case in \$act."; return 0
;;
esac
}

function motion_actions () { ###################################################
#/id :/: act :/: key1 :#: payload
#<hostname>/motion/<id>/action/detection|snapshot|makemovie|restart ON|OFF >> ../<id>/action/<key>/state <value>
#<hostname>/motion/<id>/get/config <key> >> ../<id>/config/<key>/state <value>
#<hostname>/motion/<id>/get/run <key> >> ../<id>/run/<key>/state <value>
#<hostname>/motion/<id>/set/<key> <value> >> ../<id>/config+run/<key>/state <value>
local cfgf cmd sr s
[[ $debug -ne 0 ]] && send_to_log "motion_actions" "debug" "[\$1::\$2::\$3::\$4] >> $1::$2::$3::$4"
[[ ${#@} -ne 4 || -z $1 ]] && return 1 #must have a camera id (/0.../n)
[[ "${1///}" -ne 0 ]] && cfgf="camera-${1///}.conf"
cfgf="$(dirname $motion_conf)/${cfgf:="motion.conf"}"

case $2 in
'action')
  case $3 in 
  'detection') #switch ON|OFF >> state
    case $4 in
    'ON'|1 ) cmd="$http_cmd""$1/detection/start";;
    'OFF'|0 ) cmd="$http_cmd""$1/detection/pause";;
    *) return 0
    esac
    [[ $debug -ne 0 ]] && { send_to_log "motion_actions" "debug" "exec: $cmd"; return 0; }
    sr=$(eval "$cmd") || return 1; sr=${$4^^} 
  ;;
  'snapshot'|'makemovie') #toggle ON >> OFF
    case $4 in
    'ON'|1) cmd="$http_cmd""$1/action/$3";;
    *) return 0
    esac 
    [[ $debug -ne 0 ]] && { send_to_log "motion_actions" "debug" "exec: $cmd"; return 0; }
    sr=$(eval "$cmd") || return 1; sr="$([[ $4 =~ ON ]] && echo "OFF" || echo "0")"
  ;;
  'restart') #payload=YES >> OK
    case $4 in
    'YES') cmd=$http_cmd/0/action/restart;;
    *) return 0
    esac
    [[ $debug -ne 0 ]] && { send_to_log "motion_actions" "debug" "exec: $cmd"; return 0; }
    sr=$(eval "$cmd") || return 1; sr="OK"
  esac
  $mqtt_cmd/motion""$1/$3/state -m "${sr:="#err#"}"
;;

'get') #key1=config|run payload=<param> >> <param value>
  case $4 in #payload
  'detection') #special case detection
    cmd="$http_cmd""$1/detection/status";
    [[ $debug -ne 0 ]] && { send_to_log "motion_actions" "debug" "exec: $cmd"; return 0; }
    sr=$(eval $cmd)
    case $(echo ${sr#*'status'} | tr -d '[:blank:]') in
      'ACTIVE') sr="ON";;'PAUSE') sr="OFF"
    esac
  ;;
  *) #any motion parameter
    cmd="$http_cmd""$1/config/get?query=$4"
    [[ $debug -ne 0 ]] && { send_to_log "motion_actions" "debug" "exec: $cmd"; return 0; }
    sr=$($cmd | grep -i "$4")
    [[ -n $sr && $? -eq 0 ]] && { sr=${sr#*'='};sr=${sr%'Done'*};sr=$(echo $sr | tr -d '[:blank:]'); }   
  esac
  $mqtt_cmd/motion""$1/get/$4/state -m "${sr:="#err#"}"
;;

'set') #key1=<param>, payload=<new value>, <param> must be in whitelist >> <new value>
#get list of all motion parameters
#s=$(curl -s 192.168.1.129:7999/1/config/list);s=${s// /}
#s=$(grep "movie_quality" <<<"$s");echo $?;echo $s
#check prerequistes to set motion parameters
  [[ -n $(cat $motion_conf 2>/dev/null | grep "webcontrol_parms.*3") ]] && sr=1
  [[ -f "$whtl_ufi" && $sr -eq 1 ]] || unset sr
  [[ -z $sr ]] && { $mqtt_cmd/motion/set/state -m "#disabled#";return 0; }
#check if parameter is included in $whtl_ufi
  sr=$(cat "$whtl_ufi" 2>/dev/null | grep "$3")
  [[ -z $sr ]] && { $mqtt_cmd/motion""$1/set/$3/state -m "#blocked#"; return 0; }
#try to set motion runtime parameter; exclude parameters starting with '@' or '&' 
  if [[ ${3:0:1} =~ [^\&@] ]]; then 
    s=${4//'%'/'%25'};s=${s//' '/'%20'} #url encode s=$(jq -rn --arg x $4 '$x|@uri')
    cmd="$http_cmd""$1/config/set?$3=$s" 
    [[ $debug -ne 0 ]] && { send_to_log "motion_actions" "debug" "exec: $cmd"; return 0; }
    sr=$($cmd) && sr="$4" || sr="#err#" #exec
  fi
#if we get here, also set the parameter in the config file, this will also set [\&@] 
  cmd="setconfig \"$3\" \"$4\" \"$cfgf\" ' '"
  [[ ! -f $cfgf ]] && return 1 #return if config file does not exist
  eval $cmd && sr="$4" || sr="#err#" #exec
  $mqtt_cmd/motion""$1/get/$3/state -m "$sr"
;;
*) send_to_log "motion_actions" "debug" "'$2' has no case in \$act."; return 0
esac
}

function daemon_actions () { ###################################################
#act :/: key1 :/: key2 :#: payload
#<hostname>/daemon/control <stop|restart|reload|debug> >> ../daemon/control/<param>/state OK|#err# 
#<hostname>/daemon/get/ <var> >> ../daemon/get/<var>/state  
#<hostname>/daemon/set/<var> <new value> >> ../daemon/get/<var>/state <new value> 
local sr cmd pid
[[ $debug -ne 0 ]] && send_to_log "daemon_actions" "debug" "[\$1::\$2::\$3] >> $1::$2::$3"
[[ ${#@} -ne 3 ]] && return 1
case $1 in
"control") #payload=action 
  case $3 in
    'stop') cmd="flag_exit=stop";;
    'restart') cmd="flag_exit=restart";;
    'reload') pid=$(cat "$run_path/$service-loop.pid" 2>/dev/null) \
              && cmd="kill -s SIGHUP $pid 2>/dev/null" \
              || cmd="#err#"; sr="#err#";;
    'debug') cmd="debug=$val";sr="$val";;
    *) cmd="#err#"
  esac
  [[ $debug -ne 0 ]] && { send_to_log "daemon_actions" "debug" "exec: $cmd"; return 0; }
  eval "$cmd" && sr="${sr:="OK"}" || sr="#err#"
  $mqtt_cmd/daemon/control/$3/state -m "${sr:="#err#"}"
;;
'get') #payload=<param> >> <param value>
  case $3 in
  "ssid"|"wifi") sr=$(iwgetid);sr="${sr#*'ESSID:'}";;
  "status") sr=$(status --json);;
  *) [[ "$3" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]] && [[ -n ${!3} ]] && sr="${!3}"
  esac
  $mqtt_cmd/daemon/get/$3/state -m "${sr:="#err#"}"
;;
'set') #key1=<param>, payload=<new value>, <param> must be in whitelist >> <new value>
  #check if parameter is included in $whtl_daemon
  sr=$(echo "$whtl_daemon" 2>/dev/null | grep "$2")
  [[ -z $sr ]] && { $mqtt_cmd/daemon/get/$2/state -m "#blocked#"; return 0; } || unset sr
  [[ "$2" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]] && cmd="$2=\"$3\"" || unset cmd
  [[ $debug -ne 0 ]]  && { send_to_log "daemon_actions" "debug" "exec: ${cmd:"#err#"}"; return 0; }
  [[ -n $cmd ]] && eval "$cmd" 2>/dev/null && sr="${!3}"
  $mqtt_cmd/daemon/get/$2/state -m "${sr:="#err"}"
;;
*) send_to_log "daemon_actions" "debug" "'$1' has no case in \$act."; return 0
esac
}

function os_actions () { ###################################################
#act :: payload
#<hostname>/oscmd/<cmd> <args> >> ../oscmd/json "<json>" 
[[ ${#@} -ne 2 ]] && return 1
case $1 in
'demo') cmd="demo $2"; sr="result of pseudo just for demo";;
'ls') return 0; cmd="ls $2"; sr="$(eval "$cmd")";;
*) send_to_log "os_actions" "debug" "'$1' has no case in \$act."; return 0
esac
json="{\"$topic\":{\"exec\":{\"cmd\":\"$1\",\"args\":\"$2\",\"res\":\""$sr"\"}}}"
$mqtt_cmd/oscmd/json -m "$json"
}

################################################################################
### INSTALL/SETUP FUNCTIONS ####################################################
################################################################################

function install_packages () { #################################################
local pkg miss err_pkg uinp
#get missing packages
  for pkg in $inst_pkgs; do
    dpkg -s "$pkg" >/dev/null 2>&1 && continue || miss+="$pkg "
  done
#user interface
  if [[ -n "$miss" ]]; then
    read -t 10 -n 3 -p "# Missing packages '$miss'.Enter YES to install now." uinp
    case $uinp in
    'YES') echo -e "\n# Install missing packages...";;
    *) echo -e "[ERR] Missing packages not installed, please install $inst_pkgs manually."; return 10;;
    esac
  else
    echo "[OK] Required packages are already installed."; return 0
  fi
#auto install packages
  for pkg in $miss; do
    apt-get -y install $pkg &>/dev/null || { echo "[ERR] Package '$pkg' not installed, please install manually."; err_pkg+="$pkg "; } 
  done
  [[ -z "$err_pkg" ]] && { echo "[OK] Required packages were installed successfully."; return 0; }
  return 11
}

function install_program () { ##################################################
local dst
  dst="$inst_path/$(basename $0)"
  echo "# Copy '$(basename $0)' to $dst."
  cp $0 $dst && chown root:root $dst && chmod 751 $dst && return 0
  return 21
}

function install_systemd () { ##################################################
echo "# Create /etc/systemd/system/$service.service"
#unit file definition
  cat > "/etc/systemd/system/$service.service" <<EOF || return 31
[Unit]
Description="MQTT Publish Statistics"
After=network.target

[Service]
Type=forking
ExecStart=/bin/bash -c "$inst_path/${basename $0} start"
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF
#daemon-reload+enable+start
  systemctl daemon-reload || { echo ":( systemctl daemon-reload failed."; return 32; }
  echo -e "[OK] Installed $service.service."
  read -t 10 -n 3 -p "# Do you want to enable and start $service.service?" uinp
  case $uinp in
  'YES') 
     systemctl enable $service.service || { echo ":( Could not enable $service.service"; return 33; }
     systemctl start $service.service || { echo ":( Could not start $service.service"; return 34; }
  ;;
  *) echo -e "To enable $service.service please run:
> systemctl daemon-reload && systemctl enable $service && systemctl start $service.service" 
  esac
}

function install_config () { ###################################################
local uinp conf_path
conf_path="/etc/$service"
  echo "# Create default config in $conf_path."
#check if $conf_path exists.
  [[ -d $conf_path ]] && {
     read -t 10 -n 3 -p "# Config in $conf_path already exists. YES to overwrite ALL." uinp
     case $uinp in
     'YES') echo "# Overwrite existing config in $conf_path.";;
     *) echo -e "[OK] Using existing config in $conf_path."; return 0;;
     esac; }
#create .conf...
  mkdir -p  $conf_path || return 41
  cat > $conf_path/$service.conf <<EOF || return 42
#Default config file for $service created $(date '+%Y-%m-%d %H:%M:%S').
$(sed -n 12,35p $0)
EOF
  echo "List of motion/daemon parameters that may be changed by mqttsubs." > $conf_path/whitelist
  echo "[OK] Default '$service.conf' created in $conf_path."
}

function setup() { #############################################################
  [[ $EUID -ne 0 ]] && { echo "[FAIL] You are not root!. Only root can install this program."; exit 1; }
  install_packages || { echo "[FAIL] [$?] Could not install required packages."; exit 1; }
  install_program || { echo "[FAIL] [$?] Could not install ${basename $0}."; exit 1; }
  install_config || { echo "[FAIL] [$?] Could not install default config file."; exit 1; }
  install_systemd || { echo "[FAIL] [$?] Could not install systemd unit file."; exit 1; }
}

################################################################################
##### ERROR/DEBUG FUNCTIONS ####################################################
################################################################################

function trap_error () { #######################################################
#error trap called on ERR
  local dat=$(date "+%Y-%m-%d %H:%M:%s") code=$? line=$BASH_LINENO cmd=$BASH_COMMAND
  echo "[$dat] [ERR@$line>>$code] $cmd" >> $log_path/error.log
  # exit 1 #optional if exit is desired
}

function trap_term () { ########################################################
#terminate trap called on EXIT or SIGTERM
local pid files f
#send LWT offline message to mqtt
  [[ -n $lwt_topic ]] && $mqtt_cmd/$lwt_topic -m "${lwt_disconnect}"  
#terminate mosquitto_sub; this will also terminate the daemon loop!
  pid=$(cat $run_path/$service.pid 2>/dev/null)
  [[ -n $pid ]] && kill -s SIGTERM $pid 2>/dev/null
#delete all files we created in $run_path
  rm -rf $run_path/* 2>/dev/null
exit
}

################################################################################
### START/STOP FUNCTIONS #######################################################
################################################################################

function start() { #############################################################
#start daemon; save pid to $run_path/$service.pid
#check running, prep, mosquitto_sub &, loop, started
local pid f fifo sr

[[ $EUID -ne 0 ]] && { echo "[FAIL] You are not root!. Only root start $service."; exit 1; }

#check if already running
  pid=$(cat $run_path/$service.pid 2>/dev/null)
  [[ -n $pid ]] && echo "[OK] $service is already running [$pid]." && exit 0

#create runtime folders; TODO: avoid root privileges
for f in $run_path $log_path; do
  mkdir -p $f 2>/dev/null || { echo "[FAIL] Could not create runtime '$f'; check your permissions!"; exit 1; }
done; cd $run_path
  
#create fifo pipe for mosquitto_sub mqtt messages received
fifo="$run_path/fifo" 
[[ ! -p $fifo ]] && { mkfifo $fifo || { echo "[FAIL] Could not create '$fifo'; check your permissions!"; exit 1; }; }

### start mosquitto_sub process ####################
($subscriber -h $broker_ip -p $broker_port -v -t "$topic/#" >$fifo 2>/dev/null & echo $! >&3) 3>"$run_path/$service.pid"
pid=$(cat $run_path/$service.pid) 2>/dev/null
[[ -z $pid ]] && { echo "[FAIL] $subscriber did not start!"; exit 1; }

trap "trap_term" SIGTERM
trap "trap_error" ERR
( ### start daemon loop ####################
  #redirect stdin stdout stderr
  [[ $debug -eq 0 ]] && exec 0<&- 1>>$log_path/$service.log 2>>$log_path/error.log
#set traps to handle signals
  trap "[[ -f $conf_ufi ]] && source $conf_ufi" SIGHUP
  trap "trap_term" EXIT
#start main daemon loop
while read msg <$fifo; do
#...split mqtt message; $topic/cat/id/act/key1/key2 <payload>
  unset id cat act sbj val
  tmp=${msg%%' '*};tmp=${tmp/"$topic/"}                       #get topic, remove $topic
  id=$(echo $tmp | cut -d'/' -f 2);                           #get id
  [[ $id =~ ^[0-9]+ ]] && id="/$id" || unset id               #check if id is valid, else unset!
  tmp=${tmp/"$id/"//}                                         #remove id
  cat="${tmp%%'/'*}";tmp=${tmp/"$cat/"}                       #get cat=category [camera|motion|daemon|os]
  act="${tmp%%'/'*}";tmp=${tmp/"$act/"}                       #get act=action [get|set|detection|snapshot|control|<cmd>...]
  key1="${tmp%%'/'*}";tmp=${tmp/"$key1/"}                     #key1 [config|run|..|<var>]
  key2="${tmp##*'/'}"                                         #key2 [<var>]
  val="${msg#*' '}"                                           #get payload >> val
#...start interpret/filter/actions here
  [[ ${tmp##*"/"} =~ state ]] && continue                     #ignore topics ending with /state
  [[ $debug -ne 0 ]] && send_to_log "start:loop" "debug" "$msg >> [cat|id|act|key1|key2#val] $cat|$id|$act|$key1|$key2#$val"
  [[ $debug -eq 1 ]] && continue
  case $cat in
  'camera') camera_actions "$id" "$act" "$key1" "$val";;
  'motion') motion_actions "$id" "$act" "$key1" "$val";;
  'daemon') daemon_actions "$act" "$key1" "$val";;
  'oscmd') os_actions "$act" "$val";;
  *) send_to_log "start:loop" "debug" "'$cat' has no case in \$cat."
  esac
#...end interpret/filter/actions
  [[ -n $flag_exit ]] && break                                #stop or restart from mqtt
done #end daemon loop; trapped (this happens when mosquitto_sub pid is killed)
[[ -n $flag_exit ]] && ( sleep 2;$ME $flag_exit ) &  #restart daemon from mqtt
) #& echo $! > "$run_path/$service-loop.pid" # end subshell daemon loop

### started daemon ####################
  [[ -n $lwt_topic ]] && $mqtt_cmd/$lwt_topic -m "${lwt_connect}"
  [[ -n $(cat $motion_conf 2>/dev/null | grep "webcontrol_parms.*3") ]] && sr="enabled"
  [[ -f "$$whtl_ufi" && -n $sr ]] || sr="disabled"
  sr="Started $service service [$pid], listening to '$topic/#', set_motion_params=${sr:="disabled"}"
  echo "[OK] $sr"; send_to_log "daemon:start" "OK" "$sr"
exit 0
}

function stop() { ##############################################################
#stop a running daemon service by sending SIGTERM to mosquitto_sub.
local pid
  pid=$(cat $run_path/$service.pid 2>/dev/null)
  [[ -z $pid ]] && { echo "[INFO] $service is not running."; exit 1; } 
  kill -s SIGTERM $pid 2>/dev/null && { echo "[OK] $service stopped."; exit 0; }
}

function status () { ###########################################################
local pid
  pid=$(cat $run_path/$service.pid 2>/dev/null)
  [[ -z $pid ]] && { echo "[INFO] $service is not running."; exit 1; }
  json="{\"$topic\":{\"service\":{\"name\":\"$service\",\"status\":\"running\",\"pid\":\"$pid\",\"topic\":\"$topic\",\"broker\":\"$broker_ip\"}}}"
  msg="[OK] $service is running [$pid].\n...Listening to topic '$topic' @ broker $broker_ip\n"
  [[ $1 =~ '--json' ]] && echo $json || echo -e "$msg"
  return 0
}

#function watchdog () { #########################################################
# this will scan motion.log for fatal daemon error and then try to restart via http command
# key: "[0:motion] [ERR] [ALL] motion_watchdog: Thread 1 - Watchdog timeout did NOT restart, killing it!"
#  [[ -f $run_path/watchdog.pid ]] && return 0
#  ( trap rm $run_path/watchdog.pid 2>/dev/null EXIT
#    (tail -Fn0 "$motion_log" & echo $! >&3) 3>"$run_path/watchdog.pid" | \
#    while read line ; do
#      $(echo $line | grep "\\[0:motion\\].* \\[ERR\\].*killing it!" >/dev/null 2>&1) || continue
#      $http_cmd/0/action/restart && $mqtt_pub/$lwt_topic -m "$lwt_connect"
#      echo "[$(date '+%Y/%m/%d %T')] [WD] [WRN] Restart motion daemon via http command."
#  done ) &
#}

#function heartbeat () { ########################################################
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
##### HELP/USAGE FUNCTIONS #####################################################
################################################################################

function showuse() { ###########################################################
  cat <<EOF
$(sed -n 638,644p $0) 
EOF
  exit 0
}

function showhelp () { #########################################################
cat <<EOF
##### ABOUT ####################################################################
'mqttsubs.sh' is a bash script to enable control of motioneye via the 
 mqtt protocol. It uses mosquitto-clients package to subscribe- and publish
 to '$topic/#'. 
  
USAGE: $> ./$(basename $0) start|status [options], [stop|restart]

OPTIONS:
  start --debug [level]    :: debug mode, no commands are executed, default level 1
                              level: 1 >> echo split msg >> cat/id/act/key1/key2#payload
                              level: 2 >> run action >> send to log
  status --json            :: display status in json format
                              
MQTT: $='$topic'
  $/camera/<camid>/[control/<var>|get/config|get/run|set/<var>] # <val>
  $/motion/<camid>/[detection|snapshot|get/config|get/run|set/<var>] # <val>
  $/daemon/[control|get/config|get/run|set/config/<var>|set/run/<var>] # <val>                            
  $/oscmd/[udef] 
  
Note: To set motion parameters, 'webcontrol_parms 3' must be set in 'motion.conf'
      file and 'set' command <var> must be included in a 'whitelist' file.

See: https://www.lavrsen.dk/foswiki/bin/view/Motion/MotionHttpAPI
                                 
EOF
exit 0
}

################################################################################
##### MAIN #####################################################################
################################################################################
#program static defs do NOT change!
ME=$(dirname $(readlink -f "$0"))
inst_path="/usr/sbin" #used during setup to copy this script
inst_pkgs="bc motion mosquitto-clients"
service="${service:="mqttsubs"}"
run_path="${run_path:="/var/run/$service"}"
log_path="${log_path:="/var/log/$service"}"

conf_ufi="/etc/$service/$service.conf" #default when installed
[[ ! -f $conf_ufi ]] && conf_ufi="$ME/$service.conf" #fallback
[[ -f $conf_ufi ]] && source "$conf_ufi"
whtl_ufi="$(dirname $conf_ufi)/whitelist"
whtl_daemon="debug"

#-- defaults, can be part of a config file -------------------------------------
#defaults daemon
debug=${debug:=0}

#defaults mosquitto
subscriber="${subscriber:="/usr/bin/mosquitto_sub"}"
publisher="${publisher:="/usr/bin/mosquitto_pub"}"
broker=${broker:="127.0.0.1:1883"}
topic="${topic:=$(hostname)}"
lwt_topic="${lwt_topic:="LWT"}"
lwt_connect="${lwt_connect:="online"}"
lwt_disconnect="${lwt_disconnect:="offline"}"
AlertBusTopic="ohab/security/AlertBus"
EventBusTopic="ohab/security/EventBus"

#defaults motion
motion_conf=${motion_conf:="/etc/motioneye/motion.conf"}  #default for motioneye
[[ ! -f $motion_conf ]] && motion_conf="$ME/motion.conf"  #fallback
motion=${motion:="127.0.0.1:7999"}
#-- end defaults ---------------------------------------------------------------

#set roots
broker_ip="${broker%:*}";broker_port="${broker/"$broker_ip"/}"; broker_port="${broker_port/:/}"
motion_ip="${motion%:*}";motion_port="${motion/"$motion_ip"/}"; motion_port="${motion_port/:/}"
http_cmd="curl -s http://$motion_ip:$motion_port"
mqtt_cmd="$publisher -h $broker_ip -p $broker_port -t $topic"

#get options
case $2 in
'--debug') debug=${3:=1};;
'--json'):;; #used in status action
esac

case $1 in
'-?'|'-h'|'--help') showhelp;; 
'start') start; set_motion_events;;
'stop') stop;;
'restart') stop;sleep 2;start;;
'status') status "$2";;
'install') setup;;
'camera_ptz') camera_action "$1" "control" "$2" "$3";;
'on_motion_detected') on_motion_detected "$2";;
'on_camera_lost') on_camera_lost "$2";;
'on_camera_found') on_camera_found "$2";;
#'on_movie_start') :;; #on_event 'on_movie_start' "$2";;
#'on_movie_end') :;; #on_event 'on_movie_end' "$2";;
*) showuse
esac


