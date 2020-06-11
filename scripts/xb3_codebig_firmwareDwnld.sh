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
source /lib/rdk/getpartnerid.sh
source /lib/rdk/getaccountid.sh
source /lib/rdk/t2Shared_api.sh

if [ -f /etc/device.properties ]
then
    source /etc/device.properties
fi

XCONF_LOG_FILE_NAME=xconf.txt.0
XCONF_LOG_FILE_PATHNAME=${LOG_PATH}/${XCONF_LOG_FILE_NAME}
XCONF_LOG_FILE=${XCONF_LOG_FILE_PATHNAME}

CURL_PATH=/fss/gw/usr/bin
interface=erouter0
BIN_PATH=/fss/gw/usr/bin
REBOOT_WAIT="/tmp/.waitingreboot"
DOWNLOAD_INPROGRESS="/tmp/.downloadingfw"
deferReboot="/tmp/.deferringreboot"
NO_DOWNLOAD="/tmp/.downloadBreak"
ABORT_REBOOT="/tmp/AbortReboot"
abortReboot_count=0

CRONTAB_DIR="/var/spool/cron/crontabs/"
CRON_FILE_BK="/tmp/cron_tab$$.txt"
LAST_HTTP_RESPONSE="/tmp/XconfSavedOutput"

#GLOBAL DECLARATIONS
image_upg_avl=0
reb_window=0
CDL_SERVER_OVERRIDE=0
FILENAME="/tmp/response.txt"
OUTPUT="/tmp/XconfOutput.txt"
HTTP_CODE=/tmp/fwdl_http_code.txt
WAN_INTERFACE="erouter0"

firmwareName_configured=""

FW_START="/nvram/.FirmwareUpgradeStartTime"
FW_END="/nvram/.FirmwareUpgradeEndTime"

#to support ocsp
EnableOCSPStapling="/tmp/.EnableOCSPStapling"
EnableOCSP="/tmp/.EnableOCSPCA"

if [ -f $EnableOCSPStapling ] || [ -f $EnableOCSP ]; then
    CERT_STATUS="--cert-status"
fi

isPeriodicFWCheckEnabled=`syscfg get PeriodicFWCheck_Enable`
isWanLinkHealEnabled=`syscfg get wanlinkheal`

CONN_TRIES=3
CODEBIG_BLOCK_TIME=1800
CODEBIG_BLOCK_FILENAME="/tmp/.lastcodebigfail_cdl"
FORCE_DIRECT_ONCE="/tmp/.forcedirectonce_cdl"

conn_str="Direct"
CodebigAvailable=0
UseCodebig=0


#if [ $# -ne 1 ]; then
        #echo "USAGE: $0 <TFTP Server IP> <UploadProtocol> <UploadHttpLink> <uploadOnReboot>"
#    echo "USAGE: $0 <firmwareName>"
#else
#        firmwareName_configured=$1
#fi

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


IsCodebigBlocked()
{
    ret=0
    if [ -f $CODEBIG_BLOCK_FILENAME ]; then
        modtime=$(($(date +%s) - $(date +%s -r $CODEBIG_BLOCK_FILENAME)))
        if [ "$modtime" -le "$CODEBIG_BLOCK_TIME" ]; then
            echo "XCONF SCRIPT: Last Codebig failed blocking is still valid, preventing Codebig" >>  $DCM_LOG_FILE
            ret=1
        else
            echo "XCONF SCRIPT: Last Codebig failed blocking has expired, removing $CODEBIG_BLOCK_FILENAME, allowing Codebig" >> $DCM_LOG_FILE
            rm -f $CODEBIG_BLOCK_FILENAME
            ret=0
        fi
    fi
    return $ret
}

