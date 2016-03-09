#!/bin/sh

XCONF_LOG_PATH=/rdklogs/logs
XCONF_LOG_FILE_NAME=xconf.txt.0
XCONF_LOG_FILE_PATHNAME=${XCONF_LOG_PATH}/${XCONF_LOG_FILE_NAME}
XCONF_LOG_FILE=${XCONF_LOG_FILE_PATHNAME}

CURL_PATH=/bin
interface=erouter0
BIN_PATH=/bin

#GLOBAL DECLARATIONS
image_upg_avl=0


#
# release numbering system rules
#

# 5 part release numbering scheme where the five parts consisted of 
#+ "Major Rev"."Minor Rev"."Internal Rev". "Patch Level"."SPIN".

# 1.Major  Rev and Minor Rev will follow the matching RDKB version.
# 2.Any field which formerly contained  a zero (except for "Minor Rev") will be suppressed in the build number as well as the preceding "."
# 3.The "Spin" field will be  preceded by  "s"  for spin,  rather than a ".'  ie s4
# 4.The Spin field is always in the range of 1-x; Since it is  never 0, this field is always present.
# 5.The "Patch Level" field will be preceded by  "p" (lower case)  for patch rather than a "." . ie p2
# 6.The patch level field is in the range of 0-x.  If the patch level value is zero, the entire field will be suppressed including the leading "p". 
# 7."Internal Rev" can be in the range of 0-x, When the value of Internal Rev is 0, it will be suppressed, including the preceding "."
# 8.Initial State: We will be reverting the Internal Rev to Zero. This will allow us to suppress the field initially
# 9. The "Patch level" filed if present will always preceed "Spin" field.

# example build release numbers
# 1.22s55555                    spin_on_minor           3
# 1.22p4444s55555               spin_on_patch           1
# 1.22.333s55555                spin_on_internal        2
# 1.22.333p4444s55555           spin_on_patch           3
# 

# param1 : cur_rel_num param2 : upg_rel_num
# assumption : 
#       cur and upg firmware version are validated against release numbering system rules
#       no assumption is made about the length of the fields
# spin_on : 1 spin_on_patch 2 spin_on_internal 3 spin_on_minor

