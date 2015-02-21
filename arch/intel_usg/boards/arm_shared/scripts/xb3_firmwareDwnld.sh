#!/bin/sh

CURL_PATH=/fss/gw
interface=erouter0
BIN_PATH=/fss/gw/usr/ccsp

#GLOBAL DECLARATIONS
image_upg_avl=0

checkFirmwareUpgCriteria()
{
    # Retrieve current firmware version
    currentVersion=`dmcli eRT getvalues Device.DeviceInfo.X_CISCO_COM_FirmwareName | grep TG1682 | cut -d ":" -f 3 | tr -d ' '`

    echo "XCONF SCRIPT : CurrentVersion : $currentVersion"
    echo "XCONF SCRIPT : UpgradeVersion : $firmwareVersion"

    # Parse current firmware version
    cur_num=`echo $currentVersion | cut -d "_" -f 2`
    cur_major=`echo $cur_num | cut -d "." -f 1`
    cur_minor1=`echo $cur_num| cut -d "." -f 2 | cut -d "s" -f 1`
    cur_minor2=`echo $cur_num| cut -d "." -f 2 | cut -d "s" -f 2`

    # Parse upgrade firmware version 
    upg_num=`echo $firmwareVersion | cut -d "_" -f 2`
    upg_major=`echo $upg_num | cut -d "." -f 1`
    upg_minor1=`echo $upg_num| cut -d "." -f 2 | cut -d "s" -f 1`
    upg_minor2=`echo $upg_num| cut -d "." -f 2 | cut -d "s" -f 2`

    if [ $upg_major -gt $cur_major ];then
        image_upg_avl=1;

    elif [ $upg_major -lt $cur_major ];then
        image_upg_avl=0

    elif [ $upg_major -eq $cur_major ];then
        echo "Current and upgrade firmware major versions equal,"

        if [ $upg_minor1 -gt $cur_minor1 ];then
            image_upg_avl=1

        elif [ $upg_minor1 -lt $cur_minor1 ];then
            image_upg_avl=0

        elif [ $upg_minor1 -eq $cur_minor1 ];then
            echo " Current and upgrade minor1 versions equal"

            if [ $upg_minor2 -gt $cur_minor2 ];then
                image_upg_avl=1

            elif [ $upg_minor2 -le $cur_minor2 ];then
                echo " Current and upgrade  minor2 versions equal/less"
                image_upg_avl=0

            fi
        fi
    fi

    echo "XCONF SCRIPT : Image available is $image_upg_avl" 
    
}