# Get the configuration of codebig settings
get_Codebigconfig()
{
   UseCodebig=0
   # If /usr/bin/GetServiceUrl not available, then only direct connection available and no fallback mechanism
   if [ -f /usr/bin/GetServiceUrl ]; then
      CodebigAvailable=1
   fi
   if [ "$CodebigAvailable" -eq "1" ]; then
       CodeBigEnable=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.CodeBigFirst.Enable | grep value | cut -f3 -d : | cut -f2 -d " "`
   fi

   if [ -f $FORCE_DIRECT_ONCE ]; then
      rm -f $FORCE_DIRECT_ONCE
      echo_t "XCONF SCRIPT : Last Codebig attempt failed, forcing direct once" >> $XCONF_LOG_FILE
   elif [ "$CodebigAvailable" -eq "1" ] && [ "x$CodeBigEnable" == "xtrue" ] ; then
      UseCodebig=1
      conn_str="Codebig" 
   fi

   echo_t "XCONF SCRIPT : Using $conn_str connection as the Primary"
   echo_t "XCONF SCRIPT : Using $conn_str connection as the Primary" >> $XCONF_LOG_FILE
}

checkFirmwareUpgCriteria()
{
    image_upg_avl=0;

    # Retrieve current firmware version
      currentVersion=`dmcli eRT getvalues Device.DeviceInfo.X_CISCO_COM_FirmwareName | grep value | cut -d ":" -f 3 | tr -d ' ' `

    echo_t "XCONF SCRIPT : CurrentVersion : $currentVersion"
    echo_t "XCONF SCRIPT : UpgradeVersion : $firmwareVersion"

    echo_t "XCONF SCRIPT : CurrentVersion : $currentVersion" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : UpgradeVersion : $firmwareVersion" >> $XCONF_LOG_FILE

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
            image_upg_avl=1

        elif [ $upg_major_rev -eq $cur_major_rev ];then
            echo_t "XCONF SCRIPT : Current and upgrade firmware major versions equal,"

            if [ $upg_minor_rev -gt $cur_minor_rev ];then
                image_upg_avl=1

            elif [ $upg_minor_rev -lt $cur_minor_rev ];then
                image_upg_avl=1

            elif [ $upg_minor_rev -eq $cur_minor_rev ];then
                echo_t "XCONF SCRIPT : Current and upgrade minor versions equal"

                if [ $upg_internal_rev -gt $cur_internal_rev ];then
                    image_upg_avl=1;

                elif [ $upg_internal_rev -lt $cur_internal_rev ];then
                    image_upg_avl=1

                elif [ $upg_internal_rev -eq $cur_internal_rev ];then
                    echo_t "XCONF SCRIPT : Current and upgrade firmware internal versions equal,"

                    if [ $upg_patch_level -gt $cur_patch_level ];then
                        image_upg_avl=1;

                    elif [ $upg_patch_level -lt $cur_patch_level ];then
                        image_upg_avl=1

                    elif [ $upg_patch_level -eq $cur_patch_level ];then
                        echo_t "XCONF SCRIPT : Current and upgrade firmware patch versions equal,"

                        if [ $upg_spin -gt $cur_spin ];then
                            image_upg_avl=1

                        elif [ $upg_spin -lt $cur_spin ];then
                            image_upg_avl=1

                        elif [ $upg_spin -eq $cur_spin ];then
                            echo_t "XCONF SCRIPT : Current and upgrade  spin versions equal/less"
                            image_upg_avl=0
                        fi
                    fi
                fi
            fi
        fi

    echo_t "XCONF SCRIPT : current --> [$cur_major_rev , $cur_minor_rev , $cur_internal_rev , $cur_patch_level , $cur_spin , $cur_spin_on , $cur_p_npos , $cur_s_npos]"
    echo_t "XCONF SCRIPT : current --> [$cur_major_rev , $cur_minor_rev , $cur_internal_rev , $cur_patch_level , $cur_spin , $cur_spin_on , $cur_p_npos , $cur_s_npos]" >> $XCONF_LOG_FILE

    echo_t "XCONF SCRIPT : upgrade --> [$upg_major_rev , $upg_minor_rev , $upg_internal_rev , $upg_patch_level , $upg_spin , $upg_spin_on , $upg_p_npos , $upg_s_npos]"
    echo_t "XCONF SCRIPT : upgrade --> [$upg_major_rev , $upg_minor_rev , $upg_internal_rev , $upg_patch_level , $upg_spin , $upg_spin_on , $upg_p_npos , $upg_s_npos]" >> $XCONF_LOG_FILE

    echo_t "XCONF SCRIPT : [$image_upg_avl] $cur_rel_num --> $upg_rel_num"
    echo_t "XCONF SCRIPT : [$image_upg_avl] $cur_rel_num --> $upg_rel_num" >> $XCONF_LOG_FILE

}

#This is a temporary function added to check FirmwareUpgCriteria
#This function will not check any other criteria other than matching current firmware and requested firmware

checkFirmwareUpgCriteria_temp()
{
                image_upg_avl=0

                currentVersion=$IMAGENAME
                firmwareVersion=`grep firmwareVersion $OUTPUT | cut -d \| -f2 | sed 's/-signed.*//'`
                currentVersion=`echo $currentVersion | tr '[A-Z]' '[a-z]'`
                firmwareVersion=`echo $firmwareVersion | tr '[A-Z]' '[a-z]'`
                if [ "$currentVersion" != "" ] && [ "$firmwareVersion" != "" ];then
                        if [ "$currentVersion" == "$firmwareVersion" ]; then
                                echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are same. No upgrade/downgrade required"
                                echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are same. No upgrade/downgrade required">> $XCONF_LOG_FILE
                                image_upg_avl=0
								if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
									exit
								fi
                        else
                                echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are different. Processing Upgrade/Downgrade"
                                echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are different. Processing Upgrade/Downgrade">> $XCONF_LOG_FILE
                                image_upg_avl=1
                        fi
                else
                        echo_t "XCONF SCRIPT : Current image ("$currentVersion") Or Requested image ("$firmwareVersion") returned NULL. No Upgrade/Downgrade"
                        echo_t "XCONF SCRIPT : Current image ("$currentVersion") Or Requested image ("$firmwareVersion") returned NULL. No Upgrade/Downgrade">> $XCONF_LOG_FILE
                        image_upg_avl=0
						if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
							exit  
						fi  

                                                                                                                                                                       fi
}

getRequestType()
{
     request_type=2
     if [ "$1" == "ci.xconfds.ccp.xcal.tv" ]; then
            request_type=4
     fi
     return $request_type
}

# Adjusting date. This is required for liboauth patch
adjustDate()
{
retries=0
while [ "$retries" -lt 10 ]
do
    echo_t "Trial $retries..."

    if [ $retries -ne 0 ]
    then
        if [ -f /nvram/adjdate.txt ];
        then
        	echo -e "$0  --> /nvram/adjdate exist. It is used by another program"
            echo -e "$0 --> Sleeping 15 seconds and try again\n"
        else
            echo -e "$0  --> /nvram/adjdate NOT exist. Writing date value"
            dateString=`date +'%s'`
            count=$(expr $dateString - $SECONDV)
            echo "$0  --> date adjusted:"
            date -d @$count
            echo $count > /nvram/adjdate.txt
            break
         fi
    fi

        retries=`expr $retries + 1`
        sleep 15
done
if [ ! -f /nvram/adjdate.txt ];then
        echo_t "XCONF Failed...... Because unable to write to /nvram/adjdate.txt"
fi

}


# Check if a new image is available on the XCONF server
getFirmwareUpgDetail()
{
    # The retry count and flag are used to resend a
    # query to the XCONF server if issues with the
    # respose or the URL received
    xconf_retry_count=0
    retry_flag=1
    isIPv6=`ifconfig erouter0 | grep inet6 | grep -i 'Global'`

    # Set the XCONF server url read from /tmp/Xconf
    # Determine the env from $type

    #s16 : env=`cat /tmp/Xconf | cut -d "=" -f1`
    env=$type

    # If an /tmp/Xconf file was not created, use the default values
    if [ ! -f /tmp/Xconf ]; then
        echo_t "XCONF SCRIPT : ERROR : /tmp/Xconf file not found! Using defaults"
        echo_t "XCONF SCRIPT : ERROR : /tmp/Xconf file not found! Using defaults" >> $XCONF_LOG_FILE
        env="PROD"
        xconf_url="https://xconf.xcal.tv/xconf/swu/stb/"
    else
        xconf_url=`cut -d "=" -f2 /tmp/Xconf`
    fi

    # if xconf_url uses http, then log it
    case $(echo "$xconf_url" | cut -d ":" -f1 | tr '[:upper:]' '[:lower:]') in
        "https")
            #echo_t "XCONF SCRIPT : firmware download using HTTPS to $xconf_url" >> $XCONF_LOG_FILE
            ;;
        "http")
            echo_t "XCONF SCRIPT : firmware download using insecure protocol to $xconf_url" >> $XCONF_LOG_FILE
            ;;
        *)
            echo_t "XCONF SCRIPT : ERROR : firmware download using invalid URL to '$xconf_url'" >> $XCONF_LOG_FILE
            ;;
    esac

    get_Codebigconfig
    # Check with the XCONF server if an update is available
    while [ $xconf_retry_count -lt $CONN_TRIES ] && [ $retry_flag -eq 1 ]
    do

        echo_t "**RETRY is $((xconf_retry_count + 1)) and RETRY_FLAG is $retry_flag**" >> $XCONF_LOG_FILE

        # White list the Xconf server url
        #echo "XCONF SCRIPT : Whitelisting Xconf Server url : $xconf_url"
        #echo "XCONF SCRIPT : Whitelisting Xconf Server url : $xconf_url" >> $XCONF_LOG_FILE
        #/etc/whitelist.sh "$xconf_url"

        # Perform cleanup by deleting any previous responses
        rm -f $FILENAME
        rm -f $HTTP_CODE
        rm -f $OUTPUT

        firmwareDownloadProtocol=""
        firmwareFilename=""
        firmwareLocation=""
        firmwareVersion=""
        rebootImmediately=""
        ipv6FirmwareLocation=""
        upgradeDelay=""
        delayDownload=""

        currentVersion=$IMAGENAME
        devicemodel=$modelName

        # Retry if $devicemodel is NULL
        if [ -z "$devicemodel" ];then
            devicemodel=`dmcli eRT getv Device.DeviceInfo.ModelName | grep value | cut -d ":" -f 3 | tr -d ' ' `
        fi

	if [ "$devicemodel" == "" ];then
            echo_t "XCONF SCRIPT : Device model returned NULL from DeviceInfo.ModelName . Reading it from /etc/device.properties " >> $XCONF_LOG_FILE
            devicemodel=$MODEL_NUM
        fi

        MAC=`ifconfig  | grep $interface |  grep -v $interface:0 | tr -s ' ' | cut -d ' ' -f5`
                date=`date`

        echo_t "XCONF SCRIPT : CURRENT VERSION : $currentVersion"
        echo_t "XCONF SCRIPT : CURRENT MAC  : $MAC"
        echo_t "XCONF SCRIPT : CURRENT DATE : $date"
        if [ "$UseCodebig" -eq "1" ] && [ $CDL_SERVER_OVERRIDE -eq 0 ];then
            SECONDV=`dmcli eRT getv Device.X_CISCO_COM_CableModem.TimeOffset | grep value | cut -d ":" -f 3 | tr -d ' ' `
            serial=`dmcli eRT getv Device.DeviceInfo.SerialNumber | grep value | cut -d ":" -f 3 | tr -d ' ' `
            CB_CAPABILITIES='&capabilities=rebootDecoupled&capabilities="RCDL"&capabilities="supportsFullHttpUrl"'
            request_type=2

            echo_t "XCONF SCRIPT : OFFSET TIME : $SECONDV" >> $XCONF_LOG_FIL
            echo_t "XCONF SCRIPT : SERIAL : $serial" >> $XCONF_LOG_FILE

            echo_t "XCONF SCRIPT : Adjusting date"

	    adjustDate                
        fi

		if [ "$firmwareName_configured" != "" ]; then
                    currentVersion=$firmwareName_configured
                fi
                partnerId=$(getPartnerId)
                accountId=$(getAccountId)
                unitActivationStatus=`syscfg get unit_activated`

                if [ -z "$unitActivationStatus" ] || [ $unitActivationStatus -eq 0 ]; then
                    activationInProgress="true"
                else
                    activationInProgress="false"
                fi

		if [ "$UseCodebig" -eq "0" ] || [ $CDL_SERVER_OVERRIDE -eq 1 ];then
                        echo_t "Trying Direct Communication" >> $XCONF_LOG_FILE
			echo_t "XCONF SCRIPT : Post string creation"
			POSTSTR="eStbMac=$MAC&firmwareVersion=$currentVersion&env=$env&model=$devicemodel&partnerId=$partnerId&activationInProgress=${activationInProgress}&accountId=${accountId}&localtime=$date&timezone=EST05&capabilities=\"rebootDecoupled\"&capabilities=\"RCDL\"&capabilities=\"supportsFullHttpUrl\""
			echo_t "XCONF SCRIPT : POSTSTR : $POSTSTR" >> $XCONF_LOG_FILE

			# Query the  XCONF Server, using TLS 1.2
			echo_t "Attempting TLS1.2 connection to $xconf_url " >> $XCONF_LOG_FILE
			CURL_CMD="curl $CERT_STATUS --connect-timeout 30 --interface $interface $addr_type -w '%{http_code}\n' --tlsv1.2 -d \"$POSTSTR\" -o \"$FILENAME\" $xconf_url -m 30"
			echo_t "CURL_CMD: $CURL_CMD" >> $XCONF_LOG_FILE
			result= eval "$CURL_CMD" > $HTTP_CODE
			ret=$?

			HTTP_RESPONSE_CODE=$(awk -F\" '{print $1}' $HTTP_CODE)
			echo_t "ret = $ret http_code: $HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE

		else
                echo_t "Trying Codebig Communication" >> $XCONF_LOG_FILE
                ###############Jason string creation##########
                echo_t "XCONF SCRIPT : Jason string creation"
                JSONSTR="&eStbMac=${MAC}&firmwareVersion=${currentVersion}&env=${env}&model=${devicemodel}&partnerId=${partnerId}&activationInProgress=${activationInProgress}&accountId=${accountId}&serial=$serial&localtime=${date}&timezone=US/Eastern${CB_CAPABILITIES}"
                echo_t "XCONF SCRIPT : JSONSTR : $JSONSTR" >> $XCONF_LOG_FILE
                echo_t "XCONF SCRIPT : Get Signed URL"

                domain_name=`echo $xconf_url | cut -d / -f3`
                getRequestType $domain_name
                request_type=$?

                ########Get Signed URL from configparamgen.################
                SIGN_CMD="configparamgen $request_type \"$JSONSTR\""
                eval $SIGN_CMD > /nvram/.signedRequest
                echo_t "configparamgen success" >> $XCONF_LOG_FILE
                CB_SIGNED_REQUEST=`cat /nvram/.signedRequest`
                SIGNED_REQUEST_LOG=`echo $CB_SIGNED_REQUEST | sed -ne 's#oauth_consumer_key=.*oauth_signature.*#-- <hidden> --#p'`
                echo_t "CB_SIGNED_REQUEST : $SIGNED_REQUEST_LOG" >>$XCONF_LOG_FILE
                rm -f /nvram/.signedRequest
                rm -f /nvram/adjdate.txt

                echo_t "XCONF SCRIPT : Executing CURL for  https://xconf-prod.codebig2.net "

            # Query the  XCONF Server, using TLS 1.2
            echo_t "Attempting TLS1.2 connection to $xconf_url " >> $XCONF_LOG_FILE
            CURL_CMD="curl $CERT_STATUS --connect-timeout 30 --interface $interface $addr_type -w '%{http_code}\n' --tlsv1.2 -o \"$FILENAME\" \"$CB_SIGNED_REQUEST\" -m 30"
            CURL_CMD_LOG=`echo $CURL_CMD | sed -ne 's#oauth_consumer_key=.*oauth_signature.*#-- <hidden> --#p'`
            echo_t "CURL_CMD:$CURL_CMD_LOG"
            echo_t "CURL_CMD:$CURL_CMD_LOG" >> $XCONF_LOG_FILE
            result= eval "$CURL_CMD" > $HTTP_CODE
            ret=$?

            HTTP_RESPONSE_CODE=$(awk -F\" '{print $1}' $HTTP_CODE)
            echo_t "ret = $ret http_code: $HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE
            echo_t "Codebig Communication - ret:$ret, http_code:$HTTP_RESPONSE_CODE" | tee -a $XCONF_LOG_FILE ${LOG_PATH}/TlsVerify.txt
		fi	

        echo_t "XCONF SCRIPT : HTTP RESPONSE CODE is $HTTP_RESPONSE_CODE"
        echo_t "XCONF SCRIPT : HTTP RESPONSE CODE is $HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE

            if [ $HTTP_RESPONSE_CODE -eq 200 ];then
		    # Print the response
		    cat $FILENAME
		    echo
		    cat "$FILENAME" >> $XCONF_LOG_FILE
		    echo >> $XCONF_LOG_FILE

                    cat "$FILENAME" | tr -d '\n' | sed 's/[{}]//g' | awk  '{n=split($0,a,","); for (i=1; i<=n; i++) print a[i]}' | sed 's/\"\:\"/\|/g' | sed -r 's/\"\:(true)($)/\|true/gI' | sed -r 's/\"\:(false)($)/\|false/gI' | sed -r 's/\"\:(null)($)/\|\1/gI' | sed -r 's/\"\:(-?[0-9]+)($)/\|\1/g' | sed 's/[\,]/ /g' | sed 's/\"//g' > $OUTPUT

                    retry_flag=0

		firmwareDownloadProtocol=`grep firmwareDownloadProtocol $OUTPUT  | cut -d \| -f2`

                echo_t "XCONF SCRIPT : firmwareDownloadProtocol [$firmwareDownloadProtocol]"
                echo_t "XCONF SCRIPT : firmwareDownloadProtocol [$firmwareDownloadProtocol]" >> $XCONF_LOG_FILE

                    if [ "$firmwareDownloadProtocol" == "http" ];then
                echo_t "XCONF SCRIPT : Download image from HTTP server" >> $XCONF_LOG_FILE

		firmwareLocation=`grep firmwareLocation $OUTPUT | cut -d \| -f2 | tr -d ' '`
            else
                echo_t "XCONF SCRIPT : Download from $firmwareDownloadProtocol server not supported, check XCONF server configurations"
                echo_t "XCONF SCRIPT : Download from $firmwareDownloadProtocol server not supported, check XCONF server configurations" >> $XCONF_LOG_FILE
                echo_t "XCONF SCRIPT : Retrying query in 2 minutes" >> $XCONF_LOG_FILE


                retry_flag=1
                image_upg_avl=0

                if [ $xconf_retry_count -lt $((CONN_TRIES - 1)) ]; then
                    if [ "$UseCodebig" -eq "0" ]; then
                        sleep_time=120
                    elif [ "$xconf_retry_count" -eq "0" ]; then
                        sleep_time=10
                    else
                        sleep_time=30
                    fi
                    echo_t "XCONF SCRIPT : Retrying query in $sleep_time seconds" >> $XCONF_LOG_FILE
                    sleep $sleep_time
                fi

                #Increment the retry count
                xconf_retry_count=$((xconf_retry_count+1))

                continue
            fi
            echo "$firmwareLocation" > /tmp/.xconfssrdownloadurl
            firmwareFilename=`grep firmwareFilename $OUTPUT | cut -d \| -f2`
            firmwareVersion=`grep firmwareVersion $OUTPUT | cut -d \| -f2 | sed 's/-signed.*//'`
            ipv6FirmwareLocation=`grep ipv6FirmwareLocation  $OUTPUT | cut -d \| -f2 | tr -d ' '`
            upgradeDelay=`grep upgradeDelay $OUTPUT | cut -d \| -f2`
            delayDownload=`grep delayDownload $OUTPUT | cut -d \| -f2`

		rebootImmediately=`grep rebootImmediately $OUTPUT | cut -d \| -f2`

                 echo_t "XCONF SCRIPT : Protocol :"$firmwareDownloadProtocol
                 echo_t "XCONF SCRIPT : Filename :"$firmwareFilename
                 echo_t "XCONF SCRIPT : Location :"$firmwareLocation
                 echo_t "XCONF SCRIPT : Version  :"$firmwareVersion
                 echo_t "XCONF SCRIPT : Reboot   :"$rebootImmediately

                 if [ -n "$delayDownload" ]; then
                     echo_t "XCONF SCRIPT : Device configured with download delay of $delayDownload minutes"
                     echo_t "XCONF SCRIPT : Device configured with download delay of $delayDownload minutes" >> $XCONF_LOG_FILE
                 fi

                 if [ -z "$delayDownload" ] || [ "$rebootImmediately" = "true" ] || [ $delayDownload -lt 0 ];then
                     delayDownload=0
                     echo_t "XCONF SCRIPT : Resetting the download delay to 0 minutes" >> $XCONF_LOG_FILE
                 fi
            if [ "X"$firmwareLocation = "X" ];then
                echo_t "XCONF SCRIPT : No URL received in $FILENAME" >> $XCONF_LOG_FILE
                retry_flag=1
                image_upg_avl=0

                if [ $xconf_retry_count -lt $((CONN_TRIES - 1)) ]; then
                    if [ "$UseCodebig" -eq "0" ]; then
                        sleep_time=120
                    elif [ "$xconf_retry_count" -eq "0" ]; then
                        sleep_time=10
                    else
                        sleep_time=30
                    fi
                    echo_t "XCONF SCRIPT : Retrying query in $sleep_time seconds" >> $XCONF_LOG_FILE
                    sleep $sleep_time
                fi
                #Increment the retry count
                xconf_retry_count=$((xconf_retry_count+1))

            else
                if [ "$UseCodebig" -eq "1" ] && [ $CDL_SERVER_OVERRIDE -eq 0 ];then

                        imageHTTPURL="$firmwareLocation/$firmwareFilename"
                        domainName=`echo $imageHTTPURL | awk -F/ '{print $3}'`
                        imageHTTPURL=`echo $imageHTTPURL | sed -e "s|.*$domainName||g"`

                        echo imageHTTPURL : $imageHTTPURL
                        echo $imageHTTPURL >> $XCONF_LOG_FILE
			
						adjustDate

                        echo_t "XCONF SCRIPT : Get Signed URL from configparamgen for ssr respose"

                        ########Get Signed URL from configparamgen.################
                        SIGN_CMD="configparamgen 1 \"$imageHTTPURL\""
                        echo $SIGN_CMD >>$XCONF_LOG_FILE
                        echo -e "\n"
                        eval $SIGN_CMD > /nvram/.signedRequest
                        cbSignedimageHTTPURL1=`cat /nvram/.signedRequest`
                        cbSignedimageHTTPURL_Log=`echo $cbSignedimageHTTPURL1 | sed -ne 's#oauth_consumer_key=.*oauth_signature.*#-- <hidden> --#p'`

                        echo cbSignedimageHTTPURL1 : $cbSignedimageHTTPURL_Log
                        echo $cbSignedimageHTTPURL_Log >>$XCONF_LOG_FILE
                        rm -f /nvram/.signedRequest
                        rm -f /nvram/adjdate.txt

                        cbSignedimageHTTPURL=`echo $cbSignedimageHTTPURL1 | sed 's|stb_cdl%2F|stb_cdl/|g'`
                        serverUrl=`echo $cbSignedimageHTTPURL | sed -e "s|&oauth_consumer_key.*||g"`
                        authorizationHeader=`echo $cbSignedimageHTTPURL | sed -e "s|&|\", |g" -e "s|=|=\"|g" -e "s|.*oauth_consumer_key|oauth_consumer_key|g"`
                        authorizationHeader="Authorization: OAuth realm=\"\", $authorizationHeader\""

                        echo $authorizationHeader > /tmp/authHeader
                        echo_t "authorizationHeader written to /tmp/authHeader"

                   CURL_CMD="curl $CERT_STATUS --connect-timeout 30 --tlsv1.2 --interface $interface -H '$authorizationHeader' $addr_type -w '%{http_code}\n' -fgLo /var/$firmwareFilename '$serverUrl'"
                        CURL_CMD_LOG=`echo $CURL_CMD | sed -ne 's#oauth_consumer_key=.*oauth_signature.*#-- <hidden> --#p'`
                        echo CURL_CMD_CDL : $CURL_CMD_LOG
                        echo CURL_CMD_CDL : $CURL_CMD_LOG >>$XCONF_LOG_FILE
                    echo_t "Execute above curl command to start code download (if you want to try manually)"
				fi	

                # Check if a newer version was returned in the response
            # If image_upg_avl = 0, retry reconnecting with XCONf in next window
            # If image_upg_avl = 1, download new firmware
                        #This is a temporary function added to check FirmwareUpgCriteria
                        #This function will not check any other criteria other than matching current firmware and requested firmware

                        checkFirmwareUpgCriteria_temp

                        if [ $image_upg_avl -eq 1 ] && [ $delayDownload -ne 0 ] && [ "$triggeredFrom" != "delayedDownload" ];
                        then
                            cp $OUTPUT $LAST_HTTP_RESPONSE
                            echo "curr_conn_type|$curr_conn_type" >> $LAST_HTTP_RESPONSE

                            now=$(date +"%T")
                            SchedAtHr=$(echo $now | cut -d':' -f1)
                            SchedAtMin=$(echo $now | cut -d':' -f2)
                            Sec=$(echo $now | cut -d':' -f3)

                            if [ $Sec -gt 29 ]; then
                                SchedAtMin=`expr $SchedAtMin + 1`
                            fi

                            SchedAtMin=`expr $SchedAtMin + $delayDownload`
                            while [ $SchedAtMin -gt 59 ]
                            do
                                SchedAtMin=`expr $SchedAtMin - 60`
                                SchedAtHr=`expr $SchedAtHr + 1`
                                if [ $SchedAtHr -gt 23 ]; then
                                    SchedAtHr=0
                                fi
                            done

                            echo_t "XCONF SCRIPT : current Time: $now, download scheduled at $SchedAtHr:$SchedAtMin" >> $XCONF_LOG_FILE

                            if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
                                crontab -l -c $CRONTAB_DIR > $CRON_FILE_BK
                                SCRIPT_NAME=${0##*/}
                                sed -i "/[A-Za-z0-9]*$SCRIPT_NAME 5 */d" $CRON_FILE_BK
                                echo "$SchedAtMin $SchedAtHr * * * /etc/$SCRIPT_NAME 5" >> $CRON_FILE_BK
                                crontab $CRON_FILE_BK -c $CRONTAB_DIR
                                rm -rf $CRON_FILE_BK

                                exit
                            else
                                delayDownloadSec=$((delayDownload*60))
                                sleep $delayDownloadSec
                            fi
                        fi

                        fi


        # If a response code of 404 was received, exit
        elif [ $HTTP_RESPONSE_CODE -eq 404 ]; then
            retry_flag=0
            image_upg_avl=0
            echo_t "XCONF SCRIPT : Response code received is 404" >> $XCONF_LOG_FILE
            if [ "$DEVICE_MODEL" = "TCHXB3" ]; then
                echo_t "XCONF SCRIPT : Creating /tmp/.xconfssrdownloadurl with $HTTP_RESPONSE_CODE Xconf response"  >> $XCONF_LOG_FILE
                echo "404" > /tmp/.xconfssrdownloadurl
            fi

            if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
                exit
            fi
        # If a response code of 0 was received, the server is unreachable
        # Try reconnecting
        else

            retry_flag=1
            image_upg_avl=0

            if [ $xconf_retry_count -lt $((CONN_TRIES - 1)) ]; then
                if [ "$UseCodebig" -eq "0" ]; then
                    sleep_time=120
                elif [ "$xconf_retry_count" -eq "0" ]; then
                    sleep_time=10
                else
                    sleep_time=30
                fi
                echo_t "XCONF SCRIPT : Retrying query in $sleep_time seconds" >> $XCONF_LOG_FILE
                sleep $sleep_time
            fi
            #Increment the retry count
            xconf_retry_count=$((xconf_retry_count+1))

        fi

    done

    if [ $xconf_retry_count -ge $CONN_TRIES ] && [ $image_upg_avl -eq 0 ]; then
        if [ "$UseCodebig" -eq "1" ]; then
            [ -f $CODEBIG_BLOCK_FILENAME ] || touch $CODEBIG_BLOCK_FILENAME
            touch $FORCE_DIRECT_ONCE
        fi
        echo_t "XCONF SCRIPT : Retry limit to connect with XCONF server reached"
        if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
	   exit
	fi
    fi
}

#Fetch firmware name and location from last saved response.
fetchFirmwareDetail()
{
    #Firmware download delay timer expired. Remove it from cron.
    SCRIPT_NAME=${0##*/}
    crontab -l -c $CRONTAB_DIR > $CRON_FILE_BK
    sed -i "/[A-Za-z0-9]*$SCRIPT_NAME 5 */d" $CRON_FILE_BK
    crontab $CRON_FILE_BK -c $CRONTAB_DIR
    rm -rf $CRON_FILE_BK

    if [ ! -e $LAST_HTTP_RESPONSE ]; then
        echo_t "XCONF SCRIPT : Last saved file not available" >> $XCONF_LOG_FILE
        return
    fi
    echo_t "XCONF SCRIPT : Fetching firmware details from last saved response" >> $XCONF_LOG_FILE

    firmwareDownloadProtocol=`grep firmwareDownloadProtocol $LAST_HTTP_RESPONSE  | cut -d \| -f2`
    firmwareLocation=`grep firmwareLocation $LAST_HTTP_RESPONSE | cut -d \| -f2 | tr -d ' '`
    firmwareFilename=`grep firmwareFilename $LAST_HTTP_RESPONSE | cut -d \| -f2`

    if [ -z "$firmwareLocation" ] || [ -z "$firmwareFilename" ]; then
        echo_t "XCONF SCRIPT : Fetch firmware upgrade details from Xconf" >> $XCONF_LOG_FILE
        return
    fi

    firmwareVersion=`grep firmwareVersion $LAST_HTTP_RESPONSE | cut -d \| -f2`
    ipv6FirmwareLocation=`grep ipv6FirmwareLocation $LAST_HTTP_RESPONSE | cut -d \| -f2 | tr -d ' '`
    delayDownload=`grep delayDownload $LAST_HTTP_RESPONSE | cut -d \| -f2`
    rebootImmediately=`grep rebootImmediately $LAST_HTTP_RESPONSE | cut -d \| -f2`
    curr_conn_type=`grep curr_conn_type $LAST_HTTP_RESPONSE | cut -d \| -f2`

    image_upg_avl=1;

    if [ "$curr_conn_type" != "direct" ]; then
        serverUrl=""
        authorizationHeader=""
        imageHTTPURL="$firmwareLocation/$firmwareFilename"
        domainName=`echo $imageHTTPURL | awk -F/ '{print $3}'`
        imageHTTPURL=`echo $imageHTTPURL | sed -e "s|.*$domainName||g"`
        do_Codebig_signing "SSR"
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

    # Extract maintenance window start and end time
    if [ -f "$FW_START" ] && [ -f "$FW_END" ]
    then
      start_time=`cat $FW_START`
      end_time=`cat $FW_END`
    fi

    if [ "$start_time" = "$end_time" ]
    then
        echo_t "XCONF SCRIPT : Start time can not be equal to end time" >> $XCONF_LOG_FILE
	t2CountNotify "Test_StartEndEqual"
        echo_t "XCONF SCRIPT : Resetting values to default" >> $XCONF_LOG_FILE
	if [ "$MODEL_NUM" = "DPC3939B" ] || [ "$MODEL_NUM" = "DPC3941B" ]; then
          start_time=0
          end_time=10800
        else
          start_time=3600
          end_time=14400
	fi
        echo "$start_time" > $FW_START
        echo "$end_time" > $FW_END
    fi

    echo_t "XCONF SCRIPT : Firmware upgrade start time : $start_time" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : Firmware upgrade end time : $end_time" >> $XCONF_LOG_FILE

    #
    # Generate time to check for update
    #
    if [ $1 -eq '1' ]; then

        echo_t "XCONF SCRIPT : Check Update time being calculated within 24 hrs."
        echo_t "XCONF SCRIPT : Check Update time being calculated within 24 hrs." >> $XCONF_LOG_FILE

        # Calculate random hour
        # The max random time can be 23:59:59
        rand_hr=`awk -v min=0 -v max=23 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

        echo_t "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec"
        min_to_sleep=$(($rand_hr*60 + $rand_min))
        sec_to_sleep=$(($min_to_sleep*60 + $rand_sec))

        printf "XCONF SCRIPT : Checking update with XCONF server at \t";
        # date -d "$min_to_sleep minutes" +'%H:%M:%S'
        date -d @"$(( `date +%s`+$sec_to_sleep ))"

        date_upgch_part="$(( `date +%s`+$sec_to_sleep ))"
        date_upgch_final=`date -d @"$date_upgch_part"`

        echo_t "Checking update on $date_upgch_final" >> $XCONF_LOG_FILE

    fi

    #
    # Generate time to downlaod HTTP image
    # device reboot time
    #
    if [ $2 -eq '1' ]; then

        if [ "$3" == "r" ]; then
            echo_t "XCONF SCRIPT : Device reboot time being calculated in maintenance window"
            echo_t "XCONF SCRIPT : Device reboot time being calculated in maintenance window" >> $XCONF_LOG_FILE
        fi

        if [ "$start_time" -gt "$end_time" ]
        then
            start_time=$(($start_time-86400))
        fi

        #Calculate random value
        random_time=`awk -v min=$start_time -v max=$end_time 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'`

        if [ $random_time -le 0 ]
        then
            random_time=$((random_time+86400))
        fi
        random_time_in_sec=$random_time

        # Calculate random second
        rand_sec=$((random_time%60))

        # Calculate random min
        random_time=$((random_time/60))
        rand_min=$((random_time%60))

        # Calculate random hour
        random_time=$((random_time/60))
        rand_hr=$((random_time%60))

        echo_t "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec" >> $XCONF_LOG_FILE

        # Get current time
        if [ "$UTC_ENABLE" == "true" ]
        then
            cur_hr=`LTime H | sed 's/^0*//'`
            cur_min=`LTime M | sed 's/^0*//'`
            cur_sec=`date +"%S" | sed 's/^0*//'`
        else
            cur_hr=`date +"%H" | sed 's/^0*//'`
            cur_min=`date +"%M" | sed 's/^0*//'`
            cur_sec=`date +"%S" | sed 's/^0*//'`
        fi
        echo_t "XCONF SCRIPT : Current Local Time: $cur_hr hr $cur_min min $cur_sec sec" >> $XCONF_LOG_FILE

        curr_hr_in_sec=$((cur_hr*60*60))
        curr_min_in_sec=$((cur_min*60))
        curr_time_in_sec=$((curr_hr_in_sec+curr_min_in_sec+cur_sec))
        echo_t "XCONF SCRIPT : Current Time in secs: $curr_time_in_sec sec" >> $XCONF_LOG_FILE

        if [ $curr_time_in_sec -le $random_time_in_sec ]
        then
            sec_to_sleep=$((random_time_in_sec-curr_time_in_sec))
        else
            sec_to_12=$((86400-curr_time_in_sec))
            sec_to_sleep=$((sec_to_12+random_time_in_sec))
        fi

        min_to_sleep=$((sec_to_sleep/60))

        time=$(( `date +%s`+$sec_to_sleep ))
        date_final=`date -d @${time} +"%T"`

        echo_t "Action on $date_final"
        echo_t "Action on $date_final" >> $XCONF_LOG_FILE
        touch $REBOOT_WAIT
    fi

    echo_t "XCONF SCRIPT : SLEEPING FOR $min_to_sleep minutes or $sec_to_sleep seconds"
    echo_t "XCONF SCRIPT : SLEEPING FOR $min_to_sleep minutes or $sec_to_sleep seconds" >> $XCONF_LOG_FILE

    #echo "XCONF SCRIPT : SPIN 17 : sleeping for 30 sec, *******TEST BUILD***********"
    #sec_to_sleep=30

    sleep $sec_to_sleep
    echo_t "XCONF script : got up after $sec_to_sleep seconds"
    echo_t "XCONF script : got up after $sec_to_sleep seconds" >> $XCONF_LOG_FILE
}

