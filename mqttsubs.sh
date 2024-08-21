#!/bin/bash
################################################################################
# Purpose: Publish System Info to a mqtt-server.                               #
# Packages: bc netcat-openbsd mosquitto-clients                                #
# Version: v1.0                                                                #
# Author: Roland Ebener                                                        # 
# Last Change: 2024/08/09                                                      #
################################################################################

#:L10 #ADJUST CODE IF THIS LINE CHANGES #>>> create pubstats.conf...$(sed -n 12,52p $0)...

# This config is used by pubstats.sh. You must restart pubstats.service or send
# SIGHUP to a started/running pid for changes to take effect.
# For poll_interval use: Y|Q|M|W;d|h|m|s; see also time2seconds() function.
# A poll interval of -1 or '' disables polling.
# bflag: ct cl mu su du pd dc so (temp load memu swpu dsku prcd dirc srvo)

#daemon config
#daemon_pi=15s        #should be less than the smallest poll_interval set

#mosquitto config
# You need at least a broker ip address. The default topic is the host's name.
broker="192.168.1.252:1883"
#topic="myTopic"      #default=$(hostname)
#publish_pi=          #default=5m, i.e send to mqtt bus every 5 minutes

#poll user functions
#wanip_provider=      #default: "https://api.ipify.org"
#wanip_topic=         #default: "$topic/wan"
#wanip_pi=1m          #comment or set to '-1' to disable
#rut955_pi=1m         #comment or set to '-1' to disable
#bind_root_pi=1M      #comment or set to '-1' to disable

#poll intervals; to disable comment or set to '-1' 
#time spans allowed: Y)ear,Q)uarter,M)onth,W)eek,d)ays h)ours m)inutes s)econds
#e.g. 30s = every 30 seconds; 1M = once every month; 2Q = once every 1/2 Year
#cpu_temp_pi=30s
#cpu_load_pi=30s
#mem_use_pi=30s
#swap_use_pi=30s
#proc_degraded_pi=5m
#disk_use_pi=3h
#server_offline_pi=30m
#dir_change_pi=1d

#critical thresholds; when reached bflag is set
#cpu_temp_warn=65
#cpu_load_warn=75
#mem_use_warn=75
#swap_use_warn=65
#disk_use_warn=75

#:L54 #ADJUST CODE IF THIS LINE CHANGES #>>> create pubstats.conf...$(sed -n 12,52p $0))...

################################################################################
###### HELPER FUNCTIONS ########################################################
################################################################################

function is_valid_ip () {
#checks string for valid ip address
#if valid echo $1,return 0 else echo "", return 1
  echo "$1" | grep -Eo '^(([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))\.){3}([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))$' 
  return $?
}
time2seconds() {
local input=$1; input=${input:=1s} ; default=1s
  sed 's/Y/*24*3600*365 +/g; s/Q/*24*3600*90 +/g; s/M/*24*3600*30 +/g; s/W/*24*3600*7 +/g; s/d/*24*3600 +/g; 
       s/h/*3600 +/g; s/m/*60 +/g; s/s/\+/g; s/+[ ]*$//g' <<< "$input" | bc
}
function time_elapsed() {
# checks if a given amount of time for an identifier elapsed.
# $1 id; eg: mem, cpu, dir, disk etc...
# $2 time interval in format  time2seconds format, e.g. "1m"; "3m 30s"
# returns 0 if time elapsed, 1 if not.
local file interval previous current elapsed
  [[ $RUNAS_DAEMON -ne 1 ]] && return 0 #time is always over!
  [[ -z $2 ]] && return 1 #empty =~ disable!, time is never over
  [[ "$(sed s/[^0-9,-].*// <<<$s)" -eq "-1" ]] && return 1 #disable!
  file="$run_path/.$1.timer"
  [[ -f $file ]] || { touch $file; return 0; } #first call, time is over!
  current=$(date +"%s")  
  previous=$(date +"%s" -r $file)
  interval=$(time2seconds "$2" || return 2) # return=2 interval format, disabled
  elapsed=$(( $current - $previous ))
  [[ $elapsed -ge $interval ]] && { touch $file; return 0; } #time is over
  return 1 #time is not over
}
function get_average () {
local line val=0 samples=0 
  file="$run_path/.$1.samples"; [[ -f "$file" ]] || return 1
  while read line; do   
    samples=$(($samples+1))
    val=$(awk -v a=$val -v b=$line 'BEGIN { print a+b }' ) 
  done < <(cat $file); 
  rm $file > /dev/null 2>&1
  echo $(awk -v a=$val -v b=$samples 'BEGIN{ printf "%0.1f", a/b }')
}
function send_to_log () {
#$1=topic;$2=severity;$3=message
local logf="$log_path/$service.log" dat="$(date "+%Y-%m-%d %H:%M:%S")" 
  msg="[$dat] [$1] [${2^^}] $3"
  [[ $RUNAS_DAEMON -ne 0 ]] && { echo $msg; return 0; }
  echo $msg >> "$logf"; return 0
}