checkFirmwareUpgCriteria()
{
    image_upg_avl=0;

    # Retrieve current firmware version
    currentVersion=`dmcli eRT getvalues Device.DeviceInfo.X_CISCO_COM_FirmwareName | grep TG1682 | cut -d ":" -f 3 | tr -d ' '`

    echo "XCONF SCRIPT : CurrentVersion : $currentVersion"
    echo "XCONF SCRIPT : UpgradeVersion : $firmwareVersion"

    echo "XCONF SCRIPT : CurrentVersion : $currentVersion" >> $XCONF_LOG_FILE
    echo "XCONF SCRIPT : UpgradeVersion : $firmwareVersion" >> $XCONF_LOG_FILE

    cur_rel_num=`echo $currentVersion | cut -d "_" -f 2`
    upg_rel_num=`echo $firmwareVersion | cut -d "_" -f 2`

    cur_major_rev=0
    cur_minor_rev=0
    cur_internal_rev=0
    cur_patch_level=0
    cur_spin=1
    cur_spin_on=0

    upg_major_rev=0
    upg_minor_rev=0
    upg_internal_rev=0
    upg_patch_level=0
    upg_spin=1
    upg_spin_on=0

    #
    # Parse and normalize current firmware version
    #

    # major
    cur_major_rev=`echo $cur_rel_num | cut -d "." -f 1`

    # minor
    cur_first_dot_length=`expr match "${cur_rel_num}" '[0-9]*\.'`
    cur_second_dot_or_p_or_s_length=`expr match "${cur_rel_num}" '[0-9]*\.[0-9]*[\.,p,s]'`
    length=${cur_second_dot_or_p_or_s_length}
    length=$((length-$cur_first_dot_length))
    length=$((length-1))
    cur_minor_rev=${cur_rel_num:$cur_first_dot_length:$length}

    # internal
    cur_second_dot_length=`expr match "${cur_rel_num}" '[0-9]*\.[0-9]*[\.]'`
    #echo "XCONF SCRIPT : cur_second_dot_length=$cur_second_dot_length"
    if [ $cur_second_dot_length -eq 0 ]; then
        cur_internal_rev=0
    else
        cur_p_or_s_length=`expr match "${cur_rel_num}" '[0-9]*\.[0-9]*\.[0-9]*[p,s]'`
        #echo "XCONF SCRIPT : cur_p_or_s_length=$cur_p_or_s_length"
        length=${cur_p_or_s_length}
        length=$((length-$cur_second_dot_length))
        length=$((length-1))
        cur_internal_rev=${cur_rel_num:$cur_second_dot_length:$length}
    fi

    # patch
    cur_s_npos=`expr index "${cur_rel_num}" s`
    cur_p_npos=`expr index "${cur_rel_num}" p`
    if [ $cur_p_npos -eq 0 ]; then
        cur_patch_level=0
    else
        length=${cur_s_npos}
        length=$((length-$cur_p_npos))
        length=$((length-1))
        cur_patch_level=${cur_rel_num:$cur_p_npos:$length}
    fi

    # spin
    length=${cur_s_npos}
    cur_spin=${cur_rel_num:$length}

    if [ $cur_patch_level -ne 0 ];then
        cur_spin_on=1;
    elif [ $cur_internal_rev -ne 0 ];then
        cur_spin_on=2;
    else
        cur_spin_on=3;
    fi
    
    #
    # Parse and normalize upgrade firmware version
    # 

    # major
    upg_major_rev=`echo $upg_rel_num | cut -d "." -f 1`

    # minor
    upg_first_dot_length=`expr match "${upg_rel_num}" '[0-9]*\.'`
    upg_second_dot_or_p_or_s_length=`expr match "${upg_rel_num}" '[0-9]*\.[0-9]*[\.,p,s]'`
    length=${upg_second_dot_or_p_or_s_length}
    length=$((length-$upg_first_dot_length))
    length=$((length-1))
    upg_minor_rev=${upg_rel_num:$upg_first_dot_length:$length}

    # internal
    upg_second_dot_length=`expr match "${upg_rel_num}" '[0-9]*\.[0-9]*[\.]'`
    #echo "XCONF SCRIPT : upg_second_dot_length=$upg_second_dot_length"
    if [ $upg_second_dot_length -eq 0 ]; then
        upg_internal_rev=0
    else
        upg_p_or_s_length=`expr match "${upg_rel_num}" '[0-9]*\.[0-9]*\.[0-9]*[p,s]'`
        #echo "XCONF SCRIPT : upg_p_or_s_length=$upg_p_or_s_length"
        length=${upg_p_or_s_length}
        length=$((length-$upg_second_dot_length))
        length=$((length-1))
        upg_internal_rev=${upg_rel_num:$upg_second_dot_length:$length}
    fi

    # patch
    upg_s_npos=`expr index "${upg_rel_num}" s`
    upg_p_npos=`expr index "${upg_rel_num}" p`
    if [ $upg_p_npos -eq 0 ]; then
        upg_patch_level=0
    else
        length=${upg_s_npos}
        length=$((length-$upg_p_npos))
        length=$((length-1))
        upg_patch_level=${upg_rel_num:$upg_p_npos:$length}
    fi

    # spin
    length=${upg_s_npos}
    upg_spin=${upg_rel_num:$length}

    if [ $upg_patch_level -ne 0 ];then
        upg_spin_on=1;
    elif [ $upg_internal_rev -ne 0 ];then
        upg_spin_on=2;
    else
        upg_spin_on=3;
    fi

        if [ $upg_major_rev -gt $cur_major_rev ];then
            image_upg_avl=1;

        elif [ $upg_major_rev -lt $cur_major_rev ];then
            image_upg_avl=0

        elif [ $upg_major_rev -eq $cur_major_rev ];then
            echo "XCONF SCRIPT : Current and upgrade firmware major versions equal,"

            if [ $upg_minor_rev -gt $cur_minor_rev ];then
                image_upg_avl=1

            elif [ $upg_minor_rev -lt $cur_minor_rev ];then
                image_upg_avl=0

            elif [ $upg_minor_rev -eq $cur_minor_rev ];then
                echo "XCONF SCRIPT : Current and upgrade minor versions equal"

                if [ $upg_internal_rev -gt $cur_internal_rev ];then
                    image_upg_avl=1;

                elif [ $upg_internal_rev -lt $cur_internal_rev ];then
                    image_upg_avl=0

                elif [ $upg_internal_rev -eq $cur_internal_rev ];then
                    echo "XCONF SCRIPT : Current and upgrade firmware internal versions equal,"

                    if [ $upg_patch_level -gt $cur_patch_level ];then
                        image_upg_avl=1;

                    elif [ $upg_patch_level -lt $cur_patch_level ];then
                        image_upg_avl=0

                    elif [ $upg_patch_level -eq $cur_patch_level ];then
                        echo "XCONF SCRIPT : Current and upgrade firmware patch versions equal,"

                        if [ $upg_spin -gt $cur_spin ];then
                            image_upg_avl=1

                        elif [ $upg_spin -le $cur_spin ];then
                            echo "XCONF SCRIPT : Current and upgrade  spin versions equal/less"
                            image_upg_avl=0
                        fi
                    fi
                fi
            fi
        fi

    echo "XCONF SCRIPT : current --> [$cur_major_rev , $cur_minor_rev , $cur_internal_rev , $cur_patch_level , $cur_spin , $cur_spin_on , $cur_p_npos , $cur_s_npos]" 
    echo "XCONF SCRIPT : current --> [$cur_major_rev , $cur_minor_rev , $cur_internal_rev , $cur_patch_level , $cur_spin , $cur_spin_on , $cur_p_npos , $cur_s_npos]" >> $XCONF_LOG_FILE

    echo "XCONF SCRIPT : upgrade --> [$upg_major_rev , $upg_minor_rev , $upg_internal_rev , $upg_patch_level , $upg_spin , $upg_spin_on , $upg_p_npos , $upg_s_npos]" 
    echo "XCONF SCRIPT : upgrade --> [$upg_major_rev , $upg_minor_rev , $upg_internal_rev , $upg_patch_level , $upg_spin , $upg_spin_on , $upg_p_npos , $upg_s_npos]" >> $XCONF_LOG_FILE

    echo "XCONF SCRIPT : [$image_upg_avl] $cur_rel_num --> $upg_rel_num"
    echo "XCONF SCRIPT : [$image_upg_avl] $cur_rel_num --> $upg_rel_num" >> $XCONF_LOG_FILE

}