# Check if a new image is available on the XCONF server
getFirmwareUpgDetail()
{
    # The retry count and flag are used to resend a 
    # query to the XCONF server if issues with the 
    # respose or the URL received
    xconf_retry_count=1
    retry_flag=1

    # Set the XCONF server url and env read from /etc/Xconf 
    env=`cat /etc/Xconf | cut -d "=" -f1`
    xconf_url=`cat /etc/Xconf | cut -d "=" -f2`
    
    # If an /etc/Xconf file was not created, use the default values
    if [ ! -f /etc/Xconf ]; then
        echo "XCONF SCRIPT : ERROR : /etc/Xconf file not found! Using defaults"
        env="PROD"
        xconf_url="https://xconf.xcal.tv/xconf/swu/stb/"
    fi

    echo "XCONF SCRIPT : env is $env"
    echo "XCONF SCRIPT : xconf url  is $xconf_url"

    # Check with the XCONF server if an update is available 
    while [ $xconf_retry_count -le 3 ] && [ $retry_flag -eq 1 ]
    do
        echo RETRY is $xconf_retry_count and RETRY_FLAG is $retry_flag

	    # Perform cleanup by deleting any previous responses
	    rm -f /tmp/response.txt
	    firmwareDownloadProtocol=""
	    firmwareFilename=""
	    firmwareLocation=""
	    firmwareVersion=""
	    rebootImmediately=""
        ipv6FirmwareLocation=""
        upgradeDelay=""
       
        currentVersion=`dmcli eRT getvalues Device.DeviceInfo.X_CISCO_COM_FirmwareName | grep TG1682 | cut -d ":" -f 3 | tr -d ' ' `
        MAC=`ifconfig  | grep $interface |  grep -v $interface:0 | tr -s ' ' | cut -d ' ' -f5`
        date=`date`
        
        echo "XCONF SCRIPT : CURRENT VERSION : $currentVersion"
        echo "XCONF SCRIPT : CURRENT MAC  : $MAC"
        echo "XCONF SCRIPT : CURRENT DATE : $date"


        # Query the  XCONF Server
        HTTP_RESPONSE_CODE=`$CURL_PATH/curl --interface $interface -k -w '%{http_code}\n' -d "eStbMac=$MAC&firmwareVersion=$currentVersion&env=$env&model=TG1682G&localtime=$date&timezone=EST05&capabilities="rebootDecoupled"&capabilities="RCDL"&capabilities="supportsFullHttpUrl"" -o "/tmp/response.txt" "$xconf_url" --connect-timeout 30 -m 30`
	    
        echo "XCONF SCRIPT : HTTP RESPONSE CODE is" $HTTP_RESPONSE_CODE

        # Print the response
        cat /tmp/response.txt


	    if [ $HTTP_RESPONSE_CODE -eq 200 ];then
		    retry_flag=0
		    firmwareDownloadProtocol=`head -1 /tmp/response.txt | cut -d "," -f1 | cut -d ":" -f2 | cut -d '"' -f2`

		    if [ $firmwareDownloadProtocol == "http" ];then
                echo "XCONF SCRIPT : Download image from HTTP server"
                firmwareLocation=`head -1 /tmp/response.txt | cut -d "," -f3 | cut -d ":" -f2- | cut -d '"' -f2`
            else
                echo "XCONF SCRIPT : Download from TFTP server not suported, check XCONF server configurations"
                
                # sleep for 2 minutes and retry
                sleep 120;

                retry_flag=1
                image_upg_avl=0

                #Increment the retry count
                xconf_retry_count=$((xconf_retry_count+1))

                continue
                #firmwareLocation=`head -1 /tmp/response.txt | cut -d "," -f3 | cut -d ":" -f2 | cut -d '"' -f2`    
            fi

    	    firmwareFilename=`head -1 /tmp/response.txt | cut -d "," -f2 | cut -d ":" -f2 | cut -d '"' -f2`
    	   	firmwareVersion=`head -1 /tmp/response.txt | cut -d "," -f4 | cut -d ":" -f2 | cut -d '"' -f2`
	    	ipv6FirmwareLocation=`head -1 /tmp/response.txt | cut -d "," -f5 | cut -d ":" -f2-`
	    	upgradeDelay=`head -1 /tmp/response.txt | cut -d "," -f6 | cut -d ":" -f2`
            
            if [ $env == "dev" ] || [ $env == "DEV" ];then
    	   	    rebootImmediately=`head -1 /tmp/response.txt | cut -d "," -f7 | cut -d ":" -f2 | cut -d '}' -f1`
            else
                rebootImmediately=`head -1 /tmp/response.txt | cut -d "," -f5 | cut -d ":" -f2 | cut -d '}' -f1`
            fi    
                                    

            # firmwareLocation=http://162.150.228.179:8080/Images
            # firmwareVersion=TG1682_0.3s5_VBNsd_signed.bin

    	   	 echo "XCONF SCRIPT : Protocol :"$firmwareDownloadProtocol
    	   	 echo "XCONF SCRIPT : Filename :"$firmwareFilename
    	   	 echo "XCONF SCRIPT : Location :"$firmwareLocation
    	   	 echo "XCONF SCRIPT : Version  :"$firmwareVersion
    	   	 echo "XCONF SCRIPT : Reboot   :"$rebootImmediately
	
        	if [ "X"$firmwareLocation = "X" ];then
                echo "XCONF SCRIPT : No URL received in /tmp/response.txt"
                retry_flag=1
                image_upg_avl=0

                #Increment the retry count
                xconf_retry_count=$((xconf_retry_count+1))

            else
           	# Check if a newer version was returned in the response
            # If image_upg_avl = 0, retry reconnecting with XCONf in next window
            # If image_upg_avl = 1, download new firmware 
                checkFirmwareUpgCriteria  
			fi
		

        # If a response code of 404 was received, error
	    elif [ $HTTP_RESPONSE_CODE -eq 404 ]; then 
        	retry_flag=0
           	image_upg_avl=0
	
        # If a response code of 0 was received, the server is unreachable
        # Try reconnecting 
        elif [ $HTTP_RESPONSE_CODE -eq 0 ]; then
            
            echo "XCONF SCRIPT : Response code 0, sleeping for 2 minutes and retrying"
            # sleep for 2 minutes and retry
            sleep 120;

            retry_flag=1
            image_upg_avl=0

           	#Increment the retry count
           	xconf_retry_count=$((xconf_retry_count+1))

        fi

    done

    if [ $xconf_retry_count -eq 4 ];then
        echo "XCONF SCRIPT : Retry limit to connect with XCONF server reached" 
    fi
}

