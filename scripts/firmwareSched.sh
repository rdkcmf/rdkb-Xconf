#!/bin/sh
##########################################################################
# If not stated otherwise in this file or this component's Licenses.txt
# file the following copyright and licenses apply:
#
# Copyright 2017 RDK Management
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##########################################################################
source /etc/utopia/service.d/log_capture_path.sh
source /etc/utopia/service.d/log_env_var.sh

ALT_DCMRESPONSE="/tmp/DCMresponse_alt.txt"
DCMRESPONSE="/nvram/DCMresponse.txt"
CRONINTERVAL="/nvram/cron_update.txt"
CRONTAB_DIR="/var/spool/cron/crontabs/"
CRONTAB_FILE=$CRONTAB_DIR"root"
FORMATTED_TMP_DCM_RESPONSE='/tmp/DCMSettings.conf'
CRON_FILE_BK="/tmp/cron_tab$$.txt"
REBOOT_WAIT="/tmp/.waitingreboot"
XCONF_LOG_FILE_NAME=xconf.txt.0
XCONF_LOG_FILE_PATHNAME=${LOG_PATH}/${XCONF_LOG_FILE_NAME}
XCONF_LOG_FILE=${XCONF_LOG_FILE_PATHNAME}
FWUPGRADE_EXCLUDE=`syscfg get AutoExcludedEnabled`
if [ "$FWUPGRADE_EXCLUDE" = "true" ] && [ "$type" != "PROD" ] && [ $BUILD_TYPE != "prod" ] && [ ! -f /nvram/swupdate.conf ] ; then
    echo "Device excluded from FW Upgrade!! Exiting"
    exit
fi
BOX=`grep BOX_TYPE /etc/device.properties | cut -d "=" -f2 | tr 'A-Z' 'a-z'`
RDKFWUpgrader_PID=`pidof rdkfwupgrader`
#check if RDKFirmwareUpgrader is enabled if true send dbus trigger to the rdkfwupgrader daemon uing check_now()
isRDKFWUpgraderEnabled=`syscfg get RDKFirmwareUpgraderEnabled`
if [ "x$isRDKFWUpgraderEnabled" = "xtrue" ] && [ -n "$RDKFWUpgrader_PID" ] ; then
    echo "isRDKFWUpgraderEnabled = $isRDKFWUpgraderEnabled"
    DOWNLOAD_SCRIPT="/lib/rdk/rdkfwupgrader_check_now.sh"
    SCRIPT_NAME="rdkfwupgrader_check_now.sh"
	
elif [ "$BOX" = "tccbr" ]; then
    DOWNLOAD_SCRIPT="/etc/cbr_firmwareDwnld.sh"
    SCRIPT_NAME="cbr_firmwareDwnld.sh"
else
    FIRMWARE_DOWNLOAD='_firmwareDwnld.sh'
    DOWNLOAD_SCRIPT="/etc/$BOX$FIRMWARE_DOWNLOAD"
    SCRIPT_NAME="$BOX$FIRMWARE_DOWNLOAD"
fi
if [ -z "$BOX" ]; then
    echo_t "Box Type Not found exiting scheduler script"  >> $XCONF_LOG_FILE
    exit
fi
isPeriodicFWCheckEnabled=`syscfg get PeriodicFWCheck_Enable`
if [ "$isPeriodicFWCheckEnabled" != "true" ]
then
  echo "XCONF SCRIPT : Calling XCONF CDL script"
  $DOWNLOAD_SCRIPT 1 &
  exit
fi

updateCron()
{
    rand_hr=0
    rand_min=0
    # Calculate random time for cron pattern
    # The max random time can be 23:59:59
    echo_t "XCONF SCRIPT: Check Update time being calculated within 24 hrs." >> $XCONF_LOG_FILE
    rand_hr=`awk -v min=0 -v max=23 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`
    rand_min=`awk -v min=0 -v max=59 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`
    cronPattern="$rand_min $rand_hr * * *"
    crontab -l -c $CRONTAB_DIR > $CRON_FILE_BK
    sed -i "/$SCRIPT_NAME/d" $CRON_FILE_BK
    echo "$cronPattern  $DOWNLOAD_SCRIPT 2" >> $CRON_FILE_BK
    crontab $CRON_FILE_BK -c $CRONTAB_DIR
    rm -rf $CRON_FILE_BK
    echo_t "XCONF SCRIPT: Time Generated : $rand_hr hr $rand_min min"
}
##############################################################
#                                                            #
#                          Main App                          #
#                                                            #
##############################################################
# Check if the crontab entry needs to be removed or not
if [ "$1" == "RemoveCronJob" ]
then
   echo_t "XCONF SCRIPT: Removing the firmwareDwnld crontab"
   crontab -l -c $CRONTAB_DIR > $CRON_FILE_BK
   sed -i "/$SCRIPT_NAME/d" $CRON_FILE_BK
   crontab $CRON_FILE_BK -c $CRONTAB_DIR
   rm -rf $CRON_FILE_BK
   
   echo_t "XCONF SCRIPT: Starting the Download Script"
   $DOWNLOAD_SCRIPT 1 &
   
   echo_t "XCONF SCRIPT: Removed firmwareDwnld crontab entry, exiting... "
   exit
fi
# Check if we have DCM response file
if [ ! -f $FORMATTED_TMP_DCM_RESPONSE ]
then
   count=0
   # Loop here for 2 minutes or till the DCM response file is created
   while [ $count -le 12 ]
   do
     sleep 10
     if [ -f $FORMATTED_TMP_DCM_RESPONSE ]
     then
         break
     else
        count=`expr $count + 1`
     fi
     
   done
fi
if [ ! -f $REBOOT_WAIT ]
then
    killall $DOWNLOAD_SCRIPT
fi

	      cronPattern=""
        if [ -f "$FORMATTED_TMP_DCM_RESPONSE" ]
        then
           cronPattern=`grep "urn:settings:CheckSchedule:cron" $FORMATTED_TMP_DCM_RESPONSE | cut -f2 -d=`
        
           if [ "$cronPattern" != "" ]
           then
	      echo_t "XCONF SCRIPT: Firmware scheduler cron schedule time is $cronPattern"
              crontab -l -c $CRONTAB_DIR > $CRON_FILE_BK
              sed -i "/$SCRIPT_NAME/d" $CRON_FILE_BK
              echo "$cronPattern  $DOWNLOAD_SCRIPT 2" >> $CRON_FILE_BK
              crontab $CRON_FILE_BK -c $CRONTAB_DIR
              rm -rf $CRON_FILE_BK
              
              if [ ! -f $REBOOT_WAIT ]
	      then
              	  echo_t "XCONF SCRIPT: Cron scheduling done, now call download script during bootup"
                  $DOWNLOAD_SCRIPT 1 &
              fi
           else 
             #Cron pattern not found for Xconf firmware download.
             echo_t "Cron pattern not found for firmware downlaod, call firmware download script"
             updateCron
             if [ ! -f $REBOOT_WAIT ]
	           then
              	$DOWNLOAD_SCRIPT 1 &           
             fi
           fi
       else
           echo_t "firmwareSched.sh: File->/tmp/DCMSettings.conf not available, call firmware download script"            
           updateCron
    	   if [ ! -f $REBOOT_WAIT ]
	   then
            	$DOWNLOAD_SCRIPT 1 &     
           fi
       fi
