#!/bin/sh

CURL_PATH=/fss/gw
interface=wan0
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
        HTTP_RESPONSE_CODE=`$CURL_PATH/curl -k -w '%{http_code}\n' -d "eStbMac=$MAC&firmwareVersion=$currentVersion&env=dev&model=TG1682G&localtime=$date&timezone=EST05&capabilities="rebootDecoupled"&capabilities="RCDL"&capabilities="supportsFullHttpUrl"" -o "/tmp/response.txt" "https://xconf.poa.xcal.tv/xconf/swu/stb/" --connect-timeout 10 -m 10`
	    
        echo "XCONF SCRIPT : HTTP RESPONSE CODE is" $HTTP_RESPONSE_CODE

        # Print the response
        cat /tmp/response.txt

	    if [ $HTTP_RESPONSE_CODE -eq 200 ];then
		    retry_flag=0
		    firmwareDownloadProtocol=`head -1 /tmp/response.txt | cut -d "," -f1 | cut -d ":" -f2 | cut -d '"' -f2`

		    if [ $firmwareDownloadProtocol = "http" ];then
                firmwareLocation=`head -1 /tmp/response.txt | cut -d "," -f3 | cut -d ":" -f2- | cut -d '"' -f2`
            else
                firmwareLocation=`head -1 /tmp/response.txt | cut -d "," -f3 | cut -d ":" -f2 | cut -d '"' -f2`    
            fi

    	    firmwareFilename=`head -1 /tmp/response.txt | cut -d "," -f2 | cut -d ":" -f2 | cut -d '"' -f2`
    	   	firmwareVersion=`head -1 /tmp/response.txt | cut -d "," -f4 | cut -d ":" -f2 | cut -d '"' -f2`
	    	ipv6FirmwareLocation=`head -1 /tmp/response.txt | cut -d "," -f5 | cut -d ":" -f2-`
	    	upgradeDelay=`head -1 /tmp/response.txt | cut -d "," -f6 | cut -d ":" -f2`		
    	   	rebootImmediately=`head -1 /tmp/response.txt | cut -d "," -f7 | cut -d ":" -f2 | cut -d '}' -f1`

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

    sleep $sec_to_sleep
    echo "XCONF script : got up after $sec_to_sleep seconds"
}

# Get the MAC address of the WAN interface
getMacAddress()
{
	ifconfig  | grep $interface |  grep -v $interface:0 | tr -s ' ' | cut -d ' ' -f5
}

#####################################################Main Application#####################################################

# Check if the WAN interface has an ip address, if not , wait for it to receives one
estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`

while [ "$estbIp" = "" ] ; 
do
    sleep 1
    estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
    echo "XCONF SCRIPT : Sleeping for an ip to the $interface interface "
done;

echo "XCONF SCRIPT : $interface has an ip address of  $estbIp"

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

if [ $image_upg_avl -eq 1 ];then
    
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

                # Try rebooting the device succesfully till the following conidtions are met 
                # 1. We calculate and remain within the reboot maintenance window
                # 2. The reboot ready status is OK within the maintenance window
                # 3. Reboot_Now returns success and is going to reboot the device

                while [ $reboot_device_success -eq 0 ]; do
		            # Determine the time to reboot in the maintenance window
                    # and then check the reboot status
                    calcRandTime 0 1 r

                    # Check the Reboot status
                    # Continously check reboot status every 10 seconds  
                    # till the end of the maintenace window until the reboot status is OK
            
                    $BIN_PATH/XconfHttpDl http_reboot_status
                    http_reboot_ready_stat=$?

                    while [ $http_reboot_ready_stat -eq 1]   
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

	        else # http_dl_image != 0
		        
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