################################################################################
### DAEMON FUNCTIONS ###########################################################
################################################################################

### USER DEFINED ###############################################################
function publish_template () {
  #time_elapsed "<publish_template>" $<mypub_pi> || return 0
  #...you actions
  # $publisher -h $broker_ip -p $broker_port -t "<my/topic>" -m "<mypayload>"
  #send_to_log "<identifier>" "<status>" "<message>"
  return 0
}

function get_rut955 () {
#get info from router RUT955
local topic topics
  [[ -z $rut955_pi ]] && return 1
  time_elapsed "get_rut955" $rut955_pi || return 0
  topics="signal connection network operator"
  for topic in $topics;do
    $publisher -h $broker_ip -p $broker_port -t "router/get" -m "$topic" >/dev/null 2>&1
  done
}

function update_bind_root () {
  time_elapsed "update_bind_root" $bind_root_pi || return 0
  curl -s -o "/etc/bind/db.root" "https://www.internic.net/domain/named.root"
  [[ $? -ne 0 ]] && { send_to_log "update_bind_root" "WARN" "Could not download files."; return 1; }
  systemctl restart bind9
  [[ $? -ne 0 ]] && { send_to_log "update_bind_root" "FAIL" "systemctl restart bind9 failed."; return 1; }
  send_to_log "update_bind_root" "OK" "Bind9 root servers '/etc/bind/db.root' update success."
}

### MONITORS ###################################################################
function monitor_gen () {
#Arguments: [$1] = cpu_temp || cpu_load || mem_use || swap_use
local pi thres val msg txt device disk_use process serv cmd pname ip port
pi="${1,,}""_pi"; pi=${!pi} #get value from "${1,,}_pi" pointer
thres="${1,,}""_warn"; thres=${!thres};
  time_elapsed "$1" "$pi" || return 0
  case $1 in 
  "cpu_temp") 
    val=$(vcgencmd measure_temp 2>/dev/null | cut -d'=' -f2 | cut -d"'" -f1) || return 1
    msg="CPU temperature reached $val °C.";;
  "cpu_load") 
    val=$(grep 'cpu ' /proc/stat | awk '{usage=100-($5*100)/($2+$3+$4+$5+$6+$7+$8)} END {printf "%0.2f", usage}') 
