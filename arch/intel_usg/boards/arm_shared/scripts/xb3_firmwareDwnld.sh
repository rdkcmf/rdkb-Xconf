#!/bin/sh

CURL_PATH=/fss/gw
interface=erouter0
BIN_PATH=/fss/gw/usr/ccsp

#GLOBAL DECLARATIONS
XconfServer=""
dnldInProgressFlag="/tmp/.imageDnldInProgress"
firmwareLocation=""
HttpServer=""
image_upg_avl=0

#Check if a new image is available on the XCONF server
getFirmwareUpgDetail()
{
    #The retry count and flag are used to resend a 
    #query to the XCONF server if issues with the 
    #respose or the URL received
    xconf_retry_count=1
    retry_flag=1

    #Check with the XCONF server if an update is available 
    while [ $xconf_retry_count -le 3 ] && [ $retry_flag -eq 1 ]
    do
    
        echo RETRY is $xconf_retry_count and RETRY_FLAG is $retry_flag

	    #Perform cleanup by deleting any previous responses
	    rm -f /tmp/response.txt
	    firmwareDownloadProtocol=""
	    firmwareFilename=""
	    firmwareLocation=""
	    firmwareVersion=""
	    rebootImmediately=""

        MAC=`ifconfig  | grep $interface |  grep -v $interface:0 | tr -s ' ' | cut -d ' ' -f5`

        HTTP_RESPONSE_CODE=`$CURL_PATH/curl --sslv2 -w '%{http_code}\n' -d "eStbMac=$MAC&firmwareVersion=PX001AN_1.3.4p4s1_PRODse&env=prod&model=PX001ANM&localtime=Mon Oct  6 11:14:05 UTC 2014&timezone=PST08PDT&capabilities=rebootDecoupled&capabilities=RCDL&capabilities=supportsFullHttpUrl" -o "/tmp/response.txt" "http://xconf.xcal.tv/xconf/swu/stb/" --connect-timeout 10 -m 10`

	    echo "XCONF SCRIPT : HTTP RESPONSE CODE is" $HTTP_RESPONSE_CODE

	    if [ $HTTP_RESPONSE_CODE -eq 200 ];then
            retry_flag=0
            
		    firmwareDownloadProtocol=`cat /tmp/response.txt | cut -d "," -f1 | cut -d ":" -f2 | cut -d '"' -f2`
    	    firmwareFilename=`cat /tmp/response.txt | cut -d "," -f2 | cut -d ":" -f2` #| cut -d '"' -f2`
    	    firmwareLocation=`cat /tmp/response.txt | cut -d "," -f3 | cut -d ":" -f3` #| cut -d '"' -f1`
    	    firmwareVersion=`cat /tmp/response.txt | cut -d "," -f4 | cut -d ":" -f2 | cut -d '"' -f2`
    	    rebootImmediately=`cat /tmp/response.txt | cut -d "," -f5 | cut -d ":" -f2 | cut -d '}' -f1`

    	    #echo "Protocol :"$firmwareDownloadProtocol
    	    #echo "Filename :"$firmwareFilename
    	    #echo "Location :"$firmwareLocation
    	    #echo "Version  :"$firmwareVersion
    	    #echo "Reboot   :"$rebootImmediately
	
		    if [ -f /tmp/response.txt ];then
			    #A response has been received in /tmp/response.txt
        		if [ "X"$firmwareLocation = "X" ];then
                    echo "XCONF SCRIPT : No URL received in /tmp/response.txt"
                    image_upg_avl=1

			    #Firmware location received in response.txt
        		else
				    firmwareLocation='"'http:${firmwareLocation}
                	#echo "New image avaialble from $firmwareLocation"
                    image_upg_avl=1
			    fi
		    #No response.txt created
		    else
                echo "XCONF SCRIPT : ERROR - /tmp/response.txt does not exist "
			    retry_flag=0
                image_upg_avl=0
		    fi

	    #If a response code of 404 was received, upgrade not available yet
	    elif [ $HTTP_RESPONSE_CODE -eq 404 ]; then 
            retry_flag=0
            image_upg_avl=0
	
        #If a response code of 0 was received, the server is unreachable
        #Try reconnecting 
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

    #Calculate random min
    rand_min=`awk -v min=0 -v max=59 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

    #Calculate random second
    rand_sec=`awk -v min=0 -v max=59 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

    #
    # Generate time to check for update
    #
    if [ $1 -eq '1' ]; then
        
        echo "Check Update called with #1 = $1 and #2 = $2"

        #Calculate random hour
        #The max random time can be 23:59:59
        rand_hr=`awk -v min=0 -v max=23 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

        echo "Time Generated : $rand_hr hr $rand_min min $rand_sec sec"
        min_to_sleep=$(($rand_hr*60 + $rand_min))
        sec_to_sleep=$(($min_to_sleep*60 + $rand_sec))

        printf "Checking update at \t";
        #date -d "$min_to_sleep minutes" +'%H:%M:%S'
        date -D '%s' -d "$(( `date +%s`+$sec_to_sleep ))"
    fi

    #
    # Generate time to downlaod HTTP image
    #
    if [ $2 -eq '1' ]; then
        
        echo "HTTP download image called with #1 = $1 and #2 = $2"

        #Calculate random hour
        #The max time random time can be 3:59:59
        rand_hr=`awk -v min=0 -v max=2 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

        echo "Time Generated : $rand_hr hr $rand_min min $rand_sec sec"

        cur_hr=`date +"%H"`
        cur_min=`date +"%M"`
        cur_sec=`date +"%S"`

        # Time to maintenance window
        start_hr=`expr 23 - ${cur_hr} + 1`
        start_min=`expr 59 - ${cur_min}`
        start_sec=`expr 59 - ${cur_sec}`

        #TIME TO START OF MAINTENANCE WINDOW
        echo "Time to 1:00 AM : $start_hr hours, $start_min minutes and $start_sec seconds"
        min_wait=$((start_hr*60 + $start_min))
        #date -d "$time today + $min_wait minutes + $start_sec seconds" +'%H:%M:%S'
        date -D '%s' -d "$(( `date +%s`+$(($min_wait*60 + $start_sec)) ))"

        #TIME TO START OF HTTP_DL
        total_hr=$(($start_hr + $rand_hr))
        total_min=$(($start_min + $rand_min))
        total_sec=$(($start_sec + $rand_sec))

        min_to_sleep=$(($total_hr*60 + $total_min))
        sec_to_sleep=$(($min_to_sleep*60 + $total_sec))

        printf "Downloading image on ";
        #date -d "$sec_to_sleep seconds" +'%H:%M:%S'
        date -D '%s' -d "$(( `date +%s`+$sec_to_sleep ))"
    fi

    echo "SLEEPING FOR $min_to_sleep minutes or $sec_to_sleep seconds"
    #sleep $sec_to_sleep
}