# Get the MAC address of the WAN interface
getMacAddress()
{
        ifconfig  | grep $interface |  grep -v $interface:0 | tr -s ' ' | cut -d ' ' -f5
}

getBuildType()
{
   IMAGENAME=`grep "imagename" /fss/gw/version.txt | cut -d ":" -f 2`

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

   echo_t "XCONF SCRIPT : image_type is $type"
   echo_t "XCONF SCRIPT : image_type is $type" >> $XCONF_LOG_FILE
}


removeLegacyResources()
{
        #moved Xconf logging to /var/tmp/xconf.txt.0
    if [ -f /etc/Xconf.log ]; then
                rm /etc/Xconf.log
    fi

        echo_t "XCONF SCRIPT : Done Cleanup"
        echo_t "XCONF SCRIPT : Done Cleanup" >> $XCONF_LOG_FILE
}
# Check if it is still in maintenance window
checkMaintenanceWindow()
{
    if [ -f "$FW_START" ] && [ -f "$FW_END" ]
    then
      start_time=`cat $FW_START`
      end_time=`cat $FW_END`
    fi

    if [ "$start_time" -eq "$end_time" ]
    then
        echo_t "XCONF SCRIPT : Start time can not be equal to end time" >> $XCONF_LOG_FILE
	t2CountNotify "Test_StartEndEqual"
        echo_t "XCONF SCRIPT : Resetting values to default" >> $XCONF_LOG_FILE
	if [ "$MODEL_NUM" = "DPC3939B" ] || [ "$MODEL_NUM" = "DPC3941B" ]; then
          start_time=0
          end_time=10800
        else
          start_time=3600
          end_time=14400
	fi
        echo "$start_time" > $FW_START
        echo "$end_time" > $FW_END
    fi
    echo_t "XCONF SCRIPT : Firmware upgrade start time : $start_time" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : Firmware upgrade end time : $end_time" >> $XCONF_LOG_FILE

    if [ "$UTC_ENABLE" == "true" ]
    then
        reb_hr=`LTime H | sed 's/^0*//'`
        reb_min=`LTime M | sed 's/^0*//'`
        reb_sec=`date +"%S" | sed 's/^0*//'`
    else
        reb_hr=`date +"%H" | sed 's/^0*//'`
        reb_min=`date +"%M" | sed 's/^0*//'`
        reb_sec=`date +"%S" | sed 's/^0*//'`
    fi

    reb_window=0
    reb_hr_in_sec=$((reb_hr*60*60))
    reb_min_in_sec=$((reb_min*60))
    reb_time_in_sec=$((reb_hr_in_sec+reb_min_in_sec+reb_sec))
    echo_t "XCONF SCRIPT : Current time in seconds : $reb_time_in_sec" >> $XCONF_LOG_FILE

    if [ $start_time -lt $end_time ] && [ $reb_time_in_sec -ge $start_time ] && [ $reb_time_in_sec -lt $end_time ]
    then
        reb_window=1
    elif [ $start_time -gt $end_time ] && [[ $reb_time_in_sec -lt $end_time || $reb_time_in_sec -ge $start_time ]]
    then
        reb_window=1
    else
        reb_window=0
    fi
}
#####################################################Main Application#####################################################