#    val=$(top -b -n 1 | grep Cpu | cut -d',' -f 4);val=${val/' id'/};val=$(echo $val | cut -d'.' -f1); val=$((100 - $val))
    msg="CPU Load reached $val %.";;
  "mem_use") 
    val=$(free -mt | grep "Mem:" | awk '{print $2 " " $3}' | awk '{ if($2 > 0) printf "%0.2f", $2 / $1 * 100; else print 0}')
    msg="Memory reached $val %.";;
  "swap_use") 
    val=$(free -mt | grep "Swap:" | awk '{print $2 " " $3}' | awk '{ if($2 > 0) printf "%0.2f", $2 / $1 * 100; else print 0}')
    msg="Swap space reached $val %.";;
  "disk_use")  
    while read line; do
      device=$(echo $line | cut -d" " -f1)
      disk_use=$(echo $line | cut -d" " -f5 | sed "s/%//")
      [[ $disk_use -ge $thres ]] && txt+="${device%* }""!$disk_use%,"    
    done < <(df -h | grep -v "tmp" | grep "/dev/")
    txt="${txt%,*}"; msg="Disk(s) $txt reached capacity limit.";;
  "proc_degraded")
    while read line; do
      [[ "$line" = "" ]] && continue
      process=$(echo $line | cut -d":" -f1 | sed "s/ //")
      serv=$(echo $line | cut -d":" -f2 | sed "s/ //")
      cmd=$(echo $line | cut -d":" -f3 | sed "s/ //")
      [[ "$(ps -A | grep $process)" != "" ]] && continue
      txt+="${serv%* },"
      [[ $RUNAS_DAEMON -eq 0 ]] && continue
      #TODO test: restart service or custom program; THIS IS A HUUUGE SECURITY RISK!!!    
      #    [[ -z $systemctl_cmd ]] && continue 
      #    [[ -n "$(echo $cmd | grep -i default)" ]] && eval "$systemctl_cmd $serv" || $cmd &   
    done < <(grep -v "#" $proc_list)
    txt="${txt%,*}"; msg="Process(es) $txt degraded.";;
  "server_offline")
    while read line; do
      [[ "$line" = "" ]] && continue
      pname=$( echo $line | cut -d":" -f1 | sed "s/ //")
      ip=$(echo $line | cut -d":" -f2 | sed "s/ //")
      port=$(echo $line | cut -d":" -f3 | sed "s/ //")
      if [[ -n $port && ! $port =~ "none" ]]; then
        netcat -w 5 -z "$ip" "$port" > /dev/null 2>&1 tcp=$?
        netcat -w 5 -uz "$ip" "$port" > /dev/null 2>&1 udp=$?
        [[ $tcp -eq 1 && $udp -eq 1 ]] && txt+="$pname,"
      else
        ping -O -R -c 1 $ip > /dev/null 2>&1 || txt+="$pname,"
      fi
    done < <(grep -v "#" $serv_list)
    txt="${txt%,*}"; msg="Service(s) $txt offline.";;
  *) return 1
  esac
#cli only echo $val || $txt; absolutely no disk operations
  [[ $RUNAS_DAEMON -eq 0 && -n $val ]] && { echo "$val"; return 0; }
  [[ $RUNAS_DAEMON -eq 0 ]] && { echo ${txt:="none"}; return 0; }
#daemon disk operations: clear flag, [save sample, write log, set flag]
  [[ $run_path/.$1.flag ]] && rm $run_path/.$1.flag > /dev/null 2>&1
  [[ -n $val ]] && echo  $val >> $run_path/.$1.samples  
  [[ $(echo $val | cut -d'.' -f1) -ge $thres ]] && txt="$val"
  [[ -n $txt ]] && { send_to_log "monitor_gen>>$1" "WARN" "$msg"; echo "$1:|""$txt" > $run_path/.$1.flag; }
  return 0
}

function monitor_dir_change () {
local initf scanf line tmpf file dat tmpf dcs divf
  time_elapsed "dir_change" $dir_change_pi || return 0
  [[ ! -f $dir_list ]] && return 0
  [[ $RUNAS_DAEMON -eq 0 ]] && { echo "monitor_dir_change only possible in daemon mode!"; return 0; }
  initf="$run_path/.dir_init.lst"
  scanf="$run_path/.dir_scan.lst"
#scan files 
  while read line; do
      line=$(echo $line | sed "s/ //")
      [[ "$line" == "" ]] &&  continue
      while read file; do
        [[ ! -d "$file" ]] && echo $(md5sum "$file" 2>/dev/null ) >> "$scanf"
      done < <(find "$line" -type f 2> /dev/null)
  done < <(grep -v "#" $dir_list) 
#if this is an initial scan 
  [[ -f $initf ]] || { mv "$scanf" "$initf" > /dev/null 2>&1; return 0; }
#clear flag
  [[ $run_path/.dir_change.flag ]] && rm $run_path/.dir_change.flag > /dev/null 2>&1
#compare md5sums
  tmpf="$run_path/.dir_diff.tmp"
  diff -u "$initf" "$scanf" > "$tmpf"
  dcs=$(ls -l "$tmpf" | cut -d" " -f5) #dcs>0 if changes are detected 
#no files have changed: remove tmpf,scanf
  [[ $dcs -eq 0 ]] && { rm "$tmpf" "$scanf"; return 0; }
#files have changed: set flag, create log, move scan to init, write log
  echo $dcs > $run_path/.dir_change.flag
  divf="$log_path/dir_diff_$(date "+%Y-%m-%d_%H:%M:%S").lst"
  cat $tmpf | grep "^[-+]" > "$divf"; rm $tmpf; 
  mv "$scanf" "$initf" > /dev/null 2>&1
  send_to_log "monitor_dir_change" "WARN" "Some files changed on disk. Please check $dirdiff."
  return 0
}