#Get the MAC address of the WAN interface
getMacAddress()
{
	ifconfig  | grep $interface |  grep -v $interface:0 | tr -s ' ' | cut -d ' ' -f5
}

#####################################################Main Application#####################################################

#Check if the WAN interface has an ip address, if not , wait for it to receives one
estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`

while [ "$estbIp" = "" ] ; 
do
    sleep 1
    estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
    echo "XCONF SCRIPT : Sleeping for an ip to the $interface interface "
done;

echo $interface has an ip address of  $estbIp

#Check if new image is available	
#TEST getFirmwareUpgDetail
image_upg_avl=1

# Location and file names are hard coded for testing
firmwareLocation="http://172.20.5.186:8000"
firmwareFilename="TG1682_DEV_master_121514482014_PBTsd.bin"

#If an image isn't available, check it's 
#availability at a random time,every 24 hrs
while  [ $image_upg_avl = 0 ];do
  
    echo "XCONF_SCRIPT : No Image availability at bootup, recheck" 
    #Sleep for a random time less than 
    #a 24 hour duration 
    calcRandTime 1 0
    
    #Check for the availability of an update   
    getFirmwareUpgDetail
done

if [ $image_upg_avl -eq 1 ];then
    
    #Set the url and filename
    echo "XCONF SCRIPT : URL --- $firmwareLocation and NAME --- $firmwareFilename"
    $BIN_PATH/XconfHttpDl set_http_url $firmwareLocation $firmwareFilename
    set_url_stat=$?
        
    #If the URL was correctly set, initiate the download
    if [ $set_url_stat -eq 0 ];then

        #An upgrade is available and the URL has ben set 
       	#Determine a time in maintenance window 
       	#and initiate the download
	    calcRandTime 0 1

	    #Start the image downlaod
	    $BIN_PATH/XconfHttpDl http_download
	    http_dl_stat=$?
	    echo "XCONF SCRIPT : HTTP DL STATUS $http_dl_stat"
			
	    #If the http_dl_stat is 0, the download was succesful,          
        #start the Reboot Manager, else retry the download the next day
			
        if [ $http_dl_stat -eq 0 ];then
                #Reboot the device
                echo "XCONF SCRIPT : Reboot possible. Issuing reboot command"
                $BIN_PATH/XconfHttpDl http_reboot 
                reboot_device=$?
               
                if [ $reboot_device -eq 0 ];then
                    echo "REBOOTING DEVICE"
                fi

	    else
		    #Retry the download the next day
		    echo "Retry download the next day"	
	    fi
     
     else
        echo "SCRIPT : URL & Filename not set correctly. "

     fi
		
else
    echo "XCONF SCRIPT : Unable to contact XCONF server." 
fi
