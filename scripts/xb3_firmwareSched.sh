#!/bin/sh

source /etc/utopia/service.d/log_capture_path.sh
source /fss/gw/etc/utopia/service.d/log_env_var.sh

DCMRESPONSE="/nvram/DCMresponse.txt"
CRONINTERVAL="/nvram/cron_update.txt"
CRONTAB_DIR="/var/spool/cron/crontabs/"
CRONTAB_FILE=$CRONTAB_DIR"root"
OUTFILE='/tmp/DCMSettings.conf'
OUTFILEOPT='/tmp/.DCMSettings.conf'
CRON_FILE_BK="/tmp/cron_tab.txt"
DOWNLOAD_SCRIPT="/etc/xb3_firmwareDwnld.sh"
SCRIPT_NAME="xb3_firmwareDwnld.sh"

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
    sed -i '/xb3_firmwareDwnld.sh/d' $CRON_FILE_BK
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
              sed -i '/xb3_firmwareDwnld.sh/d' $CRON_FILE_BK
              echo_t "$cronPattern  $DOWNLOAD_SCRIPT 2" >> $CRON_FILE_BK
              crontab $CRON_FILE_BK -c $CRONTAB_DIR
              rm -rf $CRON_FILE_BK
              echo_t "XCONF SCRIPT: Cron scheduling done, now call download script during bootup"
              $DOWNLOAD_SCRIPT 1 &
           else
	      #Cron pattern not found for Xconf firmware download.
              echo_t "Cron pattern not found for firmware downlaod, call firmware download script"
              updateCron
              $DOWNLOAD_SCRIPT 1 &           
           fi
       else
            echo_t "XCONF SCRIPT: File->/tmp/DCMSettings.conf not available, call firmware download script"            
            updateCron
            $DOWNLOAD_SCRIPT 1 &     
       fi
else
       echo_t "XCONF SCRIPT: DCMresponse.txt file not present, call firmware download script"
       updateCron
       $DOWNLOAD_SCRIPT 1 &
fi