# Determine the env type and url and write to /tmp/Xconf
#type=`printenv model | cut -d "=" -f2`

removeLegacyResources
getBuildType

# Check if the firmware download process is initiated by scheduler or during boot up.
triggeredFrom=""
if [ "$1" = "1" ]
then
   echo "XCONF SCRIPT : Trigger is from boot" >> $XCONF_LOG_FILE
   triggeredFrom="boot"
elif [ "$1" = "2" ]
then
   echo "XCONF SCRIPT : Trigger is from cron" >> $XCONF_LOG_FILE
   triggeredFrom="cron"
elif [[ $1 -eq 5 ]]
then
   echo_t "XCONF SCRIPT : Trigger from delayDownload Timer" >> $XCONF_LOG_FILE
   triggeredFrom="delayedDownload"
else
   echo "XCONF SCRIPT : Trigger is Unknown. Set it to boot" >> $XCONF_LOG_FILE
   triggeredFrom="boot"
fi

# If unit is waiting for reboot after image download,we need not have to download image again.
if [ -f $REBOOT_WAIT ]
then
    echo "XCONF SCRIPT : Waiting reboot after download, so exit" >> $XCONF_LOG_FILE
    exit
fi

if [ -f $DOWNLOAD_INPROGRESS ]
then
    echo "XCONF SCRIPT : Download is in progress, exit" >> $XCONF_LOG_FILE
    exit