calcRandTime()
{
    rand_hr=0
    rand_min=0
    rand_sec=0

    # Calculate random min
    rand_min=`awk -v min=0 -v max=59 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

    # Calculate random second
    rand_sec=`awk -v min=0 -v max=59 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

    #
    # Generate time to check for update
    #
    if [ $1 -eq '1' ]; then
        
        echo "XCONF SCRIPT : Check Update time being calculated in maintenance window"

        # Calculate random hour
        # The max random time can be 23:59:59
        rand_hr=`awk -v min=0 -v max=23 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

        echo "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec"
        min_to_sleep=$(($rand_hr*60 + $rand_min))
        sec_to_sleep=$(($min_to_sleep*60 + $rand_sec))

        printf "XCONF SCRIPT : Checking update with XCONF server at \t";
        # date -d "$min_to_sleep minutes" +'%H:%M:%S'
        date -D '%s' -d "$(( `date +%s`+$sec_to_sleep ))"
    fi

    #
    # Generate time to downlaod HTTP image
    # device reboot time 
    #
    if [ $2 -eq '1' ]; then
       
        if [ $3 == "h" ]; then
            echo "XCONF SCRIPT : Http download time being calculated in maintenance window"
            
        else
            echo "XCONF SCRIPT : Device reboot time being calculated in maintenance window"
        fi 
                 
        # Calculate random hour
        # The max time random time can be 4:59:59
        rand_hr=`awk -v min=0 -v max=3 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

        echo "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec"

        cur_hr=`date +"%H"`
        cur_min=`date +"%M"`
        cur_sec=`date +"%S"`

        # Time to maintenance window
        start_hr=`expr 23 - ${cur_hr} + 1`
        start_min=`expr 59 - ${cur_min}`
        start_sec=`expr 59 - ${cur_sec}`

        # TIME TO START OF MAINTENANCE WINDOW
        echo "XCONF SCRIPT : Time to 1:00 AM : $start_hr hours, $start_min minutes and $start_sec seconds"
        min_wait=$((start_hr*60 + $start_min))
        # date -d "$time today + $min_wait minutes + $start_sec seconds" +'%H:%M:%S'
        date -D '%s' -d "$(( `date +%s`+$(($min_wait*60 + $start_sec)) ))"

        # TIME TO START OF HTTP_DL/REBOOT_DEV
        total_hr=$(($start_hr + $rand_hr))
        total_min=$(($start_min + $rand_min))
        total_sec=$(($start_sec + $rand_sec))

        min_to_sleep=$(($total_hr*60 + $total_min))
        sec_to_sleep=$(($min_to_sleep*60 + $total_sec))

        printf "XCONF SCRIPT : Action will be performed on ";
        # date -d "$sec_to_sleep seconds" +'%H:%M:%S'
        date -D '%s' -d "$(( `date +%s`+$sec_to_sleep ))"
    fi

    echo "XCONF SCRIPT : SLEEPING FOR $min_to_sleep minutes or $sec_to_sleep seconds"
    
    #echo "XCONF SCRIPT : SPIN 12 : sleeping for 30 sec, *******TEST BUILD***********"
    #sec_to_sleep=30

    sleep $sec_to_sleep
    echo "XCONF script : got up after $sec_to_sleep seconds"
}

