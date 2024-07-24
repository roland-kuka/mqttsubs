# mqttsubs.sh
Provide a generic mqtt subscriber/listener for linux-os/motion/motioneye.

SYNOPSIS:
'mqttsubs.sh' is a pure bash script to enable control of os, motion and motioneye
using the mqtt protocol. It uses mosquitto-clients package to subscribe- and 
publish to '$topic/#'.
'mqttsubs.sh' has buildin support for motion/motioneyeos camera. This allows
for control and data/status query of remote network cameras.
'mqttsubs.sh' can serve as a platform to develop mqtt based interfaces to under-
-lying OS, though this poses a security risk and must be used with utmost care.

For motioneyeOS special build with the 'mosquitto-clients' module is required.

REMARKS:
'mqttsubs.sh' should be used only on the machine running motion/motioneye and this
machine MUST be isolated from the public internet!
Running 'mqttsubs.sh' can pose a HUGE security risc. It must be run as root! and 
makes extensive use of and runtime composed commands based on user input which
are executed directly by 'eval' or other means. Make sure all config files are 
accessible for rw by 'root' only. This is especially true if 'os' commands are
permitted.

MAIN FILES: 'mqttsubs.sh'.sh 'mqttsubs.conf'
CONF SAMPLES: motion.conf camera-1.conf

OVERVIEW OF CLI OPTIONS
* install                  >>   $0 install -c /etc/mqttsubs
* start                   >>   $0 start daemon
* stop                    >>   $0 stop daemon
* restart                  >>   $0 restart daemon
* status .                 >>   $0 status daemon
* camera_ptz . . .         >>   $0 camera_ptz <id> <act> <val>
* on_motion_detected .     >>   motion event: $0 on_motion_detected %t
* on_camera_found .        >>   motion event: $0 on_camera_found %t
* on_camera_lost .         >>   motion event: $0 on_camera_lost %t

OVERVIEW OF MQTT TOPICS:
* $(hostname)/
  
* ./camera/id/
* ../control/[up|stop|down|left|right|center|vpatrol|hpatrol|setpreset|callpreset|ir|led]
  
* ./motion/id/
* ../detection [ON|0|OFF|1] >> ../state [ON|0|OFF|1]
* ../snapshot [ON|1]        >> ../state [OFF]
* ../getcf key              >> ../id/key/state <value> #get config value
* ../getrt key              >> ../id/key/state <value> #get runtime value
* ../set/key value          >> ../id/key/state <value> #set config value
  
* ./daemon/
* ../getcf key              >> ../id/key/state <value> #get config value
* ../getrt key              >> ../id/key/state <value> #get runtime variable
* ../set/key value          >> ../id/key/state <value> #set config value

*  ./oscmd/
* ../command args           >> ../oscmd/json           #{exec:{cmd:?,args:?,res:OK,ret:?}}

SETUP:
1. Build a motioneyeOS with the 'mosquitto' module.
2. Startup the camera. Wait for it to boot. Enable ssh and then ssh to camera.
3. Make a new folder '/data/etc/mqtt-subscribe'
3. Copy 'mqtt-subscribe','mqtt-subscribe.conf' to this folder.
4. Set the broker ip:port in mqtt-subscribe.conf. This should be the broker 
     used by your Home Automation System.
5. While in 'mqtt-subscribe' folder test mqtt-subscribe. >./mqtt-subscribe
6. To enable mqtt-subscribe after reboot create a file '/data/etc/userinit.sh'
   and copy the following text into this file: 
   "/data/etc/mosquitto-subscribe start"
