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
source /fss/gw/etc/utopia/service.d/log_env_var.sh

DCMRESPONSE="/nvram/DCMresponse.txt"
CRONINTERVAL="/nvram/cron_update.txt"
CRONTAB_DIR="/var/spool/cron/crontabs/"
CRONTAB_FILE=$CRONTAB_DIR"root"
OUTFILE='/tmp/DCMSettings.conf'
OUTFILEOPT='/tmp/.DCMSettings.conf'
CRON_FILE_BK="/tmp/cron_tab.txt"
REBOOT_WAIT="/tmp/.waitingreboot"
DMCLI_CHECKNOW="dmcli eRT setv Device.X_COMCAST-COM_Xcalibur.Client.xconfCheckNow bool true"


# TODO:: We no longer use these files but it will take some time before all
# cron files are free of these files. Once RDKB-20262 has been delivered in
# the field and sufficient time has passed these names and their usage should
# be completely removed.

# NOTE:: we removed direct invokation of $DOWNLOAD_SCRIPT script from here or from cron command. 
# we only call xconfCheckNow TR181 endpoint as single point of entry for firmwareware 
# downloads. This allows us simple control over download implimentation. Only side effect :
# script will not know whether it was a scheduled invokation or at boot invokation, 
# it uses first argument's value as 1 for boot and 2 for cron. Its only usage in target scripts 
# is to print log and we didn't find a corrseponding test case. So shouldn't break anything as such.

BOX=`cat /etc/device.properties | grep BOX_TYPE | cut -d "=" -f2 | tr 'A-Z' 'a-z'`

if [ "$BOX" = "tccbr" ]; then
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

processJsonResponse()
{   
    if [ -f "$DCMRESPONSE" ]
    then
        sed -i 's/,"urn:/\n"urn:/g' $DCMRESPONSE            # Updating the file by replacing all ',"urn:' with '\n"urn:'
        sed -i 's/^{//g' $DCMRESPONSE                       # Delete first character from file '{'
        sed -i 's/}$//g' $DCMRESPONSE                       # Delete first character from file '}'
        echo "" >> $DCMRESPONSE                             # Adding a new line to the file 
        cat /dev/null > $OUTFILE                            #empty old file
        cat /dev/null > $OUTFILEOPT
        while read line
        do  
            
            # Parse the settings  by
            # 1) Replace the '":' with '='
            # 2) Updating the result in a output file
            profile_Check=`echo "$line" | grep -ci 'TelemetryProfile'`
            if [ $profile_Check -ne 0 ];then
                #echo "$line"
                echo "$line" | sed 's/"header":"/"header" : "/g' | sed 's/"content":"/"content" : "/g' | sed 's/"type":"/"type" : "/g' >> $OUTFILE
                echo "$line" | sed 's/"header":"/"header" : "/g' | sed 's/"content":"/"content" : "/g' | sed 's/"type":"/"type" : "/g'  | sed -e 's/uploadRepository:URL.*","//g'  >> $OUTFILEOPT
            else
                echo "$line" | sed 's/":/=/g' | sed 's/"//g' >> $OUTFILE 
            fi            
        done < $DCMRESPONSE
        
        #rm -rf $DCMRESPONSE #Delete the /opt/DCMresponse.txt
         rm -rf $OUTFILEOPT
    else
        echo "$DCMRESPONSE not found." >> $LOG_PATH/dcmscript.log
        return 1
    fi
}


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
    sed -i "/$DMCLI_CHECKNOW/d" $CRON_FILE_BK
    echo "$cronPattern  $DMCLI_CHECKNOW " >> $CRON_FILE_BK
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
   sed -i "/$DMCLI_CHECKNOW/d" $CRON_FILE_BK
   crontab $CRON_FILE_BK -c $CRONTAB_DIR
   rm -rf $CRON_FILE_BK
   
   echo_t "XCONF SCRIPT: Starting the Download Script"
   $DMCLI_CHECKNOW
   
   echo_t "XCONF SCRIPT: Removed firmwareDwnld crontab entry, exiting... "
   exit
fi

# Check if we have DCM response file
if [ ! -f $DCMRESPONSE ]
then
   count=0
   # Loop here for 2 minutes or till the DCM response file is created
   while [ $count -le 12 ]
   do
     sleep 10
     if [ -f $DCMRESPONSE ]
     then
         break
     else
        count=`expr $count + 1`
     fi
     
   done
fi

if [ -f $DCMRESPONSE ]; then
        processJsonResponse
	cronPattern=""
        if [ -f "$OUTFILE" ]
        then
           cronPattern=`cat $OUTFILE | grep "urn:settings:CheckSchedule:cron" | cut -f2 -d=`
        
           if [ "$cronPattern" != "" ]
           then
	      echo_t "XCONF SCRIPT: Firmware scheduler cron schedule time is $cronPattern"
              crontab -l -c $CRONTAB_DIR > $CRON_FILE_BK
              sed -i "/$SCRIPT_NAME/d" $CRON_FILE_BK
              sed -i "/$DMCLI_CHECKNOW/d" $CRON_FILE_BK
              echo "$cronPattern  $DMCLI_CHECKNOW " >> $CRON_FILE_BK
              crontab $CRON_FILE_BK -c $CRONTAB_DIR
              rm -rf $CRON_FILE_BK
              
              echo_t "XCONF SCRIPT: Cron scheduling done, now call download script during bootup"
              $DMCLI_CHECKNOW
           else 
             #Cron pattern not found for Xconf firmware download.
             echo_t "Cron pattern not found for firmware downlaod, call firmware download script"
             updateCron
             $DMCLI_CHECKNOW
           fi
       else
           echo_t "XCONF SCRIPT: File->/tmp/DCMSettings.conf not available, call firmware download script"            
           updateCron
    	   $DMCLI_CHECKNOW
       fi
else
       echo_t "XCONF SCRIPT: DCMresponse.txt file not present, call firmware download script"
       updateCron
       $DMCLI_CHECKNOW
fi