fi

modelName=`dmcli eRT getv Device.DeviceInfo.ModelName | grep value | cut -d ":" -f 3 | tr -d ' ' `
echo "XCONF SCRIPT : MODEL IS $modelName" >> $XCONF_LOG_FILE

#Default xconf url
url="https://xconf.xcal.tv/xconf/swu/stb/"

# Override mechanism should work only for non-production build.
if [ "$type" != "PROD" ] && [ "$type" != "prod" ]; then
  if [ -f /nvram/swupdate.conf ]; then
      url=`grep -v '^[[:space:]]*#' /nvram/swupdate.conf`
      echo_t "XCONF SCRIPT : URL taken from /nvram/swupdate.conf override. URL=$url"
      echo_t "XCONF SCRIPT : URL taken from /nvram/swupdate.conf override. URL=$url"  >> $XCONF_LOG_FILE
      CDL_SERVER_OVERRIDE=1
  else
      # RFC override should work only for non-production build
      url_override=`syscfg get AutoExcludedURL`
      if [ "$url_override" ] ; then
         url=$url_override
      fi
  fi
fi

echo_t "XCONF SCRIPT : Device retrieves firmware update from url=$url"

#s16 echo "$type=$url" > /tmp/Xconf
echo "URL=$url" > /tmp/Xconf
echo_t "XCONF SCRIPT : Values written to /tmp/Xconf are URL=$url"
echo_t "XCONF SCRIPT : Values written to /tmp/Xconf are URL=$url" >> $XCONF_LOG_FILE