# Get the MAC address of the WAN interface
getMacAddress()
{
	ifconfig  | grep $interface |  grep -v $interface:0 | tr -s ' ' | cut -d ' ' -f5
}

getBuildType()
{
   IMAGENAME=`cat /fss/gw/version.txt | grep ^imagename= | cut -d "=" -f 2`

   TEMPDEV=`echo $IMAGENAME | grep DEV`
   if [ "$TEMPDEV" != "" ]
   then
       type="DEV"
   fi

   TEMPVBN=`echo $IMAGENAME | grep VBN`
   if [ "$TEMPVBN" != "" ]
   then
       type="VBN"
   fi

   TEMPPROD=`echo $IMAGENAME | grep PROD`
   if [ "$TEMPPROD" != "" ]
   then
       type="PROD"
   fi

   TEMPCQA=`echo $IMAGENAME | grep CQA`
   if [ "$TEMPPROD" != "" ]
   then
       type="GSLB"
   fi
}


#####################################################Main Application#####################################################

# Determine the env type and url and write to /etc/Xconf
#type=`printenv model | cut -d "=" -f2`

getBuildType

echo XCONF SCRIPT : MODEL IS $type

if [ $type == "DEV" ] || [ $type == "dev" ];then
    url="https://xconf.poa.xcal.tv/xconf/swu/stb/"
else
    url="https://xconf.xcal.tv/xconf/swu/stb/"
fi

echo "$type=$url" > /etc/Xconf
echo "XCONF SCRIPT : Values written to /etc/Xconf are $type=$url"


# Check if the WAN interface has an ip address, if not , wait for it to receives one
estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
estbIp6=`ifconfig $interface | grep "inet6 addr" | grep "Global" | tr -s " " | cut -d ":" -f2- | cut -d "/" -f1 | tr -d " "`


while [ "$estbIp" = "" ] && [ "$estbIp6" = "" ]
do
    sleep 1

    estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
    estbIp6=`ifconfig $interface | grep "inet6 addr" | grep "Global" | tr -s " " | cut -d ":" -f2- | cut -d "/" -f1 | tr -d " "`

    echo "XCONF SCRIPT : Sleeping for an ipv4 or an ipv6 address on the $interface interface "
done;

echo "XCONF SCRIPT : $interface has an ipv4 address of $estbIp or an ipv6 address of $estbIp6"

# Check if new image is available	
getFirmwareUpgDetail

# If an image isn't available, check it's 
# availability at a random time,every 24 hrs
while  [ $image_upg_avl = 0 ];
do
    echo "XCONF_SCRIPT : No Image availability at bootup, recheck in maintenace window" 
    # Sleep for a random time less than 
    # a 24 hour duration 
    calcRandTime 1 0 
    
    # Check for the availability of an update   
    getFirmwareUpgDetail
done

if [ $rebootImmediately == "true" ];then
    echo"XCONF SCRIPT : Reboot Immediately : TRUE!! Issuing reboot "
    
    $BIN_PATH/XconfHttpDl http_reboot
    reboot_device=$?

    if [ $reboot_device -eq 0 ];then
        echo "XCONF SCRIPT : REBOOTING DEVICE"
    else
        echo "XCONF SCRIPT : ERROR IN REBOOTING DEVICE"    
    fi
else
    echo "XCONF SCRIPT : Reboot Immediately : FALSE."

fi    