# Check if a new image is available on the XCONF server
getFirmwareUpgDetail()
{
    # The retry count and flag are used to resend a 
    # query to the XCONF server if issues with the 
    # respose or the URL received
    xconf_retry_count=1
    retry_flag=1

    # Set the XCONF server url read from /tmp/Xconf 
    # Determine the env from $type

    #s16 : env=`cat /tmp/Xconf | cut -d "=" -f1`
    env=$type
    xconf_url=`cat /tmp/Xconf | cut -d "=" -f2`
    
    # If an /tmp/Xconf file was not created, use the default values
    if [ ! -f /tmp/Xconf ]; then
        echo "XCONF SCRIPT : ERROR : /tmp/Xconf file not found! Using defaults"
        echo "XCONF SCRIPT : ERROR : /tmp/Xconf file not found! Using defaults" >> $XCONF_LOG_FILE
        env="PROD"
        xconf_url="https://xconf.xcal.tv/xconf/swu/stb/"
    fi

    echo "XCONF SCRIPT : env is $env"
    echo "XCONF SCRIPT : xconf url  is $xconf_url"

    # Check with the XCONF server if an update is available 
    while [ $xconf_retry_count -le 3 ] && [ $retry_flag -eq 1 ]
    do

        echo "**RETRY is $xconf_retry_count and RETRY_FLAG is $retry_flag**" >> $XCONF_LOG_FILE
        
        # White list the Xconf server url
        #echo "XCONF SCRIPT : Whitelisting Xconf Server url : $xconf_url"
        #echo "XCONF SCRIPT : Whitelisting Xconf Server url : $xconf_url" >> $XCONF_LOG_FILE
        #/etc/whitelist.sh "$xconf_url"
        
	    # Perform cleanup by deleting any previous responses
	    rm -f /tmp/response.txt
	    firmwareDownloadProtocol=""
	    firmwareFilename=""
	    firmwareLocation=""
	    firmwareVersion=""
	    rebootImmediately=""
        ipv6FirmwareLocation=""
        upgradeDelay=""
       
#TODO
		currentVersion=`cat /version.txt | grep "imagename:" | cut -d ":" -f 2`
#TODO
        MAC=`ifconfig $interface  | grep HWaddr | cut -d' ' -f7`
        date=`date`
        
        echo "XCONF SCRIPT : CURRENT VERSION : $currentVersion"
        echo "XCONF SCRIPT : CURRENT MAC  : $MAC"
        echo "XCONF SCRIPT : CURRENT DATE : $date"


        # Query the  XCONF Server
        HTTP_RESPONSE_CODE=`$CURL_PATH/curl --interface $interface -k -w '%{http_code}\n' -d "eStbMac=$MAC&firmwareVersion=$currentVersion&env=$env&model=TG1682G&localtime=$date&timezone=EST05&capabilities="rebootDecoupled"&capabilities="RCDL"&capabilities="supportsFullHttpUrl"" -o "/tmp/response.txt" "$xconf_url" --connect-timeout 30 -m 30`
	    
        echo "XCONF SCRIPT : HTTP RESPONSE CODE is" $HTTP_RESPONSE_CODE
        # Print the response
        cat /tmp/response.txt
        cat "/tmp/response.txt" >> $XCONF_LOG_FILE

	    if [ $HTTP_RESPONSE_CODE -eq 200 ];then
		    retry_flag=0
		    firmwareDownloadProtocol=`head -n1 /tmp/response.txt | cut -d "," -f1 | cut -d ":" -f2 | cut -d '"' -f2`

		    if [ "$firmwareDownloadProtocol" == "http" ];then
                echo "XCONF SCRIPT : Download image from HTTP server"
                firmwareLocation=`head -n1 /tmp/response.txt | cut -d "," -f3 | cut -d ":" -f2- | cut -d '"' -f2`
            else
                echo "XCONF SCRIPT : Download from TFTP server not supported, check XCONF server configurations"
                echo "XCONF SCRIPT : Retrying query in 2 minutes"
                
                # sleep for 2 minutes and retry
                sleep 120;

                retry_flag=1
                image_upg_avl=0

                #Increment the retry count
                xconf_retry_count=$((xconf_retry_count+1))

                continue
            fi

    	    firmwareFilename=`head -n1 /tmp/response.txt | cut -d "," -f2 | cut -d ":" -f2 | cut -d '"' -f2`
    	   	firmwareVersion=`head -n1 /tmp/response.txt | cut -d "," -f4 | cut -d ":" -f2 | cut -d '"' -f2`
	    	ipv6FirmwareLocation=`head -n1 /tmp/response.txt | cut -d "," -f5 | cut -d ":" -f2-`
	    	upgradeDelay=`head -n1 /tmp/response.txt | cut -d "," -f6 | cut -d ":" -f2`
            
            if [ "$env" == "dev" ] || [ "$env" == "DEV" ];then
    	   	    rebootImmediately=`head -n1 /tmp/response.txt | cut -d "," -f7 | cut -d ":" -f2 | cut -d '}' -f1`
            else
                rebootImmediately=`head -n1 /tmp/response.txt | cut -d "," -f5 | cut -d ":" -f2 | cut -d '}' -f1`
            fi    
                                    
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
#TODO
echo "Currently disbling checkFirmwareUpgCriteria temporarily. Once the XB6 image is having conventional PROD naming, then we have to enable it"
#checkFirmwareUpgCriteria  
#TODO	
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
        
        echo "XCONF SCRIPT : Check Update time being calculated within 24 hrs."
        echo "XCONF SCRIPT : Check Update time being calculated within 24 hrs." >> $XCONF_LOG_FILE

        # Calculate random hour
        # The max random time can be 23:59:59
        rand_hr=`awk -v min=0 -v max=23 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

        echo "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec"
        min_to_sleep=$(($rand_hr*60 + $rand_min))
        sec_to_sleep=$(($min_to_sleep*60 + $rand_sec))

        printf "XCONF SCRIPT : Checking update with XCONF server at \t";
        # date -d "$min_to_sleep minutes" +'%H:%M:%S'
        date -D '%s' -d "$(( `date +%s`+$sec_to_sleep ))"

        date_upgch_part="$(( `date +%s`+$sec_to_sleep ))"
        date_upgch_final=`date -D '%s' -d "$date_upgch_part"`

        echo "Checking update on $date_upgch_final" >> $XCONF_LOG_FILE

    fi

    #
    # Generate time to downlaod HTTP image
    # device reboot time 
    #
    if [ $2 -eq '1' ]; then
       
        if [ "$3" == "r" ]; then
            echo "XCONF SCRIPT : Device reboot time being calculated in maintenance window"
            echo "XCONF SCRIPT : Device reboot time being calculated in maintenance window" >> $XCONF_LOG_FILE
        fi 
                 
        # Calculate random hour
        # The max time random time can be 4:59:59
        rand_hr=`awk -v min=0 -v max=3 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

        echo "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec"

        cur_hr=`date +"%H"`
        cur_min=`date +"%M"`
        cur_sec=`date +"%S"`

        # Time to maintenance window
        if [ $cur_hr -eq 0 ];then
            start_hr=0
        else
            start_hr=`expr 23 - ${cur_hr} + 1`
        fi

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

        date_part="$(( `date +%s`+$sec_to_sleep ))"
        date_final=`date -D '%s' -d "$date_part"`

        echo "Action on $date_final" >> $XCONF_LOG_FILE

    fi

    echo "XCONF SCRIPT : SLEEPING FOR $min_to_sleep minutes or $sec_to_sleep seconds"
    
    #echo "XCONF SCRIPT : SPIN 17 : sleeping for 30 sec, *******TEST BUILD***********"
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
   IMAGENAME=`cat /version.txt | grep "imagename:" | cut -d ":" -f 2`
   
   #Assigning default type as VBN
   type="VBN"
   echo "XCONF SCRIPT : Assigning default image type as: $type"

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
   if [ "$TEMPCQA" != "" ]
   then
       type="GSLB"
   fi
   
   echo "XCONF SCRIPT : image_type returned $type"
   echo "XCONF SCRIPT : image_type returned $type" >> $XCONF_LOG_FILE
}

 
removeLegacyResources()
{
	#moved Xconf logging to /var/tmp/xconf.txt.0
    if [ -f /etc/Xconf.log ]; then
		rm /etc/Xconf.log
    fi

	echo "XCONF SCRIPT : Done Cleanup"
	echo "XCONF SCRIPT : Done Cleanup" >> $XCONF_LOG_FILE
}