# Check if the WAN interface has an ip address, if not , wait for it to receive one
estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
estbIp6=`ifconfig $interface | grep "inet6 addr" | grep "Global" | tr -s " " | cut -d ":" -f2- | cut -d "/" -f1 | tr -d " "`

echo "[ $(date) ] XCONF SCRIPT - Check if the WAN interface has an ip address" >> $XCONF_LOG_FILE

while [ "$estbIp" = "" ] && [ "$estbIp6" = "" ]
do
    echo "[ $(date) ] XCONF SCRIPT - No IP yet! sleep(5)" >> $XCONF_LOG_FILE
    sleep 5

    estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
    estbIp6=`ifconfig $interface | grep "inet6 addr" | grep "Global" | tr -s " " | cut -d ":" -f2- | cut -d "/" -f1 | tr -d " "`

    echo_t "XCONF SCRIPT : Sleeping for an ipv4 or an ipv6 address on the $interface interface "
done

echo_t "XCONF SCRIPT : $interface has an ipv4 address of $estbIp or an ipv6 address of $estbIp6"

    ######################
    # QUERY & DL MANAGER #
    ######################
# Checking Autoupdate exclusion
FWUPGRADE_EXCLUDE=`syscfg get AutoExcludedEnabled`
echo "FWExclusion status is : $FWUPGRADE_EXCLUDE"