### PUBLISHERS #################################################################
function publish_json() {
local warn bflag flag avg flags_json val avgs_json strings_json
  time_elapsed "publish_json" $publish_pi || return 0
  [[ $RUNAS_DAEMON -eq 0 ]] && return 0
#flags json format: "<name>":<[0|1]>,...
  unset bflag warn=0
  for flag in cpu_temp cpu_load mem_use swap_use disk_use proc_degraded \
            dir_change server_offline; do
    file="$run_path/.$flag.flag"
    if  [[ -f "$file" ]]; then
      flags_json+="\"$flag\":1,"; bflag+=1; ((warn++))    
      dynvar="${flag^^}=\"$(cat $file 2>/dev/null | cut -d'|' -f2)\""; eval "$dynvar" 
    else
      flags_json+="\"$flag\":0,"; bflag+=0
    fi
  done; 
  flags_json="\"warn\":${warn:=0},\"bflag\":\"$bflag\""  #flags short form
#  flags_json="$flags_json,${flags_json%,*}"        #flags extended form
#avgs json format: "<name>":value,...
  for avg in cpu_temp cpu_load mem_use swap_use ; do
    val=$(get_average $avg)
    avgs_json+="\"$avg\":$val,"
  done; avgs_json=${avgs_json%,*}
#strings json format: "<name>":"<text>",... 
  PROC_DEGRADED=${PROC_DEGRADED:="none"}
  SERVER_OFFLINE=${SERVER_OFFLINE:="none"}
  DISK_USE=${DISK_USE:="none"}
  strings_json="\"degraded\":\"$PROC_DEGRADED\",\"offline\":\"$SERVER_OFFLINE\",\"diskwarn\":\"$DISK_USE\""
#json format: {"avgs":{AVGS},"strings":{STRINGS},flags":{FLAGS}}
  json="{\"lupdt\":\"$(date "+%s")\",\"avgs\":{$avgs_json},\"strings\":{$strings_json},\"flags\":{$flags_json}}"
#publish output to...  
  [[ $MQTT_JSON_TT -eq 1 ]] && { echo $json >&3; return 0; } 
  $publisher -h $broker_ip -p $broker_port -t "$topic/json" -m "$json" > /dev/null 2>&1
  return 0
}

function publish_wanip() {
local ipf onlf offlf ip last_ip since current previous totoffl val json 
  wanip_provider=${wanip_provider:="https://api.ipify.org"}   
  wanip_topic=${wanip_topic:="$topic/wan"} 
  time_elapsed "publish_wanip" $wanip_pi || return 0
  ipf=$run_path/.wan_ip.dat
  onlf=$run_path/.wan_online.timer
  offlf=$run_path/.wan_offline.timer
  ip=$(curl -s $wanip_provider) #get wan ip
  ip=$(is_valid_ip $ip)
  case $? in
  0) #internet OK
    last_ip=$(cat $ipf 2> /dev/null) || last_ip="n/a"
    [[ "$ip" =~ "$last_ip" ]] || echo $ip > $ipf
    [[ -f $onlf ]] || touch $onlf
    since=$(date "+%s" -r $onlf)   
    json="\"lupdt\":\"$(date "+%s")\",\"status\":\"online\",\"since\":\"$since\",\"ip\":\"$ip\""  
 #save total offline time in seconds
    if [[ -f $offlf ]]; then   
      current=$(date +"%s"); previous=$(date +"%s" -r $offlf)
      totoffl=$(cat ${offlf/'.timer'/'.dat'} 2>/dev/null)
      totoffl=$(( $current - ${previous:=0} + ${totoffl:=0} ))
      echo $totoffl > ${offlf/'.timer'/'.dat'}    
      rm $offlf >/dev/null 2>&1
    fi;;
  *|6) #no internet! start
    if [[ ! -f $offlf ]]; then
      touch $offlf; tiofft="00:00:00"; tioffs=0
    else   
      since=$(date "+%s" -r $offlf)
    fi
    json="\"lupdt\":\"$(date "+%s")\",\"status\":\"offline\",\"since\":\"$since\",\"ip\":\"n/a\""
    rm $onlf >/dev/null 2>&1;;             
  esac  