#####################################################Main Application#####################################################

# Determine the env type and url and write to /tmp/Xconf
#type=`printenv model | cut -d "=" -f2`

removeLegacyResources
getBuildType

echo XCONF SCRIPT : MODEL IS $type

if [ "$type" == "DEV" ] || [ "$type" == "dev" ];then
    #url="https://xconf.poa.xcal.tv/xconf/swu/stb/"
    url="http://69.252.111.22/xconf/swu/stb/"
else
    url="https://xconf.xcal.tv/xconf/swu/stb/"
fi
if [ -f /nvram/swupdate.conf ] ; then
	url=`grep -v '^[[:space:]]*#' /nvram/swupdate.conf`
	echo "XCONF SCRIPT : URL taken from /nvram/swupdate.conf override. URL=$url"
fi	

#s16 echo "$type=$url" > /tmp/Xconf
echo "URL=$url" > /tmp/Xconf
echo "XCONF SCRIPT : Values written to /tmp/Xconf are URL=$url"
echo "XCONF SCRIPT : Values written to /tmp/Xconf are URL=$url" >> $XCONF_LOG_FILE

# Check if the WAN interface has an ip address, if not , wait for it to receive one
estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
estbIp6=`ifconfig $interface | grep "inet6 addr" | tr -s " " | cut -d ":" -f2- | cut -d "/" -f1 | tr -d " "`