# Triggered after delayedDownload timer expired
if [ "$triggeredFrom" = "delayedDownload" ];
then
    fetchFirmwareDetail
fi

# Check if new image is available
echo_t "XCONF SCRIPT : Checking image availability at boot up" >> $XCONF_LOG_FILE
if [ ! -e $NO_DOWNLOAD ] && [ $image_upg_avl -eq 0 ];
then	
   getFirmwareUpgDetail
fi

if [ "$rebootImmediately" == "true" ];then
    echo_t "XCONF SCRIPT : Reboot Immediately : TRUE!!"
else
    echo_t "XCONF SCRIPT : Reboot Immediately : FALSE."

fi

download_image_success=0
reboot_device_success=0
http_flash_led_disable=0
is_already_flash_led_disable=0
retry_download=0

while [ $download_image_success -eq 0 ];
do

   #skip download if file exist
   if [ -f $NO_DOWNLOAD ]
   then
      break
   fi

    if [ "$isPeriodicFWCheckEnabled" != "true" ]
    then
       # If an image wasn't available, check it's 
       # availability at a random time,every 24 hrs
       while  [ $image_upg_avl -eq 0 ];
       do
         echo_t "XCONF SCRIPT : Rechecking image availability within 24 hrs" 
         echo_t "XCONF SCRIPT : Rechecking image availability within 24 hrs" >> $XCONF_LOG_FILE

         # Sleep for a random time less than 
         # a 24 hour duration 
         calcRandTime 1 0
    
         # Check for the availability of an update   
         getFirmwareUpgDetail
       done
    fi

    if [ ! -f $DOWNLOAD_INPROGRESS ]
    then
        touch $DOWNLOAD_INPROGRESS
    fi

    if [ $image_upg_avl -eq 1 ];then

        #Wait for dnsmasq to start
        DNSMASQ_PID=`pidof dnsmasq`

        while [ "$DNSMASQ_PID" = "" ]
        do
                sleep 10
                echo_t "XCONF SCRIPT : Waiting for dnsmasq process to start"
                echo_t "XCONF SCRIPT : Waiting for dnsmasq process to start" >> $XCONF_LOG_FILE
                DNSMASQ_PID=`pidof dnsmasq`
        done
                echo_t "XCONF SCRIPT : dnsmasq process  started!!"
                echo_t "XCONF SCRIPT : dnsmasq process  started!!" >> $XCONF_LOG_FILE

        echo "$firmwareLocation" > /tmp/xconfdownloadurl

        # Set the url and filename
		if [ "$UseCodebig" -eq "0" ] || [ $CDL_SERVER_OVERRIDE -eq 1 ];then
			echo_t "XCONF SCRIPT : URL --- $firmwareLocation and NAME --- $firmwareFilename"
			echo_t "XCONF SCRIPT : URL --- $firmwareLocation and NAME --- $firmwareFilename" >> $XCONF_LOG_FILE
			echo \"\" > /tmp/authHeader
			$BIN_PATH/XconfHttpDl set_http_url $firmwareLocation/$firmwareFilename $firmwareFilename complete_url

		else
		
        echo_t "XCONF SCRIPT : URL --- $serverUrl and NAME --- $firmwareFilename" >> $XCONF_LOG_FILE

                $BIN_PATH/XconfHttpDl set_http_url $serverUrl $firmwareFilename complete_url

		fi		
                set_url_stat=$?

        # If the URL was correctly set, initiate the download
        if [ $set_url_stat -eq 0 ];then

            # An upgrade is available and the URL has ben set
            # Wait to download in the maintenance window if the RebootImmediately is FALSE
            # else download the image immediately

            if [ "$rebootImmediately" == "false" ];then

                                echo_t "XCONF SCRIPT : Reboot Immediately : FALSE. Downloading image now" >> $XCONF_LOG_FILE
		   if  [ $is_already_flash_led_disable -eq 0 ];
		   then
			echo_t "XCONF SCRIPT	: ### Disabling httpdownload LED flash ###" >> $XCONF_LOG_FILE
			$BIN_PATH/XconfHttpDl http_flash_led $http_flash_led_disable
			 is_already_flash_led_disable=1
		   fi    
            else
                echo_t  "XCONF SCRIPT : Reboot Immediately : TRUE : Downloading image now" >> $XCONF_LOG_FILE
		   if  [ $is_already_flash_led_disable -eq 1 ];
		   then
			echo_t "XCONF SCRIPT	: ### Enabling httpdownload LED flash###" >> $XCONF_LOG_FILE
			$BIN_PATH/XconfHttpDl http_flash_led $http_flash_led_enable
			 is_already_flash_led_disable=0
		  fi  
            fi

			#Trigger FirmwareDownloadStartedNotification before commencement of firmware download
			current_time=`date +%s`
			echo_t "current_time calculated as $current_time" >> $XCONF_LOG_FILE
			dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.FirmwareDownloadStartedNotification string $current_time
			echo_t "XCONF SCRIPT : FirmwareDownloadStartedNotification SET is triggered" >> $XCONF_LOG_FILE

                # Start the image download
                        echo "[ $(date) ] XCONF SCRIPT  ### httpdownload started ###" >> $XCONF_LOG_FILE
                $BIN_PATH/XconfHttpDl http_download
                http_dl_stat=$?
                        echo "[ $(date) ] XCONF SCRIPT  ### httpdownload completed ###" >> $XCONF_LOG_FILE
                echo_t "XCONF SCRIPT : HTTP DL STATUS $http_dl_stat"
                echo_t "**XCONF SCRIPT : HTTP DL STATUS $http_dl_stat**" >> $XCONF_LOG_FILE

                # If the http_dl_stat is 0, the download was succesful,
            # Indicate a succesful download and continue to the reboot manager

            if [ $http_dl_stat -eq 0 ];then
                echo_t "XCONF SCRIPT : HTTP download Successful" >> $XCONF_LOG_FILE
		t2CountNotify "XCONF_Dwld_success"
                # Indicate succesful download
                download_image_success=1
                rm -rf $DOWNLOAD_INPROGRESS
            else
                # Indicate an unsuccesful download
                echo_t "XCONF SCRIPT : HTTP download NOT Successful" >> $XCONF_LOG_FILE
		t2CountNotify "XCONF_Dwld_failed"
                rm -rf $DOWNLOAD_INPROGRESS
                download_image_success=0
                # Set the flag to 0 to force a requery
                image_upg_avl=0
                if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
			# No need of looping here as we will trigger a cron job at random time
			exit
		fi
            fi

		#Trigger FirmwareDownloadCompletedNotification after firmware download

		# true indicates successful download and false indicates unsuccessful download.
		if [ $http_dl_stat -eq 0 ];then
			dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.FirmwareDownloadCompletedNotification bool true
			echo_t "FirmwareDownloadCompletedNotification SET to true is triggered" >> $XCONF_LOG_FILE
		else
			dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.FirmwareDownloadCompletedNotification bool false
			echo_t "FirmwareDownloadCompletedNotification SET to false is triggered" >> $XCONF_LOG_FILE
		fi


        else
	    download_image_success=0
            # Set the flag to 0 to force a requery
            image_upg_avl=0
            rm -rf $DOWNLOAD_INPROGRESS
 	    if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
                 retry_download=`expr $retry_download + 1`
	     
         	 if [ $retry_download -eq 3 ]
          	 then
             	    echo_t "XCONF SCRIPT : ERROR : URL & Filename not set correctly after 3 retries.Exiting" >> $XCONF_LOG_FILE
        	    exit  
          	 fi
            fi       
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
        checkMaintenanceWindow

        if [ $reb_window -eq 1 ]; then
            echo_t "XCONF SCRIPT : Still within current maintenance window for reboot"
            echo_t "XCONF SCRIPT : Still within current maintenance window for reboot" >> $XCONF_LOG_FILE
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
            checkMaintenanceWindow

            if [ $reb_window -eq 1 ]
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
        echo_t "XCONF SCRIPT : Reboot Immediately : TRUE!, rebooting device now"
        http_reboot_ready_stat=0
        echo_t "XCONF SCRIPT : http_reboot_ready_stat is $http_reboot_ready_stat"

    fi

    echo_t "XCONF SCRIPT : http_reboot_ready_stat is $http_reboot_ready_stat" >> $XCONF_LOG_FILE

    # The reboot ready status changed to OK within the maintenance window,proceed
    if [ $http_reboot_ready_stat -eq 0 ];then

	if [ $abortReboot_count -lt 5 ];then
		#Wait for Notification to propogate
		deferfw=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.DeferFWDownloadReboot | grep value | cut -d ":" -f 3 | tr -d ' ' `
		echo_t "XCONF SCRIPT : Sleeping for $deferfw seconds before reboot" >> $XCONF_LOG_FILE
		touch $deferReboot 
		dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.RebootPendingNotification uint $deferfw
		sleep $deferfw
	else
		echo_t "XCONF SCRIPT : Abort Count reached maximum limit $abortReboot_count" >> $XCONF_LOG_FILE
	fi

        #Abort Reboot
        if [ ! -e "$ABORT_REBOOT" ]
	then

	if [ "x$isWanLinkHealEnabled" == "xtrue" ];then
	    /usr/ccsp/tad/check_gw_health.sh store-health
	fi
        #Reboot the device
            echo_t "XCONF SCRIPT : Reboot possible. Issuing reboot command"
            echo_t "RDKB_REBOOT : Reboot command issued from XCONF"
		echo_t "setting LastRebootReason"
		dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_LastRebootReason string Software_upgrade
		echo_t "XCONF SCRIPT : SET succeeded"
                $BIN_PATH/XconfHttpDl http_reboot
                reboot_device=$?

        # This indicates we're within the maintenace window/rebootImmediate=TRUE
        # and the reboot ready status is OK, issue the reboot
        # command and check if it returned correctly
            if [ $reboot_device -eq 0 ];then
            reboot_device_success=1
                     #For rdkb-4260
            echo_t "Creating file /nvram/reboot_due_to_sw_upgrade"
            touch /nvram/reboot_due_to_sw_upgrade
            echo_t "XCONF SCRIPT : REBOOTING DEVICE"
            echo_t "RDKB_REBOOT : Rebooting device due to software upgrade"

            else
            # The reboot command failed, retry in the next maintenance window
            reboot_device_success=0
            #Goto start of Reboot Manager again
            fi
        else
                echo_t "XCONF SCRIPT : Reboot aborted by user, will try in next maintenance window " >> $XCONF_LOG_FILE
		abortReboot_count=$((abortReboot_count+1))
		echo_t "XCONF SCRIPT : Abort Count is  $abortReboot_count" >> $XCONF_LOG_FILE
                touch $NO_DOWNLOAD
                rm -rf $ABORT_REBOOT
                rm -rf $deferReboot
                reboot_device_success=0

		while [ 1 ]
		do
		    checkMaintenanceWindow

		    if [ $reb_window -eq 1 ]
		    then
		        #We're still within the maintenance window, sleeping for 2 hr to come out of maintenance window
		        sleep 7200
		    else
		        #If we're out of the maintenance window, exit while loop
		        break
		    fi
		done
       fi

     # The reboot ready status didn't change to OK within the maintenance window
     else
        reboot_device_success=0
            echo_t " XCONF SCRIPT : Device is not ready to reboot : Retrying in next reboot window ";
        # Goto start of Reboot Manager again
     fi

done # While loop for reboot manager