#calculate offline percent since start of $0; final build json
  since=$(date +"%s" -r "$run_path/$service.pid")
  totoffl=$(cat ${offlf/'.timer'/'.dat'} 2>/dev/null)
  json="$json,\"offlt\":${totoffl:=0}" 
  totoffl=$(echo "${totoffl:=0}" "$since" | awk '{ if($2 > 0) printf "%0.4f", ($1/$2)*100; else print 0}')
  json="$json,\"offltp\":${totoffl:=0}"
#publish output to... 
  json="{\"wan\":{$json}}" 
#json  {"wan":{"status":"online","since":"2024-07-07 15:04:19","ip":"191.39.141.210","offlt:34,"offltp":1.3]}
  
#publish output to...
  [[ $MQTT_JSON_TT -eq 1 ]] && { echo $json >&3; return 0;} 
  $publisher -h $broker_ip -p $broker_port -t "$wanip_topic/json" -m "$json" > /dev/null 2>&1
  return 0
}

################################################################################
### INSTALL/SETUP FUNCTIONS ####################################################
################################################################################

function install_packages () { #################################################
local pkg miss err_pkg uinp
#get missing packages
  for pkg in $packages; do
    dpkg -s "$pkg" >/dev/null 2>&1 && continue || miss+="$pkg "
  done
#user interface
  if [[ -n "$miss" ]]; then
    read -t 10 -n 3 -p "# Missing packages '$miss'. Install now? [YES]." uinp
    case $uinp in
    'YES') echo -e "\n# Install missing packages...";;
    *) echo -e "[ERR] Missing packages not installed, please install $packages manually."; return 10;;
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
  dst="$prog_path/$(basename $0)"
  echo "# Copy '$(basename $0)' to $dst"
  cp $0 $dst && chown root:root $dst && chmod 751 $dst && return 0
  return 21
}


function install_config () { ###################################################
local uinp conf_path
conf_path="/etc/$service"
  echo "# Create default config in $conf_path."
#check if $conf_path exists.
  [[ -d $conf_path ]] && {
     read -t 10 -n 3 -p "# Config in $conf_path already exists. Overwrite ALL? [YES]." uinp
     case $uinp in
     'YES') echo -e "\n# Overwrite existing config in $conf_path.";;
     *) echo -e "[OK] Using existing config in $conf_path."; return 0;;
     esac; }

#TODO: Use defaults section in main to build default config
#sed to split:  s="variable=${variable:="value"}" >> var=variable, value="value"
# var=$(echo $s | sed -e 's/\(^.*\)\=$.*/\1/p')
# value=$(echo $s | sed 's/.*\(\${.*}\).*/\1/p' | sed 's/.*:=\(.*\)}.*/\1/')

#create .conf...
  mkdir -p  $conf_path || return 41
  cat > $conf_path/$service.conf <<EOF || return 42
#Default config file for $service, created $(date '+%Y-%m-%d %H:%M:%S').
$(sed -n 12,52p $0)
EOF
  echo "[OK] Default '$service.conf' created in $conf_path."

#create pubstats/list.d/...
  cat > "$conf_path/proc.list" <<EOF || return 43
# Here you can add a list of services to monitor. If one is down it 
# can be restarted by executing the default systemctl command.
#
# If you are monitoring a custom process you can specify a custom
# command to restart it.
#
# Examples:
# [Process] : [Service] : [Start Command]
#apache : apache2 : default
#named : bind9 : default
#custom : myscript : /usr/sbin/myscript --start
EOF
  cat > "$conf_path/dir.list" <<EOF || return 44
# List of directories scanned for changes. The files on these directories should
# not change such as:
#/usr/sbin
#/etc
EOF
  cat > "$conf_path/serv.list" <<EOF || return 45
# List of hostnames or ip's which can be 'pinged' to see if they are alive.
# Example:
# [Service]:[Server]:[Port]
#somename:192.168.1.251:8443
#serviceX:roli-srv0.roli.lan
EOF
  echo "[OK] Default list.d/???.list files created in $conf_path."
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
ExecStart=/bin/bash -c "$prog_path/$(basename $0) start"
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF
#daemon-reload+enable+start
  systemctl daemon-reload || { echo ":( systemctl daemon-reload failed."; return 32; }
  echo -e "[OK] Installed $service.service."
  read -t 10 -n 3 -p "# Do you want to enable and start $service.service? [y|Y]" uinp
  case $uinp in
  'y'|'Y') 
     systemctl enable $service.service || { echo ":( Could not enable $service.service"; return 33; }
     systemctl start $service.service || { echo ":( Could not start $service.service"; return 34; }
  ;;
  *) echo -e "To enable $service.service please run:
> systemctl daemon-reload && systemctl enable $service && systemctl start $service.service" 
  esac
}

function setup { ###############################################################
local uinp
[[ $EUID -ne 0 ]] && { echo "[FAIL] You are not root!. Only root can install this program."; exit 1; }
  install_packages || { echo "[FAIL] [$?] Could not install required packages."; exit 1; }
  install_program || { echo "[FAIL] [$?] Could not install $(basename $0)."; exit 1; }
  install_config || { echo "[FAIL] [$?] Could not install default config file."; exit 1; }
  install_systemd || { echo "[FAIL] [$?] Could not install systemd unit file."; exit 1; }
}

################################################################################
##### ERROR/DEBUG FUNCTIONS ####################################################
################################################################################

function trap_error () { #######################################################
#error trap called on ERR
  local dat=$(date "+%Y-%m-%d %H:%M:%S") code=$? line=$BASH_LINENO cmd=$BASH_COMMAND
  echo "[$dat] [ERR@$line>>$code] $cmd" >> $log_path/error.log
  # exit 1 #optional if exit is desired
}

function trap_term () { ########################################################
#terminate trap called on EXIT or SIGTERM
local pid files f
#send LWT offline message to mqtt
  $publisher -h $broker_ip -p $broker_port -t "$topic/$service/LWT" -m "offline" > /dev/null 2>&1
#delete files we created in $run_path
  files="*.pid .*.timer .*.dat .*.samples .*.lst" #TODO: complete list!!! list of files to delete in $run_path
  for f in $files;do rm -f $run_path/$f 2>/dev/null; done
  exit 0
}

################################################################################
### START/STOP FUNCTIONS #######################################################
################################################################################

function start() { #############################################################
#start daemon; save pid to $run_path/$service.pid
#check running,prep,loop,started
local pid f

#check if already running
pid=$(cat $run_path/$service.pid 2>/dev/null)
[[ -n $pid ]] && echo "[OK] $service is already running [$pid]." && exit 0

#create runtime folders; TODO: avoid root privileges
for f in $run_path $log_path; do
  mkdir -p $f 2>/dev/null || { echo "[FAIL] Could not create runtime '$f'; check your permissions!"; exit 1; }
done; cd "$run_path"

trap "[[ -f $conf_ufi ]] && source $conf_ufi" SIGHUP
trap "trap_term" SIGTERM
trap "trap_error" ERR
( ### start daemon loop ####################
  RUNAS_DAEMON=1
#redirect stdin stdout stderr
   exec 0<&- 1>>$log_path/$service.log 2>>$log_path/error.log
#set traps to handle signals
  trap "trap_term" EXIT
#start main daemon loop
  while :;do
    get_rut955; update_bind_root
    monitor_gen "cpu_temp"
    monitor_gen "mem_use"; monitor_gen "swap_use"; monitor_gen "cpu_load"
    monitor_gen "disk_use"; monitor_gen "proc_degraded"; monitor_gen "server_offline"
    monitor_dir_change
    publish_json;publish_wanip
    sleep "$(time2seconds ${daemon_pi:=15s})"
done  #end daemon loop; trapped! 
) & echo $! > $run_path/$service.pid; pid=$(cat $run_path/$service.pid)

### started daemon ####################
  $publisher -h $broker_ip -p $broker_port -t "$topic/$service/LWT" -m "online" > /dev/null 2>&1
  echo "[OK] Started '$service' [$pid]."
exit 0
}

function stop() { ##############################################################
#stop a running deamon by sending SIGTERM to pid
local pid
  pid=$(cat $run_path/$service.pid 2>/dev/null)
  [[ -z $pid ]] && { echo "[INFO] $service is not running."; exit 1; }
  kill -s SIGTERM $pid 2>/dev/null && { echo "[OK] $service stopped."; exit 0; }
}