echo "[ $(date) ] XCONF SCRIPT - Check if the WAN interface has an ip address" >> $XCONF_LOG_FILE

while [ "$estbIp" = "" ] && [ "$estbIp6" = "" ]
do
    echo "[ $(date) ] XCONF SCRIPT - No IP yet! sleep(5)" >> $XCONF_LOG_FILE
    sleep 5

    estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
    estbIp6=`ifconfig $interface | grep "inet6 addr" | tr -s " " | cut -d ":" -f2- | cut -d "/" -f1 | tr -d " "`

    echo "XCONF SCRIPT : Sleeping for an ipv4 or an ipv6 address on the $interface interface "
done

echo "XCONF SCRIPT : $interface has an ipv4 address of $estbIp or an ipv6 address of $estbIp6"

    ######################
    # QUERY & DL MANAGER #
    ######################

# Check if new image is available
echo "XCONF SCRIPT : Checking image availability at boot up" >> $XCONF_LOG_FILE	
getFirmwareUpgDetail

if [ "$rebootImmediately" == "true" ];then
    echo "XCONF SCRIPT : Reboot Immediately : TRUE!!"
else
    echo "XCONF SCRIPT : Reboot Immediately : FALSE."

fi    

download_image_success=0
reboot_device_success=0

while [ $download_image_success -eq 0 ]; 
do
    # If an image wasn't available, check it's 
    # availability at a random time,every 24 hrs
    while  [ $image_upg_avl -eq 0 ];
    do
        echo "XCONF SCRIPT : Rechecking image availability within 24 hrs" 
        echo "XCONF SCRIPT : Rechecking image availability within 24 hrs" >> $XCONF_LOG_FILE

        # Sleep for a random time less than 
        # a 24 hour duration 
        calcRandTime 1 0
    
        # Check for the availability of an update   
        getFirmwareUpgDetail
    done

    if [ $image_upg_avl -eq 1 ];then

        #Wait for dnsmasq to start