if [ $image_upg_avl -eq 1 ];then

    # Whitelist the returned firmrware location
    echo "XCONF SCRIPT : Whitelisting download location : $firmwareLocation"
    /etc/whitelist.sh "$firmwareLocation"

    # Set the url and filename
    echo "XCONF SCRIPT : URL --- $firmwareLocation and NAME --- $firmwareFilename"
    $BIN_PATH/XconfHttpDl set_http_url $firmwareLocation $firmwareFilename
    set_url_stat=$?
        
    # If the URL was correctly set, initiate the download
    if [ $set_url_stat -eq 0 ];then
        
        download_image_success=0
        reboot_device_success=0
                
        while [ $download_image_success -eq 0 ]; do
            # An upgrade is available and the URL has ben set 
       	    # Determine a time in maintenance window 
       	    # and initiate the download
	        calcRandTime 0 1 h

	        # Start the image download
	        $BIN_PATH/XconfHttpDl http_download
	        http_dl_stat=$?
	        echo "XCONF SCRIPT : HTTP DL STATUS $http_dl_stat"
			
	        # If the http_dl_stat is 0, the download was succesful,          
            # start the Reboot Manager
		
            ##################
            # REBOOT MANAGER #
            ##################

            if [ $http_dl_stat -eq 0 ];then
                
                # Indicate succesful download
                download_image_success=1

                # Try rebooting the device succesfully if :
                # 1. Issue an immediate reboot if still within the maintenance window and phone is on hook
                # 2. If an immediate reboot is not possile ,calculate and remain within the reboot maintenance window
                # 3. The reboot ready status is OK within the maintenance window
                # 4. Reboot_Now returns success and is going to reboot the device

                while [ $reboot_device_success -eq 0 ]; do

                    # Check if still within reboot window
                    reb_hr=`date +"%H"`
                    reb_min=`date +"%M"`
                    reb_sec=`date +"%S"`

                    if [ $reb_hr -le 4 ] && [ $reb_min -le 59 ] && [ $reb_sec -le 59 ];then
                        echo "XCONF SCRIPT : Still within current maintenance window for reboot"
                        reboot_now=1    
                    else
                        echo "XCONF SCRIPT : Not within current maintenance window for reboot.Rebooting in  the next "
                        reboot_now=0
                    fi

                    # If we are not supposed to reboot now, calculate random time
                    # to reboot in next maintenance window 
                    if [ $reboot_now -eq 0 ];then
                    calcRandTime 0 1 r
                    fi    

                    # Check the Reboot status
                    # Continously check reboot status every 10 seconds  
                    # till the end of the maintenace window until the reboot status is OK
                    $BIN_PATH/XconfHttpDl http_reboot_status
                    http_reboot_ready_stat=$?

                    while [ $http_reboot_ready_stat -eq 1 ]   
                    do     
                        sleep 10
                        cur_hr=`date +"%H"`
                        cur_min=`date +"%M"`
                        cur_sec=`date +"%S"`

                        if [ $cur_hr -le 4 ] && [ $cur_min -le 59 ] && [ $cur_sec -le 59 ];
                        then
                            #We're still within the reboot window 
                            $BIN_PATH/XconfHttpDl http_reboot_status
                            http_reboot_ready_stat=$?
                    
                        else
                            #If we're out of the reboot window, exit while loop
                            break
                        fi
                    done 
               
                    # The reboot ready status changed to OK within the maintenance window,proceed
		            if [ $http_reboot_ready_stat -eq 0 ];then
		        
                        #Reboot the device
		                echo "XCONF SCRIPT : Reboot possible. Issuing reboot command"
		                $BIN_PATH/XconfHttpDl http_reboot 
		                reboot_device=$?
		       
                        # This indicates we're within the maintenace window
                        # and the reboot ready status is OK, issue the reboot
                        # command and check if it returned correctly
		                if [ $reboot_device -eq 0 ];then
                            reboot_device_success=1
		                    echo "XCONF SCRIPT : REBOOTING DEVICE"
                
                        # The reboot command failed, retry in the next maintenance window 
                        else 
                            reboot_device_success=0
                            #Goto start of Reboot Manager again  
		                fi

                    # The reboot ready status didn't change to OK within the maintenance window 
		            else
                        reboot_device_success=0
		                echo " XCONF SCRIPT : Device is not ready to reboot : Retrying in next reboot window ";
                        # Goto start of Reboot Manager again  
		            fi
                    
                done # While loop for reboot manager

	        else # http_dl_image !=0 ,FAILURE
		        
                # The http download failed. 
                # Indicate unsuccesful download to retry
                download_image_success=0
		        echo "XCONF SCRIPT : HTTP download failed : Retrying in next download window"	
	        fi
     
        done #While loop for http download
    
    else
        echo "XCONF SCRIPT : ERROR : URL & Filename not set correctly.Exiting XCONF. "

    fi
		
else
    echo "XCONF SCRIPT : ERROR : Unable to contact XCONF server.Exiting XCONF." 
fi