function status () { ###########################################################
local pid json msg
#get status of running daemon
  pid=$(cat $run_path/$service.pid 2>/dev/null)
  [[ -z $pid ]] && { echo "[INFO] $service is not running."; exit 1; }
  json="{\"$topic\":{\"service\":{\"name\":\"$service\",\"status\":\"running\",\"pid\":\"$pid\",\"topic\":\"$topic\",\"broker\":\"$broker_ip\"}}}"
  msg="[OK] $service is running  [$pid].\n...Listening to topic '$topic' @ broker $broker_ip\n"
  [[ $1 =~ '--json' ]] && echo $json || echo -e "$msg"
  return 0
}

################################################################################
### HELP/USAGE FUNCTIONS #######################################################
################################################################################

function showuse() {
cat <<EOF
##### ABOUT ####################################################################
'pubstats.sh' is a bash script to publish system statistics using the 
 mqtt protocol. It is setup as a service and provides data on cpu, memory, 
 disks, services and servers-ip. It can  scan selected folders for changes.
 A warn-flag is set and published to display anormalities.

USAGE: $> ./$(basename $0) [start|stop|restart|status] [options]
...[monitor (temp|cpu|mem|disk]) ]

EOF
exit 1
}

################################################################################
### MAIN #######################################################################
################################################################################
#program static defs do NOT change!
ME=$(dirname $(readlink -f "$0"))
prog_path="/usr/sbin" #used during setup to copy this script
packages="bc netcat-openbsd mosquitto-clients"
service=${service:="pubstats"}
run_path=${run_path:="/var/run/$service"}
log_path=${log_path:="/var/log/$service"}

conf_ufi="/etc/$service/$service.conf" #default when installed
[[ ! -f $conf_ufi ]] && conf_ufi="$ME/pubstats.conf" #fallback
[[ -f $conf_ufi ]] && source "$conf_ufi"

#-- defaults, can be part of a config file -------------------------------------
#defaults daemon
daemon_pi=15s #in seconds! this should be set to ~0.5x smallest PI.

#defaults mosquitto
publisher=${publisher:="/usr/bin/mosquitto_pub"}
broker=${broker:="127.0.0.1:1883"}
topic=${topic:="$(hostname)"}
publish_pi=${publish_pi:="5m"}

#defaults poll { [#Y] [#Q] [#M] [#d] [#h] [#m] [#s] }
# To disable a polling function just comment/unset the poll interval
cpu_temp_pi=${cpu_temp_pi:="30s"}
cpu_load_pi=${cpu_load_pi:="30s"}
mem_use_pi=${cpu_load_pi:="30s"}
swap_use_pi=${swap_use_pi:="30s"}
proc_degraded_pi=${proc_degraded_pi:="5m"}
disk_use_pi=${disk_use_pi:="3h"}
server_offline_pi=${server_offline_pi:="30m"}
dir_change_pi=${dir_change_pi:="1d"}

#defaults critical threshold
cpu_temp_warn=${cpu_temp_warn:="65"}
cpu_load_warn=${cpu_load_warn:="75"}
mem_use_warn=${mem_use_warn:="75"}
swap_use_warn=${swap_use_warn:="65"}
disk_use_warn=${disk_use_warn:="75"}

#poll user functions
#wanip_provider=              #default: "https://api.ipify.org"
#wanip_topic=                 #default: "$topic/wan"
#wanip_pi=1m                  #comment to disable
#rut955_pi=1m                 #comment to disable
#bind_root_pi=1M              #comment to disable
#-- end defaults ---------------------------------------------------------------

#set roots
broker_ip="${broker%:*}";broker_port="${broker/"$broker_ip"/}"; broker_port="${broker_port/:/}"
proc_list="$(dirname $conf_ufi)/proc.list"
dir_list="$(dirname $conf_ufi)/dir.list"
serv_list="$(dirname $conf_ufi)/serv.list"

#check root
[[ $(id -u) -ne 0 ]] && { "echo [ERR] You must be root to run this."; exit 1; }

case $1 in
'monitor')
  RUNAS_DAEMON=0
  case $2 in
  'temp') monitor_gen "cpu_temp";;
  'mem') monitor_gen "mem_use";;
  'swp') monitor_gen "swap_use";;
  'cpu') monitor_gen "cpu_load";;
  'dsk') monitor_gen "disk_use";;
  'prc') monitor_gen "proc_degraded";;
  'srv') monitor_gen "server_offline";;
  *) exit 0
  esac;;
'start') start;;
'stop') stop;;
'restart') stop; sleep5; start;;
'status') status $2;;
'install') setup;;
*) showuse
esac
exit 0