#DNSMASQ_PID=`pidof dnsmasq`
#
#       while [ "$DNSMASQ_PID" = "" ]
#       do
#           sleep 10
#           echo "XCONF SCRIPT : Waiting for dnsmasq process to start"
#           echo "XCONF SCRIPT : Waiting for dnsmasq process to start" >> $XCONF_LOG_FILE
#           DNSMASQ_PID=`pidof dnsmasq`
#       done
#
#       echo "XCONF SCRIPT : dnsmasq process  started!!"
#       echo "XCONF SCRIPT : dnsmasq process  started!!" >> $XCONF_LOG_FILE
    
        # Whitelist the returned firmware location
        #echo "XCONF SCRIPT : Whitelisting download location : $firmwareLocation"
        #echo "XCONF SCRIPT : Whitelisting download location : $firmwareLocation" >> $XCONF_LOG_FILE
        echo "$firmwareLocation" > /tmp/xconfdownloadurl
        #/etc/whitelist.sh "$firmwareLocation"

        # Set the url and filename
        echo "XCONF SCRIPT : URL --- $firmwareLocation and NAME --- $firmwareFilename"
        echo "XCONF SCRIPT : URL --- $firmwareLocation and NAME --- $firmwareFilename" >> $XCONF_LOG_FILE
        $BIN_PATH/XconfHttpDl set_http_url $firmwareLocation $firmwareFilename
        set_url_stat=$?
        
        # If the URL was correctly set, initiate the download
        if [ $set_url_stat -eq 0 ];then
        
            # An upgrade is available and the URL has ben set 
            # Wait to download in the maintenance window if the RebootImmediately is FALSE
            # else download the image immediately

            if [ "$rebootImmediately" == "false" ];then

				echo "XCONF SCRIPT : Reboot Immediately : FALSE. Downloading image now"
				echo "XCONF SCRIPT : Reboot Immediately : FALSE. Downloading image now" >> $XCONF_LOG_FILE
            else
                echo  "XCONF SCRIPT : Reboot Immediately : TRUE : Downloading image now"
                echo  "XCONF SCRIPT : Reboot Immediately : TRUE : Downloading image now" >> $XCONF_LOG_FILE
            fi
			
			#echo "XCONF SCRIPT : Sleep to prevent gw refresh error"
			#echo "XCONF SCRIPT : Sleep to prevent gw refresh error" >> $XCONF_LOG_FILE
            #sleep 60

	        # Start the image download
			echo "[ $(date) ] XCONF SCRIPT  ### httpdownload started ###" >> $XCONF_LOG_FILE
	        $BIN_PATH/XconfHttpDl http_download
	        http_dl_stat=$?
			echo "[ $(date) ] XCONF SCRIPT  ### httpdownload completed ###" >> $XCONF_LOG_FILE
	        echo "XCONF SCRIPT : HTTP DL STATUS $http_dl_stat"
	        echo "**XCONF SCRIPT : HTTP DL STATUS $http_dl_stat**" >> $XCONF_LOG_FILE
			
	        # If the http_dl_stat is 0, the download was succesful,          
            # Indicate a succesful download and continue to the reboot manager
		
            if [ $http_dl_stat -eq 0 ];then
                echo "XCONF SCRIPT : HTTP download Successful" >> $XCONF_LOG_FILE
                # Indicate succesful download
                download_image_success=1
            else
                # Indicate an unsuccesful download
                echo "XCONF SCRIPT : HTTP download NOT Successful" >> $XCONF_LOG_FILE
                download_image_success=0
                # Set the flag to 0 to force a requery
                image_upg_avl=0
            fi

        else
            echo "XCONF SCRIPT : ERROR : URL & Filename not set correctly.Requerying "
            echo "XCONF SCRIPT : ERROR : URL & Filename not set correctly.Requerying " >> $XCONF_LOG_FILE
            # Indicate an unsuccesful download
            download_image_success=0
            # Set the flag to 0 to force a requery
            image_upg_avl=0
        fi
    fi
done

    ##################
    # REBOOT MANAGER #
    ##################

    # Try rebooting the device if :
    # 1. Issue an immediate reboot if still within the maintenance window and phone is on hook
    # 2. If an immediate reboot is not possile ,calculate and remain within the reboot maintenance window
    # 3. The reboot ready status is OK within the maintenance window 
    # 4. The rebootImmediate flag is set to true

while [ $reboot_device_success -eq 0 ]; do
                    
    # Verify reboot criteria ONLY if rebootImmediately is FALSE
    if [ "$rebootImmediately" == "false" ];then

        # Check if still within reboot window
        reb_hr=`date +"%H"`

        if [ $reb_hr -le 4 ] && [ $reb_hr -ge 1 ]; then
            echo "XCONF SCRIPT : Still within current maintenance window for reboot"
            echo "XCONF SCRIPT : Still within current maintenance window for reboot" >> $XCONF_LOG_FILE
            reboot_now=1    
        else
            echo "XCONF SCRIPT : Not within current maintenance window for reboot.Rebooting in  the next "
            echo "XCONF SCRIPT : Not within current maintenance window for reboot.Rebooting in  the next " >> $XCONF_LOG_FILE
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

    else
        #RebootImmediately is TRUE
        echo "XCONF SCRIPT : Reboot Immediately : TRUE!, rebooting device now"
        http_reboot_ready_stat=0    
        echo "XCONF SCRIPT : http_reboot_ready_stat is $http_reboot_ready_stat"
                            
    fi 
                    
    echo "XCONF SCRIPT : http_reboot_ready_stat is $http_reboot_ready_stat" >> $XCONF_LOG_FILE

    # The reboot ready status changed to OK within the maintenance window,proceed
    if [ $http_reboot_ready_stat -eq 0 ];then
		        
        #Reboot the device
	    echo "XCONF SCRIPT : Reboot possible. Issuing reboot command"
	    echo "RDKB_REBOOT : Reboot command issued from XCONF"
		$BIN_PATH/XconfHttpDl http_reboot 
		reboot_device=$?
		       
        # This indicates we're within the maintenace window/rebootImmediate=TRUE
        # and the reboot ready status is OK, issue the reboot
        # command and check if it returned correctly
		if [ $reboot_device -eq 0 ];then
            reboot_device_success=1
		    echo "XCONF SCRIPT : REBOOTING DEVICE"
                
        else 
            # The reboot command failed, retry in the next maintenance window 
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
